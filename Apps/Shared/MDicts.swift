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

// MARK: - MDicts (Thin Wrapper)

/// Thin wrapper for managing multiple dictionaries
/// Does NOT own the MDict instances - only references them
/// Can be recreated freely without losing loaded dictionary state
///
/// Usage:
/// ```swift
/// // App owns the items
/// @State var items: [MDict] = [...]
///
/// // Create wrapper when needed (order = priority)
/// let dicts = MDicts(items)
///
/// // Stream lookup results
/// for await result in dicts.lookup("hello") {
///     print("\(result.dict.metadata?.title): \(result.entry.article.html)")
/// }
/// ```
public struct MDicts: Sendable {
    
    // MARK: - Properties
    
    /// The dictionary items (not owned, just referenced)
    /// Order = priority (first = highest)
    public let items: [MDict]
    
    // MARK: - Initialization
    
    /// Create from array of items
    /// Order determines lookup priority
    public init(_ items: [MDict]) {
        self.items = items
    }
    
    /// Create empty
    public init() {
        self.items = []
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
    
    /// Items that are pinned (should stay in memory)
    public var pinned: [MDict] {
        items.filter { $0.isPinned }
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
    
    /// Unload all non-pinned dictionaries
    /// Call this on memory warning
    public func handleMemoryWarning() {
        for item in items where !item.isPinned {
            item.unload()
        }
    }
    
    /// Unload all dictionaries
    public func unloadAll() {
        for item in items {
            item.unload()
        }
    }
    
    /// Load pinned dictionaries
    public func loadPinned() async {
        for item in pinned where !item.isLoaded {
            try? await item.loadAsync()
        }
    }
    
    /// Load first dictionary (default behavior on app start)
    public func loadFirst() async {
        if let first = items.first, !first.isLoaded {
            try? await first.loadAsync()
        }
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
