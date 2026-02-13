//
//  LookupHistoryService.swift
//  OpenMDict-iOS
//
//  CRUD and aggregation for lookup history records.
//  Writes happen on a background context; reads use the viewContext.
//  Posts `didChangeNotification` after every mutation so the UI can refresh.
//
//  Thread-safety:
//  - LookupRecord is `nonisolated` (not MainActor-isolated), matching
//    CoreData's own context-queue confinement threading model.
//  - UI layer receives HistoryItem (Sendable value type) instead.
//  - Background writes use Task.detached + await ctx.perform { }.
//

import CoreData
import Foundation

// MARK: - Value Types (file-scope, nonisolated)

/// Sendable value type representing a lookup history record.
/// At file scope so that Hashable conformance is nonisolated
/// (required by DiffableDataSource under `-default-isolation=MainActor`).
nonisolated struct HistoryItem: Sendable, Hashable, DateGroupable {
    let objectID: NSManagedObjectID
    let word: String
    let dictId: String
    let dictName: String
    let lastLookedUpAt: Date?

    var groupingDate: Date? { lastLookedUpAt }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(word)
        hasher.combine(dictId)
    }

    nonisolated static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.word == rhs.word && lhs.dictId == rhs.dictId
    }
}

/// A single date section with its title and records.
/// Thin wrapper around `DateSection<HistoryItem>` for API convenience.
struct HistorySection {
    let title: String
    let records: [HistoryItem]
}

// MARK: - Service

final class LookupHistoryService {

    static let shared = LookupHistoryService()

    /// Posted after any mutation (insert / update / delete / clear).
    nonisolated static let didChangeNotification = Notification.Name("LookupHistoryDidChange")

    private var stack: CoreDataStack { CoreDataStack.shared }

    // MARK: - Record Lookup (Upsert)

