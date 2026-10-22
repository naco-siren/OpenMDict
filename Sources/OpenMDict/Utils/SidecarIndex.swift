import Foundation

// MARK: - Public Cache Config

// MARK: - Sidecar Write Mode

/// How the parser should handle sidecar *write* work when a slow-path parse
/// completes. Reads (fast-path loads) are unaffected by this setting — they
/// are always enabled as long as `MDictSidecarCache.cacheDirectory` is set.
///
/// The modes are mutually exclusive (one enum case, not a bitset) so the
/// semantics of each combination are written out explicitly. To add a new
/// mode in the future, just add a new `case` and a handler in
/// `MDictSidecarCache.enqueueWrite`.
public enum SidecarWriteMode: Sendable {

    /// **Never write.** Only reads work. Use for Action Extensions and any
    /// other sandboxed/short-lived process, so the main app is the single
    /// source of truth for sidecar generation. `enqueueWrite` becomes a
    /// no-op; `flushPendingWrites` has nothing to drain.
    case disabled

    /// **Batched — optimised for user-perceived loading delay.** Writes are
    /// recorded in an internal FIFO queue but not dispatched. The host app
    /// is expected to call `flushPendingWrites()` at the end of its initial
    /// bulk dictionary load; until then, all CPU stays on parsing. Any dict
    /// that finishes parsing after the flush has been called will also go
    /// onto the queue and wait for the next flush — so the host app should
    /// usually switch to `.immediate` mode once the bulk phase is done.
    case batched

    /// **Immediate — optimised for throughput.** Each write is dispatched on
    /// `DispatchQueue.global(qos: .utility)` as soon as the parser hands it
    /// over. On multi-core devices this lets write N run in parallel with
    /// parse N+1, at the cost of some CPU contention during heavy bulk
    /// loading. This is the default; it matches the pre-batching behaviour
    /// and is the right choice for CLIs, tests, benchmarks, and the main
    /// app **after** the initial bulk load.
    case immediate
}

// MARK: - Sidecar Cache

/// Global configuration for the persistent sidecar index cache.
///
/// Set `cacheDirectory` once at host-process startup to enable the sidecar
/// fast-path. When `nil` (the default) the parsers always go through the
/// slow path and never touch sidecar files in either direction.
///
/// The directory is created lazily on first write — callers do not need to
/// pre-create it, though they usually do so during their own bootstrap for
/// cleaner permission-error handling.
///
/// # Concurrency
///
/// `cacheDirectory` and `writeMode` are declared `nonisolated(unsafe)`
/// because the intended usage pattern is "set once at process launch, then
/// read from any thread". Callers must not mutate them from multiple threads
/// concurrently. The internal pending-write queue is protected by its own
/// `NSLock`.
public enum MDictSidecarCache {

    /// Directory where sidecar index files are stored. `nil` disables the
    /// cache entirely — both reads and writes become no-ops.
    ///
    /// Recommended path: `AppGroup/Library/Caches/MDXIndex/` on iOS,
    /// `~/Library/Caches/openmdict/MDXIndex/` on macOS CLI.
    public nonisolated(unsafe) static var cacheDirectory: URL?

    /// How the parser should handle sidecar writes. See `SidecarWriteMode`
    /// for the full contract of each case. Default is `.immediate` — the
    /// behaviour that matches the CLI, benchmarks, unit tests, and any host
    /// that does not care about delaying writes.
    public nonisolated(unsafe) static var writeMode: SidecarWriteMode = .immediate

    /// Construct the sidecar URL for a given header SHA256, or `nil` if
    /// the cache is disabled.
    public static func sidecarURL(forHeaderSHA256 sha256: String) -> URL? {
        guard let dir = cacheDirectory else { return nil }
        return dir.appendingPathComponent("\(sha256).idx", isDirectory: false)
    }

    // MARK: - Pending write queue (internal)

    private static let pendingLock = NSLock()
    private nonisolated(unsafe) static var pendingWrites: [@Sendable () -> Void] = []

    /// Enqueue a sidecar write task, honouring `writeMode`.
    /// Called by `MDXParser` and `MDDParser` after a successful slow-path parse.
    internal static func enqueueWrite(_ task: @escaping @Sendable () -> Void) {
        switch writeMode {
        case .disabled:
            return
        case .batched:
            pendingLock.lock()
            pendingWrites.append(task)
            pendingLock.unlock()
        case .immediate:
            DispatchQueue.global(qos: .utility).async(execute: task)
        }
    }

