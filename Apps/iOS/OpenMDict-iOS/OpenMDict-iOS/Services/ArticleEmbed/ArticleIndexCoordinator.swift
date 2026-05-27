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
//  Scope (this file):
//    - Availability gate (iOS 26+, language model coverage)
//    - Per-dict state introspection — consults ArticleIndexService
//      (CoreData-backed) first, then validates against the on-disk
//      sidecar + model/MDX hashes
//    - User-action APIs (index now / cancel / exclude / reorder) that
//      forward to ArticleIndexService + ArticleIndexDispatcher
//    - Lifecycle hooks called from DictionaryService /
//      DictionaryStorageService (register on import, cleanup on delete)
//    - Reader factory for the query path
//
//  Deferred to Phase 3.5:
//    - BGProcessingTask scheduling (background indexing without the
//      app foregrounded)
//    - Resumable writer + checkpoint persistence
//    - Thermal / battery / memory budget gates
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
    /// Resolution order:
    ///   1. Feature availability (iOS version)
    ///   2. Service snapshot: `userExcluded` → `.paused`
    ///   3. Service snapshot: `state == .indexing` → `.indexing(progress)`
    ///      derived from `indexedThrough / mdx.entryCount`
    ///   4. Service snapshot: `state == .error` → `.error(message)`
    ///   5. Sidecar file presence + 3-field validation:
    ///      - valid → `.indexed`
    ///      - stale or missing → `.notIndexed` (will be re-indexed)
    func state(for dictId: String, mdx: MDictReader, modelHash: Data)
        -> Result<ArticleIndexState, ArticleIndexUnavailableReason>
    {
        if case .failure(let r) = availability { return .failure(r) }

        // 2-4: service-side state.
        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        if snap.userExcluded {
            return .success(.paused)
        }
        switch snap.state {
        case .indexing:
            let total = max(1, mdx.entryCount)
            let progress = min(1.0, Double(snap.indexedThrough) / Double(total))
            return .success(.indexing(progress: progress))
        case .error:
            return .success(.error(message: snap.errorMessage ?? "Unknown error"))
        case .paused:
            return .success(.paused)
        case .notIndexed, .indexed:
            break   // fall through to filesystem check
        }

        // 5: filesystem source of truth for the "is the sidecar there +
        // valid?" question. We don't trust `snap.state == .indexed`
        // alone — the sidecar lives in Caches/ so it can be evicted out
        // from under us, or invalidated by a model upgrade since the row
        // was written. The hash check below catches both.
        let url = sidecarURL(for: dictId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(.notIndexed)
        }
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
                // Stale — needs rebuild. Surface as `notIndexed`; the
                // dispatcher will pick it up.
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

    // MARK: - User-action APIs

    /// User-action: toggle the per-dict exclusion flag (the "don't
    /// index this dict" preference). Surfaces as `.paused` state via
    /// `state(for:)`.
    func setUserExcluded(_ excluded: Bool, for dictId: String) {
        ArticleIndexService.shared.setUserExcluded(excluded, for: dictId)
    }

    /// User-action: drag-to-reorder in the overview UI. Pass dictIds
    /// in the desired display order; service rewrites
    /// `userPriorityOrder` to 0..<N matching that order.
    func reorderUserPriority(_ dictIds: [String]) {
        ArticleIndexService.shared.reorderUserPriority(dictIds)
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
    /// Records the dict in the service catalog with `.notIndexed`
    /// state so it shows up in the overview UI and becomes eligible
    /// for the dispatcher (Phase 3.5).
    ///
    /// Intentionally no-throw / no-Result — the import flow doesn't
    /// need a UI error path here. If the feature is unavailable
    /// (iOS < 26) we don't register anything because there's no UI
    /// to show it in on those builds.
    func handleDictImported(_ dictId: String) {
        guard isAvailable else {
            log.debug("handleDictImported(\(dictId)): feature unavailable, no-op")
            return
        }
        // Reset to `.notIndexed`. If a record already exists for this
        // dictId (e.g. user re-imported the same MDX after a delete),
        // setState preserves user prefs (priorityOrder + excluded) and
        // wipes stale hashes/state.
        ArticleIndexService.shared.setState(
            .notIndexed, for: dictId,
            indexedThrough: 0, modelHash: nil, mdxHash: nil
        )
        log.info("handleDictImported(\(dictId)): registered .notIndexed in service")
    }

    /// Called from `DictionaryStorageService.deleteDictionary(id:)` and
    /// `DictionaryService.handleRemoteChange(...)`'s remote-delete
    /// branch. Removes the dict's article sidecar (if any) from disk
    /// AND the catalog row from CoreData. Always runs, even when the
    /// feature is unavailable, since dead-data cleanup should be
    /// unconditional.
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
        // Drop the catalog row regardless of file presence — service
        // tolerates "delete a missing record" silently.
        ArticleIndexService.shared.delete(dictId: dictId)
    }

    /// Called from `LocalDataResetService` when the user invokes the
    /// "nuclear reset" flow. Wipes both the on-disk sidecars AND the
    /// in-memory cache (CoreData itself is wiped separately by the
    /// reset orchestrator before this gets called).
    func deleteAllSidecars() {
        let dir = AppGroupPaths.articleSidecarCacheURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            ArticleIndexService.shared.resetCaches()
            return
        }
        for url in entries where url.pathExtension == "idx" {
            try? FileManager.default.removeItem(at: url)
        }
        ArticleIndexService.shared.resetCaches()
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
