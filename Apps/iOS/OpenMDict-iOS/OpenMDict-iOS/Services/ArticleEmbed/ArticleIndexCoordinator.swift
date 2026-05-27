//
//  ArticleIndexCoordinator.swift
//  OpenMDict-iOS  (M15 Phase 3.3)
//
//  Single point of availability enforcement + per-dict indexing state
//  for the article-embedding feature. All UI entry points (全文 scope
//  toggle, import hook, settings page, etc.) route through this
//  coordinator so the `if #available(iOS 26, *)` check + hardware /
//  language / model-presence checks live in exactly one place.
//
//  Public API contract: every user-facing method returns
//  `Result<T, ArticleIndexUnavailableReason>` so callers can switch on
//  the result and either render normal UI or a `ContentUnavailableView`
//  with the reason's localized strings. Lifecycle hooks (import /
//  delete) are no-throw — they silently no-op when the feature isn't
//  available, since callers don't need a UI error path there.
//
//  Phase 3.3 scope (this file):
//    - Availability gate (iOS 26+, language model coverage)
//    - Per-dict state introspection (still a stub — no persistence
//      yet; Phase 3.4 adds the CoreData record + checkpointing)
//    - Lifecycle hooks called from DictionaryService /
//      DictionaryStorageService (just sidecar cleanup for now)
//    - Reader factory for the query path
//
//  NOT yet in 3.3 (lands in 3.4):
//    - Priority queue + dispatcher
//    - BGProcessingTask integration
//    - CoreData persistence
//    - Actual indexing execution
//

import Foundation
import NaturalLanguage
import OpenMDict   // ArticleIndexReader + format types live in core lib
import os.log

@MainActor
final class ArticleIndexCoordinator {

    static let shared = ArticleIndexCoordinator()

    private let log = Logger(
        subsystem: "io.github.naco-siren.openmdict",
        category: "ArticleIndexCoordinator"
    )

    /// Minimum supported iOS for the feature (picks up
    /// the A13+ chip tier transitively).
    static let minimumSupportedOSMajor: Int = 26

