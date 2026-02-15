//
//  LookupCountService.swift
//  OpenMDict-iOS
//
//  In-memory cached repository for per-context trophy lookup counts.
//
//  Architecture (DataRepository pattern — same as LookupHistoryService):
//  - An in-memory cache is the SINGLE SOURCE OF TRUTH for all reads.
//  - Writes update the cache synchronously on MainActor, then schedule a
//    deferred batch persist to CoreData.
//  - Increments `@Published revision` after every mutation so the UI can react.
//
//  Flush strategy (three tiers):
//  1. Dirty-count threshold (≥10): immediate flush on high-frequency lookups.
//  2. Debounce timer (2 seconds): coalesces low-frequency writes.
//  3. Lifecycle callbacks (background / memory warning / terminate): safety net.
//
//

import Combine
import CoreData
import Foundation
import UIKit

// MARK: - Service

final class LookupCountService {

    static let shared = LookupCountService()

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
    }

    @objc private func handleFlushTrigger() {
        flushDirtyEntriesToCoreData()
    }

    // MARK: - Cache Population (lazy, on first read/write)

    private func ensureCachePopulated() {
        guard !isCachePopulated else { return }
        let ctx = stack.viewContext
        let request = LookupCountRecord.fetchRequest()
        do {
            let records = try ctx.fetch(request)
            for record in records {
                cache[record.contextKey] = record.count
            }
            print("📊 LookupCountService: loaded \(records.count) trophy counters from CoreData")
        } catch {
            print("❌ LookupCountService: failed to populate cache: \(error)")
        }
        isCachePopulated = true
    }

    // MARK: - Public API

    /// Increment the trophy counter for a context.
    /// Trophy counters are monotonically increasing and survive history deletion.
    func incrementLookupCount(contextDictId: String?, contextGroupId: String?) {
        guard let key = Self.contextKey(dictId: contextDictId, groupId: contextGroupId) else { return }
        ensureCachePopulated()
        cache[key, default: 0] += 1
        dirtyKeys.insert(key)
        revision += 1
        scheduleDeferredPersist()
    }

    /// Get the trophy counter for a context.
    func lookupCount(contextDictId: String?, contextGroupId: String?) -> Int {
        guard let key = Self.contextKey(dictId: contextDictId, groupId: contextGroupId) else { return 0 }
        ensureCachePopulated()
        return Int(cache[key] ?? 0)
    }

    // MARK: - Key Building

    /// Build the context key from dict/group IDs.
    /// Exactly one parameter should be non-nil.
    private static func contextKey(dictId: String?, groupId: String?) -> String? {
        if let dictId { return "d:\(dictId)" }
        if let groupId { return "g:\(groupId)" }
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
                    print("❌ LookupCountService: background save failed: \(error)")
                }
            }
        }
    }
}
