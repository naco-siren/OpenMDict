//
//  ArticleIndexWriter.swift
//  OpenMDictCLI  (M15 Phase 3.2)
//
//  One-shot writer that produces an article-embedding sidecar from a
//  (MDictReader, ArticleEncoder) pair. Used by:
//
//    - the CLI `openmdict articleindex build` subcommand (this file's
//      caller) — offline pre-indexing for dogfood corpora
//    - the iOS app's ArticleIndexCoordinator (Phase 3.3+, to be ported)
//      — on-device incremental indexing
//
//  Strategy: in-memory build. Iterate articles in MDictReader.allKeys
//  order, encode each one's body text, append Float16 vectors to a
//  growing buffer, then write the whole file atomically with a header
//  prepended. Peak RAM = articleCount × dim × 2 bytes (~118 MB for
//  WordNet's 154k articles × 384 dim) + scratch for the encoder.
//
//  Phase 3.2 deliberately does NOT support resumable / incremental
//  indexing — that lands in Phase 3.3 via the Coordinator. On-device
//  Phase 3.3 will either:
//    (a) checkpoint per N articles to a partial file, OR
//    (b) keep this in-memory writer + the Coordinator schedules
//        smaller chunks (e.g. one dict per BGProcessingTask cycle)
//
//  Atomic write mirrors M13 MDXIndex sidecar:
//    1. Write to `<final>.tmp-<uuid>`
//    2. `Data.write(.atomic)` on temp file
//    3. `FileManager.replaceItemAt` to swap into final name
//

import Foundation
import CryptoKit
import OpenMDict

/// Progress callback fired periodically during sidecar build. Reports
/// `(done, total, elapsed)` in articles + seconds. Caller uses this to
/// drive a progress UI or just print to stderr.
public typealias ArticleIndexProgress = (_ done: Int, _ total: Int, _ elapsedSec: Double) -> Void

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

/// Stateless one-shot writer. Construct + call `build()`.
public struct ArticleIndexWriter {

    /// CoreML model file path — used to compute model_sha256 for the
    /// sidecar header. Pass the .mlpackage directory; we hash the
    /// inner model.mlmodel + weights for invalidation.
    public let modelURL: URL

    /// Output .semantic.idx path. Parent directory must exist; the
    /// writer creates a temp file alongside, then atomic-swaps.
    public let outputURL: URL

    /// Optional progress callback. Fires roughly every 100 articles
    /// plus at start + end.
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

