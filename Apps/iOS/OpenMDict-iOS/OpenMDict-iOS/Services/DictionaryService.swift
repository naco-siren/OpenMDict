//
//  DictionaryService.swift
//  OpenMDict-iOS
//
//  App-level singleton managing dictionary loading, groups, and queries.
//  Uses Combine for reactive state management with switchToLatest for query cancellation.
//
//  Data flow:
//  ```
//  searchQuery$ ─────┐
//                    ├──► CombineLatest ──► map to lookupPublisher ──► switchToLatest ──► results$
//  searchContext$ ───┘
//  ```
//

import Foundation
import Combine
import OpenMDictKit

// MARK: - Search Context

/// Current search context - group or single dictionary
enum SearchContext: Equatable {
    case group(MDicts)
    case dictionary(MDict)
    case none
    
    /// Get the Lookupable for this context
    var lookupable: (any Lookupable)? {
        switch self {
        case .group(let group): return group
        case .dictionary(let dict): return dict
        case .none: return nil
        }
    }
    
    static func == (lhs: SearchContext, rhs: SearchContext) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.group(let a), .group(let b)): return a.id == b.id
        case (.dictionary(let a), .dictionary(let b)): return a.id == b.id
        default: return false
        }
    }
}

// MARK: - SearchSession (defined in SearchSession.swift)

// SearchSession is a per-scene search handler.
// DictionaryService provides factory method to create them.
// See SearchSession.swift for implementation.

// MARK: - DictionaryService

@MainActor
final class DictionaryService: ObservableObject {
    
    static let shared = DictionaryService()
    
    // MARK: - Dependencies
    
    private let storage = DictionaryStorageService.shared
    
    // MARK: - State
    
    /// All loaded dictionary instances
    @Published private(set) var allDictionaries: [MDict] = []

    /// All groups (including default + user-defined)
    @Published private(set) var groups: [MDicts] = []
    
    private init() {}
    
    // MARK: - Search Session Factory
    
    /// Create a new search session for a scene
    /// Each scene should hold its own SearchSession instance
    func createSearchSession() -> SearchSession {
        SearchSession()
    }
    
    // MARK: - Sessions (App-wide)
    
    /// Shared import session for dictionary import workflow
    let importSession = ImportSession()
    
    /// Shared group management session for group create/edit workflow
    let groupSession = GroupManagementSession()
    
    // MARK: - Computed
    
    var defaultGroup: MDicts? {
        groups.first { $0.isDefault }
    }
    
    func group(id: String) -> MDicts? {
        groups.first { $0.id == id }
    }
    
    func dict(id: String) -> MDict? {
        allDictionaries.first { $0.id == id }
    }
    
    /// Get the import date for a dictionary (from manifest)
    func importedDate(_ dictId: String) -> Date? {
        storage.manifest.dictionaries.first(where: { $0.id == dictId })?.importedAt
    }
    
    // MARK: - Setup
    
    /// Call from AppDelegate on launch.
    /// Loads Library manifest → user dictionaries → groups → background loading.
    /// If manifest doesn't exist (fresh install), dictionaries will be empty until
    /// SetupViewController imports preset dictionaries and calls `reloadAfterSetup()`.
    func setup() {
        // 1. Load manifest (dictionary metadata + group config)
        storage.loadManifest()

        // 2. Load dictionaries from Library/Dictionaries/
        loadUserDictionaries()

        // 3. Setup groups from manifest (or create defaults)
        setupGroups()

        // 4. Background loading
        Task {
            await loadAllMetadata()
            await loadAllDictionaries()
        }
    }

    /// Called after SetupViewController finishes importing preset dictionaries.
    /// Re-loads the manifest and all dictionaries from scratch.
    /// Awaits full loading so dictionaries are ready for search immediately.
    func reloadAfterSetup() async {
        allDictionaries = []
        groups = []

        // 1. Load manifest (dictionary metadata + group config)
        storage.loadManifest()

        // 2. Load dictionaries from Library/Dictionaries/
        loadUserDictionaries()

        // 3. Setup groups from manifest (or create defaults)
        setupGroups()

        // 4. Await full loading (metadata + readers) so search works immediately
        await loadAllMetadata()
        await loadAllDictionaries()
    }
    
