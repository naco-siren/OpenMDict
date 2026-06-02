//
//  ArticleIndexService.swift
//  OpenMDict-iOS  (M15 Phase 3.4)
//
//  Per-dict article-embedding indexing state persistence. Mirrors the
//  M11 DataRepository pattern used by LookupCountService /
//  LookupHistoryService: an in-memory cache is the single source of
//  truth for reads, writes update the cache + persist to CoreData,
//  Combine `@Published revision` notifies observers.
//
//  Why simpler than LookupCountService:
//
//    - Write volume is low (per-dict events: import / index start /
//      progress checkpoint / complete / error / user pause). At most a
//      few per minute during active indexing. No need for a debounce
//      timer or dirty-set batching — writes are sync write-through on
//      MainActor.
//    - The cache is small (one record per dict, ~20 records max for a
//      typical user library), so full reload from CoreData is cheap.
//
//  LOCAL-ONLY: `ArticleIndexRecord` lives in the "Local" Configuration
//  (OpenMDict_iOS_Local.sqlite), never CloudKit-synced — indexing state
//  is inherently per-device. Consequently this service does NOT
//  subscribe to CloudKit remote-change notifications (unlike
//  LookupCountService et al.): the Local store never emits them and
//  there's no cross-device replication to react to. The Coordinator
//  still validates `.indexed` against actual sidecar-file presence +
//  the model/MDX hashes, so a stale row (sidecar evicted from Caches/,
//  or model upgraded) self-heals to `.notIndexed` at introspection.
//

import Combine
import CoreData
import Foundation
import UIKit

// MARK: - Snapshot type

/// In-memory snapshot of an `ArticleIndexRecord`. Sendable + Equatable
/// for clean propagation through Combine. The actual CoreData entity
/// class (`ArticleIndexRecord`) is NSManagedObject — not Sendable, not
/// suitable for crossing the MainActor boundary.
struct ArticleIndexRecordSnapshot: Sendable, Equatable {
    let dictId: String
    let state: PersistedState
    let indexedThrough: Int32
    let modelHash: String?
    let mdxHash: String?
    let lastUpdated: Date?
    let userPriorityOrder: Int32
    let userExcluded: Bool
    let errorMessage: String?

    /// Maps to the stored `stateRaw` string. Kept separate from
    /// `ArticleIndexState` (the UI-facing state in ArticleIndexState.swift)
    /// because persisted state never carries the `.notSupported` or
    /// `.pendingDownload` cases — those are computed at runtime from
    /// the (language, model) check.
    enum PersistedState: String, Sendable {
        case notIndexed
        case indexing
        case indexed
        case paused
        case error
    }

    /// Default for a freshly-discovered dict.
    static func initial(dictId: String) -> ArticleIndexRecordSnapshot {
        ArticleIndexRecordSnapshot(
            dictId: dictId, state: .notIndexed, indexedThrough: 0,
            modelHash: nil, mdxHash: nil, lastUpdated: nil,
            userPriorityOrder: 0, userExcluded: false, errorMessage: nil
        )
    }
}

// MARK: - Service

@MainActor
final class ArticleIndexService {

    static let shared = ArticleIndexService()

    private var stack: CoreDataStack { CoreDataStack.shared }

    /// Revision counter — incremented after every mutation so UI can
    /// react via `$revision.dropFirst().sink { ... }` (the standard
    /// M11 pattern; see LookupCountService for prior art).
    @Published private(set) var revision: UInt = 0

    /// Per-dictId cached snapshot. Single source of truth.
    private var cache: [String: ArticleIndexRecordSnapshot] = [:]

    private var isCachePopulated = false

    private init() {
        // No CloudKit remote-change subscription: ArticleIndexRecord is
        // local-only (the "Local" store never emits remote-change
        // notifications), so there's nothing cross-device to react to.
        // Contrast LookupCountService, which subscribes precisely
        // because its entity IS CloudKit-synced.
    }

    // MARK: - Reset (called by LocalDataResetService nuclear path)

    func resetCaches() {
        cache.removeAll()
        isCachePopulated = false
        revision &+= 1
    }

