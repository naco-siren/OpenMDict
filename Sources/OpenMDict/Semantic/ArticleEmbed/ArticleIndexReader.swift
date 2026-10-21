//
//  ArticleIndexReader.swift
//  OpenMDictCLI  (M15 Phase 3.6)
//
//  Counterpart to ArticleIndexWriter — opens a `.semantic.idx` sidecar
//  via mmap, validates the header against (MDX, model) hashes, and
//  serves top-K cosine-similarity queries over the Float16 vector pool.
//
//  Memory: mmap'd file-backed clean pages. Reading a vector row triggers
//  a page fault (lazy), but the pages are file-backed clean so the
//  kernel can drop them under pressure (M13's sidecar + jetsam pattern).
//  Working set during a query = ceil(file_size / page_size) pages, but
//  most of those are evictable.
//
//  Phase 3.6 v1 cosine scan: convert Float16 → Float32 per-row + dot
//  product with the query vector (also Float32, already L2-normalized
//  by ArticleEncoder). Linear scan, O(N × d) per query. For a 154k × 384
//  pool that's ~60M MADs; on M-series CPU with SIMD vDSP_dotpr this
//  runs ~50 ms; on Intel CPU maybe 200-300 ms. Acceptable v1.
//
//  Future optimization (Phase 3.x): vDSP_dotpr on per-row pre-converted
//  Float32 chunks, or batch convert + matrix multiply, or Metal kernel
//  for the M-series boost. None needed for Phase 3.2/3.6 verification.
//

import Foundation
import CryptoKit
import Accelerate

public enum ArticleIndexReaderError: Error, CustomStringConvertible {
    case openFailed(URL, Error)
    case mmapFailed(URL, Int32)         // errno
    case headerInvalid(String)          // human-readable reason
    case validationFailed(ArticleIndexValidationResult)
    case queryDimMismatch(query: Int, sidecar: Int)

    public var description: String {
        switch self {
        case .openFailed(let u, let e):    return "open \(u.path): \(e)"
        case .mmapFailed(let u, let err):  return "mmap \(u.path): errno=\(err)"
        case .headerInvalid(let m):        return "Sidecar header invalid: \(m)"
        case .validationFailed(let r):     return "Sidecar invalid: \(r)"
        case .queryDimMismatch(let q, let s):
            return "Query dim \(q) doesn't match sidecar dim \(s)"
        }
    }
}

/// One (article-index, score) hit from a query. The article index is
/// the position in `MDictReader.allKeys`, since the sidecar uses
/// implicit positional mapping. Caller resolves index → key via
/// `mdict.allKeys[idx]`.
public struct ArticleIndexHit: Sendable {
    public let articleIndex: Int
    public let cosineSimilarity: Float

    public init(articleIndex: Int, cosineSimilarity: Float) {
        self.articleIndex = articleIndex
        self.cosineSimilarity = cosineSimilarity
    }
}

/// Sidecar reader. Open once (mmaps the file), then run many queries.
/// `deinit` munmaps cleanly.
public final class ArticleIndexReader {

    public let header: ArticleIndexHeader
    public let sidecarURL: URL

    /// mmap'd base pointer of the entire file. Body data starts at
    /// `basePtr + ArticleIndexFormat.headerSize`.
    private let basePtr: UnsafeRawPointer
    private let fileSize: Int

    /// Per-article cosine scratch — converted-to-Float32 view of one
    /// row, reused across query iterations to avoid per-row allocs.
    private var rowScratch: [Float]

    /// Initializer. Opens the file, validates header magic, mmaps the
    /// content. Caller can then run `query(_:topK:)`.
    public init(sidecarURL: URL) throws {
        self.sidecarURL = sidecarURL

        // 1. Open + stat for size
        let fd = open(sidecarURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw ArticleIndexReaderError.mmapFailed(sidecarURL, errno)
        }
        defer { close(fd) }   // mmap stays valid after close per Unix semantics

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw ArticleIndexReaderError.mmapFailed(sidecarURL, errno)
        }
        self.fileSize = Int(st.st_size)

        // 2. mmap entire file (PROT_READ, MAP_PRIVATE, file-backed)
        guard let mapped = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED
        else {
            throw ArticleIndexReaderError.mmapFailed(sidecarURL, errno)
        }
        self.basePtr = UnsafeRawPointer(mapped)

        // 3. Read + parse header. We need to make a Data view of the
        // first 96 bytes to feed ArticleIndexHeader.parse, which expects
        // Data not raw pointer.
        let headerData = Data(
            bytes: basePtr,
            count: min(ArticleIndexFormat.headerSize, fileSize)
        )
        guard let parsed = ArticleIndexHeader.parse(headerData) else {
            // Don't leak the mmap on init failure.
            munmap(UnsafeMutableRawPointer(mutating: basePtr), fileSize)
            throw ArticleIndexReaderError.headerInvalid("not a sidecar (magic mismatch)")
        }
        self.header = parsed

