//
//  CoreDataStack.swift
//  OpenMDict-iOS
//
//  Singleton managing the Core Data persistent container.
//  Provides a main-queue viewContext for reads and
//  background contexts for writes.
//
//  Uses NSPersistentCloudKitContainer.  CloudKit sync is enabled
//  or disabled based on the `enableCloudKit` parameter passed to
//  `setup(enableCloudKit:)`.  When disabled, the container still
//  uses NSPersistentCloudKitContainer (for uniform API) but omits
//  `cloudKitContainerOptions` — making it a local-only store.
//
//  Persistent history tracking is ALWAYS enabled, even in offline
//  mode.  This allows a future offline → cloud transition to export
//  pre-existing records to CloudKit automatically.
//

import CloudKit
import Combine
import CoreData

final class CoreDataStack {

    static let shared = CoreDataStack()

    // MARK: - Remote Change Publisher

    /// Emits when CloudKit remote changes arrive in the local store.
    /// Each Service subscribes with its own `.debounce()` to refresh caches.
    let remoteChangePublisher = PassthroughSubject<Void, Never>()

    /// Optional async hook called before `remoteChangePublisher.send()`.
    /// The main app installs DeduplicationService here; extensions leave
    /// it nil so they don't need to link the dedup code.
    var remoteChangePreprocessor: (() async -> Void)?

    private var remoteChangeObserver: Any?

    /// Coalesces rapid-fire NSPersistentStoreRemoteChange notifications
    /// into a single dedup + publish cycle.  Without this, startup can
    /// fire 20+ notifications, each spawning a concurrent deduplicateAll()
    /// Task — a thundering herd that saturates the CPU and deadlocks.
    private var remoteChangeWorkItem: DispatchWorkItem?

    /// Guards against re-entrant preprocessor runs.
    /// While a dedup pass is in flight, new notifications are coalesced
    /// but won't spawn a second concurrent pass.
    private var isProcessingRemoteChange = false

    // MARK: - CloudKit Mirroring Events

    /// Emits the end time of every successful CloudKit import observed in
    /// this process. `DictionaryService` re-evaluates pending remote deletes
    /// on it, so a mirroring reset that re-imports the zone resolves cleanly.
    let cloudKitImportCompletedPublisher = PassthroughSubject<Date, Never>()

    /// Bumped whenever the mirroring-reset bookkeeping changes
    /// (the troubleshooting screen subscribes to refresh its status row).
    @Published private(set) var mirroringStatusRevision: UInt = 0

    /// End time of the most recent successful CloudKit import in this process.
    private(set) var lastSuccessfulImportEnd: Date?

    /// `true` from the moment a CloudKit event fails in a way that makes
    /// `NSPersistentCloudKitContainer` reset its mirror (expired persistent-
    /// history token, expired server change token, zone gone) until the next
    /// successful import completes. A reset purges EVERY mirrored row locally
    /// before re-importing, so while this is set the disappearance of a row
    /// must not be read as "another device deleted it".
    private(set) var isMirroringResetSuspected = false
    private(set) var mirroringResetSuspectedAt: Date?

    private var cloudKitEventObserver: Any?

    private static let lastResetDateKey = "cloudkit.lastMirroringResetAt"
    private static let lastResetReasonKey = "cloudkit.lastMirroringResetReason"
    private static let resetCountKey = "cloudkit.mirroringResetCount"

    /// The most recent mirroring reset seen on this device, persisted across
    /// launches for the troubleshooting screen.
    var lastMirroringReset: (date: Date, reason: String)? {
        guard let date = UserDefaults.standard.object(forKey: Self.lastResetDateKey) as? Date else {
            return nil
        }
        return (date, UserDefaults.standard.string(forKey: Self.lastResetReasonKey) ?? "unknown")
    }

    /// How many mirroring resets this device has recorded.
    var mirroringResetCount: Int {
        UserDefaults.standard.integer(forKey: Self.resetCountKey)
    }

    // MARK: - Container

    /// Backing storage — set by `setup(enableCloudKit:)` or
    /// `reloadWithCloudKit()`.  Accessing before `setup()` is a
    /// programmer error.
    private var _persistentContainer: NSPersistentContainer?

