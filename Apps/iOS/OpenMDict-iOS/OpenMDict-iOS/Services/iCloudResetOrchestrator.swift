//
//  iCloudResetOrchestrator.swift
//  OpenMDict-iOS
//
//  Coordinates the multi-step iCloud nuclear reset (Tier 3).
//
//  Two roles:
//
//  A. **Active reset** (Device A — the device that initiates the nuke):
//     1. Write NuclearResetSignal to default zone (propagation flag)
//     2. Delete CloudKit zone  → if this fails, ABORT (don't touch local data)
//     3. Delete DictionaryFile records → non-fatal, orphans are harmless
//     4. Clear all Service in-memory caches
//     5. Delete local dictionary files and MDD cache
//     6. Reset and recreate CoreData container
//     7. Re-install remote change preprocessor
//
//  B. **Passive reset** (Device B/C/… — other devices that detect the signal):
//     Called from remoteChangePreprocessor or app launch when an
//     unprocessed NuclearResetSignal is found in the default zone.
//     1. Mark signal as processed (prevent re-trigger)
//     2. Clear all Service in-memory caches
//     3. Delete local dictionary files and MDD cache
//     4. Reset and recreate CoreData container (stops re-export)
//     5. Delete CloudKit zone again (clean up re-exported corrupt data)
//     6. Delete DictionaryFile records (non-fatal)
//     7. Re-install remote change preprocessor
//     8. Post notification → UI replaces rootViewController
//
//  The caller (UI layer) is responsible for post-reset app state transition
//  (destroying extra scenes, replacing rootViewController, etc.).
//

import Foundation

final class iCloudResetOrchestrator {

    static let shared = iCloudResetOrchestrator()

    private init() {}

    /// Guards against concurrent passive reset runs.
    private var isPassiveResetInProgress = false

    // MARK: - Progress

    enum Progress {
        case starting
        case deletingCloudData
        case deletingLocalData
        case recreatingDatabase
        case complete
        case failed(Error)
    }

    // MARK: - Tier 3: Active Nuclear Reset (Device A)

    /// Clear ALL iCloud data and local data, then recreate an empty container.
    ///
    /// **Safety**: The reset signal is written first, then cloud deletion runs.
    /// If the CloudKit zone deletion fails (e.g. no network), the entire
    /// operation aborts — local data is NOT touched.
    ///
    /// - Parameter onProgress: Called on MainActor with each progress step.
    func performClearAll(onProgress: @escaping (Progress) -> Void) async {
        onProgress(.starting)

        // ── Step 0: Write reset signal to default zone ─────────────
        // This MUST succeed before we delete any data. If writing the
        // signal fails, other devices won't know about the reset and
        // will re-pollute the cloud with their corrupt data.
        do {
            try await CloudKitResetService.shared.writeResetSignal()
        } catch {
            debugLog("❌ Nuclear reset ABORTED — failed to write reset signal: \(error)")
            onProgress(.failed(error))
            return
        }

        // ── Step 1: Delete CloudKit CoreData zone ────────────────────
        onProgress(.deletingCloudData)
        do {
            try await CloudKitResetService.shared.deleteCoreDataZone()
        } catch {
            debugLog("❌ Nuclear reset ABORTED — zone deletion failed: \(error)")
            onProgress(.failed(error))
            return
        }

        // ── Step 2: Delete DictionaryFile records (non-fatal) ────────
        do {
            try await CloudKitResetService.shared.deleteAllDictionaryFileRecords()
        } catch {
            debugLog("⚠️ DictionaryFile cleanup failed (continuing): \(error)")
        }

        // ── Step 3: Clear all Service in-memory caches ───────────────
        clearAllServiceCaches()

        // ── Step 4: Delete local files ───────────────────────────────
        onProgress(.deletingLocalData)
        LocalDataResetService.shared.deleteAllDictionaryFiles()
        LocalDataResetService.shared.deleteMDDCache()

        // ── Step 5: Reset and recreate CoreData container ────────────
        onProgress(.recreatingDatabase)
        CoreDataStack.shared.resetAndRecreateContainer(enableCloudKit: true)

        // ── Step 6: Re-install remote change preprocessor ────────────
        installPreprocessor()

        onProgress(.complete)
        debugLog("✅ Nuclear reset complete — app is in clean state")
    }

