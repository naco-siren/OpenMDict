//
//  CoreDataStack.swift
//  OpenMDict-iOS
//
//  Singleton managing the Core Data persistent container.
//  Provides a main-queue viewContext for reads and
//  background contexts for writes.
//

import CoreData

final class CoreDataStack {

    static let shared = CoreDataStack()

    // MARK: - Container

    /// Persistent container for the OpenMDict_iOS data model.
    /// Lazily loaded — the store is created on first access.
    /// Store is placed in the App Group shared container for extension access.
    private lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "OpenMDict_iOS")

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
        container.persistentStoreDescriptions = [
            NSPersistentStoreDescription(url: storeURL)
        ]

        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                // In a shipping app we log and continue rather than crash.
                // An uninitialized store simply means history won't persist.
                debugLog("❌ CoreData failed to load: \(error), \(error.userInfo)")
            } else {
                debugLog("✅ CoreData store loaded: \(description.url?.path ?? "?")")
            }
        }
        // Automatically merge background-context saves into the viewContext.
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
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
