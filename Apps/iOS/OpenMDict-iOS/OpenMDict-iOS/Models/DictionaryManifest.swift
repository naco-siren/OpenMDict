//
//  DictionaryManifest.swift
//  OpenMDict-iOS
//
//  Data model for persisting user-imported dictionaries and group configurations.
//  Stored as JSON in Library/Dictionaries/manifest.json
//

import Foundation

// MARK: - DictionaryManifest

/// Root structure for manifest.json
struct DictionaryManifest: Codable {
    var version: Int = 1
    var dictionaries: [DictionaryEntry] = []
    var groups: GroupsConfig = GroupsConfig()
}

// MARK: - DictionaryEntry

extension DictionaryManifest {
    
    /// Metadata for a user-imported dictionary
    struct DictionaryEntry: Codable, Identifiable {
        /// UUID for this dictionary (used as folder name)
        let id: String
        
        /// User-editable display name
        var displayName: String
        
        /// Original filename when imported (e.g., "MyDict.mdx")
        /// Used for duplicate detection
        let originalFileName: String
        
        /// Import timestamp
        let importedAt: Date
        
        /// Number of MDD files (0-N)
        var mdd: Int
        
        /// Number of custom CSS files (0-N)
        var css: Int
        
        /// Number of custom JS files (0-N)
        var js: Int
        
        /// Number of custom font files (0-N)
        var fonts: Int
        
        // MARK: - Initialization
        
        init(
            id: String = UUID().uuidString,
            displayName: String,
            originalFileName: String,
            importedAt: Date = Date(),
            mdd: Int = 0,
            css: Int = 0,
            js: Int = 0,
            fonts: Int = 0
        ) {
            self.id = id
            self.displayName = displayName
            self.originalFileName = originalFileName
            self.importedAt = importedAt
            self.mdd = mdd
            self.css = css
            self.js = js
            self.fonts = fonts
        }
    }
}

// MARK: - GroupsConfig

extension DictionaryManifest {
    
    /// Configuration for dictionary groups
    struct GroupsConfig: Codable {
        /// Ordered list of dictionary IDs for the default "All Dictionaries" group
        /// Format: "bundled:{filename}" for bundled, UUID for imported
        var defaultOrder: [String] = []
        
        /// User-created groups
        var userGroups: [UserGroup] = []
    }
    
    /// A user-created dictionary group
    struct UserGroup: Codable, Identifiable {
        /// UUID for this group
        let id: String
        
        /// Display name
        var name: String
        
        /// Creation timestamp
        let createdAt: Date
        
        /// Last modification timestamp
        var modifiedAt: Date
        
        /// Ordered list of dictionary IDs in this group
        var dictionaryIds: [String]
        
        // MARK: - Initialization
        
        init(
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
    static let bundledPrefix = "bundled:"
    
    /// Create ID for a bundled dictionary
    static func bundledId(for filename: String) -> String {
        "\(bundledPrefix)\(filename)"
    }
    
    /// Check if an ID refers to a bundled dictionary
    static func isBundledId(_ id: String) -> Bool {
        id.hasPrefix(bundledPrefix)
    }
    
    /// Extract filename from a bundled dictionary ID
    static func bundledFilename(from id: String) -> String? {
        guard isBundledId(id) else { return nil }
        return String(id.dropFirst(bundledPrefix.count))
    }
}

// MARK: - Manifest Query Helpers

extension DictionaryManifest {
    
    /// Find a dictionary entry by ID
    func dictionary(id: String) -> DictionaryEntry? {
        dictionaries.first { $0.id == id }
    }
    
    /// Find a dictionary entry by original filename
    func dictionary(originalFileName: String) -> DictionaryEntry? {
        dictionaries.first { $0.originalFileName == originalFileName }
    }
    
    /// Find a user group by ID
    func userGroup(id: String) -> UserGroup? {
        groups.userGroups.first { $0.id == id }
    }
    
    /// Check if a dictionary with this original filename is already imported
    func isAlreadyImported(originalFileName: String) -> Bool {
        dictionary(originalFileName: originalFileName) != nil
    }
}

// MARK: - Manifest Mutation Helpers

extension DictionaryManifest {
    
    /// Add a new dictionary entry
    mutating func addDictionary(_ entry: DictionaryEntry) {
        dictionaries.append(entry)
        // Also add to default order at the end
        groups.defaultOrder.append(entry.id)
    }
    
    /// Remove a dictionary entry by ID
    mutating func removeDictionary(id: String) {
        dictionaries.removeAll { $0.id == id }
        // Also remove from all groups
        groups.defaultOrder.removeAll { $0 == id }
        for i in groups.userGroups.indices {
            groups.userGroups[i].dictionaryIds.removeAll { $0 == id }
            groups.userGroups[i].modifiedAt = Date()
        }
    }
    
    /// Update a dictionary entry
    mutating func updateDictionary(_ entry: DictionaryEntry) {
        if let index = dictionaries.firstIndex(where: { $0.id == entry.id }) {
            dictionaries[index] = entry
        }
    }
    
    /// Update only the display name for a dictionary
    mutating func updateDisplayName(id: String, newName: String) {
        if let index = dictionaries.firstIndex(where: { $0.id == id }) {
            dictionaries[index].displayName = newName
        }
    }
    
    /// Add a new user group
    mutating func addUserGroup(_ group: UserGroup) {
        groups.userGroups.append(group)
    }
    
    /// Remove a user group by ID
    mutating func removeUserGroup(id: String) {
        groups.userGroups.removeAll { $0.id == id }
    }
    
    /// Update a user group
    mutating func updateUserGroup(_ group: UserGroup) {
        if let index = groups.userGroups.firstIndex(where: { $0.id == group.id }) {
            var updated = group
            updated.modifiedAt = Date()
            groups.userGroups[index] = updated
        }
    }
}
