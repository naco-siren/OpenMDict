//
//  LookupSession.swift
//  OpenMDict-iOS
//
//  Per-scene lookup session with reactive pipeline
//

import Foundation
import Combine
import OpenMDictKit

/// Independent lookup session for each scene
/// Manages its own query, context, and results
@MainActor
final class LookupSession: ObservableObject {
    
    // MARK: - Inputs

    private let querySubject = CurrentValueSubject<String, Never>("")
    private let contextSubject = CurrentValueSubject<SearchContext, Never>(.none)
    private let volumeSubject: CurrentValueSubject<SearchResultVolume, Never>

    // MARK: - Output

    @Published private(set) var results: [WordDisplayItem] = []
    @Published private(set) var lemmaResults: [WordDisplayItem] = []
    @Published private(set) var suggestions: [String] = []

    /// Whether the full search pipeline (results → lemma → suggestions) has settled
    /// for the current query. Consumers show "Searching…" when false + query non-empty.
    @Published private(set) var isSearchSettled: Bool = true

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        let raw = UserDefaults.standard.integer(forKey: "searchResultVolume")
        let volume = SearchResultVolume(rawValue: raw) ?? .normal
        self.volumeSubject = CurrentValueSubject(volume)
        subscribeToSettingsChanges()
        setupPipeline()
        setupLemmaPipeline()
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
                .debounce(for: .milliseconds(LookupPipelineConfig.queryDebounceMs), scheduler: RunLoop.main)
                .removeDuplicates(),
            contextSubject
                .removeDuplicates(),
            volumeSubject
                .removeDuplicates()
        )
        .map { query, context, volume -> AnyPublisher<[WordSearchResult], Never> in
            // Trim whitespace so trailing spaces (e.g. "look ") still match "look"
            let searchQuery = query.trimmingCharacters(in: .whitespaces)
            guard !searchQuery.isEmpty,
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
            print("🔍 Search '\(searchQuery)' in \(contextName)")

            let limit = volume.perDictLimit

            return lookupable.lookupPublisher(prefix: searchQuery, limit: limit)
                .eraseToAnyPublisher()
        }
        .switchToLatest()
        // lookupPublisher emits on background thread. Hop to main BEFORE any
        // @MainActor code (WordDisplayItem mapping, @Published assignment).
        // No debounce needed: each lookupPublisher now emits exactly once
        // (single Future for all dicts), not N times per dictionary.
        .receive(on: DispatchQueue.main)
        .map { results in
            results.map { WordDisplayItem(from: $0) }
        }
        .sink { [weak self] results in
            self?.results = results
            // Fast path: enough direct results → lemma/suggestions will be skipped.
            if results.count >= LookupPipelineConfig.resultThreshold, self?.isSearchSettled == false {
                self?.isSearchSettled = true
            }
            if !results.isEmpty {
                print("🔍 Results: \(results.count) items")
            }
        }
        .store(in: &cancellables)
    }

    // MARK: - Lemma Resolution

    private var lemmaTask: Task<Void, Never>?

    /// Lemma resolution pipeline:
    /// - Clears stale lemma results immediately when query changes (switchMap semantics).
    /// - After direct search results settle (300ms debounce), evaluates whether
    ///   lemma resolution is needed (results < 3).
    /// - Runs layered resolution on background thread:
    ///   Layer 1: Normalize + strip stopwords → search candidates → early stop if enough
    ///   Layer 2: NLTagger + English inflection rules → search candidates → merge
    /// - All intermediate state is invisible to user (search bar shows raw query only).
    private func setupLemmaPipeline() {
        // 1) Immediate clear + cancel on query change (switchMap semantics)
        querySubject
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.lemmaTask?.cancel()
                self?.lemmaResults = []
            }
            .store(in: &cancellables)

        // 2) Evaluate after direct results settle
        $results
            .debounce(for: .milliseconds(LookupPipelineConfig.lemmaDebounceMs), scheduler: DispatchQueue.main)
            .sink { [weak self] results in
                self?.evaluateLemmaResolution(for: results)
            }
            .store(in: &cancellables)
    }

    private func evaluateLemmaResolution(for results: [WordDisplayItem]) {
        lemmaTask?.cancel()

        let query = querySubject.value
        guard results.count < LookupPipelineConfig.resultThreshold, !query.isEmpty else {
            if !query.isEmpty {
                print("🔍 Lemma: skipped (\(results.count) direct results ≥ 3)")
            }
            lemmaResults = []
            evaluateSuggestions(for: results, lemmaResults: [])
            return
        }
        print("🔍 Lemma: resolving '\(query)' (\(results.count) direct results)")

        let context = contextSubject.value
        let volume = volumeSubject.value
        let existingWords = Set(results.map { $0.word.lowercased() })

        // Capture reader+metadata tuples on MainActor — safe to pass to background
        let readerInfos: [LemmaReaderInfo]
        switch context {
        case .dictionary(let dict):
            if let reader = dict.reader {
                readerInfos = [LemmaReaderInfo(reader: reader, dictId: dict.id, dictName: dict.preferredTitle)]
            } else {
                readerInfos = []
            }
        case .group(let group):
            readerInfos = group.active.compactMap { dict in
                guard let reader = dict.reader else { return nil }
                return LemmaReaderInfo(reader: reader, dictId: dict.id, dictName: dict.preferredTitle)
            }
        case .none:
            readerInfos = []
        }

        guard !readerInfos.isEmpty else {
            lemmaResults = []
            evaluateSuggestions(for: results, lemmaResults: [])
            return
        }

        lemmaTask = Task { [weak self] in
            let items = await resolveLemmaInBackground(
                query: query,
                readerInfos: readerInfos,
                perDictLimit: volume.perDictLimit,
                existingResultCount: results.count,
                existingWords: existingWords
            )

            guard !Task.isCancelled else { return }
            self?.lemmaResults = items
            if !items.isEmpty {
                print("🔍 Lemma: found \(items.count) results")
            } else {
                print("🔍 Lemma: no results")
            }
            // Chain to suggestions (terminal stage that marks isSearchSettled)
            if let self {
                self.evaluateSuggestions(for: self.results, lemmaResults: items)
            }
        }
    }

    // MARK: - Suggestions

    private var suggestionsTask: Task<Void, Never>?

    /// Derived suggestions pipeline:
    /// - Clears stale suggestions immediately when query changes.
    /// - Triggered by `evaluateLemmaResolution` chaining to `evaluateSuggestions`
    ///   (sequential: results → lemma → suggestions), NOT by Combine subscription.
    ///   This avoids race conditions where combineLatest would fire before lemma completes.
    /// - When total results < 3 and query is non-empty, runs Levenshtein-ranked
    ///   suggestions on a background thread (`@concurrent`).
    /// - Deduplicates against both direct results and lemma results.
    /// - `evaluateSuggestions` is the terminal stage that marks `isSearchSettled = true`.
    private func setupSuggestionsPipeline() {
        // Clear stale suggestions immediately when query changes
        querySubject
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.suggestionsTask?.cancel()
                self?.suggestions = []
            }
            .store(in: &cancellables)
        // Suggestions are now triggered by evaluateLemmaResolution → evaluateSuggestions chain
    }

    /// Terminal stage of the search pipeline (results → lemma → suggestions).
    /// Marks `isSearchSettled = true` on all exit paths (sync and async).
    private func evaluateSuggestions(for results: [WordDisplayItem], lemmaResults: [WordDisplayItem]) {
        suggestionsTask?.cancel()

        let query = querySubject.value
        let totalResults = results.count + lemmaResults.count
        guard totalResults < LookupPipelineConfig.resultThreshold, !query.isEmpty else {
            if !query.isEmpty {
                print("🔍 Suggestions: skipped (\(totalResults) total results ≥ 3) → settled")
            }
            suggestions = []
            isSearchSettled = true
            return
        }
        print("🔍 Suggestions: computing for '\(query)' (\(totalResults) total results)")

        let context = contextSubject.value
        // Deduplicate against both direct results and lemma results (case-insensitive)
        let existingWords = Set(
            results.map { $0.word.lowercased() } +
            lemmaResults.map { $0.word.lowercased() }
        )

        // Capture Sendable readers on MainActor — safe to pass to background
        let readers: [MDictReader]
        switch context {
        case .dictionary(let dict): readers = [dict.reader].compactMap { $0 }
        case .group(let group):     readers = group.activeReaders
        case .none:                 readers = []
        }

        guard !readers.isEmpty else {
            suggestions = []
            isSearchSettled = true
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
            self?.isSearchSettled = true
            if !filtered.isEmpty {
                print("🔍 Suggestions: found \(filtered.count) → settled")
            } else {
                print("🔍 Suggestions: none → settled")
            }
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
        if !query.isEmpty {
            isSearchSettled = false
        }
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
        isSearchSettled = true
    }
    
    var currentQuery: String {
        querySubject.value
    }
    
    var currentContext: SearchContext {
        contextSubject.value
    }
}