    /// Drain the pending-write queue by dispatching every task to the global
    /// utility queue. Safe to call multiple times and safe to call in any
    /// `writeMode` — if the queue is empty it is a no-op.
    ///
    /// The main app should call this once at the end of its initial bulk
    /// dictionary load, and usually also switch `writeMode` to `.immediate`
    /// at that point so any later single-dict imports write straight away.
    public static func flushPendingWrites() {
        pendingLock.lock()
        let tasks = pendingWrites
        pendingWrites.removeAll(keepingCapacity: false)
        pendingLock.unlock()

        guard !tasks.isEmpty else { return }
        for task in tasks {
            DispatchQueue.global(qos: .utility).async(execute: task)
        }
    }

    /// Current number of queued writes. Useful for diagnostics and tests.
    public static var pendingWriteCount: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingWrites.count
    }
}

// MARK: - Binary Format

/// Sidecar binary format constants.
///
/// Layout (all integers little-endian, no padding/alignment requirements):
///
/// ```
/// Header (96 bytes, fixed):
///   [0..4]    magic = "MDIX"        UInt32 (ASCII)
///   [4..8]    formatVersion         UInt32
///   [8..16]   sourceFileSize        UInt64    // failure detection #1
///   [16..24]  sourceMTimeNanos      Int64     // failure detection #2
///   [24..56]  sourceHeaderSHA256    32 bytes  // failure detection #3 (raw, not hex)
///   [56..60]  recordBlockCount      UInt32
///   [60..64]  keywordCount          UInt32
///   [64..72]  stringPoolOffset      UInt64
///   [72..80]  stringPoolSize        UInt64
///   [80..84]  encodingTag           UInt32    // see SidecarEncoding
///   [84..88]  flags                 UInt32    // bit0 = caseSensitive
///   [88..96]  reserved
///
/// RecordBlocks (recordBlockCount × 24 bytes):
///   compressedSize   UInt64
///   decompressedSize UInt64
///   fileOffset       UInt64
///
/// KeywordEntries (keywordCount × 28 bytes):
///   stringPoolOffset    UInt64    // byte offset within string pool
///   stringByteLength    UInt32    // UTF-8 byte length
///   recordBlockIndex    UInt32
///   recordOffset        UInt64    // local offset within block
///   recordSize          UInt32
///
/// SortedIndices (keywordCount × 4 bytes):
///   UInt32 array of KeywordEntries indices, sorted by lowercased(keyword)
///
/// StringPool (stringPoolSize bytes):
///   Concatenated UTF-8 keyword bytes (no separator, sliced via stringByteLength)
/// ```
internal enum SidecarFormat {
    /// Magic number, read as little-endian UInt32 from the file.
    /// On disk the four bytes are 'M','D','I','X' (0x4D,0x44,0x49,0x58),
    /// which decode to 0x5849444D when interpreted as LE.
    static let magicLE: UInt32 = 0x5849444D

    /// Bump this when the on-disk format changes incompatibly.
    static let formatVersion: UInt32 = 1

    static let headerSize: Int = 96
    static let recordBlockEntrySize: Int = 24
    static let keywordEntrySize: Int = 28
    static let sortedIndexEntrySize: Int = 4
}

/// Encoding tag stored in the sidecar header. Mirrors MDX/MDD source encoding
/// so the parser can reconstruct the same `String.Encoding` for decoding records.
internal enum SidecarEncoding: UInt32 {
    case utf8 = 0
    case utf16le = 1
    case utf16be = 2
    case gbk = 3
    case big5 = 4

    init(encodingString: String) {
        switch encodingString.uppercased() {
        case "UTF-16", "UTF-16LE": self = .utf16le
        case "UTF-16BE": self = .utf16be
        case "GBK", "GB2312", "GB18030": self = .gbk
        case "BIG5": self = .big5
        default: self = .utf8
        }
    }

    var encodingString: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16le: return "UTF-16LE"
        case .utf16be: return "UTF-16BE"
        case .gbk: return "GBK"
        case .big5: return "BIG5"
        }
    }
}

// MARK: - Loaded Sidecar Payload

