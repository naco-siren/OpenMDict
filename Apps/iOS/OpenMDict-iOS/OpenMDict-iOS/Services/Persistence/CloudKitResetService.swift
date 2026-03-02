//
//  CloudKitResetService.swift
//  OpenMDict-iOS
//
//  Handles CloudKit-side data deletion and reset signalling for the
//  iCloud nuclear reset.
//
//  Three capabilities:
//  1. Delete the CoreData CloudKit zone — wipes all 6 synced entity types.
//  2. Delete all DictionaryFile CKRecords from the default zone — wipes
//     manually-synced dictionary file assets.
//  3. Write / read a NuclearResetSignal CKRecord in the default zone —
//     propagates the reset command to other devices.
//
//  The NuclearResetSignal record lives in the default zone, which is
//  unaffected by CoreData zone deletion.  Other devices discover it
//  via a CKQuery on the default zone (triggered by
//  remoteChangePreprocessor or app launch) and perform their own
//  local data reset.
//

import CloudKit
import Foundation

final class CloudKitResetService {

    static let shared = CloudKitResetService()

    private let container = CKContainer(
        identifier: AppIdentifiers.cloudKitContainerID
    )
    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    /// Maximum records per CKModifyRecordsOperation batch.
    private let maxBatchSize = 400

    /// Fixed record ID for the reset signal — only one signal active at a time.
    private static let resetSignalRecordID = CKRecord.ID(
        recordName: "NuclearResetSignal-latest",
        zoneID: CKRecordZone.default().zoneID
    )

    /// Record type name registered in CloudKit.
    private static let resetSignalRecordType = "NuclearResetSignal"

    /// UserDefaults key for tracking the last processed signal UUID.
    private static let lastProcessedUUIDKey = "lastProcessedResetSignalUUID"

    private init() {}

    // MARK: - Delete CoreData Zone

    /// Delete the CloudKit zone used by NSPersistentCloudKitContainer.
    /// This removes ALL records for the 6 synced CoreData entities.
    ///
    /// `.zoneNotFound` is treated as success (zone may already be deleted).
    /// Network / auth errors propagate to the caller.
    func deleteCoreDataZone() async throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "com.apple.coredata.cloudkit.zone",
            ownerName: CKCurrentUserDefaultName
        )
        do {
            try await database.deleteRecordZone(withID: zoneID)
            debugLog("☁️🗑️ Deleted CoreData CloudKit zone")
        } catch let error as CKError where error.code == .zoneNotFound {
            debugLog("☁️🗑️ CoreData zone already gone (zoneNotFound) — treating as success")
        }
    }

    // MARK: - Delete DictionaryFile Records

    /// Enumerate and delete ALL DictionaryFile CKRecords from the default zone.
    ///
    /// Uses `recordZoneChanges(inZoneWith:since:)` on the default zone to
    /// discover all records, then batch-deletes them.
    ///
    /// Partial failure is non-fatal: orphaned records waste iCloud storage
    /// but do not cause data corruption.
    func deleteAllDictionaryFileRecords() async throws {
        let defaultZoneID = CKRecordZone.default().zoneID

        // 1. Enumerate all records in the default zone.
        var allRecordIDs: [CKRecord.ID] = []
        var changeToken: CKServerChangeToken? = nil
        var moreComing = true

        while moreComing {
            do {
                let changes = try await database.recordZoneChanges(
                    inZoneWith: defaultZoneID,
                    since: changeToken
                )

                for (recordID, result) in changes.modificationResultsByID {
                    guard case .success(let modification) = result else { continue }
                    if modification.record.recordType == "DictionaryFile" {
                        allRecordIDs.append(recordID)
                    }
                }

                changeToken = changes.changeToken
                moreComing = changes.moreComing
            } catch let error as CKError where error.code == .zoneNotFound {
                debugLog("☁️🗑️ Default zone not found — no DictionaryFile records to delete")
                return
            }
        }

        guard !allRecordIDs.isEmpty else {
            debugLog("☁️🗑️ No DictionaryFile records to delete")
            return
        }

        debugLog("☁️🗑️ Found \(allRecordIDs.count) DictionaryFile records — deleting…")

        // 2. Batch delete.
        for batchStart in stride(from: 0, to: allRecordIDs.count, by: maxBatchSize) {
            let batchEnd = min(batchStart + maxBatchSize, allRecordIDs.count)
            let batch = Array(allRecordIDs[batchStart..<batchEnd])

            let operation = CKModifyRecordsOperation(
                recordsToSave: nil,
                recordIDsToDelete: batch
            )
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
            } catch {
                // Log but do NOT propagate — partial deletion is acceptable.
                debugLog("⚠️ Batch delete failed (\(batch.count) records): \(error)")
            }
        }

        debugLog("☁️🗑️ Deleted \(allRecordIDs.count) DictionaryFile records from default zone")
    }

    // MARK: - Nuclear Reset Signal

    /// Write a NuclearResetSignal CKRecord to the default zone.
    ///
    /// This record persists across CoreData zone deletions (it's in the
    /// default zone, not the CoreData zone).  Other devices query for it
    /// and, upon discovering an unprocessed signal, perform a passive
    /// reset (clear local data + re-delete the zone).
    ///
    /// The signal contains a UUID so each device can track whether it
    /// has already processed this specific reset event.
    ///
    /// - Returns: The UUID written to the signal record.
    @discardableResult
    func writeResetSignal() async throws -> String {
        let uuid = UUID().uuidString
        let record = CKRecord(
            recordType: Self.resetSignalRecordType,
            recordID: Self.resetSignalRecordID
        )
        record["uuid"] = uuid as CKRecordValue
        record["timestamp"] = Date() as CKRecordValue

        let operation = CKModifyRecordsOperation(
            recordsToSave: [record],
            recordIDsToDelete: nil
        )
        // Overwrite if it already exists (from a previous reset).
        operation.savePolicy = .changedKeys
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

        // Mark as processed on the initiating device immediately —
        // we don't want to passive-reset ourselves.
        markSignalProcessed(uuid: uuid)

        debugLog("☁️📡 Wrote NuclearResetSignal (uuid=\(uuid))")
        return uuid
    }

    /// Query the default zone for a NuclearResetSignal record.
    ///
    /// - Returns: The signal's UUID if a record exists, `nil` if not found
    ///   or on error (errors are logged but not propagated — a missed
    ///   signal just means the device resets on the next check).
    func fetchResetSignalUUID() async -> String? {
        do {
            let record = try await database.record(for: Self.resetSignalRecordID)
            return record["uuid"] as? String
        } catch let error as CKError where error.code == .unknownItem {
            // No signal record exists — nothing to do.
            return nil
        } catch {
            debugLog("⚠️ Failed to fetch NuclearResetSignal: \(error)")
            return nil
        }
    }

    /// Check whether this device has already processed a given signal UUID.
    func hasProcessedSignal(uuid: String) -> Bool {
        let last = UserDefaults.standard.string(forKey: Self.lastProcessedUUIDKey)
        return last == uuid
    }

    /// Mark a signal UUID as processed on this device.
    func markSignalProcessed(uuid: String) {
        UserDefaults.standard.set(uuid, forKey: Self.lastProcessedUUIDKey)
    }
}
