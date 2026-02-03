//
//  DictionaryStorageService.swift
//  OpenMDict-iOS
//
//  Manages dictionary file storage in Library/Dictionaries/
//  Handles manifest.json persistence, file import/export, and directory operations.
//
//  ⚠️ INTERNAL SERVICE - Do not call from UI layer!
//  UI should use DictionaryService which wraps these methods
//  and handles in-memory state updates.
//

import Foundation
import OpenMDictKit
import UniformTypeIdentifiers
import CryptoKit

// MARK: - ResourceFile (for UI display)

/// Information about a resource file in storage (for UI display)
struct ResourceFile: Identifiable, Hashable {
    let id: String           // hash value (unique within type)
    let type: ResourceType
    let fileName: String     // e.g., "a1b2c3d4.mdd" (hash prefix for display)
    let fileSize: Int64
    let isRemovable: Bool    // false for MDX
    
    enum ResourceType: String, CaseIterable {
        case mdx, mdd, css, js
        
        var displayName: String {
            switch self {
            case .mdx: return "Dictionary File"
            case .mdd: return "Resource Files"
            case .css: return "Custom Styles"
            case .js: return "Custom Scripts"
            }
        }
        
        var fileExtension: String {
            rawValue
        }
    }
    
    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

// MARK: - ResourceError

/// Errors specific to resource operations
enum ResourceError: LocalizedError {
    case accessDenied(URL)
    case duplicateFile(hash: String)
    case notFound(hash: String)
    case dictionaryNotFound(id: String)
    case hashCalculationFailed(Error)
    case copyFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .accessDenied(let url):
            return "Cannot access file: \(url.lastPathComponent)"
        case .duplicateFile(let hash):
            return "This file already exists (hash: \(hash.prefix(8))...)"
        case .notFound(let hash):
            return "File not found: \(hash.prefix(8))..."
        case .dictionaryNotFound(let id):
            return "Dictionary not found: \(id.prefix(8))..."
        case .hashCalculationFailed(let error):
            return "Failed to calculate file hash: \(error.localizedDescription)"
        case .copyFailed(let error):
            return "Failed to copy file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Associated Files (for import)

/// Files discovered alongside an MDX during import
struct AssociatedFiles {
    var mddFiles: [URL] = []
    var cssFiles: [URL] = []
    var jsFiles: [URL] = []
    var fontFiles: [URL] = []
    
    var isEmpty: Bool {
        mddFiles.isEmpty && cssFiles.isEmpty && jsFiles.isEmpty && fontFiles.isEmpty
    }
    
    var totalCount: Int {
        mddFiles.count + cssFiles.count + jsFiles.count + fontFiles.count
    }
    
    var summary: String {
        var parts: [String] = []
        if !mddFiles.isEmpty { parts.append("\(mddFiles.count) MDD") }
        if !cssFiles.isEmpty { parts.append("\(cssFiles.count) CSS") }
        if !jsFiles.isEmpty { parts.append("\(jsFiles.count) JS") }
        if !fontFiles.isEmpty { parts.append("\(fontFiles.count) fonts") }
        return parts.isEmpty ? "No resources" : parts.joined(separator: ", ")
    }
}

// MARK: - Selected File (for import form)

/// A file selected by user for import (with security-scoped bookmark)
struct SelectedFile {
    let url: URL
    let fileName: String
    let fileSize: Int64
    let bookmarkData: Data?
    var isAutoDiscovered: Bool
    
