//
//  LookupRecord+CoreDataClass.swift
//  OpenMDict-iOS
//
//  Manually managed NSManagedObject subclass.
//  Marked `nonisolated` (SE-0449) so that @NSManaged properties
//  are NOT implicitly MainActor-isolated under the project's
//  `-default-isolation=MainActor` setting.
//
//  This is the Apple-recommended pattern for CoreData + Swift 6
//  strict concurrency: NSManagedObject subclasses opt out of
//  global-actor isolation because CoreData enforces its own
//  thread-safety model via context-queue confinement.
//
//  IMPORTANT: @NSManaged properties MUST be declared inside the
//  class body (not in an extension) for `nonisolated` to propagate.
//

import CoreData

@objc(LookupRecord)
nonisolated public class LookupRecord: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<LookupRecord> {
        return NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
    }

    @NSManaged public var word: String?
    @NSManaged public var dictId: String?
    @NSManaged public var dictName: String?
    @NSManaged public var firstLookedUpAt: Date?
    @NSManaged public var lastLookedUpAt: Date?
    @NSManaged public var lookupCount: Int32

    /// Lookup context: non-nil when the lookup was performed in a single-dictionary context.
    @NSManaged public var lookupContextDictId: String?

    /// Lookup context: non-nil when the lookup was performed in a group context (including "all").
    @NSManaged public var lookupContextGroupId: String?
}