// MARK: - Background Suggestions Computation

/// Compute distance-ranked suggestions on a background thread.
/// `MDictReader` is `@unchecked Sendable` with thread safety guaranteed by
/// internal NSLock guards (BinaryReader.atomicRead, ResourceProvider.cacheLock).
/// `suggestions()` operates on immutable in-memory keyword data — no I/O, no locks needed.
///
/// Each reader returns `[ScoredSuggestion]` (word + distance). This function merges
/// across readers, deduplicates (keeping min distance), and returns globally ranked results.
@concurrent
private nonisolated func computeSuggestionsInBackground(
    readers: [MDictReader],
    query: String,
    existingWords: Set<String>
) async -> [String] {
    // Collect from all readers, dedup case-insensitively keeping best (min) distance.
    var best: [String: ScoredSuggestion] = [:]  // lowercased key → best scored suggestion

    for reader in readers {
        guard !Task.isCancelled else { return [] }
        for s in reader.suggestions(for: query, limit: LookupPipelineConfig.suggestionsPerReader) {
            let key = s.word.lowercased()
            guard !existingWords.contains(key) else { continue }
            if let existing = best[key] {
                if s.distance < existing.distance { best[key] = s }
            } else {
                best[key] = s
            }
        }
    }

    guard !Task.isCancelled, !best.isEmpty else { return [] }

    // Global rank: distance ascending, alphabetical for ties.
    return best.values
        .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.word < $1.word }
        .prefix(LookupPipelineConfig.maxSuggestions)
        .map(\.word)
}

