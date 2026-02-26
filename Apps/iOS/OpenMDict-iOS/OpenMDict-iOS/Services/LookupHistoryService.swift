//
//  LookupHistoryService.swift
//  OpenMDict-iOS
//
//  In-memory cached repository for lookup history records.
//
//  Architecture (DataRepository pattern):
//  - An in-memory cache (`cache`) is the SINGLE SOURCE OF TRUTH for all reads.
//  - Writes update the cache synchronously on MainActor, then schedule a
//    deferred batch persist to CoreData.
//  - Increments `@Published revision` after every mutation so the UI can react.
//
//  Flush strategy (three tiers):
//  1. Dirty-count threshold (≥10): immediate flush on high-frequency lookups.
//  2. Debounce timer (2 seconds): coalesces low-frequency writes.
//  3. Lifecycle callbacks (background / memory warning / terminate): safety net.
//
//  Thread-safety:
//  - The service is MainActor-isolated (via `-default-isolation=MainActor`).
//  - Background CoreData writes use Task.detached + ctx.perform { }.
//  - LookupRecord and value types are `nonisolated` for CoreData queue confinement
//    and DiffableDataSource Hashable conformance.
//

import Combine
import CoreData
import Foundation
import UIKit

/// Convenience alias for the (word, dictId) pair used throughout lookup history.
typealias WordDictPair = (word: String, dictId: String)

// MARK: - Value Types (file-scope, nonisolated)

/// Compound key matching the CoreData compound index on
/// (word, dictId, lookupContextDictId, lookupContextGroupId).
nonisolated struct LookupRecordKey: Hashable, Sendable {
    let word: String
    let dictId: String
    let contextDictId: String   // "" if original is nil
    let contextGroupId: String  // "" if original is nil
}

/// In-memory representation of a single LookupRecord.
/// Replaces NSManagedObject for all read paths.
nonisolated struct CachedLookupRecord: Sendable {
    /// Stable identity for delete operations. Nil if not yet persisted to CoreData.
    var objectID: NSManagedObjectID?
    let word: String
    let dictId: String
    var firstLookedUpAt: Date
    var lastLookedUpAt: Date
    var lookupCount: Int32
    let lookupContextDictId: String?
    let lookupContextGroupId: String?
}

