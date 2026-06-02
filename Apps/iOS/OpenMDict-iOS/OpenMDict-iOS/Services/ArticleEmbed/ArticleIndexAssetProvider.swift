//
//  ArticleIndexAssetProvider.swift
//  OpenMDict-iOS  (M15 Phase 3.5 ③)
//
//  Wraps `NSBundleResourceRequest` for the article-embed model + vocab.
//  These two files (~80 MB compiled MLModel + 228 KB vocab) are tagged
//  `article-embed-model` as On-Demand Resources, so they DON'T ship in
//  the base IPA — the system downloads them lazily the first time a
//  dict actually starts indexing.
//
//  Lifecycle:
//
//    acquire() → if resources are local, returns immediately; if not,
//                triggers a download and resolves when complete. Holds
//                the request alive (and the resource reservation) until
//                release() is called. Multiple acquire() calls coalesce
//                onto the same request — subsequent jobs piggyback on
//                the already-loaded model.
//
//    release() → drops the request reference. The system MAY purge the
//                downloaded files under storage pressure after this; the
//                next acquire() re-acquires (instant if still local).
//                Called from the dispatcher's `evictEncoder` path so the
//                request matches the encoder's lifecycle.
//
//  Progress: a `progress` callback fires during download (KVO on the
//  request's NSProgress). Caller surfaces it to the UI via
//  Dispatcher.$downloadProgress → cell subtitle. Hops to MainActor before
//  invoking the callback because NSProgress KVO fires on an arbitrary
//  queue.
//
//  Extensions: the model files are NOT included in the Action / Share
//  Extension's `membershipExceptions` (confirmed in the pbxproj), so
//  ODR-only is safe — extensions don't try to load the encoder anyway.
//

import Combine
import Foundation

@MainActor
final class ArticleIndexAssetProvider {

    // MARK: - State machine

    /// Single source of truth for "is the model usable?".
    ///
    /// All UI / dispatcher decisions about overlay rendering, retry
    /// availability, and "can I start indexing?" read this. The previous
    /// design had VC + dispatcher each maintaining their own caches +
    /// running a separate `conditionallyBeginAccessingResources` probe;
    /// the probe occasionally hung indefinitely on the system's internal
    /// ODR reservation state (same layer as `beginAccessingResources`),
    /// which made the overlay get stuck in the pessimistic-loading
    /// branch forever. State machine eliminates the probe and the race.
    enum State: Sendable, Equatable {
        /// Have not attempted acquire yet. Initial state on every app
        /// launch (dispatcher singleton is per-process).
        case unknown
        /// Acquire in flight. `progress` is nil until NSProgress KVO
        /// emits the first fraction; the UI should render an
        /// indeterminate spinner during that window.
        case acquiring(progress: Double?)
        /// Successfully held — `Bundle.main.url(...)` resolves the model
        /// + vocab paths. `assets` is non-nil.
        case ready
        /// Last acquire attempt failed with a classified error. `retry()`
        /// can re-enter the state machine.
        case failed(ODRError)
    }

    @Published private(set) var state: State = .unknown

    /// Resolved URLs once `state == .ready`. Read by the dispatcher
    /// when it picks up a job. Nil in any other state.
    @Published private(set) var assets: Assets?

    /// In-flight `ensureAcquired` Task so concurrent callers (VC's
    /// `viewWillAppear` + dispatcher's `executeJob`) coalesce onto a
    /// single attempt rather than starting two `NSBundleResourceRequest`s.
    private var ensureTask: Task<Void, Never>?

    static let shared = ArticleIndexAssetProvider()

    /// The On-Demand Resource tag in Xcode's Resource Tags inspector.
    /// Both `all-MiniLM-L6-v2.mlpackage` and `vocab.txt` carry this tag.
    /// Set to "Download Only On Demand" so it's excluded from the
    /// initial install (saves ~80 MB from the base IPA).
    static let resourceTag = "article-embed-model"

    /// Resolved bundle URLs after the resources are locally accessible.
    /// The URLs are valid as long as the underlying NSBundleResourceRequest
    /// is held (i.e. between acquire and release).
    struct Assets: Sendable {
        let modelURL: URL
        let vocabURL: URL
    }

