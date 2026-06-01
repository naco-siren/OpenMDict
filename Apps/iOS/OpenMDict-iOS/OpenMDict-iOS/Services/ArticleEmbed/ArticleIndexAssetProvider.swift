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

import Foundation
import os.log

@MainActor
final class ArticleIndexAssetProvider {

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

    private let log = Logger(
        subsystem: "io.github.naco-siren.openmdict",
        category: "ArticleIndexAssetProvider"
    )

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

    /// Is the resource tag currently downloaded + locally available?
    /// Cheap, doesn't trigger a download. Useful for the master toggle
    /// to show "Model not downloaded yet" hint before the user starts
    /// the first indexing job.
    func resourcesAvailableLocally() async -> Bool {
        let probe = NSBundleResourceRequest(tags: [Self.resourceTag])
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            probe.conditionallyBeginAccessingResources { available in
                if available {
                    // We weren't planning to hold this — end it now. The
                    // separate acquire() call will create its own held
                    // request when the encoder actually needs the URLs.
                    probe.endAccessingResources()
                }
                cont.resume(returning: available)
            }
        }
    }

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
    /// down, server unavailable, etc.) or `.missingFromBundle` if the
    /// download succeeded but the URLs still don't resolve (shouldn't
    /// happen with correct Xcode tagging).
    func acquire(progress: (@Sendable (Double) -> Void)? = nil) async throws -> Assets {
        // If a prior acquire() is still held, just return the URLs.
        // The system has already loaded the resources locally; this
        // path is a fast resolve for "second + subsequent dicts in a
        // BG pass" (no redownload).
        if activeRequest != nil {
            return try Self.resolveBundleURLs()
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

        log.info("Acquiring resource tag '\(Self.resourceTag)' (may trigger download)")
        do {
            try await request.beginAccessingResources()
        } catch {
            progressObservation = nil
            let classified = ODRError.classify(error)
            log.error("Resource acquire failed: \(String(describing: error)) → classified=\(String(describing: classified))")
            throw AssetError.downloadFailed(classified)
        }
        progressObservation = nil
        activeRequest = request
        log.info("Resources acquired")
        return try Self.resolveBundleURLs()
    }

    /// Drop the held request. The system may purge the downloaded files
    /// under storage pressure after this. Idempotent — safe to call when
    /// nothing is held. Dispatcher calls this from `evictEncoder` so the
    /// asset lifetime matches the encoder's.
    func release() {
        guard let request = activeRequest else { return }
        log.info("Releasing resource tag '\(Self.resourceTag)'")
        request.endAccessingResources()
        activeRequest = nil
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