    /// Build the sidecar end-to-end. Returns the produced header on
    /// success. `reader` and `encoder` must be from the same model
    /// configuration (the encoder's vocab + max_len determine the
    /// embedding output; the header records both).
    public func build(reader: MDictReader, encoder: ArticleEncoder) throws -> ArticleIndexHeader {
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
        let dim = encoder.dimension > 0 ? encoder.dimension : 384  // detected on first encode

        // 2. Encode every article. We do a "warm-up" encode on key 0
        // so encoder.dimension is populated for the header.
        // (Then re-use that vector — saves one encode.)
        let buildStart = Date()
        progress?(0, count, 0)

        var pool = Data(capacity: count * dim * 2)  // worst case; resized below if dim differs
        var poolPtr = 0
        var detectedDim = dim
        var lastReport = buildStart

        for (i, key) in allKeys.enumerated() {
            guard let entry = reader.lookup(key) else {
                // Missing article at this index — skip with a zero
                // vector to keep positional alignment. Should never
                // happen with a healthy MDX but be defensive.
                let zeros = [UInt16](repeating: 0, count: detectedDim)
                pool.append(zeros.withUnsafeBufferPointer { Data(buffer: $0) })
                poolPtr += 1
                continue
            }
            let plain = Self.stripHTML(entry.article.html)

            // Wrap each prediction in an autoreleasepool. CoreML on
            // macOS holds onto MTLBuffer + IOSurface for each
            // prediction until ARC drains; without a per-iteration
            // pool drain, a long inference loop accumulates Metal
            // resources and eventually fails with "Failed to allocate
            // memory IOSurface object". This is a well-known
            // macOS-only CoreML quirk.
            let vec: [Float]
            do {
                vec = try autoreleasepool {
                    try encoder.encode(plain)
                }
            } catch {
                throw ArticleIndexWriterError.encodeFailed(article: i, key: key, underlying: error)
            }

            // Detect dimension on first real encode + reserve buffer.
            if poolPtr == 0 {
                detectedDim = vec.count
                pool.reserveCapacity(count * detectedDim * 2)
            }
            precondition(vec.count == detectedDim,
                         "Encoder returned variable-dim output (\(vec.count) vs \(detectedDim))")

            // Convert to FP16 bits + append. We store [UInt16] (the
            // raw FP16 bit pattern, not Swift's Float16 type) to avoid
            // platform-dependent Float16 init quirks on Intel mac.
            // UInt16 has a guaranteed 2-byte contiguous layout matching
            // IEEE 754 binary16, so the on-disk bytes are correct.
            var halfBits = [UInt16](repeating: 0, count: detectedDim)
            for d in 0..<detectedDim {
                halfBits[d] = float16Bits(from: vec[d])
            }
            pool.append(halfBits.withUnsafeBufferPointer { Data(buffer: $0) })
            poolPtr += 1

            // Periodic progress sample.
            let now = Date()
            if now.timeIntervalSince(lastReport) > 1.0 || i == count - 1 {
                progress?(i + 1, count, now.timeIntervalSince(buildStart))
                lastReport = now
            }
        }

        // 3. Build the header now that we know the final dimension.
        let header = ArticleIndexHeader(
            modelSHA256: modelSHA,
            mdxHeaderSHA256: mdxSHABytes,
            embeddingDim: UInt32(detectedDim),
            articleCount: UInt32(count),
            tokenizerMaxLen: UInt32(encoder.tokenizerMaxLength)
        )

        // 4. Atomic write.
        try writeAtomic(header: header, body: pool)
        return header
    }

    /// Write `header.serialize() + body` to `outputURL`, going through
    /// a temp file in the same directory so a kill mid-write leaves
    /// only a `.tmp-<uuid>` orphan (never a half-written final file).
    private func writeAtomic(header: ArticleIndexHeader, body: Data) throws {
        let parent = outputURL.deletingLastPathComponent()
        let tmpName = outputURL.lastPathComponent + ".tmp-" + UUID().uuidString
        let tmpURL = parent.appendingPathComponent(tmpName, isDirectory: false)

        var combined = Data(capacity: ArticleIndexFormat.headerSize + body.count)
        combined.append(header.serialize())
        combined.append(body)

        do {
            try combined.write(to: tmpURL, options: .atomic)
        } catch {
            throw ArticleIndexWriterError.writeFailed(tmpURL, error)
        }
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: outputURL)
            }
        } catch {
            // Best-effort cleanup of the orphan temp.
            try? FileManager.default.removeItem(at: tmpURL)
            throw ArticleIndexWriterError.writeFailed(outputURL, error)
        }
    }

    // MARK: - Helpers

    /// SHA256 of the entire .mlpackage's serialized model bytes. We
    /// don't have a single canonical "model file" — .mlpackage is a
    /// directory — so we hash the inner `Data/com.apple.CoreML/model.mlmodel`
    /// which is the protobuf graph. Weight files are large + content-
    /// identical across re-conversions of the same source so this
    /// catches the architecture changes that matter for sidecar
    /// invalidation.
    private static func computeModelSHA256(modelURL: URL) throws -> Data {
        // Find model.mlmodel inside either .mlpackage or .mlmodelc.
        let candidates = [
            modelURL.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"),
            modelURL.appendingPathComponent("model.mil"),  // .mlmodelc form
            modelURL,  // direct .mlmodel file
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

    /// Hex string → 32-byte Data. Returns nil if input isn't valid hex
    /// of the expected length.
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

    /// Same HTML→plaintext logic as the POC runner. Strips tags, decodes
    /// common entities, collapses whitespace. Phase 3.x could replace
    /// with a more thorough WebView-equivalent extractor if needed.
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
        // For Phase 3.2 we don't pipe the override through, so it's
        // always 128. If that changes, plumb it.
        128
    }
}
