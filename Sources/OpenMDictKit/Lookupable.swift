//
//  Lookupable.swift
//  OpenMDict
//
//
import Combine

// MARK: - Lookupable Protocol

/// Protocol for dictionary lookup capability
/// Both MDict (single) and MDicts (group) conform to this
public protocol Lookupable {
    /// Reactive lookup - returns results progressively as dictionaries load
    /// - Parameters:
    ///   - prefix: Search prefix
    ///   - limit: Maximum results per dictionary
    /// - Returns: Publisher that emits cumulative sorted results
    func lookupPublisher(prefix: String, limit: Int) -> AnyPublisher<[WordSearchResult], Never>
}

// MARK: - Word Search Result

/// Result item from lookup - contains everything needed for display
/// This is the "currency" of the reactive lookup pipeline
public struct WordSearchResult: Identifiable, Hashable, Sendable {
    public let word: String
    public let dictId: String
    public let dictName: String
    
    public var id: String { "\(dictId):\(word)" }
    
    public init(word: String, dictId: String, dictName: String) {
        self.word = word
        self.dictId = dictId
        self.dictName = dictName
    }
}
