import Foundation

// MARK: - Resource Provider

/// Provides resources (CSS, images, audio) for dictionary entries
/// Supports:
/// - .mdd resource files
/// - External files in the same directory as the .mdx
public final class ResourceProvider {
    
    // MARK: - Properties
    
    private let mddReaders: [MDDParser]
    private let baseDirectory: URL
    private var cache: [String: Data] = [:]
    private let useCache: Bool
    
    /// Number of resources available in MDD files
    public var mddResourceCount: Int {
        mddReaders.reduce(0) { $0 + $1.resourceCount }
    }
    
    // MARK: - Initialization
    
    /// Initialize with MDX path
    /// Automatically discovers:
    /// - Same-name .mdd file
    /// - Additional numbered .mdd files (e.g., dict.1.mdd, dict.2.mdd)
    /// - External files in the same directory
    ///
    /// - Parameters:
    ///   - mdxPath: Path to the .mdx file
    ///   - useCache: Whether to cache loaded resources (default: true)
    public init(mdxPath: String, useCache: Bool = true) {
        self.useCache = useCache
        
        let mdxURL = URL(fileURLWithPath: mdxPath)
        self.baseDirectory = mdxURL.deletingLastPathComponent()
        let baseName = mdxURL.deletingPathExtension().lastPathComponent
        
        // Discover MDD files
        var readers: [MDDParser] = []
        
        // 1. Same-name .mdd
        let primaryMDD = baseDirectory.appendingPathComponent(baseName + ".mdd")
        if let reader = try? MDDParser(path: primaryMDD.path) {
            readers.append(reader)
        }
        
        // 2. Numbered .mdd files (dict.1.mdd, dict.2.mdd, etc.)
        for i in 1...99 {
            let numberedMDD = baseDirectory.appendingPathComponent("\(baseName).\(i).mdd")
            if FileManager.default.fileExists(atPath: numberedMDD.path) {
                if let reader = try? MDDParser(path: numberedMDD.path) {
                    readers.append(reader)
                }
            } else {
                break  // Stop at first missing number
            }
        }
        
        self.mddReaders = readers
    }
    
    /// Initialize with explicit MDD paths
    public init(mddPaths: [String], baseDirectory: String, useCache: Bool = true) {
        self.useCache = useCache
        self.baseDirectory = URL(fileURLWithPath: baseDirectory)
        
        var readers: [MDDParser] = []
        for path in mddPaths {
            if let reader = try? MDDParser(path: path) {
                readers.append(reader)
            }
        }
        self.mddReaders = readers
    }
    
    // MARK: - Public API
    
    /// Get a resource by path
    /// - Parameter path: Resource path (e.g., "mydict.css", "/img/logo.png")
    /// - Returns: Resource data or nil if not found
    public func resource(for path: String) -> Data? {
        // Check cache first
        let normalizedPath = normalizePath(path)
        if useCache, let cached = cache[normalizedPath] {
            return cached
        }
        
        // Try MDD files first
        for reader in mddReaders {
            if let data = reader.lookup(path) {
                if useCache { cache[normalizedPath] = data }
                return data
            }
        }
        
        // Fall back to external file
        if let data = loadExternalFile(path: path) {
            if useCache { cache[normalizedPath] = data }
            return data
        }
        
        return nil
    }
    
    /// Subscript access
    public subscript(path: String) -> Data? {
        resource(for: path)
    }
    
    /// Check if a resource exists
    public func contains(_ path: String) -> Bool {
        // Check MDD files
        for reader in mddReaders {
            if reader.contains(path) {
                return true
            }
        }
        
        // Check external file
        let fileURL = resolveExternalPath(path)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// Get resource as string (for CSS, JS, etc.)
    public func string(for path: String, encoding: String.Encoding = .utf8) -> String? {
        guard let data = resource(for: path) else { return nil }
        return String(data: data, encoding: encoding)
    }
    
    /// Clear the cache
    public func clearCache() {
        cache.removeAll()
    }
    
    /// List all available resources in MDD files
    public var allMDDPaths: [String] {
        mddReaders.flatMap { $0.allPaths }
    }
    
    // MARK: - Private
    
    private func normalizePath(_ path: String) -> String {
        path.lowercased()
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    private func resolveExternalPath(_ path: String) -> URL {
        let normalized = normalizePath(path)
        return baseDirectory.appendingPathComponent(normalized)
    }
    
    private func loadExternalFile(path: String) -> Data? {
        let fileURL = resolveExternalPath(path)
        return try? Data(contentsOf: fileURL)
    }
}

// MARK: - MIME Type Helper

extension ResourceProvider {
    
    /// Get MIME type for a resource path
    public static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        
        switch ext {
        // Text
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        case "json": return "application/json"
        case "txt": return "text/plain"
            
        // Images
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
            
        // Audio
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "m4a", "aac": return "audio/mp4"
        case "spx": return "audio/speex"
            
        // Fonts
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "eot": return "application/vnd.ms-fontobject"
            
        // Other
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
            
        default: return "application/octet-stream"
        }
    }
}
