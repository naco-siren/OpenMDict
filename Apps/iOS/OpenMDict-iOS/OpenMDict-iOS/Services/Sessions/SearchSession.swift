//
//  SearchSession.swift
//  OpenMDict-iOS
//
//  Per-scene search session with reactive pipeline
//

import Foundation
import Combine
import OpenMDictKit

/// Independent search session for each scene
/// Manages its own query, context, and results
@MainActor
final class SearchSession: ObservableObject {
    
    // MARK: - Inputs

    private let querySubject = CurrentValueSubject<String, Never>("")
    private let contextSubject = CurrentValueSubject<SearchContext, Never>(.none)
    private let volumeSubject: CurrentValueSubject<SearchResultVolume, Never>

    // MARK: - Output

    @Published private(set) var results: [WordDisplayItem] = []
    @Published private(set) var suggestions: [String] = []

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        let raw = UserDefaults.standard.integer(forKey: "searchResultVolume")
        let volume = SearchResultVolume(rawValue: raw) ?? .normal
        self.volumeSubject = CurrentValueSubject(volume)
        subscribeToSettingsChanges()
        setupPipeline()
        setupSuggestionsPipeline()
    }
    
    // MARK: - Reactive Pipeline
    
    /// Core reactive pipeline:
    /// ```
    /// (query, context, volume) ──► map to lookupPublisher ──► switchToLatest ──► results
    ///                                                             ↑
    ///                                             Key: auto-cancels previous search
    /// ```
    /// Volume changes (from Settings.bundle) trigger re-search automatically.
    private func setupPipeline() {
        Publishers.CombineLatest3(
            querySubject
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .removeDuplicates(),
            contextSubject
                .removeDuplicates(),
            volumeSubject
                .removeDuplicates()
        )
        .map { query, context, volume -> AnyPublisher<[WordDisplayItem], Never> in
            guard !query.isEmpty,
                  let lookupable = context.lookupable else {
                return Just([]).eraseToAnyPublisher()
            }

            // Log search start
            let contextName: String
            switch context {
            case .group(let g): contextName = "group '\(g.name)'"
            case .dictionary(let d): contextName = "dict '\(d.loggingTitle)'"
            case .none: contextName = "none"
            }
            print("🔍 Search '\(query)' in \(contextName)")

            let totalLimit = volume.totalLimit
            let limit: Int
            switch context {
            case .group(let g):
                let dictCount = max(g.items.filter(\.isEnabled).count, 1)
                limit = max(totalLimit / dictCount, 2)
            case .dictionary:
                limit = totalLimit
            case .none:
                limit = totalLimit
            }

            return lookupable.lookupPublisher(prefix: query, limit: limit)
                .map { results in
                    results.map { WordDisplayItem(from: $0) }
                }
                .eraseToAnyPublisher()
        }
        .switchToLatest()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] results in
            self?.results = results
            if !results.isEmpty {
                print("🔍 Results: \(results.count) items")
            }
        }
        .store(in: &cancellables)
    }

    // MARK: - Suggestions

    private var suggestionsTask: Task<Void, Never>?

    /// Derived suggestions pipeline:
    /// - Clears stale suggestions immediately when query changes.
    /// - After results settle (300ms debounce, avoids premature firing during
    ///   progressive group results), evaluates whether suggestions are needed.
    /// - When results < 3 and query is non-empty, runs Levenshtein-ranked
    ///   suggestions on a background thread (`@concurrent`).
    /// - Previous computation is auto-cancelled when new results arrive.
    private func setupSuggestionsPipeline() {
        // 1) Clear stale suggestions immediately when query changes
        querySubject
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.suggestionsTask?.cancel()
                self?.suggestions = []
            }
            .store(in: &cancellables)

        // 2) Evaluate after results settle
        $results
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] results in
                self?.evaluateSuggestions(for: results)
            }
            .store(in: &cancellables)
    }

    private func evaluateSuggestions(for results: [WordDisplayItem]) {
        suggestionsTask?.cancel()

        let query = querySubject.value
        guard results.count < 3, !query.isEmpty else {
            suggestions = []
            return
        }

        let context = contextSubject.value
        let existingWords = Set(results.map(\.word))

        // Capture Sendable readers on MainActor — safe to pass to background
        let readers: [MDictReader]
        switch context {
        case .dictionary(let dict): readers = [dict.reader].compactMap { $0 }
        case .group(let group):     readers = group.activeReaders
        case .none:                 readers = []
        }

        guard !readers.isEmpty else {
            suggestions = []
            return
        }

        // Run expensive Levenshtein computation off main thread.
        // MDictReader is Sendable (thread-safe via internal locks).
        suggestionsTask = Task { [weak self] in
            let filtered = await computeSuggestionsInBackground(
                readers: readers,
                query: query,
                existingWords: existingWords
            )

            guard !Task.isCancelled else { return }
            self?.suggestions = filtered
        }
    }

    /// Listen for Settings.bundle changes to searchResultVolume.
    private func subscribeToSettingsChanges() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { _ in
                SearchResultVolume(rawValue: UserDefaults.standard.integer(forKey: "searchResultVolume"))
            }
            .removeDuplicates()
            .sink { [weak self] newVolume in
                self?.volumeSubject.send(newVolume)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - API
    
    func updateQuery(_ query: String) {
        querySubject.send(query)
    }
    
    func setContext(_ context: SearchContext) {
        contextSubject.send(context)
    }
    
    func setContext(group: MDicts) {
        setContext(.group(group))
    }
    
    func setContext(dict: MDict) {
        setContext(.dictionary(dict))
    }
    
    func clearSearch() {
        querySubject.send("")
    }
    
    var currentQuery: String {
        querySubject.value
    }
    
    var currentContext: SearchContext {
        contextSubject.value
    }
}

// MARK: - Background Suggestions Computation

/// Compute Levenshtein-ranked suggestions on a background thread.
/// `MDictReader` is `@unchecked Sendable` with thread safety guaranteed by
/// internal NSLock guards (BinaryReader.atomicRead, ResourceProvider.cacheLock).
/// `suggestions()` operates on immutable in-memory keyword data — no I/O, no locks needed.
@concurrent
private nonisolated func computeSuggestionsInBackground(
    readers: [MDictReader],
    query: String,
    existingWords: Set<String>
) async -> [String] {
    var allSuggestions = Set<String>()

    for reader in readers {
        guard !Task.isCancelled else { return [] }
        let s = reader.suggestions(for: query, limit: 8)
        allSuggestions.formUnion(s)
    }

    guard !Task.isCancelled else { return [] }

    return Array(
        allSuggestions
            .filter { !existingWords.contains($0) }
            .sorted()
            .prefix(5)
    )
}

// MARK: - Search Result Volume

/// Qualitative search result volume, mapped to a total result budget at query time.
/// Users see qualitative labels (A Few / Less / Default / More / A Lot) in Settings;
/// the exact numbers are an implementation detail that developers can tune freely.
///
/// For single-dictionary queries, `totalLimit` is used directly as the per-dict limit.
/// For group queries, `totalLimit` is divided by the number of enabled dictionaries
/// to derive the per-dict limit (minimum 1), keeping the overall result count stable.
private enum SearchResultVolume: Int {
    case aFew   = 0
    case less   = 1
    case normal = 2  // default
    case more   = 3
    case aLot   = 4

    /// Total result budget. For groups, divided by dict count to get per-dict limit.
    var totalLimit: Int {
        switch self {
        case .aFew:   return 10
        case .less:   return 20
        case .normal: return 30
        case .more:   return 40
        case .aLot:   return 50
        }
    }
}
