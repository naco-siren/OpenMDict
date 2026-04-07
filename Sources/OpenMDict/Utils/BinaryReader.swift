import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Errors that can occur during binary reading
enum BinaryReaderError: Error, CustomStringConvertible {
    case readFailed(expected: Int, got: Int)
    case seekFailed(position: UInt64)
    case invalidData(String)

    var description: String {
        switch self {
        case .readFailed(let expected, let got):
            return "Read failed: expected \(expected) bytes, got \(got)"
        case .seekFailed(let position):
            return "Seek failed to position \(position)"
        case .invalidData(let msg):
            return "Invalid data: \(msg)"
        }
    }
}

/// Low-level binary reader for MDX/MDD files.
///
/// **Backing storage**: `mmap(2)` with `MAP_PRIVATE` + `PROT_READ`. The entire
/// file is mapped into the process address space at construction time, exposed
/// as a zero-copy `Data` (via `bytesNoCopy`). All reads are pure pointer
/// dereferences — no syscalls, no userspace copies, and no locking is needed
/// because reading mapped memory is inherently thread-safe.
///
/// On iOS this is a meaningful win for memory pressure: `mmap`'d file pages
/// are *clean* (backed by the file on disk), so the kernel can evict them at
/// any time without swap. They do not count toward the process's dirty memory
/// footprint that drives jetsam.
///
/// **Fallback**: under `#if DEBUG_DISABLE_MMAP` the reader uses `FileHandle`
/// + `NSLock` (the previous implementation), retained for QA / A/B testing.
final class BinaryReader {

    // MARK: - Storage

    #if DEBUG_DISABLE_MMAP
    private let handle: FileHandle
    private let lock = NSLock()
    #else
    /// The mmap-backed `Data`. The custom deallocator releases the mapping
    /// when this `Data` is destroyed.
    private let mapped: Data
    /// Sequential read cursor (used during init parsing only — random-access
    /// reads use `atomicRead(at:count:)` which is stateless).
    private var cursor: Int = 0
    #endif

    let fileSize: UInt64

    // MARK: - Init

    init(path: String) throws {
        #if DEBUG_DISABLE_MMAP
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw BinaryReaderError.invalidData("Cannot open file: \(path)")
        }
        self.handle = handle
        let currentPos = handle.offsetInFile
        handle.seekToEndOfFile()
        self.fileSize = handle.offsetInFile
        handle.seek(toFileOffset: currentPos)
        #else
        // Open the file just long enough to mmap it; the fd can be closed
        // immediately after — Unix mappings keep the file alive.
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw BinaryReaderError.invalidData("Cannot open file: \(path)")
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else {
            throw BinaryReaderError.invalidData("Cannot stat or empty file: \(path)")
        }
        let size = Int(st.st_size)

        guard let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              raw != UnsafeMutableRawPointer(bitPattern: -1)
        else {
            throw BinaryReaderError.invalidData("mmap failed for: \(path)")
        }

        // Hint to the kernel: random access. Disables readahead so record
        // lookups don't pull in adjacent unused pages.
        _ = madvise(raw, size, MADV_RANDOM)

