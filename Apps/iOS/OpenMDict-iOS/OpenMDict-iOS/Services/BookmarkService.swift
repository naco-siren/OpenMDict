//
//  BookmarkService.swift
//  OpenMDict-iOS
//
//  CRUD for bookmark records.
//  Writes happen on the viewContext; batch delete uses a background context.
//  Publishes `revision` (Combine @Published) after every mutation so the
//  UI can react without NotificationCenter.
//
//  Thread-safety:
//  - BookmarkRecord is `nonisolated` (not MainActor-isolated), matching
//    CoreData's own context-queue confinement threading model.
//  - UI layer receives BookmarkItem (Sendable value type) instead.
//

import Combine
import CoreData
import Foundation

// MARK: - Value Type (Sendable, Hashable)

/// Sendable value type representing a bookmark.
/// Decouples the UI layer from NSManagedObject.
/// Defined at file scope (not nested inside BookmarkService) so that
/// Hashable conformance is nonisolated — required for DiffableDataSource
/// under the project's `-default-isolation=MainActor` setting.
nonisolated struct BookmarkItem: Sendable, Hashable, DateGroupable {
    let objectID: NSManagedObjectID
    let word: String
    let dictId: String
    let dictName: String
    /// Whether the referenced dictionary exists on this device.
    /// `false` for records synced from another device whose dictionary hasn't been synced yet.
    let isDictAvailable: Bool
    let createdAt: Date?

    var groupingDate: Date? { createdAt }

    func hash(into hasher: inout Hasher) {
        hasher.combine(word)
        hasher.combine(dictId)
    }

    static func == (lhs: BookmarkItem, rhs: BookmarkItem) -> Bool {
        lhs.word == rhs.word && lhs.dictId == rhs.dictId
    }
}

// MARK: - BookmarkService

final class BookmarkService {

    static let shared = BookmarkService()

    /// Monotonically increasing revision counter; incremented after every
    /// mutation (insert / delete / clear).  Downstream consumers subscribe
    /// via `$revision.dropFirst()` to react to changes.
    @Published private(set) var revision: UInt = 0

    private var stack: CoreDataStack { CoreDataStack.shared }

    /// Cancellable for CloudKit remote change subscription.
    private var remoteChangeCancellable: AnyCancellable?

    private init() {
        // CloudKit remote change — bump revision so UI re-fetches from CoreData
        remoteChangeCancellable = CoreDataStack.shared.remoteChangePublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                debugLog("☁️ BookmarkService: remote change → revision bump")
                self?.revision += 1
            }
    }

    // MARK: - Toggle (Insert or Delete)

    /// Toggle a bookmark. If a record with the same (word, dictId) exists,
    /// delete it; otherwise create a new one.
    ///
    /// - Returns: `true` if a bookmark was created, `false` if it was removed.
    @discardableResult
    func toggleBookmark(word: String, dictId: String) -> Bool {
        let ctx = stack.viewContext
        let request = NSFetchRequest<BookmarkRecord>(entityName: "BookmarkRecord")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "word == %@", word),
            NSPredicate(format: "dictId == %@", dictId),
        ])
        // No fetchLimit — delete ALL duplicates if CloudKit sync created them.

        do {
            let matches = try ctx.fetch(request)
            if let existing = matches.first {
                // Already bookmarked → remove all matching records
                for match in matches { ctx.delete(match) }
                try ctx.save()
                revision += 1
                return false
            } else {
                // Not bookmarked → create
                let record = BookmarkRecord(context: ctx)
                record.word = word
                record.dictId = dictId
                record.createdAt = Date()
                try ctx.save()
                revision += 1
                return true
            }
        } catch {
            debugLog("❌ BookmarkService toggleBookmark failed: \(error)")
            return false
        }
    }

    // MARK: - Query

    /// Check if a (word, dictId) pair is bookmarked.
    func isBookmarked(word: String, dictId: String) -> Bool {
        let ctx = stack.viewContext
        let request = NSFetchRequest<BookmarkRecord>(entityName: "BookmarkRecord")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "word == %@", word),
            NSPredicate(format: "dictId == %@", dictId),
        ])
        request.fetchLimit = 1

        do {
            let count = try ctx.count(for: request)
            return count > 0
        } catch {
            debugLog("❌ BookmarkService isBookmarked failed: \(error)")
            return false
        }
    }

    /// Fetch all bookmarks, most recent first.
    /// Note: `dictName` and `isDictAvailable` are populated with defaults here.
    /// The UI layer resolves the actual display name from `DictMetadataService`.
    func allBookmarks() -> [BookmarkItem] {
        let ctx = stack.viewContext
        let request = NSFetchRequest<BookmarkRecord>(entityName: "BookmarkRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            let records = try ctx.fetch(request)
            return records.map { record in
                BookmarkItem(
                    objectID: record.objectID,
                    word: record.word ?? "",
                    dictId: record.dictId ?? "",
                    dictName: "",
                    isDictAvailable: true,
                    createdAt: record.createdAt
                )
            }
        } catch {
            debugLog("❌ BookmarkService allBookmarks fetch failed: \(error)")
            return []
        }
    }

    // MARK: - Delete

    /// Delete a single bookmark by its managed object ID.
    func deleteBookmark(objectID: NSManagedObjectID) {
        // Use existingObject(with:) — object(with:) returns a fault for
        // already-deleted objects, causing an uncatchable ObjC exception on save().
        // This can happen when the dedup service deletes the record concurrently.
        let ctx = stack.viewContext
        do {
            let object = try ctx.existingObject(with: objectID)
            ctx.delete(object)
            try ctx.save()
            revision += 1
        } catch {
            debugLog("❌ BookmarkService deleteBookmark failed: \(error)")
        }
    }

    /// Delete all bookmarks.
    func clearAll() {
        let ctx = self.stack.newBackgroundContext()
        let viewContext = self.stack.viewContext
        Task.detached {
            var success = false
            do {
                try await ctx.perform(schedule: .immediate as NSManagedObjectContext.ScheduledTaskType) {
                    let request = NSFetchRequest<NSFetchRequestResult>(entityName: "BookmarkRecord")
                    let batchDelete = NSBatchDeleteRequest(fetchRequest: request)
                    batchDelete.resultType = .resultTypeObjectIDs

                    let result = try ctx.execute(batchDelete) as? NSBatchDeleteResult
                    if let objectIDs = result?.result as? [NSManagedObjectID] {
                        NSManagedObjectContext.mergeChanges(
                            fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                            into: [viewContext]
                        )
                    }
                }
                success = true
            } catch {
                debugLog("❌ BookmarkService clearAll failed: \(error)")
            }
            if success {
                await MainActor.run {
                    BookmarkService.shared.revision += 1
                }
            }
        }
    }
}
