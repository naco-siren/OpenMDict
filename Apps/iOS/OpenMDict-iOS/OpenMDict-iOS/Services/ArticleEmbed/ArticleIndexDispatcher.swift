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
//    - Eviction on memory warning / quiet period is still TODO.
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

import Foundation
import OpenMDict     // ArticleEncoder + ArticleIndexWriter + ArticleIndexHeader
import OpenMDictKit  // MDict / MDicts — needed for DictionaryService.dict(...).reader
import os.log

@MainActor
final class ArticleIndexDispatcher {

    static let shared = ArticleIndexDispatcher()

    private let log = Logger(
        subsystem: "io.github.naco-siren.openmdict",
        category: "ArticleIndexDispatcher"
    )

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

    private init() {}

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
            log.debug("enqueue(\(dictId)): feature unavailable, dropping")
            return
        }

        // Already running this dictId?
        if runningDictId == dictId {
            // Maybe promote priority. Pre-emption only triggers if the
            // currently-running job is `.background` and the new one
            // is `.interactive`.
            if priority > .background {
                log.info("enqueue(\(dictId)): preempting running .background job for .interactive")
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
    /// build is cancelled — the writer flushes a valid partial sidecar and
    /// the service keeps `.indexing` at that checkpoint, so a later run
    /// (re-enqueue or BGTask) resumes rather than restarting from 0. To
    /// fully stop AND hide a dict, use `setUserExcluded(true)` instead.
    func cancel(_ dictId: String) {
        queue.removeAll(where: { $0.dictId == dictId })
        if runningDictId == dictId {
            log.info("cancel(\(dictId)): cancelling in-flight build (partial kept for resume)")
            runningBuildTask?.cancel()
            // executeJob's .interrupted branch persists progress; the
            // runningTask continuation nils runningDictId + drains the queue.
        }
    }

    /// Cancel all pending + running. Used by app-level shutdown,
    /// LocalDataResetService, "Pause all" toggles.
    func cancelAll() {
        log.info("cancelAll: clearing \(self.queue.count) queued + running=\(self.runningDictId ?? "nil")")
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
            log.info("runBackgroundPass: master toggle off, skipping")
            return
        }
        let eligible = ArticleIndexService.shared.allSnapshots()
            .filter { $0.state != .indexed && !$0.userExcluded }
            .sorted { $0.userPriorityOrder < $1.userPriorityOrder }
            .map(\.dictId)
        log.info("runBackgroundPass: \(eligible.count) dict(s) eligible")
        for dictId in eligible {
            if shouldStop() {
                log.info("runBackgroundPass: stopping before \(dictId) (deadline)")
                break
            }
            runningDictId = dictId
            // CPU profile — the GPU is forbidden while backgrounded.
            await executeJob(dictId: dictId, profile: .background)
            runningDictId = nil
        }
        log.info("runBackgroundPass: finished")
    }

    // MARK: - Internal queue drain

    private func runNextIfIdle() {
        guard runningDictId == nil else { return }
        guard !queue.isEmpty else { return }

        // Pop highest-priority pending; ties broken by FIFO order.
        // Linear scan is fine — typical queue length < 20.
        var bestIdx = 0
        for (i, job) in queue.enumerated() where job.priority > queue[bestIdx].priority {
            bestIdx = i
        }
        let job = queue.remove(at: bestIdx)
        runningDictId = job.dictId
        log.info("Starting job: dictId=\(job.dictId) priority=\(job.priority == .interactive ? "interactive" : "background")")

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
        // 1. Locate the MDictReader for this dict.
        guard let mdict = DictionaryService.shared.dict(id: dictId),
              let reader = mdict.reader
        else {
            log.error("executeJob(\(dictId)): dict not loaded or has no reader, skipping")
            ArticleIndexService.shared.setState(
                .error, for: dictId,
                errorMessage: "Dictionary not loaded"
            )
            return
        }

        // 2. Locate the bundled model + vocab. (ODR is a follow-up; for
        // now we use the POC bundle pattern.)
        guard let (modelURL, vocabURL) = Self.resolveAssets() else {
            log.error("executeJob(\(dictId)): model/vocab missing from bundle")
            ArticleIndexService.shared.setState(
                .error, for: dictId,
                errorMessage: "CoreML model not bundled — see POC-Resources/"
            )
            return
        }

        // 3. Encoder for this profile (foreground GPU / background CPU),
        // (re)loading if the profile changed since the last job.
        guard let encoder = ensureEncoder(profile: profile, modelURL: modelURL, vocabURL: vocabURL) else {
            ArticleIndexService.shared.setState(
                .error, for: dictId,
                errorMessage: "CoreML model not bundled or encoder load failed"
            )
            return
        }

        // 4. Mark indexing started.
        let totalArticles = reader.entryCount
        log.info("executeJob(\(dictId)): build starting, \(totalArticles) articles to encode")
        ArticleIndexService.shared.setState(
            .indexing, for: dictId, indexedThrough: 0
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
            modelURL: modelURL,
            outputURL: outURL,
            progress: { [weak self] done, total, elapsed in
                guard let self else { return }
                // Hop to MainActor to write service state.
                Task { @MainActor in
                    // NB: `done` is the absolute row count (includes any
                    // articles already on disk from a resume), but
                    // `elapsed` is from this run's start, so `done/elapsed`
                    // reads artificially high for the first few seconds
                    // after a resume (e.g. 287/s, 166/s ... before
                    // settling). The number stabilizes after a minute.
                    let ips = elapsed > 0 ? Double(done) / elapsed : 0
                    self.log.info("indexing \(dictId): \(done)/\(total) (\(String(format: "%.1f", elapsed))s, \(String(format: "%.1f", ips))/s)")
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

        // 7. Handle the outcome.
        switch result {
        case .success(.completed(let header)):
            let modelHashHex = header.modelSHA256.map { String(format: "%02x", $0) }.joined()
            let mdxHashHex = header.mdxHeaderSHA256.map { String(format: "%02x", $0) }.joined()
            ArticleIndexService.shared.setState(
                .indexed, for: dictId,
                indexedThrough: Int32(totalArticles),
                modelHash: modelHashHex,
                mdxHash: mdxHashHex
            )
            log.info("executeJob(\(dictId)): indexed \(header.articleCount) articles successfully")
        case .success(.interrupted(_, let through)):
            // cancel() / preempt / BGTask expiry fired: the writer flushed
            // a valid partial. Keep .indexing at the checkpoint so the next
            // run (re-enqueue or BGTask) resumes instead of restarting.
            ArticleIndexService.shared.setState(
                .indexing, for: dictId, indexedThrough: Int32(through)
            )
            log.info("executeJob(\(dictId)): interrupted at \(through); checkpoint saved for resume")
        case .failure(let error):
            // If WE cancelled (app backgrounding mid-GPU-predict, preempt,
            // user cancel), the on-disk partial is still valid — don't
            // surface a scary error; the persisted progress lets the next
            // run resume.
            if buildTask.isCancelled {
                log.info("executeJob(\(dictId)): build cancelled mid-flight; checkpoint kept (\(String(describing: error)))")
            } else {
                ArticleIndexService.shared.setState(
                    .error, for: dictId,
                    errorMessage: "\(error)"
                )
                log.error("executeJob(\(dictId)): build failed: \(String(describing: error))")
            }
        }
    }

    private func recordProgress(dictId: String, indexedThrough: Int32) {
        ArticleIndexService.shared.setState(
            .indexing, for: dictId,
            indexedThrough: indexedThrough
        )
    }

    /// Return an encoder configured for `profile`, (re)loading if the
    /// current one is nil or was built for a different profile. Foreground
    /// uses GPU (fast); background uses CPU (the GPU is forbidden while the
    /// app is backgrounded). Dropping the old instance first keeps peak
    /// memory at a single model.
    ///
    /// **Chip-tier downgrade**: on chips where the small-model GPU path is
    /// slower than CPU (A13 et al — see `DeviceChipInfo.prefersCPUForeground`),
    /// a foreground request is transparently mapped to `.background`
    /// (`.cpuOnly`). The caller still asks for `.foreground`; we just don't
    /// dispatch through the GPU when we know it loses.
    private func ensureEncoder(
        profile requestedProfile: ArticleEncoder.ComputeProfile,
        modelURL: URL, vocabURL: URL
    ) -> ArticleEncoder? {
        let profile = Self.effectiveProfile(requested: requestedProfile)
        if requestedProfile != profile {
            log.info("ComputeProfile: \(String(describing: requestedProfile)) → \(String(describing: profile)) on \(DeviceChipInfo.gpuName ?? "?") (GPU loses to CPU for this model)")
        }
        if let e = encoder, encoderProfile == profile { return e }
        encoder = nil
        do {
            let e = try ArticleEncoder(
                modelPath: modelURL.path, vocabPath: vocabURL.path, profile: profile
            )
            encoder = e
            encoderProfile = profile
            log.info("Encoder loaded (profile=\(profile == .foreground ? "foreground/GPU" : "background/CPU"))")
            return e
        } catch {
            log.error("Encoder load failed: \(String(describing: error))")
            return nil
        }
    }

    /// Translate a requested compute profile into what we actually run.
    /// `.background` is identity (the GPU-in-background ban is a kernel
    /// rule, can't override). `.foreground` gets downgraded to `.background`
    /// on chips where the GPU is slower than CPU for our small MiniLM-L6
    /// model (see `DeviceChipInfo.prefersCPUForeground`).
    private static func effectiveProfile(
        requested: ArticleEncoder.ComputeProfile
    ) -> ArticleEncoder.ComputeProfile {
        guard requested == .foreground else { return requested }
        return DeviceChipInfo.prefersCPUForeground ? .background : .foreground
    }

    /// Find the bundled model + vocab. Returns nil if either is
    /// missing. Same lookup logic as the POC.
    private static func resolveAssets() -> (model: URL, vocab: URL)? {
        guard let model = Bundle.main.url(
            forResource: "all-MiniLM-L6-v2", withExtension: "mlmodelc"
        ), let vocab = Bundle.main.url(
            forResource: "vocab", withExtension: "txt"
        ) else { return nil }
        return (model, vocab)
    }
}