    private var persistentContainer: NSPersistentContainer {
        guard let c = _persistentContainer else {
            fatalError("CoreDataStack.setup(enableCloudKit:) must be called before accessing the container")
        }
        return c
    }

    // MARK: - Contexts

    /// Main-queue context for reads and lightweight UI-driven writes.
    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    /// Create a new private-queue context for background writes.
    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = persistentContainer.newBackgroundContext()
        ctx.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return ctx
    }

    // MARK: - Lifecycle

    /// Initialise the persistent store.
    /// Call once, early in the app lifecycle (AppDelegate).
    ///
    /// - Parameter enableCloudKit: When `true`, the store description
    ///   includes `cloudKitContainerOptions` and CloudKit sync begins
    ///   immediately.  When `false`, the store is local-only.
    func setup(enableCloudKit: Bool) {
        guard _persistentContainer == nil else { return }
        _persistentContainer = createContainer(enableCloudKit: enableCloudKit)
        if enableCloudKit {
            installRemoteChangeObserver()
            installCloudKitEventObserver()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: Self.debugExpireHistoryOnLaunchKey) {
                // Test harness: expire the cloud store's history BEFORE the
                // mirroring delegate's post-setup export, reproducing the
                // 2026-10-08 launch-order race deterministically.
                let expired = debugExpireCloudStoreHistory()
                debugLog("🧪 DEBUG: expireHistoryOnLaunch → \(expired ? "expired" : "FAILED")")
            }
            #endif
            purgeLocalStoreHistory()
        }
    }

    /// Tear down the current (local-only) container and recreate it
    /// with CloudKit sync enabled.
    ///
    /// **Safety**: Only call during first-launch setup, when the store
    /// is empty and no Service has cached a viewContext reference.
    /// `DictionaryService.setup()` must NOT have been called yet.
    func reloadWithCloudKit() {
        // Remove existing observer
        if let obs = remoteChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            remoteChangeObserver = nil
        }

        // Recreate container with CloudKit
        _persistentContainer = createContainer(enableCloudKit: true)
        installRemoteChangeObserver()
        installCloudKitEventObserver()

        debugLog("☁️ CoreDataStack: reloaded with CloudKit enabled")
    }

    /// Save the viewContext if it has changes.
    func saveViewContext() {
        let ctx = viewContext
        guard ctx.hasChanges else { return }
        do {
            try ctx.save()
        } catch {
            debugLog("❌ CoreData viewContext save failed: \(error)")
        }
    }

    // MARK: - Reset

    /// Tear down the current container, delete all local stores and mirror
    /// metadata, and recreate a fresh container.
    ///
    /// Used by the iCloud reset flow (nuclear option) to clear all local
    /// CoreData state and start over.
    ///
    /// - Parameter enableCloudKit: Whether the new container should have
    ///   CloudKit sync enabled.
    func resetAndRecreateContainer(enableCloudKit: Bool) {
        // 1. Remove observers and cancel pending work.
        if let obs = remoteChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            remoteChangeObserver = nil
        }
        removeCloudKitEventObserver()
        resetMirroringState()
        remoteChangeWorkItem?.cancel()
        remoteChangeWorkItem = nil
        isProcessingRemoteChange = false

        // 2. Reset the viewContext to detach all managed objects.
        _persistentContainer?.viewContext.reset()

        // 3. Remove persistent stores from the coordinator.
        if let coordinator = _persistentContainer?.persistentStoreCoordinator {
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }

        // 4. Delete SQLite files.
        let url = Self.storeURL()
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            try? FileManager.default.removeItem(at: fileURL)
        }

        // 5. Delete CloudKit mirror metadata directory.
        let ckDir = url.deletingLastPathComponent()
            .appendingPathComponent("ckAssetFiles")
        try? FileManager.default.removeItem(at: ckDir)

        // 6. Nil out the container.
        _persistentContainer = nil

        // 7. Recreate.
        _persistentContainer = createContainer(enableCloudKit: enableCloudKit)
        if enableCloudKit {
            installRemoteChangeObserver()
            installCloudKitEventObserver()
            purgeLocalStoreHistory()
        }

        debugLog("🔄 CoreDataStack: container reset and recreated (CloudKit=\(enableCloudKit))")
    }

    /// The SQLite store URL for the CloudKit-synced (Default) configuration.
    /// Holds the M11 entities: bookmarks, lookup history, dict metadata,
    /// groups, lookup counts.
    static func cloudStoreURL() -> URL {
        appSupportDir().appendingPathComponent("OpenMDict_iOS.sqlite")
    }

    /// The SQLite store URL for the local-only (Local) configuration.
    /// Holds M15 Phase 3's ArticleIndexRecord — never synced because
    /// indexing state is per-device. See ArticleIndexRecord's XML
    /// comment + this file's `createContainer(...)` for details.
    static func localStoreURL() -> URL {
        appSupportDir().appendingPathComponent("OpenMDict_iOS_Local.sqlite")
    }

    /// Backward-compat: callers prior to the two-store split used this
    /// to get THE store URL. Now resolves to the CloudKit store.
    static func storeURL() -> URL { cloudStoreURL() }

    /// App Group Application Support directory. Both stores live here.
    private static func appSupportDir() -> URL {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier
        ) else {
            fatalError("App Group container unavailable")
        }
        let dir = groupURL.appendingPathComponent(
            "Library/Application Support", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    // MARK: - Private

    /// Build and load a persistent container.
    ///
    /// Two physical SQLite files are loaded into the same container,
    /// each bound to a CoreData Configuration:
    ///
    ///   "Default" → `OpenMDict_iOS.sqlite`
    ///      Bookmarks, lookup history, dict metadata, groups, lookup
    ///      counts. CloudKit-synced when `enableCloudKit == true`.
    ///   "Local"   → `OpenMDict_iOS_Local.sqlite`
    ///      M15 Phase 3 article-embedding state. NEVER synced — the
    ///      state is per-device (each device builds its own sidecar
    ///      from local files; cross-device sync would just create
    ///      stale rows that the Coordinator immediately invalidates).
    ///
    /// Both stores share the same viewContext / background contexts.
    /// Fetch / insert / save are transparent — the Configuration name
    /// only affects which physical file the row lives in.
    ///
    /// - Parameter enableCloudKit: Applies to the Default store only.
    ///   The Local store is always local-only.
    private func createContainer(enableCloudKit: Bool) -> NSPersistentContainer {
        let container = NSPersistentCloudKitContainer(name: "OpenMDict_iOS")

        // CloudKit (or local-when-disabled) store, holds M11 entities.
        let cloudDesc = NSPersistentStoreDescription(url: Self.cloudStoreURL())
        cloudDesc.configuration = "Default"
        if enableCloudKit {
            cloudDesc.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: AppIdentifiers.cloudKitContainerID
            )
        }
        // Persistent history tracking must be enabled in ALL processes that
        // write to this store — including the Action Extension, which opens
        // the same SQLite with enableCloudKit: false.
        //
        // If the main app has CloudKit enabled (history tracking ON) and any
        // other process opens the store WITHOUT history tracking, CoreData
        // cannot create the required transaction entries → ctx.save() throws
        // → writes silently fail (e.g. bookmark toggle shows no response).
        //
        // Apple's requirement: "All processes sharing a CloudKit-backed store
        // must enable persistent history tracking."
        //
        // Remote change notifications are separate: the Action Extension does
        // not need to receive them, so keep that flag CloudKit-only.
        cloudDesc.setOption(true as NSNumber,
                            forKey: NSPersistentHistoryTrackingKey)
        if enableCloudKit {
            cloudDesc.setOption(true as NSNumber,
                                forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }

        // Local-only store, holds ArticleIndexRecord. Never CloudKit.
        // History tracking still enabled for consistency with the cloud
        // store (the Action Extension reads/writes both with the same
        // setup() call, so they need symmetric requirements).
        let localDesc = NSPersistentStoreDescription(url: Self.localStoreURL())
        localDesc.configuration = "Local"
        localDesc.setOption(true as NSNumber,
                            forKey: NSPersistentHistoryTrackingKey)

        container.persistentStoreDescriptions = [cloudDesc, localDesc]

        // loadPersistentStores invokes the completion handler ONCE per
        // store description. We track which configs succeeded vs failed
        // and attempt store-by-store recovery for any that errored.
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                let configName = description.configuration ?? "?"
                debugLog("❌ CoreData [\(configName)] failed to load: \(error), \(error.userInfo)")

                // Recovery: delete the corrupt store and retry just it.
                // Common causes: lightweight migration failure after schema change,
                // corrupt WAL journal from force-kill during write.
                if let url = description.url {
                    debugLog("⚠️ CoreData [\(configName)]: attempting recovery — deleting store at \(url.lastPathComponent)")
                    for suffix in ["", "-wal", "-shm"] {
                        let fileURL = URL(fileURLWithPath: url.path + suffix)
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                    // Also remove CloudKit mirror metadata if present
                    let ckDir = url.deletingLastPathComponent()
                        .appendingPathComponent("ckAssetFiles")
                    try? FileManager.default.removeItem(at: ckDir)

                    // Retry load — invokes completion handler for ALL
                    // already-loaded stores again too, so guard against
                    // re-loading via the configuration check (an already-
                    // loaded store will simply succeed).
                    container.loadPersistentStores { desc2, error2 in
                        let cfg2 = desc2.configuration ?? "?"
                        if let error2 = error2 {
                            debugLog("❌ CoreData [\(cfg2)] recovery also failed: \(error2)")
                        } else {
                            debugLog("✅ CoreData [\(cfg2)] recovered (CloudKit=\(enableCloudKit)): \(desc2.url?.path ?? "?")")
                        }
                    }
                }
            } else {
                let configName = description.configuration ?? "?"
                debugLog("✅ CoreData [\(configName)] loaded (CloudKit=\(enableCloudKit && description.cloudKitContainerOptions != nil)): \(description.url?.path ?? "?")")
            }
        }

        // Automatically merge background-context saves into the viewContext.
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.name = "viewContext"

        return container
    }

    /// Purge persistent history older than 7 days from the LOCAL store only.
    ///
    /// The cloud ("Default") store is deliberately never purged.
    /// `NSPersistentCloudKitContainer` anchors its exporter on a
    /// persistent-history token — the number of the last transaction it
    /// analysed — and Core Data reports that token as expired
    /// (`NSPersistentHistoryTokenExpiredError`, 134301) the moment that
    /// transaction row no longer exists, regardless of its age or of any
    /// newer transactions. An export with nothing to do does not advance the
    /// token, so on a device that sat idle for a week the old date-based
    /// purge deleted the anchor, the next export failed, and the mirroring
    /// delegate reset with reason "HistoryExpired": every mirrored row was
    /// purged locally and the whole zone re-imported (2026-10-08 incident).
    /// Apple's guidance for mirrored stores is to leave history alone.
    ///
    /// The Local store (article-index state) has no history consumer, so a
    /// date cutoff is safe there. `affectedStores` confines the request —
    /// without it the request would purge both stores.
    func purgeLocalStoreHistory() {
        let ctx = newBackgroundContext()
        let localURL = Self.localStoreURL()
        Task.detached {
            await ctx.perform {
                guard let localStore = ctx.persistentStoreCoordinator?.persistentStore(for: localURL) else {
                    return
                }
                let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
                let request = NSPersistentHistoryChangeRequest.deleteHistory(before: cutoff)
                request.affectedStores = [localStore]
                do {
                    try ctx.execute(request)
                    debugLog("🧹 Purged Local-store persistent history older than 7 days (cloud store untouched)")
                } catch {
                    debugLog("⚠️ Local-store history purge failed: \(error)")
                }
            }
        }
    }

    // MARK: - CloudKit Event Observer

    /// Observe `NSPersistentCloudKitContainer.eventChangedNotification`
    /// (public API, iOS 14+) for the whole life of the process so the app can
    /// tell a mirroring reset apart from genuine remote changes.
    private func installCloudKitEventObserver() {
        guard cloudKitEventObserver == nil else { return }
        cloudKitEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Destructure inside the closure: Notification is not Sendable.
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            let type = event.type
            let endDate = event.endDate
            let succeeded = event.succeeded
            let nsError = event.error as NSError?
            let domain = nsError?.domain
            let code = nsError?.code
            MainActor.assumeIsolated {
                self?.handleCloudKitEvent(type: type, endDate: endDate, succeeded: succeeded,
                                          errorDomain: domain, errorCode: code)
            }
        }
    }

    private func removeCloudKitEventObserver() {
        if let obs = cloudKitEventObserver {
            NotificationCenter.default.removeObserver(obs)
            cloudKitEventObserver = nil
        }
    }

    /// Forget any in-flight reset suspicion (container is being recreated).
    private func resetMirroringState() {
        isMirroringResetSuspected = false
        mirroringResetSuspectedAt = nil
        lastSuccessfulImportEnd = nil
        mirroringStatusRevision &+= 1
    }

    /// Maps a failed CloudKit event's error to the reason the mirroring
    /// delegate will reset for, or nil when the error does not cause a reset.
    ///
    /// 134301 is `NSPersistentHistoryTokenExpiredError`; the CloudKit codes
    /// are the ones the delegate's recovery path treats as "start over".
    nonisolated static func mirroringResetReason(errorDomain: String, errorCode: Int) -> String? {
        if errorDomain == NSCocoaErrorDomain && errorCode == 134301 {
            return "historyExpired"
        }
        if errorDomain == CKErrorDomain {
            switch CKError.Code(rawValue: errorCode) {
            case .changeTokenExpired: return "changeTokenExpired"
            case .zoneNotFound, .userDeletedZone: return "zoneDeleted"
            default: return nil
            }
        }
        return nil
    }

    private static func eventTypeName(_ type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: return "setup"
        case .import: return "import"
        case .export: return "export"
        @unknown default: return "unknown"
        }
    }

    private func handleCloudKitEvent(
        type: NSPersistentCloudKitContainer.EventType,
        endDate: Date?,
        succeeded: Bool,
        errorDomain: String?,
        errorCode: Int?
    ) {
        // Each request posts once when it starts (no endDate) and once when
        // it finishes; only finished events carry a result.
        guard let endDate else { return }
        let name = Self.eventTypeName(type)

        if !succeeded {
            debugLog("☁️ CloudKit \(name) failed: \(errorDomain ?? "?") \(errorCode ?? 0)")
            if let domain = errorDomain, let code = errorCode,
               let reason = Self.mirroringResetReason(errorDomain: domain, errorCode: code),
               !isMirroringResetSuspected {
                isMirroringResetSuspected = true
                mirroringResetSuspectedAt = endDate
                recordMirroringReset(reason: reason, at: endDate)
                debugLog("☁️⚠️ CloudKit mirroring reset suspected (\(reason)) — remote deletes on hold until the next successful import")
                mirroringStatusRevision &+= 1
            }
            return
        }

        debugLog("☁️ CloudKit \(name) succeeded")
        guard type == .import else { return }
        lastSuccessfulImportEnd = endDate
        if isMirroringResetSuspected {
            isMirroringResetSuspected = false
            debugLog("☁️✅ CloudKit mirroring reset recovered — import completed")
            mirroringStatusRevision &+= 1
        }
        cloudKitImportCompletedPublisher.send(endDate)
    }

    private func recordMirroringReset(reason: String, at date: Date) {
        let defaults = UserDefaults.standard
        defaults.set(date, forKey: Self.lastResetDateKey)
        defaults.set(reason, forKey: Self.lastResetReasonKey)
        defaults.set(defaults.integer(forKey: Self.resetCountKey) + 1, forKey: Self.resetCountKey)
    }

    #if DEBUG
    // MARK: - Debug Harness (HistoryExpired reproduction)

    /// Launch argument `-openmdict.debug.expireHistoryOnLaunch 1`: expire the
    /// cloud store's history right after the stores load, before the first
    /// export — the exact order of the 2026-10-08 incident.
    static let debugExpireHistoryOnLaunchKey = "openmdict.debug.expireHistoryOnLaunch"

    /// Delete EVERY persistent-history transaction of the cloud store.
    ///
    /// The mirroring exporter's stored token then refers to a transaction
    /// that no longer exists, so its next export (the post-setup export on
    /// the next launch, or the one triggered by any local save) fails with
    /// 134301 and the delegate resets with reason HistoryExpired — the same
    /// state a device reaches after sitting idle through the old 7-day purge.
    @discardableResult
    func debugExpireCloudStoreHistory() -> Bool {
        let ctx = newBackgroundContext()
        let url = Self.cloudStoreURL()
        var ok = false
        ctx.performAndWait {
            guard let store = ctx.persistentStoreCoordinator?.persistentStore(for: url) else { return }
            let request = NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture)
            request.affectedStores = [store]
            do {
                try ctx.execute(request)
                ok = true
            } catch {
                debugLog("🧪 DEBUG: expire cloud-store history failed: \(error)")
            }
        }
        if ok {
            debugLog("🧪 DEBUG: expired ALL cloud-store persistent history — the next CloudKit export will fail with 134301 (HistoryExpired)")
        }
        return ok
    }

    /// Number of persistent-history transactions stored for the cloud store.
    func debugCloudStoreHistoryTransactionCount() -> Int {
        let ctx = newBackgroundContext()
        let url = Self.cloudStoreURL()
        var count = 0
        ctx.performAndWait {
            guard let store = ctx.persistentStoreCoordinator?.persistentStore(for: url) else { return }
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
            request.affectedStores = [store]
            request.fetchRequest = NSPersistentHistoryTransaction.fetchRequest
            guard let result = try? ctx.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction] else { return }
            count = transactions.count
        }
        return count
    }
    #endif

    /// Subscribe to NSPersistentStoreRemoteChange and relay via
    /// `remoteChangePublisher`.
    ///
    /// Pipeline: remote change → debounce → preprocessor (dedup) → publish.
    ///
    /// Notifications are coalesced with a 0.3 s debounce window.  While a
    /// preprocessor pass is in flight, additional notifications set a
    /// `pendingRemoteChange` flag so that exactly one follow-up pass runs
    /// after the current one finishes — no thundering herd.
    private func installRemoteChangeObserver() {
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistentContainer.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            debugLog("☁️ Remote change detected")
            // NotificationCenter closure is @Sendable nonisolated even
            // though queue: .main guarantees the main thread.  Hop to
            // MainActor explicitly so Swift 6 can verify isolation.
            Task { @MainActor in
                self?.scheduleRemoteChangeProcessing()
            }
        }
    }

    /// Debounce + single-flight guard for remote change processing.
    private func scheduleRemoteChangeProcessing() {
        // Cancel any pending debounce timer — we'll restart it.
        remoteChangeWorkItem?.cancel()

        // If a preprocessor pass is already running, just mark that
        // another round is needed once it finishes.
        if isProcessingRemoteChange {
            // The flag itself acts as "pending" — when the in-flight
            // pass finishes, it checks and re-schedules.
            remoteChangeWorkItem = DispatchWorkItem { [weak self] in
                self?.executeRemoteChangeProcessing()
            }
            // Don't schedule immediately — let the current pass finish
            // and re-check in executeRemoteChangeProcessing().
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.executeRemoteChangeProcessing()
        }
        remoteChangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Runs dedup (if installed) then publishes.  Re-checks for
    /// additional notifications that arrived while running.
    private func executeRemoteChangeProcessing() {
        guard !isProcessingRemoteChange else { return }
        isProcessingRemoteChange = true
        remoteChangeWorkItem = nil

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let preprocessor = self.remoteChangePreprocessor {
                await preprocessor()
            }
            self.remoteChangePublisher.send()

            self.isProcessingRemoteChange = false

            // If more notifications arrived while we were processing,
            // schedule one follow-up pass (debounced).
            // We detect this by checking if scheduleRemoteChangeProcessing()
            // left a pending workItem while we were busy.
            if self.remoteChangeWorkItem != nil {
                debugLog("☁️ Remote change: re-processing queued notifications")
                self.remoteChangeWorkItem = nil
                self.scheduleRemoteChangeProcessing()
            }
        }
    }
}
