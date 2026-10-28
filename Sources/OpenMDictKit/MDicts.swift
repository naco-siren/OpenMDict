import Foundation
import Combine
import OpenMDict

// MARK: - Lookup Result

/// Result from looking up a word across dictionaries
public struct MDictLookupResult {
    public let dict: MDict
    public let entry: MDictWordEntry
    
    public init(dict: MDict, entry: MDictWordEntry) {
        self.dict = dict
        self.entry = entry
    }
}

// MARK: - MDicts

/// Dictionary group ViewModel with metadata and runtime dictionary references
///
/// Combines two roles:
/// - **Persistable metadata**: id, name, isDefault, dictionaryIds (for user-defined groups)
/// - **Runtime container**: items array populated from DictionaryService
///
/// Marked as `@MainActor` class since it manages UI-facing state and
/// holds references to `@MainActor` isolated `MDict` instances.
///
/// Usage:
/// ```swift
/// // Create a group with metadata
/// let group = MDicts(id: "favorites", name: "Favorites", dictionaryIds: ["wordnet", "gcide"])
///
/// // Populate with actual MDict instances
/// group.populate(from: allDictionaries)
///
/// // Stream lookup results
/// for await result in group.lookup("hello") {
///     print("\(result.dict.metadata?.title): \(result.entry.article.html)")
/// }
/// ```
@MainActor
public final class MDicts: ObservableObject, Identifiable {
    
    // MARK: - Persistable Properties
    
    /// Unique identifier for this group
    public nonisolated let id: String
    
    /// Display name
    public var name: String
    
    /// Whether this is the default "All Dictionaries" group
    public var isDefault: Bool
    
    /// Ordered list of dictionary IDs (determines lookup priority)
    public var dictionaryIds: [String]
    
    /// Creation timestamp (nil for default group)
    public var createdAt: Date?
    
    /// Last modification timestamp (nil for default group)
    public var modifiedAt: Date?
    
    // MARK: - Runtime Properties (not persisted)
    
    /// Actual MDict instances, populated by DictionaryService
    @Published public private(set) var items: [MDict] = []
    
    // MARK: - Initialization
    
    /// Create a group with metadata (items populated later)
    public init(id: String, name: String, isDefault: Bool = false, dictionaryIds: [String] = [],
                createdAt: Date? = nil, modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.dictionaryIds = dictionaryIds
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
    
    /// Create from MDict array directly (for ad-hoc usage)
    public init(_ items: [MDict]) {
        self.id = UUID().uuidString
        self.name = ""
        self.isDefault = false
        self.dictionaryIds = items.map { $0.id }
        self.items = items
    }
    
    /// Create empty
    public init() {
        self.id = UUID().uuidString
        self.name = ""
        self.isDefault = false
        self.dictionaryIds = []
    }
    
    // MARK: - Population
    
    /// Populate items from a dictionary list (call after loading from persistence)
    public func populate(from allDicts: [MDict]) {
        items = dictionaryIds.compactMap { id in
            allDicts.first { $0.id == id }
        }
    }
    
    // MARK: - Computed Properties
    
    /// Number of dictionaries
    public var count: Int { items.count }
    
    /// Whether empty
    public var isEmpty: Bool { items.isEmpty }
    
    /// Items that are currently loaded
    public var loaded: [MDict] {
        items.filter { $0.isLoaded }
    }
    
    /// Items that are enabled for searching
    public var enabled: [MDict] {
        items.filter { $0.isEnabled }
    }
    
    /// Items that are both loaded and enabled (ready for lookup)
    public var active: [MDict] {
        items.filter { $0.isLoaded && $0.isEnabled }
    }

    /// Sendable readers for all active (loaded + enabled) dictionaries.
    /// Capture on MainActor, pass to background tasks.
    public var activeReaders: [MDictReader] {
        active.compactMap(\.reader)
    }

    // MARK: - Access
    
    /// Get item by ID
    public func item(id: String) -> MDict? {
        items.first { $0.id == id }
    }
    
    /// Get item by index
    public subscript(index: Int) -> MDict? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }
    
    // MARK: - Lookup API
    
