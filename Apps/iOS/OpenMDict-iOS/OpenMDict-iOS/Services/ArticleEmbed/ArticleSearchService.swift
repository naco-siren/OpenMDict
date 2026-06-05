//
//  ArticleSearchService.swift
//  OpenMDict-iOS
//
//  M15 — article-content ("词条内容") QUERY path. The indexing side
//  (ArticleIndexWriter → `.semantic.idx` sidecars) has shipped; this is
//  the missing consumer that turns a typed query into article hits.
//
//  Mirrors SemanticSearchService's shape: a @MainActor singleton whose
//  public `search` does the light prep on main (lazy-build the CoreML
//  encoder, snapshot the dict refs) then hands the heavy lifting —
//  query encode + per-dict mmap cosine scan + cross-dict merge — to a
//  `Task.detached`. The core engine (`ArticleEncoder.encode` +
//  `ArticleIndexReader.query`) already exists in the core lib; this file
//  is purely the iOS-side wiring.
//
//  Concurrency: `ArticleEncoder` and `MDictReader` are both
//  `@unchecked Sendable`, so they cross into the detached task safely.
//  `ArticleIndexReader` is NOT Sendable (mutable per-query scratch) so it
//  is constructed and consumed entirely inside the detached task, never
//  passed across the boundary. Sidecar URLs are resolved on main (where
//  `AppGroupPaths` lives) and carried in the Sendable `ArticleDictRef`.
//

import Foundation
import OpenMDict        // ArticleEncoder, ArticleIndexReader, MDictReader
import OpenMDictKit

// MARK: - Public input / output

/// One dictionary to search: its app id, the MDict reader (for the
/// positional articleIndex → keyword mapping) and the resolved sidecar
/// path. Built on main by the caller; Sendable so it crosses into the
/// detached compute task.
struct ArticleDictRef: Sendable {
    let dictId: String
    /// Used only for `allKeys[hit.articleIndex]`. `@unchecked Sendable`.
    let reader: MDictReader
    /// Resolved on main from `AppGroupPaths.articleSidecarCacheURL`.
    let sidecarURL: URL
}

/// One article-content hit. `key` is the dict keyword whose article body
/// matched; `dictId` round-trips so the UI can route a tap to the right
/// dictionary; `similarity` is cosine in roughly [−1, 1] (vectors are
/// L2-normalized, so dot == cosine).
struct ArticleMatch: Sendable, Hashable {
    let key: String
    let dictId: String
    let similarity: Float
}

enum ArticleSearchError: Error, CustomStringConvertible {
    case modelUnavailable

    var description: String {
        switch self {
        case .modelUnavailable:
            return "Article-search model/vocab not available (ODR not acquired)"
        }
    }
}

// MARK: - Service

@MainActor
final class ArticleSearchService {

    static let shared = ArticleSearchService()
    private init() {}

    /// Lazily-built CoreML encoder. Construction compiles the .mlpackage
    /// (slow, seconds on first cold run) so we build once and reuse across
    /// queries. The model path is ODR-stable for the app session, so we
    /// never invalidate this — `ArticleIndexAssetProvider.release()` (on
    /// master-toggle-off) drops the file, but the article scope stops
    /// querying at the same time, so a stale handle is never read.
    private var encoder: ArticleEncoder?

    // MARK: - Public API

    /// Cross-dict article-content search. Encodes `query` once, scans each
    /// dict's sidecar for top-K cosine hits, merges, and returns the global
    /// top-K by similarity descending.
    ///
    /// Returns `[]` for empty query / no dicts. Throws
    /// `ArticleSearchError.modelUnavailable` if the encoder can't be built
    /// (model not yet downloaded) — callers treat that as "no results".
    func search(query: String,
                in dicts: [ArticleDictRef],
                topK: Int) async throws -> [ArticleMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !dicts.isEmpty, topK > 0 else { return [] }

        // Lazy encoder build (may await the ODR acquire + compile).
        let enc = try await ensureEncoder()

        // Heavy lifting off main. enc + dicts are Sendable; the
        // ArticleIndexReader instances are created inside.
        return try await Task.detached(priority: .userInitiated) { [trimmed, dicts, topK] in
            try Self.computeMatches(encoder: enc, query: trimmed, dicts: dicts, topK: topK)
        }.value
    }

    /// Drop the cached encoder. Called when the master toggle goes off so
    /// the CoreML model memory is released alongside the ODR reservation.
    func evictEncoder() {
        encoder = nil
    }

    // MARK: - Encoder lifecycle

    private func ensureEncoder() async throws -> ArticleEncoder {
        if let encoder { return encoder }

        // Route through the ODR-aware provider; on a fully-indexed dict the
        // model is already local so this returns fast.
        await ArticleIndexAssetProvider.shared.ensureAcquired()
        guard let assets = ArticleIndexAssetProvider.shared.assets else {
            throw ArticleSearchError.modelUnavailable
        }

        let built = try ArticleEncoder(
            modelPath: assets.modelURL.path,
            vocabPath: assets.vocabURL.path
            // profile defaults to .foreground (.cpuAndGPU) — fast for a
            // single interactive query; the A13 ANE-hang only bit the
            // sustained background INDEX path.
        )
        encoder = built
        debugLog("ArticleSearchService: built encoder (dim=\(built.dimension))")
        return built
    }

    // MARK: - Detached compute

    /// Pure function: encode the query, scan every dict's sidecar, merge.
    /// Runs entirely off-main inside a detached task.
    nonisolated private static func computeMatches(
        encoder: ArticleEncoder,
        query: String,
        dicts: [ArticleDictRef],
        topK: Int
    ) throws -> [ArticleMatch] {
        let encodeStart = CFAbsoluteTimeGetCurrent()
        let qVec = try encoder.encode(query)
        let encodeMs = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000

        var all: [ArticleMatch] = []
        var scannedDicts = 0
        let scanStart = CFAbsoluteTimeGetCurrent()

        for ref in dicts {
            guard FileManager.default.fileExists(atPath: ref.sidecarURL.path) else {
                // Snapshot said .indexed but the sidecar is gone (e.g. cache
                // evicted). Skip — the dict just contributes nothing.
                continue
            }
            let reader: ArticleIndexReader
            do {
                reader = try ArticleIndexReader(sidecarURL: ref.sidecarURL)
            } catch {
                print("❌ ArticleSearch: open sidecar for \(ref.dictId) failed: \(error)")
                continue
            }

            let hits: [ArticleIndexHit]
            do {
                hits = try reader.query(qVec, topK: topK)
            } catch {
                print("❌ ArticleSearch: query \(ref.dictId) failed: \(error)")
                continue
            }

            // Positional index → keyword. allKeys is COW; bind once per dict.
            let keys = ref.reader.allKeys
            for hit in hits {
                guard hit.articleIndex >= 0, hit.articleIndex < keys.count else { continue }
                all.append(ArticleMatch(
                    key: keys[hit.articleIndex],
                    dictId: ref.dictId,
                    similarity: hit.cosineSimilarity
                ))
            }
            scannedDicts += 1
        }

        // Global top-K across dicts.
        all.sort { $0.similarity > $1.similarity }
        if all.count > topK { all.removeLast(all.count - topK) }

        let scanMs = (CFAbsoluteTimeGetCurrent() - scanStart) * 1000
        print(String(format: "🔎 ArticleSearch '%@': %d hits from %d/%d dicts (encode %.1fms, scan %.1fms)",
                     query, all.count, scannedDicts, dicts.count, encodeMs, scanMs))
        return all
    }
}
