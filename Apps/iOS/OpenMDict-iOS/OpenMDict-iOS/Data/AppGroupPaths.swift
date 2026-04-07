//
//  AppGroupPaths.swift
//  OpenMDict-iOS
//
//  Shared App Group directory layout, compiled into **both** the main app
//  target and the Action Extension target.
//
//  Why this file exists (vs. folding it into DictionaryStorageService):
//  `DictionaryStorageService` and `DictionaryService` carry main-app state
//  (UIKit, MainActor, Combine, CoreData, a lot of state-management code)
//  that the short-lived, read-only Action Extension does not need. Rather
//  than adding 1200+ lines of unrelated service code to the extension
//  target, the path *constants* that both targets must agree on live here
//  in a tiny dependency-free helper.
//
//  Concrete file-layout logic (per-dict subdirectories, MDD/CSS/JS roots,
//  manifest locations, etc.) still lives in `DictionaryStorageService` —
//  only the handful of App Group roots that the extension needs directly
//  are exposed here.
//

import Foundation

/// App Group directory roots shared between the main app and extensions.
nonisolated enum AppGroupPaths {

    /// Root of the App Group shared container. Traps on fatal configuration
    /// error (missing entitlement). Same semantics as
    /// `DictionaryStorageService.rootDirectoryURL`'s guard.
    static var containerURL: URL {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier
        ) else {
            fatalError("App Group container unavailable — check Signing & Capabilities → App Groups")
        }
        return groupURL
    }

    /// Persistent sidecar index cache — `AppGroup/Library/Caches/MDXIndex/`.
    ///
    /// Sidecar `.idx` files are pure derived data: the slow-path MDX/MDD
    /// parser can always rebuild them. Lives in `Library/Caches` so iOS can
    /// evict it under disk pressure. Not iCloud-backed up, not CloudKit-synced.
    static var sidecarIndexCacheURL: URL {
        containerURL.appendingPathComponent("Library/Caches/MDXIndex", isDirectory: true)
    }
}
