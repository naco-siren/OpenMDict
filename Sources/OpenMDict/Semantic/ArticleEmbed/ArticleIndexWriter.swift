//
//  ArticleIndexWriter.swift
//  OpenMDict  (M15 Phase 3.2; streaming-write redesign in Phase 3.5)
//
//  One-shot writer that produces an article-embedding sidecar from a
//  (MDictReader, ArticleEncoder) pair. Used by:
//
//    - the CLI `openmdict articleindex build` subcommand — offline
//      pre-indexing for dogfood corpora
//    - the iOS app's ArticleIndexDispatcher — on-device incremental
//      indexing (foreground GPU + background CPU via BGProcessingTask)
//
//  Strategy: streaming append to a single FileHandle. Walk the records in
//  MDictReader.allKeys order; for each real article, encode + append one
//  row (key index + FP16 vector) directly to the file. `@@@LINK=` aliases
//  and missing records are walked past without a row (format version 2,
//  see ArticleIndexFormat.swift). **Peak RAM = one row's worth of FP16
//  (~768 B for MiniLM-L6's 384-dim)** plus encoder/model overhead.
//
//  This is load-bearing for the BGProcessingTask path. The previous
//  "build the whole pool in memory then atomic-write" design blew the
//  ~50–100 MB per-task background memory budget after roughly 55k
//  articles of WordNet (jetsam'd the app, see the original `Peak RAM`
//  comment that confessed `~118 MB` peak). Streaming reduces peak by
//  five orders of magnitude.
//
//  Resumability lives in the on-disk format. The header's `row_count`
//  (rows committed) and `key_count` (keys walked, the resume point) ARE
//  the truth:
//
//    Body-append             (file grows, header counts UNCHANGED)
//        ↓
//    Periodic checkpoint     (truncate to exact size + in-place update
//                             of row_count, then key_count + fsync)
//        ↓
//    Body-append             ... and so on
//
//  Crash windows:
//    - between an `append` and the next checkpoint, the file may have
//      trailing partial-row bytes that the header doesn't account for.
//      The reader tolerates that — its size check is `>= expected` and
//      queries only scan the first `row_count` rows. The writer
//      overwrites trailing on the next resume by seeking to
//      `headerSize + row_count × rowStride` (the canonical write head).
//    - between the row_count and key_count updates of a checkpoint,
//      key_count lags the rows. Resume continues after the larger of
//      key_count and the last row's key index, so no record gets a
//      second row.
//
//  No atomic file swap on each checkpoint — that would require holding
//  a full second copy. Streaming trades atomicity for memory; each
//  in-place header update is still atomic at the 4-byte word level
//  (POSIX), so the file never advertises more rows than it has.
//

import Foundation
import CryptoKit

/// Progress callback fired periodically during sidecar build. Reports
/// `(done, total, elapsed)`: MDX keys walked (articles and aliases
/// alike), the dictionary's key count (or the `limit`), and seconds.
/// Caller uses this to drive a progress UI or just print to stderr.
public typealias ArticleIndexProgress = @Sendable (_ done: Int, _ total: Int, _ elapsedSec: Double) -> Void

public enum ArticleIndexWriterError: Error, CustomStringConvertible {
    case readerHasNoSHA256          // MDictReader couldn't compute headerSHA256
    case encodeFailed(article: Int, key: String, underlying: Error)
    case writeFailed(URL, Error)
    case modelHashFailed

    public var description: String {
        switch self {
        case .readerHasNoSHA256:
            return "MDictReader couldn't compute MDX header SHA256 — encrypted MDX?"
        case .encodeFailed(let i, let key, let err):
            return "Encode failed at article \(i) ('\(key)'): \(err)"
        case .writeFailed(let url, let err):
            return "Failed to write \(url.path): \(err)"
        case .modelHashFailed:
            return "Could not compute SHA256 of the CoreML model file"
        }
    }
}

/// Outcome of a `build()` call.
public enum ArticleIndexBuildOutcome: Sendable {
    /// Every key was walked; the sidecar at `outputURL` is complete (its
    /// `key_count` equals the dictionary's key count, modulo any
    /// `limit`). `header` is the final header.
    case completed(ArticleIndexHeader)

    /// `isCancelled` fired mid-build. A valid partial sidecar
    /// (`key_count == indexedThrough`) was flushed to `outputURL`;
    /// re-invoking `build()` resumes from there. `indexedThrough` counts
    /// keys, like the progress callback.
    case interrupted(header: ArticleIndexHeader, indexedThrough: Int)
}