    enum AssetError: Error, CustomStringConvertible {
        /// `Bundle.main.url(forResource:withExtension:)` returned nil
        /// AFTER the ODR request reported success. This is functionally
        /// the same as `ODRError.fileNotFoundAfterDownload` but with the
        /// model-specific path baked into the message; we keep both
        /// representations because the model has a fixed tag/filename
        /// pair known at compile time.
        case missingFromBundle(String)
        /// Wraps any acquisition-time `Error` from
        /// `NSBundleResourceRequest.beginAccessingResources` through the
        /// shared `ODRError` classifier. UI binds to the inner `ODRError`
        /// for the localized title / message / SF Symbol.
        case downloadFailed(ODRError)

        var description: String {
            switch self {
            case .missingFromBundle(let what):
                return "Bundle resource missing after acquire: \(what)"
            case .downloadFailed(let err):
                return "Model download failed: \(err.errorDescription ?? String(describing: err))"
            }
        }
    }

    // Logging convention: `debugLog(...)` for info, `print("❌ …")` for
    // errors. Matches the rest of the codebase (PresetDictionaryService etc.).

    /// The currently-held resource request. Non-nil between a successful
    /// acquire and the matching release. Held so the OS keeps the
    /// downloaded files locally accessible.
    private var activeRequest: NSBundleResourceRequest?

    /// KVO observation on the active request's NSProgress. Held while a
    /// download is in flight so the caller's progress callback fires.
    /// Cleared after acquire returns (success or failure).
    private var progressObservation: NSKeyValueObservation?

    private init() {}

    // MARK: - Public API

