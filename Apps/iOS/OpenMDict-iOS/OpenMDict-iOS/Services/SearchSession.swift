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
    
    // MARK: - Output
    
    @Published private(set) var results: [WordDisplayItem] = []
    
    // MARK: - State
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    init() {
        setupPipeline()
    }
    
    // MARK: - Reactive Pipeline
    
    /// Core reactive pipeline:
    /// ```
    /// (query, context) ──► map to lookupPublisher ──► switchToLatest ──► results
    ///                                                    ↑
    ///                                    Key: auto-cancels previous search
    /// ```
    private func setupPipeline() {
        Publishers.CombineLatest(
            querySubject
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .removeDuplicates(),
            contextSubject
                .removeDuplicates()
        )
        .map { [weak self] query, context -> AnyPublisher<[WordDisplayItem], Never> in
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
            
            return lookupable.lookupPublisher(prefix: query, limit: 50)
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
