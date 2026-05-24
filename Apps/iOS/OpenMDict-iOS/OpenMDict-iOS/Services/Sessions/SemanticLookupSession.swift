//
//  SemanticLookupSession.swift
//  OpenMDict-iOS
//
//  M15 Phase 1, Step 1.3 — drop-in alternate session driving the search
//  bar's `语义` scope. Conforms to LookupSessionProtocol so
//  WordListViewController can swap between this and the spelling-scope
//  SpellingLookupSession by switching `searchSession`.
//
//  Behavioral differences vs. SpellingLookupSession:
//
//    - `results` is populated by SemanticSearchService.relatedKeywords,
//      not by MDict prefix lookup.
//    - `lemmaResults` is always empty — semantic neighbors already collapse
//      morphological variants via the service's lemma dedup, no separate
//      "related forms" section to surface.
//    - `suggestions` is populated only when the semantic compute returns
//      weak results (few matches or low top similarity). The Levenshtein
//      fuzzy logic from the spelling scope is invoked as a typo fallback —
//      a query that doesn't land near anything semantically is more often
//      a misspelling than an exotic word. WordListVC then renders these
//      under the same `.spellingSuggestions` section the user already sees
//      in the spelling scope.
//    - The pipeline is naturally slower (~100–500ms per cross-group query
//      depending on dict count + cache state). isSearchSettled handles the
//      "Searching…" UI state the same way SpellingLookupSession does.
//
//  For now this file duplicates a fair amount of
//  SpellingLookupSession scaffolding (pipeline setup, context handling, settings
//  subscription). The shared parts can be factored out once the feature
//  validates end-to-end.
//

import Foundation
import Combine
import OpenMDict
import OpenMDictKit

/// Lookup session for the `语义` scope. Drives the same publisher surface as
/// SpellingLookupSession but powered by NLEmbedding cosine similarity rather than
/// MDict prefix/lemma/fuzzy matching.
@MainActor
final class SemanticLookupSession: ObservableObject, LookupSessionProtocol {

    // MARK: - Inputs

    private let querySubject = CurrentValueSubject<String, Never>("")
    private let contextSubject = CurrentValueSubject<SearchContext, Never>(.none)
    private let tierSubject: CurrentValueSubject<RelatedWordsTier, Never>

    // MARK: - Outputs

    @Published private(set) var results: [WordDisplayItem] = []
    /// Always empty for semantic — included to satisfy LookupSessionProtocol.
    @Published private(set) var lemmaResults: [WordDisplayItem] = []
    /// Populated only when the semantic compute returns weak results
    /// (see `spellingFallbackCountThreshold` / `spellingFallbackSimThreshold`
    /// below) — typo-shaped queries get Levenshtein-distance fuzzy
    /// suggestions surfaced alongside whatever weak semantic matches
    /// we did find.
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var isSearchSettled: Bool = true

    // MARK: - Protocol Publisher Accessors

