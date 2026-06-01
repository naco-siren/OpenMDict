//
//  ODRError.swift
//  OpenMDict-iOS
//
//  User-facing error type for On-Demand Resource acquisition failures.
//
//  Wraps the raw errors that `NSBundleResourceRequest.beginAccessingResources`
//  can throw — mostly `NSURLErrorDomain` (network) + `NSCocoaErrorDomain`
//  with `NSBundleErrorMinimum`-range codes (ODR-specific). The mapping is
//  in `classify(_:)`, a `nonisolated static` so it can run from anywhere.
//
//  Shape: a Sendable + Equatable + LocalizedError enum with cases keyed
//  to USER-VISIBLE situations (no network / data restricted / out of
//  space / server unreachable / etc.), each carrying its own SF Symbol +
//  localized title + localized message ready to drop into an
//  `EmptyStateView` (or any ContentUnavailableView surface).
//
//  Used by:
//    • `PresetDictionaryService.importFromODR` (rewrapped through
//      `PresetImportError.odr(ODRError)`)
//    • `ArticleIndexAssetProvider.acquire` (rewrapped through
//      `ArticleIndexAssetProvider.AssetError.downloadFailed(ODRError)`)
//
//  Note on `unknown`: the underlying `Error` is collapsed to its
//  `localizedDescription` at classify-time so the enum stays Sendable +
//  Equatable. The raw NSError domain/code is logged elsewhere; the
//  string here is what the UI shows.
//

import Foundation

public enum ODRError: LocalizedError, Sendable, Equatable {

    /// Device has no usable network connection. Maps from
    /// `NSURLErrorNotConnectedToInternet` / `NetworkConnectionLost` /
    /// `CannotConnectToHost`. User action: turn on Wi-Fi / cellular.
    case noNetwork

    /// App's cellular/wifi data use is disabled. Maps from
    /// `NSURLErrorDataNotAllowed` / `InternationalRoamingOff`.
    /// User action: Settings > Cellular > <app> ON.
    case dataNotAllowed

    /// Not enough free disk to receive the asset pack. Maps from
    /// `NSCocoaErrorDomain` code 4995 (`NSBundleOnDemandResourceOutOfSpaceError`).
    /// User action: free up storage and retry.
    case insufficientStorage

    /// Server / CDN couldn't be reached. Maps from `NSURLErrorTimedOut` /
    /// `CannotFindHost` / `BadServerResponse` / `DNSLookupFailed`. Usually
    /// transient. User action: wait, retry.
    case temporarilyUnavailable

    /// The ODR request reported success but `Bundle.main.url(forResource:
    /// withExtension:)` still returns nil for the file we expected. This
    /// is almost always a config bug (tag points to a file the build
    /// didn't include) — surfaces to the user as "couldn't download"
    /// but logs the tag + filename so we can debug.
    case fileNotFoundAfterDownload(tag: String, filename: String)

    /// Everything else. The original error's `localizedDescription` is
    /// captured so the user sees SOMETHING informative even when we
    /// don't recognize the code. Sendable + Equatable preserved by
    /// flattening to String here (storing the raw Error would lose both).
    case unknown(underlyingDescription: String)

    // MARK: - Classification

    /// Convert a raw `Error` from `NSBundleResourceRequest` (or anything
    /// else that throws an `NSError`-bridgeable failure) into one of
    /// these user-facing cases. Never throws. Defaults to `.unknown` for
    /// codes we haven't seen — those still surface a usable message via
    /// the underlying `localizedDescription`.
    nonisolated public static func classify(_ error: Error) -> ODRError {
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            switch ns.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorInternationalRoamingOff:
                return .noNetwork
            case NSURLErrorDataNotAllowed:
                return .dataNotAllowed
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorBadServerResponse,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable:
                return .temporarilyUnavailable
            default:
                return .unknown(underlyingDescription: ns.localizedDescription)
            }
        case NSCocoaErrorDomain:
            // ODR-specific codes are documented in the Foundation
            // headers as 4992..4999 ("NSBundleErrorMinimum" range).
            // 4995 = NSBundleOnDemandResourceOutOfSpaceError — the
            // only one users routinely hit.
            if ns.code == 4995 {
                return .insufficientStorage
            }
            return .unknown(underlyingDescription: ns.localizedDescription)
        default:
            return .unknown(underlyingDescription: ns.localizedDescription)
        }
    }

    // MARK: - UI binding

    /// SF Symbol name for the EmptyStateView icon.
    public var sfSymbol: String {
        switch self {
        case .noNetwork:                 return "wifi.slash"
        case .dataNotAllowed:            return "antenna.radiowaves.left.and.right.slash"
        case .insufficientStorage:       return "externaldrive.badge.exclamationmark"
        case .temporarilyUnavailable:    return "arrow.triangle.2.circlepath.icloud"
        case .fileNotFoundAfterDownload: return "questionmark.folder"
        case .unknown:                   return "exclamationmark.icloud"
        }
    }

    /// Short title for the EmptyStateView (or `errorDescription` if used
    /// purely as `LocalizedError`).
    public var localizedTitle: String {
        switch self {
        case .noNetwork:              return L10n.ODRError.noNetworkTitle
        case .dataNotAllowed:         return L10n.ODRError.dataNotAllowedTitle
        case .insufficientStorage:    return L10n.ODRError.insufficientStorageTitle
        case .temporarilyUnavailable: return L10n.ODRError.temporarilyUnavailableTitle
        case .fileNotFoundAfterDownload:
            return L10n.ODRError.fileNotFoundAfterDownloadTitle
        case .unknown:                return L10n.ODRError.unknownTitle
        }
    }

    /// Multi-line body copy for the EmptyStateView. May include the
    /// underlying description for `.unknown`.
    public var localizedMessage: String {
        switch self {
        case .noNetwork:              return L10n.ODRError.noNetworkMessage
        case .dataNotAllowed:         return L10n.ODRError.dataNotAllowedMessage
        case .insufficientStorage:    return L10n.ODRError.insufficientStorageMessage
        case .temporarilyUnavailable: return L10n.ODRError.temporarilyUnavailableMessage
        case .fileNotFoundAfterDownload(let tag, let filename):
            return L10n.ODRError.fileNotFoundAfterDownloadMessage(tag: tag, filename: filename)
        case .unknown(let desc):      return L10n.ODRError.unknownMessage(description: desc)
        }
    }

    // MARK: - LocalizedError

    public var errorDescription: String? { localizedTitle }
    public var failureReason: String? { localizedMessage }
}
