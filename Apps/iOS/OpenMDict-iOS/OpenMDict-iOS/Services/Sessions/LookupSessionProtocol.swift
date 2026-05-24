//
//  LookupSessionProtocol.swift
//  OpenMDict-iOS
//
//  Abstracts the SpellingLookupSession interface so WordListViewController can be
//  driven by a mock session in tutorial mode.
//

import Foundation
import Combine
import OpenMDictKit

/// Protocol for the lookup session consumed by WordListViewController.
///
/// The concrete `SpellingLookupSession` class conforms to this protocol. A mock
/// implementation can be created for tutorials with pre-populated data.
@MainActor
protocol LookupSessionProtocol: AnyObject {

    // MARK: - Observable Outputs

    /// Current search results. Observe via `resultsPublisher`.
    var results: [WordDisplayItem] { get }
    var resultsPublisher: AnyPublisher<[WordDisplayItem], Never> { get }

    /// Lemma-resolved related forms. Observe via `lemmaResultsPublisher`.
    var lemmaResults: [WordDisplayItem] { get }
    var lemmaResultsPublisher: AnyPublisher<[WordDisplayItem], Never> { get }

    /// Suggested words (fuzzy match). Observe via `suggestionsPublisher`.
    var suggestions: [String] { get }
    var suggestionsPublisher: AnyPublisher<[String], Never> { get }

    /// Whether the search pipeline has settled. Observe via `isSearchSettledPublisher`.
    var isSearchSettled: Bool { get }
    var isSearchSettledPublisher: AnyPublisher<Bool, Never> { get }

    // MARK: - Inputs

    func updateQuery(_ query: String)
    func setContext(_ context: SearchContext)
    func setContext(group: MDicts)
    func setContext(dict: MDict)
    func clearSearch()

    // MARK: - State

    var currentQuery: String { get }
    var currentContext: SearchContext { get }
}
