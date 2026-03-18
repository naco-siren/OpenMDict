//
//  SyncModeService.swift
//  OpenMDict-iOS
//
//  Manages the user's iCloud sync preference.
//
//  On first launch the mode is `.notDecided` — the setup flow presents
//  a chooser (SyncModeChooserViewController) before any CoreData sync
//  or DictionaryService initialisation happens.
//
//  Once the user decides, the mode is persisted in UserDefaults.standard
//  and read on every subsequent launch to configure CoreDataStack
//  (with or without CloudKit) before anything else runs.
//

import CloudKit
import Foundation

// MARK: - SyncMode Enum

/// Persisted in UserDefaults as a raw Int.
nonisolated enum SyncMode: Int, Sendable {
    case notDecided = 0   // First install — user has not chosen yet
    case cloudSync  = 1   // User chose iCloud sync
    case offline    = 2   // User chose offline / local-only
}

// MARK: - Cloud Data Summary

/// Counts of records found in the user's CloudKit private database.
struct CloudDataSummary {
    let dictionaryCount: Int
    let groupCount: Int
    let bookmarkCount: Int
    let lookupHistoryCount: Int

    var hasData: Bool { dictionaryCount > 0 }
}

// MARK: - Service

final class SyncModeService {

    static let shared = SyncModeService()

    private static let key = "syncMode"

    /// Shared UserDefaults accessible by the main app and extensions.
    private static let sharedDefaults = UserDefaults(
        suiteName: AppIdentifiers.appGroupIdentifier
    ) ?? UserDefaults.standard

    // MARK: - Current Mode

    /// The user's persisted sync-mode choice.
    /// Stored in App Group UserDefaults so extensions can read it.
    var currentMode: SyncMode {
        get {
            // Check App Group first, fall back to standard for migration
            let shared = Self.sharedDefaults.integer(forKey: Self.key)
            if shared != 0 { return SyncMode(rawValue: shared) ?? .notDecided }
            // Migrate from UserDefaults.standard if present (one-time)
            let legacy = UserDefaults.standard.integer(forKey: Self.key)
            if legacy != 0 {
                Self.sharedDefaults.set(legacy, forKey: Self.key)
                return SyncMode(rawValue: legacy) ?? .notDecided
            }
            return .notDecided
        }
        set {
            Self.sharedDefaults.set(newValue.rawValue, forKey: Self.key)
        }
    }

    /// Convenience: `true` when the user has opted in to iCloud sync.
    var isCloudSyncEnabled: Bool { currentMode == .cloudSync }

    private init() {}

    // MARK: - CloudKit Availability Check

    /// Result of probing CloudKit before the user makes a choice.
    enum CloudStatus {
        /// iCloud account is available.  `summary` contains counts of
        /// records in the private database (dictionaries, groups, bookmarks).
        case available(summary: CloudDataSummary)

        /// iCloud is not usable — see `reason` for details.
        case unavailable(reason: UnavailableReason)
    }

    enum UnavailableReason {
        case noNetwork
        case notSignedIn
        case restricted
        case temporarilyUnavailable
        case couldNotDetermine
    }

    /// Probe the iCloud account status and, if available, query the private
    /// CloudKit database for existing data (dictionaries, groups, bookmarks).
    ///
    /// This runs **independently of CoreDataStack** — it uses the CloudKit
    /// API directly so we can show the right CTA text before any
    /// NSPersistentCloudKitContainer initialisation.
    func checkCloudStatus() async -> CloudStatus {
        let container = CKContainer(
            identifier: AppIdentifiers.cloudKitContainerID
        )

        // 1. Account status
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            return .unavailable(reason: .couldNotDetermine)
        }

        guard accountStatus == .available else {
            switch accountStatus {
            case .noAccount:
                return .unavailable(reason: .notSignedIn)
            case .restricted:
                return .unavailable(reason: .restricted)
            case .temporarilyUnavailable:
                return .unavailable(reason: .temporarilyUnavailable)
            default:
                return .unavailable(reason: .couldNotDetermine)
            }
        }

        // 2. Fetch all records from the CoreData CloudKit zone and count by type.
        //
        //    We use recordZoneChanges(inZoneWith:since:) instead of CKQuery because
        //    NSPersistentCloudKitContainer's auto-generated record types do NOT have
        //    queryable indexes — CKQuery fails with "Field 'recordName' is not marked
        //    queryable" (CKError code 12).
        //
        //    Passing `nil` as the server change token fetches ALL records in the zone.
        //    We request only `recordType` (via empty desiredKeys) to minimise payload.
        let db = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(
            zoneName: "com.apple.coredata.cloudkit.zone",
            ownerName: CKCurrentUserDefaultName
        )

        do {
            var dictCount = 0
            var groupCount = 0
            var bookmarkCount = 0
            var lookupHistoryCount = 0

            // Fetch changes since the beginning (nil token = all records).
            // The API returns pages; we loop until moreComing is false.
            var changeToken: CKServerChangeToken? = nil
            var moreComing = true

            while moreComing {
                let changes = try await db.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: changeToken
                )

                for (_, result) in changes.modificationResultsByID {
                    guard case .success(let modification) = result else { continue }
                    switch modification.record.recordType {
                    case "CD_DictionaryMetadataRecord":
                        dictCount += 1
                    case "CD_DictionaryGroupRecord":
                        groupCount += 1
                    case "CD_BookmarkRecord":
                        bookmarkCount += 1
                    case "CD_LookupRecord":
                        lookupHistoryCount += 1
                    default:
                        break
                    }
                }

                changeToken = changes.changeToken
                moreComing = changes.moreComing
            }

            let summary = CloudDataSummary(
                dictionaryCount: dictCount,
                groupCount: groupCount,
                bookmarkCount: bookmarkCount,
                lookupHistoryCount: lookupHistoryCount
            )

            debugLog("☁️ SyncModeService: cloud data — \(summary.dictionaryCount) dicts, \(summary.groupCount) groups, \(summary.bookmarkCount) bookmarks, \(summary.lookupHistoryCount) history")

            return .available(summary: summary)

        } catch let error as CKError {
            debugLog("☁️ SyncModeService: CKError fetching zone changes — code=\(error.code.rawValue) \(error.localizedDescription)")
            switch error.code {
            case .networkUnavailable, .networkFailure:
                return .unavailable(reason: .noNetwork)
            case .notAuthenticated:
                return .unavailable(reason: .notSignedIn)
            case .zoneNotFound:
                // Zone doesn't exist — genuinely no data.
                return .available(summary: CloudDataSummary(
                    dictionaryCount: 0, groupCount: 0, bookmarkCount: 0, lookupHistoryCount: 0
                ))
            default:
                // Other CKErrors — treat as no data (zone may not be set up yet).
                return .available(summary: CloudDataSummary(
                    dictionaryCount: 0, groupCount: 0, bookmarkCount: 0, lookupHistoryCount: 0
                ))
            }
        } catch {
            debugLog("☁️ SyncModeService: unexpected error fetching zone changes — \(error)")
            return .unavailable(reason: .couldNotDetermine)
        }
    }
}
