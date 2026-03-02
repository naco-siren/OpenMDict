//
//  DictMetadataService.swift
//  OpenMDict-iOS
//
//  CoreData-backed persistence for imported dictionary metadata.
//  Replaces the root manifest.json's DictionaryEntry array.
//
//  Write-through pattern (same as GroupPersistenceService):
//  - Callers read/write directly through this service
//  - No in-memory cache: DictionaryService.allDictionaries already owns runtime state
//  - CoreData viewContext for synchronous reads; writes save immediately
//

import Combine
import CoreData
import Foundation

// MARK: - DTO

/// Lightweight value type for passing dictionary metadata across layers.
struct DictMetadata {
    let dictId: String
    var displayName: String
    let originalFileName: String
    let importedAt: Date
    var updatedAt: Date
    var totalSizeKB: Int64
    var mddCount: Int32
    var cssCount: Int32
    var jsCount: Int32
    var fontsCount: Int32
    var cloudSyncStatus: Int16
}

// MARK: - Service

final class DictMetadataService {

    static let shared = DictMetadataService()

    private var stack: CoreDataStack { CoreDataStack.shared }

    /// Revision counter — incremented on remote changes (so DictionaryService
    /// can detect new/removed dictionaries synced from other devices) and on
    /// local metadata writes (so bookmark/history VCs re-resolve display names).
    @Published private(set) var revision: UInt = 0

    /// Cancellable for CloudKit remote change subscription.
    private var remoteChangeCancellable: AnyCancellable?

    // MARK: - Reset

    /// Clear transient state and bump revision.
    /// Called during iCloud nuclear reset.
    func resetCaches() {
        downloadingDictIds.removeAll()
        revision &+= 1
    }