/// In-memory representation of a successfully loaded sidecar.
///
/// Owns the raw `Data` (typically mmap-backed) and exposes the parser-friendly
/// reconstruction of `[KeywordEntry]`, `[RecordBlockInfo]`, and the sorted
/// indices used for binary-search prefix lookup.
internal struct SidecarPayload {
    let keywords: [KeywordEntry]
    let recordBlocks: [RecordBlockInfo]
    /// `keywords` indices sorted by `keyword.lowercased()` (locale-independent).
    let sortedIndices: [UInt32]
    let encoding: SidecarEncoding
    let isCaseSensitive: Bool
}

// MARK: - Validation Identity

/// The three-field identity used to validate a sidecar against its source MDX/MDD.
internal struct SidecarSourceIdentity: Equatable {
    let fileSize: UInt64
    let mtimeNanos: Int64
    /// Raw 32-byte SHA256 digest of the MDX header bytes.
    let headerSHA256: Data

    /// Read identity from a file path. Returns `nil` if the file is missing
    /// or `headerSHA256` cannot be computed by the caller.
    static func capture(path: String, headerSHA256Hex: String) -> SidecarSourceIdentity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime: Int64
        if let date = attrs[.modificationDate] as? Date {
            mtime = Int64(date.timeIntervalSince1970 * 1_000_000_000)
        } else {
            mtime = 0
        }
        guard let sha = Data(hexString: headerSHA256Hex), sha.count == 32 else {
            return nil
        }
        return SidecarSourceIdentity(fileSize: size, mtimeNanos: mtime, headerSHA256: sha)
    }
}

// MARK: - Sidecar Loader (read path)

internal enum SidecarLoader {

    /// Attempt to load and validate a sidecar from disk.
    ///
    /// - Returns: `SidecarPayload` on success, or `nil` if the file is missing,
    ///   corrupt, version-mismatched, or fails identity validation. Failures
    ///   are silent — the caller falls back to the slow path.
    static func load(from url: URL, expectedIdentity: SidecarSourceIdentity) -> SidecarPayload? {
        // Use mapped read so the kernel can lazily page in just the bytes we touch.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            return nil
        }
        guard data.count >= SidecarFormat.headerSize else { return nil }

        // Validate magic + version
        let magic = data.readUInt32LE(at: 0)
        guard magic == SidecarFormat.magicLE else { return nil }
        let version = data.readUInt32LE(at: 4)
        guard version == SidecarFormat.formatVersion else { return nil }

        // Validate identity (fileSize + mtime + headerSHA256)
        let fileSize = data.readUInt64LE(at: 8)
        let mtimeNanos = Int64(bitPattern: data.readUInt64LE(at: 16))
        let sha = data.subdata(in: 24..<56)
        guard fileSize == expectedIdentity.fileSize,
              mtimeNanos == expectedIdentity.mtimeNanos,
              sha == expectedIdentity.headerSHA256 else {
            return nil
        }

        // Section sizes
        let recordBlockCount = Int(data.readUInt32LE(at: 56))
        let keywordCount = Int(data.readUInt32LE(at: 60))
        let stringPoolOffset = Int(data.readUInt64LE(at: 64))
        let stringPoolSize = Int(data.readUInt64LE(at: 72))
        let encodingRaw = data.readUInt32LE(at: 80)
        let flags = data.readUInt32LE(at: 84)

        guard let encoding = SidecarEncoding(rawValue: encodingRaw) else { return nil }
        let isCaseSensitive = (flags & 0x1) != 0

        // Compute and validate section offsets
        let recordBlocksOffset = SidecarFormat.headerSize
        let recordBlocksEnd = recordBlocksOffset + recordBlockCount * SidecarFormat.recordBlockEntrySize
        let keywordEntriesOffset = recordBlocksEnd
        let keywordEntriesEnd = keywordEntriesOffset + keywordCount * SidecarFormat.keywordEntrySize
        let sortedIndicesOffset = keywordEntriesEnd
        let sortedIndicesEnd = sortedIndicesOffset + keywordCount * SidecarFormat.sortedIndexEntrySize

        guard sortedIndicesEnd <= stringPoolOffset,
              stringPoolOffset + stringPoolSize <= data.count else {
            return nil
        }

