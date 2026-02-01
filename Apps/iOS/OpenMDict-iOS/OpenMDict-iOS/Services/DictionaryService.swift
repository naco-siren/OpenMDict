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
        let importedDicts: [MDict] = storage.manifest.dictionaries.compactMap { entry in
            let mdxPath = storage.mdxURL(id: entry.id).path
            guard FileManager.default.fileExists(atPath: mdxPath) else {
                print("⚠️ Imported dictionary MDX not found: \(entry.displayName)")
                return nil
            }
            return MDict(path: mdxPath)
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
                print("✅ Loaded: \(dict.metadata?.title ?? dict.id)")
            } catch {
                print("❌ Failed to load \(dict.id): \(error)")
            }
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("📚 All dictionaries loaded in \(String(format: "%.0f", elapsed))ms")
    }
    
    // MARK: - Import / Delete / Persist
    
    /// Called after importing a new dictionary
    /// - Parameter id: The new dictionary's ID
    func refreshAfterImport(_ id: String) async {
        // 1. Create MDict instance
        let mdxPath = storage.mdxURL(id: id).path
        let newDict = MDict(path: mdxPath)
        
        // 2. Track as imported
        dictionarySources[id] = .imported
        allDictionaries.append(newDict)
        
        // 3. Add to default group
        if let defaultGroup = defaultGroup {
            defaultGroup.dictionaryIds.append(id)
            defaultGroup.populate(from: allDictionaries)
        }
        
        // 4. Persist updated default order
        try? persistGroups()
        
        // 5. Load metadata + full reader
        await newDict.loadMetadata()
        
        do {
            try await newDict.load()
            print("✅ Loaded imported dictionary: \(newDict.metadata?.title ?? id)")
        } catch {
            print("❌ Failed to load imported dictionary \(id): \(error)")
        }
    }
    
    /// Called after deleting a dictionary
    /// - Parameter id: The deleted dictionary's ID
    func refreshAfterDelete(_ id: String) {
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
    
    /// Update default group order (e.g., after reordering in sidebar)
    func updateDefaultOrder(_ newOrder: [String]) {
        guard let defaultGroup = defaultGroup else { return }
        defaultGroup.dictionaryIds = newOrder
        defaultGroup.populate(from: allDictionaries)
        try? persistGroups()
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
}
