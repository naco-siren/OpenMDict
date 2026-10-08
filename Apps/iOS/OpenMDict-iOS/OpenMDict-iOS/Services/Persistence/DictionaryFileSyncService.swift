//
//  DictionaryFileSyncService.swift
//  OpenMDict-iOS
//
//  Manages dictionary file synchronisation via manual CloudKit API
//  (CKRecord + CKAsset).
//
//  CoreData structured data (metadata, groups, bookmarks, history)
//  syncs automatically via NSPersistentCloudKitContainer.
//  Dictionary *files* (MDX/MDD/CSS/JS) are too large for that path,
//  so this service uses the CloudKit private database directly:
//
//    Record type: "DictionaryFile"
//    Record naming: "dict-{dictId}-{fileName}"
//    Fields:
//      dictId        — String  (SHA256 header hash = dictionary ID)
//      fileName      — String  (original filename, e.g. "MyDict.mdx")
//      fileAsset     — CKAsset (raw file — no archive compression)
//      fileHash      — String  (SHA256 content hash; empty for manifest/mdx)
//      fileSizeBytes — Int64
//      uploadedAt    — Date
//
//  Per-file sync: each file in the dictionary directory gets its own
//  CKRecord.  Adding/removing a CSS only uploads/deletes that one record
//  plus the manifest.  Remote devices diff the manifest to determine
//  which files to download/delete.
//
//  Life cycle:
//    Import → upload each file as CKRecord → mark synced
//    Remote metadata arrives + no local files → download manifest → fetch files
//    Resource add/remove → upload single file + manifest → remote diffs + fetches
//    Delete → remove all CKRecords for dictionary
//
//  Size guard: individual files > 500 MB are marked "too large".
//

import CloudKit
import Combine
import CoreData
import Foundation
import OpenMDictKit

// MARK: - Sync Status Enum

/// CloudKit file-sync status stored in DictionaryMetadataRecord.cloudSyncStatus.
nonisolated enum CloudSyncStatus: Int16, Sendable {
    case pending  = 0   // Not yet uploaded / download not started
    case synced   = 1   // Files present in CloudKit
    case tooLarge = 2   // Exceeds 500 MB — local only
    case error    = 3   // Upload/download failed
}

// MARK: - Service

final class DictionaryFileSyncService {

    static let shared = DictionaryFileSyncService()

    // MARK: - CloudKit

    private let container = CKContainer(
        identifier: AppIdentifiers.cloudKitContainerID
    )
    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    /// CloudKit Record Type name for per-file dictionary uploads.
    private let recordType = "DictionaryFile"

    /// Maximum single-file size we are willing to upload (bytes).
    /// CKAsset technically allows ~50 GB per asset, but we cap uploads to
    /// protect the user's iCloud storage quota. Shared with the manifest
    /// reconciliation rules so counts/merges agree on what is syncable.
    private let maxAssetBytes: Int64 = ManifestSyncRules.maxSyncableBytes

    /// Dictionaries with a download in progress. The remote-change pipeline
    /// can request the same dictionary several times while one download is
    /// still running; the first caller wins, the rest are told to wait.
    private var inFlightDownloads = Set<String>()

    /// Maximum records per CKModifyRecordsOperation batch.
    private let maxBatchSize = 400

    // MARK: - Published State

    /// Per-dictionary sync progress.  Key = dictId.
    @Published private(set) var syncProgress: [String: SyncProgress] = [:]

    nonisolated enum SyncProgress: Sendable {
        case uploading(fractionCompleted: Double)
        case downloading(fractionCompleted: Double)
        case idle
    }

    // MARK: - Storage Helper

    private var storage: DictionaryStorageService { DictionaryStorageService.shared }

    private init() {}

    // MARK: - Reset

    /// Cancel tracking of any in-flight sync operations.
    /// Called during iCloud nuclear reset.
    func cancelAllOperations() {
        syncProgress.removeAll()
        inFlightDownloads.removeAll()
    }

    /// Whether a download for this dictionary is currently in progress.
    func isDownloading(_ dictId: String) -> Bool {
        inFlightDownloads.contains(dictId)
    }

    // MARK: - Record Name Helpers

