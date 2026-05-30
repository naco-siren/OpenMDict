//
//  ArticleIndexState.swift
//  OpenMDict-iOS  (M15 Phase 3.3)
//
//  Per-dict article-embedding indexing state, surfaced to UI via the
//  Coordinator. Mirrors the spec in docs/article-embeddings.md (Phase 3.3).
//
//  All user-facing strings (`localizedTitle` etc.) live in L10n —
//  Phase 3.4 wires those keys; for now they stub to English while we
//  validate the architecture.
//

import Foundation
import NaturalLanguage

/// One dict's current Phase-3 indexing status. Cases ordered by
/// "happy path" progression: notSupported (terminal) → pendingDownload
/// → notIndexed → indexing → indexed; with `paused` and `error` as
/// branches off the indexing state.
///
/// Note: `userExcluded` (Enabled vs Disabled section in the overview UI)
/// is ORTHOGONAL to this state. A disabled dict can still be `.indexed`
/// (sidecar on disk) — it just isn't queried by article search until
/// the user re-enables it. `setEnabled(false)` cancels an in-flight build
/// and transitions to `.paused(progress, indexedThrough)` so progress is
/// preserved across the section toggle.
enum ArticleIndexState: Sendable, Equatable {
    /// Dict's detected language has no embedding model in the catalog
    /// — feature can't be turned on for this dict.
    case notSupported(language: NLLanguage?)

    /// Catalog has a model for this language but it isn't downloaded
    /// yet (ODR fetch pending). User-actionable: tap to start download.
    case pendingDownload(language: NLLanguage, sizeBytes: Int)

    /// Eligible but no work done yet. Either user hasn't requested
    /// indexing OR app hasn't had a chance to backfill.
    case notIndexed

    /// Build in progress. `progress` ∈ [0, 1].
    case indexing(progress: Double, indexedThrough: Int)

    /// USER-paused only. Scheduler EXCLUDES `.paused` from eligibility —
    /// the user must explicitly resume (▶ button OR toggle off+on).
    /// `progress` reflects the on-disk partial so the cell can show
    /// "Paused at 23% · 12345/56789".
    ///
    /// Distinguished from gate-induced pauses (thermal / battery / memory)
    /// which DON'T touch persisted state — those just cancel the in-flight
    /// build; the dict reverts to `.indexing(progress)` (orphan, no live
    /// job) and the scheduler picks it back up when the gate clears.
    case paused(progress: Double, indexedThrough: Int)

    /// Sidecar present + valid against current MDX + model.
    case indexed

    /// Build attempted but failed. Human-readable error message for
    /// the user. Excluded from auto-eligibility; user retries via tap.
    case error(message: String)
}

/// Why a Phase 3 entry point can't proceed. Each case carries enough
/// context for the UI's `ContentUnavailableView` to render a meaningful
/// fallback (title + body + SF Symbol). Equatable so UI diffing in
/// SwiftUI / DiffableDataSource works. Conforms to `Error` so it can
/// be used as the failure type in `Result<T, ArticleIndexUnavailableReason>`.
enum ArticleIndexUnavailableReason: Sendable, Equatable, Error {

    /// iOS version is below the Phase 3 floor (iOS 26+). Transitively
    /// gates by hardware capability — A13 is the oldest chip eligible
    /// for iOS 26, so this check implicitly excludes A10/A12 and
    /// earlier. No separate device-model check needed.
    case osVersionTooOld(current: String, minimum: String)

    /// Detected dict language has no embedding model in our catalog.
    /// Carries the language for the message (e.g. "Hindi support
    /// coming later" — not Apple's universal Apple-Intelligence
    /// message, since this is a model-coverage issue, not an OS one).
    case languageNotSupported(NLLanguage)

    /// Model exists in the catalog but isn't downloaded yet. UI can
    /// surface a "Download N MB" CTA.
    case modelNotDownloaded(language: NLLanguage, sizeBytes: Int)

    /// Sidecar is being built right now. UI shows a progress bar
    /// instead of routing to the 全文 results view.
    case indexingInProgress(progress: Double)

    // MARK: - UI strings

    /// Localized title for `ContentUnavailableView`. Phase 3.4 swaps
    /// the literals for `L10n.SemanticUnavailable.{caseName}` keys.
    var localizedTitle: String {
        switch self {
        case .osVersionTooOld:
            return "Article search requires iOS 26+"
        case .languageNotSupported(let lang):
            return "Article search not available for \(lang.rawValue)"
        case .modelNotDownloaded:
            return "Language model needed"
        case .indexingInProgress:
            return "Indexing in progress"
        }
    }

    /// Body copy, may include format specifiers expanded from the
    /// case's associated values.
    var localizedMessage: String {
        switch self {
        case .osVersionTooOld(let current, let minimum):
            return "Your device is on iOS \(current). " +
                   "Article-content search needs iOS \(minimum) or newer."
        case .languageNotSupported(let lang):
            return "OpenMDict doesn't yet ship a language model for " +
                   "\(lang.rawValue). Use spelling or semantic scope instead."
        case .modelNotDownloaded(let lang, let sizeBytes):
            let mb = Double(sizeBytes) / 1024 / 1024
            return "OpenMDict needs to download a " +
                   "\(String(format: "%.0f", mb)) MB language model for " +
                   "\(lang.rawValue) before this scope can be used."
        case .indexingInProgress(let progress):
            return "Indexing this dictionary's articles for search — " +
                   "\(Int(progress * 100))% complete."
        }
    }

    /// SF Symbol name for the unavailable-view icon.
    var sfSymbol: String {
        switch self {
        case .osVersionTooOld:        return "iphone.gen3.slash"
        case .languageNotSupported:   return "character.bubble"
        case .modelNotDownloaded:     return "icloud.and.arrow.down"
        case .indexingInProgress:     return "hourglass"
        }
    }
}
