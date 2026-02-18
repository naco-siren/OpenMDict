//
//  CoreDataStack.swift
//  OpenMDict-iOS
//
//  Singleton managing the Core Data persistent container.
//  Provides a main-queue viewContext for reads and
//  background contexts for writes.
//
//  Uses NSPersistentCloudKitContainer for iCloud sync.
//  When the user is not signed in to iCloud or has iCloud Drive
//  disabled, the container falls back to local-only storage
//  automatically — no crash, just no sync.
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

    /// Persistent container for the OpenMDict_iOS data model.
    /// Lazily loaded — the store is created on first access.
    /// Store is placed in the App Group shared container for extension access.
    /// Uses NSPersistentCloudKitContainer to enable iCloud sync.
    private lazy var persistentContainer: NSPersistentContainer = {
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

        // CloudKit configuration
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: AppIdentifiers.cloudKitContainerID
        )

        // Persistent history tracking (required by CloudKit sync)
        description.setOption(true as NSNumber,
                              forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber,
                              forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                debugLog("❌ CoreData failed to load: \(error), \(error.userInfo)")
            } else {
                debugLog("✅ CoreData store loaded: \(description.url?.path ?? "?")")
            }
        }

        // Automatically merge background-context saves into the viewContext.
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.name = "viewContext"

        return container
    }()

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

    /// Trigger lazy initialisation of the persistent store.
    /// Call early in the app lifecycle (AppDelegate).
    func setup() {
        _ = persistentContainer

        // Listen for remote store changes (CloudKit sync arrivals)
        // and forward to Combine publisher for downstream Services.
        // NSPersistentStoreRemoteChange is a system notification that
        // can only be received via NotificationCenter; we immediately
        // relay it to the Combine publisher so all consumers subscribe
        // via remoteChangePublisher instead.
        //
        // Pipeline: remote change → preprocessor (dedup) → publish
        // The preprocessor is installed by the main app (AppDelegate)
        // and runs deduplication before downstream caches refresh.
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
}