        // Decode all sections in a single withUnsafeBytes block. This avoids
        // the overhead of `Data.subdata(in:)` (which copies on each call) and
        // lets us build Strings directly from pointers via `String(decoding:as:)`.
        // For a 300k-entry dictionary this is the difference between hundreds
        // of milliseconds and a few tens of milliseconds.
        let decoded: ([KeywordEntry], [RecordBlockInfo], [UInt32])? =
        data.withUnsafeBytes { rawBuf -> ([KeywordEntry], [RecordBlockInfo], [UInt32])? in
            guard let basePtr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            // Helper: read LE integer at absolute offset (no bounds check —
            // section offsets are validated above).
            @inline(__always) func u32(_ off: Int) -> UInt32 {
                let p = basePtr + off
                return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
            }
            @inline(__always) func u64(_ off: Int) -> UInt64 {
                let p = basePtr + off
                return UInt64(p[0]) | UInt64(p[1]) << 8 | UInt64(p[2]) << 16 | UInt64(p[3]) << 24
                     | UInt64(p[4]) << 32 | UInt64(p[5]) << 40 | UInt64(p[6]) << 48 | UInt64(p[7]) << 56
            }

            // Decode RecordBlocks
            var recordBlocks: [RecordBlockInfo] = []
            recordBlocks.reserveCapacity(recordBlockCount)
            for i in 0..<recordBlockCount {
                let base = recordBlocksOffset + i * SidecarFormat.recordBlockEntrySize
                recordBlocks.append(RecordBlockInfo(
                    compressedSize: u64(base),
                    decompressedSize: u64(base + 8),
                    fileOffset: u64(base + 16)
                ))
            }

            // Decode KeywordEntries — strings are built directly from
            // pointers into the mmap region.
            var keywords: [KeywordEntry] = []
            keywords.reserveCapacity(keywordCount)
            let stringPoolEnd = stringPoolOffset + stringPoolSize
            for i in 0..<keywordCount {
                let base = keywordEntriesOffset + i * SidecarFormat.keywordEntrySize
                let strOff = Int(u64(base))
                let strLen = Int(u32(base + 8))
                let blockIdx = Int(u32(base + 12))
                let recOff = u64(base + 16)
                let recSize = Int(u32(base + 24))

                let absStrStart = stringPoolOffset + strOff
                let absStrEnd = absStrStart + strLen
                if absStrEnd > stringPoolEnd { return nil }

                let strBuf = UnsafeBufferPointer(start: basePtr + absStrStart, count: strLen)
                let kw = String(decoding: strBuf, as: UTF8.self)
                keywords.append(KeywordEntry(
                    keyword: kw,
                    recordBlockIndex: blockIdx,
                    recordOffset: recOff,
                    recordSize: recSize
                ))
            }

            // Decode SortedIndices
            var sortedIndices: [UInt32] = []
            sortedIndices.reserveCapacity(keywordCount)
            for i in 0..<keywordCount {
                sortedIndices.append(u32(sortedIndicesOffset + i * SidecarFormat.sortedIndexEntrySize))
            }

            return (keywords, recordBlocks, sortedIndices)
        }

        guard let (keywords, recordBlocks, sortedIndices) = decoded else { return nil }

        return SidecarPayload(
            keywords: keywords,
            recordBlocks: recordBlocks,
            sortedIndices: sortedIndices,
            encoding: encoding,
            isCaseSensitive: isCaseSensitive
        )
    }
}

// MARK: - Sidecar Writer (build path)

internal enum SidecarWriter {

    /// Compute the sorted indices for an array of keywords (sorted by lowercased
    /// keyword, breaking ties by original order). This is shared between the
    /// build path (sidecar serialization) and the slow path (in-memory only).
    static func computeSortedIndices(_ keywords: [KeywordEntry]) -> [UInt32] {
        let count = keywords.count
        // Pre-lowercase once to avoid O(n log n) repeated lowercasing during sort.
        var lowered = [String](); lowered.reserveCapacity(count)
        for kw in keywords { lowered.append(kw.keyword.lowercased()) }

        var indices = [UInt32](0..<UInt32(count))
        indices.sort { a, b in
            let la = lowered[Int(a)]
            let lb = lowered[Int(b)]
            if la == lb { return a < b }
            return la < lb
        }
        return indices
    }