/// What `ArticleIndexWriter` needs from a text encoder. `ArticleEncoder`
/// (Core ML) is the production conformer; tests substitute a
/// deterministic one.
public protocol ArticleIndexEncoding {
    /// Output vector length, or 0 until the first `encode`.
    var dimension: Int { get }
    /// Tokenizer max length, recorded in the sidecar header.
    var tokenizerMaxLength: Int { get }
    /// L2-normalized embedding of `text`.
    func encode(_ text: String) throws -> [Float]
}

/// Resumable, checkpointing, cancellable sidecar writer. Construct +
/// call `build()`. Safe to call repeatedly on the same `outputURL` —
/// each call resumes from (or no-ops on) the existing partial.
public struct ArticleIndexWriter {

    /// CoreML model file path — used to compute model_sha256 for the
    /// sidecar header. Pass the .mlpackage directory; we hash the
    /// inner model.mlmodel + weights for invalidation.
    public let modelURL: URL

    /// Output .semantic.idx path. Parent directory must exist (the
    /// writer creates it if missing).
    public let outputURL: URL

    /// Optional progress callback. Fires roughly once a second + at
    /// start + end.
    public let progress: ArticleIndexProgress?

    /// Optional cap on the number of keys to walk (the first N of
    /// `allKeys`). nil = the whole dictionary. Used by the CLI's
    /// `--limit N` flag for fast iteration on big MDXs.
    public let limit: Int?

    public init(modelURL: URL, outputURL: URL, limit: Int? = nil,
         progress: ArticleIndexProgress? = nil) {
        self.modelURL = modelURL
        self.outputURL = outputURL
        self.limit = limit
        self.progress = progress
    }

    /// Build the sidecar, resuming from any valid partial already at
    /// `outputURL`. `reader` and `encoder` must be from the same model
    /// configuration (the encoder's vocab + max_len determine the
    /// embedding output; the header records both).
    ///
    /// **Resumability** + **checkpointing**: see the file header. A
    /// version-1 (dense) file at `outputURL` is not resumed; the build
    /// starts over in the current format.
    ///
    /// **Cancellation**: `isCancelled` is polled once per key; when it
    /// flips true the writer flushes (truncate + update header + fsync)
    /// and returns `.interrupted(indexedThrough:)`.
    ///
    /// - Parameters:
    ///   - checkpointEvery: keys between checkpoints (default 2000).
    ///     A larger value reduces fsync frequency but widens the
    ///     crash-loss window. The final key always triggers a flush.
    ///   - isCancelled: cooperative cancellation probe, polled per
    ///     key. `@Sendable` so the writer can run in a detached task.
    public func build<Encoder: ArticleIndexEncoding>(
        reader: MDictReader,
        encoder: Encoder,
        checkpointEvery: Int = 2000,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> ArticleIndexBuildOutcome {
        // 1. Compute the two hashes that gate sidecar validity.
        guard let mdxSHA = reader.metadata.headerSHA256,
              let mdxSHABytes = Self.hexToData(mdxSHA),
              mdxSHABytes.count == 32
        else {
            throw ArticleIndexWriterError.readerHasNoSHA256
        }
        let modelSHA = try Self.computeModelSHA256(modelURL: modelURL)

        let allKeys = reader.allKeys
        let keyTotal = limit.map { max(0, min($0, allKeys.count)) } ?? allKeys.count

        // 2. Resume detection. If a valid partial for THIS (model, MDX)
        // already sits at outputURL, pick up where it left off; else
        // start fresh by writing an initial header (no rows, no keys).
        //
        // Learn the output dimension up front: aliases are walked past
        // without an encode (see the loop), so key 0 may not be an article.
        if encoder.dimension == 0 { _ = try? encoder.encode(" ") }
        let fallbackDim = encoder.dimension > 0 ? encoder.dimension : 384
        var rowCount: Int
        var keyCursor: Int
        var dim: Int
        let createdAt: UInt64

        if let resumed = Self.loadResumableState(
            outputURL: outputURL, modelSHA: modelSHA,
            mdxSHA: mdxSHABytes, maxKeyCount: keyTotal
        ) {
            rowCount = resumed.rowCount
            keyCursor = resumed.keyCount
            dim = resumed.dim
            createdAt = resumed.createdAt
        } else {
            rowCount = 0
            keyCursor = 0
            dim = fallbackDim
            createdAt = UInt64(Date().timeIntervalSince1970)
            try Self.initializeNewFile(
                at: outputURL,
                modelSHA: modelSHA, mdxSHA: mdxSHABytes,
                embeddingDim: UInt32(dim),
                tokenizerMaxLen: UInt32(encoder.tokenizerMaxLength),
                createdAt: createdAt
            )
        }

        // Header factory — `createdAt` is preserved across resumes so the
        // final file's timestamp reflects when indexing first began.
        func makeHeader(rows: Int, keys: Int) -> ArticleIndexHeader {
            ArticleIndexHeader(
                modelSHA256: modelSHA,
                mdxHeaderSHA256: mdxSHABytes,
                embeddingDim: UInt32(dim),
                rowCount: UInt32(rows),
                keyCount: UInt32(keys),
                tokenizerMaxLen: UInt32(encoder.tokenizerMaxLength),
                createdAt: createdAt
            )
        }

        // 3. Open the file for incremental append. Seek to the canonical
        // write head (after the last committed row). A file that is
        // already complete runs no iterations and is only re-flushed.
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: outputURL)
        } catch {
            throw ArticleIndexWriterError.writeFailed(outputURL, error)
        }
        defer { try? handle.close() }
        var stride = Self.rowStride(dim: dim)
        try handle.seek(toOffset: UInt64(ArticleIndexFormat.headerSize + rowCount * stride))