    init(url: URL, isAutoDiscovered: Bool = false) {
        self.url = url
        self.fileName = url.lastPathComponent
        self.isAutoDiscovered = isAutoDiscovered
        
        // Get file size
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        self.fileSize = Int64(resourceValues?.fileSize ?? 0)
        
        // Create bookmark for later access
        self.bookmarkData = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
    
    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

// MARK: - ImportFormState

/// State model for the dictionary import/edit form
struct ImportFormState {
    var displayName: String = ""
    var mdxFile: SelectedFile?
    var mddFiles: [SelectedFile] = []
    var cssFiles: [SelectedFile] = []
    var jsFiles: [SelectedFile] = []
    var fontFiles: [SelectedFile] = []
    
    var isValid: Bool {
        mdxFile != nil && !displayName.isEmpty
    }
    
    var resourceSummary: String {
        var parts: [String] = []
        if !mddFiles.isEmpty { parts.append("\(mddFiles.count) MDD") }
        if !cssFiles.isEmpty { parts.append("\(cssFiles.count) CSS") }
        if !jsFiles.isEmpty { parts.append("\(jsFiles.count) JS") }
        if !fontFiles.isEmpty { parts.append("\(fontFiles.count) fonts") }
        return parts.isEmpty ? "No resources" : parts.joined(separator: ", ")
    }
    
    /// Create from auto-discovered files (for Quick Import)
    static func fromDiscovery(
        mdxURL: URL,
        associated: AssociatedFiles,
        displayName: String
    ) -> ImportFormState {
        var state = ImportFormState()
        state.displayName = displayName
        state.mdxFile = SelectedFile(url: mdxURL, isAutoDiscovered: false)
        state.mddFiles = associated.mddFiles.map { SelectedFile(url: $0, isAutoDiscovered: true) }
        state.cssFiles = associated.cssFiles.map { SelectedFile(url: $0, isAutoDiscovered: true) }
        state.jsFiles = associated.jsFiles.map { SelectedFile(url: $0, isAutoDiscovered: true) }
        state.fontFiles = associated.fontFiles.map { SelectedFile(url: $0, isAutoDiscovered: true) }
        return state
    }
    
    /// Create from existing manifest entry (for Edit mode)
    /// Note: This uses the old index-based naming for backward compatibility during import
    static func fromManifestEntry(
        _ entry: DictionaryManifest.DictionaryEntry,
        storage: DictionaryStorageService
    ) -> ImportFormState {
        var state = ImportFormState()
        state.displayName = entry.displayName
        
        // MDX file
        let mdxURL = storage.mdxURL(id: entry.id)
        if FileManager.default.fileExists(atPath: mdxURL.path) {
            state.mdxFile = SelectedFile(url: mdxURL, isAutoDiscovered: false)
        }
        
        // For resources, we now iterate directory instead of using count
        // This supports both old index-based and new hash-based naming
        state.mddFiles = storage.listFilesInDirectory(
            storage.mddDirectoryURL(id: entry.id),
            extension: "mdd"
        ).map { SelectedFile(url: $0, isAutoDiscovered: false) }
        
        state.cssFiles = storage.listFilesInDirectory(
            storage.cssDirectoryURL(id: entry.id),
            extension: "css"
        ).map { SelectedFile(url: $0, isAutoDiscovered: false) }
        
        state.jsFiles = storage.listFilesInDirectory(
            storage.jsDirectoryURL(id: entry.id),
            extension: "js"
        ).map { SelectedFile(url: $0, isAutoDiscovered: false) }
        
        return state
    }
}

// MARK: - Import Error

enum DictionaryImportError: LocalizedError {
    case noMDXSelected
    case duplicateImport(existingId: String)
    case fileAccessDenied(URL)
    case copyFailed(URL, Error)
    case manifestSaveFailed(Error)
    case directoryCreationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .noMDXSelected:
            return "No MDX file selected"
        case .duplicateImport:
            return "This dictionary has already been imported"
        case .fileAccessDenied(let url):
            return "Cannot access file: \(url.lastPathComponent)"
        case .copyFailed(let url, let error):
            return "Failed to copy \(url.lastPathComponent): \(error.localizedDescription)"
        case .manifestSaveFailed(let error):
            return "Failed to save manifest: \(error.localizedDescription)"
        case .directoryCreationFailed(let error):
            return "Failed to create directory: \(error.localizedDescription)"
        }
    }
}

// MARK: - DictionaryStorageService

@MainActor
final class DictionaryStorageService {
    
    static let shared = DictionaryStorageService()
    
    // MARK: - Paths
    
    /// Root directory for user dictionaries: Library/Dictionaries/
    var rootDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictionaries", isDirectory: true)
    }
    
    /// Path to manifest.json
    var manifestURL: URL {
        rootDirectoryURL.appendingPathComponent("manifest.json")
    }
    
    /// Directory for a specific dictionary
    func dictionaryDirectoryURL(id: String) -> URL {
        rootDirectoryURL.appendingPathComponent(id, isDirectory: true)
    }
    
    /// MDX file path for a dictionary
    func mdxURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent("0.mdx")
    }
    
