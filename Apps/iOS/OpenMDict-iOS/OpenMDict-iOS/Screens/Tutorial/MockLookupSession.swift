//
//  MockLookupSession.swift
//  OpenMDict-iOS
//
//  Fake LookupSessionProtocol for the Lookup Basics tutorial.
//  Publishes pre-populated results/lemma/suggestions without any
//  actual dictionary lookup. Controlled by setStep(_:) calls.
//

import Foundation
import Combine
import OpenMDictKit

@MainActor
final class MockLookupSession: LookupSessionProtocol {

    // MARK: - Published State

    @Published private(set) var results: [WordDisplayItem] = []
    @Published private(set) var lemmaResults: [WordDisplayItem] = []
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var isSearchSettled: Bool = true

    var resultsPublisher: AnyPublisher<[WordDisplayItem], Never> { $results.eraseToAnyPublisher() }
    var lemmaResultsPublisher: AnyPublisher<[WordDisplayItem], Never> { $lemmaResults.eraseToAnyPublisher() }
    var suggestionsPublisher: AnyPublisher<[String], Never> { $suggestions.eraseToAnyPublisher() }
    var isSearchSettledPublisher: AnyPublisher<Bool, Never> { $isSearchSettled.eraseToAnyPublisher() }

    // MARK: - Input (no-ops in tutorial)

    private(set) var currentQuery: String = ""
    // Default to a fake group context so WordListVC shows dict name subtitles
    private(set) var currentContext: SearchContext = .group(
        MDicts(id: "__tutorial_group__", name: "All Dictionaries", isDefault: true)
    )

    func updateQuery(_ query: String) { currentQuery = query }
    func setContext(_ context: SearchContext) { currentContext = context }
    func setContext(group: MDicts) { currentContext = .group(group) }
    func setContext(dict: MDict) { currentContext = .dictionary(dict) }
    func clearSearch() {
        results = []
        lemmaResults = []
        suggestions = []
        currentQuery = ""
    }

    // MARK: - Mock Data

    private static let sampleAId = "__tutorial_sample_a__"
    private static let sampleBId = "__tutorial_sample_b__"
    private static let sampleCId = "__tutorial_sample_c__"
    private static let sampleDId = "__tutorial_sample_d__"
    private static let wordnetId = "__tutorial_wordnet__"
    private static let sampleAName = "Sample Dictionary A"
    private static let sampleBName = "Sample Dictionary B"
    private static let sampleCName = "Sample Dictionary C"
    private static let sampleDName = "Sample Dictionary D"
    private static let wordnetName = "WordNet"

    /// Populate the session with fake data for a tutorial step.
    func setStep(_ step: Int) {
        switch step {
        case 0:
            // Empty query — WordListVC shows clipboard/history from its own sources.
            results = []
            lemmaResults = []
            suggestions = []

        case 1:
            // Search "Too" — normal results across multiple dicts
            results = [
                WordDisplayItem(word: "Too Young", dictId: Self.sampleAId, dictName: Self.sampleAName),
                WordDisplayItem(word: "Too Simple", dictId: Self.sampleBId, dictName: Self.sampleBName),
            ]
            lemmaResults = []
            suggestions = []

        case 2:
            // Search "bombardio" — no direct results + related forms (lemma)
            results = []
            lemmaResults = [
                WordDisplayItem(word: "bombardino", dictId: Self.sampleAId, dictName: Self.sampleAName),
                WordDisplayItem(word: "bombardiro crocodilo", dictId: Self.sampleCId, dictName: Self.sampleCName),
                WordDisplayItem(word: "bombombini gusini", dictId: Self.sampleDId, dictName: Self.sampleDName),
            ]
            suggestions = []

        case 3:
            // Search "Tralalero" (no match) — suggestions
            results = []
            lemmaResults = []
            suggestions = ["Tralala"]

        default:
            break
        }
    }
}