    /// Look up a word across all active dictionaries
    /// Returns AsyncStream for progressive results (first dict returns first)
    public func lookup(_ key: MDictWordKey) -> AsyncStream<MDictLookupResult> {
        let activeItems = active
        return AsyncStream { continuation in
            Task {
                for item in activeItems {
                    if let entry = item.lookup(key) {
                        continuation.yield(MDictLookupResult(dict: item, entry: entry))
                    }
                }
                continuation.finish()
            }
        }
    }
    
    /// Quick lookup - first result only
    public func quickLookup(_ key: MDictWordKey) -> MDictLookupResult? {
        for item in active {
            if let entry = item.lookup(key) {
                return MDictLookupResult(dict: item, entry: entry)
            }
        }
        return nil
    }
    
    /// Look up in a specific dictionary
    public func lookup(_ key: MDictWordKey, in dictId: String) -> MDictWordEntry? {
        item(id: dictId)?.lookup(key)
    }
    
    // MARK: - Search API
    
    /// Search by prefix across all active dictionaries
    public func search(prefix: String, limit: Int = 20) -> [String: [MDictWordKey]] {
        var results: [String: [MDictWordKey]] = [:]
        
        for item in active {
            let matches = item.search(prefix: prefix, limit: limit)
            if !matches.isEmpty {
                results[item.id] = matches
            }
        }
        
        return results
    }
    
    /// Get suggestions across all active dictionaries, globally ranked by edit distance.
    public func suggestions(for key: MDictWordKey, limit: Int = 10) -> [ScoredSuggestion] {
        // Collect from all dicts, dedup case-insensitively keeping best (min) distance.
        var best: [String: ScoredSuggestion] = [:]  // lowercased key → best scored suggestion

        for item in active {
            for s in item.suggestions(for: key, limit: limit) {
                let lc = s.word.lowercased()
                if let existing = best[lc] {
                    if s.distance < existing.distance { best[lc] = s }
                } else {
                    best[lc] = s
                }
            }
        }

        return best.values
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.word < $1.word }
            .prefix(limit)
            .map { $0 }
    }
    
    // MARK: - Resource API
    
    /// Get a resource from a specific dictionary
    public func resource(for path: String, in dictId: String) -> Data? {
        item(id: dictId)?.resource(for: path)
    }
    
    // MARK: - Memory Management
    
    /// Unload all dictionaries
    public func unloadAll() {
        for item in items {
            item.unload()
        }
    }
    
    /// Load all dictionaries sequentially
    public func loadAll() async {
        for item in items where !item.isLoaded {
            try? await item.load()
        }
    }
    
    // MARK: - Statistics
    
    public var statistics: String {
        let totalEntries = items.compactMap { $0.metadata?.entryCount }.reduce(0, +)
        let loadedCount = loaded.count
        let enabledCount = enabled.count
        
        return """
        Dictionaries: \(count) total, \(loadedCount) loaded, \(enabledCount) enabled
        Total entries: \(totalEntries)
        """
    }
}

// MARK: - MDicts + Lookupable

extension MDicts: @MainActor Lookupable {

    /// Reactive lookup — searches all enabled dictionaries, emitting results
    /// progressively as each dictionary finishes loading.
    ///
    /// Uses `MergeMany` of each `MDict.lookupPublisher`, which internally waits
    /// for `$state.first { .loaded }` before searching. This means:
    /// - Dicts already loaded → emit quickly.
    /// - Dicts still loading  → emit as soon as they finish loading.
    /// No results are silently dropped because of a mid-load query.
    ///
    /// `scan` accumulates per-dict batches into a running sorted total using
    /// a `nonisolated` free-function reference — preventing `@MainActor`
    /// inference that would otherwise cause a data-race warning when Combine
    /// calls the closure on background threads (where each MDict publisher emits).
    ///
    /// Downstream (`SpellingLookupSession`) receives N emissions (one per dict) via
    /// `switchToLatest`, updating the word list progressively.
    ///
    /// The reader's search fallbacks (full-width folding, diacritics) are a
    /// group-level decision: a first pass searches every dictionary for
    /// keys with the prefix as typed, and only when all of them come back
    /// empty does a second pass search them with the fallbacks, so that
    /// another dictionary's folded keys never sort in among direct matches.
    /// Rows of the second pass carry `WordSearchResult.fallback`.
    public func lookupPublisher(prefix: String, limit: Int = 50) -> AnyPublisher<[WordSearchResult], Never> {
        let enabledItems = items.filter { $0.isEnabled }

        guard !enabledItems.isEmpty else {
            return Just([]).eraseToAnyPublisher()
        }

        // Create one publisher per enabled dictionary and pass. Each
        // MDict.lookupPublisher waits for that dict to load ($state.first
        // { .loaded }) then searches. All captured on MainActor here;
        // background work happens inside each dict's publisher.
        let direct = enabledItems.map { $0.lookupPublisher(prefix: prefix, limit: limit, fallbacks: .none) }
        let withFallbacks = enabledItems.map { $0.lookupPublisher(prefix: prefix, limit: limit, fallbacks: .all) }
        return twoPassLookupPublisher(direct: direct, withFallbacks: withFallbacks)
    }
}