        // 4. Sanity: file size must be at least the header's expected
        // size. Trailing bytes beyond `expectedFileSize` are tolerated —
        // they come from the streaming writer's crash window between
        // body-append and the next checkpoint (the writer overwrites
        // them on resume, and queries only scan `article_count` rows so
        // trailing is invisible to callers).
        if fileSize < header.expectedFileSize {
            munmap(UnsafeMutableRawPointer(mutating: basePtr), fileSize)
            throw ArticleIndexReaderError.headerInvalid(
                "file size \(fileSize) < expected \(header.expectedFileSize) " +
                "(article_count=\(header.articleCount), dim=\(header.embeddingDim))"
            )
        }

        self.rowScratch = [Float](repeating: 0, count: Int(header.embeddingDim))
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: basePtr), fileSize)
    }

    /// Validate against a current (model, MDX) pair. Returns nil on OK,
    /// otherwise the specific mismatch — caller can choose to rebuild
    /// or reject.
    public func validate(expectedModelSHA256: Data,
                  expectedMDXHeaderSHA256: Data) -> ArticleIndexValidationResult {
        header.validate(
            expectedModelSHA256: expectedModelSHA256,
            expectedMDXHeaderSHA256: expectedMDXHeaderSHA256,
            expectedEmbeddingDim: header.embeddingDim,
            actualFileSize: fileSize
        )
    }

    /// Run a top-K cosine similarity query. `query` must be L2-normalized
    /// (ArticleEncoder.encode returns normalized vectors). Returns the top
    /// `topK` hits sorted by similarity descending.
    ///
    /// Implementation: linear scan, per-row Float16→Float32 conversion,
    /// vDSP_dotpr per row, min-heap (well, sorted-array) of top-K.
    /// For 154k articles × 384 dim on Mac M-series this completes in
    /// ~50-100 ms; Intel CPU ~200-300 ms.
    public func query(_ query: [Float], topK: Int = 10) throws -> [ArticleIndexHit] {
        let dim = Int(header.embeddingDim)
        guard query.count == dim else {
            throw ArticleIndexReaderError.queryDimMismatch(query: query.count, sidecar: dim)
        }
        let count = Int(header.articleCount)
        guard topK > 0 else { return [] }
        let k = min(topK, count)

        let poolPtr = basePtr.advanced(by: ArticleIndexFormat.headerSize)
            .assumingMemoryBound(to: UInt16.self)

        // Maintain a sorted-by-score-descending array of top-K hits.
        // For small K (typical: 10-50) sorted insertion is faster than
        // a real heap. For large K (>~100) revisit.
        var topHits: [ArticleIndexHit] = []
        topHits.reserveCapacity(k + 1)

        for i in 0..<count {
            // Convert row i Float16 → Float32 into scratch buffer.
            let rowBase = poolPtr.advanced(by: i * dim)
            for d in 0..<dim {
                rowScratch[d] = float32FromFloat16Bits(rowBase[d])
            }
            // Dot product. Both query and row are L2-normalized so
            // dot = cosine similarity directly.
            var sim: Float = 0
            query.withUnsafeBufferPointer { qPtr in
                rowScratch.withUnsafeBufferPointer { rPtr in
                    vDSP_dotpr(qPtr.baseAddress!, 1,
                               rPtr.baseAddress!, 1,
                               &sim, vDSP_Length(dim))
                }
            }

            // All-zero rows (aliases, missing records) carry no embedding.
            if sim == 0 { continue }

            // Insert into top-K if it qualifies.
            if topHits.count < k {
                // Sorted insert.
                let insertAt = topHits.firstIndex(where: { $0.cosineSimilarity < sim }) ?? topHits.count
                topHits.insert(ArticleIndexHit(articleIndex: i, cosineSimilarity: sim), at: insertAt)
            } else if sim > topHits.last!.cosineSimilarity {
                topHits.removeLast()
                let insertAt = topHits.firstIndex(where: { $0.cosineSimilarity < sim }) ?? topHits.count
                topHits.insert(ArticleIndexHit(articleIndex: i, cosineSimilarity: sim), at: insertAt)
            }
        }

        return topHits
    }
}

/// Convenience: build the encoder, encode a text query, run the search.
/// Wraps Reader + Encoder so the CLI doesn't have to plumb both.
public func runArticleSemanticQuery(
    sidecarURL: URL,
    query: String,
    modelPath: String,
    vocabPath: String,
    topK: Int
) throws -> (header: ArticleIndexHeader, hits: [ArticleIndexHit], queryEncodeMs: Double, scanMs: Double) {
    // Encode query.
    let encoder = try ArticleEncoder(modelPath: modelPath, vocabPath: vocabPath)
    let encStart = CFAbsoluteTimeGetCurrent()
    let q = try encoder.encode(query)
    let queryEncodeMs = (CFAbsoluteTimeGetCurrent() - encStart) * 1000

    // Open sidecar + scan.
    let reader = try ArticleIndexReader(sidecarURL: sidecarURL)
    let scanStart = CFAbsoluteTimeGetCurrent()
    let hits = try reader.query(q, topK: topK)
    let scanMs = (CFAbsoluteTimeGetCurrent() - scanStart) * 1000

    return (reader.header, hits, queryEncodeMs, scanMs)
}
