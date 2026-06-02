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
import OpenMDict     // ArticleIndexReader + format types live in core lib
import OpenMDictKit  // MDict — for DictionaryService.allDictionaries[*].id

@MainActor
final class ArticleIndexCoordinator {

    static let shared = ArticleIndexCoordinator()

    // Logging convention: see ArticleIndexDispatcher for the rationale —
    // debugLog (gated by VERBOSE_LOGGING) for info, print for errors.

    /// Minimum supported iOS for the feature (picks up
    /// the A13+ chip tier transitively).
    static let minimumSupportedOSMajor: Int = 26

    private init() {
        // Ensure the sidecar cache dir exists. mkdir is idempotent.
        try? FileManager.default.createDirectory(
            at: AppGroupPaths.articleSidecarCacheURL,
            withIntermediateDirectories: true
        )
        // Launch-time orphan cleanup. Any record persisted as `.indexing`
        // is stale — no live job exists yet (we're in init). Normalize to
        // `.notIndexed` so the UI doesn't show phantom spinners after a
        // force-kill / crash mid-encode. The on-disk partial sticks
        // around, so the writer still resumes when the scheduler picks
        // up the dict.
        ArticleIndexService.shared.normalizeOrphanIndexing(liveJob: nil)
        // Scrub the "Dictionary not loaded" legacy poison from earlier
        // dispatcher bug — see service method docstring.
        ArticleIndexService.shared.normalizeStaleNotLoadedErrors()
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
    ///   2. Service snapshot's state, mapped through:
    ///      - `.indexing` → `.indexing(progress, indexedThrough)`
    ///      - `.paused`   → `.paused(progress, indexedThrough)`
    ///      - `.error`    → `.error(message)`
    ///      - `.notIndexed` / `.indexed` → fall through to filesystem
    ///   3. Filesystem source of truth for `.indexed` validation.
    ///
    /// **`userExcluded` (Enabled vs Disabled section) is ORTHOGONAL** to
    /// this state — it gates the QUERY path, not indexing state. A
    /// disabled dict can still be `.indexed` and the cell shows that.
    /// The UI separately consults `snap.userExcluded` to decide which
    /// section to render the row in.
    func state(for dictId: String, mdx: MDictReader, modelHash: Data)
        -> Result<ArticleIndexState, ArticleIndexUnavailableReason>
    {
        if case .failure(let r) = availability { return .failure(r) }

        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        let total = max(1, mdx.entryCount)
        let progress = min(1.0, Double(snap.indexedThrough) / Double(total))
        switch snap.state {
        case .indexing:
            return .success(.indexing(progress: progress, indexedThrough: Int(snap.indexedThrough)))
        case .paused:
            return .success(.paused(progress: progress, indexedThrough: Int(snap.indexedThrough)))
        case .error:
            return .success(.error(message: snap.errorMessage ?? "Unknown error"))
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

    /// User-action: toggle the Enabled/Disabled section membership.
    ///
    /// - `enabled = false` (Enabled → Disabled): if the dict is currently
    ///   indexing, this is treated as an implicit pause — state becomes
    ///   `.paused(progress)` and the in-flight build is cancelled
    ///   (partial preserved on disk). Other states are untouched.
    /// - `enabled = true` (Disabled → Enabled): if state was `.paused`,
    ///   transition to `.notIndexed` so the scheduler picks it up
    ///   (implicit resume — the toggle-off+toggle-on shorthand from the
    ///   flow spec). Other states are untouched. Backfill
    ///   re-evaluates eligibility and may enqueue.
    ///
    /// By design: enabled/disabled is ORTHOGONAL to index
    /// state. The flag gates the QUERY path (forward-looking — query
    /// consumer hasn't shipped yet); index state is preserved across
    /// section moves so the UI shows e.g. "Indexed" in Disabled section.
    func setEnabled(_ enabled: Bool, for dictId: String) {
        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        if enabled {
            // Disabled → Enabled. Clear exclusion flag.
            ArticleIndexService.shared.setUserExcluded(false, for: dictId)
            // Implicit resume of paused dicts: section transition acts as
            // resume so the user doesn't have to tap ▶ AGAIN after
            // re-enabling. (Tap ▶ within Enabled section is the other
            // path; both end up at `.notIndexed` + eligible.)
            if snap.state == .paused {
                ArticleIndexService.shared.setState(
                    .notIndexed, for: dictId, indexedThrough: snap.indexedThrough
                )
                debugLog("setEnabled(\(dictId), true): implicit resume from .paused at \(snap.indexedThrough)")
            }
            backfillIfEnabled()
        } else {
            // Enabled → Disabled. If indexing, implicit pause (state
            // → .paused). The userPause path handles cancel + state
            // transition atomically.
            if snap.state == .indexing {
                ArticleIndexDispatcher.shared.userPause(dictId)
            }
            ArticleIndexService.shared.setUserExcluded(true, for: dictId)
            debugLog("setEnabled(\(dictId), false): moved to Disabled section (state=\(ArticleIndexService.shared.snapshot(for: dictId).state.rawValue))")
        }
    }

    /// User-action: explicit pause via the ⏸ button on an indexing row.
    /// Forwards to the dispatcher which cancels the build + persists
    /// `.paused` at the checkpoint. Scheduler will NOT auto-resume —
    /// the user has to tap ▶ or do the toggle-off + toggle-on dance.
    func userPause(_ dictId: String) {
        ArticleIndexDispatcher.shared.userPause(dictId)
    }

    /// User-action: explicit resume via the ▶ button on a paused row.
    /// Forwards to the dispatcher which transitions `.paused` →
    /// `.notIndexed` (preserving checkpoint) and enqueues at
    /// `.interactive` priority so the scheduler picks it up immediately,
    /// preempting any background job.
    func userResume(_ dictId: String) {
        ArticleIndexDispatcher.shared.userResume(dictId)
    }

    /// User-action: drag-to-reorder in the overview UI. Pass dictIds
    /// in the desired display order; service rewrites
    /// `userPriorityOrder` to 0..<N matching that order.
    func reorderUserPriority(_ dictIds: [String]) {
        ArticleIndexService.shared.reorderUserPriority(dictIds)
    }

    /// User-action: "Index this dict now". Enqueues at `.interactive`
    /// priority so it preempts any running background job. Returns
    /// `.failure` if the feature is unavailable (UI shows the
    /// `ContentUnavailableView`); otherwise returns `.success(())`
    /// and the indexing happens async — caller observes via
    /// `ArticleIndexService.snapshotPublisher(for:)`.
    func userRequestIndex(_ dictId: String)
        -> Result<Void, ArticleIndexUnavailableReason>
    {
        if case .failure(let r) = availability { return .failure(r) }
        // Clear any prior error state on user-initiated retry so the
        // overview UI immediately reflects "we're trying again".
        ArticleIndexService.shared.setState(
            .notIndexed, for: dictId, indexedThrough: 0,
            errorMessage: nil
        )
        ArticleIndexDispatcher.shared.enqueue(dictId, priority: .interactive)
        return .success(())
    }

    /// Cancel a running or queued index job for a dict. Idempotent —
    /// safe to call when nothing is in flight.
    func cancelIndex(_ dictId: String) {
        ArticleIndexDispatcher.shared.cancel(dictId)
    }

    /// Enqueue every eligible dict for background indexing, gated on
    /// availability + the user's "Article Search" toggle. Idempotent —
    /// the dispatcher dedups ids that are already running/queued — so
    /// it's safe to call from every front-stage trigger (scene
    /// foregrounding, overview viewDidLoad, switch flip).
    ///
    /// Eligibility uses the centralized `Dispatcher.isSchedulerEligible`
    /// predicate so the rule stays consistent across this method,
    /// `runBackgroundPass`, and `scheduleIfNeeded`. `.paused` is
    /// excluded — the user must resume explicitly.
    func backfillIfEnabled() {
        guard isAvailable, UserDefaults.standard.articleSearchEnabled else {
            debugLog("Coordinator.backfillIfEnabled: skipping (isAvailable=\(isAvailable), articleSearchEnabled=\(UserDefaults.standard.articleSearchEnabled))")
            return
        }
        var enqueued = 0
        for dict in DictionaryService.shared.allDictionaries {
            let snap = ArticleIndexService.shared.snapshot(for: dict.id)
            if !snap.userExcluded
                && ArticleIndexDispatcher.isSchedulerEligible(snap.state)
            {
                ArticleIndexDispatcher.shared.enqueue(dict.id, priority: .background)
                enqueued += 1
            }
        }
        debugLog("Coordinator.backfillIfEnabled: enqueued \(enqueued) dict(s)")
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
            debugLog("Failed to open sidecar for \(dictId): \(String(describing: error))")
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
            debugLog("handleDictImported(\(dictId)): feature unavailable, no-op")
            return
        }
        // Reset to `.notIndexed`. If a record already exists for this
        // dictId (e.g. user re-imported the same MDX after a delete),
        // setState preserves user prefs (priorityOrder + excluded) and
        // wipes stale hashes/state. We register the row regardless of
        // the master toggle so the dict still appears in the overview
        // list when the user opens the screen.
        ArticleIndexService.shared.setState(
            .notIndexed, for: dictId,
            indexedThrough: 0, modelHash: nil, mdxHash: nil
        )
        // Auto-enqueue ONLY when the user has the master "Article Search"
        // toggle on. If they enable later, backfillIfEnabled() (called
        // from SceneDelegate.sceneWillEnterForeground + the overview's
        // viewDidLoad + the toggle's own setEnabled(true)) will pick this
        // dict up. Without this gate, a fresh install + import would
        // start indexing immediately even with the master toggle off.
        guard UserDefaults.standard.articleSearchEnabled else {
            debugLog("handleDictImported(\(dictId)): registered .notIndexed; master toggle OFF, not enqueuing")
            return
        }
        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        if !snap.userExcluded {
            ArticleIndexDispatcher.shared.enqueue(dictId, priority: .background)
        }
        let suffix = snap.userExcluded ? " (user-excluded, not enqueued)" : ""
        debugLog("handleDictImported(\(dictId)): registered .notIndexed in service\(suffix)")
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
                debugLog("Deleted article sidecar for \(dictId)")
            } catch {
                let desc = String(describing: error)
                debugLog("Failed to delete article sidecar for \(dictId): \(desc)")
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
        debugLog("deleteAllSidecars: cleared \(entries.count) entries")
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