    private init() {
        // Ensure the sidecar cache dir exists. mkdir is idempotent.
        try? FileManager.default.createDirectory(
            at: AppGroupPaths.articleSidecarCacheURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Top-level availability

    /// Cheap top-level check. Use this for the 全文 scope-tab disabled
    /// state, settings entry visibility, etc. — anything that doesn't
    /// care about per-dict status. Phase 3.4 may add a battery /
    /// thermal / low-power-mode gate here too; for now it's just the
    /// OS version.
    var availability: Result<Void, ArticleIndexUnavailableReason> {
        if #unavailable(iOS 26) {
            let current = ProcessInfo.processInfo.operatingSystemVersion
            let currentStr = "\(current.majorVersion).\(current.minorVersion)"
            return .failure(.osVersionTooOld(
                current: currentStr,
                minimum: "\(Self.minimumSupportedOSMajor)"
            ))
        }
        return .success(())
    }

    /// Convenience flag — `availability` collapsed to a Bool. Cheap.
    var isAvailable: Bool {
        if case .success = availability { return true }
        return false
    }

    // MARK: - Per-dict state

    /// Returns the indexing state for a dict, OR a failure reason if
    /// the feature itself is unavailable (so the UI can short-circuit
    /// without iterating dict-by-dict).
    ///
    /// Per-dict introspection is still a stub in 3.3 — it derives state
    /// purely from sidecar file presence + validity, no CoreData yet.
    /// 3.4 adds: indexing-in-progress tracking, user-paused state,
    /// per-dict error persistence.
    func state(for dictId: String, mdx: MDictReader, modelHash: Data)
        -> Result<ArticleIndexState, ArticleIndexUnavailableReason>
    {
        if case .failure(let r) = availability { return .failure(r) }

        let url = sidecarURL(for: dictId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(.notIndexed)
        }

        // Sidecar exists — verify it's valid + not stale.
        do {
            let reader = try ArticleIndexReader(sidecarURL: url)
            guard let mdxHashHex = mdx.metadata.headerSHA256,
                  let mdxHash = Self.hexToData(mdxHashHex),
                  mdxHash.count == 32 else {
                return .success(.error(message: "MDX has no SHA256 (encrypted?)"))
            }
            let result = reader.validate(
                expectedModelSHA256: modelHash,
                expectedMDXHeaderSHA256: mdxHash
            )
            switch result {
            case .ok:
                return .success(.indexed)
            case .modelMismatch, .mdxMismatch, .wrongVersion, .dimMismatch:
                // Stale — needs rebuild. Surface as `notIndexed` since
                // the old data is no longer trustable; the queue will
                // re-index.
                return .success(.notIndexed)
            case .sizeMismatch:
                return .success(.error(message: "Sidecar file size mismatch — corrupt"))
            case .notASidecar:
                return .success(.error(message: "File present but not a sidecar — corrupt"))
            }
        } catch {
            return .success(.error(message: "Failed to open sidecar: \(error)"))
        }
    }

    // MARK: - Reader factory (query path)

    /// Open the dict's sidecar for query. Returns `.success(nil)` if
    /// the dict isn't indexed (caller should skip this dict silently
    /// in the per-dict streaming scan). `.failure` only on
    /// feature-level unavailability — that's the case where the VC
    /// should short-circuit to ContentUnavailableView before iterating
    /// dicts at all.
    func openReader(dictId: String)
        -> Result<ArticleIndexReader?, ArticleIndexUnavailableReason>
    {
        if case .failure(let r) = availability { return .failure(r) }

        let url = sidecarURL(for: dictId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(nil)
        }
        do {
            let reader = try ArticleIndexReader(sidecarURL: url)
            return .success(reader)
        } catch {
            log.warning("Failed to open sidecar for \(dictId): \(String(describing: error))")
            return .success(nil)
        }
    }

    // MARK: - Lifecycle hooks (called from DictionaryService etc.)

    /// Called from `DictionaryService.refreshAfterImport(dictId)` after
    /// the dict has loaded + the M13 keyword sidecar has been written.
    /// In Phase 3.3 this is a no-op stub; Phase 3.4 enqueues the dict
    /// for background indexing.
    ///
    /// Intentionally no-throw / no-Result — the import flow doesn't
    /// need a UI error path here. If the feature is unavailable
    /// (iOS < 26), this method silently does nothing.
    func handleDictImported(_ dictId: String) {
        guard isAvailable else {
            log.debug("handleDictImported(\(dictId)): feature unavailable, no-op")
            return
        }
        // Phase 3.4: enqueue for background indexing.
        log.info("handleDictImported(\(dictId)): would schedule indexing (stub)")
    }

    /// Called from `DictionaryStorageService.deleteDictionary(id:)` and
    /// `DictionaryService.handleRemoteChange(...)`'s remote-delete
    /// branch. Removes the dict's article sidecar (if any) from disk.
    /// Always runs, even when the feature is unavailable, since
    /// dead-file cleanup should be unconditional.
    func handleDictDeleted(_ dictId: String) {
        let url = sidecarURL(for: dictId)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                log.info("Deleted article sidecar for \(dictId)")
            } catch {
                let desc = String(describing: error)
                log.warning("Failed to delete article sidecar for \(dictId): \(desc)")
            }
        }
    }

    /// Called from `LocalDataResetService` when the user invokes the
    /// "nuclear reset" flow. Wipes the entire `SemanticIndex/` dir.
    func deleteAllSidecars() {
        let dir = AppGroupPaths.articleSidecarCacheURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.pathExtension == "idx" {
            try? FileManager.default.removeItem(at: url)
        }
        log.info("deleteAllSidecars: cleared \(entries.count) entries")
    }

    // MARK: - Internal helpers

    /// Path on disk for a given dictId's article sidecar.
    private func sidecarURL(for dictId: String) -> URL {
        AppGroupPaths.articleSidecarCacheURL
            .appendingPathComponent("\(dictId).semantic.idx", isDirectory: false)
    }

    /// Hex string → 32-byte Data. Mirror of the writer's helper —
    /// duplicating ~10 lines avoids exposing the writer's private
    /// implementation detail.
    private static func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }
}
