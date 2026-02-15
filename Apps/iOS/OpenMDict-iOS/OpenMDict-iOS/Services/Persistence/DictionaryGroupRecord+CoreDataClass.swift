//
//  DictionaryGroupRecord+CoreDataClass.swift
//  OpenMDict-iOS
//
//  Manually managed NSManagedObject subclass for dictionary groups.
//  Marked `nonisolated` (SE-0449) — same pattern as LookupRecord.
//

import CoreData

@objc(DictionaryGroupRecord)
nonisolated public class DictionaryGroupRecord: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<DictionaryGroupRecord> {
        return NSFetchRequest<DictionaryGroupRecord>(entityName: "DictionaryGroupRecord")
    }

    /// Unique group identifier: UUID string or "all" for default group.
    @NSManaged public var groupId: String

    /// Display name for the group.
    @NSManaged public var name: String

    /// Whether this is the default "All Dictionaries" group.
    @NSManaged public var isDefault: Bool

    /// Sort position among all groups (default group = 0).
    @NSManaged public var sortOrder: Int32

    /// Creation timestamp.
    @NSManaged public var createdAt: Date?

    /// Last modification timestamp.
    @NSManaged public var modifiedAt: Date?
}
