//
//  DictionaryManifest.swift
//  OpenMDictKit
//
//  Data model for persisting user-imported dictionaries and group configurations.
//  Stored as JSON in Library/Dictionaries/manifest.json
//
//  Moved from iOS app layer to enable sharing between iOS and macOS.
//

import Foundation

// MARK: - DictionaryManifest

/// Root structure for manifest.json
public struct DictionaryManifest: Codable {
    public var version: Int = 1
    public var dictionaries: [DictionaryEntry] = []
    public var groups: GroupsConfig = GroupsConfig()
    
    public init(
        version: Int = 1,
        dictionaries: [DictionaryEntry] = [],
        groups: GroupsConfig = GroupsConfig()
    ) {
        self.version = version
        self.dictionaries = dictionaries
        self.groups = groups
    }
}

// MARK: - DictionaryEntry

extension DictionaryManifest {
    
    /// Metadata for a user-imported dictionary (stored in root manifest)
    public struct DictionaryEntry: Codable, Identifiable {
        /// SHA256 hash of MDX header (used as folder name and unique ID)
        public let id: String
        
        /// User-editable display name
        public var displayName: String
        
        /// Original MDX filename when imported (e.g., "MyDict.mdx")
        /// Used for duplicate detection and as display fallback
        public let originalFileName: String
        
        /// Import timestamp
        public let importedAt: Date
        
        /// Last modification timestamp (resource added/removed)
        public var updatedAt: Date
        
        /// Total size of all files in KB (for sorting: load smallest first)
        public var totalSizeKB: Int64
        
        /// Number of MDD resource files (0-N)
        /// Note: This is a quick-check count; actual loading reads dict manifest
        public var mddCount: Int
        
        /// Number of custom CSS files (0-N)
        public var cssCount: Int
        
        /// Number of custom JS files (0-N)
        public var jsCount: Int
        
        /// Number of custom font files (0-N)
        public var fontsCount: Int

        /// Cumulative lookup count (trophy — never decreases when history is deleted)
        public var lookupCount: Int

        // MARK: - CodingKeys (with legacy fallback)

        private enum CodingKeys: String, CodingKey {
            case id, displayName, originalFileName, importedAt, updatedAt, totalSizeKB
            case mddCount, cssCount, jsCount, fontsCount, lookupCount
            // Legacy keys for reading old manifests
            case mdd, css, js, fonts
        }
                 
        public init(
            id: String,
            displayName: String,
            originalFileName: String,
            importedAt: Date = Date(),
            updatedAt: Date = Date(),
            totalSizeKB: Int64 = 0,
            mddCount: Int = 0,
            cssCount: Int = 0,
            jsCount: Int = 0,
            fontsCount: Int = 0,
            lookupCount: Int = 0
        ) {
            self.id = id
            self.displayName = displayName
            self.originalFileName = originalFileName
            self.importedAt = importedAt
            self.updatedAt = updatedAt
            self.totalSizeKB = totalSizeKB
            self.mddCount = mddCount
            self.cssCount = cssCount
            self.jsCount = jsCount
            self.fontsCount = fontsCount
            self.lookupCount = lookupCount
        }
        
        // MARK: - Decodable (backward compatible)
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decode(String.self, forKey: .displayName)
            originalFileName = try container.decode(String.self, forKey: .originalFileName)
            importedAt = try container.decode(Date.self, forKey: .importedAt)
            
            // New fields with defaults for backward compatibility
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? importedAt
            totalSizeKB = try container.decodeIfPresent(Int64.self, forKey: .totalSizeKB) ?? 0

            // Try new keys first, fallback to legacy keys
            mddCount = try container.decodeIfPresent(Int.self, forKey: .mddCount)
                       ?? container.decodeIfPresent(Int.self, forKey: .mdd)
                       ?? 0
            cssCount = try container.decodeIfPresent(Int.self, forKey: .cssCount)
                       ?? container.decodeIfPresent(Int.self, forKey: .css)
                       ?? 0
            jsCount = try container.decodeIfPresent(Int.self, forKey: .jsCount)
                       ?? container.decodeIfPresent(Int.self, forKey: .js)
                       ?? 0
            fontsCount = try container.decodeIfPresent(Int.self, forKey: .fontsCount)
                         ?? container.decodeIfPresent(Int.self, forKey: .fonts)
                         ?? 0
            lookupCount = try container.decodeIfPresent(Int.self, forKey: .lookupCount) ?? 0
        }

