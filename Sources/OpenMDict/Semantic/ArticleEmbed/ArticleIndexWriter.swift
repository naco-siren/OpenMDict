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
//  Strategy: streaming append to a single FileHandle. Iterate articles
//  in MDictReader.allKeys order; for each, encode + append the FP16
//  vector directly to the file. **Peak RAM = one row's worth of FP16
//  (~768 B for MiniLM-L6's 384-dim)** plus encoder/model overhead.
//
//  This is load-bearing for the BGProcessingTask path. The previous
//  "build the whole pool in memory then atomic-write" design blew the
//  ~50–100 MB per-task background memory budget after roughly 55k
//  articles of WordNet (jetsam'd the app, see the original `Peak RAM`
//  comment that confessed `~118 MB` peak). Streaming reduces peak by
//  five orders of magnitude.
//
//  Resumability lives in the on-disk format. The header's
//  `article_count` field IS the truth: how many rows are committed.
//
//    Body-append             (file grows, header.count UNCHANGED)
//        ↓
//    Periodic checkpoint     (truncate to exact size + in-place update
//                             of article_count at offset 76 + fsync)
//        ↓
//    Body-append             ... and so on
//
//  Crash window: between an `append` and the next checkpoint, the file
//  may have trailing partial-row bytes that the header doesn't account
//  for. The reader tolerates that — its size check is `>= expected`
//  (was `==`) and queries only scan the first `article_count` rows.
//  The writer overwrites trailing on the next resume by seeking to
//  `headerSize + article_count × dim × 2` (the canonical write head).
//
//  No atomic file swap on each checkpoint — that would require holding
//  a full second copy. Streaming trades atomicity for memory; the
//  in-place header update is still atomic at the 4-byte word level
//  (POSIX), so the file is never in an "advertises more rows than it
//  has" state.
//

import Foundation
import CryptoKit

