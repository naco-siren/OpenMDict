//
//  DictionaryManifest.swift
//  OpenMDictKit
//
//  Per-dictionary resource manifest (`<dict-id>/manifest.json`).
//  Describes the MDX, MDD, CSS, JS files inside a single dictionary folder.
//
//  Note: The root DictionaryManifest struct and DictionaryEntry have been
//  removed — dictionary metadata is now persisted in CoreData
//  (DictionaryMetadataRecord / DictMetadataService).
//

import Foundation

// MARK: - DictManifest (Per-dictionary detailed manifest)

/// Detailed resource manifest for a single dictionary.
/// Stored in `<dict-id>/manifest.json` within Library/Dictionaries/
public struct DictManifest: Codable {
    /// Dictionary ID (same as folder name, MDX header SHA256)
    public let id: String
    
    /// MDX file entry (exactly one)
    public let mdx: MDXEntry
    
    /// MDD resource files (0-N)
    public var mdd: [ResourceEntry]
    
    /// Custom CSS files (0-N)
    public var css: [ResourceEntry]
    
    /// Custom JS files (0-N)
    public var js: [ResourceEntry]
    
    public init(
        id: String,
        mdx: MDXEntry,
        mdd: [ResourceEntry] = [],
        css: [ResourceEntry] = [],
        js: [ResourceEntry] = []
    ) {
        self.id = id
        self.mdx = mdx
        self.mdd = mdd
        self.css = css
        self.js = js
    }
    
    /// Total size of all files in bytes
    public var totalSizeBytes: Int64 {
        mdx.sizeBytes
        + mdd.reduce(0) { $0 + $1.sizeBytes }
        + css.reduce(0) { $0 + $1.sizeBytes }
        + js.reduce(0) { $0 + $1.sizeBytes }
    }
    
    /// Total size in KB (for metadata sync)
    public var totalSizeKB: Int64 {
        totalSizeBytes / 1024
    }
}

// MARK: - DictManifest Entries

extension DictManifest {
    
    /// MDX file entry (read-only, cannot be removed)
    public struct MDXEntry: Codable {
        /// Original filename (e.g., "MyDict.mdx")
        public let fileName: String
        
        /// File size in bytes
        public let sizeBytes: Int64
        
        /// Import timestamp
        public let importedAt: Date
        
        public init(fileName: String, sizeBytes: Int64, importedAt: Date = Date()) {
            self.fileName = fileName
            self.sizeBytes = sizeBytes
            self.importedAt = importedAt
        }
    }
    
    /// Resource file entry (MDD/CSS/JS)
    public struct ResourceEntry: Codable, Identifiable, Equatable {
        /// Unique ID within type (same as fileName)
        public var id: String { fileName }
        
        /// Original filename (e.g., "MyDict.mdd", "custom.css")
        public let fileName: String
        
        /// SHA256 hash of file content (for duplicate detection)
        public let hash: String
        
        /// File size in bytes
        public let sizeBytes: Int64
        
        /// Import timestamp
        public let importedAt: Date
        
        public init(fileName: String, hash: String, sizeBytes: Int64, importedAt: Date = Date()) {
            self.fileName = fileName
            self.hash = hash
            self.sizeBytes = sizeBytes
            self.importedAt = importedAt
        }
    }
}

// MARK: - DictManifest Query Helpers

extension DictManifest {
    
    /// Find MDD entry by filename
    public func mddEntry(fileName: String) -> ResourceEntry? {
        mdd.first { $0.fileName == fileName }
    }
    
    /// Find MDD entry by hash
    public func mddEntry(hash: String) -> ResourceEntry? {
        mdd.first { $0.hash == hash }
    }
    
    /// Find CSS entry by filename
    public func cssEntry(fileName: String) -> ResourceEntry? {
        css.first { $0.fileName == fileName }
    }
    
    /// Find CSS entry by hash
    public func cssEntry(hash: String) -> ResourceEntry? {
        css.first { $0.hash == hash }
    }
    
    /// Find JS entry by filename
    public func jsEntry(fileName: String) -> ResourceEntry? {
        js.first { $0.fileName == fileName }
    }
    
    /// Find JS entry by hash
    public func jsEntry(hash: String) -> ResourceEntry? {
        js.first { $0.hash == hash }
    }
    
    /// All MDD file paths (relative to dict directory)
    public var mddPaths: [String] {
        mdd.map { "mdd/\($0.fileName)" }
    }
    
    /// All CSS file paths (relative to dict directory)
    public var cssPaths: [String] {
        css.map { "css/\($0.fileName)" }
    }
    
    /// All JS file paths (relative to dict directory)
    public var jsPaths: [String] {
        js.map { "js/\($0.fileName)" }
    }
}

// MARK: - DictManifest Mutation Helpers

extension DictManifest {
    
    /// Add MDD entry (returns false if hash already exists)
    @discardableResult
    public mutating func addMDD(_ entry: ResourceEntry) -> Bool {
        guard mddEntry(hash: entry.hash) == nil else { return false }
        mdd.append(entry)
        return true
    }
    
    /// Remove MDD entry by filename
    @discardableResult
    public mutating func removeMDD(fileName: String) -> Bool {
        let count = mdd.count
        mdd.removeAll { $0.fileName == fileName }
        return mdd.count < count
    }
    
    /// Add CSS entry (returns false if hash already exists)
    @discardableResult
    public mutating func addCSS(_ entry: ResourceEntry) -> Bool {
        guard cssEntry(hash: entry.hash) == nil else { return false }
        css.append(entry)
        return true
    }
    
    /// Remove CSS entry by filename
    @discardableResult
    public mutating func removeCSS(fileName: String) -> Bool {
        let count = css.count
        css.removeAll { $0.fileName == fileName }
        return css.count < count
    }
    
    /// Add JS entry (returns false if hash already exists)
    @discardableResult
    public mutating func addJS(_ entry: ResourceEntry) -> Bool {
        guard jsEntry(hash: entry.hash) == nil else { return false }
        js.append(entry)
        return true
    }
    
    /// Remove JS entry by filename
    @discardableResult
    public mutating func removeJS(fileName: String) -> Bool {
        let count = js.count
        js.removeAll { $0.fileName == fileName }
        return js.count < count
    }
}
