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

// MARK: - Service

final class SyncModeService {

    static let shared = SyncModeService()

    private static let key = "syncMode"

    // MARK: - Current Mode

    /// The user's persisted sync-mode choice.
    /// Reads from / writes to `UserDefaults.standard`.
    var currentMode: SyncMode {
        get {
            SyncMode(rawValue: UserDefaults.standard.integer(forKey: Self.key))
                ?? .notDecided
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.key)
        }
    }

    /// Convenience: `true` when the user has opted in to iCloud sync.
    var isCloudSyncEnabled: Bool { currentMode == .cloudSync }

    private init() {}

    // MARK: - CloudKit Availability Check

    /// Result of probing CloudKit before the user makes a choice.
    enum CloudStatus {
        /// iCloud account is available.  `hasData` indicates whether
        /// the private database already contains dictionary metadata
        /// (i.e. the user has synced from another device).
        case available(hasData: Bool)

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

    /// Probe the iCloud account status and, if available, check whether
    /// the private CloudKit database already contains dictionary metadata.
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

        // 2. Query private database for existing metadata records.
        //    NSPersistentCloudKitContainer auto-generates record types
        //    with a "CD_" prefix.
        let db = container.privateCloudDatabase
        let query = CKQuery(
            recordType: "CD_DictionaryMetadataRecord",
            predicate: NSPredicate(value: true)
        )

        do {
            let (results, _) = try await db.records(
                matching: query,
                resultsLimit: 1
            )
            return .available(hasData: !results.isEmpty)
        } catch let error as CKError {
            switch error.code {
            case .networkUnavailable, .networkFailure:
                return .unavailable(reason: .noNetwork)
            case .notAuthenticated:
                return .unavailable(reason: .notSignedIn)
            default:
                // Other CKErrors (e.g. unknownItem on fresh container)
                // — treat as "available but no data".
                return .available(hasData: false)
            }
        } catch {
            return .unavailable(reason: .couldNotDetermine)
        }
    }
}