        // Wrap as Data with a custom deallocator so munmap fires when the
        // Data (and therefore this BinaryReader) is released.
        self.mapped = Data(
            bytesNoCopy: raw,
            count: size,
            deallocator: .custom { ptr, len in
                munmap(ptr, len)
            }
        )
        self.fileSize = UInt64(size)
        #endif
    }

    deinit {
        #if DEBUG_DISABLE_MMAP
        try? handle.close()
        #endif
    }

    // MARK: - Sequential cursor (used during init parsing)

    var position: UInt64 {
        #if DEBUG_DISABLE_MMAP
        return handle.offsetInFile
        #else
        return UInt64(cursor)
        #endif
    }

    func seek(to offset: UInt64) {
        #if DEBUG_DISABLE_MMAP
        handle.seek(toFileOffset: offset)
        #else
        cursor = Int(offset)
        #endif
    }

    func skip(_ bytes: Int) {
        #if DEBUG_DISABLE_MMAP
        handle.seek(toFileOffset: handle.offsetInFile + UInt64(bytes))
        #else
        cursor += bytes
        #endif
    }

    // MARK: - Reads

    /// Read raw bytes at the current cursor.
    ///
    /// Always returns a `Data` with `startIndex == 0` so that legacy callers
    /// using `data[0]` indexing keep working.
    func readBytes(_ count: Int) throws -> Data {
        #if DEBUG_DISABLE_MMAP
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw BinaryReaderError.readFailed(expected: count, got: 0)
        }
        return data
        #else
        let end = cursor + count
        guard end <= mapped.count else {
            throw BinaryReaderError.readFailed(expected: count, got: max(mapped.count - cursor, 0))
        }
        // Copy out of the mmap region into a fresh Data with startIndex == 0.
        // This is a memcpy, but mmap still saves us the syscall + the kernel
        // page-cache → user-buffer transition that FileHandle.read does.
        let result = mapped.withUnsafeBytes { rawBuf -> Data in
            let base = rawBuf.baseAddress!.advanced(by: cursor)
            return Data(bytes: base, count: count)
        }
        cursor = end
        return result
        #endif
    }

    /// Read up to `count` bytes (allows partial reads).
    func readAvailable(_ count: Int) throws -> Data {
        #if DEBUG_DISABLE_MMAP
        return try handle.read(upToCount: count) ?? Data()
        #else
        let end = min(cursor + count, mapped.count)
        let actualCount = end - cursor
        let result = mapped.withUnsafeBytes { rawBuf -> Data in
            let base = rawBuf.baseAddress!.advanced(by: cursor)
            return Data(bytes: base, count: actualCount)
        }
        cursor = end
        return result
        #endif
    }

    /// Peek bytes without advancing the cursor (debug helper).
    func peekBytes(_ count: Int) throws -> Data {
        #if DEBUG_DISABLE_MMAP
        let currentPos = handle.offsetInFile
        guard let data = try handle.read(upToCount: count) else { return Data() }
        handle.seek(toFileOffset: currentPos)
        return data
        #else
        let end = min(cursor + count, mapped.count)
        let actualCount = end - cursor
        return mapped.withUnsafeBytes { rawBuf -> Data in
            let base = rawBuf.baseAddress!.advanced(by: cursor)
            return Data(bytes: base, count: actualCount)
        }
        #endif
    }

    // MARK: - Atomic Read (thread-safe random access)

    /// Atomic seek-and-read: positions to `offset` and reads `count` bytes.
    ///
    /// On the mmap path this is **lock-free** — multiple threads can read
    /// different regions concurrently without contention. We still memcpy
    /// out of the mapping into a fresh `Data` so callers can rely on
    /// `startIndex == 0`. The wins versus `FileHandle.read` are:
    ///   1. No `read(2)` syscall per call.
    ///   2. No double-buffering (page cache → kernel buffer → user buffer).
    ///   3. Clean file-backed pages (jetsam-friendly on iOS).
    ///   4. No `NSLock` contention.
    ///
    /// On the `FileHandle` fallback path it serializes through `NSLock`.
    func atomicRead(at offset: UInt64, count: Int) throws -> Data {
        #if DEBUG_DISABLE_MMAP
        lock.lock()
        defer { lock.unlock() }
        handle.seek(toFileOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw BinaryReaderError.readFailed(expected: count, got: 0)
        }
        return data
        #else
        let start = Int(offset)
        let end = start + count
        guard start >= 0, end <= mapped.count else {
            throw BinaryReaderError.readFailed(expected: count, got: 0)
        }
        return mapped.withUnsafeBytes { rawBuf -> Data in
            let base = rawBuf.baseAddress!.advanced(by: start)
            return Data(bytes: base, count: count)
        }
        #endif
    }

    // MARK: - Integer reading (Big Endian — MDX uses BE)

    func readUInt8() throws -> UInt8 {
        let data = try readBytes(1)
        return data[data.startIndex]
    }

    func readUInt16BE() throws -> UInt16 {
        let data = try readBytes(2)
        let s = data.startIndex
        return UInt16(data[s]) << 8 | UInt16(data[s + 1])
    }

    func readUInt32BE() throws -> UInt32 {
        let data = try readBytes(4)
        let s = data.startIndex
        return UInt32(data[s]) << 24 | UInt32(data[s + 1]) << 16
             | UInt32(data[s + 2]) << 8  | UInt32(data[s + 3])
    }

    func readUInt64BE() throws -> UInt64 {
        let data = try readBytes(8)
        let s = data.startIndex
        return UInt64(data[s]) << 56 | UInt64(data[s + 1]) << 48
             | UInt64(data[s + 2]) << 40 | UInt64(data[s + 3]) << 32
             | UInt64(data[s + 4]) << 24 | UInt64(data[s + 5]) << 16
             | UInt64(data[s + 6]) << 8  | UInt64(data[s + 7])
    }

    func readInt32BE() throws -> Int32 {
        Int32(bitPattern: try readUInt32BE())
    }

    func readInt64BE() throws -> Int64 {
        Int64(bitPattern: try readUInt64BE())
    }

    // MARK: - Little Endian (for some fields)

    func readUInt32LE() throws -> UInt32 {
        let data = try readBytes(4)
        let s = data.startIndex
        return UInt32(data[s]) | UInt32(data[s + 1]) << 8
             | UInt32(data[s + 2]) << 16 | UInt32(data[s + 3]) << 24
    }
}

// MARK: - Data extensions for parsing (safe, no alignment required)

extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset >= 0 && offset + 1 < self.count else { return 0 }
        let s = self.startIndex + offset
        return UInt16(self[s]) << 8 | UInt16(self[s + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 3 < self.count else { return 0 }
        let s = self.startIndex + offset
        return UInt32(self[s]) << 24 | UInt32(self[s + 1]) << 16
             | UInt32(self[s + 2]) << 8 | UInt32(self[s + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 7 < self.count else { return 0 }
        let s = self.startIndex + offset
        return UInt64(self[s]) << 56 | UInt64(self[s + 1]) << 48
             | UInt64(self[s + 2]) << 40 | UInt64(self[s + 3]) << 32
             | UInt64(self[s + 4]) << 24 | UInt64(self[s + 5]) << 16
             | UInt64(self[s + 6]) << 8  | UInt64(self[s + 7])
    }
}
