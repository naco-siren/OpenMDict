//
//  DictionaryMetadataRecord+CoreDataClass.swift
//  OpenMDict-iOS
//
//  Manually managed NSManagedObject subclass for imported dictionary metadata.
//  Replaces the DictionaryManifest.DictionaryEntry struct that was previously
//  stored in root manifest.json.
//  Marked `nonisolated` (SE-0449) — same pattern as LookupRecord.
//

import CoreData

@objc(DictionaryMetadataRecord)
nonisolated public class DictionaryMetadataRecord: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<DictionaryMetadataRecord> {
        return NSFetchRequest<DictionaryMetadataRecord>(entityName: "DictionaryMetadataRecord")
    }

    /// SHA256 hash of MDX header (used as folder name and unique ID).
    @NSManaged public var dictId: String

    /// User-editable display name.
    @NSManaged public var displayName: String

    /// Original MDX filename when imported (e.g., "MyDict.mdx").
    /// Used for duplicate detection and as display fallback.
    @NSManaged public var originalFileName: String

    /// Import timestamp.
    @NSManaged public var importedAt: Date?

    /// Last modification timestamp (resource added/removed).
    @NSManaged public var updatedAt: Date?

    /// Total size of all files in KB (for sorting: load smallest first).
    @NSManaged public var totalSizeKB: Int64

    /// Number of MDD resource files (0-N).
    @NSManaged public var mddCount: Int32

    /// Number of custom CSS files (0-N).
    @NSManaged public var cssCount: Int32

    /// Number of custom JS files (0-N).
    @NSManaged public var jsCount: Int32

    /// Number of custom font files (0-N).
    @NSManaged public var fontsCount: Int32

    // MARK: - Cloud Sync Fields

    /// CloudKit sync status for this dictionary's file archive.
    /// 0 = pending, 1 = synced, 2 = tooLarge, 3 = error
    @NSManaged public var cloudSyncStatus: Int16

    /// CKRecord.ID.recordName for the manually-managed DictionaryArchive
    /// CKRecord in CloudKit.  Nil if the archive hasn't been uploaded yet.
    @NSManaged public var cloudArchiveRecordName: String?
}