        // MARK: - Encodable (always use new keys)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(id, forKey: .id)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(originalFileName, forKey: .originalFileName)
            try container.encode(importedAt, forKey: .importedAt)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encode(totalSizeKB, forKey: .totalSizeKB)
            try container.encode(mddCount, forKey: .mddCount)
            try container.encode(cssCount, forKey: .cssCount)
            try container.encode(jsCount, forKey: .jsCount)
            try container.encode(fontsCount, forKey: .fontsCount)
            try container.encode(lookupCount, forKey: .lookupCount)
        }
    }
}

// MARK: - GroupsConfig

extension DictionaryManifest {
    
    /// Configuration for dictionary groups
    public struct GroupsConfig: Codable {
        /// Ordered list of dictionary IDs for the default "All Dictionaries" group
        /// Format: SHA256 hash string
        public var defaultOrder: [String] = []
        
        /// User-created groups
        public var userGroups: [UserGroup] = []
        
        public init(
            defaultOrder: [String] = [],
            userGroups: [UserGroup] = []
        ) {
            self.defaultOrder = defaultOrder
            self.userGroups = userGroups
        }
    }
    
    /// A user-created dictionary group
    public struct UserGroup: Codable, Identifiable {
        /// UUID for this group
        public let id: String
        
        /// Display name
        public var name: String
        
        /// Creation timestamp
        public let createdAt: Date
        
        /// Last modification timestamp
        public var modifiedAt: Date
        
        /// Ordered list of dictionary IDs in this group
        public var dictionaryIds: [String]
        
        public init(
            id: String = UUID().uuidString,
            name: String,
            createdAt: Date = Date(),
            modifiedAt: Date = Date(),
            dictionaryIds: [String] = []
        ) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
            self.dictionaryIds = dictionaryIds
        }
    }
}

// MARK: - Query Helpers

extension DictionaryManifest {
    
    /// Find a dictionary entry by ID
    public func dictionary(id: String) -> DictionaryEntry? {
        dictionaries.first { $0.id == id }
    }
    
    /// Find a dictionary entry by original filename
    public func dictionary(originalFileName: String) -> DictionaryEntry? {
        dictionaries.first { $0.originalFileName == originalFileName }
    }
    
    /// Find a user group by ID
    public func userGroup(id: String) -> UserGroup? {
        groups.userGroups.first { $0.id == id }
    }
    
    /// Check if a dictionary with this original filename is already imported
    public func isAlreadyImported(originalFileName: String) -> Bool {
        dictionary(originalFileName: originalFileName) != nil
    }
}

// MARK: - Mutation Helpers

extension DictionaryManifest {
    
    /// Add a new dictionary entry
    public mutating func addDictionary(_ entry: DictionaryEntry) {
        guard !dictionaries.contains(where: { $0.id == entry.id }) else {
            print("⚠️ Dictionary \(entry.id.prefix(16))... already in manifest")
            return
        }
        
        dictionaries.append(entry)
        
        if !groups.defaultOrder.contains(entry.id) {
            groups.defaultOrder.append(entry.id)
        }
    }
    
    /// Remove a dictionary entry by ID
    public mutating func removeDictionary(id: String) {
        dictionaries.removeAll { $0.id == id }
        groups.defaultOrder.removeAll { $0 == id }
        for i in groups.userGroups.indices {
            groups.userGroups[i].dictionaryIds.removeAll { $0 == id }
            groups.userGroups[i].modifiedAt = Date()
        }
    }
    
    /// Update a dictionary entry
    public mutating func updateDictionary(_ entry: DictionaryEntry) {
        if let index = dictionaries.firstIndex(where: { $0.id == entry.id }) {
            dictionaries[index] = entry
        }
    }
    