    /// Record a lookup. If a record with the same (word, dictId, context) exists,
    /// update `lastLookedUpAt` and increment `lookupCount`.
    /// Otherwise create a new record.
    ///
    /// Context tuple: exactly one of `lookupContextDictId` / `lookupContextGroupId` should be non-nil.
    ///
    /// Also increments the manifest-based per-context trophy counter (monotonically increasing,
    /// independent of history deletion).
    func recordLookup(word: String, dictId: String, dictName: String,
                      lookupContextDictId: String?, lookupContextGroupId: String?) {
        // Increment the manifest-based trophy counter (deferred save)
        DictionaryStorageService.shared.incrementLookupCount(
            contextDictId: lookupContextDictId, contextGroupId: lookupContextGroupId
        )

        // Create background context on MainActor before escaping.
        let ctx = self.stack.newBackgroundContext()
        Task.detached {
            try? await ctx.perform(schedule: .immediate as NSManagedObjectContext.ScheduledTaskType) {
                let request = NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
                var subpredicates: [NSPredicate] = [
                    NSPredicate(format: "word == %@", word),
                    NSPredicate(format: "dictId == %@", dictId),
                ]
                if let ctxDictId = lookupContextDictId {
                    subpredicates.append(NSPredicate(format: "lookupContextDictId == %@", ctxDictId))
                } else {
                    subpredicates.append(NSPredicate(format: "lookupContextDictId == nil OR lookupContextDictId == %@", ""))
                }
                if let ctxGroupId = lookupContextGroupId {
                    subpredicates.append(NSPredicate(format: "lookupContextGroupId == %@", ctxGroupId))
                } else {
                    subpredicates.append(NSPredicate(format: "lookupContextGroupId == nil OR lookupContextGroupId == %@", ""))
                }
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
                request.fetchLimit = 1

                let now = Date()
                if let existing = try ctx.fetch(request).first {
                    existing.lastLookedUpAt = now
                    existing.lookupCount += 1
                    existing.dictName = dictName
                } else {
                    let record = LookupRecord(context: ctx)
                    record.word = word
                    record.dictId = dictId
                    record.dictName = dictName
                    record.lookupContextDictId = lookupContextDictId
                    record.lookupContextGroupId = lookupContextGroupId
                    record.firstLookedUpAt = now
                    record.lastLookedUpAt = now
                    record.lookupCount = 1
                }
                try ctx.save()
            }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: LookupHistoryService.didChangeNotification, object: nil
                )
            }
        }
    }

    // MARK: - Read (Grouped by Date)

    /// Fetch history records for a specific lookup context, grouped by date category.
    ///
    /// Context tuple: exactly one of `lookupContextDictId` / `lookupContextGroupId` should be non-nil.
    ///
    /// Runs on viewContext (main queue) — safe because this class is MainActor-isolated.
    func groupedHistory(lookupContextDictId: String?,
                        lookupContextGroupId: String?) -> [HistorySection] {
        let ctx = stack.viewContext
        let request = NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "lastLookedUpAt", ascending: false)]

        if let ctxDictId = lookupContextDictId {
            request.predicate = NSPredicate(format: "lookupContextDictId == %@", ctxDictId)
        } else if let ctxGroupId = lookupContextGroupId {
            request.predicate = NSPredicate(format: "lookupContextGroupId == %@", ctxGroupId)
        }
        // If both nil, no predicate → returns all records (shouldn't happen in normal use)

        do {
            let records = try ctx.fetch(request)
            return groupRecordsByDate(records)
        } catch {
            print("❌ LookupHistory groupedHistory fetch failed: \(error)")
            return []
        }
    }

    /// Total lookup count for a (word, dictId) pair across all contexts.
    func totalLookupCount(word: String, dictId: String) -> Int {
        let ctx = stack.viewContext
        let request = NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "word == %@", word),
            NSPredicate(format: "dictId == %@", dictId),
        ])

        do {
            let records = try ctx.fetch(request)
            return records.reduce(0) { $0 + Int($1.lookupCount) }
        } catch {
            print("❌ LookupHistory totalLookupCount failed: \(error)")
            return 0
        }
    }

    /// Batch-fetch lookup metadata for a list of (word, dictId) pairs.
    /// Returns a dictionary keyed by "word\0dictId" with aggregated lookup info.
    /// Efficient: single Core Data fetch with an OR predicate.
    func lookupMetadata(for pairs: [(word: String, dictId: String)]) -> [String: (lastDate: Date?, count: Int)] {
        guard !pairs.isEmpty else { return [:] }
        let ctx = stack.viewContext
        let request = NSFetchRequest<LookupRecord>(entityName: "LookupRecord")

        let subpredicates = pairs.map { pair in
            NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "word == %@", pair.word),
                NSPredicate(format: "dictId == %@", pair.dictId),
            ])
        }
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates)

        do {
            let records = try ctx.fetch(request)
            var result: [String: (lastDate: Date?, count: Int)] = [:]
            for record in records {
                let key = "\(record.word ?? "")\0\(record.dictId ?? "")"
                let existing = result[key]
                let newDate: Date? = {
                    guard let recDate = record.lastLookedUpAt else { return existing?.lastDate }
                    guard let exDate = existing?.lastDate else { return recDate }
                    return max(recDate, exDate)
                }()
                result[key] = (lastDate: newDate, count: (existing?.count ?? 0) + Int(record.lookupCount))
            }
            return result
        } catch {
            print("❌ LookupHistory lookupMetadata failed: \(error)")
            return [:]
        }
    }

    // MARK: - Read (All Contexts)

    /// Fetch ALL history records across all contexts, grouped by date.
    /// Deduplicates by (word, dictId) — keeps the most recent record per pair.
    func allGroupedHistory() -> [HistorySection] {
        let ctx = stack.viewContext
        let request = NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "lastLookedUpAt", ascending: false)]

        do {
            let records = try ctx.fetch(request)
            // Deduplicate: keep only the most recent record per (word, dictId)
            var seen = Set<String>()
            let deduplicated = records.filter { record in
                let key = "\(record.word ?? "")\0\(record.dictId ?? "")"
                return seen.insert(key).inserted
            }
            return groupRecordsByDate(deduplicated)
        } catch {
            print("❌ LookupHistory allGroupedHistory fetch failed: \(error)")
            return []
        }
    }

    // MARK: - Delete

    /// Delete a single record by its managed object ID.
    func deleteRecord(objectID: NSManagedObjectID) {
        let ctx = stack.viewContext
        let object = ctx.object(with: objectID)
        ctx.delete(object)
        do {
            try ctx.save()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        } catch {
            print("❌ LookupHistory deleteRecord failed: \(error)")
        }
    }

    /// Delete history records for a specific lookup context.
    ///
    /// Context tuple: exactly one of `lookupContextDictId` / `lookupContextGroupId` should be non-nil.
    func clearHistory(lookupContextDictId: String?, lookupContextGroupId: String?) {
        // Create background context and capture viewContext on MainActor before escaping
        let ctx = self.stack.newBackgroundContext()
        let viewContext = self.stack.viewContext
        Task.detached {

            try? await ctx.perform(schedule: .immediate as NSManagedObjectContext.ScheduledTaskType) {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: "LookupRecord")
                if let ctxDictId = lookupContextDictId {
                    request.predicate = NSPredicate(format: "lookupContextDictId == %@", ctxDictId)
                } else if let ctxGroupId = lookupContextGroupId {
                    request.predicate = NSPredicate(format: "lookupContextGroupId == %@", ctxGroupId)
                }
                let batchDelete = NSBatchDeleteRequest(fetchRequest: request)
                batchDelete.resultType = .resultTypeObjectIDs

                let result = try ctx.execute(batchDelete) as? NSBatchDeleteResult
                if let objectIDs = result?.result as? [NSManagedObjectID] {
                    // mergeChanges dispatches to each context's queue internally
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                        into: [viewContext]
                    )
                }
            }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: LookupHistoryService.didChangeNotification, object: nil
                )
            }
        }
    }

    /// Delete ALL lookup history records across all contexts.
    func clearAllHistory() {
        let ctx = self.stack.newBackgroundContext()
        let viewContext = self.stack.viewContext
        Task.detached {
            try? await ctx.perform(schedule: .immediate as NSManagedObjectContext.ScheduledTaskType) {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: "LookupRecord")
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
                    name: LookupHistoryService.didChangeNotification, object: nil
                )
            }
        }
    }

    // MARK: - Date Grouping

    /// Convert LookupRecords to HistoryItems and group by date using the shared helper.
    private func groupRecordsByDate(_ records: [LookupRecord]) -> [HistorySection] {
        let items = records.compactMap { record -> HistoryItem? in
            guard record.lastLookedUpAt != nil else { return nil }
            return HistoryItem(
                objectID: record.objectID,
                word: record.word ?? "",
                dictId: record.dictId ?? "",
                dictName: record.dictName ?? "",
                lastLookedUpAt: record.lastLookedUpAt
            )
        }
        let dateSections = groupItemsByDate(items)
        return dateSections.map { HistorySection(title: $0.title, records: $0.items) }
    }
}
