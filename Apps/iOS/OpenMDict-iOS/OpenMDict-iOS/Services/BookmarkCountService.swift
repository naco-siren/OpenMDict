//
//  BookmarkCountService.swift
//  OpenMDict-iOS
//
//  In-memory cached repository for per-context trophy bookmark counts.
//
//  Architecture (DataRepository pattern — same as LookupCountService):
//  - An in-memory cache is the SINGLE SOURCE OF TRUTH for all reads.
//  - Writes update the cache synchronously on MainActor, then schedule a
//    deferred batch persist to CoreData.
//  - Increments `@Published revision` after every mutation so the UI can react.
//
//  Reuses the LookupCountRecord entity with distinct key prefixes:
//  - "bd:{dictId}" — bookmark trophy for a specific dictionary
//  - "bg:{groupId}" — bookmark trophy for a specific group
//
//  Flush strategy (three tiers):
//  1. Dirty-count threshold (≥10): immediate flush on high-frequency bookmarks.
//  2. Debounce timer (2 seconds): coalesces low-frequency writes.
//  3. Lifecycle callbacks (background / memory warning / terminate): safety net.
//

import Combine
import CoreData
import Foundation
import OpenMDictKit
import UIKit

// MARK: - Service

final class BookmarkCountService {

    static let shared = BookmarkCountService()

    private var stack: CoreDataStack { CoreDataStack.shared }

    // MARK: - Combine Publishers

    /// Revision counter — incremented after every cache mutation.
    @Published private(set) var revision: UInt = 0

    // MARK: - In-Memory Cache

    /// The single source of truth: contextKey → count.
    private var cache: [String: Int64] = [:]

    /// Whether the cache has been populated from CoreData.
    private var isCachePopulated = false

    /// Keys of cache entries that need CoreData upsert.
    private var dirtyKeys: Set<String> = []

    /// Coalescing timer for deferred persistence.
    private var deferredPersistWorkItem: DispatchWorkItem?

    /// Dirty count threshold: flush immediately when reached.
    private let flushThreshold = 10

    /// Cancellable for CloudKit remote change subscription.
    private var remoteChangeCancellable: AnyCancellable?

    // MARK: - Reset

    /// Discard all in-memory state.  Called during iCloud nuclear reset
    /// after the CoreData store has been deleted and recreated.
    func resetCaches() {
        deferredPersistWorkItem?.cancel()
        deferredPersistWorkItem = nil
        cache.removeAll()
        dirtyKeys.removeAll()
        isCachePopulated = false
        revision &+= 1
    }

