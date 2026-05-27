//
//  ArticleIndexRecord+CoreDataClass.swift
//  OpenMDict-iOS
//
//  Manually managed NSManagedObject subclass (manual codegen — no
//  `codeGenerationType` in the .xcdatamodel). Marked `nonisolated`
//  (SE-0449) so the @NSManaged properties are NOT implicitly
//  MainActor-isolated under the project's `-default-isolation=MainActor`
//  setting — same established pattern as LookupRecord /
//  DictionaryMetadataRecord. See docs/CoreData_Swift6_Concurrency.md.
//
//  IMPORTANT: @NSManaged properties MUST be declared inside the class
//  body (not an extension) for `nonisolated` to propagate.
//
//  M15 Phase 3: this entity is LOCAL-ONLY — it lives in the "Local"
//  Configuration backed by OpenMDict_iOS_Local.sqlite, which
//  CoreDataStack loads WITHOUT cloudKitContainerOptions. Nothing here
//  ever syncs to CloudKit. (See the entity's comment in
//  OpenMDict_iOS.xcdatamodel for the full rationale.)
//

import CoreData

@objc(ArticleIndexRecord)
nonisolated public class ArticleIndexRecord: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ArticleIndexRecord> {
        return NSFetchRequest<ArticleIndexRecord>(entityName: "ArticleIndexRecord")
    }

    /// dictId == the dict's MDX header SHA256 (matches DictionaryMetadataRecord).
    @NSManaged public var dictId: String

    /// Persisted state, enum-encoded: notIndexed / indexing / indexed /
    /// paused / error. Decoded via `ArticleIndexRecordSnapshot.PersistedState`.
    @NSManaged public var stateRaw: String

    /// Checkpoint — how many articles have been encoded so far (for the
    /// resumable writer, Phase 3.5). 0 when not yet started.
    @NSManaged public var indexedThrough: Int32

    /// SHA256 of the CoreML model used for the last successful build.
    /// Nil until a build completes; used for sidecar invalidation.
    @NSManaged public var modelHash: String?

    /// SHA256 of the MDX header for the last successful build.
    @NSManaged public var mdxHash: String?

    /// Timestamp of the last state transition.
    @NSManaged public var lastUpdated: Date?

    /// User-assigned ordering for the indexing overview UI (drag-reorder).
    @NSManaged public var userPriorityOrder: Int32

    /// Per-dict "don't index this one" flag. Surfaces as `.paused`.
    @NSManaged public var userExcluded: Bool

    /// Last failure detail, when `stateRaw == "error"`. Nil otherwise.
    @NSManaged public var errorMessage: String?
}
