//
//  ArticleIndexBackgroundScheduler.swift
//  OpenMDict-iOS  (M15)
//
//  BGProcessingTask plumbing for article-embedding indexing. Owns the
//  three BGTaskScheduler touchpoints:
//
//    1. register()         — at launch, install the task handler. Apple
//                            requires this to finish before
//                            didFinishLaunching returns, for every
//                            identifier in Info.plist's
//                            BGTaskSchedulerPermittedIdentifiers.
//    2. scheduleIfNeeded() — submit a request when there's pending work
//                            (called when the app backgrounds).
//    3. handle(task:)      — when the system launches the task, drive
//                            ArticleIndexDispatcher.runBackgroundPass
//                            until done or the task is about to expire.
//
//  Power policy: requiresExternalPower = true. Encoding a whole
//  dictionary through CoreML is heavy (ANE/GPU + sustained CPU); gating
//  on "plugged in" keeps it off the user's battery. requiresNetwork
//  Connectivity = false — indexing is fully on-device.
//
//  The encode loop is resumable + checkpointing (see ArticleIndexWriter),
//  so a task that runs out of time leaves a valid partial sidecar and the
//  next launch / next BGTask picks up where it left off.
//
//  ⚠️ Actor-isolation footgun (round two — DO NOT undo without reading).
//
//  The iOS 26 SDK invokes BGTaskScheduler's launchHandler AND
//  BGTask.expirationHandler from its own private serial queue
//  (`com.apple.BGTaskScheduler.<id>` in the stack trace) despite the
//  SDK's @MainActor signatures. Swift 6 runtime checks isolation at
//  CLOSURE ENTRY: if a closure is inferred @MainActor and the system
//  calls it off-Main, `_swift_task_checkIsolatedSwift` fires BEFORE any
//  body code runs and the process SIGTRAPs in
//  `_dispatch_assert_queue_fail`. So hopping inside the body is too
//  late — the closure can't be @MainActor in the first place.
//
//  The way out: every closure we hand to BGTaskScheduler must be
//  inferred as nonisolated. A closure literal inherits the isolation of
//  its ENCLOSING function, so:
//    • `register()` is `nonisolated` → its launchHandler closure is
//      nonisolated.
//    • `installExpirationHandler(on:pass:)` is `nonisolated static` →
//      the expirationHandler closure assigned inside it is nonisolated.
//    • `shared` / `log` / `taskID` are `nonisolated static` so those
//      closures can reach them without hopping (and so the static-let
//      initializer for `shared` can run from a nonisolated context).
//    • `init()` is `nonisolated` so `nonisolated static let shared`
//      can call it.
//
//  Inside the (nonisolated) closures we hop to MainActor explicitly via
//  `Task { @MainActor in ... }` for any dispatcher / scheduler work;
//  `nonisolated(unsafe) let unsafeTask = task` carries the BGTask
//  reference across the actor edge (it's documented thread-safe).
//

import BackgroundTasks
import Foundation

@MainActor
final class ArticleIndexBackgroundScheduler {

    // shared / taskID are `nonisolated static` so they're reachable
    // from the BGTaskScheduler-queue closures. See file header.
    nonisolated static let shared = ArticleIndexBackgroundScheduler()

    // Logging: `debugLog(...)` (nonisolated global) is safe to call from
    // the BGTaskScheduler private queue too — no actor isolation, no
    // SIGTRAP risk like a @MainActor closure would have. See file header
    // for the actor-isolation footgun this avoids. Production errors
    // surface via `print("❌ …")`.

    nonisolated static let taskID = AppIdentifiers.articleIndexBGTaskID

    /// The in-flight BGTask's `runBackgroundPass` Task, while it's running.
    /// `sceneWillEnterForeground` cancels it via `cancelCurrentPassAndWait()`
    /// so foreground take-over routes the next jobs through the FG queue
    /// (GPU profile). Cleared by the BGTask completion Task in `handle(task:)`.
    private var runningPass: Task<Void, Never>?

    private nonisolated init() {}

