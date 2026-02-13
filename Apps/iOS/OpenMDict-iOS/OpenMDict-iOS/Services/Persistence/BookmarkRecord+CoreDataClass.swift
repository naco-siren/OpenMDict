//
//  BookmarkRecord+CoreDataClass.swift
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

@objc(BookmarkRecord)
nonisolated public class BookmarkRecord: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<BookmarkRecord> {
        return NSFetchRequest<BookmarkRecord>(entityName: "BookmarkRecord")
    }

    @NSManaged public var word: String?
    @NSManaged public var dictId: String?
    @NSManaged public var dictName: String?
    @NSManaged public var createdAt: Date?
}
