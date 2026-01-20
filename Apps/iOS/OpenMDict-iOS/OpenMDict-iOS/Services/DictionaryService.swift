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

// MARK: - DictionaryService

@MainActor
final class DictionaryService: ObservableObject {
    
    static let shared = DictionaryService()
    
    // MARK: - State
    
    /// All dictionary instances (loaded from Bundle)
    private(set) var allDictionaries: [MDict] = []
    
    /// All groups (including default + user-defined)
    private(set) var groups: [MDicts] = []

    // MARK: - Reactive Search Pipeline (Inputs)
    
    /// Input: search query
    private let searchQuerySubject = CurrentValueSubject<String, Never>("")
    
    /// Input: search context (group or dictionary)
    private let searchContextSubject = CurrentValueSubject<SearchContext, Never>(.none)
    
    // MARK: - Reactive Search Pipeline (Output)
    
    /// Output: search results (updated progressively)
    @Published private(set) var searchResults: [WordDisplayItem] = []
    
    /// Pipeline subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    private init() {
        setupSearchPipeline()
    }
    
    // MARK: - Reactive Pipeline Setup
    
    /// Core reactive pipeline:
    /// ```
    /// (query, context) ──► map to lookupPublisher ──► switchToLatest ──► results
    ///                                                    ↑
    ///                                    Key: auto-cancels previous search
    /// ```
    private func setupSearchPipeline() {
        Publishers.CombineLatest(
            searchQuerySubject
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .removeDuplicates(),
            searchContextSubject
                .removeDuplicates()
        )
        .map { [weak self] query, context -> AnyPublisher<[WordDisplayItem], Never> in
            guard let self = self,
                  !query.isEmpty,
                  let lookupable = context.lookupable else {
                return Just([]).eraseToAnyPublisher()
            }
            
            // Log search start
            let contextName: String
            switch context {
            case .group(let g): contextName = "group '\(g.name)'"
            case .dictionary(let d): contextName = "dict '\(d.metadata?.title ?? d.id)'"
            case .none: contextName = "none"
            }
            print("🔍 Search '\(query)' in \(contextName)")
            
            // Get lookup publisher and convert WordSearchResult → WordDisplayItem
            return lookupable.lookupPublisher(prefix: query, limit: 50)
                .map { results in
                    results.map { WordDisplayItem(from: $0) }
                }
                .eraseToAnyPublisher()
        }
        .switchToLatest()  // ⭐ Key: cancels previous search when query/context changes
        .receive(on: DispatchQueue.main)
        .sink { [weak self] results in
            self?.searchResults = results
            if !results.isEmpty {
                print("🔍 Results: \(results.count) items")
            }
        }
        .store(in: &cancellables)
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
    
    func loadAllDictionaries() async {
        for dict in allDictionaries {
            do {
                try await dict.load()
                print("✅ Loaded: \(dict.metadata?.title ?? dict.id)")
            } catch {
                print("❌ Failed to load \(dict.id): \(error)")
            }
        }
        print("📚 All dictionaries loaded")
    }
    
    // MARK: - Search API (Facade for VC)
    
    /// Update search query - triggers reactive pipeline
    func updateSearchQuery(_ query: String) {
        searchQuerySubject.send(query)
    }
    
    /// Update search context - triggers reactive pipeline
    func setSearchContext(_ context: SearchContext) {
        searchContextSubject.send(context)
    }
    
    /// Convenience: set context to group
    func setSearchContext(group: MDicts) {
        setSearchContext(.group(group))
    }
    
    /// Convenience: set context to dictionary
    func setSearchContext(dict: MDict) {
        setSearchContext(.dictionary(dict))
    }
    
    /// Clear search
    func clearSearch() {
        searchQuerySubject.send("")
    }
    
    /// Current query (for UI state)
    var currentQuery: String {
        searchQuerySubject.value
    }
    
    /// Current context (for UI state)
    var currentContext: SearchContext {
        searchContextSubject.value
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
