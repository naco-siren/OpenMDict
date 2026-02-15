//
//  LookupCountRecord+CoreDataClass.swift
//  OpenMDict-iOS
//
//  Manually managed NSManagedObject subclass for per-context trophy counters.
//  Marked `nonisolated` (SE-0449) — same pattern as LookupRecord.
//

import CoreData

@objc(LookupCountRecord)
nonisolated public class LookupCountRecord: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<LookupCountRecord> {
        return NSFetchRequest<LookupCountRecord>(entityName: "LookupCountRecord")
    }

    /// Context key: "d:{dictId}" for single-dictionary context,
    /// "g:{groupId}" for group context (including "g:all").
    @NSManaged public var contextKey: String

    /// Monotonically increasing lookup count for this context.
    @NSManaged public var count: Int64

    /// Last time this counter was updated (for sync conflict resolution).
    @NSManaged public var updatedAt: Date?
}