    /// Update only the display name for a dictionary
    public mutating func updateDisplayName(id: String, newName: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].displayName = newName
        }
    }
    
    /// Add a new user group
    public mutating func addUserGroup(_ group: UserGroup) {
        groups.userGroups.append(group)
    }
    
    /// Remove a user group by ID
    public mutating func removeUserGroup(id: String) {
        groups.userGroups.removeAll { $0.id == id }
    }
    
    /// Update a user group
    public mutating func updateUserGroup(_ group: UserGroup) {
        if let index = groups.userGroups.firstIndex(where: { $0.id == group.id }) {
            var updated = group
            updated.modifiedAt = Date()
            groups.userGroups[index] = updated
        }
    }

    // MARK: - Resource Count Helpers

    /// Increment MDD count for a dictionary
    public mutating func incrementMDDCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].mddCount += 1
        }
    }

    /// Decrement MDD count for a dictionary
    public mutating func decrementMDDCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].mddCount = max(0, dictionaries[index].mddCount - 1)
        }
    }

    /// Increment CSS count for a dictionary
    public mutating func incrementCSSCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].cssCount += 1
        }
    }

    /// Decrement CSS count for a dictionary
    public mutating func decrementCSSCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].cssCount = max(0, dictionaries[index].cssCount - 1)
        }
    }

    /// Increment JS count for a dictionary
    public mutating func incrementJSCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].jsCount += 1
        }
    }

    /// Decrement JS count for a dictionary
    public mutating func decrementJSCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].jsCount = max(0, dictionaries[index].jsCount - 1)
        }
    }

    /// Increment fonts count for a dictionary
    public mutating func incrementFontsCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].fontsCount += 1
        }
    }

    /// Decrement fonts count for a dictionary
    public mutating func decrementFontsCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].fontsCount = max(0, dictionaries[index].fontsCount - 1)
        }
    }
    
    /// Update updatedAt timestamp for a dictionary
    public mutating func touchUpdatedAt(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].updatedAt = Date()
        }
    }
    
    /// Update totalSizeKB for a dictionary
    public mutating func updateTotalSize(id: String, sizeKB: Int64) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].totalSizeKB = sizeKB
        }
    }

    /// Increment lookup count for a dictionary (trophy — monotonically increasing)
    public mutating func incrementLookupCount(id: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].lookupCount += 1
        }
    }

    /// Get lookup count for a dictionary
    public func lookupCount(id: String) -> Int {
        dictionaries.first(where: { $0.id == id })?.lookupCount ?? 0
    }

    /// Get total lookup count across multiple dictionaries
    public func lookupCount(ids: [String]) -> Int {
        let idSet = Set(ids)
        return dictionaries
            .filter { idSet.contains($0.id) }
            .reduce(0) { $0 + $1.lookupCount }
    }
}

// MARK: - DictManifest (Per-dictionary detailed manifest)

/// Detailed resource manifest for a single dictionary.
/// Stored in `<dict-id>/manifest.json` within Library/Dictionaries/
public struct DictManifest: Codable {
    /// Dictionary ID (same as folder name, MDX header SHA256)
    public let id: String
    
    /// MDX file entry (exactly one)
    public let mdx: MDXEntry
    
    /// MDD resource files (0-N)
    public var mdd: [ResourceEntry]
    
    /// Custom CSS files (0-N)
    public var css: [ResourceEntry]
    
    /// Custom JS files (0-N)
    public var js: [ResourceEntry]
    
    public init(
        id: String,
        mdx: MDXEntry,
        mdd: [ResourceEntry] = [],
        css: [ResourceEntry] = [],
        js: [ResourceEntry] = []
    ) {
        self.id = id
        self.mdx = mdx
        self.mdd = mdd
        self.css = css
        self.js = js
    }
    
    /// Total size of all files in bytes
    public var totalSizeBytes: Int64 {
        mdx.sizeBytes
        + mdd.reduce(0) { $0 + $1.sizeBytes }
        + css.reduce(0) { $0 + $1.sizeBytes }
        + js.reduce(0) { $0 + $1.sizeBytes }
    }
    
    /// Total size in KB (for root manifest sync)
    public var totalSizeKB: Int64 {
        totalSizeBytes / 1024
    }
}

// MARK: - DictManifest Entries

extension DictManifest {
    
    /// MDX file entry (read-only, cannot be removed)
    public struct MDXEntry: Codable {
        /// Original filename (e.g., "MyDict.mdx")
        public let fileName: String
        