    /// Build a CKRecord name for a file in a dictionary.
    /// Format: "dict-{dictId}-{fileName}"
    private func recordName(dictId: String, fileName: String) -> String {
        "dict-\(dictId)-\(fileName)"
    }

    /// Build the manifest CKRecord name for a dictionary.
    private func manifestRecordName(dictId: String) -> String {
        recordName(dictId: dictId, fileName: "manifest.json")
    }

    // MARK: - Build CKRecord

    /// Build a single CKRecord for a dictionary file.
    private func buildFileRecord(
        dictId: String,
        fileName: String,
        fileURL: URL,
        fileHash: String,
        fileSizeBytes: Int64
    ) -> CKRecord {
        let name = recordName(dictId: dictId, fileName: fileName)
        let recordID = CKRecord.ID(recordName: name)
        let record = CKRecord(recordType: recordType, recordID: recordID)

        record["dictId"] = dictId as CKRecordValue
        record["fileName"] = fileName as CKRecordValue
        record["fileAsset"] = CKAsset(fileURL: fileURL)
        record["fileHash"] = fileHash as CKRecordValue
        record["fileSizeBytes"] = fileSizeBytes as CKRecordValue
        record["uploadedAt"] = Date() as CKRecordValue

        return record
    }

    // MARK: - Cloud Manifest