    private func loadUserDictionaries() {
        let importedDicts: [MDict] = storage.manifest.dictionaries.compactMap { entry -> MDict? in
            // Load dict manifest to get actual MDX filename
            guard let dictManifest = storage.loadDictManifest(id: entry.id) else {
                print("⚠️ Dict manifest not found for: \(entry.displayName) (id: \(entry.id))")
                return nil
            }

            // Use MDX filename from dict manifest
            let mdxPath = storage.mdxURL(id: entry.id, fileName: dictManifest.mdx.fileName).path
            guard FileManager.default.fileExists(atPath: mdxPath) else {
                print("⚠️ Imported dictionary MDX not found: \(entry.displayName) at \(mdxPath)")

                return nil
            }
            
            // Build MDD paths from dict manifest
            let mddDir = storage.mddDirectoryURL(id: entry.id)
            let mddPaths: [String] = dictManifest.mdd.map { mddEntry in
                mddDir.appendingPathComponent(mddEntry.fileName).path
            }
            
            // Use manifest's entry.id (SHA256) as the MDict id
            let dict = MDict(path: mdxPath, id: entry.id, mddPaths: mddPaths)
            // Inject user display name from manifest
            dict.userDisplayName = entry.displayName
            
            if !mddPaths.isEmpty {
                print("📦 Loaded \(entry.displayName) with \(mddPaths.count) MDD files")
            }
            
            return dict
        }
        
        allDictionaries.append(contentsOf: importedDicts)
        print("📚 Found \(importedDicts.count) dictionaries in Library")
    }
    
    private func setupGroups() {
        let manifest = storage.manifest

        // Create default group with all dictionaries
        // Use persisted order if available, otherwise all in current order
        let defaultOrder: [String]
        if !manifest.groups.defaultOrder.isEmpty {
            defaultOrder = manifest.groups.defaultOrder
        } else {
            // First time: use order from manifest dictionaries array
            defaultOrder = allDictionaries.map { $0.id }
        }

        // Filter to only IDs that exist in allDictionaries
        let validOrder = defaultOrder.filter { id in
            allDictionaries.contains { $0.id == id }
        }

        let allGroup = MDicts(
            id: "all",
            name: L10n.GroupInfo.allDictionaries,
            isDefault: true,
            dictionaryIds: validOrder
        )
        allGroup.populate(from: allDictionaries)

        groups = [allGroup]

        // Restore user groups from manifest
        for userGroup in manifest.groups.userGroups {
            let validGroupOrder = userGroup.dictionaryIds.filter { id in
                allDictionaries.contains { $0.id == id }
            }
            let group = MDicts(
                id: userGroup.id,
                name: userGroup.name,
                isDefault: false,
                dictionaryIds: validGroupOrder,
                createdAt: userGroup.createdAt,
                modifiedAt: userGroup.modifiedAt
            )
            group.populate(from: allDictionaries)
            groups.append(group)
        }

        print("📂 Setup \(groups.count) groups")
    }
    
