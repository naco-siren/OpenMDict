import Foundation

// MARK: - Public Types

/// Word key (headword) for lookup
public typealias MDictWordKey = String

/// Article content from dictionary entry
public struct MDictWordArticle: Sendable {
    /// Raw HTML definition content
    public let html: String
    
    // TODO: Future expansion for embedded resources
    // public var css: MDictResource?
    // public var images: [String: MDictResource]?
    // public var audio: [String: MDictResource]?
    
    public init(html: String) {
        self.html = html
    }
}

/// A word entry (key-article pair) from the dictionary
public struct MDictWordEntry: Sendable {
    /// The headword/keyword
    public let key: MDictWordKey
    
    /// The article content
    public let article: MDictWordArticle
    
    /// Internal index for navigation (not exposed to users)
    public let index: Int
    
    internal init(key: MDictWordKey, article: MDictWordArticle, index: Int) {
        self.key = key
        self.article = article
        self.index = index
    }
}

/// Lightweight dictionary metadata (can be loaded without full parsing)
public struct MDictMetadata: Sendable {
    public let title: String
    public let description: String
    public let entryCount: Int
    public let format: String
    public let encoding: String
    public let engineVersion: String
    public let creationDate: String
    public let isEncrypted: Bool
    public let isCaseSensitive: Bool
    
    /// File path of the MDX
    public let path: String
    
    /// File size in bytes
    public let fileSize: Int64
    
    /// Whether associated MDD files exist
    public let hasMDD: Bool
}

// MARK: - Errors

public enum MDictError: Error, CustomStringConvertible {
    case invalidHeader(String)
    case unsupportedVersion(String)
    case unsupportedEncryption
    case decompressionFailed(String)
    case invalidFormat(String)
    case fileNotFound(String)
    
    public var description: String {
        switch self {
        case .invalidHeader(let msg): return "Invalid header: \(msg)"
        case .unsupportedVersion(let v): return "Unsupported version: \(v)"
        case .unsupportedEncryption: return "Record encryption (Encrypted=1,3) is not supported"
        case .decompressionFailed(let msg): return "Decompression failed: \(msg)"
        case .invalidFormat(let msg): return "Invalid format: \(msg)"
        case .fileNotFound(let path): return "File not found: \(path)"
        }
    }
}

// MARK: - MDictReader

/// MDict dictionary reader (Engine layer facade)
/// Combines MDX parsing and MDD resource access
///
/// Usage:
/// ```swift
/// let reader = try MDictReader(path: "MyDict.mdx")
/// if let entry = reader.lookup("hello") {
///     print(entry.article.html)
/// }
/// let css = reader.resource(for: "style.css")
/// ```
public final class MDictReader: @unchecked Sendable {
    
    // MARK: - Properties
    
    /// Internal MDX parser
    internal let parser: MDXParser
    
    /// Resource provider (MDD + external files)
    public let resources: ResourceProvider
    
    /// Dictionary metadata
    public let metadata: MDictMetadata
    
    /// Total number of entries
    public var entryCount: Int { parser.entryCount }
    
    /// All word keys (for iteration/display)
    public var allKeys: [MDictWordKey] { parser.allKeywords }
    
    // MARK: - Initialization
    
