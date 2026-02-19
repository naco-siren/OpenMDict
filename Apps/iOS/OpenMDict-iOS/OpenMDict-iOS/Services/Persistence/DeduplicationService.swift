//
//  DeduplicationService.swift
//  OpenMDict-iOS
//
//  Detects and merges duplicate CoreData records after CloudKit sync.
//
//  CloudKit (NSPersistentCloudKitContainer) does not support unique
//  constraints.  When two devices create records with the same logical
//  key while offline, sync will produce duplicates.  This service runs
//  after each remote-change notification — before downstream caches
//  are refreshed — to collapse duplicates into a single winner.
//
//  Per-entity merge rules:
//  ┌───────────────────────────┬─────────────────────────────────────────────────────────┬──────────────────────────────────┐
//  │ Entity                    │ Logical unique key                                      │ Winner selection                 │
//  ├───────────────────────────┼─────────────────────────────────────────────────────────┼──────────────────────────────────┤
//  │ BookmarkRecord            │ (word, dictId)                                          │ Earliest createdAt               │
//  │ LookupRecord              │ (word, dictId, lookupContextDictId, lookupContextGroupId)│ Merge counts + dates             │
//  │ LookupCountRecord         │ contextKey                                              │ max(count)                       │
//  │ DictionaryMetadataRecord  │ dictId                                                  │ Earliest importedAt              │
//  │ DictionaryGroupRecord     │ groupId                                                 │ Latest modifiedAt                │
//  │ GroupEntryRecord           │ (groupId, dictId)                                       │ Keep any one                     │
//  └───────────────────────────┴─────────────────────────────────────────────────────────┴──────────────────────────────────┘
//
//  Performance notes:
//  - Runs on a background context → does not block UI.
//  - Only triggered by remote changes, not local writes.
//  - Typical record counts are small (<5 000) → linear scan is fine.
//  - Results merge into viewContext automatically
//    (automaticallyMergesChangesFromParent).
//

import CoreData
import Foundation

final class DeduplicationService {

    static let shared = DeduplicationService()

    private var stack: CoreDataStack { CoreDataStack.shared }

    private init() {}

    // MARK: - Public Entry Point

    /// Deduplicate all entities.  Call from a background context before
    /// forwarding the remote-change event to downstream caches.
    nonisolated func deduplicateAll() async {
        let ctx = await MainActor.run { stack.newBackgroundContext() }
        await ctx.perform {
            var totalDeleted = 0
            totalDeleted += self.deduplicateBookmarks(in: ctx)
            totalDeleted += self.deduplicateLookupRecords(in: ctx)
            totalDeleted += self.deduplicateLookupCounts(in: ctx)
            totalDeleted += self.deduplicateDictionaryMetadata(in: ctx)
            totalDeleted += self.deduplicateGroups(in: ctx)
            totalDeleted += self.deduplicateGroupEntries(in: ctx)

            guard ctx.hasChanges else {
                if totalDeleted > 0 {
                    debugLog("☁️ Dedup: cleaned \(totalDeleted) duplicates (already saved)")
                }
                return
            }
            do {
                try ctx.save()
                debugLog("☁️ Dedup: removed \(totalDeleted) duplicate records")
            } catch {
                debugLog("❌ Dedup: save failed: \(error)")
            }
        }
    }

    // MARK: - BookmarkRecord  (word, dictId) → earliest createdAt

    private nonisolated func deduplicateBookmarks(in ctx: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "BookmarkRecord")
        request.sortDescriptors = [
            NSSortDescriptor(key: "word", ascending: true),
            NSSortDescriptor(key: "dictId", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true),  // earliest first
        ]

        guard let records = try? ctx.fetch(request), records.count > 1 else { return 0 }

        var deleted = 0
        var prevWord: String?
        var prevDictId: String?

