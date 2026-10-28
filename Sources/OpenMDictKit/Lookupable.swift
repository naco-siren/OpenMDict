//
//  Lookupable.swift
//  OpenMDict
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

    /// How the key was found when no key starts with the query as typed:
    /// nil for a key that does, `.widthFolded` or `.diacriticInsensitive`
    /// otherwise (see `MDictReader.searchWithFallback`). A publisher's
    /// emission never mixes the two kinds; a group emits fallback rows only
    /// when no dictionary has a direct one.
    public let fallback: MDictLookupFallback?

    public var id: String { "\(dictId):\(word)" }

    public init(word: String, dictId: String, dictName: String, fallback: MDictLookupFallback? = nil) {
        self.word = word
        self.dictId = dictId
        self.dictName = dictName
        self.fallback = fallback
    }
}

// MARK: - Sendable Bridge for Combine ↔ Swift Concurrency

/// Wraps a non-Sendable value to cross actor boundaries via `Task.detached`.
///
/// Used to bridge Combine `Future.Promise` into `Task.detached` closures,
/// which require `sending` parameters. `Future.Promise` is a callback invoked
/// exactly once — thread-safe by contract, but the compiler can't verify this.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}
