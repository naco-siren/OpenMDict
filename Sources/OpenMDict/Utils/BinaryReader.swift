import Foundation

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
/// Thread safety:
/// - Sequential methods (`seek`, `readBytes`, etc.) are used during initialization
///   (header/keyword/record-block parsing) where no concurrency exists.
/// - `atomicRead(at:count:)` wraps seek+read under `NSLock` for post-init
///   random access (`loadRecord`) that may be called from multiple threads.
final class BinaryReader {
    private let handle: FileHandle
    private let lock = NSLock()
    let fileSize: UInt64
    
    init(path: String) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw BinaryReaderError.invalidData("Cannot open file: \(path)")
        }
        self.handle = handle
        
        let currentPos = handle.offsetInFile
        handle.seekToEndOfFile()
        self.fileSize = handle.offsetInFile
        handle.seek(toFileOffset: currentPos)
    }
    
    deinit {
        try? handle.close()
    }
    
    var position: UInt64 {
        handle.offsetInFile
    }
    
    func seek(to offset: UInt64) {
        handle.seek(toFileOffset: offset)
    }
    
    func skip(_ bytes: Int) {
        handle.seek(toFileOffset: handle.offsetInFile + UInt64(bytes))
    }
    
    /// Read raw bytes
    func readBytes(_ count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw BinaryReaderError.readFailed(expected: count, got: 0)
        }
        return data
    }
    
    /// Read bytes, allowing partial reads
    func readAvailable(_ count: Int) throws -> Data {
        return try handle.read(upToCount: count) ?? Data()
    }
    
    /// Peek bytes without advancing position (useful for debugging)
    func peekBytes(_ count: Int) throws -> Data {
        let currentPos = handle.offsetInFile
        guard let data = try handle.read(upToCount: count) else {
            return Data()
        }
        handle.seek(toFileOffset: currentPos)
        return data
    }
    
    // MARK: - Atomic Read (thread-safe)

    /// Atomic seek-and-read: positions to `offset`, reads `count` bytes, under lock.
    /// Use this for post-init random access (e.g., `loadRecord`) where concurrent
    /// calls from multiple threads are possible.
    func atomicRead(at offset: UInt64, count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        handle.seek(toFileOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw BinaryReaderError.readFailed(expected: count, got: 0)
        }
        return data
    }

    // MARK: - Integer reading (Big Endian - MDX uses BE)
    
    func readUInt8() throws -> UInt8 {
        let data = try readBytes(1)
        return data[0]
    }
    
    func readUInt16BE() throws -> UInt16 {
        let data = try readBytes(2)
        return UInt16(data[0]) << 8 | UInt16(data[1])
    }
    
    func readUInt32BE() throws -> UInt32 {
        let data = try readBytes(4)
        return UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
    }
    
    func readUInt64BE() throws -> UInt64 {
        let data = try readBytes(8)
        return UInt64(data[0]) << 56 | UInt64(data[1]) << 48 |
               UInt64(data[2]) << 40 | UInt64(data[3]) << 32 |
               UInt64(data[4]) << 24 | UInt64(data[5]) << 16 |
               UInt64(data[6]) << 8  | UInt64(data[7])
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
        return UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
    }
}

// MARK: - Data extensions for parsing (safe, no alignment required)

extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset >= 0 && offset + 1 < self.count else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
    
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 3 < self.count else { return 0 }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 |
               UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
    
    func readUInt64BE(at offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 7 < self.count else { return 0 }
        return UInt64(self[offset]) << 56 | UInt64(self[offset + 1]) << 48 |
               UInt64(self[offset + 2]) << 40 | UInt64(self[offset + 3]) << 32 |
               UInt64(self[offset + 4]) << 24 | UInt64(self[offset + 5]) << 16 |
               UInt64(self[offset + 6]) << 8  | UInt64(self[offset + 7])
    }
}