    // MARK: - Passive Reset (Device B/C/…)

    /// Check for an unprocessed NuclearResetSignal and, if found,
    /// perform a full local data reset.
    ///
    /// Called from:
    /// - `remoteChangePreprocessor` (triggered by zone deletion push)
    /// - App launch (for devices that were offline/killed)
    ///
    /// - Returns: `true` if a passive reset was performed (caller should
    ///   skip further processing like dedup).
    func checkAndHandlePassiveReset() async -> Bool {
        // Prevent concurrent runs (remote change can fire multiple times).
        guard !isPassiveResetInProgress else { return true }

        guard let uuid = await CloudKitResetService.shared.fetchResetSignalUUID() else {
            return false
        }
        guard !CloudKitResetService.shared.hasProcessedSignal(uuid: uuid) else {
            return false
        }

        debugLog("☁️🔥 Unprocessed NuclearResetSignal detected (uuid=\(uuid)) — starting passive reset")
        isPassiveResetInProgress = true

        // 1. Mark as processed FIRST — if we crash mid-reset, next launch
        //    will find stale local data but won't re-trigger (user can
        //    manually clear or re-nuke).
        CloudKitResetService.shared.markSignalProcessed(uuid: uuid)

        // 2. Clear all Service in-memory caches.
        clearAllServiceCaches()

        // 3. Delete local files.
        LocalDataResetService.shared.deleteAllDictionaryFiles()
        LocalDataResetService.shared.deleteMDDCache()

        // 4. Reset and recreate CoreData container.
        //    This stops the container from re-exporting any more data.
        CoreDataStack.shared.resetAndRecreateContainer(enableCloudKit: true)

        // 5. Delete the CoreData zone AGAIN.
        //    The original container may have already re-exported corrupt
        //    local data before we caught the signal. Deleting the zone
        //    wipes that re-exported data. The new container will recreate
        //    an empty zone with nothing to export.
        do {
            try await CloudKitResetService.shared.deleteCoreDataZone()
            debugLog("☁️🗑️ Passive reset: deleted CoreData zone (cleanup re-exported data)")
        } catch {
            debugLog("⚠️ Passive reset: zone re-deletion failed (non-fatal): \(error)")
        }

        // 6. Delete DictionaryFile records (non-fatal).
        do {
            try await CloudKitResetService.shared.deleteAllDictionaryFileRecords()
        } catch {
            debugLog("⚠️ Passive reset: DictionaryFile cleanup failed (non-fatal): \(error)")
        }

        // 7. Re-install remote change preprocessor.
        installPreprocessor()

        isPassiveResetInProgress = false

        // 8. Notify UI to reset.
        debugLog("✅ Passive reset complete — posting notification")
        NotificationCenter.default.post(name: .passiveResetDidComplete, object: nil)

        return true
    }

    // MARK: - Shared Helpers

    private func clearAllServiceCaches() {
        DictionaryFileSyncService.shared.cancelAllOperations()
        DictionaryService.shared.resetAllState()
        LookupHistoryService.shared.resetCaches()
        LookupCountService.shared.resetCaches()
        BookmarkCountService.shared.resetCaches()
        BookmarkService.shared.resetCaches()
        DictMetadataService.shared.resetCaches()
    }

    /// Install the standard remote change preprocessor that checks for
    /// passive reset signals before running dedup.
    func installPreprocessor() {
        CoreDataStack.shared.remoteChangePreprocessor = {
            let handled = await iCloudResetOrchestrator.shared.checkAndHandlePassiveReset()
            if handled { return }
            await DeduplicationService.shared.deduplicateAll()
        }
    }
}