        /// File size in bytes
        public let sizeBytes: Int64
        
        /// Import timestamp
        public let importedAt: Date
        
        public init(fileName: String, sizeBytes: Int64, importedAt: Date = Date()) {
            self.fileName = fileName
            self.sizeBytes = sizeBytes
            self.importedAt = importedAt
        }
    }
    
    /// Resource file entry (MDD/CSS/JS)
    public struct ResourceEntry: Codable, Identifiable, Equatable {
        /// Unique ID within type (same as fileName)
        public var id: String { fileName }
        
        /// Original filename (e.g., "MyDict.mdd", "custom.css")
        public let fileName: String
        
        /// SHA256 hash of file content (for duplicate detection)
        public let hash: String
        
        /// File size in bytes
        public let sizeBytes: Int64
        
        /// Import timestamp
        public let importedAt: Date
        
        public init(fileName: String, hash: String, sizeBytes: Int64, importedAt: Date = Date()) {
            self.fileName = fileName
            self.hash = hash
            self.sizeBytes = sizeBytes
            self.importedAt = importedAt
        }
    }
}

// MARK: - DictManifest Query Helpers

extension DictManifest {
    
    /// Find MDD entry by filename
    public func mddEntry(fileName: String) -> ResourceEntry? {
        mdd.first { $0.fileName == fileName }
    }
    
    /// Find MDD entry by hash
    public func mddEntry(hash: String) -> ResourceEntry? {
        mdd.first { $0.hash == hash }
    }
    
    /// Find CSS entry by filename
    public func cssEntry(fileName: String) -> ResourceEntry? {
        css.first { $0.fileName == fileName }
    }
    
    /// Find CSS entry by hash
    public func cssEntry(hash: String) -> ResourceEntry? {
        css.first { $0.hash == hash }
    }
    
    /// Find JS entry by filename
    public func jsEntry(fileName: String) -> ResourceEntry? {
        js.first { $0.fileName == fileName }
    }
    
    /// Find JS entry by hash
    public func jsEntry(hash: String) -> ResourceEntry? {
        js.first { $0.hash == hash }
    }
    
    /// All MDD file paths (relative to dict directory)
    public var mddPaths: [String] {
        mdd.map { "mdd/\($0.fileName)" }
    }
    
    /// All CSS file paths (relative to dict directory)
    public var cssPaths: [String] {
        css.map { "css/\($0.fileName)" }
    }
    
    /// All JS file paths (relative to dict directory)
    public var jsPaths: [String] {
        js.map { "js/\($0.fileName)" }
    }
}

// MARK: - DictManifest Mutation Helpers

extension DictManifest {
    
    /// Add MDD entry (returns false if hash already exists)
    @discardableResult
    public mutating func addMDD(_ entry: ResourceEntry) -> Bool {
        guard mddEntry(hash: entry.hash) == nil else { return false }
        mdd.append(entry)
        return true
    }
    
    /// Remove MDD entry by filename
    @discardableResult
    public mutating func removeMDD(fileName: String) -> Bool {
        let count = mdd.count
        mdd.removeAll { $0.fileName == fileName }
        return mdd.count < count
    }
    
    /// Add CSS entry (returns false if hash already exists)
    @discardableResult
    public mutating func addCSS(_ entry: ResourceEntry) -> Bool {
        guard cssEntry(hash: entry.hash) == nil else { return false }
        css.append(entry)
        return true
    }
    
    /// Remove CSS entry by filename
    @discardableResult
    public mutating func removeCSS(fileName: String) -> Bool {
        let count = css.count
        css.removeAll { $0.fileName == fileName }
        return css.count < count
    }
    
    /// Add JS entry (returns false if hash already exists)
    @discardableResult
    public mutating func addJS(_ entry: ResourceEntry) -> Bool {
        guard jsEntry(hash: entry.hash) == nil else { return false }
        js.append(entry)
        return true
    }
    
    /// Remove JS entry by filename
    @discardableResult
    public mutating func removeJS(fileName: String) -> Bool {
        let count = js.count
        js.removeAll { $0.fileName == fileName }
        return js.count < count
    }
}