/// Progress callback fired periodically during sidecar build. Reports
/// `(done, total, elapsed)` in articles + seconds. Caller uses this to
/// drive a progress UI or just print to stderr.
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
    /// Every article was encoded; the sidecar at `outputURL` is complete
    /// (its `article_count` equals the dict's article total, modulo any
    /// `limit`). `header` is the final header.
    case completed(ArticleIndexHeader)

    /// `isCancelled` fired mid-build. A valid partial sidecar
    /// (`article_count == indexedThrough`) was flushed to `outputURL`;
    /// re-invoking `build()` resumes from there.
    case interrupted(header: ArticleIndexHeader, indexedThrough: Int)
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

    /// Optional cap on the number of articles to index. nil = index all.
    /// Used by the CLI's `--limit N` flag for fast iteration on big MDXs.
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
    /// **Resumability** + **checkpointing**: see the file header.
    ///
    /// **Cancellation**: `isCancelled` is polled once per article; when
    /// it flips true the writer flushes (truncate + update header +
    /// fsync) and returns `.interrupted(indexedThrough:)`.
    ///
    /// - Parameters:
    ///   - checkpointEvery: articles between checkpoints (default 2000).
    ///     A larger value reduces fsync frequency but widens the
    ///     crash-loss window. The final article always triggers a flush.
    ///   - isCancelled: cooperative cancellation probe, polled per
    ///     article. `@Sendable` so the writer can run in a detached task.
    public func build(
        reader: MDictReader,
        encoder: ArticleEncoder,
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

        let allKeysFull = reader.allKeys
        let allKeys = limit.map { Array(allKeysFull.prefix($0)) } ?? allKeysFull
        let count = allKeys.count

        // 2. Resume detection. If a valid partial for THIS (model, MDX)
        // already sits at outputURL, pick up where it left off; else
        // start fresh by writing an initial header (article_count = 0).
        //
        // Learn the output dimension up front: alias rows are skipped
        // without an encode (see the loop), so row 0 may not be one.
        if encoder.dimension == 0 { _ = try? encoder.encode(" ") }
        let fallbackDim = encoder.dimension > 0 ? encoder.dimension : 384
        var poolPtr: Int
        var detectedDim: Int
        let createdAt: UInt64

        if let resumed = Self.loadResumableState(
            outputURL: outputURL, modelSHA: modelSHA,
            mdxSHA: mdxSHABytes, maxCount: count
        ) {
            poolPtr = resumed.articleCount
            detectedDim = resumed.dim
            createdAt = resumed.createdAt
        } else {
            poolPtr = 0
            detectedDim = fallbackDim
            createdAt = UInt64(Date().timeIntervalSince1970)
            try Self.initializeNewFile(
                at: outputURL,
                modelSHA: modelSHA, mdxSHA: mdxSHABytes,
                embeddingDim: UInt32(detectedDim),
                tokenizerMaxLen: UInt32(encoder.tokenizerMaxLength),
                createdAt: createdAt
            )
        }

        // Header factory — `createdAt` is preserved across resumes so the
        // final file's timestamp reflects when indexing first began.
        func makeHeader(_ articleCount: Int) -> ArticleIndexHeader {
            ArticleIndexHeader(
                modelSHA256: modelSHA,
                mdxHeaderSHA256: mdxSHABytes,
                embeddingDim: UInt32(detectedDim),
                articleCount: UInt32(articleCount),
                tokenizerMaxLen: UInt32(encoder.tokenizerMaxLength),
                createdAt: createdAt
            )
        }

        // Already complete (re-invoked on a finished sidecar, or a
        // partial that exactly reaches `count`/limit). Idempotent no-op.
        if poolPtr >= count {
            return .completed(makeHeader(count))
        }

        // 3. Open the file for incremental append. Seek to the canonical
        // write head (after the last committed row).
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: outputURL)
        } catch {
            throw ArticleIndexWriterError.writeFailed(outputURL, error)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(ArticleIndexFormat.headerSize + poolPtr * detectedDim * 2))

        let buildStart = Date()
        progress?(poolPtr, count, 0)
        var lastReport = buildStart
        var sinceCheckpoint = 0

        for i in poolPtr..<count {
            // Cooperative cancellation: flush a valid partial + bail.
            if isCancelled?() == true {
                try Self.finalizeFile(handle: handle, articleCount: poolPtr, dim: detectedDim)
                progress?(poolPtr, count, Date().timeIntervalSince(buildStart))
                return .interrupted(header: makeHeader(poolPtr), indexedThrough: poolPtr)
            }

            // Wrap the heavy ObjC-bridged work (reader.lookup → NSString-
            // backed body text; stripHTML's four `replacingOccurrences`
            // each round-trip through NSString; encoder.encode's
            // MLMultiArray scratches) so its autoreleased temporaries
            // drain every iteration. A detached Task on a long
            // synchronous loop does NOT drain its parent autorelease
            // pool until it returns — without this pool, WordNet on
            // iPhone 11 leaked ~15 KB/article, peaked at 1.9 GB before
            // the build finished, then snapped back to ~70 MB on
            // return (the textbook autorelease-accumulation signature).
            let writeDim: Int = try autoreleasepool { () throws -> Int in
                let key = allKeys[i]
                // Row i embeds the record stored at index i: `reader[i]`
                // does not follow redirects and keeps homograph records
                // (equal keys) apart. A `@@@LINK=` alias would only
                // re-embed its target, so alias-heavy dictionaries (a
                // Bible keeps ~60 verse-reference aliases per chapter)
                // would multiply the encode time and fill query results
                // with copies of one article. Aliases and missing records
                // get an all-zero row instead: it keeps the positional
                // alignment with `allKeys`, `ArticleIndexReader.query`
                // never returns it, and it is skipped over, not written.
                guard let entry = reader[i], !Self.isRedirect(entry.article.html) else {
                    try handle.seek(toOffset: UInt64(ArticleIndexFormat.headerSize + (i + 1) * detectedDim * 2))
                    return detectedDim
                }
                let plain = Self.stripHTML(entry.article.html)
                let vec: [Float]
                do {
                    vec = try encoder.encode(plain)
                } catch {
                    throw ArticleIndexWriterError.encodeFailed(article: i, key: key, underlying: error)
                }
                let actualDim = vec.count
                var bits = [UInt16](repeating: 0, count: actualDim)
                for d in 0..<actualDim { bits[d] = float16Bits(from: vec[d]) }
                try bits.withUnsafeBufferPointer { buf in
                    try handle.write(contentsOf: Data(buffer: buf))
                }
                return actualDim
            }

            // Dim detection: patch the placeholder header on the first
            // real encode of a fresh build if the encoder's actual dim
            // differs from the writer's guess. The row we just wrote is
            // already sized for `writeDim`, so the write head is at the
            // right offset for the next row.
            if poolPtr == 0, writeDim != detectedDim {
                detectedDim = writeDim
                try Self.updateHeaderEmbeddingDim(handle: handle, dim: UInt32(detectedDim))
            }
            precondition(writeDim == detectedDim,
                         "Encoder returned variable-dim output (\(writeDim) vs \(detectedDim))")

            poolPtr += 1
            sinceCheckpoint += 1

            // Periodic checkpoint: truncate to exact size + update header
            // article_count in place + fsync. After the header poke,
            // re-seek to the new write head for the next batch.
            if sinceCheckpoint >= checkpointEvery {
                try Self.finalizeFile(handle: handle, articleCount: poolPtr, dim: detectedDim)
                sinceCheckpoint = 0
                try handle.seek(toOffset: UInt64(ArticleIndexFormat.headerSize + poolPtr * detectedDim * 2))
            }

            // Periodic progress sample.
            let now = Date()
            if now.timeIntervalSince(lastReport) > 1.0 || i == count - 1 {
                progress?(poolPtr, count, now.timeIntervalSince(buildStart))
                lastReport = now
            }
        }

        // Final flush — complete sidecar (article_count == count).
        try Self.finalizeFile(handle: handle, articleCount: poolPtr, dim: detectedDim)
        return .completed(makeHeader(poolPtr))
    }

    // MARK: - File initialization + checkpoint primitives

    /// Create a new sidecar with a placeholder header (article_count = 0).
    private static func initializeNewFile(
        at outputURL: URL,
        modelSHA: Data, mdxSHA: Data,
        embeddingDim: UInt32, tokenizerMaxLen: UInt32, createdAt: UInt64
    ) throws {
        let parent = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let initial = ArticleIndexHeader(
            modelSHA256: modelSHA, mdxHeaderSHA256: mdxSHA,
            embeddingDim: embeddingDim, articleCount: 0,
            tokenizerMaxLen: tokenizerMaxLen, createdAt: createdAt
        )
        do {
            try initial.serialize().write(to: outputURL)
        } catch {
            throw ArticleIndexWriterError.writeFailed(outputURL, error)
        }
    }

    /// Commit `articleCount` rows to disk: truncate the file to the
    /// exact expected size (discarding any trailing partial-row bytes),
    /// update the header's article_count field in place, fsync. The
    /// file is in a consistent state when this returns.
    private static func finalizeFile(handle: FileHandle, articleCount: Int, dim: Int) throws {
        let expectedSize = UInt64(ArticleIndexFormat.headerSize + articleCount * dim * 2)
        try handle.truncate(atOffset: expectedSize)
        try Self.updateHeaderArticleCount(handle: handle, count: UInt32(articleCount))
        try handle.synchronize()
    }

    /// In-place update of the header's `article_count` field
    /// (offset 76, 4-byte little-endian u32). 4-byte aligned writes are
    /// atomic on every POSIX filesystem we ship to, so the file never
    /// observes a torn `article_count`.
    private static func updateHeaderArticleCount(handle: FileHandle, count: UInt32) throws {
        try handle.seek(toOffset: 76)
        var le = count.littleEndian
        try withUnsafeBytes(of: &le) { ptr in
            try handle.write(contentsOf: Data(bytes: ptr.baseAddress!, count: ptr.count))
        }
    }

    /// In-place update of the header's `embedding_dim` field
    /// (offset 72, 4-byte little-endian u32). Only used when the first
    /// real encode's vector length differs from the placeholder dim the
    /// writer guessed at file-init time.
    private static func updateHeaderEmbeddingDim(handle: FileHandle, dim: UInt32) throws {
        try handle.seek(toOffset: 72)
        var le = dim.littleEndian
        try withUnsafeBytes(of: &le) { ptr in
            try handle.write(contentsOf: Data(bytes: ptr.baseAddress!, count: ptr.count))
        }
    }

    // MARK: - Resume

    private struct ResumableState {
        let articleCount: Int
        let dim: Int
        let createdAt: UInt64
    }

    /// If `outputURL` holds a sidecar valid for the CURRENT build
    /// (matching model + MDX hashes + current format version + a file
    /// size at least the expected committed size, with
    /// `0 < article_count <= maxCount`), return its metadata so the
    /// build can resume by seeking to the write head and appending.
    ///
    /// File size > expected (trailing partial bytes from a crash between
    /// body-append and the next checkpoint) is tolerated — the writer
    /// overwrites them on resume.
    private static func loadResumableState(
        outputURL: URL, modelSHA: Data, mdxSHA: Data, maxCount: Int
    ) -> ResumableState? {
        guard FileManager.default.fileExists(atPath: outputURL.path),
              let handle = try? FileHandle(forReadingFrom: outputURL),
              let headerData = try? handle.read(upToCount: ArticleIndexFormat.headerSize),
              headerData.count == ArticleIndexFormat.headerSize,
              let header = ArticleIndexHeader.parse(headerData),
              header.formatVersion == ArticleIndexFormat.currentVersion,
              header.modelSHA256 == modelSHA,
              header.mdxHeaderSHA256 == mdxSHA,
              header.embeddingDim > 0
        else { return nil }
        try? handle.close()

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let dim = Int(header.embeddingDim)
        let existingCount = Int(header.articleCount)
        let expectedSize = ArticleIndexFormat.headerSize + existingCount * dim * 2
        guard fileSize >= expectedSize,
              existingCount > 0, existingCount <= maxCount
        else { return nil }

        return ResumableState(
            articleCount: existingCount, dim: dim, createdAt: header.createdAt
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

extension ArticleEncoder {
    /// Public read of the tokenizer's max_length. The writer records
    /// this in the sidecar header for diagnostics.
    var tokenizerMaxLength: Int {
        // The tokenizer is private; we know we initialized it with
        // ArticleTokenizer's default 128 unless an override was passed.
        // Phase 3.x doesn't plumb the override through, so it's always 128.
        128
    }
}
