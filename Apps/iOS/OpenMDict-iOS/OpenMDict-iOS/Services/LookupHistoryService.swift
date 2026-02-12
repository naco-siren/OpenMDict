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
//  - UI layer receives HistoryRecord (Sendable value type) instead.
//  - Background writes use Task.detached + await ctx.perform { }.
//

import CoreData
import Foundation

final class LookupHistoryService {

    static let shared = LookupHistoryService()

    /// Posted after any mutation (insert / update / delete / clear).
    nonisolated static let didChangeNotification = Notification.Name("LookupHistoryDidChange")

    private var stack: CoreDataStack { CoreDataStack.shared }

    // MARK: - Value Types (public API surface)

    /// Sendable value type representing a lookup history record.
    /// Decouples the UI layer from NSManagedObject.
    struct HistoryRecord: Sendable {
        let objectID: NSManagedObjectID
        let word: String
        let dictId: String
        let dictName: String
        let lastLookedUpAt: Date?
    }

    /// A single date section with its title and records (most recent first within each group).
    struct HistorySection {
        let title: String
        let records: [HistoryRecord]
    }

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

    // MARK: - Date Grouping

    /// Group records into date-based sections, converting LookupRecord → HistoryRecord.
    ///
    /// Categories (in order):
    /// - Today
    /// - Yesterday
    /// - 2 Days Ago … 6 Days Ago
    /// - 1 Week Ago, 2 Weeks Ago
    /// - Earlier This Month
    /// - Last Month
    /// - <Month YYYY> (e.g. "September 2025")
    /// - Last Year
    /// - <YYYY> (e.g. "2023")
    private func groupRecordsByDate(_ records: [LookupRecord]) -> [HistorySection] {
        guard !records.isEmpty else { return [] }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        // Pre-compute boundary dates
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth)!
        let startOfThisYear = calendar.date(from: calendar.dateComponents([.year], from: now))!
        let startOfLastYear = calendar.date(byAdding: .year, value: -1, to: startOfThisYear)!

        // Month-year formatter for older months
        let monthYearFormatter = DateFormatter()
        monthYearFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        // Ordered dict preserving insertion order
        var sections: [(key: String, records: [HistoryRecord])] = []
        var sectionMap: [String: Int] = [:]

        func appendToSection(key: String, record: HistoryRecord) {
            if let idx = sectionMap[key] {
                sections[idx].records.append(record)
            } else {
                sectionMap[key] = sections.count
                sections.append((key: key, records: [record]))
            }
        }

        for managedRecord in records {
            guard let date = managedRecord.lastLookedUpAt else { continue }

            // Convert NSManagedObject → Sendable value type
            let record = HistoryRecord(
                objectID: managedRecord.objectID,
                word: managedRecord.word ?? "",
                dictId: managedRecord.dictId ?? "",
                dictName: managedRecord.dictName ?? "",
                lastLookedUpAt: date
            )

            let key: String
            if date >= startOfToday {
                key = L10n.HistorySection.today
            } else if date >= startOfYesterday {
                key = L10n.HistorySection.yesterday
            } else {
                let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
                if daysAgo <= 6 {
                    // 2–6 days ago
                    key = L10n.HistorySection.daysAgo(daysAgo)
                } else {
                    let weeksAgo = calendar.dateComponents([.weekOfYear], from: calendar.startOfDay(for: date), to: startOfToday).weekOfYear ?? 0
                    if weeksAgo <= 2 && date >= startOfThisMonth {
                        key = L10n.HistorySection.weeksAgo(weeksAgo)
                    } else if date >= startOfThisMonth {
                        key = L10n.HistorySection.earlierThisMonth
                    } else if date >= startOfLastMonth {
                        key = L10n.HistorySection.lastMonth
                    } else if date >= startOfThisYear {
                        // Earlier months this year
                        key = monthYearFormatter.string(from: date)
                    } else if date >= startOfLastYear {
                        key = L10n.HistorySection.lastYear
                    } else {
                        // Older years
                        let year = calendar.component(.year, from: date)
                        key = "\(year)"
                    }
                }
            }

            appendToSection(key: key, record: record)
        }

        return sections.map { HistorySection(title: $0.key, records: $0.records) }
    }
}
