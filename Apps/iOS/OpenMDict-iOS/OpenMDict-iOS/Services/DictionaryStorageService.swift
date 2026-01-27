//
//  DictionaryStorageService.swift
//  OpenMDict-iOS
//
//  Manages dictionary file storage in Library/Dictionaries/
//  Handles manifest.json persistence, file import/export, and directory operations.
//

import Foundation
import UniformTypeIdentifiers

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
        
        // MDD files
        for i in 0..<entry.mdd {
            let url = storage.mddDirectoryURL(id: entry.id).appendingPathComponent("\(i).mdd")
            if FileManager.default.fileExists(atPath: url.path) {
                state.mddFiles.append(SelectedFile(url: url, isAutoDiscovered: false))
            }
        }
        
        // CSS files
        for i in 0..<entry.css {
            let url = storage.cssDirectoryURL(id: entry.id).appendingPathComponent("\(i).css")
            if FileManager.default.fileExists(atPath: url.path) {
                state.cssFiles.append(SelectedFile(url: url, isAutoDiscovered: false))
            }
        }
        
        // JS files
        for i in 0..<entry.js {
            let url = storage.jsDirectoryURL(id: entry.id).appendingPathComponent("\(i).js")
            if FileManager.default.fileExists(atPath: url.path) {
                state.jsFiles.append(SelectedFile(url: url, isAutoDiscovered: false))
            }
        }
        
        return state
    }
}

// MARK: - Import Error

enum DictionaryImportError: LocalizedError {
    case noMDXSelected
    case fileAccessDenied(URL)
    case copyFailed(URL, Error)
    case manifestSaveFailed(Error)
    case directoryCreationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .noMDXSelected:
            return "No MDX file selected"
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
    
    // MARK: - Import
    
    /// Import a dictionary with its associated files
    /// - Parameters:
    ///   - mdxFile: The selected MDX file
    ///   - mddFiles: Selected MDD files
    ///   - cssFiles: Selected CSS files
    ///   - jsFiles: Selected JS files
    ///   - fontFiles: Selected font files
    ///   - displayName: User-visible name
    /// - Returns: The new dictionary's ID
    func importDictionary(
        mdxFile: SelectedFile,
        mddFiles: [SelectedFile] = [],
        cssFiles: [SelectedFile] = [],
        jsFiles: [SelectedFile] = [],
        fontFiles: [SelectedFile] = [],
        displayName: String
    ) async throws -> String {
        let id = UUID().uuidString
        
        // 1. Create directory structure
        do {
            try createDictionaryDirectories(id: id)
        } catch {
            throw DictionaryImportError.directoryCreationFailed(error)
        }
        
        // 2. Copy MDX
        try await copyFile(mdxFile, to: mdxURL(id: id))
        
        // 3. Copy MDDs
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
            mdd: mddFiles.count,
            css: cssFiles.count,
            js: jsFiles.count,
            fonts: fontFiles.count
        )
        manifest.addDictionary(entry)
        
        do {
            try saveManifest()
        } catch {
            // Rollback: delete the directory we just created
            try? FileManager.default.removeItem(at: dictionaryDirectoryURL(id: id))
            throw DictionaryImportError.manifestSaveFailed(error)
        }
        
        print("✅ Imported dictionary: \(displayName) (id: \(id))")
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
    
    // MARK: - UTTypes
    
    /// UTType for .mdx files
    static var mdxType: UTType {
        UTType("io.github.naco-siren.openmdict.mdx") ?? .data
    }
    
    /// UTType for .mdd files
    static var mddType: UTType {
        UTType("io.github.naco-siren.openmdict.mdd") ?? .data
    }
}