// MARK: - Two-Pass Group Search

/// The merged, accumulated emissions of `direct`, then — if they amounted
/// to nothing — those of `withFallbacks`. A file-scope `nonisolated`
/// function, so the closures below are not `@MainActor`: Combine runs them
/// on the threads the dictionaries' searches finish on.
private nonisolated func twoPassLookupPublisher(
    direct: [AnyPublisher<[WordSearchResult], Never>],
    withFallbacks: [AnyPublisher<[WordSearchResult], Never>]
) -> AnyPublisher<[WordSearchResult], Never> {
    let found = FoundFlag()
    let firstPass = Publishers.MergeMany(direct)
        .scan([WordSearchResult](), accumulateLookupResults)
        .handleEvents(receiveOutput: { results in if !results.isEmpty { found.set() } })
    // `Deferred` runs when `firstPass` has completed, so `found` is final.
    // It is subscribed on the main queue: each dictionary's publisher reads
    // the dictionary's main-actor state when subscribed, and the first pass
    // completes on the thread its last search finished on.
    let secondPass = Deferred { () -> AnyPublisher<[WordSearchResult], Never> in
        guard !found.isSet else { return Empty().eraseToAnyPublisher() }
        return Publishers.MergeMany(withFallbacks)
            .scan([WordSearchResult](), accumulateLookupResults)
            .eraseToAnyPublisher()
    }
    .subscribe(on: DispatchQueue.main)
    return firstPass.append(secondPass).eraseToAnyPublisher()
}

/// Whether the first pass found anything; set from the threads the
/// searches finish on, read when the second pass starts.
private final class FoundFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// MARK: - Lookup Result Accumulation

/// Merges an incoming per-dictionary result batch into the running accumulation,
/// maintaining stable alphabetical sort (word order; arrival order for ties).
///
/// File-scope `nonisolated` function — NOT a closure literal — to prevent
/// `@MainActor` inference in Swift 6 with `-default-isolation=MainActor`.
/// Combine calls `scan`'s accumulator on background threads (where each
/// `MDict.lookupPublisher` emits), so `@MainActor` isolation here would
/// cause a data-race warning.
private nonisolated func accumulateLookupResults(
    _ accumulated: [WordSearchResult],
    _ incoming: [WordSearchResult]
) -> [WordSearchResult] {
    let combined = accumulated + incoming
    return combined.enumerated()
        .sorted { a, b in
            let cmp = a.element.word.localizedCaseInsensitiveCompare(b.element.word)
            return cmp == .orderedSame ? a.offset < b.offset : cmp == .orderedAscending
        }
        .map { $0.element }
}

// MARK: - Hashable

extension MDicts: Hashable {
    public nonisolated static func == (lhs: MDicts, rhs: MDicts) -> Bool {
        lhs.id == rhs.id
    }
    
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Codable (only persistable fields)

extension MDicts: @MainActor Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, isDefault, dictionaryIds
    }
    
    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let isDefault = try container.decode(Bool.self, forKey: .isDefault)
        let dictionaryIds = try container.decode([String].self, forKey: .dictionaryIds)
        self.init(id: id, name: name, isDefault: isDefault, dictionaryIds: dictionaryIds)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // Access MainActor-isolated properties safely
        MainActor.assumeIsolated {
            try? container.encode(self.name, forKey: .name)
            try? container.encode(self.isDefault, forKey: .isDefault)
            try? container.encode(self.dictionaryIds, forKey: .dictionaryIds)
        }
    }
}