    /// Register the BGTask handler. Call once from
    /// `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// `nonisolated` is load-bearing: closures inherit the enclosing
    /// function's isolation, and if this were @MainActor the launchHandler
    /// closure would also be @MainActor and SIGTRAP when BGTaskScheduler
    /// calls it from its own queue. See file header.
    nonisolated func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskID, using: nil
        ) { rawTask in
            // Inferred nonisolated — runs safely on BGTaskScheduler's queue.
            // Do NOT touch any @MainActor state synchronously here; hop via
            // the Task below.
            guard let task = rawTask as? BGProcessingTask else {
                // setTaskCompleted may itself be @MainActor-isolated under
                // iOS 26; the only safe action from this queue is bail.
                return
            }
            nonisolated(unsafe) let unsafeTask = task
            Task { @MainActor in
                ArticleIndexBackgroundScheduler.shared.handle(task: unsafeTask)
            }
        }
        debugLog("Registered BGTask handler: \(Self.taskID)")
    }

    /// Submit a processing request IF indexing work is pending and the
    /// feature is available. Coalesced by the system, so calling on every
    /// background transition is fine.
    func scheduleIfNeeded() {
        guard ArticleIndexCoordinator.shared.isAvailable,
              UserDefaults.standard.articleSearchEnabled else { return }
        // Match `ArticleIndexDispatcher.isSchedulerEligible`: only enqueue
        // a BGTask when there's actual work the scheduler will pick up.
        // `.paused` no longer counts (user must explicitly resume).
        let hasPending = ArticleIndexService.shared.allSnapshots()
            .contains { !$0.userExcluded && ArticleIndexDispatcher.isSchedulerEligible($0.state) }
        guard hasPending else {
            debugLog("scheduleIfNeeded: nothing pending, not submitting")
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.taskID)
        request.requiresExternalPower = true        // heavy — charge only
        request.requiresNetworkConnectivity = false // fully on-device
        do {
            try BGTaskScheduler.shared.submit(request)
            debugLog("Submitted background indexing request")
        } catch {
            // Common on the simulator (BGTaskScheduler unsupported) and
            // when the per-app pending-request cap is hit — non-fatal.
            print("❌ BGTask submit failed: \(String(describing: error))")
        }
    }

    /// Drive the dispatcher's background pass to completion, or until the
    /// task is about to expire; then reschedule if work remains. Runs on
    /// MainActor — register()'s closure hops here via Task.
    private func handle(task: BGProcessingTask) {
        debugLog("BGTask launched — starting background indexing pass")

        let pass = Task { @MainActor in
            await ArticleIndexDispatcher.shared.runBackgroundPass(
                shouldStop: { Task.isCancelled }
            )
        }
        self.runningPass = pass

        // Install the expirationHandler from a NONISOLATED context so the
        // closure itself is inferred nonisolated. Doing this synchronously
        // here (inside @MainActor handle) would inherit @MainActor and
        // re-trip the same actor-check trap.
        Self.installExpirationHandler(on: task, pass: pass)

        nonisolated(unsafe) let unsafeTask = task
        Task { @MainActor in
            _ = await pass.value
            self.runningPass = nil
            // Chain another request if anything is still unfinished.
            self.scheduleIfNeeded()
            unsafeTask.setTaskCompleted(success: !pass.isCancelled)
            debugLog("BGTask completed (interrupted=\(pass.isCancelled))")
        }
    }

    /// Cancel the currently-running BGTask pass (if any) and wait for it
    /// to actually exit. Used by `SceneDelegate.sceneWillEnterForeground`
    /// to take over from background work: without this, a sync
    /// `backfillIfEnabled` call immediately after returns to a dispatcher
    /// whose `runningDictId` is still pinned to the BG job (the pass
    /// hasn't released it yet), so the enqueue no-ops and the build
    /// stays on the CPU encoder.
    func cancelCurrentPassAndWait() async {
        guard let pass = runningPass else { return }
        debugLog("cancelCurrentPassAndWait: foreground take-over")
        pass.cancel()
        ArticleIndexDispatcher.shared.cancelCurrentBuild()
        _ = await pass.value
        // runningPass may already be nil here — the completion Task in
        // handle(task:) races us to clear it. Either way the pass is done.
    }

    /// `nonisolated` so the expirationHandler closure assigned inside is
    /// inferred nonisolated. BGTaskScheduler calls expirationHandler from
    /// the same private queue as launchHandler, so the same actor-isolation
    /// trap applies — don't undo this. See file header.
    nonisolated private static func installExpirationHandler(
        on task: BGProcessingTask, pass: Task<Void, Never>
    ) {
        nonisolated(unsafe) let unsafeTask = task
        unsafeTask.expirationHandler = {
            // Inferred nonisolated (enclosing func is nonisolated).
            // ONLY nonisolated APIs synchronously (Task.cancel + Self.log);
            // hop for the @MainActor dispatcher call.
            debugLog("BGTask expiring — interrupting pass")
            pass.cancel()
            Task { @MainActor in
                ArticleIndexDispatcher.shared.cancelCurrentBuild()
            }
        }
    }
}
