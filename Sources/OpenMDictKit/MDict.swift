import Foundation
import Combine
import OpenMDict

// MARK: - Load State

/// Dictionary loading state
public enum MDictLoadState: Sendable, Equatable {
    case unloaded
    case loading
    case loaded
    case error(String)
}

// MARK: - MDict (ViewModel)

/// Single dictionary ViewModel
/// Holds MDictReader and manages loading state
///
/// Usage:
/// ```swift
/// let dict = MDict(path: "MyDict.mdx")
/// try await dict.load()
/// if let entry = dict.lookup("hello") {
///     print(entry.article.html)
/// }
/// ```
public final class MDict: ObservableObject, Identifiable {
    
    // MARK: - Identity
    
    /// Unique identifier (derived from filename)
    public let id: String
    
    /// File path to the MDX
    public let path: String
    
    // MARK: - State
    
    /// Lightweight metadata (available before full load)
    public private(set) var metadata: MDictMetadata?
    
    /// Current loading state
    public private(set) var state: MDictLoadState = .unloaded
    
    /// Whether this dictionary is enabled for searching
    public var isEnabled: Bool = true
    
    // MARK: - Resource
    
    /// The actual dictionary reader (nil when unloaded)
    private var _reader: MDictReader?
    
    /// Whether the dictionary is currently loaded
    public var isLoaded: Bool { _reader != nil }
    
    // MARK: - Thread Safety
    
    private let lock = NSLock()
    
    // MARK: - Caching
    
    // TODO: Implement LRU cache for lookup history
    // private var recentEntries = LRUCache<MDictWordKey, MDictWordEntry>(capacity: 50)
    
    /*
     Cache Strategy Notes:
     
     1. Lookup history caching is straightforward - use a separate LRU cache.
     
     2. Prefetch caching should be more aggressive but with:
        - Lower priority
        - Smaller capacity
     
     3. Prefetch cache lifecycle is tied to lookup history:
        - When a history entry is dequeued, its prefetched entries can be disposed.
     
     4. Consider reference counting for shared entries:
        - Example: Search history is ["apple", "pear"]
        - Both might reference "fruit" in their related entries
        - "fruit" has refcount=2 in the shared cache
        - "pineapple" (only related to "apple") has refcount=1
        - When "apple" is dequeued from history:
          - "pineapple" refcount becomes 0 → removed
          - "fruit" refcount becomes 1 → survives
     
     5. The caches might not need to store actual values, just pointers/references.
    */
    
    // MARK: - Initialization
    
    /// Create a dictionary ViewModel from MDX path
    /// Only loads metadata, not full dictionary
    public init(path: String) {
        self.path = path
        self.id = Self.generateId(from: path)
        
        // Load metadata immediately (fast, header only)
        self.metadata = MDictReader.loadMetadata(from: path)
    }
    
    /// Create with pre-loaded metadata
    public init(path: String, metadata: MDictMetadata) {
        self.path = path
        self.id = Self.generateId(from: path)
        self.metadata = metadata
    }
    
    private static func generateId(from path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }
    
    // MARK: - Lifecycle
    
    /// Load the dictionary into memory
    /// Thread-safe, idempotent
    public func load() throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard _reader == nil else { return }
        
        state = .loading
        
        do {
            _reader = try MDictReader(path: path)
            metadata = _reader?.metadata
            state = .loaded
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Load asynchronously
    public func loadAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.load()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Unload the dictionary to free memory
    /// Thread-safe
    public func unload() {
        lock.lock()
        defer { lock.unlock() }
        
        _reader = nil
        state = .unloaded
        // TODO: Clear caches
    }
    
    // MARK: - Lookup API
    
    /// Look up a word
    /// - Parameter key: The word to look up
    /// - Returns: Entry with article content, or nil if not found
    public func lookup(_ key: MDictWordKey) -> MDictWordEntry? {
        // TODO: Check LRU cache first
        // if let cached = recentEntries[key] { return cached }
        
        guard let entry = _reader?.lookup(key) else { return nil }
        
        // TODO: Add to LRU cache
        // recentEntries[key] = entry
        
        return entry
    }
    
    /// Search for word keys with a prefix
    public func search(prefix: String, limit: Int = 20) -> [MDictWordKey] {
        _reader?.search(prefix: prefix, limit: limit) ?? []
    }
    
    /// Get suggestions for a misspelled word
    public func suggestions(for key: MDictWordKey, limit: Int = 5) -> [MDictWordKey] {
        _reader?.suggestions(for: key, limit: limit) ?? []
    }
    
    // MARK: - Navigation
    
    /// Get previous entry
    /// - Parameter entry: Current entry
    /// - Returns: Previous entry or nil if at beginning
    public func prev(_ entry: MDictWordEntry) -> MDictWordEntry? {
        // TODO: Check prefetch cache
        // TODO: Trigger prefetch for surrounding entries
        return _reader?[entry.index - 1]
    }
    
    /// Get next entry
    /// - Parameter entry: Current entry
    /// - Returns: Next entry or nil if at end
    public func next(_ entry: MDictWordEntry) -> MDictWordEntry? {
        // TODO: Check prefetch cache
        // TODO: Trigger prefetch for surrounding entries
        return _reader?[entry.index + 1]
    }
    
    /// Access entry by index
    public subscript(index: Int) -> MDictWordEntry? {
        _reader?[index]
    }
    
    // MARK: - Resource API
    
    /// Get a resource
    public func resource(for path: String) -> Data? {
        _reader?.resource(for: path)
    }
    
    /// Get a resource as string
    public func resourceString(for path: String, encoding: String.Encoding = .utf8) -> String? {
        _reader?.resourceString(for: path, encoding: encoding)
    }
    
    /// Check if a resource exists
    public func hasResource(_ path: String) -> Bool {
        _reader?.hasResource(path) ?? false
    }
}

// MARK: - Equatable & Hashable

extension MDict: Equatable {
    public static func == (lhs: MDict, rhs: MDict) -> Bool {
        lhs.id == rhs.id
    }
}

extension MDict: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
