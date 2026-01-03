import Foundation

// MARK: - MDictReader (Facade)

/// Main entry point for MDict dictionaries
/// Combines MDX (definitions) and MDD (resources) access
///
/// Usage:
/// ```swift
/// let dict = try MDictReader(path: "MyDict.mdx")
/// if let entry = dict.lookup("hello") {
///     print(entry.definition)
/// }
/// let css = dict.resource(for: "style.css")
/// ```
public final class MDictReader {
    
    // MARK: - Properties
    
    /// The underlying MDX parser
    public let mdx: MDXParser
    
    /// Resource provider (MDD + external files)
    public let resources: ResourceProvider
    
    /// Dictionary info (delegates to MDXParser)
    public var info: MDictInfo { mdx.info }
    
    /// All keywords
    public var allKeywords: [String] { mdx.allKeywords }
    
    // MARK: - Initialization
    
    /// Load a dictionary from an MDX file
    /// Automatically discovers associated MDD files and resources
    ///
    /// - Parameter path: Path to the .mdx file
    /// - Throws: MDictError if the file cannot be opened or parsed
    public init(path: String) throws {
        self.mdx = try MDXParser(path: path)
        self.resources = ResourceProvider(mdxPath: path)
    }
    
    /// Load with explicit MDD paths
    ///
    /// - Parameters:
    ///   - mdxPath: Path to the .mdx file
    ///   - mddPaths: Explicit paths to .mdd files (optional)
    public init(mdxPath: String, mddPaths: [String]? = nil) throws {
        self.mdx = try MDXParser(path: mdxPath)
        
        if let mddPaths = mddPaths {
            let baseDir = (mdxPath as NSString).deletingLastPathComponent
            self.resources = ResourceProvider(mddPaths: mddPaths, baseDirectory: baseDir)
        } else {
            self.resources = ResourceProvider(mdxPath: mdxPath)
        }
    }
    
    // MARK: - Word Lookup API
    
    /// Look up a word
    /// - Parameter keyword: The word to look up
    /// - Returns: Entry with definition and navigation, or nil if not found
    public func lookup(_ keyword: String) -> MDictEntry? {
        mdx.lookup(keyword)
    }
    
    /// Access entry by index
    public subscript(index: Int) -> MDictEntry? {
        mdx[index]
    }
    
    /// Search for words with a prefix
    /// - Parameters:
    ///   - prefix: Prefix to match
    ///   - limit: Maximum results (default 20)
    /// - Returns: Array of matching keywords
    public func search(prefix: String, limit: Int = 20) -> [String] {
        mdx.search(prefix: prefix, limit: limit)
    }
    
    /// Get suggestions for a misspelled word
    /// - Parameters:
    ///   - keyword: The word to find suggestions for
    ///   - limit: Maximum suggestions
    /// - Returns: Array of similar keywords
    public func suggestions(for keyword: String, limit: Int = 5) -> [String] {
        mdx.suggestions(for: keyword, limit: limit)
    }
    
    // MARK: - Resource API
    
    /// Get a resource (CSS, image, audio, etc.)
    /// - Parameter path: Resource path
    /// - Returns: Resource data or nil
    public func resource(for path: String) -> Data? {
        resources.resource(for: path)
    }
    
    /// Get a resource as string
    /// - Parameters:
    ///   - path: Resource path
    ///   - encoding: String encoding (default UTF-8)
    /// - Returns: Resource as string or nil
    public func resourceString(for path: String, encoding: String.Encoding = .utf8) -> String? {
        resources.string(for: path, encoding: encoding)
    }
    
    /// Check if a resource exists
    public func hasResource(_ path: String) -> Bool {
        resources.contains(path)
    }
    
    /// Number of resources in MDD files
    public var resourceCount: Int {
        resources.mddResourceCount
    }
    
    /// All resource paths from MDD files
    public var allResourcePaths: [String] {
        resources.allMDDPaths
    }
}

// MARK: - Convenience Typealiases

/// Alias for backward compatibility
public typealias DictionaryReader = MDictReader