    /// MDD directory for a dictionary
    func mddDirectoryURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent("mdd", isDirectory: true)
    }
    
    /// CSS directory for a dictionary
    func cssDirectoryURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent("css", isDirectory: true)
    }
    
    /// JS directory for a dictionary
    func jsDirectoryURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent("js", isDirectory: true)
    }
    
    /// Fonts directory for a dictionary
    func fontsDirectoryURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent("fonts", isDirectory: true)
    }
    
    // MARK: - Manifest
    
    private(set) var manifest: DictionaryManifest = DictionaryManifest()
    
    /// Load manifest from disk
    func loadManifest() {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            print("📄 No manifest.json found, starting fresh")
            return
        }
        
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(DictionaryManifest.self, from: data)
            print("📄 Loaded manifest: \(manifest.dictionaries.count) dictionaries, \(manifest.groups.userGroups.count) user groups")
        } catch {
            print("❌ Failed to load manifest: \(error)")
        }
    }
    
    /// Save manifest to disk
    func saveManifest() throws {
        try ensureRootDirectoryExists()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        print("📄 Saved manifest")
    }
    
    // MARK: - Manifest Mutation
    
    /// Update the default group order
    func updateDefaultOrder(_ order: [String]) {
        manifest.groups.defaultOrder = order
    }
    
    /// Update user groups
    func updateUserGroups(_ groups: [DictionaryManifest.UserGroup]) {
        manifest.groups.userGroups = groups
    }
    
    // MARK: - Directory Management
    
    /// Ensure root directory exists
    private func ensureRootDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootDirectoryURL.path) {
            try fm.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
            print("📁 Created root directory: \(rootDirectoryURL.path)")
        }
    }
    
    /// Create directory structure for a new dictionary
    private func createDictionaryDirectories(id: String) throws {
        let fm = FileManager.default
        let baseDir = dictionaryDirectoryURL(id: id)
        
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: mddDirectoryURL(id: id), withIntermediateDirectories: true)
        try fm.createDirectory(at: cssDirectoryURL(id: id), withIntermediateDirectories: true)
        try fm.createDirectory(at: jsDirectoryURL(id: id), withIntermediateDirectories: true)
        try fm.createDirectory(at: fontsDirectoryURL(id: id), withIntermediateDirectories: true)
        
        // Exclude from iCloud backup
        var mutableBaseDir = baseDir
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableBaseDir.setResourceValues(resourceValues)
    }
    
    /// List files in a directory with given extension
    func listFilesInDirectory(_ dirURL: URL, extension ext: String) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        return contents
            .filter { $0.pathExtension.lowercased() == ext.lowercased() }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    // MARK: - Import
    
    /// Import a dictionary with its associated files
    /// - Parameters:
    ///   - mdxFile: The selected MDX file
    ///   - mddFiles: Selected MDD files
    ///   - cssFiles: Selected CSS files
    ///   - jsFiles: Selected JS files
    ///   - fontFiles: Selected font files
    ///   - displayName: User-visible name
    ///   - headerSHA256: SHA256 hash of MDX header (used as storage directory name)
    /// - Returns: The new dictionary's ID (same as headerSHA256)
    /// - Throws: `DictionaryImportError.duplicateImport` if dictionary already exists
    func importDictionary(
        mdxFile: SelectedFile,
        mddFiles: [SelectedFile] = [],
        cssFiles: [SelectedFile] = [],
        jsFiles: [SelectedFile] = [],
        fontFiles: [SelectedFile] = [],
        displayName: String,
        headerSHA256: String
    ) async throws -> String {
        // Use SHA256 hash as the dictionary ID / directory name
        // This enables automatic duplicate detection based on content
        let id = headerSHA256
        
        // Check for duplicate (directory already exists)
        if isDuplicateImport(headerSHA256: id) {
            throw DictionaryImportError.duplicateImport(existingId: id)
        }
        
        // 1. Create directory structure
        do {
            try createDictionaryDirectories(id: id)
        } catch {
            throw DictionaryImportError.directoryCreationFailed(error)
        }
        
        // 2. Copy MDX
        try await copyFile(mdxFile, to: mdxURL(id: id))
        
        // 3. Copy MDDs (using index-based naming for initial import)
        for (index, file) in mddFiles.enumerated() {
            let destURL = mddDirectoryURL(id: id).appendingPathComponent("\(index).mdd")
            try await copyFile(file, to: destURL)
        }
        
        // 4. Copy CSS
        for (index, file) in cssFiles.enumerated() {
            let destURL = cssDirectoryURL(id: id).appendingPathComponent("\(index).css")
            try await copyFile(file, to: destURL)
        }
        
        // 5. Copy JS
        for (index, file) in jsFiles.enumerated() {
            let destURL = jsDirectoryURL(id: id).appendingPathComponent("\(index).js")
            try await copyFile(file, to: destURL)
        }
        
        // 6. Copy fonts (preserve extension)
        for (index, file) in fontFiles.enumerated() {
            let ext = file.url.pathExtension
            let destURL = fontsDirectoryURL(id: id).appendingPathComponent("\(index).\(ext)")
            try await copyFile(file, to: destURL)
        }
        
        // 7. Update manifest
        let entry = DictionaryManifest.DictionaryEntry(
            id: id,
            displayName: displayName,
            originalFileName: mdxFile.fileName,
            mddCount: mddFiles.count,
            cssCount: cssFiles.count,
            jsCount: jsFiles.count,
            fontsCount: fontFiles.count
        )
        manifest.addDictionary(entry)
        
        do {
            try saveManifest()
        } catch {
            // Rollback: delete the directory we just created
            try? FileManager.default.removeItem(at: dictionaryDirectoryURL(id: id))
            throw DictionaryImportError.manifestSaveFailed(error)
        }
        
        print("✅ Imported dictionary: \(displayName) (id: \(id.prefix(16))...)")
        return id
    }
    
    /// Copy a file using security-scoped access
    private func copyFile(_ file: SelectedFile, to destURL: URL) async throws {
        // Try to resolve from bookmark first
        var sourceURL = file.url
        
        if let bookmarkData = file.bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                bookmarkDataIsStale: &isStale
            ) {
                sourceURL = resolvedURL
            }
        }
        
        // Access the security-scoped resource
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw DictionaryImportError.fileAccessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw DictionaryImportError.copyFailed(sourceURL, error)
        }
    }
    
    // MARK: - Delete
    
    /// Delete a user-imported dictionary
    func deleteDictionary(id: String) throws {
        // Don't allow deleting bundled dictionaries
        guard !DictionaryManifest.isBundledId(id) else {
            print("⚠️ Cannot delete bundled dictionary: \(id)")
            return
        }
        
        let dirURL = dictionaryDirectoryURL(id: id)
        
        if FileManager.default.fileExists(atPath: dirURL.path) {
            try FileManager.default.removeItem(at: dirURL)
        }
        
        manifest.removeDictionary(id: id)
        try saveManifest()
        
        print("🗑️ Deleted dictionary: \(id)")
    }
    
    // MARK: - Discovery
    
    /// Discover associated files for an MDX
    /// Scans the same directory for MDD, CSS, JS files with matching names
    func discoverAssociatedFiles(for mdxURL: URL) -> AssociatedFiles {
        let directory = mdxURL.deletingLastPathComponent()
        let baseName = mdxURL.deletingPathExtension().lastPathComponent
        
        var result = AssociatedFiles()
        
        guard directory.startAccessingSecurityScopedResource() else {
            print("⚠️ Cannot access directory for discovery")
            return result
        }
        defer { directory.stopAccessingSecurityScopedResource() }
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return result
        }
        
        for url in contents {
            let fileName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            
            // MDD: baseName.mdd, baseName.1.mdd, baseName.2.mdd, etc.
            if ext == "mdd" {
                if fileName == baseName || fileName.hasPrefix("\(baseName).") {
                    result.mddFiles.append(url)
                }
            }
            
            // CSS: baseName.css
            if ext == "css" && fileName == baseName {
                result.cssFiles.append(url)
            }
            
            // JS: baseName.js
            if ext == "js" && fileName == baseName {
                result.jsFiles.append(url)
            }
        }
        
        // Sort MDD files by name to maintain consistent order
        result.mddFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        
        print("🔍 Discovered: \(result.summary) for \(baseName)")
        return result
    }
    
    // MARK: - Query
    
    /// Get all user-imported dictionary IDs
    var importedDictionaryIds: [String] {
        manifest.dictionaries.map { $0.id }
    }
    
    /// Check if a dictionary with this original filename exists
    func isAlreadyImported(originalFileName: String) -> DictionaryManifest.DictionaryEntry? {
        manifest.dictionary(originalFileName: originalFileName)
    }
    
    /// Check if a dictionary with this SHA256 hash is already imported
    /// The hash is used as directory name, so we check if the directory exists
    func isDuplicateImport(headerSHA256: String) -> Bool {
        let dirURL = dictionaryDirectoryURL(id: headerSHA256)
        return FileManager.default.fileExists(atPath: dirURL.path)
    }
    
    // MARK: - Update
    
    /// Update the display name for a dictionary
    func updateDisplayName(id: String, newName: String) throws {
        manifest.updateDisplayName(id: id, newName: newName)
        try saveManifest()
        print("📝 Updated display name for \(id.prefix(16))...: \(newName)")
    }
    
    // MARK: - UTTypes
    
    /// UTType for .mdx files
    static var mdxType: UTType {
        UTType("io.github.naco-siren.openmdict.mdx") ?? .data
    }
    
    /// UTType for .mdd files
    static var mddType: UTType {
        UTType("io.github.naco-siren.openmdict.mdd") ?? .data
    }
    
    // MARK: - Resource Management (Hash-based)
    
    /// Calculate SHA256 hash of a file (for resource naming)
    /// Uses chunked reading to handle large files efficiently
    func calculateSHA256(of fileURL: URL) async throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw ResourceError.hashCalculationFailed(error)
        }
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1MB chunks
        
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: chunkSize),
                  !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - MDD Resource CRUD
    
    /// Add an MDD file to a dictionary (using SHA256 hash as filename)
    /// - Returns: Hash of the added file
    /// - Throws: ResourceError.duplicateFile if file already exists
    func addMDDResource(dictId: String, sourceURL: URL) async throws -> String {
        guard manifest.dictionary(id: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        let mddDir = mddDirectoryURL(id: dictId)
        
        // Security-scoped access
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        // Calculate hash
        let hash = try await calculateSHA256(of: sourceURL)
        
        // Check for duplicate
        let destURL = mddDir.appendingPathComponent("\(hash).mdd")
        if FileManager.default.fileExists(atPath: destURL.path) {
            throw ResourceError.duplicateFile(hash: hash)
        }
        
        // Copy file
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        // Update manifest count
        manifest.incrementMDDCount(id: dictId)
        try saveManifest()
        
        print("➕ Added MDD resource: \(hash.prefix(8))... to \(dictId.prefix(8))...")
        return hash
    }
    
    /// Remove an MDD file by hash
    func removeMDDResource(dictId: String, hash: String) throws {
        guard manifest.dictionary(id: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        let mddDir = mddDirectoryURL(id: dictId)
        let targetURL = mddDir.appendingPathComponent("\(hash).mdd")
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw ResourceError.notFound(hash: hash)
        }
        
        try FileManager.default.removeItem(at: targetURL)
        
        manifest.decrementMDDCount(id: dictId)
        try saveManifest()
        
        print("➖ Removed MDD resource: \(hash.prefix(8))... from \(dictId.prefix(8))...")
    }
    
    /// List all MDD files for a dictionary
    func listMDDResources(dictId: String) -> [ResourceFile] {
        let mddDir = mddDirectoryURL(id: dictId)
        return listResourceFiles(in: mddDir, type: .mdd)
    }
    
    // MARK: - CSS Resource CRUD
    
    /// Add a CSS file to a dictionary
    func addCSSResource(dictId: String, sourceURL: URL) async throws -> String {
        guard manifest.dictionary(id: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        let cssDir = cssDirectoryURL(id: dictId)
        
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        let hash = try await calculateSHA256(of: sourceURL)
        let destURL = cssDir.appendingPathComponent("\(hash).css")
        
        if FileManager.default.fileExists(atPath: destURL.path) {
            throw ResourceError.duplicateFile(hash: hash)
        }
        
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        manifest.incrementCSSCount(id: dictId)
        try saveManifest()
        
        print("➕ Added CSS resource: \(hash.prefix(8))... to \(dictId.prefix(8))...")
        return hash
    }
    
    /// Remove a CSS file by hash
    func removeCSSResource(dictId: String, hash: String) throws {
        guard manifest.dictionary(id: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        let cssDir = cssDirectoryURL(id: dictId)
        let targetURL = cssDir.appendingPathComponent("\(hash).css")
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw ResourceError.notFound(hash: hash)
        }
        
        try FileManager.default.removeItem(at: targetURL)
        
        manifest.decrementCSSCount(id: dictId)
        try saveManifest()
        
        print("➖ Removed CSS resource: \(hash.prefix(8))... from \(dictId.prefix(8))...")
    }
    
    /// List all CSS files for a dictionary
    func listCSSResources(dictId: String) -> [ResourceFile] {
        let cssDir = cssDirectoryURL(id: dictId)
        return listResourceFiles(in: cssDir, type: .css)
    }
    
    // MARK: - JS Resource CRUD
    
    /// Add a JS file to a dictionary
    func addJSResource(dictId: String, sourceURL: URL) async throws -> String {
        guard manifest.dictionary(id: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        let jsDir = jsDirectoryURL(id: dictId)
        
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        let hash = try await calculateSHA256(of: sourceURL)
        let destURL = jsDir.appendingPathComponent("\(hash).js")
        
        if FileManager.default.fileExists(atPath: destURL.path) {
            throw ResourceError.duplicateFile(hash: hash)
        }
        
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        manifest.incrementJSCount(id: dictId)
        try saveManifest()
        
        print("➕ Added JS resource: \(hash.prefix(8))... to \(dictId.prefix(8))...")
        return hash
    }
    
    /// Remove a JS file by hash
    func removeJSResource(dictId: String, hash: String) throws {
        guard manifest.dictionary(id: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        let jsDir = jsDirectoryURL(id: dictId)
        let targetURL = jsDir.appendingPathComponent("\(hash).js")
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw ResourceError.notFound(hash: hash)
        }
        
        try FileManager.default.removeItem(at: targetURL)
        
        manifest.decrementJSCount(id: dictId)
        try saveManifest()
        
        print("➖ Removed JS resource: \(hash.prefix(8))... from \(dictId.prefix(8))...")
    }
    
    /// List all JS files for a dictionary
    func listJSResources(dictId: String) -> [ResourceFile] {
        let jsDir = jsDirectoryURL(id: dictId)
        return listResourceFiles(in: jsDir, type: .js)
    }
    
    // MARK: - Resource Listing Helper
    
    /// List ResourceFile objects from a directory
    private func listResourceFiles(in dirURL: URL, type: ResourceFile.ResourceType) -> [ResourceFile] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        let ext = type.fileExtension
        
        return contents
            .filter { $0.pathExtension.lowercased() == ext }
            .compactMap { url -> ResourceFile? in
                let fullName = url.deletingPathExtension().lastPathComponent
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
                let size = Int64(attrs?.fileSize ?? 0)
                
                // Use first 8 chars of hash for display filename
                let displayName = "\(fullName.prefix(8)).\(ext)"
                
                return ResourceFile(
                    id: fullName,  // Full hash as ID
                    type: type,
                    fileName: displayName,
                    fileSize: size,
                    isRemovable: true
                )
            }
            .sorted { $0.id < $1.id }
    }
    
    // MARK: - MDX Resource (Read-only)
    
    /// Get MDX file info for a dictionary (read-only, not removable)
    func getMDXResource(dictId: String) -> ResourceFile? {
        let mdxURL = mdxURL(id: dictId)
        
        guard FileManager.default.fileExists(atPath: mdxURL.path) else {
            return nil
        }
        
        let attrs = try? mdxURL.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(attrs?.fileSize ?? 0)
        
        return ResourceFile(
            id: "mdx",
            type: .mdx,
            fileName: "0.mdx",
            fileSize: size,
            isRemovable: false
        )
    }
    
    /// Get all resources for a dictionary (MDX + MDD + CSS + JS)
    func allResources(for dictId: String) -> [ResourceFile] {
        var resources: [ResourceFile] = []
        
        if let mdx = getMDXResource(dictId: dictId) {
            resources.append(mdx)
        }
        
        resources.append(contentsOf: listMDDResources(dictId: dictId))
        resources.append(contentsOf: listCSSResources(dictId: dictId))
        resources.append(contentsOf: listJSResources(dictId: dictId))
        
        return resources
    }
}
