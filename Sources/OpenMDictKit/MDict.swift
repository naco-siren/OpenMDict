import Foundation
import Combine
@_exported import OpenMDict

// MARK: - Load State

/// Dictionary loading state
public enum MDictLoadState: Sendable, Equatable {
    case unloaded
    case loading
    case metadataLoaded
    case loaded
    case error(String)
    
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - Background Load Results

/// Result from full dictionary load (includes extraction done in background)
private struct MDictLoadResult: Sendable {
    let reader: MDictReader
    let cleanedDescription: String?
    let extractedTitle: String?
    let extractedAuthor: String?
}

/// Result from metadata-only load (includes extraction done in background)
private struct MDictMetadataResult: Sendable {
    let metadata: MDictMetadata?
    let cleanedDescription: String?
    let extractedTitle: String?
    let extractedAuthor: String?
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
    
    /// Unique identifier
    /// - For bundled: derived from filename (e.g., "MyDict")
    /// - For imported: SHA256 hash of MDX header
    public nonisolated let id: String
    
    /// File path to the MDX
    public nonisolated let path: String
    
    /// Explicit MDD file paths (for imported dictionaries with non-standard structure)
    /// When set, ResourceProvider uses these instead of auto-discovery.
    public var mddPaths: [String]?
    
    // MARK: - Injected Properties (set by app layer)
    
    /// User-customized display name (from manifest)
    /// Set by DictionaryService after creating MDict instance.
    public var userDisplayName: String?
    
    /// Original filename when imported (e.g., "MyDict.mdx")
    /// Used as fallback when title is empty. Set by DictionaryService.
    public var originalFileName: String?
    
    // MARK: - Published State
    
    /// Lightweight metadata (available after loadMetadata or load)
    @Published public private(set) var metadata: MDictMetadata?
    
    /// Current loading state
    @Published public private(set) var state: MDictLoadState = .unloaded
    
    /// Whether this dictionary is enabled for searching
    public var isEnabled: Bool = true
    
    // MARK: - Parsed Description (populated during background load)
    
    /// Cleaned description (HTML stripped, metadata removed)
    /// Populated during load/loadMetadata - access is O(1), no computation.
    public private(set) var cleanedDescription: String?
    
    /// Extracted title from description (may differ from metadata.title)
    /// Populated during load/loadMetadata - access is O(1), no computation.
    public private(set) var extractedTitle: String?
    
    /// Extracted author from description
    /// Populated during load/loadMetadata - access is O(1), no computation.
    public private(set) var extractedAuthor: String?
    
    // MARK: - Display Titles (computed, but cheap - just property access)
    
    /// Best available title for UI display
    /// Priority: userDisplayName > extractedTitle > metadata.title > originalFileName (no ext) > id
    public var displayTitle: String {
        if let name = userDisplayName, !name.isEmpty { return name }
        if let extracted = extractedTitle { return extracted }
        if let title = metadata?.title { return title }
        if let original = originalFileName {
            return (original as NSString).deletingPathExtension
        }
        return id
    }
    
    /// Title for logging (stable, not affected by extraction or user preference)
    /// Priority: metadata.title > id
    public var loggingTitle: String {
        metadata?.title ?? id
    }
    
    // MARK: - Reader
    
    /// The actual dictionary reader (nil when unloaded)
    private var _reader: MDictReader?
    
    /// Whether the dictionary is currently loaded
    public var isLoaded: Bool { _reader != nil }
    
    // MARK: - Initialization
    
    /// Create a dictionary ViewModel from MDX path
    /// ID is derived from filename (e.g., "MyDict" from "MyDict.mdx")
    public nonisolated init(path: String) {
        self.path = path
        self.id = Self.extractId(from: path)
    }
    
    /// Create a dictionary ViewModel with explicit ID
    /// Use this for imported dictionaries where ID should be the storage directory name (SHA256)
    /// rather than the filename (which is always "0.mdx")
    public nonisolated init(path: String, id: String) {
        self.path = path
        self.id = id
        self.mddPaths = nil
    }
    
    /// Create a dictionary ViewModel with explicit ID and MDD paths
    /// Use this for imported dictionaries where MDDs are in a different directory
    public init(path: String, id: String, mddPaths: [String]) {
        self.path = path
        self.id = id
        self.mddPaths = mddPaths
    }
    
    private nonisolated static func extractId(from path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }
    
    // MARK: - Lifecycle
    
