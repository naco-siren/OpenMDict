//
//  LocalDataResetService.swift
//  OpenMDict-iOS
//
//  Handles local file system cleanup for the iCloud reset flow.
//  Deletes dictionary files and MDD cache from the App Group container.
//

import Foundation

final class LocalDataResetService {

    static let shared = LocalDataResetService()

    private init() {}

    // MARK: - Dictionary Files

    /// Delete all dictionary files from `AppGroup/Library/Dictionaries/`
    /// and recreate the empty directory.
    func deleteAllDictionaryFiles() {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier
        ) else { return }

        let dictDir = groupURL.appendingPathComponent(
            "Library/Dictionaries", isDirectory: true
        )
        try? FileManager.default.removeItem(at: dictDir)
        try? FileManager.default.createDirectory(
            at: dictDir, withIntermediateDirectories: true
        )

        debugLog("🗑️ Deleted all dictionary files")
    }

    // MARK: - MDD Cache

    /// Delete the MDD extraction cache from `AppGroup/Library/Caches/MDD/`
    /// and recreate the empty directory.
    func deleteMDDCache() {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier
        ) else { return }

        let cacheDir = groupURL.appendingPathComponent(
            "Library/Caches/MDD", isDirectory: true
        )
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true
        )

        debugLog("🗑️ Deleted MDD cache")
    }

    // MARK: - MDX Sidecar Index Cache

    /// Delete every persistent sidecar index file under
    /// `AppGroup/Library/Caches/MDXIndex/` and recreate the empty directory.
    /// Sidecar files are pure derived data, so this is always safe — the
    /// next dictionary load will simply rebuild them on the slow path.
    func deleteMDXIndexCache() {
        let cacheDir = DictionaryStorageService.shared.sidecarIndexCacheURL
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true
        )
        debugLog("🗑️ Deleted MDX sidecar index cache")
    }
}
