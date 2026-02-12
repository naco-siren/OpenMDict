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
    private lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "OpenMDict_iOS")
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                // In a shipping app we log and continue rather than crash.
                // An uninitialized store simply means history won't persist.
                print("❌ CoreData failed to load: \(error), \(error.userInfo)")
            } else {
                print("✅ CoreData store loaded: \(description.url?.lastPathComponent ?? "?")")
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
            print("❌ CoreData viewContext save failed: \(error)")
        }
    }
}