/// Sendable value type representing a lookup history record.
/// At file scope so that Hashable conformance is nonisolated
/// (required by DiffableDataSource under `-default-isolation=MainActor`).
nonisolated struct HistoryItem: Sendable, Hashable, DateGroupable {
    let objectID: NSManagedObjectID?
    let word: String
    let dictId: String
    let dictName: String
    /// Whether the referenced dictionary exists on this device.
    /// `false` for records synced from another device whose dictionary hasn't been synced yet.
    let isDictAvailable: Bool
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

    private var stack: CoreDataStack { CoreDataStack.shared }

    // MARK: - Combine Publishers

    /// Revision counter — incremented after every cache mutation.
    /// List-style consumers use `$revision.dropFirst().sink { ... }` to react.
    @Published private(set) var revision: UInt = 0

    /// Per-(word, dictId) lookup count publisher.
    /// Emits the aggregated count across all contexts whenever it changes.
    /// Ideal for ArticleVC which tracks a single word's count.
    func lookupCountPublisher(word: String, dictId: String) -> AnyPublisher<Int, Never> {
        $revision
            .map { [weak self] _ in
                self?.totalLookupCount(word: word, dictId: dictId) ?? 0
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - In-Memory Cache

    /// The single source of truth for all reads after population.
    private var cache: [LookupRecordKey: CachedLookupRecord] = [:]

    /// Whether the cache has been populated from CoreData.
    private var isCachePopulated = false

    /// Keys of cache entries that need CoreData upsert.
    private var dirtyKeys: Set<LookupRecordKey> = []

    /// Coalescing timer for deferred persistence.
    private var deferredPersistWorkItem: DispatchWorkItem?

    /// Dirty count threshold: flush immediately when reached.
    private let flushThreshold = 10

    /// Cancellable for CloudKit remote change subscription.
    private var remoteChangeCancellable: AnyCancellable?

    // MARK: - Init

    private init() {
        // Scene entering background — flush to avoid data loss
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFlushTrigger),
            name: UIScene.didEnterBackgroundNotification, object: nil
        )
        // System memory warning — flush (but keep cache)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFlushTrigger),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
        // App will terminate — last chance to persist
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFlushTrigger),
            name: UIApplication.willTerminateNotification, object: nil
        )

        // CloudKit remote change — reload cache from CoreData
        remoteChangeCancellable = CoreDataStack.shared.remoteChangePublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.reloadCacheFromCoreData()
            }
    }

    @objc private func handleFlushTrigger() {
        flushDirtyEntriesToCoreData()
    }

    // MARK: - Cache Population (lazy, on first read)

    private func ensureCachePopulated() {
        guard !isCachePopulated else { return }
        populateCacheFromCoreData()
        isCachePopulated = true
    }

    /// Reload the entire cache from CoreData.
    /// Called on CloudKit remote change to pick up records synced from other devices.
    ///
    /// IMPORTANT: do NOT call flushDirtyEntriesToCoreData() here.
    /// Background ctx.save() fires NSPersistentStoreRemoteChange (even for
    /// local saves when persistent history tracking is enabled), which would
    /// re-trigger this handler and create an infinite feedback loop.
    ///
    /// Instead, dirty entries are saved aside before the reload, then
    /// re-applied on top.  They stay in `dirtyKeys` and will be flushed
    /// by the normal three-tier schedule (threshold / debounce / lifecycle).
    private func reloadCacheFromCoreData() {
        guard isCachePopulated else { return }  // not yet populated → skip

        // Preserve dirty entries — they have the latest data and must not
        // be overwritten by the (potentially stale) CoreData values.
        let pendingDirty: [LookupRecordKey: CachedLookupRecord] = dirtyKeys.reduce(into: [:]) { result, key in
            if let entry = cache[key] { result[key] = entry }
        }

        cache.removeAll()
        populateCacheFromCoreData()

        // Re-apply dirty entries on top of the reloaded data
        for (key, entry) in pendingDirty {
            cache[key] = entry
        }

        revision += 1
        debugLog("☁️ LookupHistoryService: cache reloaded from CoreData (preserved \(pendingDirty.count) dirty entries)")
    }

    /// Fetch all LookupRecords from CoreData into the in-memory cache.
    private func populateCacheFromCoreData() {
        let ctx = stack.viewContext
        let request = NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
        do {
            let records = try ctx.fetch(request)
            for record in records {
                let key = LookupRecordKey(
                    word: record.word ?? "",
                    dictId: record.dictId ?? "",
                    contextDictId: record.lookupContextDictId ?? "",
                    contextGroupId: record.lookupContextGroupId ?? ""
                )
                cache[key] = CachedLookupRecord(
                    objectID: record.objectID,
                    word: record.word ?? "",
                    dictId: record.dictId ?? "",
                    firstLookedUpAt: record.firstLookedUpAt ?? Date(),
                    lastLookedUpAt: record.lastLookedUpAt ?? Date(),
                    lookupCount: record.lookupCount,
                    lookupContextDictId: record.lookupContextDictId,
                    lookupContextGroupId: record.lookupContextGroupId
                )
            }
        } catch {
            debugLog("❌ LookupHistory cache population failed: \(error)")
        }
    }

    // MARK: - Record Lookup (Upsert — synchronous cache + deferred persist)

    /// Record a lookup. If a record with the same (word, dictId, context) exists,
    /// update `lastLookedUpAt` and increment `lookupCount`.
    /// Otherwise create a new record.
    ///
    /// Context tuple: exactly one of `lookupContextDictId` / `lookupContextGroupId` should be non-nil.
    ///
    /// Also increments the per-context trophy counter via LookupCountService (monotonically
    /// increasing, independent of history deletion).
    func recordLookup(word: String, dictId: String,
                      lookupContextDictId: String?, lookupContextGroupId: String?) {
        // Increment the CoreData-based trophy counter (deferred save).
        // When searching within a group, bump both the group AND the
        // specific dictionary that produced this result.
        LookupCountService.shared.incrementLookupCount(
            contextDictId: lookupContextDictId, contextGroupId: lookupContextGroupId
        )
        if lookupContextGroupId != nil {
            LookupCountService.shared.incrementLookupCount(
                contextDictId: dictId, contextGroupId: nil
            )
        }

        // Ensure cache is ready
        ensureCachePopulated()

        // Synchronous cache upsert
        let key = LookupRecordKey(
            word: word,
            dictId: dictId,
            contextDictId: lookupContextDictId ?? "",
            contextGroupId: lookupContextGroupId ?? ""
        )
        let now = Date()
        if var existing = cache[key] {
            existing.lastLookedUpAt = now
            existing.lookupCount += 1
            cache[key] = existing
        } else {
            cache[key] = CachedLookupRecord(
                objectID: nil,
                word: word,
                dictId: dictId,
                firstLookedUpAt: now,
                lastLookedUpAt: now,
                lookupCount: 1,
                lookupContextDictId: lookupContextDictId,
                lookupContextGroupId: lookupContextGroupId
            )
        }

        // Mark dirty and schedule persistence
        dirtyKeys.insert(key)
        scheduleDeferredPersist()

        // Notify UI immediately (cache is already updated)
        revision += 1
    }

    // MARK: - Read (Grouped by Date) — pure cache

    /// Fetch history records for a specific lookup context, grouped by date category.
    ///
    /// Context tuple: exactly one of `lookupContextDictId` / `lookupContextGroupId` should be non-nil.
    func groupedHistory(lookupContextDictId: String?,
                        lookupContextGroupId: String?) -> [HistorySection] {
        ensureCachePopulated()

        let filtered: [CachedLookupRecord]
        if let ctxDictId = lookupContextDictId {
            filtered = cache.values.filter { ($0.lookupContextDictId ?? "") == ctxDictId }
        } else if let ctxGroupId = lookupContextGroupId {
            filtered = cache.values.filter { ($0.lookupContextGroupId ?? "") == ctxGroupId }
        } else {
            // Both nil → return all (shouldn't happen in normal use)
            filtered = Array(cache.values)
        }

        let sorted = filtered.sorted { $0.lastLookedUpAt > $1.lastLookedUpAt }
        return groupCachedRecordsByDate(sorted)
    }

    /// Total lookup count for a (word, dictId) pair across all contexts.
    func totalLookupCount(word: String, dictId: String) -> Int {
        ensureCachePopulated()
        return cache.values
            .filter { $0.word == word && $0.dictId == dictId }
            .reduce(0) { $0 + Int($1.lookupCount) }
    }

    /// Batch-fetch lookup metadata for a list of (word, dictId) pairs.
    /// Returns a dictionary keyed by "word\0dictId" with aggregated lookup info.
    func lookupMetadata(for pairs: [WordDictPair]) -> [String: (lastDate: Date?, count: Int)] {
        guard !pairs.isEmpty else { return [:] }
        ensureCachePopulated()

        // Build a set for O(1) membership check
        let pairSet = Set(pairs.map { "\($0.word)\0\($0.dictId)" })

        var result: [String: (lastDate: Date?, count: Int)] = [:]
        for record in cache.values {
            let pairKey = "\(record.word)\0\(record.dictId)"
            guard pairSet.contains(pairKey) else { continue }

            let existing = result[pairKey]
            let newDate: Date? = {
                let recDate = record.lastLookedUpAt
                guard let exDate = existing?.lastDate else { return recDate }
                return max(recDate, exDate)
            }()
            result[pairKey] = (lastDate: newDate, count: (existing?.count ?? 0) + Int(record.lookupCount))
        }
        return result
    }

    // MARK: - Read (All Contexts) — pure cache

    /// Fetch ALL history records across all contexts, grouped by date.
    /// Deduplicates by (word, dictId) — keeps the most recent record per pair.
    func allGroupedHistory() -> [HistorySection] {
        ensureCachePopulated()

        // Sort by lastLookedUpAt descending, then deduplicate
        let sorted = cache.values.sorted { $0.lastLookedUpAt > $1.lastLookedUpAt }
        var seen = Set<String>()
        let deduplicated = sorted.filter { record in
            let key = "\(record.word)\0\(record.dictId)"
            return seen.insert(key).inserted
        }
        return groupCachedRecordsByDate(deduplicated)
    }

    // MARK: - Delete (immediate cache + immediate CoreData)

    /// Delete a single record by its managed object ID.
    func deleteRecord(objectID: NSManagedObjectID) {
        ensureCachePopulated()

        // Find and remove from cache
        if let key = cache.first(where: { $0.value.objectID == objectID })?.key {
            cache.removeValue(forKey: key)
            dirtyKeys.remove(key)
        }

        // Immediate CoreData delete
        let ctx = stack.viewContext
        let object = ctx.object(with: objectID)
        ctx.delete(object)
        do {
            try ctx.save()
        } catch {
            debugLog("❌ LookupHistory deleteRecord failed: \(error)")
        }

        revision += 1
    }

    /// Delete history records for a specific lookup context.
    ///
    /// Context tuple: exactly one of `lookupContextDictId` / `lookupContextGroupId` should be non-nil.
    func clearHistory(lookupContextDictId: String?, lookupContextGroupId: String?) {
        ensureCachePopulated()

        // Remove matching entries from cache
        let keysToRemove = cache.keys.filter { key in
            if let ctxDictId = lookupContextDictId {
                return key.contextDictId == ctxDictId
            } else if let ctxGroupId = lookupContextGroupId {
                return key.contextGroupId == ctxGroupId
            }
            return false
        }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            dirtyKeys.remove(key)
        }

        // Immediate CoreData batch delete
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
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                        into: [viewContext]
                    )
                }
            }
        }

        // Notify immediately (cache is already updated)
        revision += 1
    }

    /// Delete ALL lookup history records across all contexts.
    func clearAllHistory() {
        ensureCachePopulated()

        // Clear cache entirely
        cache.removeAll()
        dirtyKeys.removeAll()
        deferredPersistWorkItem?.cancel()
        deferredPersistWorkItem = nil

        // Immediate CoreData batch delete
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
        }

        // Notify immediately (cache is already updated)
        revision += 1
    }

    // MARK: - Deferred Persistence

    /// Schedule a deferred CoreData persist.
    /// Three-tier strategy:
    /// 1. Dirty count ≥ threshold → immediate flush
    /// 2. 2-second debounce timer → coalesced flush
    /// 3. Lifecycle callbacks → safety-net flush (handled by handleFlushTrigger)
    private func scheduleDeferredPersist() {
        // Tier 1: threshold reached → immediate flush
        if dirtyKeys.count >= flushThreshold {
            flushDirtyEntriesToCoreData()
            return
        }

        // Tier 2: debounce timer
        deferredPersistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushDirtyEntriesToCoreData()
        }
        deferredPersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    /// Force-flush all pending writes to CoreData immediately.
    func flushDirtyEntriesToCoreData() {
        deferredPersistWorkItem?.cancel()
        deferredPersistWorkItem = nil

        guard !dirtyKeys.isEmpty else { return }
        let keysToFlush = dirtyKeys
        dirtyKeys.removeAll()

        let entriesToPersist = keysToFlush.compactMap { cache[$0] }
        guard !entriesToPersist.isEmpty else { return }

        let ctx = stack.newBackgroundContext()
        Task.detached { [entriesToPersist] in
            try? await ctx.perform(schedule: .immediate as NSManagedObjectContext.ScheduledTaskType) {
                for entry in entriesToPersist {
                    let request = NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
                    var subpredicates: [NSPredicate] = [
                        NSPredicate(format: "word == %@", entry.word),
                        NSPredicate(format: "dictId == %@", entry.dictId),
                    ]
                    if let ctxDictId = entry.lookupContextDictId, !ctxDictId.isEmpty {
                        subpredicates.append(NSPredicate(format: "lookupContextDictId == %@", ctxDictId))
                    } else {
                        subpredicates.append(NSPredicate(format: "lookupContextDictId == nil OR lookupContextDictId == %@", ""))
                    }
                    if let ctxGroupId = entry.lookupContextGroupId, !ctxGroupId.isEmpty {
                        subpredicates.append(NSPredicate(format: "lookupContextGroupId == %@", ctxGroupId))
                    } else {
                        subpredicates.append(NSPredicate(format: "lookupContextGroupId == nil OR lookupContextGroupId == %@", ""))
                    }
                    request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
                    request.fetchLimit = 1

                    if let existing = try ctx.fetch(request).first {
                        existing.lastLookedUpAt = entry.lastLookedUpAt
                        existing.lookupCount = entry.lookupCount
                    } else {
                        let record = LookupRecord(context: ctx)
                        record.word = entry.word
                        record.dictId = entry.dictId
                        record.lookupContextDictId = entry.lookupContextDictId
                        record.lookupContextGroupId = entry.lookupContextGroupId
                        record.firstLookedUpAt = entry.firstLookedUpAt
                        record.lastLookedUpAt = entry.lastLookedUpAt
                        record.lookupCount = entry.lookupCount
                    }
                }
                try ctx.save()
            }

            // After save, backfill objectIDs for newly created entries
            await MainActor.run { [weak self] in
                self?.backfillObjectIDs(for: keysToFlush)
            }
        }
    }

    /// After a background persist, newly inserted records now have permanent objectIDs
    /// in the viewContext (via automaticallyMergesChangesFromParent). Capture them so
    /// that deleteRecord(objectID:) can find them later.
    private func backfillObjectIDs(for keys: Set<LookupRecordKey>) {
        let ctx = stack.viewContext
        for key in keys {
            guard cache[key]?.objectID == nil else { continue }
            let request = NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
            var subpredicates: [NSPredicate] = [
                NSPredicate(format: "word == %@", key.word),
                NSPredicate(format: "dictId == %@", key.dictId),
            ]
            if !key.contextDictId.isEmpty {
                subpredicates.append(NSPredicate(format: "lookupContextDictId == %@", key.contextDictId))
            } else {
                subpredicates.append(NSPredicate(format: "lookupContextDictId == nil OR lookupContextDictId == %@", ""))
            }
            if !key.contextGroupId.isEmpty {
                subpredicates.append(NSPredicate(format: "lookupContextGroupId == %@", key.contextGroupId))
            } else {
                subpredicates.append(NSPredicate(format: "lookupContextGroupId == nil OR lookupContextGroupId == %@", ""))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
            request.fetchLimit = 1
            if let record = try? ctx.fetch(request).first {
                cache[key]?.objectID = record.objectID
            }
        }
    }

    // MARK: - Date Grouping

    /// Convert CachedLookupRecords to HistoryItems and group by date using the shared helper.
    /// Note: `dictName` and `isDictAvailable` are populated with defaults here.
    /// The UI layer resolves the actual display name from `DictMetadataService`.
    private func groupCachedRecordsByDate(_ records: [CachedLookupRecord]) -> [HistorySection] {
        let items = records.map { record in
            HistoryItem(
                objectID: record.objectID,
                word: record.word,
                dictId: record.dictId,
                dictName: "",
                isDictAvailable: true,
                lastLookedUpAt: record.lastLookedUpAt
            )
        }
        let dateSections = groupItemsByDate(items)
        return dateSections.map { HistorySection(title: $0.title, records: $0.items) }
    }
}