        let buildStart = Date()
        progress?(keyCursor, keyTotal, 0)
        var lastReport = buildStart
        var sinceCheckpoint = 0

        while keyCursor < keyTotal {
            let i = keyCursor
            // Cooperative cancellation: flush a valid partial + bail.
            if isCancelled?() == true {
                try Self.finalizeFile(handle: handle, rowCount: rowCount, keyCount: i, rowStride: stride)
                progress?(i, keyTotal, Date().timeIntervalSince(buildStart))
                return .interrupted(header: makeHeader(rows: rowCount, keys: i), indexedThrough: i)
            }

            // Wrap the heavy ObjC-bridged work (reader[i] → NSString-
            // backed body text; stripHTML's four `replacingOccurrences`
            // each round-trip through NSString; encoder.encode's
            // MLMultiArray scratches) so its autoreleased temporaries
            // drain every iteration. A detached Task on a long
            // synchronous loop does NOT drain its parent autorelease
            // pool until it returns — without this pool, WordNet on
            // iPhone 11 leaked ~15 KB/article, peaked at 1.9 GB before
            // the build finished, then snapped back to ~70 MB on
            // return (the textbook autorelease-accumulation signature).
            let writtenDim: Int? = try autoreleasepool { () throws -> Int? in
                // A row embeds the record stored at index i: `reader[i]`
                // does not follow redirects and keeps homograph records
                // (equal keys) apart. A `@@@LINK=` alias would only
                // re-embed its target, so alias-heavy dictionaries (a
                // Bible keeps ~60 verse-reference aliases per chapter)
                // would multiply the encode time and fill query results
                // with copies of one article. Aliases and missing records
                // get no row; the key index stored in each row keeps the
                // mapping to `allKeys`.
                guard let entry = reader[i], !Self.isRedirect(entry.article.html) else {
                    return nil
                }
                let plain = Self.stripHTML(entry.article.html)
                let vec: [Float]
                do {
                    vec = try encoder.encode(plain)
                } catch {
                    throw ArticleIndexWriterError.encodeFailed(article: i, key: allKeys[i], underlying: error)
                }
                try handle.write(contentsOf: Self.encodeRow(keyIndex: i, vector: vec))
                return vec.count
            }

            if let writtenDim {
                // Dim detection: patch the placeholder header on the first
                // row if the encoder's actual dim differs from the guess.
                // The row just written is already sized for `writtenDim`;
                // the header poke moves the file position, so seek back to
                // the write head after it.
                if rowCount == 0, writtenDim != dim {
                    dim = writtenDim
                    stride = Self.rowStride(dim: dim)
                    try Self.updateHeaderField(handle: handle,
                                               offset: ArticleIndexFormat.embeddingDimOffset,
                                               value: UInt32(dim))
                    try handle.seek(toOffset: UInt64(ArticleIndexFormat.headerSize + stride))
                }
                precondition(writtenDim == dim,
                             "Encoder returned variable-dim output (\(writtenDim) vs \(dim))")
                rowCount += 1
            }
            keyCursor = i + 1
            sinceCheckpoint += 1

            // Periodic checkpoint: truncate to exact size + update the
            // header counts in place + fsync. After the header poke,
            // re-seek to the write head for the next batch.
            if sinceCheckpoint >= checkpointEvery {
                try Self.finalizeFile(handle: handle, rowCount: rowCount, keyCount: keyCursor, rowStride: stride)
                sinceCheckpoint = 0
                try handle.seek(toOffset: UInt64(ArticleIndexFormat.headerSize + rowCount * stride))
            }

            // Periodic progress sample.
            let now = Date()
            if now.timeIntervalSince(lastReport) > 1.0 || keyCursor == keyTotal {
                progress?(keyCursor, keyTotal, now.timeIntervalSince(buildStart))
                lastReport = now
            }
        }

