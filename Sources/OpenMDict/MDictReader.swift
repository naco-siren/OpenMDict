import Foundation
import CryptoKit

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
    /// Title from MDX header. nil if the header contains only a placeholder.
    public let title: String?
    public let description: String
    /// Entry count. nil for header-only loads (call full load to get actual count).
    public let entryCount: Int?
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
    
    /// SHA256 hash of the MDX header bytes.
    /// Used as the dictionary's unique identifier for storage and duplicate detection.
    /// Note: This is specifically SHA256, not MD5 or any other hash algorithm.
    public let headerSHA256: String?
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
    public private(set) var resources: ResourceProvider
    
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
        let title = Self.resolveTitle(parser.info.title.htmlEntityDecoded)
        
        // Compute SHA256 of header for duplicate detection
        // Note: We read the header again here, but it's a small overhead compared to full parsing
        let headerSHA256 = Self.computeHeaderSHA256(path: path)
        
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
            hasMDD: hasMDD,
            headerSHA256: headerSHA256
        )
    }
    
    /// Load a dictionary from an MDX file with explicit MDD paths
    /// Use this when MDD files are not in the same directory as MDX
    ///
    /// - Parameters:
    ///   - path: Path to the .mdx file
    ///   - mddPaths: Explicit paths to MDD files
    /// - Throws: MDictError if the file cannot be opened or parsed
    public init(path: String, mddPaths: [String]) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MDictError.fileNotFound(path)
        }
        
        self.parser = try MDXParser(path: path)
        
        // Use explicit MDD paths instead of auto-discovery
        let mdxURL = URL(fileURLWithPath: path)
        let baseDirectory = mdxURL.deletingLastPathComponent().path
        self.resources = ResourceProvider(mddPaths: mddPaths, baseDirectory: baseDirectory)

        // Build metadata
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let hasMDD = !mddPaths.isEmpty || Self.checkMDDExists(mdxPath: path)
        let title = Self.resolveTitle(parser.info.title.htmlEntityDecoded)
        let headerSHA256 = Self.computeHeaderSHA256(path: path)
        
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
            hasMDD: hasMDD,
            headerSHA256: headerSHA256
        )
    }
    
    /// Reload the resource provider with new MDD paths
    /// Call this after adding/removing MDD files
    ///
    /// - Parameter mddPaths: New MDD paths (empty array to clear all)
    public func reloadResources(mddPaths: [String]) {
        let baseDirectory = (metadata.path as NSString).deletingLastPathComponent
        self.resources = ResourceProvider(mddPaths: mddPaths, baseDirectory: baseDirectory)
    }
    
    // MARK: - Static Metadata Loading
    
    /// Load only metadata without full parsing (fast)
    /// Useful for displaying dictionary list without loading all keywords
    ///
    /// - Parameter path: Path to the .mdx file
    /// - Returns: Metadata or nil if file cannot be read
    public static func loadMetadata(from path: String) -> MDictMetadata? {
        guard let result = MDXParser.readHeaderOnlyWithData(path: path) else {
            return nil
        }
        
        let info = result.info
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let hasMDD = checkMDDExists(mdxPath: path)
        let title = resolveTitle(info.title.htmlEntityDecoded)
        
        // Compute SHA256 hash of header bytes for duplicate detection
        // Using SHA256 (not MD5 or other algorithms) for better collision resistance
        let headerSHA256 = sha256Hash(of: result.headerData)
        
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
            hasMDD: hasMDD,
            headerSHA256: headerSHA256
        )
    }
    
    // MARK: - SHA256 Hash Helpers
    
    /// Compute SHA256 hash of MDX header bytes
    /// Used for duplicate detection when importing dictionaries
    private static func computeHeaderSHA256(path: String) -> String? {
        guard let result = MDXParser.readHeaderOnlyWithData(path: path) else {
            return nil
        }
        return sha256Hash(of: result.headerData)
    }
    
    /// Compute SHA256 hash of data and return as lowercase hex string
    private static func sha256Hash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Private Helpers
    
    /// Resolve title, falling back to filename if title is a placeholder
    private static func resolveTitle(_ rawTitle: String) -> String? {
        let placeholders = [
            "Title (No HTML code allowed)",
            "Title",
            ""
        ]
        
        let trimmed = rawTitle.trimmingCharacters(in: .whitespaces)
        
        if placeholders.contains(trimmed) {
            return nil
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
