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
//    - `suggestions` is always empty — when a semantic query is OOV in
//      every active dict's NLEmbedding space, we return nothing rather
//      than offering a Levenshtein fuzzy fallback (which doesn't translate
//      to "semantic neighbors of a non-existent word" in any useful way).
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
    /// Always empty for semantic — included to satisfy LookupSessionProtocol.
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
    private func runSearch(query: String, context: SearchContext, tier: RelatedWordsTier) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearchSettled = true
            return
        }

        // Resolve readers + display metadata on MainActor. Captured as
        // a Sendable tuple struct so the detached search can build display items.
        let dictInfos: [DictInfo] = Self.dictInfos(from: context)
        guard !dictInfos.isEmpty else {
            results = []
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

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.results = items
                self.isSearchSettled = true
                if items.isEmpty {
                    print("🧠 Semantic: no matches (OOV or all below floor) → settled")
                } else {
                    print("🧠 Semantic: \(items.count) matches → settled")
                }
            }
        }
    }

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
