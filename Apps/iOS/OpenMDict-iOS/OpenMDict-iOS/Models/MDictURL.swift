//
//  MDictURL.swift
//  OpenMDict-iOS
//
//  Parses and normalizes MDict-specific URL schemes (sound://, entry://, etc.)
//

import Foundation

/// Represents a parsed MDict URL
struct MDictURL {
    
    /// URL scheme types used in MDict dictionaries
    enum Scheme: String {
        case sound      // sound://uk/word.mp3 - pronunciation audio
        case entry      // entry://word - cross-reference link
        case mdict      // mdict://dictId/resource - internal resource (our custom scheme)
        case unknown
    }
    
    let scheme: Scheme
    let originalURL: URL
    
    /// The resource path, normalized for MDict lookup
    /// For sound://uk/file.mp3 → "uk/file.mp3"
    /// For entry://word → "word"
    let resourcePath: String
    
    /// The resource path in MDD format (with backslashes)
    /// For sound://uk/file.mp3 → "\uk\file.mp3"
    var mddPath: String {
        "\\" + resourcePath.replacingOccurrences(of: "/", with: "\\")
    }
    
    // MARK: - Initialization
    
    init?(_ url: URL) {
        self.originalURL = url
        
        guard let schemeString = url.scheme else { return nil }
        
        switch schemeString.lowercased() {
        case "sound":
            self.scheme = .sound
            self.resourcePath = Self.parseSoundURL(url)
            
        case "entry":
            self.scheme = .entry
            self.resourcePath = Self.parseEntryURL(url)
            
        case "mdict":
            self.scheme = .mdict
            self.resourcePath = Self.parseMDictURL(url)
            
        default:
            self.scheme = .unknown
            self.resourcePath = url.path
        }
    }
    
    init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url)
    }
    
    // MARK: - URL Parsing
    
    /// Parse sound:// URL
    /// Format: sound://[subdir/]filename.mp3
    /// Example: sound://uk/word.mp3 → "uk/word.mp3"
    /// The "uk" part becomes url.host, "/word.mp3" becomes url.path
    private static func parseSoundURL(_ url: URL) -> String {
        var components: [String] = []
        
        // Host is the first path segment (e.g., "uk" or "us")
        if let host = url.host, !host.isEmpty {
            components.append(host)
        }
        
        // Path is the rest (e.g., "/word.mp3")
        let path = url.path
        if !path.isEmpty {
            // Remove leading slash
            let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            if !cleanPath.isEmpty {
                components.append(cleanPath)
            }
        }
        
        return components.joined(separator: "/")
    }
    
    /// Parse entry:// URL (cross-reference link)
    /// Format: entry://word or entry://word#anchor
    /// Example: entry://stomach → "stomach"
    private static func parseEntryURL(_ url: URL) -> String {
        // Entry word is in the host
        return url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    /// Parse mdict:// URL (our custom scheme for resources)
    /// Format: mdict://dictId/path/to/resource
    /// Example: mdict://MyDict/mydict.css → "mydict.css"
    private static func parseMDictURL(_ url: URL) -> String {
        // dictId is host, resource path is path
        let path = url.path
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}

// MARK: - Convenience

extension MDictURL {
    
    /// Check if this is an audio URL
    var isAudio: Bool { scheme == .sound }
    
    /// Check if this is a cross-reference link
    var isEntryLink: Bool { scheme == .entry }
    
    /// Get all path variations for MDD lookup
    var pathVariations: [String] {
        [
            resourcePath,                   // uk/word.mp3
            "/" + resourcePath,             // /uk/word.mp3
            mddPath,                        // \uk\word.mp3
        ]
    }
}
