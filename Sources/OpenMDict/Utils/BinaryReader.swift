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
/// **Backing storage**: prefers `mmap(2)` (`MAP_SHARED` + `PROT_READ`) — the
/// whole file is mapped into the address space and exposed as a zero-copy
/// `Data`. All reads are pure pointer dereferences: no syscalls, no userspace
/// copies, and no locking (reading mapped memory is inherently thread-safe).
///
/// On iOS this is a win for memory pressure: file-backed pages are *clean*
/// (PROT_READ, no writes), so the kernel can evict them at any time without
/// swap — they don't count toward the dirty footprint that drives jetsam.
///
/// **Runtime fallback**: if `mmap` fails (notably iOS refusing to map a very
/// large — 1 GB+ — file: `mmap` returns `MAP_FAILED`), the reader transparently
/// falls back to a `FileHandle` + `NSLock`. This is slower (a `pread`-style
/// syscall per access, serialized) but keeps the dictionary fully functional.
/// Without it, a single failed mapping silently strips *all* of a dict's MDD
/// resources (images / audio / js) while the MDX still loads.
///
/// `#if DEBUG_DISABLE_MMAP` forces the FileHandle path for QA / A-B testing.
///
/// **Why `MAP_SHARED` not `MAP_PRIVATE`**: the files are immutable and accessed
/// read-only, so copy-on-write is pointless; `MAP_SHARED` also avoids the COW
/// commit charge the kernel reserves for a `MAP_PRIVATE` region, which is the
/// most likely reason a 1 GB+ `MAP_PRIVATE` mapping was being refused on device.
final class BinaryReader {

    // MARK: - Storage
    //
    // Exactly one of these is non-nil. `mapped != nil` ⇒ mmap path (lock-free).
    // `handle != nil` ⇒ FileHandle fallback (serialized via `lock`).

    /// The mmap-backed `Data`. Its custom deallocator `munmap`s on release.
    private let mapped: Data?
    /// FileHandle fallback (also the `DEBUG_DISABLE_MMAP` path).
    private let handle: FileHandle?
    /// Serializes the FileHandle path only (the mmap path needs no lock).
    private let lock = NSLock()
    /// Sequential read cursor. Used by `readBytes`/`seek`/`skip` (single-threaded
    /// init parsing); random-access reads use `atomicRead(at:count:)`.
    private var cursor: Int = 0

    let fileSize: UInt64

    // MARK: - Init

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw BinaryReaderError.invalidData("Cannot open file: \(path)")
        }

        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else {
            close(fd)
            throw BinaryReaderError.invalidData("Cannot stat or empty file: \(path)")
        }
        let size = Int(st.st_size)
        self.fileSize = UInt64(size)

        #if DEBUG_DISABLE_MMAP
        let attemptMmap = false
        #else
        let attemptMmap = true
        #endif

        if attemptMmap {
            let rawPtr = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)
            if let raw = rawPtr, raw != UnsafeMutableRawPointer(bitPattern: -1) {
                close(fd)  // Unix mappings keep the file alive after close.
                // Hint random access — disables readahead so record lookups
                // don't pull in adjacent unused pages.
                _ = madvise(raw, size, MADV_RANDOM)
                self.mapped = Data(
                    bytesNoCopy: raw,
                    count: size,
                    deallocator: .custom { ptr, len in munmap(ptr, len) }
                )
                self.handle = nil
                return
            }
            // mmap failed — capture errno immediately, then fall back so the
            // dict still works instead of losing all MDD resources silently.
            let err = String(cString: strerror(errno))
            print("⚠️ BinaryReader: mmap failed (\(err)) for \(size)-byte file — using FileHandle fallback: \((path as NSString).lastPathComponent)")
        }

        // FileHandle fallback. Reuse the already-open fd (FileHandle closes it).
        self.mapped = nil
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: - Sequential cursor (used during init parsing)

    var position: UInt64 { UInt64(cursor) }

    func seek(to offset: UInt64) { cursor = Int(offset) }

    func skip(_ bytes: Int) { cursor += bytes }

    // MARK: - Reads

    /// Read raw bytes at the current cursor.
    ///
    /// Always returns a `Data` with `startIndex == 0` so that legacy callers
    /// using `data[0]` indexing keep working.
    func readBytes(_ count: Int) throws -> Data {
        if let mapped {
            let end = cursor + count
            guard end <= mapped.count else {
                throw BinaryReaderError.readFailed(expected: count, got: max(mapped.count - cursor, 0))
            }
            // Copy out of the mmap region into a fresh Data with startIndex == 0.
            let result = mapped.withUnsafeBytes { rawBuf -> Data in
                Data(bytes: rawBuf.baseAddress!.advanced(by: cursor), count: count)
            }
            cursor = end
            return result
        } else {
            lock.lock(); defer { lock.unlock() }
            handle!.seek(toFileOffset: UInt64(cursor))
            guard let data = try handle!.read(upToCount: count), data.count == count else {
                throw BinaryReaderError.readFailed(expected: count, got: 0)
            }
            cursor += count
            return data
        }
    }

    /// Read up to `count` bytes (allows partial reads).
    func readAvailable(_ count: Int) throws -> Data {
        if let mapped {
            let end = min(cursor + count, mapped.count)
            let actualCount = end - cursor
            let result = mapped.withUnsafeBytes { rawBuf -> Data in
                Data(bytes: rawBuf.baseAddress!.advanced(by: cursor), count: actualCount)
            }
            cursor = end
            return result
        } else {
            lock.lock(); defer { lock.unlock() }
            handle!.seek(toFileOffset: UInt64(cursor))
            let data = (try handle!.read(upToCount: count)) ?? Data()
            cursor += data.count
            return data
        }
    }

    /// Peek bytes without advancing the cursor (debug helper).
    func peekBytes(_ count: Int) throws -> Data {
        if let mapped {
            let end = min(cursor + count, mapped.count)
            let actualCount = end - cursor
            return mapped.withUnsafeBytes { rawBuf -> Data in
                Data(bytes: rawBuf.baseAddress!.advanced(by: cursor), count: actualCount)
            }
        } else {
            lock.lock(); defer { lock.unlock() }
            handle!.seek(toFileOffset: UInt64(cursor))
            return (try handle!.read(upToCount: count)) ?? Data()
        }
    }

    // MARK: - Atomic Read (thread-safe random access)

    /// Atomic seek-and-read: positions to `offset` and reads `count` bytes.
    ///
    /// On the mmap path this is **lock-free** — multiple threads read different
    /// regions concurrently. On the FileHandle fallback it serializes through
    /// `NSLock`. Both return a fresh `Data` with `startIndex == 0`.
    func atomicRead(at offset: UInt64, count: Int) throws -> Data {
        if let mapped {
            let start = Int(offset)
            let end = start + count
            guard start >= 0, end <= mapped.count else {
                throw BinaryReaderError.readFailed(expected: count, got: 0)
            }
            return mapped.withUnsafeBytes { rawBuf -> Data in
                Data(bytes: rawBuf.baseAddress!.advanced(by: start), count: count)
            }
        } else {
            lock.lock(); defer { lock.unlock() }
            handle!.seek(toFileOffset: offset)
            guard let data = try handle!.read(upToCount: count), data.count == count else {
                throw BinaryReaderError.readFailed(expected: count, got: 0)
            }
            return data
        }
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