    /// Load the dictionary asynchronously (full load with keywords)
    /// Heavy IO + extraction runs on background thread, state updates on MainActor
    public func load() async throws {
        guard state == .unloaded || state == .metadataLoaded || state.isError else { return }

        if state != .metadataLoaded {
            state = .loading
        }
        
        do {
            // Heavy IO + extraction on background thread
            let result = try await performFullLoad(path: path, mddPaths: mddPaths)
            
            // Back on MainActor - update state
            self._reader = result.reader
            self.metadata = result.reader.metadata
            self.cleanedDescription = result.cleanedDescription
            self.extractedTitle = result.extractedTitle
            self.extractedAuthor = result.extractedAuthor
            self.state = .loaded
        } catch {
            self.state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Load only metadata (fast, header only)
    /// Extraction still happens in background.
    public func loadMetadata() async {
        guard state == .unloaded else { return }
        
        // Background load + extraction
        let result = await performMetadataLoad(path: path)
        
        self.metadata = result.metadata
        self.cleanedDescription = result.cleanedDescription
        self.extractedTitle = result.extractedTitle
        self.extractedAuthor = result.extractedAuthor
        self.state = .metadataLoaded
    }
    
    /// Unload the dictionary to free memory
    public func unload() {
        _reader = nil
        state = .unloaded
        // Keep metadata and extracted info - they're small
    }
    
    /// Reload resources with updated MDD paths
    /// Call this after adding/removing MDD files to refresh the ResourceProvider.
    /// Dictionary must be loaded.
    ///
    /// - Parameter newMddPaths: Updated MDD file paths
    public func reloadResources(mddPaths newMddPaths: [String]) {
        guard let reader = _reader else {
            print("⚠️ Cannot reload resources: dictionary not loaded")
            return
        }
        
        self.mddPaths = newMddPaths
        reader.reloadResources(mddPaths: newMddPaths)
        print("📦 Reloaded resources for \(loggingTitle): \(newMddPaths.count) MDD files")
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

// MARK: - MDict + Lookupable

extension MDict: @MainActor Lookupable {
    
    /// Reactive lookup - waits for dictionary to load, then emits results once
    public func lookupPublisher(prefix: String, limit: Int = 50) -> AnyPublisher<[WordSearchResult], Never> {
        let dictId = self.id
        
        return $state
            .first { $0 == .loaded || $0.isError }
            .map { [weak self] currentState -> [WordSearchResult] in
                guard currentState == .loaded,
                      let self = self else { return [] }
                
                let keys = self.search(prefix: prefix, limit: limit)
                let dictName = self.displayTitle
                
                return keys.map { key in
                    WordSearchResult(word: key, dictId: dictId, dictName: dictName)
                }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}

// MARK: - Background Loading (nonisolated)

/// Full load: parse MDX + extract description info
/// Runs entirely on background thread.
@concurrent
private nonisolated func performFullLoad(path: String, mddPaths: [String]?) async throws -> MDictLoadResult {
    let reader: MDictReader
    if let mddPaths = mddPaths, !mddPaths.isEmpty {
        reader = try MDictReader(path: path, mddPaths: mddPaths)
    } else {
        reader = try MDictReader(path: path)
    }
    
    // Piggyback extraction while still on background thread
    let desc = reader.metadata.description
    let (cleaned, title, author) = extractDescriptionInfo(desc)
    
    return MDictLoadResult(
        reader: reader,
        cleanedDescription: cleaned,
        extractedTitle: title,
        extractedAuthor: author
    )
}

/// Metadata-only load: parse header + extract description info
/// Runs entirely on background thread.
@concurrent
private nonisolated func performMetadataLoad(path: String) async -> MDictMetadataResult {
    guard let metadata = MDictReader.loadMetadata(from: path) else {
        return MDictMetadataResult(
            metadata: nil,
            cleanedDescription: nil,
            extractedTitle: nil,
            extractedAuthor: nil
        )
    }
    
    // Piggyback extraction while still on background thread
    let desc = metadata.description
    let (cleaned, title, author) = extractDescriptionInfo(desc)
    
    return MDictMetadataResult(
        metadata: metadata,
        cleanedDescription: cleaned,
        extractedTitle: title,
        extractedAuthor: author
    )
}

/// Extract cleaned description, title, and author from description HTML
/// Called from background thread during load.
private nonisolated func extractDescriptionInfo(_ description: String) -> (String?, String?, String?) {
    guard !description.isEmpty else {
        return (nil, nil, nil)
    }
    
    let cleaned = MDictDescriptionParser.cleanDescription(description)
    let title = MDictDescriptionParser.tryExtractTitle(from: description)
    let author = MDictDescriptionParser.tryExtractAuthor(from: description)
    
    return (cleaned, title, author)
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
