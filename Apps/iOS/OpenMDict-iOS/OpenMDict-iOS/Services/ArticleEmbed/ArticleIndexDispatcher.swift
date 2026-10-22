//
//  ArticleIndexDispatcher.swift
//  OpenMDict-iOS  (M15 Phase 3.4)
//
//  Single-job-at-a-time execution layer for article-embedding indexing.
//  Sits between the Coordinator (state/availability) and the underlying
//  `ArticleIndexWriter` (the actual encode + sidecar-write loop).
//
//  Job model:
//    - One running job at a time. The encoder is heavy to load and
//      heavy to run; parallel jobs would just thrash the ANE/GPU
//      scheduler with no throughput gain.
//    - Two priorities: `.interactive` (user tapped "Index now") and
//      `.background` (queued by handleDictImported / BGProcessingTask).
//      Interactive jobs preempt — if a background job is running and
//      the user requests an interactive one, the bg job is cancelled
//      and re-queued, the interactive job runs first.
//    - Cancellation is cooperative. The writer polls a per-article
//      `isCancelled`; we drive it by cancelling the detached build task
//      (`runningBuildTask`) — NOT `runningTask` — because Task.detached
//      doesn't inherit the parent's cancellation.
//
//  Encoder lifecycle:
//    - Lazy-loaded on first job, kept alive across jobs (CoreML's first
//      .mlpackage compile is multi-second; cold-loading per-dict would
//      add a huge overhead).
//    - Evicted on memory warning (cancel + drop, with a 30s cool-down
//      before the next reload), and on a 60s idle timer when the queue
//      drains. See "Resource gates" section.
//
//  Resource gates (Phase 3.5 ④):
//    - Thermal: `.serious`/`.critical` adds `.thermal` to `pauseReasons`;
//      transitions back to `.fair`/`.nominal` clear it. Pause is also
//      automatic across BGTask wake-ups (`runBackgroundPass` checks
//      `isPaused` in its loop) so the system doesn't sneak indexing
//      past a hot device.
//    - Low Power Mode: gates both background AND interactive — sustained
//      ANE/GPU encoding is the opposite of "low power" and the user
//      opted in.
//    - Memory warning: one-shot cancel + evict + 30s cooldown so the
//      kernel can reclaim before we'd want to reload an ~80 MB encoder.
//    - Idle eviction: 60s after the last job (queue empty AND no running)
//      the encoder is dropped. First post-eviction job pays ~1–2s reload,
//      which is amortized over the multi-minute encode that follows.
//
//  Pause semantics: entering a pause cancels the in-flight build (the
//  writer flushes a valid partial → resumable). The queue is intentionally
//  preserved so `isInFlight(_:)` stays true and the UI keeps showing the
//  rows. When pause lifts, `runNextIfIdle` drains.
//
//  Asset acquisition (still a stopgap):
//    - Model + vocab come from the bundle per the POC pattern. Anyone
//      building the iOS app must drop the files in via
//      `scripts/build-st-coreml.py` first. ODR (so the base IPA doesn't
//      carry the ~86 MB model) is still TODO.
//
//  Resumability + background:
//    - The writer is resumable: it auto-resumes from any partial at the
//      output path and atomic-checkpoints every N articles, so cancel /
//      preempt / BGTask-expiry interrupt cleanly (service keeps
//      `.indexing` at the checkpoint) and the next run continues.
//    - `runBackgroundPass(shouldStop:)` is the BGProcessingTask entry
//      point; `ArticleIndexBackgroundScheduler` owns the BGTask plumbing.
//

import Combine       // @Published pauseReasons for the overview UI
import Foundation
import OpenMDict     // ArticleEncoder + ArticleIndexWriter + ArticleIndexHeader
import OpenMDictKit  // MDict / MDicts — needed for DictionaryService.dict(...).reader
import UIKit         // UIApplication.didReceiveMemoryWarningNotification

@MainActor
final class ArticleIndexDispatcher {

    static let shared = ArticleIndexDispatcher()

    // Logging convention: `debugLog(...)` for info/diagnostic (gated
    // by VERBOSE_LOGGING build flag, zero release-cost), `print("❌ …")`
    // for errors that should surface in release builds too. Matches
    // the rest of the codebase (PresetDictionaryService etc.). Earlier
    // versions used os.Logger which doesn't show info-level logs in
    // the Xcode console by default — that confused debugging.

    /// Job priority. Interactive preempts background.
    enum Priority: Int, Comparable {
        case background = 0
        case interactive = 1
        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct PendingJob {
        let dictId: String
        let priority: Priority
    }

    /// Lazy-loaded encoder. Lives across jobs; reloaded when the compute
    /// profile changes (foreground GPU ↔ background CPU).
    private var encoder: ArticleEncoder?
    private var encoderProfile: ArticleEncoder.ComputeProfile?

    /// dictId currently running, plus the queue-drain wrapper task.
    private var runningDictId: String?
    private var runningTask: Task<Void, Never>?

    /// The detached task actually running the encode loop. Cancelling
    /// THIS (not `runningTask`) is what stops the writer: `Task.detached`
    /// does NOT inherit the parent's cancellation, so the writer's
    /// per-article `Task.isCancelled` poll only flips when we cancel the
    /// detached task directly. Held here so cancel() / preempt / the
    /// BGTask expiration handler can reach it.
    private var runningBuildTask: Task<ArticleIndexBuildOutcome, Error>?

    /// FIFO-within-priority pending queue.
    private var queue: [PendingJob] = []

    // MARK: - Resource gates (Phase 3.5 ④)

