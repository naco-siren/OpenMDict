import Foundation
import Combine
@_exported import OpenMDict

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
/// Marked as `@MainActor` to ensure all state updates happen on main thread.
/// Heavy IO work is offloaded via `nonisolated` helper functions.
///
/// Usage:
/// ```swift
/// let dict = MDict(path: "MyDict.mdx")
/// try await dict.load()
/// if let entry = dict.lookup("hello") {
///     print(entry.article.html)
/// }
/// ```
@MainActor
public final class MDict: ObservableObject, Identifiable {
    
    // MARK: - Identity
    
    /// Unique identifier (derived from filename)
    public nonisolated let id: String
    
    /// File path to the MDX
    public nonisolated let path: String
    
    // MARK: - State
    
    /// Lightweight metadata (available before full load)
    @Published public private(set) var metadata: MDictMetadata?
    
    /// Current loading state
    @Published public private(set) var state: MDictLoadState = .unloaded
    
    /// Whether this dictionary is enabled for searching
    public var isEnabled: Bool = true
    
    // MARK: - Resource
    
    /// The actual dictionary reader (nil when unloaded)
    private var _reader: MDictReader?
    
    /// Whether the dictionary is currently loaded
    public var isLoaded: Bool { _reader != nil }
    
    // MARK: - Caching
    
    // TODO: Implement LRU cache as an actor for thread-safe concurrent access
    // private let cache = LRUCacheActor<MDictWordKey, MDictWordEntry>(capacity: 50)
    
    // MARK: - Initialization
    
    /// Create a dictionary ViewModel from MDX path
    /// Only loads metadata, not full dictionary
    public nonisolated init(path: String) {
        self.path = path
        self.id = Self.generateId(from: path)
        
        // Note: metadata loading moved to an async call since we're nonisolated here
        // Will be populated on first load or via loadMetadata()
    }
    
    private nonisolated static func generateId(from path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }
    
    // MARK: - Lifecycle
    
    /// Load the dictionary asynchronously
    /// Heavy IO runs on background thread, state updates on MainActor
    public func load() async throws {
        guard state == .unloaded || state.isError else { return }
        
        state = .loading
        
        do {
            // Heavy IO on background thread via nonisolated function
            let reader = try await loadReaderInBackground(path: path)
            
            // Back on MainActor - update state
            self._reader = reader
            self.metadata = reader.metadata
            self.state = .loaded
        } catch {
            self.state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Unload the dictionary to free memory
    public func unload() {
        _reader = nil
        state = .unloaded
    }
    
    /// Load only metadata (fast, header only)
    public func loadMetadata() async {
        if metadata == nil {
            self.metadata = await loadMetadataInBackground(path: path)
        }
    }
    
    // MARK: - Lookup API
    
    /// Look up a word
    /// - Parameter key: The word to look up
    /// - Returns: Entry with article content, or nil if not found
    public func lookup(_ key: MDictWordKey) -> MDictWordEntry? {
        _reader?.lookup(key)
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
    public func prev(_ entry: MDictWordEntry) -> MDictWordEntry? {
        _reader?[entry.index - 1]
    }
    
    /// Get next entry
    public func next(_ entry: MDictWordEntry) -> MDictWordEntry? {
        _reader?[entry.index + 1]
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

// MARK: - Background Loading (nonisolated)

/// Load MDictReader on background thread
/// This function is nonisolated, so calling it from MainActor will automatically
/// suspend and run on the cooperative thread pool (similar to Dispatchers.IO)
private nonisolated func loadReaderInBackground(path: String) async throws -> MDictReader {
    try MDictReader(path: path)
}

/// Load metadata only (fast, header parsing)
private nonisolated func loadMetadataInBackground(path: String) async -> MDictMetadata? {
    MDictReader.loadMetadata(from: path)
}

// MARK: - State Helpers

extension MDictLoadState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - Equatable & Hashable

extension MDict: Equatable {
    public nonisolated static func == (lhs: MDict, rhs: MDict) -> Bool {
        lhs.id == rhs.id
    }
}

extension MDict: Hashable {
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