// MARK: - Lemma Reader Info

/// Reader + dictionary metadata tuple for background lemma resolution.
/// Captured on MainActor, safe to pass to `@concurrent` background tasks.
private struct LemmaReaderInfo: Sendable {
    let reader: MDictReader
    let dictId: String
    let dictName: String
}

// MARK: - Background Lemma Resolution

/// Layered lemma resolution on a background thread.
///
/// Layer 1: Normalize + strip stopwords → search candidates → early stop if enough.
/// Layer 2: NLTagger + English inflection rules → search candidates → merge.
///
/// All intermediate state is invisible to the user.
/// Checks `Task.isCancelled` between phases for switchMap cancellation.
@concurrent
private nonisolated func resolveLemmaInBackground(
    query: String,
    readerInfos: [LemmaReaderInfo],
    perDictLimit: Int,
    existingResultCount: Int,
    existingWords: Set<String>
) async -> [WordDisplayItem] {
    let threshold = LookupPipelineConfig.resultThreshold

    // Phase 1: Normalize
    let normalized = LemmaResolver.normalize(query)
    guard !normalized.isEmpty else { return [] }

    // Phase 2: Strip stopwords → candidates
    let strippedCandidates = LemmaResolver.stripStopwords(normalized)
    guard !Task.isCancelled else { return [] }

    // Search stripped candidates (these may differ from the original query)
    // Only search candidates that differ from the full normalized query.
    // Direct search matches "to fun" as a prefix; individual tokens like "fun"
    // are NOT searched directly, so they ARE new candidates worth searching.
    let newCandidates = strippedCandidates.filter { $0 != normalized }

    var allLemmaResults: [WordDisplayItem] = []
    var seenWords = existingWords  // case-insensitive dedup against direct results

    if !newCandidates.isEmpty {
        let strippedResults = searchCandidates(
            newCandidates, in: readerInfos, limit: perDictLimit, excluding: &seenWords
        )
        allLemmaResults.append(contentsOf: strippedResults)
    }

    guard !Task.isCancelled else { return [] }

    // Check if we have enough total results — early stop (避免画蛇添足)
    if existingResultCount + allLemmaResults.count >= threshold {
        return allLemmaResults
    }

    // Phase 3: Inflection resolution (NLTagger + rules, parallel)
    // Use the first stripped candidate as primary, or fall back to full normalized string
    let primaryWord = strippedCandidates.first ?? normalized

    // Run NLTagger and rule-based resolution
    let nlCandidates = LemmaResolver.nltaggerLemmas(primaryWord)
    let ruleCandidates = EnglishInflectionRules.resolve(primaryWord)

    guard !Task.isCancelled else { return [] }

    // Also resolve each stripped candidate individually if there are multiple
    var allInflectionCandidates = Set(nlCandidates + ruleCandidates)
    for candidate in strippedCandidates where candidate != primaryWord {
        guard !Task.isCancelled else { return [] }
        let nlExtra = LemmaResolver.nltaggerLemmas(candidate)
        let ruleExtra = EnglishInflectionRules.resolve(candidate)
        allInflectionCandidates.formUnion(nlExtra)
        allInflectionCandidates.formUnion(ruleExtra)
    }

    // Remove candidates we've already searched
    let alreadySearched = Set(strippedCandidates + [normalized])
    let inflectionOnly = allInflectionCandidates.filter { !alreadySearched.contains($0) }

    guard !inflectionOnly.isEmpty, !Task.isCancelled else {
        return allLemmaResults
    }

    let inflectionResults = searchCandidates(
        Array(inflectionOnly), in: readerInfos, limit: perDictLimit, excluding: &seenWords
    )
    allLemmaResults.append(contentsOf: inflectionResults)

    guard !Task.isCancelled else { return [] }
    return allLemmaResults
}