        for record in records {
            let word = record.value(forKey: "word") as? String ?? ""
            let dictId = record.value(forKey: "dictId") as? String ?? ""

            if word == prevWord && dictId == prevDictId {
                // Duplicate — delete this one (we keep the first = earliest createdAt)
                ctx.delete(record)
                deleted += 1
            } else {
                prevWord = word
                prevDictId = dictId
            }
        }
        return deleted
    }

    // MARK: - LookupRecord  (word, dictId, contextDictId, contextGroupId) → merge

    private nonisolated func deduplicateLookupRecords(in ctx: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LookupRecord")
        request.sortDescriptors = [
            NSSortDescriptor(key: "word", ascending: true),
            NSSortDescriptor(key: "dictId", ascending: true),
            NSSortDescriptor(key: "lookupContextDictId", ascending: true),
            NSSortDescriptor(key: "lookupContextGroupId", ascending: true),
        ]

        guard let records = try? ctx.fetch(request), records.count > 1 else { return 0 }

        typealias LookupKey = (word: String, dictId: String, ctxDict: String, ctxGroup: String)

        var deleted = 0
        var currentWinner: NSManagedObject?
        var currentKey: LookupKey?

        for record in records {
            let key: LookupKey = (
                record.value(forKey: "word") as? String ?? "",
                record.value(forKey: "dictId") as? String ?? "",
                record.value(forKey: "lookupContextDictId") as? String ?? "",
                record.value(forKey: "lookupContextGroupId") as? String ?? ""
            )

            if let prevKey = currentKey,
               key.word == prevKey.word &&
               key.dictId == prevKey.dictId &&
               key.ctxDict == prevKey.ctxDict &&
               key.ctxGroup == prevKey.ctxGroup,
               let winner = currentWinner {
                // Duplicate — merge into winner, then delete
                let winnerCount = winner.value(forKey: "lookupCount") as? Int32 ?? 0
                let dupCount = record.value(forKey: "lookupCount") as? Int32 ?? 0
                winner.setValue(winnerCount + dupCount, forKey: "lookupCount")

                // firstLookedUpAt = min
                let winnerFirst = winner.value(forKey: "firstLookedUpAt") as? Date ?? Date.distantFuture
                let dupFirst = record.value(forKey: "firstLookedUpAt") as? Date ?? Date.distantFuture
                winner.setValue(min(winnerFirst, dupFirst), forKey: "firstLookedUpAt")

                // lastLookedUpAt = max
                let winnerLast = winner.value(forKey: "lastLookedUpAt") as? Date ?? Date.distantPast
                let dupLast = record.value(forKey: "lastLookedUpAt") as? Date ?? Date.distantPast
                winner.setValue(max(winnerLast, dupLast), forKey: "lastLookedUpAt")

                ctx.delete(record)
                deleted += 1
            } else {
                currentWinner = record
                currentKey = key
            }
        }
        return deleted
    }

    // MARK: - LookupCountRecord  (contextKey) → max(count)

    private nonisolated func deduplicateLookupCounts(in ctx: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LookupCountRecord")
        request.sortDescriptors = [
            NSSortDescriptor(key: "contextKey", ascending: true),
        ]

        guard let records = try? ctx.fetch(request), records.count > 1 else { return 0 }

        var deleted = 0
        var currentWinner: NSManagedObject?
        var prevContextKey: String?

        for record in records {
            let contextKey = record.value(forKey: "contextKey") as? String ?? ""

            if contextKey == prevContextKey, let winner = currentWinner {
                // Duplicate — keep max count in winner
                let winnerCount = winner.value(forKey: "count") as? Int64 ?? 0
                let dupCount = record.value(forKey: "count") as? Int64 ?? 0
                winner.setValue(max(winnerCount, dupCount), forKey: "count")

                // updatedAt = max
                let winnerDate = winner.value(forKey: "updatedAt") as? Date ?? Date.distantPast
                let dupDate = record.value(forKey: "updatedAt") as? Date ?? Date.distantPast
                winner.setValue(max(winnerDate, dupDate), forKey: "updatedAt")

                ctx.delete(record)
                deleted += 1
            } else {
                currentWinner = record
                prevContextKey = contextKey
            }
        }
        return deleted
    }

    // MARK: - DictionaryMetadataRecord  (dictId) → earliest importedAt

    private nonisolated func deduplicateDictionaryMetadata(in ctx: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DictionaryMetadataRecord")
        request.sortDescriptors = [
            NSSortDescriptor(key: "dictId", ascending: true),
            NSSortDescriptor(key: "importedAt", ascending: true),  // earliest first
        ]

        guard let records = try? ctx.fetch(request), records.count > 1 else { return 0 }

        var deleted = 0
        var prevDictId: String?

        for record in records {
            let dictId = record.value(forKey: "dictId") as? String ?? ""

            if dictId == prevDictId {
                // Duplicate — delete this one (we keep the first = earliest importedAt)
                ctx.delete(record)
                deleted += 1
            } else {
                prevDictId = dictId
            }
        }
        return deleted
    }

    // MARK: - DictionaryGroupRecord  (groupId) → latest modifiedAt

    private nonisolated func deduplicateGroups(in ctx: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DictionaryGroupRecord")
        request.sortDescriptors = [
            NSSortDescriptor(key: "groupId", ascending: true),
            NSSortDescriptor(key: "modifiedAt", ascending: false),  // latest first
        ]

        guard let records = try? ctx.fetch(request), records.count > 1 else { return 0 }

        var deleted = 0
        var prevGroupId: String?

        for record in records {
            let groupId = record.value(forKey: "groupId") as? String ?? ""

            if groupId == prevGroupId {
                // Duplicate — delete this one (we keep the first = latest modifiedAt)
                ctx.delete(record)
                deleted += 1
            } else {
                prevGroupId = groupId
            }
        }
        return deleted
    }

    // MARK: - GroupEntryRecord  (groupId, dictId) → keep any one

    private nonisolated func deduplicateGroupEntries(in ctx: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "GroupEntryRecord")
        request.sortDescriptors = [
            NSSortDescriptor(key: "groupId", ascending: true),
            NSSortDescriptor(key: "dictId", ascending: true),
            NSSortDescriptor(key: "sortOrder", ascending: true),
        ]

        guard let records = try? ctx.fetch(request), records.count > 1 else { return 0 }

        var deleted = 0
        var prevGroupId: String?
        var prevDictId: String?

        for record in records {
            let groupId = record.value(forKey: "groupId") as? String ?? ""
            let dictId = record.value(forKey: "dictId") as? String ?? ""

            if groupId == prevGroupId && dictId == prevDictId {
                ctx.delete(record)
                deleted += 1
            } else {
                prevGroupId = groupId
                prevDictId = dictId
            }
        }
        return deleted
    }
}