    // MARK: - Init

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFlushTrigger),
            name: UIScene.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFlushTrigger),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
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

    // MARK: - Cache Population (lazy, on first read/write)

    private func ensureCachePopulated() {
        guard !isCachePopulated else { return }
        populateCacheFromCoreData()
        isCachePopulated = true
    }

    /// Reload the entire cache from CoreData.
    /// Called on CloudKit remote change to pick up counters synced from other devices.
    /// Uses max() merge: if local cache has a higher count, keep it.
    ///
    /// IMPORTANT: do NOT call flushDirtyEntriesToCoreData() here.
    /// Background ctx.save() fires NSPersistentStoreRemoteChange (even for
    /// local saves when persistent history tracking is enabled), which would
    /// re-trigger this handler and create an infinite feedback loop.  Dirty
    /// entries are safe — they stay in the cache and will be flushed by the
    /// normal three-tier schedule (threshold / debounce / lifecycle).
    /// The max() merge below preserves any local cache values that are higher
    /// than what CoreData has, so no data is lost.
    private func reloadCacheFromCoreData() {
        guard isCachePopulated else { return }

        let ctx = stack.viewContext
        let request = LookupCountRecord.fetchRequest()
        request.predicate = Self.bookmarkKeysPredicate
        do {
            let records = try ctx.fetch(request)
            // Merge using max() — monotonically increasing counters
            var merged: [String: Int64] = [:]
            for record in records {
                let existing = cache[record.contextKey] ?? 0
                merged[record.contextKey] = max(existing, record.count)
            }
            // Also preserve any cache entries not yet in CoreData
            for (key, count) in cache where merged[key] == nil {
                merged[key] = count
            }
            cache = merged
            revision += 1
            debugLog("☁️ BookmarkCountService: cache reloaded (\(merged.count) entries)")
        } catch {
            debugLog("❌ BookmarkCountService: reload failed: \(error)")
        }
    }

    private func populateCacheFromCoreData() {
        let ctx = stack.viewContext
        let request = LookupCountRecord.fetchRequest()
        request.predicate = Self.bookmarkKeysPredicate
        do {
            let records = try ctx.fetch(request)
            for record in records {
                let existing = cache[record.contextKey] ?? 0
                cache[record.contextKey] = max(existing, record.count)
            }
            debugLog("📊 BookmarkCountService: loaded \(records.count) trophy counters from CoreData")
        } catch {
            debugLog("❌ BookmarkCountService: failed to populate cache: \(error)")
        }
    }

    /// Predicate to fetch only bookmark-related records (bd: / bg: prefixes).
    private static let bookmarkKeysPredicate = NSPredicate(
        format: "contextKey BEGINSWITH %@ OR contextKey BEGINSWITH %@", "bd:", "bg:"
    )

    // MARK: - Public API

    /// Increment the bookmark trophy counter for a context.
    /// Trophy counters are monotonically increasing and survive bookmark deletion.
    func incrementBookmarkCount(contextDictId: String?, contextGroupId: String?) {
        guard let key = Self.contextKey(dictId: contextDictId, groupId: contextGroupId) else { return }
        ensureCachePopulated()
        cache[key, default: 0] += 1
        dirtyKeys.insert(key)
        revision += 1
        scheduleDeferredPersist()
    }

    /// Get the bookmark trophy counter for a context.
    func bookmarkCount(contextDictId: String?, contextGroupId: String?) -> Int {
        guard let key = Self.contextKey(dictId: contextDictId, groupId: contextGroupId) else { return 0 }
        ensureCachePopulated()
        return Int(cache[key] ?? 0)
    }

    /// Convenience: increment bookmark trophies for a dict + all groups containing it.
    /// Called from main app UI code after a successful bookmark creation.
    func incrementAll(dictId: String) {
        incrementBookmarkCount(contextDictId: dictId, contextGroupId: nil)
        for group in DictionaryService.shared.groups where group.dictionaryIds.contains(dictId) {
            incrementBookmarkCount(contextDictId: nil, contextGroupId: group.id)
        }
    }

    // MARK: - Key Building

    /// Build the context key from dict/group IDs.
    /// Exactly one parameter should be non-nil.
    private static func contextKey(dictId: String?, groupId: String?) -> String? {
        if let dictId { return "bd:\(dictId)" }
        if let groupId { return "bg:\(groupId)" }
        return nil
    }

    // MARK: - Deferred Persistence

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

    private func flushDirtyEntriesToCoreData() {
        deferredPersistWorkItem?.cancel()
        deferredPersistWorkItem = nil

        let keysToFlush = dirtyKeys
        guard !keysToFlush.isEmpty else { return }

        // Snapshot current values (let binding for Sendable capture)
        let snapshot: [String: Int64] = keysToFlush.reduce(into: [:]) { result, key in
            if let value = cache[key] { result[key] = value }
        }
        dirtyKeys.removeAll()

        // Write to CoreData on background context
        let ctx = stack.newBackgroundContext()
        Task.detached {
            await ctx.perform(schedule: .immediate) {
                for (key, count) in snapshot {
                    // Fetch-or-create pattern
                    let request = LookupCountRecord.fetchRequest()
                    request.predicate = NSPredicate(format: "contextKey == %@", key)
                    request.fetchLimit = 1

                    let record: LookupCountRecord
                    if let existing = try? ctx.fetch(request).first {
                        record = existing
                    } else {
                        record = LookupCountRecord(context: ctx)
                        record.contextKey = key
                    }
                    // Trophy counters are monotonically increasing:
                    // take the max in case of sync conflicts.
                    record.count = max(record.count, count)
                    record.updatedAt = Date()
                }

                do {
                    try ctx.save()
                } catch {
                    debugLog("❌ BookmarkCountService: background save failed: \(error)")
                }
            }
        }
    }
}