    /// Ensure `state` reaches `.ready` or `.failed`. Idempotent: if a
    /// previous `ensureAcquired()` is still running, this awaits its
    /// completion instead of starting a second attempt. Concurrent
    /// callers (VC's `viewWillAppear` + dispatcher's `executeJob`)
    /// safely coalesce onto the same attempt.
    ///
    /// Doesn't throw — failures are surfaced via `state = .failed(odr)`.
    /// Callers that need to react to success/failure should observe
    /// `$state` rather than handle return values.
    func ensureAcquired() async {
        // Already settled — nothing to do.
        if case .ready = state {
            debugLog("AssetProvider.ensureAcquired: already ready, no-op")
            return
        }
        // In flight — piggyback on the existing task.
        if let existing = ensureTask {
            debugLog("AssetProvider.ensureAcquired: awaiting existing task")
            await existing.value
            return
        }
        debugLog("AssetProvider.ensureAcquired: starting fresh acquire from state=\(state)")
        state = .acquiring(progress: nil)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                let acquired = try await self.acquire(progress: { [weak self] frac in
                    // KVO is on an arbitrary queue; hop to MainActor to
                    // touch @Published state.
                    Task { @MainActor in
                        guard let self else { return }
                        if case .acquiring = self.state {
                            self.state = .acquiring(progress: frac)
                        }
                    }
                })
                self.assets = acquired
                self.state = .ready
                debugLog("AssetProvider.ensureAcquired: success → .ready")
            } catch let assetError as AssetError {
                self.assets = nil
                switch assetError {
                case .downloadFailed(let odr):
                    self.state = .failed(odr)
                case .missingFromBundle(let what):
                    self.state = .failed(.fileNotFoundAfterDownload(
                        tag: Self.resourceTag, filename: what
                    ))
                }
                print("❌ AssetProvider.ensureAcquired: failed \(assetError) → state=\(self.state)")
            } catch {
                self.assets = nil
                self.state = .failed(.unknown(underlyingDescription: error.localizedDescription))
                print("❌ AssetProvider.ensureAcquired: failed unexpectedly \(error) → state=\(self.state)")
            }
            self.ensureTask = nil
        }
        ensureTask = task
        await task.value
    }

    /// User-driven retry from the error overlay. Clears the failure
    /// state and re-enters `ensureAcquired()`. No-op when not in a
    /// failed state.
    func retry() async {
        guard case .failed = state else {
            debugLog("AssetProvider.retry: not in .failed state (current=\(state)), no-op")
            return
        }
        debugLog("AssetProvider.retry: clearing .failed, re-entering ensureAcquired")
        state = .unknown
        await ensureAcquired()
    }

    /// Manual ceiling on how long a single `acquire()` will wait on the
    /// system's `beginAccessingResources` before classifying it as
    /// `.temporarilyUnavailable` and bailing.
    ///
    /// `NSBundleResourceRequest` has no built-in timeout: in airplane
    /// mode the ODR layer hangs indefinitely waiting for reachability
    /// to come back, which leaves the UI stuck on "Downloading…" with
    /// no progress and no way to surface "No Internet" to the user.
    /// 45 s is long enough to absorb a slow cold-start (Apple's CDN
    /// initial DNS + TLS handshake can be ~5–10 s on cellular), short
    /// enough that the user reaches actionable error UI in under a
    /// minute rather than waiting on a hung system call.
    private static let acquireTimeoutSeconds: TimeInterval = 45

    /// Acquire the model + vocab URLs. If a previous acquire() is still
    /// held (no matching release), returns the same URLs immediately —
    /// subsequent indexing jobs after the first piggyback on the same
    /// reservation. If no request is held, creates one + awaits download.
    ///
    /// `progress` fires repeatedly during the download (fraction ∈ [0, 1]).
    /// **It is invoked from an arbitrary background queue** (NSProgress
    /// KVO threading model) — callers that want to touch MainActor state
    /// must hop themselves via `Task { @MainActor in … }`. The closure is
    /// `@Sendable` so Swift 6 accepts the cross-actor capture.
    ///
    /// Throws `AssetError.downloadFailed` if the download fails (network
    /// down, server unavailable, manual timeout) or `.missingFromBundle`
    /// if the download succeeded but the URLs still don't resolve
    /// (shouldn't happen with correct Xcode tagging).
    ///
    /// Failure paths ALWAYS call `request.progress.cancel()` +
    /// `request.endAccessingResources()` before throwing — without this,
    /// the system's internal reservation for the tag stays "in flight"
    /// even after our request is gone, and subsequent acquire attempts
    /// (across app relaunches!) hang waiting on the zombie reservation.
    /// This caused a hang on the second and third relaunch.
    func acquire(progress: (@Sendable (Double) -> Void)? = nil) async throws -> Assets {
        // If a prior acquire() is still held, just return the URLs.
        // The system has already loaded the resources locally; this
        // path is a fast resolve for "second + subsequent dicts in a
        // BG pass" (no redownload).
        if activeRequest != nil {
            debugLog("AssetProvider.acquire: fast path (activeRequest held)")
            let urls = try Self.resolveBundleURLs()
            // Keep state in sync — fast-path callers (e.g. a second
            // job after the first) won't re-trigger the state
            // machine but the @Published state should still reflect
            // .ready so VC overlays don't stale.
            self.assets = urls
            if case .ready = state {} else { state = .ready }
            return urls
        }

        let request = NSBundleResourceRequest(tags: [Self.resourceTag])
        // Urgent priority — the user just started an indexing job and
        // is actively waiting. The system uses this hint to allocate
        // higher download bandwidth.
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent

        // Hook up progress observation BEFORE beginAccessingResources
        // so the early "0%" tick reaches the caller. The KVO closure runs
        // on whatever thread NSProgress chose; we invoke the caller's
        // `progress` directly without an actor hop — `progress` is
        // `@Sendable` and the caller is responsible for any MainActor work.
        if let progress {
            progressObservation = request.progress.observe(
                \.fractionCompleted, options: [.initial, .new]
            ) { prog, _ in
                progress(prog.fractionCompleted)
            }
        }

        debugLog("Acquiring resource tag '\(Self.resourceTag)' (may trigger download, timeout=\(Self.acquireTimeoutSeconds)s)")

        // Run beginAccessingResources + a sleep-throws racer in a
        // ThrowingTaskGroup. Whichever finishes first wins; the other
        // is cancelled. The sleep-throws task supplies the manual
        // timeout that NSBundleResourceRequest itself doesn't have.
        //
        // `request` crosses the actor boundary into the unstructured
        // task group; Swift 6 strict concurrency flags this because
        // NSBundleResourceRequest isn't declared Sendable. The class
        // IS thread-safe per Apple's headers (the begin/end and the
        // progress KVO are all callable from any queue), so we
        // explicitly mark the local capture as `nonisolated(unsafe)`.
        nonisolated(unsafe) let unsafeRequest = request
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await unsafeRequest.beginAccessingResources()
                }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.acquireTimeoutSeconds * 1_000_000_000)
                    )
                    throw AssetTimeoutMarker()
                }
                // Await whichever completes first. Then cancel the other.
                // `group.next()` returns nil only after every task ends, so
                // this never throws nil — but Swift requires the !.
                try await group.next()!
                group.cancelAll()
            }
        } catch {
            // Failure path — release the system-side reservation BEFORE
            // throwing. Skipping this is what caused the zombie-tag hang
            // across relaunches: the OS thought the previous process was
            // still acquiring this tag, so new requests queued behind
            // the dead one indefinitely.
            request.progress.cancel()
            request.endAccessingResources()
            progressObservation = nil

            let classified: ODRError = (error is AssetTimeoutMarker)
                ? .temporarilyUnavailable
                : ODRError.classify(error)
            print("❌ Resource acquire failed: \(String(describing: error)) → classified=\(String(describing: classified))")
            throw AssetError.downloadFailed(classified)
        }
        progressObservation = nil
        activeRequest = request
        debugLog("Resources acquired")
        return try Self.resolveBundleURLs()
    }

    /// Sentinel thrown by the timeout task in `acquire`'s ThrowingTaskGroup
    /// so the catch block can distinguish "we timed out" from "the system
    /// raised an honest NSURL/NSCocoa error." The user-facing classification
    /// stays `.temporarilyUnavailable` either way.
    private struct AssetTimeoutMarker: Error {}

    /// Drop the held request. The system may purge the downloaded files
    /// under storage pressure after this. Idempotent — safe to call when
    /// nothing is held.
    ///
    /// **No callers in production code today.** An earlier design called
    /// this from `Dispatcher.evictEncoder` (the 60 s idle timer + memory
    /// warning paths) to "match the encoder lifetime", but that
    /// conflated two different resources:
    ///   - Encoder = ~80 MB RAM — eviction frees RAM pressure
    ///   - ODR file = ~43 MB disk — Apple's ODR layer purges it
    ///     automatically under storage pressure; no manual release needed
    /// Coupling them caused a nasty UX bug: every successful indexing
    /// pass was followed 60 s later by a forced state-machine reset
    /// (state → `.unknown`) which made the overview VC re-render the
    /// "Downloading Language Model" overlay even though the model was
    /// still on disk. Decoupled in this commit.
    ///
    /// Kept callable for future scenarios (explicit "free storage"
    /// affordance, master toggle off cleanup, etc.) but expect to
    /// audit those callsites — the state-machine reset to `.unknown`
    /// is correct for "user said 'forget this'", incorrect for "we're
    /// briefly low on RAM".
    func release() {
        guard let request = activeRequest else { return }
        debugLog("AssetProvider.release: releasing resource tag '\(Self.resourceTag)'")
        request.endAccessingResources()
        activeRequest = nil
        assets = nil
        state = .unknown
        progressObservation = nil
    }

    // MARK: - Internal

    /// Resolve the bundle URLs after the resource request reports success.
    /// `Bundle.main.url(forResource:withExtension:)` returns non-nil only
    /// for resources currently locally accessible.
    private static func resolveBundleURLs() throws -> Assets {
        guard let model = Bundle.main.url(
            forResource: "all-MiniLM-L6-v2", withExtension: "mlmodelc"
        ) else { throw AssetError.missingFromBundle("all-MiniLM-L6-v2.mlmodelc") }
        guard let vocab = Bundle.main.url(
            forResource: "vocab", withExtension: "txt"
        ) else { throw AssetError.missingFromBundle("vocab.txt") }
        return Assets(modelURL: model, vocabURL: vocab)
    }
}