/// Search candidate words across all readers, building WordDisplayItem results.
/// Deduplicates (case-insensitive) against `seenWords` and updates it.
/// Called from within `resolveLemmaInBackground` (already on background thread).
private nonisolated func searchCandidates(
    _ candidates: [String],
    in readerInfos: [LemmaReaderInfo],
    limit: Int,
    excluding seenWords: inout Set<String>
) -> [WordDisplayItem] {
    var results: [WordDisplayItem] = []

    for candidate in candidates {
        guard !Task.isCancelled else { return [] }
        for info in readerInfos {
            guard !Task.isCancelled else { return [] }
            let matches = info.reader.search(prefix: candidate, limit: limit)
            for match in matches {
                let key = match.lowercased()
                guard !seenWords.contains(key) else { continue }
                seenWords.insert(key)
                results.append(WordDisplayItem(
                    word: match, dictId: info.dictId, dictName: info.dictName
                ))
            }
        }
    }

    return results
}

// MARK: - Search Result Volume

/// Qualitative search result volume controlling per-dictionary result limits.
/// Users see qualitative labels (A Few / Less / Default / More / A Lot) in Settings;
/// the exact numbers are an implementation detail that developers can tune freely.
///
/// `perDictLimit` is applied uniformly to every dictionary in a group query
/// or to the single dictionary in a single-dict query. This avoids the problem
/// where large groups (e.g. "All Dictionaries" with 25 dicts) would produce
/// very few results per dict after dividing a fixed total budget.
private enum SearchResultVolume: Int {
    case aFew   = 0
    case less   = 1
    case normal = 2  // default
    case more   = 3
    case aLot   = 4

    /// Maximum results requested from each dictionary.
    var perDictLimit: Int {
        switch self {
        case .aFew:   return 1
        case .less:   return 3
        case .normal: return 5
        case .more:   return 8
        case .aLot:   return 12
        }
    }
}