    /// Reasons indexing is currently paused. Non-empty == paused.
    /// - `.thermal` — `ProcessInfo.thermalState` is `.serious` or `.critical`.
    /// - `.lowPower` — Low Power Mode on (gates background AND interactive: a
    ///   long encode loop sustained at 100% CPU is the opposite of "low power",
    ///   and the user opted in).
    /// - `.memoryWarning` — short cool-down (30s) after a memory-warning so we
    ///   don't immediately reload the ~80 MB encoder that just got evicted.
    /// Why indexing is currently not advancing. Covers BOTH the global
    /// gate set (system conditions: thermal / Low Power / memory /
    /// storage) AND the per-dict user-initiated case.
    ///
    /// **Cases are declared in strength order — strongest (hardest to
    /// overcome) first, weakest (easiest to bypass) last.** This is also
    /// the display-priority order for `primaryReason(from:)` when
    /// multiple reasons fire concurrently: it walks `allCases` (which
    /// CaseIterable derives from declaration order) and picks the first
    /// one present. Reordering this enum changes the UX surface — keep
    /// "hard to overcome" on top.
    ///
    /// Architectural note: today the global `pauseReasons` set only ever
    /// contains the SYSTEM cases (`.thermal`, `.lowPower`, `.memoryWarning`).
    /// `.userInitiated` is "implicit" — it's represented by a dict's
    /// PERSISTED `.paused` state, not by membership in the global set
    /// (one user pause is per-dict, not a global condition). The case
    /// lives here so the enum is conceptually complete and so a future
    /// per-dict pause-reason field on `ArticleIndexRecordSnapshot` can
    /// reuse the same vocabulary. `.insufficientStorage` is forward-
    /// looking — when a storage-monitor lands, it'll join the global set
    /// just like thermal does, and the cell will surface it
    /// automatically via the gate-pause path.
    enum PauseReason: String, Sendable, CaseIterable {
        /// User tapped ⏸. The strongest reason — only the user's own
        /// explicit action can clear it (▶ button OR toggle off + on).
        /// Currently NOT emitted into the global set — represented per-
        /// dict by persisted state `.paused`. Reserved here so the enum
        /// is complete + future per-dict reason fields can reuse it.
        case userInitiated
        /// Free disk space below the safety threshold for resuming the
        /// encode. Strong — the user has to actively free up storage
        /// (delete files, offload apps). Forward-looking — storage-
        /// monitor + threshold check still TODO. Would join the global
        /// set like thermal does and auto-clear when space frees up.
        case insufficientStorage
        /// On-Demand Resource download in progress for the CoreML model +
        /// vocab tag (`article-embed-model`, ~80 MB). The cell renders
        /// the download percentage via `Dispatcher.downloadProgress`
        /// instead of `localizedLabel` (which has no progress info).
        /// Cleared as soon as `acquire` completes; the encoder loads,
        /// the build starts. Slots here (between insufficientStorage
        /// and memoryWarning) because the user CAN influence it (better
        /// network → faster) but mostly has to wait.
        case downloadingModel
        /// Recent memory warning — encoder evicted, brief cool-down
        /// active. System-managed but takes a moment to recover; user
        /// can speed it up by closing other apps.
        case memoryWarning
        /// Low Power Mode active. Weak — one toggle in Settings.app
        /// brings indexing right back.
        case lowPower
        /// Device thermal state is serious/critical. Weakest — the user
        /// just has to wait; iOS will clear the gate as soon as the
        /// SoC cools, no action needed.
        case thermal

        /// Full-sentence subtitle for the cell — e.g.
        /// "Paused until device cools down". Each case maps to its own
        /// complete phrase (not a short noun label stuffed into a
        /// "Paused (%@)" template) so the user immediately understands
        /// what's happening and what to expect.
        var localizedLabel: String {
            switch self {
            case .userInitiated:       return L10n.ArticleIndex.PauseReason.userInitiated
            case .insufficientStorage: return L10n.ArticleIndex.PauseReason.insufficientStorage
            case .downloadingModel:    return L10n.ArticleIndex.PauseReason.downloadingModelIndeterminate
            case .memoryWarning:       return L10n.ArticleIndex.PauseReason.memory
            case .lowPower:            return L10n.ArticleIndex.PauseReason.lowPower
            case .thermal:             return L10n.ArticleIndex.PauseReason.thermal
            }
        }

        /// Whether *entering* this pause should interrupt — and requeue —
        /// the dict whose build is currently running. True for genuine
        /// resource gates that must stop work mid-build. False ONLY for
        /// `.downloadingModel`: executeJob brackets its OWN
        /// `ensureAcquired()` call with add/remove of this reason (to keep
        /// a SECOND job from starting while the ODR download is in flight),
        /// and the SAME job continues right after — so requeuing there
        /// would re-enqueue the already-running dict and, because the model
        /// is usually already local, fire on every job and spin forever.
        var interruptsRunningBuild: Bool {
            switch self {
            case .downloadingModel:
                return false
            case .userInitiated, .insufficientStorage, .memoryWarning,
                 .lowPower, .thermal:
                return true
            }
        }
    }

    /// Pick the user-facing primary reason when multiple gates fire
    /// concurrently (e.g. thermal AND Low Power). Walks the enum's
    /// declaration order (= strength order, see PauseReason doc) via
    /// `allCases` and picks the strongest one present — keeps the
    /// subtitle concise and surfaces the hardest blocker first so the
    /// user doesn't try to resume only to be re-paused.
    static func primaryReason(from reasons: Set<PauseReason>) -> PauseReason? {
        PauseReason.allCases.first { reasons.contains($0) }
    }

    /// `@Published` so the overview UI can subscribe and reflect
    /// gate-pause state in real time — e.g. "Paused (thermal)" subtitle
    /// on the row that was running when thermal spiked. Persisted
    /// `.paused` state is user-pause only (sticky); gate-pause is
    /// transient and surfaced exclusively via this publisher.
    @Published private(set) var pauseReasons: Set<PauseReason> = []

    // Note: `downloadProgress` + `modelAcquireError` used to live here
    // as `@Published` properties for the overview VC to subscribe to.
    // They were moved to `ArticleIndexAssetProvider.state` (a proper
    // state machine — `.unknown`/`.acquiring(p)`/`.ready`/`.failed(odr)`)
    // so VC + Dispatcher both observe the SAME source of truth. The
    // previous design had three caches (VC's modelLocallyAvailable
    // probe + dispatcher's downloadProgress + dispatcher's
    // modelAcquireError) drifting independently, which is what caused
    // the relaunch-race and missing-log bugs seen on device.

