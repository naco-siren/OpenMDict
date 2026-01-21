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
    
    // MARK: - State
    
    /// All dictionary instances (loaded from Bundle)
    private(set) var allDictionaries: [MDict] = []
    
    /// All groups (including default + user-defined)
    private(set) var groups: [MDicts] = []
    
    // MARK: - Dictionary Load Events
    
    /// Emits when a dictionary finishes loading (for UI to refresh pending articles)
    let onDictionaryLoaded = PassthroughSubject<MDict, Never>()
    
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
    
    // MARK: - Setup
    
    /// Call from AppDelegate on launch
    func setup() {
        loadBundledDictionaries()
        setupDefaultGroups()
        
        Task {
            await loadAllMetadata()
            
            await loadAllDictionaries()
        }
    }
    
    private func loadBundledDictionaries() {
        let names = ["SampleDictF", "SampleDictA", "SampleDictE", "SampleDictB", "SampleDictC", "SampleDictD"]
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
    /// After each dict loads, emits onDictionaryLoaded for UI refresh
    func loadAllDictionaries() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for dict in allDictionaries {
            do {
                try await dict.load()
                print("✅ Loaded: \(dict.metadata?.title ?? dict.id)")
                onDictionaryLoaded.send(dict)
            } catch {
                print("❌ Failed to load \(dict.id): \(error)")
            }
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("📚 All dictionaries loaded in \(String(format: "%.0f", elapsed))ms")
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
