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
            print("❌ GroupPersistenceService: failed to fetch groups: \(error)")
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
            print("❌ GroupPersistenceService: failed to fetch entries: \(error)")
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

    // MARK: - Full Save (replace all)

    /// Replace all group + entry records with the given data.
    /// Called by DictionaryService.persistGroups().
    ///
    /// Strategy: delete-all then insert.
    /// This is acceptable because:
    /// - Group count is tiny (< 20 typical)
    /// - Mutations are infrequent (user-initiated only)
    /// - Simpler than diffing, no stale orphan risk
    func saveAllGroups(_ groups: [SavedGroup]) {
        let ctx = stack.viewContext

        // 1. Delete all existing records
        deleteAllRecords(entity: "DictionaryGroupRecord", in: ctx)
        deleteAllRecords(entity: "GroupEntryRecord", in: ctx)

        // 2. Insert fresh records
        for (index, group) in groups.enumerated() {
            let record = DictionaryGroupRecord(context: ctx)
            record.groupId = group.groupId
            record.name = group.name
            record.isDefault = group.isDefault
            record.sortOrder = Int32(index)
            record.createdAt = group.createdAt
            record.modifiedAt = group.modifiedAt

            for (dictIndex, dictId) in group.dictionaryIds.enumerated() {
                let entry = GroupEntryRecord(context: ctx)
                entry.groupId = group.groupId
                entry.dictId = dictId
                entry.sortOrder = Int32(dictIndex)
            }
        }

        // 3. Save
        do {
            try ctx.save()
            print("📂 GroupPersistenceService: saved \(groups.count) groups to CoreData")
        } catch {
            print("❌ GroupPersistenceService: save failed: \(error)")
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

    private func deleteAllRecords(entity: String, in ctx: NSManagedObjectContext) {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        deleteRequest.resultType = .resultTypeObjectIDs

        do {
            let result = try ctx.execute(deleteRequest) as? NSBatchDeleteResult
            if let objectIDs = result?.result as? [NSManagedObjectID] {
                let changes = [NSDeletedObjectsKey: objectIDs]
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: changes,
                    into: [ctx]
                )
            }
        } catch {
            print("❌ GroupPersistenceService: batch delete \(entity) failed: \(error)")
        }
    }
}
