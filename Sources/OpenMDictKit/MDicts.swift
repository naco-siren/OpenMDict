import Foundation
import OpenMDict

// MARK: - Lookup Result

/// Result from looking up a word across dictionaries
public struct MDictLookupResult: Sendable {
    public let dict: MDict
    public let entry: MDictWordEntry
    
    public init(dict: MDict, entry: MDictWordEntry) {
        self.dict = dict
        self.entry = entry
    }
}

// MARK: - MDicts

/// Dictionary group with metadata and runtime dictionary references
///
/// Combines two roles:
/// - **Persistable metadata**: id, name, isDefault, dictionaryIds (for user-defined groups)
/// - **Runtime container**: items array populated from DictionaryService
///
/// Usage:
/// ```swift
/// // Create a group with metadata
/// var group = MDicts(id: "favorites", name: "Favorites", dictionaryIds: ["wordnet", "gcide"])
///
/// // Populate with actual MDict instances
/// group.populate(from: allDictionaries)
///
/// // Stream lookup results
/// for await result in group.lookup("hello") {
///     print("\(result.dict.metadata?.title): \(result.entry.article.html)")
/// }
/// ```
public struct MDicts: Identifiable, Hashable {
    
    // MARK: - Persistable Properties
    
    /// Unique identifier for this group
    public let id: String
    
    /// Display name
    public var name: String
    
    /// Whether this is the default "All Dictionaries" group
    public var isDefault: Bool
    
    /// Ordered list of dictionary IDs (determines lookup priority)
    public var dictionaryIds: [String]
    
    // MARK: - Runtime Properties (not persisted)
    
    /// Actual MDict instances, populated by DictionaryService
    public private(set) var items: [MDict] = []
    
    // MARK: - Initialization
    
    /// Create a group with metadata (items populated later)
    public init(id: String, name: String, isDefault: Bool = false, dictionaryIds: [String] = []) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.dictionaryIds = dictionaryIds
    }
    
    /// Create from MDict array directly (for backward compatibility / ad-hoc usage)
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
    /// - Parameter allDicts: All available MDict instances
    public mutating func populate(from allDicts: [MDict]) {
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
    ///
    /// - Parameter key: The word to look up
    /// - Returns: Async stream of lookup results
    public func lookup(_ key: MDictWordKey) -> AsyncStream<MDictLookupResult> {
        AsyncStream { continuation in
            Task {
                for item in active {
                    if let entry = item.lookup(key) {
                        continuation.yield(MDictLookupResult(dict: item, entry: entry))
                    }
                }
                continuation.finish()
            }
        }
    }
    
    /// Quick lookup - first result only
    /// - Parameter key: The word to look up
    /// - Returns: First matching result or nil
    public func quickLookup(_ key: MDictWordKey) -> MDictLookupResult? {
        for item in active {
            if let entry = item.lookup(key) {
                return MDictLookupResult(dict: item, entry: entry)
            }
        }
        return nil
    }
    
    /// Look up in a specific dictionary
    /// - Parameters:
    ///   - key: The word to look up
    ///   - dictId: Dictionary ID to search in
    /// - Returns: Entry or nil
    public func lookup(_ key: MDictWordKey, in dictId: String) -> MDictWordEntry? {
        item(id: dictId)?.lookup(key)
    }
    
    // MARK: - Search API
    
    /// Search by prefix across all active dictionaries
    /// - Parameters:
    ///   - prefix: Prefix to search for
    ///   - limit: Maximum results per dictionary
    /// - Returns: Dictionary mapping dict ID to matches
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
    /// - Parameters:
    ///   - key: The word to find suggestions for
    ///   - limit: Maximum total suggestions
    /// - Returns: Array of unique suggestions
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
    /// - Parameters:
    ///   - path: Resource path
    ///   - dictId: Dictionary ID
    /// - Returns: Resource data or nil
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
            try? await item.loadAsync()
        }
    }
    
    // MARK: - Hashable
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: MDicts, rhs: MDicts) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Codable (only persistable fields)

extension MDicts: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, isDefault, dictionaryIds
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        dictionaryIds = try container.decode([String].self, forKey: .dictionaryIds)
        items = []  // Populated at runtime
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(dictionaryIds, forKey: .dictionaryIds)
        // items is not encoded
    }
}

// MARK: - Statistics

extension MDicts {
    
    /// Get statistics string
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
