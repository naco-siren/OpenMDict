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

// MARK: - Dictionary Source

/// Indicates where a dictionary comes from
enum DictionarySource {
    case bundled    // From app bundle (read-only)
    case imported   // User imported (in Library/Dictionaries/)
}

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
    
    /// All dictionary instances (bundled + imported)
    @Published private(set) var allDictionaries: [MDict] = []
    
    /// Track which dictionaries are bundled vs imported
    private(set) var dictionarySources: [String: DictionarySource] = [:]
    
    /// All groups (including default + user-defined)
    @Published private(set) var groups: [MDicts] = []
    
    private init() {}
    
    // MARK: - Search Session Factory
    
    /// Create a new search session for a scene
    /// Each scene should hold its own SearchSession instance
    func createSearchSession() -> SearchSession {
        SearchSession()
    }
    
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
    
    /// Check if a dictionary is bundled (read-only)
    func isBundled(_ dictId: String) -> Bool {
        dictionarySources[dictId] == .bundled
    }
    
    /// Check if a dictionary is imported (can be deleted)
    func isImported(_ dictId: String) -> Bool {
        dictionarySources[dictId] == .imported
    }
    
    /// Get all bundled dictionary IDs
    var bundledDictionaryIds: [String] {
        dictionarySources.filter { $0.value == .bundled }.map { $0.key }
    }
    
    /// Get all imported dictionary IDs
    var importedDictionaryIds: [String] {
        dictionarySources.filter { $0.value == .imported }.map { $0.key }
    }
    
    // MARK: - Setup
    
    /// Call from AppDelegate on launch
    func setup() {
        // 1. Load manifest (user dictionary metadata + group config)
        storage.loadManifest()
        
        // 2. Load bundled dictionaries
        loadBundledDictionaries()
        
        // 3. Load user-imported dictionaries
        loadUserDictionaries()
        
        // 4. Setup groups from manifest (or create defaults)
        setupGroups()
        
        // 5. Background loading
        Task {
            await loadAllMetadata()
            await loadAllDictionaries()
        }
    }
    
    // TODO: replace hardcoded dictionaries with a better system after resource management and group management is completed!
    private func loadBundledDictionaries() {
        let names = ["SampleDictF", "SampleDictA", "SampleDictE", "SampleDictB", "SampleDictC", "SampleDictD"]
        let bundledDicts: [MDict] = names.compactMap { name in
            guard let url = Bundle.main.url(
                forResource: name,
                withExtension: "mdx"
            ) else {
                print("⚠️ Dictionary not found in bundle: \(name).mdx")
                return nil
            }
            return MDict(path: url.path)
        }
        
        // Track as bundled
        for dict in bundledDicts {
            dictionarySources[dict.id] = .bundled
        }
        
        allDictionaries.append(contentsOf: bundledDicts)
        print("📚 Found \(bundledDicts.count) bundled dictionaries")
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
            // Inject properties from manifest for displayTitle fallback chain
            dict.userDisplayName = entry.displayName
            dict.originalFileName = entry.originalFileName
            
            if !mddPaths.isEmpty {
                print("📦 Loaded \(entry.displayName) with \(mddPaths.count) MDD files")
            }
            
            return dict
        }
        
        // Track as imported
        for dict in importedDicts {
            dictionarySources[dict.id] = .imported
        }
        
        allDictionaries.append(contentsOf: importedDicts)
        print("📚 Found \(importedDicts.count) user dictionaries")
    }
    
    private func setupGroups() {
        let manifest = storage.manifest
        
        // Create default group with all dictionaries
        // Use persisted order if available, otherwise all in current order
        let defaultOrder: [String]
        if !manifest.groups.defaultOrder.isEmpty {
            defaultOrder = manifest.groups.defaultOrder
        } else {
            // First time: bundled first (with bundled: prefix), then imported
            defaultOrder = bundledDictionaryIds.map { DictionaryManifest.bundledId(for: $0) }
                         + importedDictionaryIds
        }
        
        let allGroup = MDicts(
            id: "all",
            name: "All Dictionaries",
            isDefault: true,
            dictionaryIds: resolveOrderToActualIds(defaultOrder)
        )
        allGroup.populate(from: allDictionaries)
        
        groups = [allGroup]
        
        // Restore user groups from manifest
        for userGroup in manifest.groups.userGroups {
            let group = MDicts(
                id: userGroup.id,
                name: userGroup.name,
                isDefault: false,
                dictionaryIds: resolveOrderToActualIds(userGroup.dictionaryIds)
            )
            group.populate(from: allDictionaries)
            groups.append(group)
        }
        
        print("📂 Setup \(groups.count) groups")
    }
    
    /// Convert persisted IDs (with bundled: prefix) to actual MDict IDs
    private func resolveOrderToActualIds(_ persistedIds: [String]) -> [String] {
        persistedIds.compactMap { id in
            if DictionaryManifest.isBundledId(id) {
                // bundled:Thesaurus → Thesaurus (the actual MDict.id)
                return DictionaryManifest.bundledFilename(from: id)
            } else {
                // UUID for imported dictionary
                return id
            }
        }.filter { id in
            // Only include IDs that exist in allDictionaries
            allDictionaries.contains { $0.id == id }
        }
    }
    
    /// Convert actual MDict IDs to persisted format (with bundled: prefix)
    private func actualIdsToPersistedOrder(_ actualIds: [String]) -> [String] {
        actualIds.map { id in
            if isBundled(id) {
                return DictionaryManifest.bundledId(for: id)
            } else {
                return id
            }
        }
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

    /// Import a dictionary from MDX file
    /// - Parameters:
    ///   - mdxFile: Source MDX file URL
    ///   - displayName: Display name for the dictionary
    ///   - headerSHA256: SHA256 hash of MDX header (used as ID)
    /// - Returns: The new dictionary's ID
    func importDictionary(
        mdxFile: SelectedFile,
        displayName: String,
        headerSHA256: String
    ) async throws -> String {
        // 1. Copy files to storage
        let dictId = try await storage.importDictionary(
            mdxFile: mdxFile,
            displayName: displayName,
            headerSHA256: headerSHA256
        )

        // 2. Load into memory and update groups
        await refreshAfterImport(dictId)

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
    
    /// Called after importing a new dictionary
    /// - Parameter id: The new dictionary's ID
    private func refreshAfterImport(_ id: String) async {
        print("🔄 refreshAfterImport: \(id.prefix(16))...")

        // Safety check: don't add if already exists
        if allDictionaries.contains(where: { $0.id == id }) {
            print("⚠️ Dictionary already in allDictionaries, skipping")
            return
        }
        
        // 1. Create MDict instance
        guard let mdxPath = storage.mdxURL(id: id)?.path else {
            print("⚠️ MDX file not found! skipping")
            return
        }
        let newDict = MDict(path: mdxPath, id: id)
        
        // Inject properties from manifest for displayTitle fallback chain
        if let entry = storage.manifest.dictionary(id: id) {
            newDict.userDisplayName = entry.displayName
            newDict.originalFileName = entry.originalFileName
        }
        
        // 2. Track as imported
        dictionarySources[id] = .imported
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
        dictionarySources.removeValue(forKey: id)
        
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
        // Update default order
        if let defaultGroup = defaultGroup {
            storage.updateDefaultOrder(actualIdsToPersistedOrder(defaultGroup.dictionaryIds))
        }
        
        // Update user groups
        let userGroupsData = groups
            .filter { !$0.isDefault }
            .map { group in
                DictionaryManifest.UserGroup(
                    id: group.id,
                    name: group.name,
                    createdAt: Date(), // TODO: track original creation date
                    modifiedAt: Date(),
                    dictionaryIds: actualIdsToPersistedOrder(group.dictionaryIds)
                )
            }
        storage.updateUserGroups(userGroupsData)
        
        try storage.saveManifest()
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
