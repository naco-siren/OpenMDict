//
//  GroupEntryRecord+CoreDataClass.swift
//  OpenMDict-iOS
//
//  Manually managed NSManagedObject subclass for group entries.
//  Join entity: a (groupId, dictId) pair with sortOrder for ordering.
//  Marked `nonisolated` (SE-0449) — same pattern as LookupRecord.
//
//  Why a join entity instead of a to-many relationship?
//  CloudKit does not support ordered relationships.
//  GroupEntryRecord + sortOrder is the standard CloudKit pattern
//  for ordered many-to-many.
//

import CoreData

@objc(GroupEntryRecord)
nonisolated public class GroupEntryRecord: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<GroupEntryRecord> {
        return NSFetchRequest<GroupEntryRecord>(entityName: "GroupEntryRecord")
    }

    /// Group identifier (matches DictionaryGroupRecord.groupId).
    @NSManaged public var groupId: String

    /// Dictionary identifier (SHA256 hash).
    @NSManaged public var dictId: String

    /// Sort position of this dictionary within the group.
    @NSManaged public var sortOrder: Int32
}