    /// Write the CloudKit-facing copy of a manifest to a temp file.
    ///
    /// Files above `maxAssetBytes` are never uploaded, so the manifest stored
    /// in CloudKit lists syncable entries only. Advertising a local-only file
    /// would make every peer fetch a record that does not exist, and a peer's
    /// merge could then "delete" the origin's local copy (see
    /// `ManifestSyncRules`).
    private func cloudManifestFile(for manifest: DictManifest) -> (url: URL, sizeBytes: Int64)? {
        let subset = ManifestSyncRules.syncableSubset(of: manifest)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(subset) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-manifest-\(manifest.id).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            debugLog("❌ Could not stage cloud manifest for \(manifest.id.prefix(16)): \(error)")
            return nil
        }
        return (url, Int64(data.count))
    }

    // MARK: - Enumerate Files

    /// Enumerate all files in a dictionary directory that should be synced.
    /// Returns (fileName, fileURL, fileHash, fileSizeBytes) tuples.
    private func enumerateFiles(
        dictId: String,
        manifest: DictManifest
    ) -> [(fileName: String, fileURL: URL, fileHash: String, fileSizeBytes: Int64)] {
        let dictDir = storage.dictionaryDirectoryURL(id: dictId)
        var files: [(String, URL, String, Int64)] = []

        // manifest.json — the CloudKit copy lists syncable entries only.
        if let cloudManifest = cloudManifestFile(for: manifest) {
            files.append(("manifest.json", cloudManifest.url, "", cloudManifest.sizeBytes))
        }

        // MDX
        let mdxURL = dictDir.appendingPathComponent(manifest.mdx.fileName)
        files.append((manifest.mdx.fileName, mdxURL, "", manifest.mdx.sizeBytes))

        // MDD
        let mddDir = storage.mddDirectoryURL(id: dictId)
        for entry in manifest.mdd {
            let url = mddDir.appendingPathComponent(entry.fileName)
            files.append((entry.fileName, url, entry.hash, entry.sizeBytes))
        }

        // CSS
        let cssDir = storage.cssDirectoryURL(id: dictId)
        for entry in manifest.css {
            let url = cssDir.appendingPathComponent(entry.fileName)
            files.append((entry.fileName, url, entry.hash, entry.sizeBytes))
        }

        // JS
        let jsDir = storage.jsDirectoryURL(id: dictId)
        for entry in manifest.js {
            let url = jsDir.appendingPathComponent(entry.fileName)
            files.append((entry.fileName, url, entry.hash, entry.sizeBytes))
        }

        // Fonts
        let fontsDir = storage.fontsDirectoryURL(id: dictId)
        for entry in manifest.fonts {
            let url = fontsDir.appendingPathComponent(entry.fileName)
            files.append((entry.fileName, url, entry.hash, entry.sizeBytes))
        }

        return files
    }

    // MARK: - Upload (Full Dictionary)

    /// Upload all files in a dictionary as individual CKRecords.
    /// Updates `DictionaryMetadataRecord.cloudSyncStatus` on completion.
    func uploadDictionary(dictId: String) async {
        // Pre-flight
        guard SyncModeService.shared.isCloudSyncEnabled else { return }
        guard await isCloudAvailable() else {
            debugLog("☁️↑ Upload skipped — iCloud not available")
            return
        }

        let dictDir = storage.dictionaryDirectoryURL(id: dictId)
        guard FileManager.default.fileExists(atPath: dictDir.path) else {
            debugLog("☁️↑ Upload skipped — directory missing for \(dictId.prefix(16))")
            return
        }

        guard let manifest = storage.loadDictManifest(id: dictId) else {
            debugLog("☁️↑ Upload skipped — no manifest for \(dictId.prefix(16))")
            return
        }

        syncProgress[dictId] = .uploading(fractionCompleted: 0)

        // Enumerate and size-check
        let allFiles = enumerateFiles(dictId: dictId, manifest: manifest)

        // Check if any individual file is too large
        let tooLargeFile = allFiles.first { $0.fileSizeBytes > maxAssetBytes }
        if let oversized = tooLargeFile {
            debugLog("☁️↑ File too large: \(oversized.fileName) (\(oversized.fileSizeBytes / 1024 / 1024) MB) — \(dictId.prefix(16))")
            updateSyncStatus(dictId: dictId, status: .tooLarge)
            syncProgress.removeValue(forKey: dictId)
            return
        }

        // Build CKRecords
        let records = allFiles.map {
            buildFileRecord(dictId: dictId, fileName: $0.fileName,
                            fileURL: $0.fileURL, fileHash: $0.fileHash,
                            fileSizeBytes: $0.fileSizeBytes)
        }

        // Batch upload (chunk if > maxBatchSize)
        let totalRecords = records.count
        var uploaded = 0

        for batchStart in stride(from: 0, to: totalRecords, by: maxBatchSize) {
            let batchEnd = min(batchStart + maxBatchSize, totalRecords)
            let batch = Array(records[batchStart..<batchEnd])

            do {
                try await uploadBatch(batch)
                uploaded += batch.count
                syncProgress[dictId] = .uploading(
                    fractionCompleted: Double(uploaded) / Double(totalRecords)
                )
            } catch {
                debugLog("❌ Upload batch failed for \(dictId.prefix(16)): \(error)")
                updateSyncStatus(dictId: dictId, status: .error)
                syncProgress.removeValue(forKey: dictId)
                return
            }
        }

        debugLog("☁️↑ Uploaded \(totalRecords) files for \(dictId.prefix(16))")
        updateSyncStatus(dictId: dictId, status: .synced)
        syncProgress.removeValue(forKey: dictId)
    }

    // MARK: - Upload (Single File — Incremental)

    /// Upload a single file + updated manifest.
    /// Use after adding or overwriting a resource file.
    func uploadSingleFile(
        dictId: String,
        fileName: String,
        fileURL: URL,
        fileHash: String,
        fileSizeBytes: Int64
    ) async {
        guard SyncModeService.shared.isCloudSyncEnabled else { return }
        guard await isCloudAvailable() else { return }

        // Size check
        if fileSizeBytes > maxAssetBytes {
            debugLog("☁️↑ Single file too large: \(fileName) — \(dictId.prefix(16))")
            return
        }

        var records: [CKRecord] = []

        // The new/updated file
        records.append(buildFileRecord(
            dictId: dictId, fileName: fileName,
            fileURL: fileURL, fileHash: fileHash,
            fileSizeBytes: fileSizeBytes
        ))

        // Updated manifest (CloudKit copy: syncable entries only)
        guard let localManifest = storage.loadDictManifest(id: dictId),
              let cloudManifest = cloudManifestFile(for: localManifest) else {
            debugLog("❌ Single file upload skipped — no manifest for \(dictId.prefix(16))")
            return
        }
        records.append(buildFileRecord(
            dictId: dictId, fileName: "manifest.json",
            fileURL: cloudManifest.url, fileHash: "",
            fileSizeBytes: cloudManifest.sizeBytes
        ))

        do {
            try await uploadBatch(records)
            debugLog("☁️↑ Uploaded single file \(fileName) for \(dictId.prefix(16))")
        } catch {
            debugLog("❌ Single file upload failed (\(fileName)): \(error)")
        }
    }

    // MARK: - Delete (Single File — Incremental)

    /// Delete a single file CKRecord + re-upload updated manifest.
    /// Use after removing a resource file.
    func deleteSingleFile(dictId: String, fileName: String) async {
        guard SyncModeService.shared.isCloudSyncEnabled else { return }
        guard await isCloudAvailable() else { return }

        let fileRecordID = CKRecord.ID(
            recordName: recordName(dictId: dictId, fileName: fileName)
        )

        // Updated manifest (CloudKit copy: syncable entries only)
        guard let localManifest = storage.loadDictManifest(id: dictId),
              let cloudManifest = cloudManifestFile(for: localManifest) else {
            debugLog("❌ Single file delete skipped — no manifest for \(dictId.prefix(16))")
            return
        }
        let manifestRecord = buildFileRecord(
            dictId: dictId, fileName: "manifest.json",
            fileURL: cloudManifest.url, fileHash: "",
            fileSizeBytes: cloudManifest.sizeBytes
        )

        let operation = CKModifyRecordsOperation(
            recordsToSave: [manifestRecord],
            recordIDsToDelete: [fileRecordID]
        )
        operation.savePolicy = .allKeys
        operation.qualityOfService = .userInitiated

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:  cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                self.database.add(operation)
            }
            debugLog("☁️✕ Deleted single file \(fileName) for \(dictId.prefix(16))")
        } catch {
            debugLog("❌ Single file delete failed (\(fileName)): \(error)")
        }
    }

    // MARK: - Download (Full Dictionary)

    /// Download all files for a dictionary from CloudKit.
    /// Returns `true` if the dictionary files are now available locally.
    @discardableResult
    func downloadDictionary(dictId: String) async -> Bool {
        // Single-flight (must precede the first await).
        guard inFlightDownloads.insert(dictId).inserted else {
            debugLog("☁️↓ \(dictId.prefix(16)) already downloading — skip")
            return false
        }
        defer { inFlightDownloads.remove(dictId) }

        // Pre-flight
        guard SyncModeService.shared.isCloudSyncEnabled else { return false }
        guard await isCloudAvailable() else {
            debugLog("☁️↓ Download skipped — iCloud not available")
            return false
        }

        let dictDir = storage.dictionaryDirectoryURL(id: dictId)
        if FileManager.default.fileExists(atPath: dictDir.path) {
            debugLog("☁️↓ Directory already exists for \(dictId.prefix(16)) — skip download")
            return true
        }

        // Everything is downloaded into a staging directory and moved into
        // place only once every file is present, so a dictionary directory
        // that exists is always complete (no half-built directory for a
        // concurrent caller to trip over).
        let stagingDir = storage.downloadStagingDirectoryURL(id: dictId)
        try? FileManager.default.removeItem(at: stagingDir)

        syncProgress[dictId] = .downloading(fractionCompleted: 0)

        // 1. Fetch manifest
        guard let remoteManifest = await fetchRemoteManifest(dictId: dictId) else {
            debugLog("❌ No manifest in CloudKit for \(dictId.prefix(16))")
            updateSyncStatus(dictId: dictId, status: .error)
            syncProgress.removeValue(forKey: dictId)
            return false
        }
        // Entries above the upload cap cannot exist as CloudKit assets
        // (an older build may still have listed them).
        let plan = ManifestSyncRules.merge(local: nil, remote: remoteManifest)
        let manifest = plan.merged

        syncProgress[dictId] = .downloading(fractionCompleted: 0.1)

        // 2. Create directory structure (in staging)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            for subdir in AppIdentifiers.ResourceDirectory.all {
                let subdirURL = stagingDir.appendingPathComponent(subdir, isDirectory: true)
                try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
            }
        } catch {
            debugLog("❌ Failed to create dirs for \(dictId.prefix(16)): \(error)")
            try? FileManager.default.removeItem(at: stagingDir)
            updateSyncStatus(dictId: dictId, status: .error)
            syncProgress.removeValue(forKey: dictId)
            return false
        }

        // 3. Build record IDs → staging paths mapping
        var recordIDToLocalPath: [String: URL] = [:]
        func stagingPath(_ subdir: String, _ fileName: String) -> URL {
            stagingDir.appendingPathComponent(subdir, isDirectory: true).appendingPathComponent(fileName)
        }

        // MDX
        let mdxName = recordName(dictId: dictId, fileName: manifest.mdx.fileName)
        recordIDToLocalPath[mdxName] = stagingDir.appendingPathComponent(manifest.mdx.fileName)

        for entry in plan.download.mdd {
            recordIDToLocalPath[recordName(dictId: dictId, fileName: entry.fileName)] =
                stagingPath(AppIdentifiers.ResourceDirectory.mdd, entry.fileName)
        }
        for entry in plan.download.css {
            recordIDToLocalPath[recordName(dictId: dictId, fileName: entry.fileName)] =
                stagingPath(AppIdentifiers.ResourceDirectory.css, entry.fileName)
        }
        for entry in plan.download.js {
            recordIDToLocalPath[recordName(dictId: dictId, fileName: entry.fileName)] =
                stagingPath(AppIdentifiers.ResourceDirectory.js, entry.fileName)
        }
        for entry in plan.download.fonts {
            recordIDToLocalPath[recordName(dictId: dictId, fileName: entry.fileName)] =
                stagingPath(AppIdentifiers.ResourceDirectory.fonts, entry.fileName)
        }

        // 4. Fetch all file records
        let recordIDs = recordIDToLocalPath.keys.map { CKRecord.ID(recordName: $0) }
        let totalFiles = recordIDs.count
        var downloaded = 0

        for batchStart in stride(from: 0, to: totalFiles, by: maxBatchSize) {
            let batchEnd = min(batchStart + maxBatchSize, totalFiles)
            let batch = Array(recordIDs[batchStart..<batchEnd])

            let fetchedRecords: [CKRecord.ID: CKRecord]
            do {
                fetchedRecords = try await fetchBatch(batch)
            } catch {
                debugLog("❌ Batch fetch failed for \(dictId.prefix(16)): \(error)")
                try? FileManager.default.removeItem(at: stagingDir)
                updateSyncStatus(dictId: dictId, status: .error)
                syncProgress.removeValue(forKey: dictId)
                return false
            }

            // Copy each asset to its staging path
            var copyFailed = false
            for (recordID, record) in fetchedRecords {
                guard let asset = record["fileAsset"] as? CKAsset,
                      let assetURL = asset.fileURL,
                      let destURL = recordIDToLocalPath[recordID.recordName] else {
                    continue
                }
                do {
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.copyItem(at: assetURL, to: destURL)
                    downloaded += 1
                    syncProgress[dictId] = .downloading(
                        fractionCompleted: 0.1 + 0.8 * Double(downloaded) / Double(totalFiles)
                    )
                } catch {
                    debugLog("❌ Failed to copy \(recordID.recordName): \(error)")
                    copyFailed = true
                    break
                }
            }

            // Abort early if any file copy failed within this batch
            if copyFailed { break }
        }

        // Validate download completeness — partial downloads leave a
        // corrupt dictionary directory that the user cannot open.
        if downloaded < totalFiles {
            debugLog("❌ Incomplete download: \(downloaded)/\(totalFiles) files — cleaning up \(dictId.prefix(16))")
            try? FileManager.default.removeItem(at: stagingDir)
            updateSyncStatus(dictId: dictId, status: .error)
            syncProgress.removeValue(forKey: dictId)
            return false
        }

        // 5. Save manifest into staging (last, so a complete staging dir
        //    always has one), then publish atomically.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: stagingDir.appendingPathComponent("manifest.json"), options: .atomic)
            try FileManager.default.createDirectory(at: dictDir.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: stagingDir, to: dictDir)
        } catch {
            debugLog("❌ Failed to publish download for \(dictId.prefix(16)): \(error)")
            try? FileManager.default.removeItem(at: stagingDir)
            updateSyncStatus(dictId: dictId, status: .error)
            syncProgress.removeValue(forKey: dictId)
            return false
        }
        storage.invalidateDictManifestCache(id: dictId)

        // 6. isExcludedFromBackup
        var mutableDir = dictDir
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableDir.setResourceValues(resourceValues)

        syncProgress[dictId] = .downloading(fractionCompleted: 1.0)

        debugLog("☁️↓ Downloaded \(downloaded)/\(totalFiles) files for \(dictId.prefix(16))")
        updateSyncStatus(dictId: dictId, status: .synced)
        syncProgress.removeValue(forKey: dictId)
        return true
    }

    // MARK: - Fetch Remote Manifest

    /// Fetch the manifest CKRecord from CloudKit and decode it as DictManifest.
    func fetchRemoteManifest(dictId: String) async -> DictManifest? {
        let name = manifestRecordName(dictId: dictId)
        let recordID = CKRecord.ID(recordName: name)

        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            debugLog("❌ Manifest fetch failed for \(dictId.prefix(16)): \(error)")
            return nil
        }

        guard let asset = record["fileAsset"] as? CKAsset,
              let assetURL = asset.fileURL else {
            debugLog("❌ No asset in manifest record for \(dictId.prefix(16))")
            return nil
        }

        do {
            let data = try Data(contentsOf: assetURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DictManifest.self, from: data)
        } catch {
            debugLog("❌ Manifest decode failed for \(dictId.prefix(16)): \(error)")
            return nil
        }
    }

    /// Whether the dictionary's manifest record still exists in CloudKit.
    ///
    /// A genuine remote delete removes it (`deleteCloudRecords`); a
    /// mirroring reset only purges local rows and never touches CloudKit.
    /// This is the evidence `DictionaryService` requires before deleting
    /// local files for a dictionary whose metadata row disappeared.
    /// Returns nil when CloudKit could not be asked (retry later).
    func remoteManifestExists(dictId: String) async -> Bool? {
        let recordID = CKRecord.ID(recordName: manifestRecordName(dictId: dictId))
        do {
            // desiredKeys keeps the asset itself from being downloaded.
            let results = try await database.records(for: [recordID], desiredKeys: ["dictId"])
            guard let result = results[recordID] else { return nil }
            switch result {
            case .success:
                return true
            case .failure(let error):
                if let ckError = error as? CKError, ckError.code == .unknownItem { return false }
                debugLog("⚠️ Manifest existence check failed for \(dictId.prefix(16)): \(error)")
                return nil
            }
        } catch let error as CKError where error.code == .unknownItem {
            return false
        } catch {
            debugLog("⚠️ Manifest existence check failed for \(dictId.prefix(16)): \(error)")
            return nil
        }
    }

    // MARK: - Download Updated Files (Incremental)

    /// Diff local vs remote manifest and download/delete only changed files.
    @discardableResult
    func downloadUpdatedFiles(dictId: String, remoteManifest: DictManifest) async -> Bool {
        // Single-flight (must precede the first await).
        guard inFlightDownloads.insert(dictId).inserted else {
            debugLog("☁️↓ \(dictId.prefix(16)) already downloading — skip incremental update")
            return false
        }
        defer { inFlightDownloads.remove(dictId) }

        let localManifest = storage.loadDictManifest(id: dictId)

        // Reconcile: only syncable remote entries are fetched, local entries
        // above the upload cap are never deleted (CloudKit has no copy), and
        // the merged manifest keeps them.
        let plan = ManifestSyncRules.merge(local: localManifest, remote: remoteManifest)

        // Download new/changed files
        var recordIDToLocalPath: [String: URL] = [:]

        for entry in plan.download.mdd {
            recordIDToLocalPath[recordName(dictId: dictId, fileName: entry.fileName)] =
                storage.mddDirectoryURL(id: dictId).appendingPathComponent(entry.fileName)
        }
        for entry in plan.download.css {
            recordIDToLocalPath[recordName(dictId: dictId, fileName: entry.fileName)] =
                storage.cssDirectoryURL(id: dictId).appendingPathComponent(entry.fileName)
        }
        for entry in plan.download.js {
            recordIDToLocalPath[recordName(dictId: dictId, fileName: entry.fileName)] =
                storage.jsDirectoryURL(id: dictId).appendingPathComponent(entry.fileName)
        }
        for entry in plan.download.fonts {
            recordIDToLocalPath[recordName(dictId: dictId, fileName: entry.fileName)] =
                storage.fontsDirectoryURL(id: dictId).appendingPathComponent(entry.fileName)
        }

        if !recordIDToLocalPath.isEmpty {
            let recordIDs = recordIDToLocalPath.keys.map { CKRecord.ID(recordName: $0) }
            do {
                let fetched = try await fetchBatch(recordIDs)
                for (recordID, record) in fetched {
                    guard let asset = record["fileAsset"] as? CKAsset,
                          let assetURL = asset.fileURL,
                          let destURL = recordIDToLocalPath[recordID.recordName] else {
                        continue
                    }
                    try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    // Remove existing file if overwriting
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.copyItem(at: assetURL, to: destURL)
                }
            } catch {
                debugLog("❌ Incremental download failed for \(dictId.prefix(16)): \(error)")
                return false
            }
        }

        // Delete removed files (syncable ones only — see ManifestSyncRules)
        for entry in plan.delete.mdd {
            try? FileManager.default.removeItem(
                at: storage.mddDirectoryURL(id: dictId).appendingPathComponent(entry.fileName))
        }
        for entry in plan.delete.css {
            try? FileManager.default.removeItem(
                at: storage.cssDirectoryURL(id: dictId).appendingPathComponent(entry.fileName))
        }
        for entry in plan.delete.js {
            try? FileManager.default.removeItem(
                at: storage.jsDirectoryURL(id: dictId).appendingPathComponent(entry.fileName))
        }
        for entry in plan.delete.fonts {
            try? FileManager.default.removeItem(
                at: storage.fontsDirectoryURL(id: dictId).appendingPathComponent(entry.fileName))
        }

        // Save merged manifest locally
        let manifestURL = storage.dictManifestURL(id: dictId)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(plan.merged) {
            try? data.write(to: manifestURL, options: .atomic)
        }
        storage.invalidateDictManifestCache(id: dictId)

        debugLog("☁️↓ Incremental update: \(plan.changeCount) changes for \(dictId.prefix(16))")
        return true
    }

    // MARK: - Delete (All Records for Dictionary)

    /// Delete all CloudKit records for a dictionary.
    /// Call when the user deletes a dictionary locally.
    func deleteCloudRecords(dictId: String) async {
        guard SyncModeService.shared.isCloudSyncEnabled else { return }
        guard await isCloudAvailable() else { return }

        var recordIDsToDelete: [CKRecord.ID] = []

        // Try local manifest first; fall back to remote manifest if
        // local files were already deleted (prevents CKRecord orphans
        // that permanently consume the user's iCloud quota).
        var manifest: DictManifest? = storage.loadDictManifest(id: dictId)
        if manifest == nil {
            manifest = await fetchRemoteManifest(dictId: dictId)
        }

        // Manifest record itself
        recordIDsToDelete.append(CKRecord.ID(
            recordName: manifestRecordName(dictId: dictId)
        ))

        if let manifest {
            // MDX
            recordIDsToDelete.append(CKRecord.ID(
                recordName: recordName(dictId: dictId, fileName: manifest.mdx.fileName)
            ))
            // MDD
            for entry in manifest.mdd {
                recordIDsToDelete.append(CKRecord.ID(
                    recordName: recordName(dictId: dictId, fileName: entry.fileName)
                ))
            }
            // CSS
            for entry in manifest.css {
                recordIDsToDelete.append(CKRecord.ID(
                    recordName: recordName(dictId: dictId, fileName: entry.fileName)
                ))
            }
            // JS
            for entry in manifest.js {
                recordIDsToDelete.append(CKRecord.ID(
                    recordName: recordName(dictId: dictId, fileName: entry.fileName)
                ))
            }
            // Fonts
            for entry in manifest.fonts {
                recordIDsToDelete.append(CKRecord.ID(
                    recordName: recordName(dictId: dictId, fileName: entry.fileName)
                ))
            }
        } else {
            debugLog("⚠️ No manifest (local or remote) for \(dictId.prefix(16)) — only manifest CKRecord will be deleted")
        }

        // Batch delete
        for batchStart in stride(from: 0, to: recordIDsToDelete.count, by: maxBatchSize) {
            let batchEnd = min(batchStart + maxBatchSize, recordIDsToDelete.count)
            let batch = Array(recordIDsToDelete[batchStart..<batchEnd])

            let operation = CKModifyRecordsOperation(
                recordsToSave: nil,
                recordIDsToDelete: batch
            )
            operation.qualityOfService = .utility

            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    operation.modifyRecordsResultBlock = { result in
                        switch result {
                        case .success:  cont.resume()
                        case .failure(let error): cont.resume(throwing: error)
                        }
                    }
                    self.database.add(operation)
                }
            } catch {
                // Not fatal — orphaned CKRecords are harmless
                debugLog("⚠️ Cloud records delete failed for \(dictId.prefix(16)): \(error)")
            }
        }

        debugLog("☁️✕ Deleted \(recordIDsToDelete.count) cloud records for \(dictId.prefix(16))")
    }

    // MARK: - Helpers

    /// Check if iCloud account is available.
    private func isCloudAvailable() async -> Bool {
        do {
            let status = try await container.accountStatus()
            return status == .available
        } catch {
            return false
        }
    }

    /// Update the CloudKit sync status on the metadata record.
    private func updateSyncStatus(
        dictId: String,
        status: CloudSyncStatus
    ) {
        let ctx = CoreDataStack.shared.viewContext
        let request = DictionaryMetadataRecord.fetchRequest()
        request.predicate = NSPredicate(format: "dictId == %@", dictId)
        request.fetchLimit = 1

        guard let record = try? ctx.fetch(request).first else { return }
        record.cloudSyncStatus = status.rawValue
        try? ctx.save()
    }

    /// Upload a batch of CKRecords with .allKeys save policy.
    private func uploadBatch(_ records: [CKRecord]) async throws {
        try await withCloudKitRetry {
            let operation = CKModifyRecordsOperation(
                recordsToSave: records,
                recordIDsToDelete: nil
            )
            operation.savePolicy = .allKeys
            operation.qualityOfService = .userInitiated

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:  cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                self.database.add(operation)
            }
        }
    }

    /// Fetch a batch of CKRecords by their IDs.
    private func fetchBatch(_ recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        try await withCloudKitRetry {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CKRecord.ID: CKRecord], Error>) in
                let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
                operation.qualityOfService = .userInitiated

                var results: [CKRecord.ID: CKRecord] = [:]

                operation.perRecordResultBlock = { recordID, result in
                    switch result {
                    case .success(let record):
                        results[recordID] = record
                    case .failure(let error):
                        debugLog("⚠️ fetchBatch: per-record failure \(recordID.recordName): \(error.localizedDescription)")
                    }
                }
                operation.fetchRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        cont.resume(returning: results)
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
                self.database.add(operation)
            }
        }
    }

    // MARK: - CloudKit Retry

    /// Retry a CloudKit operation up to `maxRetries` times for transient errors.
    /// Respects `CKError.retryAfterSeconds` when provided by the server.
    private func withCloudKitRetry<T>(
        maxRetries: Int = 3,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch let ckError as CKError where ckError.isRetriable {
                lastError = ckError
                let delay = ckError.retryAfterSeconds
                    ?? min(Double(attempt + 1) * 2.0, 15.0)
                debugLog("☁️ Retry \(attempt + 1)/\(maxRetries) after \(String(format: "%.1f", delay))s — \(ckError.code.rawValue)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                throw error  // Non-retriable → fail immediately
            }
        }
        throw lastError!
    }

}

// MARK: - CKError + Retriable

private extension CKError {
    /// Transient errors that CloudKit expects callers to retry.
    var isRetriable: Bool {
        switch code {
        case .requestRateLimited,   // Server throttling (includes retryAfterSeconds)
             .zoneBusy,             // Zone temporarily unavailable
             .serviceUnavailable,   // Server maintenance
             .networkFailure,       // Temporary network issue
             .networkUnavailable:   // Connectivity lost
            return true
        default:
            return false
        }
    }
}
