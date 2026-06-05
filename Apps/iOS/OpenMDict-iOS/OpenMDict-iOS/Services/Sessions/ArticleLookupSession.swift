//
//  ArticleLookupSession.swift
//  OpenMDict-iOS
//
//  M15 — drives the search bar's `词条内容` (article-content) scope.
//  Conforms to LookupSessionProtocol so WordListViewController swaps it in
//  exactly like SemanticLookupSession, by switching `searchSession`.
//
//  Structure mirrors SemanticLookupSession (query/context subjects →
//  debounced CombineLatest → cancel-previous async search), with two
//  differences:
//
//    - The compute backend is ArticleSearchService (CoreML query encode +
//      per-dict sidecar cosine scan) instead of NLEmbedding neighbors.
//    - Only dicts that are BOTH enabled (not userExcluded) AND finished
//      indexing (state == .indexed) are searched — they're the only ones
//      with a queryable `.semantic.idx` sidecar. This matches
//      WordListViewController.articleScopeFullyIndexed()'s filter, so the
//      scope only ever offers real search once those dicts are ready.
//
//  `lemmaResults` and `suggestions` are always empty: article search is a
//  semantic full-text match, so there's no morphological "related forms"
//  section and a Levenshtein spelling fallback would be off-register.
//  `statusMessage` uses the protocol's nil default — the searching spinner
//  (driven by isSearchSettled) is enough feedback, including for the slow
//  first-query encoder build.
//

import Foundation
import Combine
import OpenMDict
import OpenMDictKit

@MainActor
final class ArticleLookupSession: ObservableObject, LookupSessionProtocol {

    /// Global top-K returned across all searched dicts. Fixed for now; a
    /// user-facing "result count" setting is out of scope.
    private static let topK: Int = 30

    // MARK: - Inputs

    private let querySubject = CurrentValueSubject<String, Never>("")
    private let contextSubject = CurrentValueSubject<SearchContext, Never>(.none)

    // MARK: - Outputs

    @Published private(set) var results: [WordDisplayItem] = []
    /// Always empty — article search has no morphological related-forms section.
    @Published private(set) var lemmaResults: [WordDisplayItem] = []
    /// Always empty — no spelling fallback for semantic full-text search.
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var isSearchSettled: Bool = true

    // MARK: - Protocol Publisher Accessors

    var resultsPublisher: AnyPublisher<[WordDisplayItem], Never> { $results.eraseToAnyPublisher() }
    var lemmaResultsPublisher: AnyPublisher<[WordDisplayItem], Never> { $lemmaResults.eraseToAnyPublisher() }
    var suggestionsPublisher: AnyPublisher<[String], Never> { $suggestions.eraseToAnyPublisher() }
    var isSearchSettledPublisher: AnyPublisher<Bool, Never> { $isSearchSettled.eraseToAnyPublisher() }
    // statusMessage / statusMessagePublisher use the protocol's nil default.

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        setupPipeline()
    }

    // MARK: - Reactive Pipeline

    /// (query, context) ──debounce──► cancel-previous async article search.
    private func setupPipeline() {
        Publishers.CombineLatest(
            querySubject
                .debounce(for: .milliseconds(LookupPipelineConfig.queryDebounceMs), scheduler: RunLoop.main)
                .removeDuplicates(),
            contextSubject
                .removeDuplicates()
        )
        .sink { [weak self] query, context in
            self?.runSearch(query: query, context: context)
        }
        .store(in: &cancellables)
    }

    private func runSearch(query: String, context: SearchContext) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearchSettled = true
            return
        }

        let infos = Self.dictInfos(from: context)
        guard !infos.isEmpty else {
            // No enabled+indexed dict in this context — nothing to search.
            results = []
            isSearchSettled = true
            return
        }

        // Drop prior-query rows immediately so WordListVC flips to the
        // searching spinner during the compute window (the first query also
        // pays the one-time CoreML encoder build).
        results = []
        isSearchSettled = false

        let refs = infos.map { $0.ref }
        let nameById = Dictionary(uniqueKeysWithValues: infos.map { ($0.ref.dictId, $0.dictName) })

        searchTask = Task { [refs, nameById, trimmed] in
            do {
                let matches = try await ArticleSearchService.shared.search(
                    query: trimmed, in: refs, topK: Self.topK
                )
                guard !Task.isCancelled else { return }
                let items: [WordDisplayItem] = matches.map { m in
                    WordDisplayItem(word: m.key, dictId: m.dictId, dictName: nameById[m.dictId] ?? "")
                }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.results = items
                    self.isSearchSettled = true
                }
            } catch {
                print("❌ ArticleLookupSession: search '\(trimmed)' failed: \(error)")
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.results = []
                    self.isSearchSettled = true
                }
            }
        }
    }

    // MARK: - Context → searchable dict refs

    /// Sendable ref + display name, snapshotted on main. Only enabled
    /// (`!userExcluded`) AND fully-indexed (`state == .indexed`) dicts are
    /// included — they're the ones with a queryable sidecar.
    private struct DictInfo {
        let ref: ArticleDictRef
        let dictName: String
    }

    @MainActor
    private static func dictInfos(from context: SearchContext) -> [DictInfo] {
        let service = ArticleIndexService.shared

        func makeInfo(_ dict: MDict) -> DictInfo? {
            let snap = service.snapshot(for: dict.id)
            guard !snap.userExcluded, snap.state == .indexed else { return nil }
            guard let reader = dict.reader else { return nil }
            let sidecarURL = AppGroupPaths.articleSidecarCacheURL
                .appendingPathComponent("\(dict.id).semantic.idx", isDirectory: false)
            return DictInfo(
                ref: ArticleDictRef(dictId: dict.id, reader: reader, sidecarURL: sidecarURL),
                dictName: dict.preferredTitle
            )
        }

        switch context {
        case .dictionary(let dict):
            return makeInfo(dict).map { [$0] } ?? []
        case .group(let group):
            return group.active.compactMap(makeInfo)
        case .none:
            return []
        }
    }

    // MARK: - LookupSessionProtocol API

    func updateQuery(_ query: String) {
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