    // MARK: - Read API

    /// Get the snapshot for a dict, populating the cache lazily on
    /// first access. Returns the `initial(...)` default if no record
    /// exists yet — callers don't need to handle a nil case.
    func snapshot(for dictId: String) -> ArticleIndexRecordSnapshot {
        ensureCachePopulated()
        return cache[dictId] ?? .initial(dictId: dictId)
    }

    /// All current snapshots, sorted by `userPriorityOrder` ascending
    /// (the order the user dragged them into in the indexing overview
    /// UI). Used by the overview page to render the list.
    func allSnapshots() -> [ArticleIndexRecordSnapshot] {
        ensureCachePopulated()
        return cache.values.sorted { $0.userPriorityOrder < $1.userPriorityOrder }
    }

    /// Combine publisher for one dict's snapshot. Re-emits whenever
    /// `revision` ticks and the snapshot for `dictId` actually changed.
    /// UI subscribes per-dict for fine-grained cell updates without
    /// rebuilding the whole list.
    func snapshotPublisher(for dictId: String) -> AnyPublisher<ArticleIndexRecordSnapshot, Never> {
        $revision
            .map { [weak self] _ in self?.snapshot(for: dictId) ?? .initial(dictId: dictId) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - Write API

    /// Upsert the snapshot for a dict. Write-through to CoreData
    /// synchronously on the viewContext — writes are infrequent enough
    /// that batching isn't worth the complexity.
    func upsert(_ snap: ArticleIndexRecordSnapshot) {
        ensureCachePopulated()
        cache[snap.dictId] = snap
        persist(snap)
        revision &+= 1
    }

    /// Convenience: transition state + update timestamp. Other fields
    /// preserved from the existing snapshot (or `initial(...)` if no
    /// record yet).
    func setState(_ state: ArticleIndexRecordSnapshot.PersistedState,
                  for dictId: String,
                  indexedThrough: Int32? = nil,
                  modelHash: String? = nil,
                  mdxHash: String? = nil,
                  errorMessage: String? = nil) {
        let prev = snapshot(for: dictId)
        let next = ArticleIndexRecordSnapshot(
            dictId: dictId,
            state: state,
            indexedThrough: indexedThrough ?? prev.indexedThrough,
            modelHash: modelHash ?? prev.modelHash,
            mdxHash: mdxHash ?? prev.mdxHash,
            lastUpdated: Date(),
            userPriorityOrder: prev.userPriorityOrder,
            userExcluded: prev.userExcluded,
            errorMessage: state == .error ? (errorMessage ?? prev.errorMessage) : nil
        )
        upsert(next)
    }

    /// Update only `indexedThrough` for a dict. Preserves state — fixes
    /// the race where a progress callback hopping to MainActor via
    /// `Task { @MainActor in ... }` runs AFTER a `userPause` already
    /// transitioned state to `.paused`. If progress used `setState(.indexing)`
    /// like before, it would clobber the .paused back to .indexing and the
    /// `executeJob` `.interrupted` branch would persist .indexing (because
    /// `prev.state` reads the just-clobbered value), causing the user's
    /// "toggle-disabled while indexing → state shows as 'To be indexed'"
    /// bug. Now the writer's progress only advances the checkpoint
    /// counter; state transitions are exclusively the caller's job.
    func updateProgress(_ indexedThrough: Int32, for dictId: String) {
        var snap = snapshot(for: dictId)
        snap = ArticleIndexRecordSnapshot(
            dictId: snap.dictId, state: snap.state,
            indexedThrough: indexedThrough,
            modelHash: snap.modelHash, mdxHash: snap.mdxHash,
            lastUpdated: Date(),
            userPriorityOrder: snap.userPriorityOrder,
            userExcluded: snap.userExcluded,
            errorMessage: snap.errorMessage
        )
        upsert(snap)
    }

    /// User-action: set the userExcluded flag (per-dict pause).
    /// Preserves other fields.
    func setUserExcluded(_ excluded: Bool, for dictId: String) {
        var snap = snapshot(for: dictId)
        snap = ArticleIndexRecordSnapshot(
            dictId: snap.dictId, state: snap.state,
            indexedThrough: snap.indexedThrough,
            modelHash: snap.modelHash, mdxHash: snap.mdxHash,
            lastUpdated: snap.lastUpdated,
            userPriorityOrder: snap.userPriorityOrder,
            userExcluded: excluded,
            errorMessage: snap.errorMessage
        )
        upsert(snap)
    }

    /// User-action: reorder per the drag UI. Pass the dictIds in the
    /// order they should appear; we re-assign `userPriorityOrder` to
    /// 0..<N matching that order.
    func reorderUserPriority(_ dictIds: [String]) {
        ensureCachePopulated()
        for (idx, dictId) in dictIds.enumerated() {
            var snap = cache[dictId] ?? .initial(dictId: dictId)
            snap = ArticleIndexRecordSnapshot(
                dictId: snap.dictId, state: snap.state,
                indexedThrough: snap.indexedThrough,
                modelHash: snap.modelHash, mdxHash: snap.mdxHash,
                lastUpdated: snap.lastUpdated,
                userPriorityOrder: Int32(idx),
                userExcluded: snap.userExcluded,
                errorMessage: snap.errorMessage
            )
            cache[dictId] = snap
            persist(snap)
        }
        revision &+= 1
    }

    /// Normalize orphan `.indexing` records on app launch / coordinator
    /// init. Any record persisted as `.indexing` whose `dictId != liveJob`
    /// is converted to `.notIndexed` (with `indexedThrough` preserved so
    /// the writer's resume-from-disk-partial path still kicks in when the
    /// scheduler picks it up).
    ///
    /// Without this, a force-kill / crash mid-encode leaves a phantom
    /// `.indexing` row that the UI shows as a perpetually-spinning cell
    /// (no live job → spinner never advances). The Coordinator's
    /// `backfillIfEnabled` + new eligibility rule together would still
    /// pick it up, but the UI would be wrong until the scheduler got to
    /// it. Normalizing at launch makes the UI immediately correct.
    func normalizeOrphanIndexing(liveJob: String?) {
        ensureCachePopulated()
        var changed = 0
        for (dictId, snap) in cache where snap.state == .indexing && dictId != liveJob {
            let next = ArticleIndexRecordSnapshot(
                dictId: snap.dictId,
                state: .notIndexed,
                indexedThrough: snap.indexedThrough,
                modelHash: snap.modelHash, mdxHash: snap.mdxHash,
                lastUpdated: Date(),
                userPriorityOrder: snap.userPriorityOrder,
                userExcluded: snap.userExcluded,
                errorMessage: nil
            )
            cache[dictId] = next
            persist(next)
            changed += 1
        }
        if changed > 0 {
            debugLog("🧹 ArticleIndexService: normalized \(changed) orphan .indexing record(s) → .notIndexed")
            revision &+= 1
        }
    }

    /// One-shot launch normalize: rows persisted as `.error` with
    /// `errorMessage == "Dictionary not loaded"` are wiped back to
    /// `.notIndexed`. That specific message came from an earlier
    /// dispatcher bug where `executeJob` ran during the dictionary-load
    /// window and persisted `.error` for every dict whose reader hadn't
    /// finished mmap'ing yet. The dispatcher no longer persists that
    /// state (it leaves the row untouched and waits for the next
    /// backfill), but the legacy poison sits in CoreData on any device
    /// that ran the buggy version — every cell shows "Dictionary not
    /// loaded" forever because `isSchedulerEligible` filters `.error`
    /// out, so the backfill enqueues 0 and the user sees stale rows.
    ///
    /// Safe to run unconditionally on launch: real `.error` rows
    /// (encoder load failed, build failed, etc.) carry different
    /// `errorMessage`s and aren't touched.
    func normalizeStaleNotLoadedErrors() {
        ensureCachePopulated()
        var changed = 0
        for (dictId, snap) in cache
            where snap.state == .error && snap.errorMessage == "Dictionary not loaded"
        {
            let next = ArticleIndexRecordSnapshot(
                dictId: snap.dictId,
                state: .notIndexed,
                indexedThrough: snap.indexedThrough,
                modelHash: snap.modelHash, mdxHash: snap.mdxHash,
                lastUpdated: Date(),
                userPriorityOrder: snap.userPriorityOrder,
                userExcluded: snap.userExcluded,
                errorMessage: nil
            )
            cache[dictId] = next
            persist(next)
            changed += 1
        }
        if changed > 0 {
            debugLog("🧹 ArticleIndexService: cleared \(changed) stale 'Dictionary not loaded' .error record(s) → .notIndexed")
            revision &+= 1
        }
    }

    /// Delete the record for a dict (called when the dict itself is
    /// deleted from the library).
    func delete(dictId: String) {
        ensureCachePopulated()
        cache.removeValue(forKey: dictId)
        deleteFromCoreData(dictId: dictId)
        revision &+= 1
    }

    // MARK: - CoreData I/O

    private func ensureCachePopulated() {
        guard !isCachePopulated else { return }
        let ctx = stack.viewContext
        let request = ArticleIndexRecord.fetchRequest()
        do {
            let records = try ctx.fetch(request)
            for record in records {
                let snap = Self.snapshot(from: record)
                cache[snap.dictId] = snap
            }
            debugLog("📊 ArticleIndexService: loaded \(records.count) records from CoreData")
        } catch {
            debugLog("❌ ArticleIndexService: failed to populate cache: \(error)")
        }
        isCachePopulated = true
    }

    /// Upsert (find-or-create) on viewContext + save. Synchronous so
    /// the cache and CoreData are guaranteed consistent at method exit.
    private func persist(_ snap: ArticleIndexRecordSnapshot) {
        let ctx = stack.viewContext
        let request = ArticleIndexRecord.fetchRequest()
        request.predicate = NSPredicate(format: "dictId == %@", snap.dictId)
        request.fetchLimit = 1
        do {
            let record = try ctx.fetch(request).first ?? ArticleIndexRecord(context: ctx)
            record.dictId = snap.dictId
            record.stateRaw = snap.state.rawValue
            record.indexedThrough = snap.indexedThrough
            record.modelHash = snap.modelHash
            record.mdxHash = snap.mdxHash
            record.lastUpdated = snap.lastUpdated
            record.userPriorityOrder = snap.userPriorityOrder
            record.userExcluded = snap.userExcluded
            record.errorMessage = snap.errorMessage
            if ctx.hasChanges { try ctx.save() }
        } catch {
            debugLog("❌ ArticleIndexService: persist failed for \(snap.dictId): \(error)")
        }
    }

    private func deleteFromCoreData(dictId: String) {
        let ctx = stack.viewContext
        let request = ArticleIndexRecord.fetchRequest()
        request.predicate = NSPredicate(format: "dictId == %@", dictId)
        do {
            let records = try ctx.fetch(request)
            for r in records { ctx.delete(r) }
            if ctx.hasChanges { try ctx.save() }
        } catch {
            debugLog("❌ ArticleIndexService: delete failed for \(dictId): \(error)")
        }
    }

    /// Build a snapshot from a CoreData record. Non-optional attributes
    /// (dictId, stateRaw, indexedThrough, userPriorityOrder,
    /// userExcluded) are guaranteed non-nil by the model's default
    /// values; only `stateRaw` needs a fallback, for an unknown enum
    /// string from a future schema.
    private static func snapshot(from record: ArticleIndexRecord) -> ArticleIndexRecordSnapshot {
        let state = ArticleIndexRecordSnapshot.PersistedState(rawValue: record.stateRaw) ?? .notIndexed
        return ArticleIndexRecordSnapshot(
            dictId: record.dictId,
            state: state,
            indexedThrough: record.indexedThrough,
            modelHash: record.modelHash,
            mdxHash: record.mdxHash,
            lastUpdated: record.lastUpdated,
            userPriorityOrder: record.userPriorityOrder,
            userExcluded: record.userExcluded,
            errorMessage: record.errorMessage
        )
    }
}
