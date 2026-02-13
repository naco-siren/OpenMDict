//
//  BookmarkService.swift
//  OpenMDict-iOS
//
//  CRUD for bookmark records.
//  Writes happen on the viewContext; batch delete uses a background context.
//  Posts `didChangeNotification` after every mutation so the UI can refresh.
//
//  Thread-safety:
//  - BookmarkRecord is `nonisolated` (not MainActor-isolated), matching
//    CoreData's own context-queue confinement threading model.
//  - UI layer receives BookmarkItem (Sendable value type) instead.
//

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

    /// Posted after any mutation (insert / delete / clear).
    nonisolated static let didChangeNotification = Notification.Name("BookmarkDidChange")

    private var stack: CoreDataStack { CoreDataStack.shared }

    // MARK: - Toggle (Insert or Delete)

    /// Toggle a bookmark. If a record with the same (word, dictId) exists,
    /// delete it; otherwise create a new one.
    ///
    /// - Returns: `true` if a bookmark was created, `false` if it was removed.
    @discardableResult
    func toggleBookmark(word: String, dictId: String, dictName: String) -> Bool {
        let ctx = stack.viewContext
        let request = NSFetchRequest<BookmarkRecord>(entityName: "BookmarkRecord")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "word == %@", word),
            NSPredicate(format: "dictId == %@", dictId),
        ])
        request.fetchLimit = 1

        do {
            if let existing = try ctx.fetch(request).first {
                // Already bookmarked → remove
                ctx.delete(existing)
                try ctx.save()
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
                return false
            } else {
                // Not bookmarked → create
                let record = BookmarkRecord(context: ctx)
                record.word = word
                record.dictId = dictId
                record.dictName = dictName
                record.createdAt = Date()
                try ctx.save()
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
                return true
            }
        } catch {
            print("❌ BookmarkService toggleBookmark failed: \(error)")
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
            print("❌ BookmarkService isBookmarked failed: \(error)")
            return false
        }
    }

    /// Fetch all bookmarks, most recent first.
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
                    dictName: record.dictName ?? "",
                    createdAt: record.createdAt
                )
            }
        } catch {
            print("❌ BookmarkService allBookmarks fetch failed: \(error)")
            return []
        }
    }

    // MARK: - Delete

    /// Delete a single bookmark by its managed object ID.
    func deleteBookmark(objectID: NSManagedObjectID) {
        let ctx = stack.viewContext
        let object = ctx.object(with: objectID)
        ctx.delete(object)
        do {
            try ctx.save()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        } catch {
            print("❌ BookmarkService deleteBookmark failed: \(error)")
        }
    }

    /// Delete all bookmarks.
    func clearAll() {
        let ctx = self.stack.newBackgroundContext()
        let viewContext = self.stack.viewContext
        Task.detached {
            try? await ctx.perform(schedule: .immediate as NSManagedObjectContext.ScheduledTaskType) {
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
            await MainActor.run {
                NotificationCenter.default.post(
                    name: BookmarkService.didChangeNotification, object: nil
                )
            }
        }
    }
}
