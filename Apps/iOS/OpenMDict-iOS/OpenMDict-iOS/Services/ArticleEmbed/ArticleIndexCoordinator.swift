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
//    - Launch check of every record's sidecar: converts complete indexes
//      in the old dense layout, deletes files the writer won't resume or
//      the reader can't use, and resets those records' progress
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

import Combine       // MDict.$state.values (wait for a dictionary to load)
import Foundation
import NaturalLanguage
import OpenMDict     // ArticleIndexReader + format types live in core lib
import OpenMDictKit  // MDict — for DictionaryService.allDictionaries[*].id

@MainActor
final class ArticleIndexCoordinator {

    static let shared = ArticleIndexCoordinator()

    // Logging convention: see ArticleIndexDispatcher for the rationale —
    // debugLog (gated by VERBOSE_LOGGING) for info, print for errors.

    /// Minimum supported iOS for the feature (see docs/article-embeddings.md,
    /// "Why iOS 26 as the floor" — picks up the A13+ chip tier transitively).
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
        // Make every record agree with its sidecar file (header reads run
        // off the main actor; builds wait for this — see the method).
        launchSidecarCheck = Task { await self.checkSidecarsAtLaunch() }
    }

    // MARK: - Launch sidecar check

    /// The launch check of every record's sidecar. Builds wait for it
    /// (`waitForLaunchSidecarCheck`), so none starts from a file it is
    /// about to delete or with progress it is about to reset.
    private var launchSidecarCheck: Task<Void, Never>?

    /// Conversions of version-1 indexes, run one at a time (each reads a
    /// whole index and writes a new one).
    private var conversionChain: Task<Void, Never>?

    /// Suspends until the launch sidecar check has applied its resets.
    /// Conversions it schedules may still be running.
    func waitForLaunchSidecarCheck() async {
        await launchSidecarCheck?.value
    }

    /// Check each record against its sidecar's header (read off the main
    /// actor) and make the record agree with what the writer and the
    /// reader will do with that file (`ArticleIndexSidecar.launchAction`):
    ///
    ///   - a current-version file stays (complete, or a partial the writer
    ///     resumes);
    ///   - a complete version-1 index is converted in place once its
    ///     dictionary has loaded, and is still queried until then; one
    ///     that can't be converted is deleted and rebuilt;
    ///   - anything else is deleted and the record's progress restarts at
    ///     0 — a version-1 partial (the writer starts it over in the
    ///     current format), a version this build doesn't know (a newer
    ///     build wrote it), a corrupt or truncated file — and so is the
    ///     progress of a record whose file is gone. An indexed dictionary
    ///     becomes `.notIndexed`, so backfill rebuilds it; a paused or
    ///     failed one keeps that state.
    private func checkSidecarsAtLaunch() async {
        let targets = ArticleIndexService.shared.allSnapshots().map { ($0.dictId, sidecarURL(for: $0.dictId)) }
        guard !targets.isEmpty else { return }
        let conditions = await Task.detached(priority: .utility) {
            targets.map { ($0.0, ArticleIndexSidecar.inspect($0.1)) }
        }.value

        var reset = 0
        for (dictId, condition) in conditions {
            // Deleted meanwhile, or article search turned off (records wiped).
            guard ArticleIndexService.shared.hasRecord(for: dictId) else { continue }
            let snap = ArticleIndexService.shared.snapshot(for: dictId)
            switch ArticleIndexSidecar.launchAction(for: condition, recordIsIndexed: snap.state == .indexed) {
            case .keep:
                break
            case .convert:
                scheduleConversion(dictId)
            case .discard:
                if discardSidecar(dictId) {
                    reset += 1
                    debugLog("Launch sidecar check \(dictId): \(condition) → progress reset")
                }
            }
        }
        if reset > 0 {
            backfillIfEnabled()
        }
    }

    /// Delete the dict's sidecar and restart its progress at 0; an indexed
    /// dict becomes `.notIndexed`, other states are kept. Returns whether
    /// the record changed.
    @discardableResult
    private func discardSidecar(_ dictId: String) -> Bool {
        try? FileManager.default.removeItem(at: sidecarURL(for: dictId))
        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        let state: ArticleIndexRecordSnapshot.PersistedState = snap.state == .indexed ? .notIndexed : snap.state
        guard state != snap.state || snap.indexedThrough != 0 else { return false }
        ArticleIndexService.shared.setState(state, for: dictId, indexedThrough: 0)
        return true
    }

    /// Convert the dict's version-1 index once the dictionary has loaded:
    /// telling articles from aliases needs its records. A dictionary that
    /// doesn't load keeps its version-1 index (still queried) until a
    /// later launch converts it.
    private func scheduleConversion(_ dictId: String) {
        Task {
            guard let reader = await self.loadedReader(for: dictId) else { return }
            let previous = self.conversionChain
            self.conversionChain = Task {
                await previous?.value
                await self.convertDenseSidecar(dictId, reader: reader)
            }
        }
    }

    /// The dict's reader once it has loaded; nil if it isn't in the
    /// library or fails to load.
    private func loadedReader(for dictId: String) async -> MDictReader? {
        guard let dict = DictionaryService.shared.dict(id: dictId) else { return nil }
        for await state in dict.$state.values {
            switch state {
            case .loaded:
                return dict.reader
            case .error:
                return nil
            case .unloaded, .loading, .metadataLoaded:
                continue
            }
        }
        return nil
    }

    /// Rewrite the dict's version-1 index in the current layout (no
    /// encoding: the article rows are copied) next to it, then rename it
    /// over the old file. If the version-1 rows can't be converted (an
    /// older writer's file, an incomplete or foreign index) the index is
    /// deleted and rebuilt; on an I/O failure the version-1 index stays.
    private func convertDenseSidecar(_ dictId: String, reader: MDictReader) async {
        guard let start = convertibleSnapshot(dictId, reader: reader) else { return }
        let url = sidecarURL(for: dictId)
        let temp = ArticleIndexSidecar.conversionURL(for: url)
        let began = CFAbsoluteTimeGetCurrent()
        let result = await Task.detached(priority: .utility) {
            () -> Result<ArticleIndexHeader, ArticleIndexConversionError> in
            do {
                return .success(try ArticleIndexSidecar.writeCurrentFromDense(
                    source: url, destination: temp, reader: reader))
            } catch let error as ArticleIndexConversionError {
                return .failure(error)
            } catch {
                return .failure(.ioFailed("\(error)"))
            }
        }.value

        // The record must not have moved meanwhile (re-index requested,
        // content replaced, dictionary deleted): the converted file would
        // then describe nothing current.
        guard let now = convertibleSnapshot(dictId, reader: reader),
              now.lastUpdated == start.lastUpdated
        else {
            try? FileManager.default.removeItem(at: temp)
            debugLog("ArticleIndex \(dictId): record changed during the conversion; discarded it")
            return
        }
        switch result {
        case .success(let header):
            // The swap is a rename (atomic; a query that has the old file
            // mapped keeps reading it), done here on the main actor so no
            // state change can slip between the check above and the swap.
            do {
                try ArticleIndexSidecar.commitConversion(from: temp, to: url)
                let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
                debugLog("ArticleIndex \(dictId): converted the version-1 index (\(header.rowCount) articles, \(header.keyCount) keys) in \(String(format: "%.0f", ms)) ms")
            } catch {
                try? FileManager.default.removeItem(at: temp)
                print("❌ ArticleIndex \(dictId): converting the version-1 index failed, kept it: \(error)")
            }
        case .failure(let error) where error.requiresRebuild:
            try? FileManager.default.removeItem(at: temp)
            debugLog("ArticleIndex \(dictId): version-1 index can't be converted (\(error)); rebuilding")
            discardSidecar(dictId)
            backfillIfEnabled()
        case .failure(let error):
            try? FileManager.default.removeItem(at: temp)
            print("❌ ArticleIndex \(dictId): converting the version-1 index failed, kept it: \(error)")
        }
    }

    /// The record of a dict whose version-1 index may be converted now:
    /// still indexed, not being built, same reader. nil otherwise.
    private func convertibleSnapshot(_ dictId: String, reader: MDictReader) -> ArticleIndexRecordSnapshot? {
        guard ArticleIndexService.shared.hasRecord(for: dictId) else { return nil }
        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        guard snap.state == .indexed,
              !ArticleIndexDispatcher.shared.isInFlight(dictId),
              DictionaryService.shared.dict(id: dictId)?.reader === reader
        else { return nil }
        return snap
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
        guard let mdxHashHex = mdx.metadata.headerSHA256,
              let mdxHash = Self.hexToData(mdxHashHex),
              mdxHash.count == 32 else {
            return .success(.error(message: "MDX has no SHA256 (encrypted?)"))
        }
        // A file the reader refuses — not a sidecar, a version this build
        // doesn't know, a corrupt or truncated header — is never queried
        // and the writer starts it over (the launch check deletes it), so
        // the dict is simply not indexed. The same goes for a stale file
        // (model / MDX / dim mismatch) and for a partial, which covers
        // fewer keys than the dictionary has.
        guard let reader = try? ArticleIndexReader(sidecarURL: url),
              reader.validate(expectedModelSHA256: modelHash, expectedMDXHeaderSHA256: mdxHash) == .ok,
              Int(reader.header.keyCount) >= mdx.entryCount
        else {
            return .success(.notIndexed)
        }
        return .success(.indexed)
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

    /// Called just BEFORE a dictionary's MDX is replaced in place (a preset
    /// updated to a newer build). Stops a build that is running, deletes the
    /// sidecar and marks the dictionary `.notIndexed` (the user's
    /// preferences — Disabled section, order — are kept). Done before the
    /// swap so that a kill at any later point cannot leave an index of the
    /// old content looking valid: a rebuilt preset keeps its header hash,
    /// which is all the sidecar validation checks. Nothing is queued here;
    /// `handleDictImported` queues it once the new file has opened (and a
    /// launch backfill picks it up if the app was killed in between).
    func prepareForContentReplacement(_ dictId: String) {
        ArticleIndexDispatcher.shared.cancel(dictId)
        try? FileManager.default.removeItem(at: sidecarURL(for: dictId))
        ArticleIndexService.shared.setState(.notIndexed, for: dictId, indexedThrough: 0)
    }

    /// Called from `DictionaryStorageService.deleteDictionary(id:)` and
    /// `DictionaryService.handleRemoteChange(...)`'s remote-delete
    /// branch. Removes the dict's article sidecar (if any) from disk
    /// AND the catalog row from CoreData. Always runs, even when the
    /// feature is unavailable, since dead-data cleanup should be
    /// unconditional.
    func handleDictDeleted(_ dictId: String) {
        let url = sidecarURL(for: dictId)
        try? FileManager.default.removeItem(at: ArticleIndexSidecar.conversionURL(for: url))
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
