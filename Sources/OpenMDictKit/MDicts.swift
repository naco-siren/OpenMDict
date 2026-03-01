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

    /// Reactive lookup - searches all enabled dictionaries on a background thread.
    ///
    /// Captures `MDictReader` references (Sendable, thread-safe via internal NSLock)
    /// and dictionary metadata on MainActor, then dispatches all binary searches
    /// to a single background block. Emits **once** with sorted results.
    ///
    /// This avoids the previous MergeMany+scan pattern which caused N emissions
    /// per query (one per dictionary) and `@MainActor` data-race warnings when
    /// scan/sort closures ran on background threads.
    public func lookupPublisher(prefix: String, limit: Int = 50) -> AnyPublisher<[WordSearchResult], Never> {
        let enabledItems = items.filter { $0.isEnabled }

        guard !enabledItems.isEmpty else {
            return Just([]).eraseToAnyPublisher()
        }

        // Capture Sendable readers + metadata on MainActor.
        // Dicts that haven't loaded yet (reader == nil) are skipped for this query.
        let dictInfos: [GroupSearchInfo] = enabledItems.compactMap { dict in
            guard let reader = dict.reader else { return nil }
            return GroupSearchInfo(reader: reader, dictId: dict.id, dictName: dict.preferredTitle)
        }

        guard !dictInfos.isEmpty else {
            return Just([]).eraseToAnyPublisher()
        }

        // Bridge Swift Concurrency → Combine: Task.detached runs all searches
        // off MainActor; promise fulfills the Future on completion.
        // Deferred ensures work starts on subscription (respects switchToLatest timing).
        // UncheckedSendableBox wraps promise to satisfy `sending` parameter.
        return Deferred {
            Future<[WordSearchResult], Never> { promise in
                let box = UncheckedSendableBox(value: promise)
                Task.detached(priority: .userInitiated) {
                    let results = await performGroupSearch(
                        dictInfos: dictInfos, prefix: prefix, limit: limit
                    )
                    box.value(.success(results))
                }
            }
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - Background Group Search

/// Reader + metadata tuple for background group search.
/// Captured on MainActor, passed to `@concurrent` task.
private struct GroupSearchInfo: Sendable {
    let reader: MDictReader
    let dictId: String
    let dictName: String
}

/// Search all dictionaries in a group on a background thread.
/// `MDictReader` is `@unchecked Sendable` (thread-safe via internal NSLock).
/// Checks `Task.isCancelled` between dictionaries for cooperative cancellation.
@concurrent
private nonisolated func performGroupSearch(
    dictInfos: [GroupSearchInfo],
    prefix: String,
    limit: Int
) async -> [WordSearchResult] {
    var allResults: [WordSearchResult] = []
    for info in dictInfos {
        guard !Task.isCancelled else { return [] }
        let keys = info.reader.search(prefix: prefix, limit: limit)
        allResults.append(contentsOf: keys.map {
            WordSearchResult(word: $0, dictId: info.dictId, dictName: info.dictName)
        })
    }

    guard !Task.isCancelled else { return [] }

    // Stable sort: alphabetical by word, preserving dictionary order for ties
    return allResults.enumerated()
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
