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
    
    /// Metadata for a user-imported dictionary
    public struct DictionaryEntry: Codable, Identifiable {
        /// SHA256 hash of MDX header (used as folder name and unique ID)
        public let id: String
        
        /// User-editable display name
        public var displayName: String
        
        /// Original filename when imported (e.g., "MyDict.mdx")
        /// Used for duplicate detection and as display fallback
        public let originalFileName: String
        
        /// Import timestamp
        public let importedAt: Date
        
        /// Number of MDD resource files (0-N)
        /// Note: This is a quick-check count; actual loading iterates directory
        public var mddCount: Int
        
        /// Number of custom CSS files (0-N)
        public var cssCount: Int
        
        /// Number of custom JS files (0-N)
        public var jsCount: Int
        
        /// Number of custom font files (0-N)
        public var fontsCount: Int
        
        // MARK: - CodingKeys (with legacy fallback)
        
        private enum CodingKeys: String, CodingKey {
            case id, displayName, originalFileName, importedAt
            case mddCount, cssCount, jsCount, fontsCount
            // Legacy keys for reading old manifests
            case mdd, css, js, fonts
        }
                 
        public init(
            id: String,
            displayName: String,
            originalFileName: String,
            importedAt: Date = Date(),
            mddCount: Int = 0,
            cssCount: Int = 0,
            jsCount: Int = 0,
            fontsCount: Int = 0
        ) {
            self.id = id
            self.displayName = displayName
            self.originalFileName = originalFileName
            self.importedAt = importedAt
            self.mddCount = mddCount
            self.cssCount = cssCount
            self.jsCount = jsCount
            self.fontsCount = fontsCount
        }
        
        // MARK: - Decodable (backward compatible)
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decode(String.self, forKey: .displayName)
            originalFileName = try container.decode(String.self, forKey: .originalFileName)
            importedAt = try container.decode(Date.self, forKey: .importedAt)

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
        }

        // MARK: - Encodable (always use new keys)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(id, forKey: .id)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(originalFileName, forKey: .originalFileName)
            try container.encode(importedAt, forKey: .importedAt)
            try container.encode(mddCount, forKey: .mddCount)
            try container.encode(cssCount, forKey: .cssCount)
            try container.encode(jsCount, forKey: .jsCount)
            try container.encode(fontsCount, forKey: .fontsCount)
        }
    }
}

// MARK: - GroupsConfig

extension DictionaryManifest {
    
    /// Configuration for dictionary groups
    public struct GroupsConfig: Codable {
        /// Ordered list of dictionary IDs for the default "All Dictionaries" group
        /// Format: "bundled:{filename}" for bundled, SHA256 hash for imported
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

// MARK: - Dictionary ID Helpers

extension DictionaryManifest {
    
    /// Prefix for bundled dictionary IDs
    public static let bundledPrefix = "bundled:"
    
    /// Create ID for a bundled dictionary
    public static func bundledId(for filename: String) -> String {
        "\(bundledPrefix)\(filename)"
    }
    
    /// Check if an ID refers to a bundled dictionary
    public static func isBundledId(_ id: String) -> Bool {
        id.hasPrefix(bundledPrefix)
    }
    
    /// Extract filename from a bundled dictionary ID
    public static func bundledFilename(from id: String) -> String? {
        guard isBundledId(id) else { return nil }
        return String(id.dropFirst(bundledPrefix.count))
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
}