    /// Load a dictionary from an MDX file
    /// Automatically discovers associated MDD files and resources
    ///
    /// - Parameter path: Path to the .mdx file
    /// - Throws: MDictError if the file cannot be opened or parsed
    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MDictError.fileNotFound(path)
        }
        
        self.parser = try MDXParser(path: path)
        self.resources = ResourceProvider(mdxPath: path)
        
        // Build metadata
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let hasMDD = Self.checkMDDExists(mdxPath: path)
        let title = Self.resolveTitle(parser.info.title.htmlEntityDecoded, path: path)
        
        self.metadata = MDictMetadata(
            title: title,
            description: parser.info.description.htmlEntityDecoded,
            entryCount: parser.entryCount,
            format: parser.info.format,
            encoding: parser.info.encoding,
            engineVersion: parser.info.engineVersion,
            creationDate: parser.info.creationDate,
            isEncrypted: parser.info.isEncrypted,
            isCaseSensitive: parser.info.isCaseSensitive,
            path: path,
            fileSize: fileSize,
            hasMDD: hasMDD
        )
    }
    
    // MARK: - Static Metadata Loading
    
    /// Load only metadata without full parsing (fast)
    /// Useful for displaying dictionary list without loading all keywords
    ///
    /// - Parameter path: Path to the .mdx file
    /// - Returns: Metadata or nil if file cannot be read
    public static func loadMetadata(from path: String) -> MDictMetadata? {
        guard let info = MDXParser.readHeaderOnly(path: path) else {
            return nil
        }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let hasMDD = checkMDDExists(mdxPath: path)
        let title = resolveTitle(info.title.htmlEntityDecoded, path: path)
        
        return MDictMetadata(
            title: title,
            description: info.description.htmlEntityDecoded,
            entryCount: info.entryCount,
            format: info.format,
            encoding: info.encoding,
            engineVersion: info.engineVersion,
            creationDate: info.creationDate,
            isEncrypted: info.isEncrypted,
            isCaseSensitive: info.isCaseSensitive,
            path: path,
            fileSize: fileSize,
            hasMDD: hasMDD
        )
    }
    
    // MARK: - Private Helpers
    
    /// Resolve title, falling back to filename if title is a placeholder
    private static func resolveTitle(_ rawTitle: String, path: String) -> String {
        let placeholders = [
            "Title (No HTML code allowed)",
            "Title",
            ""
        ]
        
        let trimmed = rawTitle.trimmingCharacters(in: .whitespaces)
        
        if placeholders.contains(trimmed) {
            // Use filename without extension
            return (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".mdx", with: "", options: .caseInsensitive)
        }
        
        return rawTitle
    }
    
    private static func checkMDDExists(mdxPath: String) -> Bool {
        let basePath = (mdxPath as NSString).deletingPathExtension
        let mddPath = basePath + ".mdd"
        return FileManager.default.fileExists(atPath: mddPath)
    }
    
    // MARK: - Lookup API
    
    /// Look up a word by key
    /// - Parameter key: The word to look up
    /// - Returns: Entry with article content, or nil if not found
    public func lookup(_ key: MDictWordKey) -> MDictWordEntry? {
        guard let (originalKey, definition, index) = parser.lookupWithIndex(key) else {
            return nil
        }
        return MDictWordEntry(
            key: originalKey,  // Use original key from dictionary
            article: MDictWordArticle(html: definition),
            index: index
        )
    }
    
    /// Access entry by index
    /// - Parameter index: Index in keyword list
    /// - Returns: Entry or nil if out of bounds
    public subscript(index: Int) -> MDictWordEntry? {
        guard let (keyword, definition) = parser.entryAt(index) else {
            return nil
        }
        return MDictWordEntry(
            key: keyword,
            article: MDictWordArticle(html: definition),
            index: index
        )
    }
    
    // MARK: - Search API
    
    /// Search for word keys with a prefix
    /// - Parameters:
    ///   - prefix: Prefix to match
    ///   - limit: Maximum results (default 20)
    /// - Returns: Array of matching word keys
    public func search(prefix: String, limit: Int = 20) -> [MDictWordKey] {
        parser.search(prefix: prefix, limit: limit)
    }
    
    /// Get suggestions for a misspelled word
    /// - Parameters:
    ///   - key: The word to find suggestions for
    ///   - limit: Maximum suggestions
    /// - Returns: Array of similar word keys
    public func suggestions(for key: MDictWordKey, limit: Int = 5) -> [MDictWordKey] {
        parser.suggestions(for: key, limit: limit)
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
    
    // MARK: - Debug API
    
    /// Read raw header XML for debugging
    /// - Parameter path: Path to the .mdx file
    /// - Returns: Tuple of (encoding description, raw XML string) or nil if file cannot be read
    public static func readRawHeader(from path: String) -> (encoding: String, xml: String)? {
        guard let reader = try? BinaryReader(path: path) else { return nil }
        
        do {
            let headerLen = try reader.readUInt32BE()
            let headerData = try reader.readBytes(Int(headerLen))
            
            let headerStr: String
            let encoding: String
            
            if headerData.count >= 2 && headerData[0] == 0xFF && headerData[1] == 0xFE {
                headerStr = String(data: Data(headerData), encoding: .utf16LittleEndian) ?? ""
                encoding = "UTF-16LE (BOM detected)"
            } else if headerData.count >= 2 && headerData.suffix(2) == Data([0x00, 0x00]) {
                headerStr = String(data: Data(headerData.dropLast(2)), encoding: .utf16LittleEndian) ?? ""
                encoding = "UTF-16LE (null-terminated)"
            } else {
                headerStr = String(data: Data(headerData), encoding: .utf8) ?? ""
                encoding = "UTF-8"
            }
            
            return (encoding, headerStr)
        } catch {
            return nil
        }
    }
}
