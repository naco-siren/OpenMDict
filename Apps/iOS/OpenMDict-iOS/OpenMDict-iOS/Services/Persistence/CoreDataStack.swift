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
        installRemoteChangeObserver()
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

    // MARK: - Private

    /// Build and load a persistent container.
    ///
    /// - Parameter enableCloudKit: Whether to attach CloudKit sync
    ///   options to the store description.
    private func createContainer(enableCloudKit: Bool) -> NSPersistentContainer {
        let container = NSPersistentCloudKitContainer(name: "OpenMDict_iOS")

        // Place the store in the App Group shared container so that
        // extensions (Action Extension, etc.) can access the same data.
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier
        ) else {
            fatalError("App Group container unavailable — check Signing & Capabilities → App Groups")
        }
        let storeDir = groupURL.appendingPathComponent(
            "Library/Application Support", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: storeDir, withIntermediateDirectories: true
        )
        let storeURL = storeDir.appendingPathComponent("OpenMDict_iOS.sqlite")

        let description = NSPersistentStoreDescription(url: storeURL)

        // CloudKit configuration — only when user opted in
        if enableCloudKit {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: AppIdentifiers.cloudKitContainerID
            )
        }

        // Persistent history tracking — ALWAYS enabled.
        // Required by CloudKit sync, and also allows a future
        // offline → cloud transition to export existing records.
        description.setOption(true as NSNumber,
                              forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber,
                              forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                debugLog("❌ CoreData failed to load: \(error), \(error.userInfo)")
            } else {
                debugLog("✅ CoreData store loaded (CloudKit=\(enableCloudKit)): \(description.url?.path ?? "?")")
            }
        }

        // Automatically merge background-context saves into the viewContext.
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.name = "viewContext"

        return container
    }

    /// Subscribe to NSPersistentStoreRemoteChange and relay via
    /// `remoteChangePublisher`.
    ///
    /// Pipeline: remote change → preprocessor (dedup) → publish.
    private func installRemoteChangeObserver() {
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistentContainer.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            debugLog("☁️ Remote change detected")
            if let preprocessor = self?.remoteChangePreprocessor {
                Task { @MainActor in
                    await preprocessor()
                    self?.remoteChangePublisher.send()
                }
            } else {
                self?.remoteChangePublisher.send()
            }
        }
    }
}