    // MARK: - Loading
    /// Load only metadata for all dictionaries (fast, parallel)
    /// After this, sidebar can display dictionary names
    func loadAllMetadata() async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await withTaskGroup(of: Void.self) { group in
            for dict in allDictionaries {
                group.addTask {
                    await dict.loadMetadata()
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("📖 All metadata loaded in \(String(format: "%.0f", elapsed))ms")
    }

    /// Load full reader for all dictionaries (slow, sequential)
    /// MDict.$state changes will notify subscribers directly
    func loadAllDictionaries() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for dict in allDictionaries {
            do {
                try await dict.load()
                print("✅ Loaded: \(dict.loggingTitle)")
            } catch {
                print("❌ Failed to load \(dict.id): \(error)")
            }
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("📚 All dictionaries loaded in \(String(format: "%.0f", elapsed))ms")
    }
    
    // MARK: - Import / Delete / Persist

    /// Check if a dictionary with this header SHA256 is already imported
    func isDuplicateImport(headerSHA256: String) -> Bool {
        storage.isDuplicateImport(headerSHA256: headerSHA256)
    }

    /// Import a dictionary using data from the current ImportSession.
    /// The session must have an MDX file set. Resource files (MDD/CSS/JS) are read from the session.
    /// - Parameter displayName: Display name for the dictionary
    /// - Returns: The new dictionary's ID
    func importDictionary(displayName: String) async throws -> String {
        guard let mdxPendingFile = importSession.mdxPendingFile,
              let headerSHA256 = importSession.mdxMetadata?.headerSHA256 else {
            throw NSError(domain: "DictionaryService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No MDX file selected in ImportSession"])
        }
        
        let mdxFile = SelectedFile(url: mdxPendingFile.url)
        let mddFiles = importSession.pendingMDDFiles.map { SelectedFile(url: $0.url) }
        let cssFiles = importSession.pendingCSSFiles.map { SelectedFile(url: $0.url) }
        let jsFiles = importSession.pendingJSFiles.map { SelectedFile(url: $0.url) }
        
        // 1. Copy files to storage
        let dictId = try await storage.importDictionary(
            mdxFile: mdxFile,
            mddFiles: mddFiles,
            cssFiles: cssFiles,
            jsFiles: jsFiles,
            displayName: displayName,
            headerSHA256: headerSHA256
        )

        // 2. Load into memory and update groups
        await refreshAfterImport(dictId)
        
        // 3. Reset import session
        importSession.reset()

        return dictId
    }

    /// Delete a dictionary
    /// - Parameter dictId: Dictionary ID to delete
    func deleteDictionary(dictId: String) throws {
        // 1. Remove from storage
        try storage.deleteDictionary(id: dictId)

        // 2. Remove from memory and update groups
        refreshAfterDelete(dictId)
    }
    
    /// Update display name for a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - newName: New display name
    func updateDisplayName(dictId: String, newName: String) throws {
        // 1. Update in-memory MDict instance
        guard let dict = dict(id: dictId) else {
            throw NSError(domain: "DictionaryService", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Dictionary not found: \(dictId)"])
        }
        dict.userDisplayName = newName

        // 2. Persist to storage
        try storage.updateDisplayName(id: dictId, newName: newName)
    }
    
    /// Update default group order (e.g., after reordering in sidebar)
    func updateDefaultOrder(_ newOrder: [String]) {
        guard let defaultGroup = defaultGroup else { return }
        defaultGroup.dictionaryIds = newOrder
        defaultGroup.populate(from: allDictionaries)
        try? persistGroups()
    }
    
    // MARK: - Internal Refresh (called by methods above)
    
    /// Load a newly imported dictionary into memory and add it to groups.
    /// Called after importing a new dictionary (either from ImportSession or PresetDictionaryService).
    /// - Parameter id: The new dictionary's ID (SHA256 hash)
    func refreshAfterImport(_ id: String) async {
        print("🔄 refreshAfterImport: \(id.prefix(16))...")

        // Safety check: don't add if already exists
        if allDictionaries.contains(where: { $0.id == id }) {
            print("⚠️ Dictionary already in allDictionaries, skipping")
            return
        }
        
        // 1. Create MDict instance with MDD paths from dict manifest
        guard let mdxPath = storage.mdxURL(id: id)?.path else {
            print("⚠️ MDX file not found! skipping")
            return
        }
        
        // Build MDD paths from dict manifest (same as loadImportedDictionaries)
        var mddPaths: [String] = []
        if let dictManifest = storage.loadDictManifest(id: id) {
            let mddDir = storage.mddDirectoryURL(id: id)
            mddPaths = dictManifest.mdd.map { mddEntry in
                mddDir.appendingPathComponent(mddEntry.fileName).path
            }
            if !mddPaths.isEmpty {
                print("📦 refreshAfterImport: found \(mddPaths.count) MDD files")
            }
        }
        
        let newDict = MDict(path: mdxPath, id: id, mddPaths: mddPaths)
        
        // Inject user display name from manifest
        if let entry = storage.manifest.dictionary(id: id) {
            newDict.userDisplayName = entry.displayName
        }
        
        // 2. Add to dictionary list
        allDictionaries.append(newDict)
        print("📚 allDictionaries count: \(allDictionaries.count)")
        
        // 3. Add to default group
        if let defaultGroup = defaultGroup {
            // Check before append to prevent duplicates
            if !defaultGroup.dictionaryIds.contains(id) {
                defaultGroup.dictionaryIds.append(id)
                print("✅ Added to dictionaryIds, count: \(defaultGroup.dictionaryIds.count)")
            } else {
                print("⚠️ ID already in dictionaryIds, skipping")
            }
            defaultGroup.populate(from: allDictionaries)
            print("📋 defaultGroup.items count: \(defaultGroup.items.count)")
        }
        
        // 4. Persist updated default order
        try? persistGroups()
        
        // 5. Load metadata + full reader
        await newDict.loadMetadata()
        
        do {
            try await newDict.load()
            // Debug: show raw title vs resolved title
            if let meta = newDict.metadata {
                print("✅ Loaded imported dictionary:")
                print("  id: \(id.prefix(16))...")
                print("  loggingTitle: \(newDict.loggingTitle)")
                print("  description prefix: \(meta.description.prefix(100))...")
            }
        } catch {
            print("❌ Failed to load imported dictionary \(id): \(error)")
        }
    }
    
    /// Called after deleting a dictionary
    /// - Parameter id: The deleted dictionary's ID
    private func refreshAfterDelete(_ id: String) {
        // 1. Remove from allDictionaries
        allDictionaries.removeAll { $0.id == id }
        
        // 2. Remove from all groups
        for group in groups {
            group.dictionaryIds.removeAll { $0 == id }
            group.populate(from: allDictionaries)
        }
        
        // 3. Persist updated groups
        try? persistGroups()
        
        print("🗑️ Removed dictionary from service: \(id)")
    }
    
    /// Persist current group configuration to manifest
    func persistGroups() throws {
        // Update default order (IDs are SHA256 hashes, no prefix conversion needed)
        if let defaultGroup = defaultGroup {
            storage.updateDefaultOrder(defaultGroup.dictionaryIds)
        }

        // Update user groups
        let userGroupsData = groups
            .filter { !$0.isDefault }
            .map { group in
                DictionaryManifest.UserGroup(
                    id: group.id,
                    name: group.name,
                    createdAt: group.createdAt ?? Date(),
                    modifiedAt: group.modifiedAt ?? Date(),
                    dictionaryIds: group.dictionaryIds
                )
            }
        storage.updateUserGroups(userGroupsData)

        try storage.saveManifest()
    }
    
    // MARK: - Group CRUD
    
    /// Create a new user group
    /// - Parameter name: Display name for the group (auto-deduplicated if conflict)
    /// - Returns: The new MDicts group instance (already added to `groups` and persisted)
    @discardableResult
    func createGroup(name: String = L10n.GroupInfo.newGroup) throws -> MDicts {
        let finalName = uniqueGroupName(from: name)
        
        let now = Date()
        let group = MDicts(
            id: UUID().uuidString,
            name: finalName,
            isDefault: false,
            dictionaryIds: [],
            createdAt: now,
            modifiedAt: now
        )
        groups.append(group)
        
        try persistGroups()
        
        print("➕ Created group: \(finalName) (\(group.id.prefix(8))...)")
        return group
    }
    
    /// Rename a user group
    /// - Throws: `GroupNameConflictError` if another group already has this name
    func renameGroup(id: String, newName: String) throws {
        guard let group = groups.first(where: { $0.id == id && !$0.isDefault }) else {
            print("⚠️ User group not found: \(id)")
            return
        }
        
        // Check for name conflict (excluding self)
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if groups.contains(where: { $0.id != id && !$0.isDefault && $0.name == trimmedName }) {
            throw GroupNameConflictError(name: trimmedName)
        }
        
        group.name = trimmedName
        group.modifiedAt = Date()
        
        try persistGroups()
        print("✏️ Renamed group \(id.prefix(8))... to: \(trimmedName)")
    }
    
    /// Error thrown when a group name already exists
    struct GroupNameConflictError: LocalizedError {
        let name: String
        var errorDescription: String? {
            "A group named \"\(name)\" already exists."
        }
    }
    
    /// Generate a unique group name by appending a suffix if needed
    /// Internal (not private) so GroupManagementSession can use it
    func uniqueGroupName(from baseName: String) -> String {
        let existingNames = Set(groups.filter { !$0.isDefault }.map { $0.name })
        
        if !existingNames.contains(baseName) {
            return baseName
        }
        
        // Append " 2", " 3", etc.
        var counter = 2
        while existingNames.contains("\(baseName) \(counter)") {
            counter += 1
        }
        return "\(baseName) \(counter)"
    }
    
    /// Delete a user group (does NOT delete dictionaries)
    func deleteGroup(id: String) throws {
        groups.removeAll { $0.id == id && !$0.isDefault }
        
        // Persist all groups (will sync to manifest, removing the deleted group)
        try persistGroups()
        
        print("🗑️ Deleted group: \(id.prefix(8))...")
    }
    
    /// Reorder user groups (default group is excluded from reordering).
    /// `newOrder` contains user group IDs in the desired order.
    func reorderUserGroups(newOrder: [String]) throws {
        let defaultGroups = groups.filter { $0.isDefault }
        let reordered = newOrder.compactMap { id in groups.first { $0.id == id } }
        
        // Default group(s) first, then reordered user groups
        groups = defaultGroups + reordered
        
        try persistGroups()
        print("🔄 Reordered \(newOrder.count) user groups")
    }
    
    /// Add a dictionary to a user group
    func addDictionaryToGroup(groupId: String, dictId: String) throws {
        guard let group = groups.first(where: { $0.id == groupId && !$0.isDefault }) else {
            print("⚠️ User group not found: \(groupId)")
            return
        }
        guard !group.dictionaryIds.contains(dictId) else {
            print("⚠️ Dictionary \(dictId.prefix(8))... already in group")
            return
        }
        
        group.dictionaryIds.append(dictId)
        group.populate(from: allDictionaries)
        group.modifiedAt = Date()
        
        try persistGroups()
        print("➕ Added dict \(dictId.prefix(8))... to group \(groupId.prefix(8))...")
    }
    
    /// Remove a dictionary from a user group (does NOT delete dictionary)
    func removeDictionaryFromGroup(groupId: String, dictId: String) throws {
        guard let group = groups.first(where: { $0.id == groupId && !$0.isDefault }) else {
            print("⚠️ User group not found: \(groupId)")
            return
        }
        
        group.dictionaryIds.removeAll { $0 == dictId }
        group.populate(from: allDictionaries)
        group.modifiedAt = Date()
        
        try persistGroups()
        print("➖ Removed dict \(dictId.prefix(8))... from group \(groupId.prefix(8))...")
    }
    
    /// Reorder dictionaries within a user group
    func reorderDictionariesInGroup(groupId: String, newOrder: [String]) throws {
        guard let group = groups.first(where: { $0.id == groupId }) else {
            print("⚠️ Group not found: \(groupId)")
            return
        }
        
        group.dictionaryIds = newOrder
        group.populate(from: allDictionaries)
        group.modifiedAt = Date()
        
        try persistGroups()
        print("🔄 Reordered \(newOrder.count) dicts in group \(groupId.prefix(8))...")
    }
    
    // MARK: - Lookup API (for article display)
    
    /// Lookup in a group (returns AsyncStream for progressive results)
    func lookup(_ word: String, in group: MDicts) -> AsyncStream<ArticleDisplayItem> {
        AsyncStream { continuation in
            Task {
                for await result in group.lookup(word) {
                    continuation.yield(ArticleDisplayItem(from: result))
                }
                continuation.finish()
            }
        }
    }
    
    /// Lookup in a single dictionary
    func lookup(_ word: String, in dict: MDict) -> ArticleDisplayItem? {
        guard let entry = dict.lookup(word) else { return nil }
        return ArticleDisplayItem(from: entry, dict: dict)
    }
    
    // MARK: - Resource Management (Public API)
    
    /// Get all resources for a dictionary (MDX + MDD + CSS + JS)
    /// - Parameter dictId: Dictionary ID
    /// - Returns: List of ResourceFile for UI display
    func resources(for dictId: String) -> [ResourceFile] {
        storage.allResources(for: dictId)
    }

    /// Add an MDD file to a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileURL: Source file URL (from UIDocumentPicker)
    /// - Returns: fileName of the added file
    func addMDD(to dictId: String, from fileURL: URL) async throws -> String {
        let fileName = try await storage.addMDDResource(dictId: dictId, sourceURL: fileURL)
        // Reload MDD resources in MDict instance
        reloadMDDResources(for: dictId)
        return fileName
    }

    /// Remove an MDD file from a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileName: File name to remove
    func removeMDD(from dictId: String, fileName: String) throws {
        try storage.removeMDDResource(dictId: dictId, fileName: fileName)
        // Reload MDD resources in MDict instance
        reloadMDDResources(for: dictId)
    }
    
    /// Reload MDD resources for a dictionary after add/remove
    private func reloadMDDResources(for dictId: String) {
        guard let dict = dict(id: dictId) else { return }
        let mddPaths = storage.listMDDFiles(for: dictId).map { $0.path }
        dict.reloadResources(mddPaths: mddPaths)
    }

    /// Add a CSS file to a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileURL: Source file URL (from UIDocumentPicker)
    /// - Returns: fileName of the added file
    func addCSS(to dictId: String, from fileURL: URL) async throws -> String {
        let fileName = try await storage.addCSSResource(dictId: dictId, sourceURL: fileURL)
        return fileName
    }

    /// Remove a CSS file from a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileName: File name to remove
    func removeCSS(from dictId: String, fileName: String) throws {
        try storage.removeCSSResource(dictId: dictId, fileName: fileName)
    }

    /// Add a JS file to a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileURL: Source file URL (from UIDocumentPicker)
    /// - Returns: fileName of the added file
    func addJS(to dictId: String, from fileURL: URL) async throws -> String {
        let fileName = try await storage.addJSResource(dictId: dictId, sourceURL: fileURL)
        return fileName
    }

    /// Remove a JS file from a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileName: File name to remove
    func removeJS(from dictId: String, fileName: String) throws {
        try storage.removeJSResource(dictId: dictId, fileName: fileName)
    }
}