    var resultsPublisher: AnyPublisher<[WordDisplayItem], Never> { $results.eraseToAnyPublisher() }
    var lemmaResultsPublisher: AnyPublisher<[WordDisplayItem], Never> { $lemmaResults.eraseToAnyPublisher() }
    var suggestionsPublisher: AnyPublisher<[String], Never> { $suggestions.eraseToAnyPublisher() }
    var isSearchSettledPublisher: AnyPublisher<Bool, Never> { $isSearchSettled.eraseToAnyPublisher() }

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        self.tierSubject = CurrentValueSubject(RelatedWordsTier.current)
        subscribeToSettingsChanges()
        setupPipeline()
    }

    // MARK: - Reactive Pipeline

    /// Mirrors SpellingLookupSession's CombineLatest3 pattern:
    /// ```
    /// (query, context, tier) ──► map to async semantic compute ──► results
    /// ```
    /// Each emission cancels the previous in-flight Task — semantic compute
    /// is too expensive to run multiple overlapping queries.
    private func setupPipeline() {
        Publishers.CombineLatest3(
            querySubject
                .debounce(for: .milliseconds(LookupPipelineConfig.queryDebounceMs), scheduler: RunLoop.main)
                .removeDuplicates(),
            contextSubject
                .removeDuplicates(),
            tierSubject
                .removeDuplicates()
        )
        .sink { [weak self] query, context, tier in
            self?.runSearch(query: query, context: context, tier: tier)
        }
        .store(in: &cancellables)
    }

    /// Trigger a single semantic search. Cancels any in-flight previous one.
    ///
    /// Important: this method is entered AFTER the debounce gate, so by the
    /// time we're here the user has paused typing and a new query is about
    /// to be submitted to the heavy semantic pipeline. We aggressively clear
    /// prior `results` / `suggestions` right at the top so WordListVC's
    /// empty-state logic flips to the loading spinner immediately, instead
    /// of leaving the stale previous-query rows on screen for the multi-
    /// hundred-millisecond (or multi-second on first preload) compute window.
    /// The spelling pipeline is fast enough that this aggressive clear isn't
    /// needed there — only semantic.
    private func runSearch(query: String, context: SearchContext, tier: RelatedWordsTier) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            suggestions = []
            isSearchSettled = true
            return
        }

        // Resolve readers + display metadata on MainActor. Captured as
        // a Sendable tuple struct so the detached search can build display items.
        let dictInfos: [DictInfo] = Self.dictInfos(from: context)
        guard !dictInfos.isEmpty else {
            results = []
            suggestions = []
            isSearchSettled = true
            return
        }

        let contextLabel: String
        switch context {
        case .group(let g):      contextLabel = "group '\(g.name)'"
        case .dictionary(let d): contextLabel = "dict '\(d.loggingTitle)'"
        case .none:              contextLabel = "none"
        }
        print("🧠 Semantic '\(trimmed)' in \(contextLabel) (K=\(tier.k), floor=\(tier.floor))")

        // Drop prior-query state on the floor before the heavy compute begins.
        // updateEmptyState() will then see empty results + empty suggestions +
        // isSearchSettled=false and render the spinner overlay until the task
        // below assigns new values.
        results = []
        suggestions = []
        isSearchSettled = false

        searchTask = Task { [weak self, dictInfos] in
            // Build a id→display-name lookup once so the background mapping
            // doesn't need to touch MainActor MDict objects.
            let nameById = Dictionary(uniqueKeysWithValues: dictInfos.map { ($0.dictId, $0.dictName) })
            // Pass our app-level dict ids to the service so result.dictId
            // round-trips back to the same key we use for WordDisplayItem.
            // Don't let the service rederive ids from headerSHA256, because
            // not all MDicts in this app use SHA256-based ids (some bundled /
            // preset paths use the filename-derived MDict.id).
            let dictRefs = dictInfos.map {
                SemanticDictRef(id: $0.dictId, reader: $0.reader)
            }

            let matches = await SemanticSearchService.shared.relatedKeywords(
                query: trimmed, in: dictRefs, tier: tier
            )

            guard !Task.isCancelled else { return }

            let items: [WordDisplayItem] = matches.map { m in
                WordDisplayItem(
                    word: m.key,
                    dictId: m.dictId,
                    dictName: nameById[m.dictId] ?? ""
                )
            }

            // Spelling-fallback evaluation. When the semantic compute returns
            // weak results — few matches or a mediocre top similarity — the
            // query itself is probably misspelled (NLEmbedding doesn't have
            // the exact form, so we pick up adjacent-but-not-quite words).
            // Borrow the spelling scope's Levenshtein-distance suggestion
            // logic and surface the typo fixes in the same `spellingSuggestions`
            // section the user already understands. They retain the option of
            // tapping a fuzzy suggestion to commit to that spelling.
            let topSim = matches.first?.similarity ?? 0
            let needsSpellingFallback =
                matches.count < Self.spellingFallbackCountThreshold ||
                topSim <= Self.spellingFallbackSimThreshold

            var spellingSuggestions: [String] = []
            if needsSpellingFallback {
                let readers = dictInfos.map { $0.reader }
                // Filter out the query itself + every word already shown as a
                // semantic match — those would be confusing duplicates.
                var existingWords = Set(items.map { $0.word.lowercased() })
                existingWords.insert(trimmed.lowercased())
                spellingSuggestions = await computeSuggestionsInBackground(
                    readers: readers,
                    query: trimmed,
                    existingWords: existingWords
                )
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.results = items
                self.suggestions = spellingSuggestions
                self.isSearchSettled = true
                let suggestionSuffix = spellingSuggestions.isEmpty
                    ? ""
                    : " + \(spellingSuggestions.count) spelling fallback"
                if items.isEmpty {
                    print("🧠 Semantic: no matches (OOV or all below floor)\(suggestionSuffix) → settled")
                } else {
                    print("🧠 Semantic: \(items.count) matches (top sim \(String(format: "%.2f", topSim)))\(suggestionSuffix) → settled")
                }
            }
        }
    }

    /// Top cosine-similarity below which we suspect a typo and run the
    /// spelling-style fuzzy fallback alongside the semantic matches.
    /// 0.65 is "weak even for a common adjective" in our bench data — words
    /// like "happy" / "melancholy" / "beautiful" all clear it comfortably,
    /// while OOV / off-axis queries fall below.
    private static let spellingFallbackSimThreshold: Double = 0.65

    /// Result-count below which we also run the spelling fallback regardless
    /// of similarity — empty / very-thin result sets are themselves a strong
    /// typo signal.
    private static let spellingFallbackCountThreshold: Int = 3

    /// Listen for Settings.bundle changes to `semanticResultsCount`.
    private func subscribeToSettingsChanges() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { _ in RelatedWordsTier.current }
            .removeDuplicates()
            .sink { [weak self] newTier in
                self?.tierSubject.send(newTier)
            }
            .store(in: &cancellables)
    }

    // MARK: - Context → reader tuples

    /// Sendable reader+name tuple snapshotted on MainActor so the background
    /// search task can build WordDisplayItems without re-entering MainActor.
    private struct DictInfo: Sendable {
        let reader: MDictReader
        let dictId: String
        let dictName: String
    }

    @MainActor
    private static func dictInfos(from context: SearchContext) -> [DictInfo] {
        switch context {
        case .dictionary(let dict):
            guard let reader = dict.reader else { return [] }
            return [DictInfo(reader: reader, dictId: dict.id, dictName: dict.preferredTitle)]
        case .group(let group):
            return group.active.compactMap { dict in
                guard let reader = dict.reader else { return nil }
                return DictInfo(reader: reader, dictId: dict.id, dictName: dict.preferredTitle)
            }
        case .none:
            return []
        }
    }

    // MARK: - LookupSessionProtocol API

    func updateQuery(_ query: String) {
        // See SpellingLookupSession.updateQuery — same idempotency contract:
        // skipping no-op writes keeps isSearchSettled / spinner state from
        // being toggled to false without a corresponding settle path.
        guard query != querySubject.value else { return }
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
        searchTask?.cancel()
        querySubject.send("")
        results = []
        isSearchSettled = true
    }

    var currentQuery: String { querySubject.value }
    var currentContext: SearchContext { contextSubject.value }
}