        // Final flush — complete sidecar (key_count == keyTotal).
        try Self.finalizeFile(handle: handle, rowCount: rowCount, keyCount: keyTotal, rowStride: stride)
        return .completed(makeHeader(rows: rowCount, keys: keyTotal))
    }

    // MARK: - File initialization + checkpoint primitives

    /// Bytes per current-version row for `dim`-dimensional vectors.
    static func rowStride(dim: Int) -> Int {
        ArticleIndexFormat.rowKeyIndexSize + dim * 2
    }

    /// One current-version row: little-endian u32 key index, then the
    /// vector as Float16.
    static func encodeRow(keyIndex: Int, vector: [Float]) -> Data {
        var row = Data(count: rowStride(dim: vector.count))
        row.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(keyIndex).littleEndian, toByteOffset: 0, as: UInt32.self)
            for (d, value) in vector.enumerated() {
                raw.storeBytes(of: float16Bits(from: value).littleEndian,
                               toByteOffset: ArticleIndexFormat.rowKeyIndexSize + d * 2,
                               as: UInt16.self)
            }
        }
        return row
    }

    /// Create a new sidecar with a placeholder header (no rows, no keys).
    private static func initializeNewFile(
        at outputURL: URL,
        modelSHA: Data, mdxSHA: Data,
        embeddingDim: UInt32, tokenizerMaxLen: UInt32, createdAt: UInt64
    ) throws {
        let parent = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let initial = ArticleIndexHeader(
            modelSHA256: modelSHA, mdxHeaderSHA256: mdxSHA,
            embeddingDim: embeddingDim, rowCount: 0, keyCount: 0,
            tokenizerMaxLen: tokenizerMaxLen, createdAt: createdAt
        )
        do {
            try initial.serialize().write(to: outputURL)
        } catch {
            throw ArticleIndexWriterError.writeFailed(outputURL, error)
        }
    }

    /// Commit `rowCount` rows covering `keyCount` keys: truncate the file
    /// to the exact expected size (discarding any trailing partial-row
    /// bytes), update the header's row_count and then key_count fields in
    /// place, fsync. The file is in a consistent state when this returns.
    private static func finalizeFile(handle: FileHandle, rowCount: Int, keyCount: Int, rowStride: Int) throws {
        let expectedSize = UInt64(ArticleIndexFormat.headerSize + rowCount * rowStride)
        try handle.truncate(atOffset: expectedSize)
        // row_count first: if the process dies before key_count is
        // written, resume finds the newer rows through their key indices.
        try Self.updateHeaderField(handle: handle, offset: ArticleIndexFormat.rowCountOffset,
                                   value: UInt32(rowCount))
        try Self.updateHeaderField(handle: handle, offset: ArticleIndexFormat.keyCountOffset,
                                   value: UInt32(keyCount))
        try handle.synchronize()
    }

    /// In-place update of a 4-byte little-endian u32 header field
    /// (embedding_dim, row_count, key_count). 4-byte aligned writes are
    /// atomic on every POSIX filesystem we ship to, so the file never
    /// observes a torn field. Leaves the file position after the field.
    private static func updateHeaderField(handle: FileHandle, offset: UInt64, value: UInt32) throws {
        try handle.seek(toOffset: offset)
        var le = value.littleEndian
        try withUnsafeBytes(of: &le) { ptr in
            try handle.write(contentsOf: Data(bytes: ptr.baseAddress!, count: ptr.count))
        }
    }

    // MARK: - Resume

    private struct ResumableState {
        let rowCount: Int
        let keyCount: Int
        let dim: Int
        let createdAt: UInt64
    }

    /// If `outputURL` holds a sidecar valid for the CURRENT build
    /// (matching model + MDX hashes + current format version + a file
    /// size at least the expected committed size, with some progress and
    /// `key_count <= maxKeyCount`), return where to continue so the build
    /// can resume by seeking to the write head and appending.
    ///
    /// File size > expected (trailing partial bytes from a crash between
    /// body-append and the next checkpoint) is tolerated — the writer
    /// overwrites them on resume.
    private static func loadResumableState(
        outputURL: URL, modelSHA: Data, mdxSHA: Data, maxKeyCount: Int
    ) -> ResumableState? {
        guard FileManager.default.fileExists(atPath: outputURL.path),
              let handle = try? FileHandle(forReadingFrom: outputURL)
        else { return nil }
        defer { try? handle.close() }
        guard let headerData = try? handle.read(upToCount: ArticleIndexFormat.headerSize),
              let header = ArticleIndexHeader.parse(headerData),
              header.formatVersion == ArticleIndexFormat.currentVersion,
              header.modelSHA256 == modelSHA,
              header.mdxHeaderSHA256 == mdxSHA,
              header.embeddingDim > 0,
              let fileSize = try? handle.seekToEnd()
        else { return nil }

        let rows = Int(header.rowCount)
        var keys = Int(header.keyCount)
        guard fileSize >= UInt64(header.expectedFileSize),
              rows > 0 || keys > 0, keys <= maxKeyCount
        else { return nil }

        if rows > 0 {
            // Rows hold ascending key indices, so the last one bounds how
            // far the committed rows reach — past key_count when a
            // checkpoint stopped between its two header writes.
            let lastRowOffset = header.headerSize + (rows - 1) * header.rowStride
            guard (try? handle.seek(toOffset: UInt64(lastRowOffset))) != nil,
                  let raw = try? handle.read(upToCount: ArticleIndexFormat.rowKeyIndexSize),
                  raw.count == ArticleIndexFormat.rowKeyIndexSize
            else { return nil }
            let lastKey = Int(UInt32(littleEndian: raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard lastKey < maxKeyCount, rows <= lastKey + 1 else { return nil }
            keys = max(keys, lastKey + 1)
        }

        return ResumableState(
            rowCount: rows, keyCount: keys,
            dim: Int(header.embeddingDim), createdAt: header.createdAt
        )
    }

    // MARK: - Helpers

    /// True for an MDX alias record (`@@@LINK=target`, the form
    /// `MDXParser` follows on lookup). Looks only at the first bytes.
    static func isRedirect(_ record: String) -> Bool {
        record.drop(while: { $0.isWhitespace }).prefix(8).uppercased() == "@@@LINK="
    }

    /// SHA256 of the model's serialized graph for sidecar invalidation.
    /// `.mlpackage` is a directory, so we hash the inner protobuf at
    /// `Data/com.apple.CoreML/model.mlmodel`; for `.mlmodelc` we hash
    /// `model.mil`. Weight files are large + content-identical across
    /// re-conversions of the same source, so this digest catches the
    /// architecture changes that matter.
    private static func computeModelSHA256(modelURL: URL) throws -> Data {
        let candidates = [
            modelURL.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"),
            modelURL.appendingPathComponent("model.mil"),  // .mlmodelc form
            modelURL,                                       // direct .mlmodel file
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c.path),
               let data = try? Data(contentsOf: c) {
                let digest = SHA256.hash(data: data)
                return Data(digest)
            }
        }
        throw ArticleIndexWriterError.modelHashFailed
    }

    /// Hex string → 32-byte Data. Returns nil if input isn't valid hex.
    private static func hexToData(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex)
                ?? hex.endIndex
            let byte = UInt8(hex[idx..<next], radix: 16)
            guard let byte else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    /// HTML → plaintext (strip tags, decode common entities, collapse
    /// whitespace). Phase 3.x could replace with a more thorough
    /// WebView-equivalent extractor if needed.
    public static func stripHTML(_ html: String) -> String {
        let scriptStripped = html.replacingOccurrences(
            of: "<(script|style)[^>]*>.*?</\\1>", with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let tagStripped = scriptStripped.replacingOccurrences(
            of: "<[^>]+>", with: " ",
            options: .regularExpression
        )
        let entityMap: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&copy;": "©",
        ]
        var out = tagStripped
        for (entity, replacement) in entityMap {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ArticleEncoder additions for the writer

extension ArticleEncoder: ArticleIndexEncoding {
    /// Public read of the tokenizer's max_length. The writer records
    /// this in the sidecar header for diagnostics.
    public var tokenizerMaxLength: Int {
        // The tokenizer is private; we know we initialized it with
        // ArticleTokenizer's default 128 unless an override was passed.
        // Phase 3.x doesn't plumb the override through, so it's always 128.
        128
    }
}