    private var isPaused: Bool { !pauseReasons.isEmpty }

    private var pauseReasonsDescription: String {
        pauseReasons.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Pending idle-evict timer. Encoder is heavy (~80 MB CoreML model + buffers);
    /// holding it when the queue's been empty for a while wastes resident memory
    /// the kernel may dirty-page out under pressure anyway. The first job after
    /// eviction pays a ~1–2s reload, which is fine.
    private var idleEvictTask: Task<Void, Never>?

    /// How long to keep the encoder loaded after the queue drains. Short enough
    /// that successive small jobs don't churn (60 s ≫ one job's cold-load cost);
    /// long enough that "open settings → see indexing list" doesn't pay reload.
    /// `TimeInterval` (not `Duration`) — iOS 15 target.
    private static let idleEvictionDelaySeconds: TimeInterval = 60

    /// Memory-warning cool-down — how long we keep `.memoryWarning` in the
    /// pause set after the warning fires. Lets the kernel reclaim, then we
    /// resume. Shorter than idle eviction because we expect to come back.
    private static let memoryWarningCooldownSeconds: TimeInterval = 30

    /// `Task.sleep(nanoseconds:)` argument from a TimeInterval (seconds).
    private static func nanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds * 1_000_000_000))
    }

    private init() {
        registerResourceObservers()
    }

    // MARK: - Public API

    /// Enqueue a dict for indexing. Cheap call; actual work happens
    /// async. Observe progress via
    /// `ArticleIndexService.shared.snapshotPublisher(for: dictId)`.
    ///
    /// If the same dictId is already running:
    ///   - same priority → no-op
    ///   - new priority is higher → cancel the running job and
    ///     restart it at the new priority
    ///
    /// If the dictId is already queued, its priority is bumped to
    /// `max(existing, new)`.
    func enqueue(_ dictId: String, priority: Priority) {
        // Cheap availability gate. We don't return a Result here
        // because the call sites (handleDictImported / BGTask) don't
        // have a UI to surface failures — the silent no-op matches
        // the Coordinator's lifecycle-hook contract.
        guard ArticleIndexCoordinator.shared.isAvailable else {
            debugLog("enqueue(\(dictId)): feature unavailable, dropping")
            return
        }

        // Already running this dictId?
        if runningDictId == dictId {
            // Maybe promote priority. Pre-emption only triggers if the
            // currently-running job is `.background` and the new one
            // is `.interactive`.
            if priority > .background {
                debugLog("enqueue(\(dictId)): preempting running .background job for .interactive")
                // Cancel the in-flight build (flushes a valid partial) and
                // re-enqueue at .interactive. The runningTask continuation
                // nils runningDictId + drains the queue, resuming this dict
                // from its checkpoint at the higher priority.
                runningBuildTask?.cancel()
                queue.insert(PendingJob(dictId: dictId, priority: priority), at: 0)
            }
            return
        }

        // Dedupe in queue + promote priority if applicable.
        if let idx = queue.firstIndex(where: { $0.dictId == dictId }) {
            let existing = queue[idx]
            if priority > existing.priority {
                queue[idx] = PendingJob(dictId: dictId, priority: priority)
            }
            return
        }

        // New job.
        queue.append(PendingJob(dictId: dictId, priority: priority))
        runNextIfIdle()
    }

    /// Cancel a job. If queued, it's removed. If running, the in-flight
    /// build is cancelled — the writer flushes a valid partial sidecar
    /// (resumable from disk). State remains whatever the caller sets
    /// independently. Callers that want explicit "user paused" semantics
    /// MUST use `userPause(_:)` instead; this is the low-level "stop
    /// what's running" used by section toggles, master-toggle-off, etc.
    func cancel(_ dictId: String) {
        queue.removeAll(where: { $0.dictId == dictId })
        if runningDictId == dictId {
            debugLog("cancel(\(dictId)): cancelling in-flight build (partial kept on disk)")
            runningBuildTask?.cancel()
            // executeJob's .interrupted branch USED to persist `.indexing`
            // at the checkpoint — Phase 3.5 rework: state changes are now
            // the caller's responsibility (userPause / setEnabled). The
            // dispatcher only manages "is a job running."
        }
    }

    /// User-action pause for `dictId`. Cancels the in-flight build (if
    /// running) and transitions persisted state to `.paused` with the
    /// current checkpoint preserved. Scheduler EXCLUDES `.paused` from
    /// eligibility — the user must explicitly resume (▶ button OR toggle
    /// off + toggle on).
    ///
    /// Distinct from `cancel(_:)`: cancel is the low-level "stop running"
    /// used by section-toggle / master-toggle-off; userPause is the
    /// high-level "user said pause this indexing run, remember that."
    func userPause(_ dictId: String) {
        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        debugLog("userPause(\(dictId)): cancelling build + state → .paused at \(snap.indexedThrough)")
        // Persist .paused BEFORE cancelling. executeJob's .interrupted
        // branch no longer writes state, so ordering is fine either way,
        // but writing first makes the UI's $revision tick observable as
        // "now paused" before the spinner stops.
        ArticleIndexService.shared.setState(
            .paused, for: dictId, indexedThrough: snap.indexedThrough
        )
        queue.removeAll(where: { $0.dictId == dictId })
        if runningDictId == dictId {
            runningBuildTask?.cancel()
        }
    }

    /// Inverse of `userPause`. Transitions `.paused` (or anything stuck)
    /// back to `.notIndexed` with `indexedThrough` preserved (writer
    /// resumes from disk partial), then enqueues at `.interactive`
    /// priority so the scheduler picks it up immediately.
    func userResume(_ dictId: String) {
        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        debugLog("userResume(\(dictId)): state → .notIndexed at \(snap.indexedThrough), enqueue .interactive")
        ArticleIndexService.shared.setState(
            .notIndexed, for: dictId, indexedThrough: snap.indexedThrough
        )
        enqueue(dictId, priority: .interactive)
    }

    /// User tapped Retry on the EmptyStateView shown when the asset
    /// provider's state is `.failed`. Delegates to
    /// `AssetProvider.retry()` which clears the failure + re-enters
    /// `ensureAcquired()`. After that re-acquire completes (regardless
    /// of success/failure — observable via `provider.$state`), kicks
    /// the backfill so per-dict jobs come back through the dispatcher.
    func retryModelAcquire() {
        debugLog("Dispatcher.retryModelAcquire: delegating to AssetProvider.retry")
        Task {
            await ArticleIndexAssetProvider.shared.retry()
            ArticleIndexCoordinator.shared.backfillIfEnabled()
        }
    }

    /// Cancel all pending + running. Used by app-level shutdown,
    /// LocalDataResetService, "Pause all" toggles.
    func cancelAll() {
        debugLog("cancelAll: clearing \(self.queue.count) queued + running=\(self.runningDictId ?? "nil")")
        queue.removeAll()
        // Cancel the in-flight build; its .interrupted handling keeps the
        // partial + checkpoint. Running continuations nil out runningDictId.
        runningBuildTask?.cancel()
    }

    /// Cancel just the in-flight build, leaving the queue intact. The
    /// writer flushes a valid partial (→ resumable). Used by the BGTask
    /// expiration handler when the system reclaims background time.
    func cancelCurrentBuild() {
        runningBuildTask?.cancel()
    }

    /// Snapshot for the overview UI: what's running + what's queued.
    func currentlyRunning() -> String? { runningDictId }
    func pendingJobIds() -> [String] { queue.map(\.dictId) }

    /// True if `dictId` is the running job OR sitting in the pending queue.
    /// Lets callers tell "user-cancellable in-flight work" apart from a
    /// stale `.indexing` row (where the row says indexing but no job
    /// actually exists, e.g. after an app relaunch).
    func isInFlight(_ dictId: String) -> Bool {
        runningDictId == dictId || queue.contains { $0.dictId == dictId }
    }

    /// Current pause set as a stable, sorted, comma-separated string. Empty
    /// string when not paused. Public so the overview UI can show "paused
    /// (thermal,lowPower)" beside the master toggle.
    func pauseStateDescription() -> String { pauseReasonsDescription }

    // MARK: - Background pass (BGProcessingTask)

    /// Drive indexing for the BGProcessingTask handler: index every
    /// eligible dict (not yet fully indexed, not user-excluded), in
    /// user-priority order, serially. Returns when all are done or
    /// `shouldStop()` goes true (the BGTask is about to expire).
    ///
    /// Cancellation has two layers: `shouldStop()` prevents starting the
    /// NEXT dict, and the expiration handler also calls
    /// `cancelCurrentBuild()` to interrupt the in-flight one (which
    /// checkpoints a partial). Both are needed — an in-flight encode loop
    /// won't notice `shouldStop` on its own.
    func runBackgroundPass(shouldStop: @escaping @Sendable () -> Bool) async {
        guard ArticleIndexCoordinator.shared.isAvailable else { return }
        // Master "Article Search" toggle gate. The BGTask can be woken
        // by the system even if the user has since flipped this off —
        // honor that here so we don't sneak indexing past their opt-out.
        guard UserDefaults.standard.articleSearchEnabled else {
            debugLog("runBackgroundPass: master toggle off, skipping")
            return
        }
        // Eligibility = Enabled (not userExcluded) AND state ∈ {.notIndexed,
        // .indexing-orphan}. `.paused` is excluded — the user must
        // explicitly resume. `.error` is excluded — user retries via tap.
        // `.indexed` is excluded — already done.
        //
        // Sort: default-group `dictionaryIds` order (the canonical
        // "all dictionaries" custom order shared with the sidebar /
        // group editor). Falls back to `userPriorityOrder` only if the
        // default group is absent (defensive — should never happen).
        let snapshots = ArticleIndexService.shared.allSnapshots()
            .filter { !$0.userExcluded && Self.isSchedulerEligible($0.state) }
        let eligible = Self.sortByDefaultGroupOrder(snapshots).map(\.dictId)
        debugLog("runBackgroundPass: \(eligible.count) dict(s) eligible")
        for dictId in eligible {
            if shouldStop() {
                debugLog("runBackgroundPass: stopping before \(dictId) (deadline)")
                break
            }
            // Pause gates apply to BGTask passes too. If the system woke
            // us up but conditions degraded (thermal hot, user enabled
            // low-power mid-flight, jetsam-low), bail the pass — the
            // next BGTask wake-up (chained by `scheduleIfNeeded()`) or
            // foreground take-over will pick up from the checkpoint.
            if isPaused {
                debugLog("runBackgroundPass: paused (\(self.pauseReasonsDescription)), bailing before \(dictId)")
                break
            }
            runningDictId = dictId
            // CPU profile — the GPU is forbidden while backgrounded.
            await executeJob(dictId: dictId, profile: .background)
            runningDictId = nil
        }
        debugLog("runBackgroundPass: finished")
        scheduleIdleEvictionIfDone()
    }

    // MARK: - Internal queue drain

    private func runNextIfIdle() {
        guard runningDictId == nil else { return }
        // Don't start anything while paused — the queue holds (it's intentional
        // to keep `isInFlight(_:)` true so the UI keeps showing the row), and
        // we drain when pause lifts (`removePauseReason` → `runNextIfIdle`).
        if isPaused {
            debugLog("runNextIfIdle: paused (\(self.pauseReasonsDescription)), holding \(self.queue.count) job(s)")
            // Encoder is sitting idle — wind it down on the same grace timer.
            // First job after pause lifts pays a one-time reload (~1–2 s),
            // which is fine relative to a multi-minute encode.
            scheduleIdleEvictionIfDone()
            return
        }
        guard !queue.isEmpty else {
            // No work in flight, no pending — wind down the encoder after a
            // grace period so we don't sit on ~80 MB resident memory forever.
            scheduleIdleEvictionIfDone()
            return
        }
        cancelIdleEviction()  // we're about to use the encoder again

        // Pop highest-priority pending; ties broken by FIFO order.
        // Linear scan is fine — typical queue length < 20.
        var bestIdx = 0
        for (i, job) in queue.enumerated() where job.priority > queue[bestIdx].priority {
            bestIdx = i
        }
        let job = queue.remove(at: bestIdx)
        runningDictId = job.dictId
        debugLog("Starting job: dictId=\(job.dictId) priority=\(job.priority == .interactive ? "interactive" : "background")")

        runningTask = Task { [weak self] in
            // Foreground queue → GPU profile (fast). App-backgrounding
            // cancels the in-flight build; the BGTask path re-runs on CPU.
            await self?.executeJob(dictId: job.dictId, profile: .foreground)
            self?.runningDictId = nil
            self?.runningTask = nil
            self?.runNextIfIdle()
        }
    }

    // MARK: - Per-job execution

    /// Run the index-build pipeline for one dict. Resolves assets,
    /// loads encoder (lazy), opens the MDictReader, runs the writer
    /// with progress callbacks → service. On error or cancellation,
    /// updates service state accordingly.
    private func executeJob(dictId: String, profile: ArticleEncoder.ComputeProfile) async {
        // 1. Locate the MDictReader for this dict. `reader == nil` is a
        // TRANSIENT condition — the dict is still being mmap'd by
        // DictionaryService — NOT a persistent failure. Leave the
        // service state untouched so the next backfill retries cleanly.
        // (Earlier versions persisted `.error` here with errorMessage
        // "Dictionary not loaded"; if we hit this branch during the
        // dictionary-load window it would poison every dict's row in
        // CoreData and the user would see "Dictionary not loaded" on
        // every cell forever. `normalizeStaleNotLoadedErrors` in the
        // coordinator scrubs that legacy poison on launch.)
        guard let mdict = DictionaryService.shared.dict(id: dictId),
              let reader = mdict.reader
        else {
            debugLog("executeJob(\(dictId)): reader not ready yet, will retry on next backfill")
            return
        }

        // 2. Acquire model + vocab via On-Demand Resources. Go through
        //    the provider's `ensureAcquired()` so the VC observes the
        //    same state machine. `.downloadingModel` stays in the gate
        //    set during the wait (still useful for ordering — keeps
        //    `runNextIfIdle` from starting another job mid-download).
        addPauseReason(.downloadingModel)
        debugLog("executeJob(\(dictId)): awaiting AssetProvider.ensureAcquired")
        await ArticleIndexAssetProvider.shared.ensureAcquired()
        removePauseReason(.downloadingModel)

        let providerState = ArticleIndexAssetProvider.shared.state
        debugLog("executeJob(\(dictId)): provider state after ensureAcquired = \(providerState)")
        let assets: ArticleIndexAssetProvider.Assets
        switch providerState {
        case .ready:
            guard let acquired = ArticleIndexAssetProvider.shared.assets else {
                print("❌ executeJob(\(dictId)): provider .ready but assets == nil; bailing")
                return
            }
            assets = acquired
        case .failed(let odrError):
            // The provider already published `.failed(odrError)` to its
            // observers (overview VC, etc.). Per-dict state stays
            // untouched so the scheduler can re-pick this dict cleanly
            // once the user retries the model fetch.
            print("❌ executeJob(\(dictId)): acquire failed: \(odrError)")
            return
        case .unknown, .acquiring:
            // ensureAcquired completed but state isn't terminal? That's
            // a programming error in the provider — log and bail.
            print("❌ executeJob(\(dictId)): provider state non-terminal after ensureAcquired: \(providerState)")
            return
        }

        // Re-check post-acquire state — between starting the download and
        // here, several things can change:
        //   • user-pause via ⏸ (state → .paused)
        //   • section toggle off (state → .paused, userExcluded → true)
        //   • gate trigger (.thermal / .lowPower / .memoryWarning)
        //   • master toggle off (cancelAll runs, but our runningTask
        //     isn't cancelled today during acquire — defense in depth here)
        // If anything blocks us, bail. The dispatcher will re-evaluate on
        // the next eligibility tick.
        let postAcquireSnap = ArticleIndexService.shared.snapshot(for: dictId)
        if postAcquireSnap.state == .paused {
            debugLog("executeJob(\(dictId)): user paused during model download, bailing")
            return
        }
        if postAcquireSnap.userExcluded {
            debugLog("executeJob(\(dictId)): toggled to Disabled during download, bailing")
            return
        }
        if isPaused {
            debugLog("executeJob(\(dictId)): gate (\(self.pauseReasonsDescription)) fired during download, bailing")
            return
        }
        guard UserDefaults.standard.articleSearchEnabled else {
            debugLog("executeJob(\(dictId)): master toggle off during download, bailing")
            return
        }

        // 3. Encoder for this profile (foreground GPU / background CPU),
        // (re)loading if the profile changed since the last job.
        guard let encoder = ensureEncoder(
            profile: profile, modelURL: assets.modelURL, vocabURL: assets.vocabURL
        ) else {
            ArticleIndexService.shared.setState(
                .error, for: dictId,
                errorMessage: "Encoder load failed"
            )
            return
        }

        // 4. Mark indexing started. Preserve `indexedThrough` from the
        // current snapshot rather than resetting to 0 — `userResume` and
        // section-toggle paths just put the dict here with a checkpoint
        // (writer will resume from the on-disk partial), and clobbering
        // to 0 would briefly flash the UI to "0/N" before the writer's
        // first progress callback restores it.
        // `indexedThrough` and the progress total count MDX keys (entries),
        // aliases included — the writer walks every key, embeds only real
        // articles, and the key total is known without reading records.
        let prevIndexed = ArticleIndexService.shared.snapshot(for: dictId).indexedThrough
        let totalKeys = reader.entryCount
        debugLog("executeJob(\(dictId)): build starting from \(prevIndexed)/\(totalKeys)")
        ArticleIndexService.shared.setState(
            .indexing, for: dictId, indexedThrough: prevIndexed
        )

        // 5. Compute output sidecar path.
        let outURL = AppGroupPaths.articleSidecarCacheURL
            .appendingPathComponent("\(dictId).semantic.idx", isDirectory: false)
        try? FileManager.default.createDirectory(
            at: AppGroupPaths.articleSidecarCacheURL,
            withIntermediateDirectories: true
        )

        // 6. Build on a detached task. The writer is resumable +
        // checkpointing + cancellable: it auto-resumes from any partial
        // already at outURL, atomic-flushes a valid partial every N
        // articles, and polls isCancelled per-article (flushing + bailing
        // when the surrounding Task is cancelled).
        let writer = ArticleIndexWriter(
            modelURL: assets.modelURL,
            outputURL: outURL,
            progress: { [weak self] done, total, elapsed in
                guard let self else { return }
                // Hop to MainActor to write service state.
                Task { @MainActor in
                    // NB: `done` is the absolute key count (includes any
                    // keys already on disk from a resume), but
                    // `elapsed` is from this run's start, so `done/elapsed`
                    // reads artificially high for the first few seconds
                    // after a resume (e.g. 287/s, 166/s ... before
                    // settling). The number stabilizes after a minute.
                    let ips = elapsed > 0 ? Double(done) / elapsed : 0
                    debugLog("indexing \(dictId): \(done)/\(total) (\(String(format: "%.1f", elapsed))s, \(String(format: "%.1f", ips))/s)")
                    self.recordProgress(dictId: dictId, indexedThrough: Int32(done))
                }
            }
        )

        let buildTask = Task.detached { [reader, encoder] () -> ArticleIndexBuildOutcome in
            // The writer polls isCancelled per article. Task.detached does
            // NOT inherit the parent's cancellation, so we keep this task's
            // handle (runningBuildTask) and cancel IT in cancel() / preempt
            // / the BGTask expiration handler — that's what flips
            // Task.isCancelled here and makes the writer checkpoint + bail.
            try writer.build(
                reader: reader, encoder: encoder,
                isCancelled: { Task.isCancelled }
            )
        }
        runningBuildTask = buildTask
        let result = await buildTask.result
        runningBuildTask = nil

        // The dictionary's MDX was replaced while this ran (a preset updated
        // in place): what was built describes the old content. The header
        // hash cannot tell — a rebuilt preset keeps its header — so compare
        // the reader itself, discard the output and start over.
        if DictionaryService.shared.dict(id: dictId)?.reader !== reader {
            try? FileManager.default.removeItem(at: outURL)
            ArticleIndexService.shared.setState(.notIndexed, for: dictId, indexedThrough: 0)
            // `enqueue` ignores the id that is still running; queue it
            // directly — the running task's continuation starts it next.
            if UserDefaults.standard.articleSearchEnabled,
               !ArticleIndexService.shared.snapshot(for: dictId).userExcluded,
               !queue.contains(where: { $0.dictId == dictId }) {
                queue.append(PendingJob(dictId: dictId, priority: .background))
            }
            debugLog("executeJob(\(dictId)): content replaced during the build; discarded")
            return
        }

        // 7. Handle the outcome.
        switch result {
        case .success(.completed(let header)):
            let modelHashHex = header.modelSHA256.map { String(format: "%02x", $0) }.joined()
            let mdxHashHex = header.mdxHeaderSHA256.map { String(format: "%02x", $0) }.joined()
            ArticleIndexService.shared.setState(
                .indexed, for: dictId,
                indexedThrough: Int32(totalKeys),
                modelHash: modelHashHex,
                mdxHash: mdxHashHex
            )
            debugLog("executeJob(\(dictId)): indexed \(header.rowCount) articles (\(header.keyCount) keys) successfully")
        case .success(.interrupted(_, let through)):
            // cancel() / preempt / BGTask expiry / gate fired: the writer
            // flushed a valid partial. Phase 3.5 rework: state is the
            // CALLER's responsibility (userPause sets .paused;
            // section-toggle sets .paused; gate sets nothing — dict still
            // .notIndexed and the scheduler retries when gate clears).
            // We still need to record indexedThrough so the UI shows the
            // checkpointed progress; the persisted `state` is whatever the
            // caller left it.
            let prev = ArticleIndexService.shared.snapshot(for: dictId)
            ArticleIndexService.shared.setState(
                prev.state, for: dictId, indexedThrough: Int32(through)
            )
            debugLog("executeJob(\(dictId)): interrupted at \(through); state=\(prev.state.rawValue) (caller-owned)")
        case .failure(let error):
            // If WE cancelled (app backgrounding mid-GPU-predict, preempt,
            // user cancel), the on-disk partial is still valid — don't
            // surface a scary error; the persisted progress lets the next
            // run resume.
            if buildTask.isCancelled {
                debugLog("executeJob(\(dictId)): build cancelled mid-flight; checkpoint kept (\(String(describing: error)))")
            } else {
                ArticleIndexService.shared.setState(
                    .error, for: dictId,
                    errorMessage: "\(error)"
                )
                print("❌ executeJob(\(dictId)): build failed: \(String(describing: error))")
            }
        }
    }

    /// Progress callback handler — ONLY updates the checkpoint counter,
    /// never the state. The writer's progress callback hops to MainActor
    /// via `Task { @MainActor in ... }`, so a callback enqueued just
    /// before `userPause` ran can land AFTER `userPause`'s `setState(.paused)`.
    /// If we used `setState(.indexing, ...)` here, we'd undo the userPause
    /// (state flips back to .indexing) — see `Service.updateProgress`.
    private func recordProgress(dictId: String, indexedThrough: Int32) {
        ArticleIndexService.shared.updateProgress(indexedThrough, for: dictId)
    }

    /// Return an encoder configured for `profile`, (re)loading if the
    /// current one is nil or was built for a different profile. Dropping the
    /// old instance first keeps peak memory at a single model.
    ///
    /// In practice the profile is always CPU now — `effectiveProfile` maps
    /// every request to `.background` (`.cpuOnly`); the GPU path is disabled
    /// under the app-lifecycle GPU ban (see `effectiveProfile`).
    private func ensureEncoder(
        profile requestedProfile: ArticleEncoder.ComputeProfile,
        modelURL: URL, vocabURL: URL
    ) -> ArticleEncoder? {
        let profile = Self.effectiveProfile(requested: requestedProfile)
        if requestedProfile != profile {
            debugLog("ComputeProfile: \(String(describing: requestedProfile)) → \(String(describing: profile)) (GPU disabled — CPU only)")
        }
        if let e = encoder, encoderProfile == profile { return e }
        encoder = nil
        do {
            let e = try ArticleEncoder(
                modelPath: modelURL.path, vocabPath: vocabURL.path, profile: profile
            )
            encoder = e
            encoderProfile = profile
            debugLog("Encoder loaded (profile=\(profile == .foreground ? "foreground/GPU" : "background/CPU"))")
            return e
        } catch {
            print("❌ Encoder load failed: \(String(describing: error))")
            return nil
        }
    }

    /// Translate a requested compute profile into what we ACTUALLY run.
    ///
    /// **Always `.background` (== `.cpuOnly`). The GPU path is disabled.**
    ///
    /// `.foreground` would map to `.cpuAndGPU`, but iOS forbids submitting
    /// GPU command buffers the moment the app leaves the foreground-ACTIVE
    /// state — and that includes the merely-INACTIVE state (Control Center
    /// pulled down, an incoming call, the Face ID sheet, the app switcher,
    /// the lock transition), not just true background. A foreground GPU
    /// build there dies with
    /// kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted.
    /// Indexing is a minutes-long task the user inevitably interrupts that
    /// way, so a GPU build is fundamentally unreliable — on TestFlight it
    /// failed systematically across A14+ devices (every dict stuck at a red
    /// error needing a manual retry).
    ///
    /// CPU is immune to the lifecycle rule and runs uninterrupted whether
    /// the app is active or inactive. The small MiniLM-L6 model's GPU
    /// advantage was never even confirmed: A13 measured GPU SLOWER (45 vs
    /// 187 articles/s); A14+ keeping GPU was an untested assumption. So we
    /// trade a hypothetical speedup for real stability and always use CPU.
    /// (`DeviceChipInfo.prefersCPUForeground` is now moot for this path but
    /// stays for other callers.)
    private static func effectiveProfile(
        requested: ArticleEncoder.ComputeProfile
    ) -> ArticleEncoder.ComputeProfile {
        .background
    }

    /// Scheduler eligibility predicate for a persisted state. Centralized
    /// so `Coordinator.backfillIfEnabled` + `runBackgroundPass` + the
    /// BG scheduler's `scheduleIfNeeded` all use the same rule.
    ///
    /// - `.notIndexed`: yes — never tried (or paused-then-resumed via the
    ///   resume path that sets back to `.notIndexed`).
    /// - `.indexing`: yes — orphan from a prior session (a crashed/killed
    ///   build left this). The writer auto-resumes from the on-disk
    ///   partial. (Live indexing is gated separately by `runningDictId`.)
    /// - `.paused`: NO — user said stop. Resume is explicit.
    /// - `.indexed`: NO — done.
    /// - `.error`: NO — user retries via tap.
    static func isSchedulerEligible(_ state: ArticleIndexRecordSnapshot.PersistedState) -> Bool {
        switch state {
        case .notIndexed, .indexing:
            return true
        case .paused, .indexed, .error:
            return false
        }
    }

    /// Sort snapshots by the default group's `dictionaryIds` order (the
    /// canonical "all dictionaries" order shared with the sidebar / group
    /// editor). Dicts not in the default group go LAST, in their original
    /// `userPriorityOrder` (defensive fallback). The default group is
    /// populated from `allDictionaries` at startup so this matches the
    /// user's expectations from the rest of the app.
    static func sortByDefaultGroupOrder(_ snaps: [ArticleIndexRecordSnapshot])
        -> [ArticleIndexRecordSnapshot]
    {
        guard let group = DictionaryService.shared.defaultGroup else {
            // No default group (shouldn't happen post-launch) — fall back
            // to the old userPriorityOrder sort so behavior degrades
            // gracefully rather than randomizing.
            return snaps.sorted { $0.userPriorityOrder < $1.userPriorityOrder }
        }
        // Build lookup: dictId → position in the canonical order.
        var orderIndex: [String: Int] = [:]
        for (i, id) in group.dictionaryIds.enumerated() { orderIndex[id] = i }
        let sentinel = Int.max
        return snaps.sorted { a, b in
            let ia = orderIndex[a.dictId] ?? sentinel
            let ib = orderIndex[b.dictId] ?? sentinel
            if ia != ib { return ia < ib }
            // Same position (both not-in-group) — fall back to userPriorityOrder
            return a.userPriorityOrder < b.userPriorityOrder
        }
    }

    // (Asset resolution moved to ArticleIndexAssetProvider for the ODR
    // path. The dispatcher no longer touches Bundle.main directly.)

    // MARK: - Resource-gate observers

    /// Register thermal / Low Power Mode / memory-warning observers + sync
    /// initial state. Called from `init`. Observers live for the lifetime of
    /// the singleton; no removal because `static let shared` never deinits.
    private func registerResourceObservers() {
        let nc = NotificationCenter.default
        // ProcessInfo.thermalStateDidChangeNotification fires on an
        // arbitrary thread — hop to MainActor before touching `self`.
        nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleThermalChange() }
        }
        nc.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePowerStateChange() }
        }
        // Memory warnings are delivered on the main thread already, but
        // hop via Task anyway for closure-isolation correctness.
        nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMemoryWarning() }
        }
        // Sync initial state — we might launch into a hot device or
        // low-power mode and need to start paused.
        handleThermalChange()
        handlePowerStateChange()
    }

    private func handleThermalChange() {
        let state = ProcessInfo.processInfo.thermalState
        let shouldPause = (state == .serious || state == .critical)
        debugLog("thermalState=\(Self.thermalStateName(state)) → paused=\(shouldPause)")
        if shouldPause {
            addPauseReason(.thermal)
        } else {
            removePauseReason(.thermal)
        }
    }

    private func handlePowerStateChange() {
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        debugLog("lowPowerMode=\(on)")
        if on {
            addPauseReason(.lowPower)
        } else {
            removePauseReason(.lowPower)
        }
    }

    /// Memory warning: cancel in-flight build (writer flushes a partial,
    /// service keeps `.indexing` at the checkpoint, next run resumes),
    /// evict the encoder (~80 MB of MLModel + buffers), and add a
    /// short cool-down to the pause set so we don't immediately reload
    /// the encoder the kernel just had to reclaim around. After the
    /// cool-down expires, normal drain resumes.
    private func handleMemoryWarning() {
        debugLog("Memory warning: cancelling current build + evicting encoder + cool-down")
        cancelCurrentBuild()
        evictEncoder(reason: "memory warning")
        addPauseReason(.memoryWarning)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanos(Self.memoryWarningCooldownSeconds))
            self?.removePauseReason(.memoryWarning)
        }
    }

    private func addPauseReason(_ reason: PauseReason) {
        let wasNotPaused = !isPaused
        let (inserted, _) = pauseReasons.insert(reason)
        guard inserted else { return }
        debugLog("Pause +\(reason.rawValue) (set=\(self.pauseReasonsDescription))")
        if wasNotPaused {
            // Just entered paused. For a genuine resource gate (thermal /
            // lowPower / memory / storage), put the running dict back on the
            // queue BEFORE cancelling its build, so it stays in-flight
            // across the pause — the cell shows the gate reason instead of
            // an orphaned "to be indexed" row, and the gate-clear drain
            // (removePauseReason → runNextIfIdle) resumes it automatically
            // without the user toggling the dict off and back on. Then
            // cancel the build so its partial + checkpoint stick.
            //
            // `.downloadingModel` is gated out (interruptsRunningBuild ==
            // false): it's executeJob's own ensureAcquired() bracket, the
            // same job continues right after, and requeuing it there would
            // double-enqueue the running dict and spin forever.
            if reason.interruptsRunningBuild {
                requeueRunningJob()
            }
            cancelCurrentBuild()
        }
    }

    /// Re-insert the currently-running dict at the front of the queue.
    /// Called when a gate pause is about to cancel its build. Without it the
    /// dict is lost: it was already popped off the queue when it started
    /// running, and the running task's continuation nils `runningDictId`
    /// once the build cancels — leaving an orphan `.indexing` row that's
    /// neither running nor queued. `isInFlight` then reports false, so the
    /// overview cell renders "to be indexed" (no resume button) AND the
    /// gate-clear `runNextIfIdle` finds an empty queue and resumes nothing,
    /// forcing the user to toggle the dict off and back on. Front-insert +
    /// `.interactive` so it's first to resume. No-op if nothing's running.
    private func requeueRunningJob() {
        guard let dictId = runningDictId else { return }
        guard !queue.contains(where: { $0.dictId == dictId }) else { return }
        queue.insert(PendingJob(dictId: dictId, priority: .interactive), at: 0)
        debugLog("Requeued running job \(dictId) at queue front for gate-pause resume")
    }

    private func removePauseReason(_ reason: PauseReason) {
        let wasPaused = isPaused
        guard pauseReasons.remove(reason) != nil else { return }
        debugLog("Pause -\(reason.rawValue) (set=\(self.pauseReasonsDescription))")
        if wasPaused && !isPaused {
            // Conditions back to normal — drain whatever's queued. If
            // nothing is queued, this is a no-op except for scheduling
            // the next idle eviction.
            runNextIfIdle()
        }
    }

    /// Evict the lazy-loaded encoder. Idempotent — no-op when nothing's loaded.
    /// Caller is responsible for ensuring no in-flight build is using it
    /// (which is why we always `cancelCurrentBuild` before evicting).
    ///
    /// Encoder eviction frees ~80 MB of RAM (MLModel + buffers). It does
    /// NOT release the ODR resource reservation — those are two different
    /// resources:
    ///   - encoder is in RAM, eviction frees RAM pressure
    ///   - ODR file (~43 MB) is on disk; iOS purges it automatically
    ///     under storage pressure, no manual release needed.
    /// An earlier version of this method called
    /// `AssetProvider.release()` here, which flipped the provider state
    /// machine to `.unknown` and made the overview VC re-render the
    /// "Downloading Language Model" overlay 60 s after every successful
    /// indexing pass — even though the model was still locally available.
    /// That bug showed up on device. Don't reintroduce it.
    private func evictEncoder(reason: String) {
        guard encoder != nil else { return }
        debugLog("Encoder eviction: \(reason) (was profile=\(self.encoderProfile == .foreground ? "foreground/GPU" : "background/CPU"))")
        encoder = nil
        encoderProfile = nil
    }

    /// Start the idle-eviction timer if (and only if) no job is in-flight
    /// and we still hold an encoder. Called from the places where work just
    /// drained: `runNextIfIdle` (queue-empty AND paused branches) and the
    /// end of `runBackgroundPass`. `queue.isEmpty` is intentionally NOT
    /// required — a paused dispatcher with queued work also benefits from
    /// dropping the encoder (the first job after pause lift reloads it).
    private func scheduleIdleEvictionIfDone() {
        guard runningDictId == nil, encoder != nil else { return }
        cancelIdleEviction()
        idleEvictTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanos(Self.idleEvictionDelaySeconds))
            guard let self, !Task.isCancelled else { return }
            // Re-check on wake — a job could have started in the sleep
            // window. (cancelIdleEviction handles the normal case but
            // belt + suspenders for any path we missed.)
            guard self.runningDictId == nil else { return }
            self.evictEncoder(reason: "idle for \(Int(Self.idleEvictionDelaySeconds))s")
        }
    }

    private func cancelIdleEviction() {
        idleEvictTask?.cancel()
        idleEvictTask = nil
    }

    /// Stable string for thermal state (rawValue is just an Int).
    private static func thermalStateName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