    private init() {
        // CloudKit remote change — bump revision so DictionaryService re-reads metadata
        remoteChangeCancellable = CoreDataStack.shared.remoteChangePublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                debugLog("☁️ DictMetadataService: remote change → revision bump")
                self?.revision += 1
            }
    }

    // MARK: - Read

    /// Load all dictionary metadata records, ordered by importedAt ascending.
    func loadAll() -> [DictMetadata] {
        let ctx = stack.viewContext
        let request = DictionaryMetadataRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: true)]

        do {
            let records = try ctx.fetch(request)
            return records.map { $0.toDTO() }
        } catch {
            debugLog("❌ DictMetadataService: failed to fetch all: \(error)")
            return []
        }
    }

    /// Find a single record by dictId.
    func find(dictId: String) -> DictMetadata? {
        fetchRecord(dictId: dictId)?.toDTO()
    }

    /// Find a single record by original filename.
    func find(originalFileName: String) -> DictMetadata? {
        let ctx = stack.viewContext
        let request = DictionaryMetadataRecord.fetchRequest()
        request.predicate = NSPredicate(format: "originalFileName == %@", originalFileName)
        request.fetchLimit = 1

        do {
            return try ctx.fetch(request).first?.toDTO()
        } catch {
            debugLog("❌ DictMetadataService: failed to find by filename: \(error)")
            return nil
        }
    }

    /// Check if any records exist (used for first-install detection).
    var hasAnyDictionaries: Bool {
        let ctx = stack.viewContext
        let request = DictionaryMetadataRecord.fetchRequest()
        request.fetchLimit = 1

        do {
            let count = try ctx.count(for: request)
            return count > 0
        } catch {
            debugLog("❌ DictMetadataService: count failed: \(error)")
            return false
        }
    }

    /// Get all imported dictionary IDs.
    var importedDictionaryIds: [String] {
        loadAll().map { $0.dictId }
    }

    // MARK: - Write

    /// Insert a new dictionary metadata record.
    func insert(_ metadata: DictMetadata) {
        let ctx = stack.viewContext

        // Guard against duplicates
        if fetchRecord(dictId: metadata.dictId) != nil {
            debugLog("⚠️ DictMetadataService: record already exists for \(metadata.dictId.prefix(16))...")
            return
        }

        let record = DictionaryMetadataRecord(context: ctx)
        record.dictId = metadata.dictId
        record.displayName = metadata.displayName
        record.originalFileName = metadata.originalFileName
        record.importedAt = metadata.importedAt
        record.updatedAt = metadata.updatedAt
        record.totalSizeKB = metadata.totalSizeKB
        record.mddCount = metadata.mddCount
        record.cssCount = metadata.cssCount
        record.jsCount = metadata.jsCount
        record.fontsCount = metadata.fontsCount

        save(ctx)
        revision += 1
    }

    /// Delete a dictionary metadata record by dictId.
    func delete(dictId: String) {
        let ctx = stack.viewContext
        guard let record = fetchRecord(dictId: dictId) else { return }
        ctx.delete(record)
        save(ctx)
        revision += 1
    }

    /// Update the display name for a dictionary.
    func updateDisplayName(dictId: String, newName: String) {
        let ctx = stack.viewContext
        guard let record = fetchRecord(dictId: dictId) else { return }
        record.displayName = newName
        record.updatedAt = Date()
        save(ctx)
        revision += 1
    }

    /// Sync resource counts from a per-dict manifest.
    /// Called after resource CRUD operations (add/remove MDD, CSS, JS).
    ///
    /// Updates resource counts in metadata.  Does NOT change cloudSyncStatus —
    /// incremental per-file sync (uploadSingleFile / deleteSingleFile) is
    /// handled by the caller (DictionaryService.syncAfterResourceAdd/Remove).
    func syncResourceCounts(dictId: String, mddCount: Int, cssCount: Int,
                            jsCount: Int, totalSizeKB: Int64) {
        let ctx = stack.viewContext
        guard let record = fetchRecord(dictId: dictId) else { return }
        record.mddCount = Int32(mddCount)
        record.cssCount = Int32(cssCount)
        record.jsCount = Int32(jsCount)
        record.totalSizeKB = totalSizeKB
        record.updatedAt = Date()
        save(ctx)
    }

    /// In-memory set of dictionaries currently downloading from CloudKit.
    /// Used by UI to show "syncing" state without writing `.pending` to CoreData
    /// (which would get exported back to CloudKit and overwrite the sender's `.synced`).
    private(set) var downloadingDictIds = Set<String>()

    /// Mark a dictionary as downloading (UI shows syncing arrow).
    func markDownloading(_ dictId: String) {
        downloadingDictIds.insert(dictId)
        revision += 1
    }

    /// Clear the downloading flag (UI reverts to CoreData's authoritative status).
    func clearDownloading(_ dictId: String) {
        downloadingDictIds.remove(dictId)
        revision += 1
    }

    // MARK: - Private Helpers

    private func fetchRecord(dictId: String) -> DictionaryMetadataRecord? {
        let ctx = stack.viewContext
        let request = DictionaryMetadataRecord.fetchRequest()
        request.predicate = NSPredicate(format: "dictId == %@", dictId)
        request.fetchLimit = 1

        do {
            return try ctx.fetch(request).first
        } catch {
            debugLog("❌ DictMetadataService: fetch by dictId failed: \(error)")
            return nil
        }
    }

    private func save(_ ctx: NSManagedObjectContext) {
        guard ctx.hasChanges else { return }
        do {
            try ctx.save()
        } catch {
            debugLog("❌ DictMetadataService: save failed: \(error)")
        }
    }
}

// MARK: - Record → DTO

extension DictionaryMetadataRecord {
    fileprivate func toDTO() -> DictMetadata {
        DictMetadata(
            dictId: dictId,
            displayName: displayName,
            originalFileName: originalFileName,
            importedAt: importedAt ?? Date(),
            updatedAt: updatedAt ?? Date(),
            totalSizeKB: totalSizeKB,
            mddCount: mddCount,
            cssCount: cssCount,
            jsCount: jsCount,
            fontsCount: fontsCount,
            cloudSyncStatus: cloudSyncStatus
        )
    }
}
