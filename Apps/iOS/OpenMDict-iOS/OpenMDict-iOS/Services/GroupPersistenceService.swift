//
//  GroupPersistenceService.swift
//  OpenMDict-iOS
//
//  CoreData-backed persistence for dictionary groups and group entries.
//
//  This is NOT a DataRepository (unlike LookupCountService / LookupHistoryService)
//  because group mutations are infrequent and always explicit (user action).
//  Instead, we write through to CoreData synchronously on the view context,
//  keeping the code simple.
//
//  Architecture:
//  - DictionaryService owns the in-memory MDicts array (single source of truth for UI).
//  - GroupPersistenceService handles CoreData reads/writes only.
//  - On launch, DictionaryService calls `loadGroups()` to populate MDicts from CoreData.
//  - On every group mutation, DictionaryService calls the appropriate save method.
//
//  Save strategy: diff-based update (not delete-all-then-insert).
//  Only changed records are inserted/updated/deleted, which is safe for
//  CloudKit sync where every delete propagates to all devices.
//

import CoreData
import Foundation

// MARK: - Loaded Group DTO

/// Lightweight value type returned by loadGroups().
/// DictionaryService converts these into MDicts instances.
struct LoadedGroup {
    let groupId: String
    let name: String
    let isDefault: Bool
    let sortOrder: Int32
    let createdAt: Date?
    let modifiedAt: Date?
    /// Ordered dictionary IDs for this group.
    let dictionaryIds: [String]
}

// MARK: - Service

final class GroupPersistenceService {

    static let shared = GroupPersistenceService()

    private var stack: CoreDataStack { CoreDataStack.shared }

    private init() {}

    // MARK: - Read

    /// Load all groups (with their entries) from CoreData, sorted by sortOrder.
    /// Returns empty array on first launch (no groups in CoreData yet).
    func loadGroups() -> [LoadedGroup] {
        let ctx = stack.viewContext

        // 1. Fetch all group records, sorted by sortOrder
        let groupRequest = DictionaryGroupRecord.fetchRequest()
        groupRequest.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]

        let groupRecords: [DictionaryGroupRecord]
        do {
            groupRecords = try ctx.fetch(groupRequest)
        } catch {
            debugLog("❌ GroupPersistenceService: failed to fetch groups: \(error)")
            return []
        }

        guard !groupRecords.isEmpty else { return [] }

        // 2. Fetch all entry records in one batch
        let entryRequest = GroupEntryRecord.fetchRequest()
        entryRequest.sortDescriptors = [
            NSSortDescriptor(key: "groupId", ascending: true),
            NSSortDescriptor(key: "sortOrder", ascending: true)
        ]

        let entryRecords: [GroupEntryRecord]
        do {
            entryRecords = try ctx.fetch(entryRequest)
        } catch {
            debugLog("❌ GroupPersistenceService: failed to fetch entries: \(error)")
            return []
        }

        // 3. Index entries by groupId
        var entriesByGroup: [String: [GroupEntryRecord]] = [:]
        for record in entryRecords {
            entriesByGroup[record.groupId, default: []].append(record)
        }

