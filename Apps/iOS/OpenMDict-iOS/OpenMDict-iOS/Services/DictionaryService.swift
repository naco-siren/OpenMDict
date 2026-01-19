//
//  DictionaryService.swift
//  OpenMDict-iOS
//
//  App-level singleton managing dictionary loading, groups, and queries
//

import Foundation
import OpenMDict
import OpenMDictKit

@MainActor
final class DictionaryService {
    
    static let shared = DictionaryService()
    
    // MARK: - State
    
    /// All dictionary instances (loaded from Bundle)
    private(set) var allDictionaries: [MDict] = []
    
    /// All groups (including default + user-defined)
    private(set) var groups: [MDicts] = []
    
    /// Loading state
    private(set) var isLoading: Bool = false
    
    // MARK: - Init
    
    private init() {}
    
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
    
    // MARK: - Setup
    
    /// Call from AppDelegate on launch
    func setup() {
        loadBundledDictionaries()
        setupDefaultGroups()
        
        Task {
            await loadAllDictionaries()
        }
    }
    
    private func loadBundledDictionaries() {
        let names = ["SampleDictF", "SampleDictA", "SampleDictE", "SampleDictB", "SampleDictC"]
        allDictionaries = names.compactMap { name in
            guard let url = Bundle.main.url(
                forResource: name,
                withExtension: "mdx"
            ) else {
                print("⚠️ Dictionary not found in bundle: \(name).mdx")
                return nil
            }
            return MDict(path: url.path)
        }
        print("📚 Found \(allDictionaries.count) bundled dictionaries")
    }
    
    private func setupDefaultGroups() {
        // Default group: all dictionaries
        let allGroup = MDicts(
            id: "all",
            name: "All Dictionaries",
            isDefault: true,
            dictionaryIds: allDictionaries.map { $0.id }
        )
        allGroup.populate(from: allDictionaries)
        
        // Example custom group
        let thesaurusGroup = MDicts(
            id: "thesaurus-only",
            name: "Thesaurus Only",
            isDefault: false,
            dictionaryIds: ["SampleDictF"]
        )
        thesaurusGroup.populate(from: allDictionaries)
        
        groups = [allGroup, thesaurusGroup]
    }
    
    // MARK: - Loading
    
    func loadAllDictionaries() async {
        isLoading = true
        
        for dict in allDictionaries {
            do {
                try await dict.load()
                print("✅ Loaded: \(dict.metadata?.title ?? dict.id)")
            } catch {
                print("❌ Failed to load \(dict.id): \(error)")
            }
        }
        
        isLoading = false
        print("📚 All dictionaries loaded")
    }
    
    // MARK: - Search API
    
    /// Search in a group (returns results from all active dictionaries)
    func search(prefix: String, in group: MDicts, limit: Int = 50) -> [WordDisplayItem] {
        var results: [WordDisplayItem] = []
        for dict in group.active {
            let words = dict.search(prefix: prefix, limit: limit)
            let items = WordDisplayItem.from(words: words, dict: dict)
            results.append(contentsOf: items)
        }
        return results
    }
    
    /// Search in a single dictionary
    func search(prefix: String, in dict: MDict, limit: Int = 50) -> [WordDisplayItem] {
        let words = dict.search(prefix: prefix, limit: limit)
        return WordDisplayItem.from(words: words, dict: dict)
    }
    
    // MARK: - Lookup API
    
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