    /// Serialize parser results to a sidecar file at `url`. Atomic write
    /// (temp file + rename) so partial failures never leave a corrupt sidecar.
    static func write(
        to url: URL,
        identity: SidecarSourceIdentity,
        keywords: [KeywordEntry],
        recordBlocks: [RecordBlockInfo],
        sortedIndices: [UInt32],
        encoding: String,
        isCaseSensitive: Bool
    ) throws {
        // 1. Build string pool & per-keyword offsets
        var stringPool = Data()
        var stringOffsets: [(offset: UInt64, length: UInt32)] = []
        stringOffsets.reserveCapacity(keywords.count)
        // Reserve a generous initial capacity (10 bytes/keyword average)
        stringPool.reserveCapacity(keywords.count * 12)

        for kw in keywords {
            let bytes = Data(kw.keyword.utf8)
            stringOffsets.append((offset: UInt64(stringPool.count), length: UInt32(bytes.count)))
            stringPool.append(bytes)
        }

        let recordBlockCount = recordBlocks.count
        let keywordCount = keywords.count
        let recordBlocksSize = recordBlockCount * SidecarFormat.recordBlockEntrySize
        let keywordEntriesSize = keywordCount * SidecarFormat.keywordEntrySize
        let sortedIndicesSize = keywordCount * SidecarFormat.sortedIndexEntrySize

        let stringPoolOffset = SidecarFormat.headerSize + recordBlocksSize + keywordEntriesSize + sortedIndicesSize
        let totalSize = stringPoolOffset + stringPool.count

        // 2. Allocate output buffer
        var out = Data(count: totalSize)

        // 3. Write header
        out.writeUInt32LE(SidecarFormat.magicLE, at: 0)
        out.writeUInt32LE(SidecarFormat.formatVersion, at: 4)
        out.writeUInt64LE(identity.fileSize, at: 8)
        out.writeUInt64LE(UInt64(bitPattern: identity.mtimeNanos), at: 16)
        out.replaceSubrange(24..<56, with: identity.headerSHA256)
        out.writeUInt32LE(UInt32(recordBlockCount), at: 56)
        out.writeUInt32LE(UInt32(keywordCount), at: 60)
        out.writeUInt64LE(UInt64(stringPoolOffset), at: 64)
        out.writeUInt64LE(UInt64(stringPool.count), at: 72)
        out.writeUInt32LE(SidecarEncoding(encodingString: encoding).rawValue, at: 80)
        out.writeUInt32LE(isCaseSensitive ? 0x1 : 0x0, at: 84)
        // bytes 88..96 are reserved (zero-initialized)

        // 4. Write RecordBlocks
        var cursor = SidecarFormat.headerSize
        for block in recordBlocks {
            out.writeUInt64LE(block.compressedSize, at: cursor)
            out.writeUInt64LE(block.decompressedSize, at: cursor + 8)
            out.writeUInt64LE(block.fileOffset, at: cursor + 16)
            cursor += SidecarFormat.recordBlockEntrySize
        }

        // 5. Write KeywordEntries
        for (i, kw) in keywords.enumerated() {
            let strInfo = stringOffsets[i]
            out.writeUInt64LE(strInfo.offset, at: cursor)
            out.writeUInt32LE(strInfo.length, at: cursor + 8)
            out.writeUInt32LE(UInt32(kw.recordBlockIndex), at: cursor + 12)
            out.writeUInt64LE(kw.recordOffset, at: cursor + 16)
            out.writeUInt32LE(UInt32(kw.recordSize), at: cursor + 24)
            cursor += SidecarFormat.keywordEntrySize
        }

        // 6. Write SortedIndices
        for idx in sortedIndices {
            out.writeUInt32LE(idx, at: cursor)
            cursor += SidecarFormat.sortedIndexEntrySize
        }

        // 7. Write StringPool
        precondition(cursor == stringPoolOffset, "Sidecar layout drift")
        out.replaceSubrange(stringPoolOffset..<totalSize, with: stringPool)

        // 8. Atomic write — ensure parent dir exists, write to .tmp, rename
        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tmpURL = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.globallyUniqueString)")
        try out.write(to: tmpURL, options: .atomic)
        // Replace destination atomically
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: url)
        }
    }
}

// MARK: - Folded-key index file

/// The folded-key index (`FoldedKeyIndex`) of a dictionary, saved next to
/// its sidecar as `<sha256>.fold` — when a lookup first builds it, or by the
/// host app's background pass (`MDictReader.saveFoldedKeyIndexIfNeeded`) —
/// so later launches and the extensions, which never write, read it instead
/// of building it again. A separate file, so the sidecar format and its fast
/// path are unchanged.
///
/// Layout (little-endian):
///
/// ```
/// Header (64 bytes):
///   [0..4]    magic = "MDFX"
///   [4..8]    formatVersion       UInt32  (bump when the folding changes)
///   [8..16]   sourceFileSize      UInt64  ┐
///   [16..24]  sourceMTimeNanos    Int64   │ same identity as the sidecar
///   [24..56]  sourceHeaderSHA256  32 bytes┘
///   [56..60]  keywordCount        UInt32
///   [60..64]  indexCount          UInt32
/// Indices (indexCount × 4 bytes): FoldedKeyIndex.indices
/// ```
internal enum FoldedIndexFile {
    /// 'M','D','F','X' read as little-endian.
    static let magicLE: UInt32 = 0x5846444D
    static let formatVersion: UInt32 = 1
    static let headerSize = 64

