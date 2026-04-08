//
//  iCloudResetOrchestrator.swift
//  OpenMDict-iOS
//
//  Coordinates the multi-step iCloud nuclear reset (Tier 3)
//  and local-only factory reset.
//
//  Three roles:
//
//  A. **Active reset** (Device A — the device that initiates the nuke):
//     0. Write NuclearResetSignal to default zone (propagation flag)
//     1. Delete CloudKit zone  → if this fails, ABORT (don't touch local data)
//     2. Delete DictionaryFile records → non-fatal, orphans are harmless
//     3. Clear all Service in-memory caches
//     4. Delete local dictionary files and MDD cache
//     5. Reset sync mode → .notDecided (triggers full setup flow)
//     6. Reset and recreate CoreData container (CloudKit disabled)
//     7. Re-install remote change preprocessor
//
//  A½. **Local-only reset** (offline users):
//     1. Clear all Service in-memory caches
//     2. Delete local dictionary files and MDD cache
//     3. Reset sync mode → .notDecided
//     4. Reset and recreate CoreData container (CloudKit disabled)
//     5. Re-install remote change preprocessor
//
//  B. **Passive reset** (Device B/C/… — other devices that detect the signal):
//     Called from remoteChangePreprocessor or app launch when an
//     unprocessed NuclearResetSignal is found in the default zone.
//     1. Mark signal as processed (prevent re-trigger)
//     2. Clear all Service in-memory caches
//     3. Delete local dictionary files and MDD cache
//     4. Reset sync mode → .notDecided
//     5. Reset and recreate CoreData container (CloudKit disabled)
//     6. Delete CloudKit zone again (clean up re-exported corrupt data)
//     7. Delete DictionaryFile records (non-fatal)
//     8. Re-install remote change preprocessor
//     9. Post notification → UI replaces rootViewController
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

    /// When `true`, the next `checkAndHandlePassiveReset()` call marks any
    /// existing signal as processed WITHOUT performing a reset, then clears
    /// the flag.
    ///
    /// **Why**: On a fresh install that chooses iCloud, `reloadWithCloudKit()`
    /// triggers `NSPersistentStoreRemoteChange` → preprocessor →
    /// `checkAndHandlePassiveReset()`.  If a previous device had done a
    /// nuclear reset, the stale `NuclearResetSignal` record still exists in
    /// the default zone.  This new device has never seen it, so
    /// `hasProcessedSignal()` returns `false` and a spurious passive reset
    /// fires, bouncing the user back to the welcome screen.
    ///
    /// Setting this flag before the first `reloadWithCloudKit()` call
    /// prevents that false trigger while still consuming the stale signal.
    var suppressPassiveResetOnce = false

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
        LocalDataResetService.shared.deleteMDXIndexCache()

        // ── Step 5: Reset sync mode → .notDecided ─────────────────────
        // Forces the full setup flow (sync mode chooser) on next UI reset,
        // just like a fresh install.
        SyncModeService.shared.currentMode = .notDecided

        // ── Step 6: Reset and recreate CoreData container ────────────
        // CloudKit disabled — the setup flow will re-enable it if the
        // user chooses iCloud again.
        onProgress(.recreatingDatabase)
        CoreDataStack.shared.resetAndRecreateContainer(enableCloudKit: false)

        // ── Step 7: Re-install remote change preprocessor ────────────
        // Harmless when CloudKit is disabled (observer not installed).
        // Will be active once setup flow calls reloadWithCloudKit().
        installPreprocessor()

        onProgress(.complete)
        debugLog("✅ Nuclear reset complete — app is in clean state")
    }

    // MARK: - Local-Only Reset (offline users)

    /// Clear all local data without touching CloudKit.
    /// Used when the user has NOT enabled iCloud sync but wants to
    /// factory-reset the app.
    ///
    /// - Parameter onProgress: Called on MainActor with each progress step.
    func performLocalClearAll(onProgress: @escaping (Progress) -> Void) async {
        onProgress(.starting)

        // ── Step 1: Clear all Service in-memory caches ───────────────
        clearAllServiceCaches()

        // ── Step 2: Delete local files ───────────────────────────────
        onProgress(.deletingLocalData)
        LocalDataResetService.shared.deleteAllDictionaryFiles()
        LocalDataResetService.shared.deleteMDDCache()
        LocalDataResetService.shared.deleteMDXIndexCache()

        // ── Step 3: Reset sync mode → .notDecided ────────────────────
        SyncModeService.shared.currentMode = .notDecided

        // ── Step 4: Reset and recreate CoreData container ────────────
        onProgress(.recreatingDatabase)
        CoreDataStack.shared.resetAndRecreateContainer(enableCloudKit: false)

        // ── Step 5: Re-install remote change preprocessor ────────────
        installPreprocessor()

        onProgress(.complete)
        debugLog("✅ Local reset complete — app is in clean state")
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

        // During first-time setup, suppress the reset but consume any stale signal
        // so it won't fire on the next app launch either.
        if suppressPassiveResetOnce {
            suppressPassiveResetOnce = false
            if let uuid = await CloudKitResetService.shared.fetchResetSignalUUID() {
                CloudKitResetService.shared.markSignalProcessed(uuid: uuid)
                debugLog("☁️ Suppressed passive reset during setup — marked stale signal \(uuid) as processed")
            }
            return false
        }

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
        LocalDataResetService.shared.deleteMDXIndexCache()

        // 4. Reset sync mode → .notDecided (full setup flow on UI reset).
        SyncModeService.shared.currentMode = .notDecided

        // 5. Reset and recreate CoreData container (CloudKit disabled).
        //    Stops re-export. Setup flow will re-enable if user picks iCloud.
        CoreDataStack.shared.resetAndRecreateContainer(enableCloudKit: false)

        // 6. Delete the CoreData zone AGAIN.
        //    The original container may have already re-exported corrupt
        //    local data before we caught the signal. Deleting the zone
        //    wipes that re-exported data.
        do {
            try await CloudKitResetService.shared.deleteCoreDataZone()
            debugLog("☁️🗑️ Passive reset: deleted CoreData zone (cleanup re-exported data)")
        } catch {
            debugLog("⚠️ Passive reset: zone re-deletion failed (non-fatal): \(error)")
        }

        // 7. Delete DictionaryFile records (non-fatal).
        do {
            try await CloudKitResetService.shared.deleteAllDictionaryFileRecords()
        } catch {
            debugLog("⚠️ Passive reset: DictionaryFile cleanup failed (non-fatal): \(error)")
        }

        // 8. Re-install remote change preprocessor.
        installPreprocessor()

        isPassiveResetInProgress = false

        // 9. Notify UI to reset.
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
