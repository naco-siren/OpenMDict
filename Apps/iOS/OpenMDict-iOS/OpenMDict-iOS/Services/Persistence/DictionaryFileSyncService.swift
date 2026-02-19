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
//    Record type: "DictionaryArchive"
//    Fields:
//      dictId           — String  (SHA256 header hash = dictionary ID)
//      archiveAsset     — CKAsset (AppleArchive of {dictId}/ directory)
//      originalFileName — String
//      fileSizeBytes    — Int64
//      uploadedAt       — Date
//
//  Archive format:  AppleArchive (.aar) with LZFSE compression.
//  iOS 15+ native — no third-party dependencies.
//
//  Life cycle:
//    Import → archive → upload CKAsset → mark synced
//    Remote metadata arrives + no local files → download CKAsset → extract
//    Delete → remove CKRecord from CloudKit
//
//  Size guard: dictionaries > 250 MB (compressed) are marked "too large"
//  and skipped.  The user must import them manually on each device.
//

import AppleArchive
import CloudKit
import Combine
import CoreData
import Foundation
import System

// MARK: - Sync Status Enum

/// CloudKit file-sync status stored in DictionaryMetadataRecord.cloudSyncStatus.
nonisolated enum CloudSyncStatus: Int16, Sendable {
    case pending  = 0   // Not yet uploaded / download not started
    case synced   = 1   // Archive present in CloudKit
    case tooLarge = 2   // Exceeds 250 MB — local only
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

    /// CloudKit Record Type name for dictionary archives.
    private let recordType = "DictionaryArchive"

    /// Maximum archive size we are willing to upload (bytes).
    /// CKAsset allows up to 250 MB per asset.
    private let maxAssetBytes: Int64 = 250 * 1024 * 1024

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

    // MARK: - Upload

    /// Archive the dictionary directory and upload it as a CKAsset.
    /// Updates `DictionaryMetadataRecord.cloudSyncStatus` and
    /// `cloudArchiveRecordName` on completion.
    ///
    /// Call this after a successful local import.
    func uploadDictionary(dictId: String) async {
        // 0a. Pre-flight: sync mode gate
        guard SyncModeService.shared.isCloudSyncEnabled else { return }

        // 0b. Pre-flight: check iCloud account
        guard await isCloudAvailable() else {
            debugLog("☁️↑ Upload skipped — iCloud not available")
            return
        }

        let dictDir = storage.dictionaryDirectoryURL(id: dictId)
        guard FileManager.default.fileExists(atPath: dictDir.path) else {
            debugLog("☁️↑ Upload skipped — directory missing for \(dictId.prefix(16))")
            return
        }

        // 1. Archive (AppleArchive + LZFSE)
        syncProgress[dictId] = .uploading(fractionCompleted: 0)

        let tmpArchive = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(dictId).aar")
        defer { try? FileManager.default.removeItem(at: tmpArchive) }

        do {
            try await compressDirectory(at: dictDir, to: tmpArchive)
        } catch {
            debugLog("❌ Archive failed for \(dictId.prefix(16)): \(error)")
            updateSyncStatus(dictId: dictId, status: .error)
            syncProgress.removeValue(forKey: dictId)
            return
        }

        // 2. Size check
        let archiveSize = (try? FileManager.default.attributesOfItem(
            atPath: tmpArchive.path)[.size] as? Int64) ?? 0

        if archiveSize > maxAssetBytes {
            debugLog("☁️↑ Too large (\(archiveSize / 1024 / 1024) MB) — \(dictId.prefix(16))")
            updateSyncStatus(dictId: dictId, status: .tooLarge)
            syncProgress.removeValue(forKey: dictId)
            return
        }

        syncProgress[dictId] = .uploading(fractionCompleted: 0.3)

        // 3. Build CKRecord
        let metadata = DictMetadataService.shared.find(dictId: dictId)
        let recordName = "dict-\(dictId)"
        let recordID = CKRecord.ID(recordName: recordName)
        let record = CKRecord(recordType: recordType, recordID: recordID)

        record["dictId"] = dictId as CKRecordValue
        record["archiveAsset"] = CKAsset(fileURL: tmpArchive)
        record["originalFileName"] = (metadata?.originalFileName ?? "") as CKRecordValue
        record["fileSizeBytes"] = archiveSize as CKRecordValue
        record["uploadedAt"] = Date() as CKRecordValue

        // 4. Upload (save with overwrite policy for idempotent retry)
        let operation = CKModifyRecordsOperation(
            recordsToSave: [record],
            recordIDsToDelete: nil
        )
        operation.savePolicy = .allKeys  // overwrite if exists
        operation.qualityOfService = .userInitiated

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        cont.resume()
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
                // Progress tracking
                operation.perRecordProgressBlock = { [weak self] _, progress in
                    Task { @MainActor in
                        // Map 0→1 upload progress to 0.3→1.0 overall
                        self?.syncProgress[dictId] = .uploading(
                            fractionCompleted: 0.3 + progress * 0.7
                        )
                    }
                }
                self.database.add(operation)
            }

            debugLog("☁️↑ Uploaded \(dictId.prefix(16)) (\(archiveSize / 1024) KB)")
            updateSyncStatus(dictId: dictId, status: .synced, recordName: recordName)

        } catch {
            debugLog("❌ Upload failed for \(dictId.prefix(16)): \(error)")
            updateSyncStatus(dictId: dictId, status: .error)
        }

        syncProgress.removeValue(forKey: dictId)
    }

    // MARK: - Download

    /// Download a dictionary archive from CloudKit and extract it locally.
    /// Returns `true` if the dictionary files are now available locally.
    @discardableResult
    func downloadDictionary(dictId: String) async -> Bool {
        // 0a. Pre-flight: sync mode gate
        guard SyncModeService.shared.isCloudSyncEnabled else { return false }

        // 0b. Pre-flight
        guard await isCloudAvailable() else {
            debugLog("☁️↓ Download skipped — iCloud not available")
            return false
        }

        let dictDir = storage.dictionaryDirectoryURL(id: dictId)
        if FileManager.default.fileExists(atPath: dictDir.path) {
            debugLog("☁️↓ Directory already exists for \(dictId.prefix(16)) — skip download")
            return true
        }

        syncProgress[dictId] = .downloading(fractionCompleted: 0)

        // 1. Fetch the CKRecord
        let recordName = "dict-\(dictId)"
        let recordID = CKRecord.ID(recordName: recordName)

        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            debugLog("❌ CloudKit fetch failed for \(dictId.prefix(16)): \(error)")
            syncProgress.removeValue(forKey: dictId)
            return false
        }

        syncProgress[dictId] = .downloading(fractionCompleted: 0.3)

        // 2. Extract CKAsset → temp file
        guard let asset = record["archiveAsset"] as? CKAsset,
              let assetURL = asset.fileURL else {
            debugLog("❌ No archive asset in CKRecord for \(dictId.prefix(16))")
            syncProgress.removeValue(forKey: dictId)
            return false
        }

        // 3. Extract to dictionary directory
        do {
            try FileManager.default.createDirectory(
                at: dictDir, withIntermediateDirectories: true
            )
            try await decompressArchive(at: assetURL, to: dictDir)
            syncProgress[dictId] = .downloading(fractionCompleted: 0.9)

            // Mark isExcludedFromBackup (iCloud backup ≠ CloudKit sync)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDir = dictDir
            try mutableDir.setResourceValues(resourceValues)

            debugLog("☁️↓ Downloaded & extracted \(dictId.prefix(16))")
            updateSyncStatus(dictId: dictId, status: .synced, recordName: recordName)
            syncProgress.removeValue(forKey: dictId)
            return true

        } catch {
            debugLog("❌ Extract failed for \(dictId.prefix(16)): \(error)")
            // Clean up partial directory
            try? FileManager.default.removeItem(at: dictDir)
            syncProgress.removeValue(forKey: dictId)
            return false
        }
    }

    // MARK: - Delete

    /// Delete the CloudKit archive for a dictionary.
    /// Call when the user deletes a dictionary locally.
    func deleteCloudArchive(dictId: String) async {
        guard SyncModeService.shared.isCloudSyncEnabled else { return }
        guard await isCloudAvailable() else { return }

        let recordName = "dict-\(dictId)"
        let recordID = CKRecord.ID(recordName: recordName)

        let operation = CKModifyRecordsOperation(
            recordsToSave: nil,
            recordIDsToDelete: [recordID]
        )
        operation.qualityOfService = .utility

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        cont.resume()
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
                self.database.add(operation)
            }
            debugLog("☁️✕ Deleted cloud archive for \(dictId.prefix(16))")
        } catch {
            // Not fatal — orphaned CKRecords are harmless
            debugLog("⚠️ Cloud archive delete failed for \(dictId.prefix(16)): \(error)")
        }
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
        status: CloudSyncStatus,
        recordName: String? = nil
    ) {
        let ctx = CoreDataStack.shared.viewContext
        let request = DictionaryMetadataRecord.fetchRequest()
        request.predicate = NSPredicate(format: "dictId == %@", dictId)
        request.fetchLimit = 1

        guard let record = try? ctx.fetch(request).first else { return }
        record.cloudSyncStatus = status.rawValue
        if let recordName {
            record.cloudArchiveRecordName = recordName
        }
        try? ctx.save()
    }

    // MARK: - AppleArchive Compress / Decompress

    /// Compress a directory into a single AppleArchive (.aar) file
    /// using LZFSE compression.
    ///
    /// Runs on a background thread — AppleArchive is thread-blocking
    /// and must not run on the cooperative thread pool.
    private func compressDirectory(at sourceDir: URL, to destArchive: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Remove destination if exists
                try? FileManager.default.removeItem(at: destArchive)

                let sourcePath = FilePath(sourceDir.path)
                let destPath = FilePath(destArchive.path)

                let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,UID,GID,MOD,FLG,SIZ")!

                do {
                    guard let fileStream = ArchiveByteStream.fileStream(
                        path: destPath,
                        mode: .writeOnly,
                        options: [.create, .truncate],
                        permissions: [.ownerReadWrite, .groupRead, .otherRead]
                    ) else {
                        throw NSError(domain: "DictionaryFileSyncService", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to create file stream"])
                    }
                    defer { try? fileStream.close() }

                    guard let compressionStream = ArchiveByteStream.compressionStream(
                        using: .lzfse,
                        writingTo: fileStream
                    ) else {
                        throw NSError(domain: "DictionaryFileSyncService", code: -2,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to create compression stream"])
                    }
                    defer { try? compressionStream.close() }

                    guard let encodeStream = ArchiveStream.encodeStream(
                        writingTo: compressionStream
                    ) else {
                        throw NSError(domain: "DictionaryFileSyncService", code: -3,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to create encode stream"])
                    }
                    defer { try? encodeStream.close() }

                    try encodeStream.writeDirectoryContents(
                        archiveFrom: sourcePath,
                        keySet: keySet
                    )

                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Decompress an AppleArchive (.aar) file into a directory.
    ///
    /// Runs on a background thread — AppleArchive is thread-blocking
    /// and must not run on the cooperative thread pool.
    private func decompressArchive(at archiveURL: URL, to destDir: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let archivePath = FilePath(archiveURL.path)
                let destPath = FilePath(destDir.path)

                do {
                    guard let fileStream = ArchiveByteStream.fileStream(
                        path: archivePath,
                        mode: .readOnly,
                        options: [],
                        permissions: []
                    ) else {
                        throw NSError(domain: "DictionaryFileSyncService", code: -4,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to open archive file"])
                    }
                    defer { try? fileStream.close() }

                    guard let decompressionStream = ArchiveByteStream.decompressionStream(
                        readingFrom: fileStream
                    ) else {
                        throw NSError(domain: "DictionaryFileSyncService", code: -5,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to create decompression stream"])
                    }
                    defer { try? decompressionStream.close() }

                    guard let decodeStream = ArchiveStream.decodeStream(
                        readingFrom: decompressionStream
                    ) else {
                        throw NSError(domain: "DictionaryFileSyncService", code: -6,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to create decode stream"])
                    }
                    defer { try? decodeStream.close() }

                    guard let extractStream = ArchiveStream.extractStream(
                        extractingTo: destPath,
                        flags: [.ignoreOperationNotPermitted]
                    ) else {
                        throw NSError(domain: "DictionaryFileSyncService", code: -7,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to create extract stream"])
                    }
                    defer { try? extractStream.close() }

                    _ = try ArchiveStream.process(
                        readingFrom: decodeStream,
                        writingTo: extractStream
                    )

                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