    static func url(forSidecar sidecarURL: URL) -> URL {
        sidecarURL.deletingPathExtension().appendingPathExtension("fold")
    }

    /// The number of indices a file with this header and `fileSize` holds,
    /// or nil if it is from another version or source, or truncated.
    private static func indexCount(header data: Data, fileSize: Int, identity: SidecarSourceIdentity,
                                   keywordCount: Int) -> Int? {
        guard data.count >= headerSize,
              data.readUInt32LE(at: 0) == magicLE,
              data.readUInt32LE(at: 4) == formatVersion,
              data.readUInt64LE(at: 8) == identity.fileSize,
              Int64(bitPattern: data.readUInt64LE(at: 16)) == identity.mtimeNanos,
              data.subdata(in: 24..<56) == identity.headerSHA256,
              Int(data.readUInt32LE(at: 56)) == keywordCount else {
            return nil
        }
        let count = Int(data.readUInt32LE(at: 60))
        return fileSize == headerSize + count * 4 ? count : nil
    }

    /// Whether a saved index for this source is at `url`, checking the
    /// header only.
    static func hasValidCopy(at url: URL, identity: SidecarSourceIdentity, keywordCount: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: headerSize),
              let size = try? handle.seekToEnd() else { return false }
        return indexCount(header: header, fileSize: Int(size), identity: identity, keywordCount: keywordCount) != nil
    }

    /// The saved index, or nil if the file is missing, from another version
    /// or source, or damaged.
    static func load(from url: URL, identity: SidecarSourceIdentity, keywordCount: Int) -> FoldedKeyIndex? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let count = indexCount(header: data, fileSize: data.count, identity: identity,
                                     keywordCount: keywordCount) else {
            return nil
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(count)
        let valid = data.withUnsafeBytes { raw -> Bool in
            for i in 0..<count {
                let value = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: headerSize + i * 4, as: UInt32.self))
                guard Int(value) < keywordCount else { return false }
                indices.append(value)
            }
            return true
        }
        return valid ? FoldedKeyIndex(indices: indices) : nil
    }

    /// Atomic write (temporary file, then rename).
    static func write(_ index: FoldedKeyIndex, to url: URL, identity: SidecarSourceIdentity,
                      keywordCount: Int) throws {
        var out = Data(count: headerSize + index.indices.count * 4)
        out.writeUInt32LE(magicLE, at: 0)
        out.writeUInt32LE(formatVersion, at: 4)
        out.writeUInt64LE(identity.fileSize, at: 8)
        out.writeUInt64LE(UInt64(bitPattern: identity.mtimeNanos), at: 16)
        out.replaceSubrange(24..<56, with: identity.headerSHA256)
        out.writeUInt32LE(UInt32(keywordCount), at: 56)
        out.writeUInt32LE(UInt32(index.indices.count), at: 60)
        for (i, value) in index.indices.enumerated() {
            out.writeUInt32LE(value, at: headerSize + i * 4)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
    }
}

// MARK: - Data little-endian helpers (sidecar uses LE throughout)

extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count, "out of bounds LE read")
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && offset + 8 <= count, "out of bounds LE read")
        return UInt64(self[offset])
            | UInt64(self[offset + 1]) << 8
            | UInt64(self[offset + 2]) << 16
            | UInt64(self[offset + 3]) << 24
            | UInt64(self[offset + 4]) << 32
            | UInt64(self[offset + 5]) << 40
            | UInt64(self[offset + 6]) << 48
            | UInt64(self[offset + 7]) << 56
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset]     = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        self[offset]     = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 4] = UInt8(truncatingIfNeeded: value >> 32)
        self[offset + 5] = UInt8(truncatingIfNeeded: value >> 40)
        self[offset + 6] = UInt8(truncatingIfNeeded: value >> 48)
        self[offset + 7] = UInt8(truncatingIfNeeded: value >> 56)
    }
}

// MARK: - Hex string helper for SHA256 round-trip

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.lowercased()
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