        // 4. Build LoadedGroup array
        return groupRecords.map { record in
            let entries = entriesByGroup[record.groupId] ?? []
            let dictIds = entries.map { $0.dictId }
            return LoadedGroup(
                groupId: record.groupId,
                name: record.name,
                isDefault: record.isDefault,
                sortOrder: record.sortOrder,
                createdAt: record.createdAt,
                modifiedAt: record.modifiedAt,
                dictionaryIds: dictIds
            )
        }
    }

    // MARK: - Full Save (diff-based)

    /// Persist groups by diffing against existing CoreData records.
    /// Only inserts, updates, or deletes the records that actually changed.
    /// Called by DictionaryService.persistGroups().
    func saveAllGroups(_ groups: [SavedGroup]) {
        let ctx = stack.viewContext

        // 1. Fetch all existing group records → index by groupId
        let existingGroups: [String: DictionaryGroupRecord]
        do {
            let request = DictionaryGroupRecord.fetchRequest()
            let records = try ctx.fetch(request)
            existingGroups = Dictionary(uniqueKeysWithValues: records.map { ($0.groupId, $0) })
        } catch {
            debugLog("❌ GroupPersistenceService: failed to fetch existing groups: \(error)")
            return
        }

        // 2. Fetch all existing entry records → index by groupId
        let existingEntries: [String: [GroupEntryRecord]]
        do {
            let request = GroupEntryRecord.fetchRequest()
            let records = try ctx.fetch(request)
            var index: [String: [GroupEntryRecord]] = [:]
            for record in records {
                index[record.groupId, default: []].append(record)
            }
            existingEntries = index
        } catch {
            debugLog("❌ GroupPersistenceService: failed to fetch existing entries: \(error)")
            return
        }

        // 3. Compute set differences
        let incomingIds = Set(groups.map { $0.groupId })
        let existingIds = Set(existingGroups.keys)

        // 4. Delete groups that no longer exist
        for groupId in existingIds.subtracting(incomingIds) {
            if let groupRecord = existingGroups[groupId] {
                ctx.delete(groupRecord)
            }
            for entry in existingEntries[groupId] ?? [] {
                ctx.delete(entry)
            }
        }

        // 5. Update existing or insert new groups + diff entries
        for (index, group) in groups.enumerated() {
            if let existing = existingGroups[group.groupId] {
                // UPDATE: only touch changed fields
                existing.name = group.name
                existing.isDefault = group.isDefault
                existing.sortOrder = Int32(index)
                existing.modifiedAt = group.modifiedAt
            } else {
                // INSERT: new group
                let record = DictionaryGroupRecord(context: ctx)
                record.groupId = group.groupId
                record.name = group.name
                record.isDefault = group.isDefault
                record.sortOrder = Int32(index)
                record.createdAt = group.createdAt
                record.modifiedAt = group.modifiedAt
            }

            // Diff entries for this group
            diffEntries(
                ctx: ctx,
                groupId: group.groupId,
                incoming: group.dictionaryIds,
                existing: existingEntries[group.groupId] ?? []
            )
        }

        // 6. Save
        guard ctx.hasChanges else { return }
        do {
            try ctx.save()
            debugLog("📂 GroupPersistenceService: saved \(groups.count) groups to CoreData")
        } catch {
            debugLog("❌ GroupPersistenceService: save failed: \(error)")
        }
    }

    // MARK: - Helper Types

    /// Lightweight value type for saving. DictionaryService builds these from MDicts.
    struct SavedGroup {
        let groupId: String
        let name: String
        let isDefault: Bool
        let createdAt: Date?
        let modifiedAt: Date?
        let dictionaryIds: [String]
    }

    // MARK: - Private Helpers

    /// Reconcile entry records for a single group using diff.
    /// Deletes entries no longer in the group, updates sortOrder for
    /// existing entries, and inserts new entries.
    private func diffEntries(
        ctx: NSManagedObjectContext,
        groupId: String,
        incoming: [String],
        existing: [GroupEntryRecord]
    ) {
        // Index existing entries by dictId
        let existingByDictId = Dictionary(uniqueKeysWithValues: existing.map { ($0.dictId, $0) })
        let incomingSet = Set(incoming)

        // Delete entries no longer in this group
        for entry in existing where !incomingSet.contains(entry.dictId) {
            ctx.delete(entry)
        }

        // Update sortOrder or insert new entries
        for (index, dictId) in incoming.enumerated() {
            if let entry = existingByDictId[dictId] {
                entry.sortOrder = Int32(index)
            } else {
                let entry = GroupEntryRecord(context: ctx)
                entry.groupId = groupId
                entry.dictId = dictId
                entry.sortOrder = Int32(index)
            }
        }
    }
}
