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
            purgeOldPersistentHistory()
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
        // 1. Remove remote change observer and cancel pending work.
        if let obs = remoteChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            remoteChangeObserver = nil
        }
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
            purgeOldPersistentHistory()
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

    /// Purge persistent history transactions older than 7 days.
    /// Prevents unbounded WAL growth when CloudKit sync is enabled.
    /// Safe to call on every launch — deleting already-synced history
    /// does not affect CloudKit mirroring.
    func purgeOldPersistentHistory() {
        let ctx = newBackgroundContext()
        Task.detached {
            await ctx.perform {
                let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
                let deleteRequest = NSPersistentHistoryChangeRequest.deleteHistory(
                    before: sevenDaysAgo
                )
                do {
                    try ctx.execute(deleteRequest)
                    debugLog("🧹 Purged persistent history older than 7 days")
                } catch {
                    debugLog("⚠️ Persistent history purge failed: \(error)")
                }
            }
        }
    }

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
