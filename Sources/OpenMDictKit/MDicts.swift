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
    
    // MARK: - Runtime Properties (not persisted)
    
    /// Actual MDict instances, populated by DictionaryService
    @Published public private(set) var items: [MDict] = []
    
    // MARK: - Initialization
    
    /// Create a group with metadata (items populated later)
    public init(id: String, name: String, isDefault: Bool = false, dictionaryIds: [String] = []) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.dictionaryIds = dictionaryIds
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
    
    /// Get suggestions across all active dictionaries
    public func suggestions(for key: MDictWordKey, limit: Int = 10) -> [MDictWordKey] {
        var allSuggestions: Set<MDictWordKey> = []
        
        for item in active {
            let suggestions = item.suggestions(for: key, limit: limit)
            allSuggestions.formUnion(suggestions)
        }
        
        return Array(allSuggestions).sorted().prefix(limit).map { $0 }
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
