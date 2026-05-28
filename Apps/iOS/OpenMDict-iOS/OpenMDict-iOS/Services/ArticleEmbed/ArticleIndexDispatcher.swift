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
//    - Cancellation is cooperative via `Task.isCancelled`. The writer
//      checks at each per-article iteration (Phase 3.5 task — current
//      ArticleIndexWriter is single-shot, doesn't check).
//
//  Encoder lifecycle:
//    - Lazy-loaded on first job, kept alive across jobs (CoreML's first
//      .mlpackage compile is multi-second; cold-loading per-dict would
//      add a huge overhead).
//    - Evicted on memory warning or after a quiet period (Phase 3.5).
//
//  Asset acquisition (Phase 3.4 stopgap):
//    - Model + vocab come from the bundled `POC-Resources/` per the
//      POC pattern. Anyone building the iOS app must drop the files
//      in via `scripts/build-st-coreml.py` first (same as the POC).
//    - Phase 3.5 replaces this with ODR (on-demand-resources) so the
//      shipped app doesn't include the 86 MB model in its base IPA.
//
//  Resumability:
//    - NOT in Phase 3.4. The writer is single-shot — kill it mid-run
//      and progress is lost; next attempt restarts from 0. Phase 3.5
//      refactors the writer for append + checkpoint, at which point
//      the dispatcher persists `indexedThrough` via the service and
//      next runs pick up where they left off.
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

    /// Lazy-loaded encoder. Lives across jobs.
    private var encoder: ArticleEncoder?

    /// dictId currently running, plus its Task handle for cancellation.
    private var runningDictId: String?
    private var runningTask: Task<Void, Never>?

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
                runningTask?.cancel()
                runningDictId = nil
                runningTask = nil
                queue.insert(PendingJob(dictId: dictId, priority: priority), at: 0)
                runNextIfIdle()
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

    /// Cancel a job. If it's currently running, the task is cancelled
    /// (the current ArticleIndexWriter is single-shot — Phase 3.4 — so
    /// cancellation only takes effect at the NEXT writer; in-flight
    /// builds run to completion or until the iOS background-task
    /// timer kills the process. Phase 3.5's resumable writer fixes
    /// this).
    func cancel(_ dictId: String) {
        queue.removeAll(where: { $0.dictId == dictId })
        if runningDictId == dictId {
            log.info("cancel(\(dictId)): cancelling running job")
            runningTask?.cancel()
            runningDictId = nil
            runningTask = nil
            // Re-mark service state — if writer was mid-progress we
            // want to revert it from .indexing to .notIndexed.
            ArticleIndexService.shared.setState(
                .notIndexed, for: dictId, indexedThrough: 0
            )
            runNextIfIdle()
        }
    }

    /// Cancel all pending + running. Used by app-level shutdown,
    /// LocalDataResetService, "Pause all" toggles.
    func cancelAll() {
        log.info("cancelAll: clearing \(self.queue.count) queued + running=\(self.runningDictId ?? "nil")")
        queue.removeAll()
        if let id = runningDictId {
            runningTask?.cancel()
            ArticleIndexService.shared.setState(
                .notIndexed, for: id, indexedThrough: 0
            )
        }
        runningDictId = nil
        runningTask = nil
    }

    /// Snapshot for the overview UI: what's running + what's queued.
    func currentlyRunning() -> String? { runningDictId }
    func pendingJobIds() -> [String] { queue.map(\.dictId) }

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
            await self?.executeJob(dictId: job.dictId)
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
    private func executeJob(dictId: String) async {
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

        // 2. Locate the bundled model + vocab. Phase 3.5 swaps this
        // for ODR; for now we use the POC bundle pattern.
        guard let (modelURL, vocabURL) = Self.resolveAssets() else {
            log.error("executeJob(\(dictId)): model/vocab missing from bundle")
            ArticleIndexService.shared.setState(
                .error, for: dictId,
                errorMessage: "CoreML model not bundled — see POC-Resources/"
            )
            return
        }

        // 3. Load encoder if needed.
        if encoder == nil {
            do {
                encoder = try ArticleEncoder(modelPath: modelURL.path, vocabPath: vocabURL.path)
                log.info("Encoder loaded for dispatcher")
            } catch {
                log.error("Encoder load failed: \(String(describing: error))")
                ArticleIndexService.shared.setState(
                    .error, for: dictId,
                    errorMessage: "Encoder load failed: \(error)"
                )
                return
            }
        }
        guard let encoder = self.encoder else { return }

        // 4. Mark indexing started.
        let totalArticles = reader.entryCount
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
            progress: { [weak self] done, _, _ in
                guard let self else { return }
                // Hop to MainActor to write service state.
                Task { @MainActor in
                    self.recordProgress(dictId: dictId, indexedThrough: Int32(done))
                }
            }
        )

        let result: Result<ArticleIndexBuildOutcome, Error> = await Task.detached { [reader, encoder] in
            do {
                // Cooperative cancellation: the writer polls this per
                // article, flushing a valid partial sidecar before
                // returning .interrupted so the next run resumes.
                let outcome = try writer.build(
                    reader: reader, encoder: encoder,
                    isCancelled: { Task.isCancelled }
                )
                return .success(outcome)
            } catch {
                return .failure(error)
            }
        }.value

        // 7. Handle result. A cancelled Task means cancel()/preempt
        // fired — the writer already flushed a valid partial to disk and
        // those paths own the service state, so don't fight them. The
        // on-disk partial lets the next run resume.
        if Task.isCancelled {
            log.info("executeJob(\(dictId)): cancelled; partial checkpoint left on disk for resume")
            return
        }
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
            // Writer reported interruption without the Task being
            // cancelled — not expected today (isCancelled only wraps
            // Task.isCancelled), but persist progress as .indexing so a
            // future run resumes from the checkpoint.
            ArticleIndexService.shared.setState(
                .indexing, for: dictId, indexedThrough: Int32(through)
            )
            log.info("executeJob(\(dictId)): interrupted at \(through), checkpoint saved")
        case .failure(let error):
            ArticleIndexService.shared.setState(
                .error, for: dictId,
                errorMessage: "\(error)"
            )
            log.error("executeJob(\(dictId)): build failed: \(String(describing: error))")
        }
    }

    private func recordProgress(dictId: String, indexedThrough: Int32) {
        // Cheap write; only check thermal here too — Phase 3.5 will
        // add proper thermal cancellation.
        ArticleIndexService.shared.setState(
            .indexing, for: dictId,
            indexedThrough: indexedThrough
        )
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
