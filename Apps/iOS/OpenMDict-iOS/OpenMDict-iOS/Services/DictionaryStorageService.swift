//
//  DictionaryStorageService.swift
//  OpenMDict-iOS
//
//  Manages dictionary file storage in Library/Dictionaries/
//  Handles file import/export, directory operations, and per-dict manifest.json.
//
//  ⚠️ INTERNAL SERVICE - Do not call from UI layer!
//  UI should use DictionaryService which wraps these methods
//  and handles in-memory state updates.
//

import Foundation
import OpenMDictKit
import UIKit
import UniformTypeIdentifiers
import CryptoKit

// MARK: - ResourceFile (for UI display)

/// Information about a resource file in storage (for UI display)
nonisolated struct ResourceFile: Identifiable, Hashable {
    /// Unique ID within type - uses fileName (not hash)
    let id: String
    let type: ResourceType
    /// Original filename (e.g., "MyDict.mdd", "custom.css")
    let fileName: String
    /// SHA256 hash of file content (for duplicate detection)
    let hash: String
    let fileSize: Int64
    
    var isRemovable: Bool {
        switch type {
        case .mdx: return false
        default: return true
        }
    }
    
    enum ResourceType: String, CaseIterable {
        case mdx, mdd, css, js, fonts

        var displayName: String {
            switch self {
            case .mdx: return "Dictionary File"
            case .mdd: return "Resource Files"
            case .css: return "Custom Styles"
            case .js: return "Custom Scripts"
            case .fonts: return "Custom Fonts"
            }
        }

        /// File extension used for the legacy directory-scan fallback and the
        /// "Add <EXT> file" button label. Fonts have several extensions
        /// (ttf/otf/woff/woff2), so there's no single one — "font" reads
        /// correctly in the button and the directory fallback isn't used for
        /// fonts (font listing is manifest-driven).
        var fileExtension: String {
            switch self {
            case .fonts: return "font"
            default:     return rawValue
            }
        }
    }
    
    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    /// Initialize from DictManifest.ResourceEntry
    init(entry: DictManifest.ResourceEntry, type: ResourceType) {
        self.id = entry.fileName
        self.type = type
        self.fileName = entry.fileName
        self.hash = entry.hash
        self.fileSize = entry.sizeBytes
    }
    
    /// Initialize from DictManifest.MDXEntry
    init(mdxEntry: DictManifest.MDXEntry) {
        self.id = mdxEntry.fileName
        self.type = .mdx
        self.fileName = mdxEntry.fileName
        self.hash = "" // MDX doesn't store content hash
        self.fileSize = mdxEntry.sizeBytes
    }
    
    /// Legacy initializer for backward compatibility
    init(id: String, type: ResourceType, fileName: String, hash: String, fileSize: Int64) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.hash = hash
        self.fileSize = fileSize
    }
}

// MARK: - ResourceError

/// Errors specific to resource operations
enum ResourceError: LocalizedError {
    case accessDenied(URL)
    /// File with same content hash already exists
    case duplicateContent(fileName: String)
    /// File with same name but different content exists (needs overwrite confirmation)
    case fileNameConflict(fileName: String, existingHash: String, newHash: String)
    case notFound(fileName: String)
    case dictionaryNotFound(id: String)
    case dictManifestNotFound(id: String)
    case hashCalculationFailed(Error)
    case copyFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .accessDenied(let url):
            return "Cannot access file: \(url.lastPathComponent)"
        case .duplicateContent(let fileName):
            return "File already exists: \(fileName)"
        case .fileNameConflict(let fileName, _, _):
            return "A different version of \(fileName) already exists"
        case .notFound(let fileName):
            return "File not found: \(fileName)"
        case .dictionaryNotFound(let id):
            return "Dictionary not found: \(id.prefix(8))..."
        case .dictManifestNotFound(let id):
            return "Dictionary manifest not found: \(id.prefix(8))..."
        case .hashCalculationFailed(let error):
            return "Failed to calculate file hash: \(error.localizedDescription)"
        case .copyFailed(let error):
            return "Failed to copy file: \(error.localizedDescription)"
        }
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
    
    /// Create from a PendingFile (used during import)
    /// Uses the PendingFile's already-captured bookmark data
    init(from pendingFile: PendingFile) {
        self.url = pendingFile.url
        self.fileName = pendingFile.fileName
        self.fileSize = pendingFile.fileSize
        self.bookmarkData = pendingFile.bookmarkData
        self.isAutoDiscovered = false
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
    
    /// Create from existing metadata (for Edit mode)
    static func fromMetadata(
        _ metadata: DictMetadata,
        storage: DictionaryStorageService
    ) -> ImportFormState {
        var state = ImportFormState()
        state.displayName = metadata.displayName

        // MDX file
        let mdxURL = storage.mdxURL(id: metadata.dictId)
        if let mdxURL = mdxURL, FileManager.default.fileExists(atPath: mdxURL.path) {
            state.mdxFile = SelectedFile(url: mdxURL, isAutoDiscovered: false)
        }
        
        // For resources, we now iterate directory instead of using count
        // This supports both old index-based and new hash-based naming
        state.mddFiles = storage.listFilesInDirectory(
            storage.mddDirectoryURL(id: metadata.dictId),
            extension: "mdd"
        ).map { SelectedFile(url: $0, isAutoDiscovered: false) }

        state.cssFiles = storage.listFilesInDirectory(
            storage.cssDirectoryURL(id: metadata.dictId),
            extension: "css"
        ).map { SelectedFile(url: $0, isAutoDiscovered: false) }

        state.jsFiles = storage.listFilesInDirectory(
            storage.jsDirectoryURL(id: metadata.dictId),
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

    private init() {}

    // MARK: - Paths

    /// Root directory for user dictionaries inside the App Group shared container.
    let rootDirectoryURL: URL = {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier
        ) else {
            fatalError("App Group container unavailable — check Signing & Capabilities → App Groups")
        }
        let root = groupURL.appendingPathComponent("Library/Dictionaries", isDirectory: true)
        debugLog("📂 Dictionaries root: \(root.path)")
        return root
    }()

    /// Root directory for the persistent sidecar index cache inside the App
    /// Group shared container. Delegates to `AppGroupPaths` so the Action
    /// Extension can compute the same path without pulling in this whole
    /// service. Sidecar files are pure derived data — the slow-path parser
    /// can always rebuild them from the MDX/MDD source.
    var sidecarIndexCacheURL: URL { AppGroupPaths.sidecarIndexCacheURL }

    /// Directory for a specific dictionary
    func dictionaryDirectoryURL(id: String) -> URL {
        rootDirectoryURL.appendingPathComponent(id, isDirectory: true)
    }
    
    /// Path to dict manifest.json (per-dictionary)
    func dictManifestURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent("manifest.json")
    }
    
    /// MDX file path for a dictionary
    func mdxURL(id: String) -> URL? {
        // Try dict manifest first (new format with original filename)
        if let dictManifest = loadDictManifest(id: id) {
            return dictionaryDirectoryURL(id: id).appendingPathComponent(dictManifest.mdx.fileName)
        } else {
            return nil
        }
    }
    
    /// MDX file path with original filename (new style)
    func mdxURL(id: String, fileName: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent(fileName)
    }
    
    /// MDD directory for a dictionary
    func mddDirectoryURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent(AppIdentifiers.ResourceDirectory.mdd, isDirectory: true)
    }

    /// CSS directory for a dictionary
    func cssDirectoryURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent(AppIdentifiers.ResourceDirectory.css, isDirectory: true)
    }

    /// JS directory for a dictionary
    func jsDirectoryURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent(AppIdentifiers.ResourceDirectory.js, isDirectory: true)
    }

    /// Fonts directory for a dictionary
    func fontsDirectoryURL(id: String) -> URL {
        dictionaryDirectoryURL(id: id).appendingPathComponent(AppIdentifiers.ResourceDirectory.fonts, isDirectory: true)
    }
    
    // MARK: - Dict Metadata (CoreData)

    private var metadataService: DictMetadataService { DictMetadataService.shared }

    // MARK: - Dict Manifest (per-dictionary)
    
    /// Cache of loaded dict manifests (avoid repeated disk reads)
    private var dictManifestCache: [String: DictManifest] = [:]
    
    /// Load dict manifest for a specific dictionary
    /// - Returns: The dict manifest, or nil if not found (legacy dictionary)
    func loadDictManifest(id: String) -> DictManifest? {
        // Check cache first
        if let cached = dictManifestCache[id] {
            return cached
        }
        
        let url = dictManifestURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Legacy dictionary without dict manifest - this is OK
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let dictManifest = try decoder.decode(DictManifest.self, from: data)
            dictManifestCache[id] = dictManifest
            print("📄 Loaded dict manifest for \(id.prefix(8))...")
            return dictManifest
        } catch {
            print("❌ Failed to load dict manifest for \(id.prefix(8))...: \(error)")
            return nil
        }
    }
    
    /// Save dict manifest for a specific dictionary
    func saveDictManifest(_ dictManifest: DictManifest) throws {
        let url = dictManifestURL(id: dictManifest.id)
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(dictManifest)
        try data.write(to: url, options: .atomic)
        
        // Update cache
        dictManifestCache[dictManifest.id] = dictManifest
        
        // Sync counts to CoreData metadata
        syncDictManifestToMetadata(dictManifest)
        
        print("📄 Saved dict manifest for \(dictManifest.id.prefix(8))...")
    }
    
    /// Update dict manifest in place
    func updateDictManifest(id: String, _ mutate: (inout DictManifest) -> Void) throws {
        guard var dictManifest = loadDictManifest(id: id) else {
            throw ResourceError.dictManifestNotFound(id: id)
        }
        mutate(&dictManifest)
        try saveDictManifest(dictManifest)
    }
    
    /// Invalidate cached dict manifest (e.g., after external changes)
    func invalidateDictManifestCache(id: String) {
        dictManifestCache.removeValue(forKey: id)
    }
    
    /// Sync dict manifest resource counts to CoreData metadata.
    private func syncDictManifestToMetadata(_ dictManifest: DictManifest) {
        metadataService.syncResourceCounts(
            dictId: dictManifest.id,
            mddCount: dictManifest.mdd.count,
            cssCount: dictManifest.css.count,
            jsCount: dictManifest.js.count,
            totalSizeKB: dictManifest.totalSizeKB
        )
    }

    /// Insert a new dictionary metadata record into CoreData.
    /// Used by PresetDictionaryService and importDictionary().
    func addDictionaryMetadata(_ metadata: DictMetadata) {
        metadataService.insert(metadata)
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

        // Exclude from iCloud backup — large dictionary files should not
        // consume the user's backup quota; future sync uses CloudKit instead.
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
        
        // Track total size for root manifest
        var totalSizeBytes: Int64 = 0
        
        // 2. Copy MDX (using original filename)
        let mdxDestURL = mdxURL(id: id, fileName: mdxFile.fileName)
        print("📄 Storage: Copying MDX \(mdxFile.fileName) to \(mdxDestURL.path)")
        let (_, mdxSize) = try await copyFile(mdxFile, to: mdxDestURL)
        totalSizeBytes += mdxSize
        print("📄 Storage: MDX copied, size=\(mdxSize)")
        
        let mdxEntry = DictManifest.MDXEntry(
            fileName: mdxFile.fileName,
            sizeBytes: mdxSize
        )
        
        // 3. Copy MDDs (using original filenames, calculate hash)
        var mddEntries: [DictManifest.ResourceEntry] = []
        print("📄 Storage: Copying \(mddFiles.count) MDD files")
        for file in mddFiles {
            let destURL = mddDirectoryURL(id: id).appendingPathComponent(file.fileName)
            print("📄 Storage: Copying MDD \(file.fileName) to \(destURL.path)")
            let (hash, size) = try await copyFileWithHash(file, to: destURL)
            totalSizeBytes += size
            print("📄 Storage: MDD copied, size=\(size), hash=\(hash.prefix(8))...")
            
            mddEntries.append(DictManifest.ResourceEntry(
                fileName: file.fileName,
                hash: hash,
                sizeBytes: size
            ))
        }
        
        // 4. Copy CSS (using original filenames, calculate hash)
        var cssEntries: [DictManifest.ResourceEntry] = []
        print("📄 Storage: Copying \(cssFiles.count) CSS files")
        for file in cssFiles {
            let destURL = cssDirectoryURL(id: id).appendingPathComponent(file.fileName)
            print("📄 Storage: Copying CSS \(file.fileName) to \(destURL.path)")
            let (hash, size) = try await copyFileWithHash(file, to: destURL)
            totalSizeBytes += size
            print("📄 Storage: CSS copied, size=\(size), hash=\(hash.prefix(8))...")
            
            cssEntries.append(DictManifest.ResourceEntry(
                fileName: file.fileName,
                hash: hash,
                sizeBytes: size
            ))
        }
        
        // 5. Copy JS (using original filenames, calculate hash)
        var jsEntries: [DictManifest.ResourceEntry] = []
        print("📄 Storage: Copying \(jsFiles.count) JS files")
        for file in jsFiles {
            let destURL = jsDirectoryURL(id: id).appendingPathComponent(file.fileName)
            print("📄 Storage: Copying JS \(file.fileName) to \(destURL.path)")
            let (hash, size) = try await copyFileWithHash(file, to: destURL)
            totalSizeBytes += size
            print("📄 Storage: JS copied, size=\(size), hash=\(hash.prefix(8))...")
            
            jsEntries.append(DictManifest.ResourceEntry(
                fileName: file.fileName,
                hash: hash,
                sizeBytes: size
            ))
        }
        
        // 6. Copy fonts (preserve extension, calculate hash)
        var fontEntries: [DictManifest.ResourceEntry] = []
        print("📄 Storage: Copying \(fontFiles.count) font files")
        for file in fontFiles {
            let destURL = fontsDirectoryURL(id: id).appendingPathComponent(file.fileName)
            print("📄 Storage: Copying font \(file.fileName) to \(destURL.path)")
            let (hash, size) = try await copyFileWithHash(file, to: destURL)
            totalSizeBytes += size
            print("📄 Storage: font copied, size=\(size), hash=\(hash.prefix(8))...")

            fontEntries.append(DictManifest.ResourceEntry(
                fileName: file.fileName,
                hash: hash,
                sizeBytes: size
            ))
        }

        // 7. Create and save dict manifest
        let dictManifest = DictManifest(
            id: id,
            mdx: mdxEntry,
            mdd: mddEntries,
            css: cssEntries,
            js: jsEntries,
            fonts: fontEntries
        )
        
        do {
            try saveDictManifest(dictManifest)
        } catch {
            // Rollback: delete the directory we just created
            try? FileManager.default.removeItem(at: dictionaryDirectoryURL(id: id))
            throw DictionaryImportError.manifestSaveFailed(error)
        }
        
        // 8. Save metadata to CoreData
        let now = Date()
        let metadata = DictMetadata(
            dictId: id,
            displayName: displayName,
            originalFileName: mdxFile.fileName,
            importedAt: now,
            updatedAt: now,
            totalSizeKB: totalSizeBytes / 1024,
            mddCount: Int32(mddFiles.count),
            cssCount: Int32(cssFiles.count),
            jsCount: Int32(jsFiles.count),
            fontsCount: Int32(fontFiles.count),
            cloudSyncStatus: CloudSyncStatus.pending.rawValue,
            enhanceDarkMode: false,
            enhanceDarkModeStrength: EnhanceDarkModeStrength.standard.rawValue
        )
        addDictionaryMetadata(metadata)

        print("✅ Imported dictionary: \(displayName) (id: \(id.prefix(16))..., \(totalSizeBytes / 1024) KB)")
        return id
    }
    
    /// Copy a file using security-scoped access
    /// - Returns: (destinationURL, fileSize) tuple
    private func copyFile(_ file: SelectedFile, to destURL: URL) async throws -> (URL, Int64) {
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
        
        // Get file size before copy
        let fileSize: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            fileSize = (attrs[.size] as? Int64) ?? 0
        } catch {
            fileSize = 0
        }
        
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw DictionaryImportError.copyFailed(sourceURL, error)
        }
        
        return (destURL, fileSize)
    }
    
    /// Copy a file and calculate its SHA256 hash
    /// - Returns: (hash, fileSize) tuple
    private func copyFileWithHash(_ file: SelectedFile, to destURL: URL) async throws -> (String, Int64) {
        let (_, fileSize) = try await copyFile(file, to: destURL)
        
        // Calculate hash of copied file
        let hash = try await calculateSHA256(of: destURL)
        
        return (hash, fileSize)
    }
    
    // MARK: - Delete
    
    /// Delete a dictionary from Library/Dictionaries/
    func deleteDictionary(id: String) throws {
        let dirURL = dictionaryDirectoryURL(id: id)

        if FileManager.default.fileExists(atPath: dirURL.path) {
            try FileManager.default.removeItem(at: dirURL)
        }

        // Invalidate cache
        invalidateDictManifestCache(id: id)

        metadataService.delete(dictId: id)

        // Drop the persistent sidecar index for this dictionary so the cache
        // does not accumulate orphans. The dict id is the MDX header SHA256.
        MDictReader.removeSidecarCache(forHeaderSHA256: id)

        // M15 Phase 3: also drop the article-embedding sidecar (independent
        // file under `Library/Caches/SemanticIndex/<dictId>.semantic.idx`).
        // The Coordinator's delete handler is unconditional — runs even
        // on iOS < 26 — so old sidecars from a downgraded device get
        // cleaned up correctly.
        Task { @MainActor in
            ArticleIndexCoordinator.shared.handleDictDeleted(id)
        }

        print("🗑️ Deleted dictionary: \(id)")
    }
    
    // MARK: - Query
    
    /// Get all user-imported dictionary IDs
    var importedDictionaryIds: [String] {
        metadataService.importedDictionaryIds
    }

    /// Check if a dictionary with this original filename exists.
    /// Returns the matching metadata, or nil if not imported.
    func isAlreadyImported(originalFileName: String) -> DictMetadata? {
        metadataService.find(originalFileName: originalFileName)
    }
    
    /// Check if a dictionary with this SHA256 hash is already imported
    /// The hash is used as directory name, so we check if the directory exists
    func isDuplicateImport(headerSHA256: String) -> Bool {
        let dirURL = dictionaryDirectoryURL(id: headerSHA256)
        return FileManager.default.fileExists(atPath: dirURL.path)
    }
    
    // MARK: - Update
    
    /// Update the display name for a dictionary
    func updateDisplayName(id: String, newName: String) {
        metadataService.updateDisplayName(dictId: id, newName: newName)
        print("📝 Updated display name for \(id.prefix(16))...: \(newName)")
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
    
    /// Add an MDD file to a dictionary (preserving original filename)
    /// - Returns: fileName of the added file
    /// - Throws: ResourceError.duplicateContent if file with same hash exists
    /// - Throws: ResourceError.fileNameConflict if file with same name but different content exists
    func addMDDResource(dictId: String, sourceURL: URL) async throws -> String {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        let mddDir = mddDirectoryURL(id: dictId)
        let fileName = sourceURL.lastPathComponent
        
        // Security-scoped access
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        // Get file size
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        
        // Calculate hash
        let hash = try await calculateSHA256(of: sourceURL)
        
        // Check for duplicate content (same hash)
        if dictManifest.mddEntry(hash: hash) != nil {
            throw ResourceError.duplicateContent(fileName: fileName)
        }
        
        // Check for filename conflict (same name, different hash)
        if let existing = dictManifest.mddEntry(fileName: fileName) {
            throw ResourceError.fileNameConflict(
                fileName: fileName,
                existingHash: existing.hash,
                newHash: hash
            )
        }
        
        // Copy file
        let destURL = mddDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        // Update dict manifest
        let entry = DictManifest.ResourceEntry(
            fileName: fileName,
            hash: hash,
            sizeBytes: fileSize
        )
        dictManifest.mdd.append(entry)
        try saveDictManifest(dictManifest)
        
        print("➕ Added MDD resource: \(fileName) to \(dictId.prefix(8))...")
        return fileName
    }
    
    /// Add MDD with overwrite if filename conflicts (called after user confirmation)
    func addMDDResourceWithOverwrite(dictId: String, sourceURL: URL) async throws -> String {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        let mddDir = mddDirectoryURL(id: dictId)
        let fileName = sourceURL.lastPathComponent
        
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let hash = try await calculateSHA256(of: sourceURL)
        
        // Remove existing file if present
        dictManifest.removeMDD(fileName: fileName)
        let destURL = mddDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destURL)
        
        // Copy new file
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        let entry = DictManifest.ResourceEntry(fileName: fileName, hash: hash, sizeBytes: fileSize)
        dictManifest.mdd.append(entry)
        try saveDictManifest(dictManifest)
        
        print("➕ Overwrote MDD resource: \(fileName) in \(dictId.prefix(8))...")
        return fileName
    }
    
    /// Remove an MDD file by fileName
    func removeMDDResource(dictId: String, fileName: String) throws {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        guard dictManifest.mddEntry(fileName: fileName) != nil else {
            throw ResourceError.notFound(fileName: fileName)
        }
        
        let mddDir = mddDirectoryURL(id: dictId)
        let targetURL = mddDir.appendingPathComponent(fileName)
        
        try FileManager.default.removeItem(at: targetURL)
        
        dictManifest.removeMDD(fileName: fileName)
        try saveDictManifest(dictManifest)
        
        print("➖ Removed MDD resource: \(fileName) from \(dictId.prefix(8))...")
    }
    
    /// List all MDD files for a dictionary (from dict manifest)
    func listMDDResources(dictId: String) -> [ResourceFile] {
        guard let dictManifest = loadDictManifest(id: dictId) else {
            // Fallback to directory scan for legacy dictionaries
            return listResourceFilesFromDirectory(in: mddDirectoryURL(id: dictId), type: .mdd)
        }
        return dictManifest.mdd.map { ResourceFile(entry: $0, type: .mdd) }
    }
    
    /// Get MDD file URLs for a dictionary (for MDict resource loading)
    func listMDDFiles(for dictId: String) -> [URL] {
        let mddDir = mddDirectoryURL(id: dictId)
        if let dictManifest = loadDictManifest(id: dictId) {
            return dictManifest.mdd.map { mddDir.appendingPathComponent($0.fileName) }
        }
        // Fallback: scan directory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: mddDir, includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents.filter { $0.pathExtension.lowercased() == "mdd" }.sorted { $0.path < $1.path }
    }
    
    // MARK: - CSS Resource CRUD
    
    /// Add a CSS file to a dictionary (preserving original filename)
    func addCSSResource(dictId: String, sourceURL: URL) async throws -> String {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        let cssDir = cssDirectoryURL(id: dictId)
        let fileName = sourceURL.lastPathComponent
        
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let hash = try await calculateSHA256(of: sourceURL)
        
        if dictManifest.cssEntry(hash: hash) != nil {
            throw ResourceError.duplicateContent(fileName: fileName)
        }
        
        if let existing = dictManifest.cssEntry(fileName: fileName) {
            throw ResourceError.fileNameConflict(fileName: fileName, existingHash: existing.hash, newHash: hash)
        }
        
        let destURL = cssDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        let entry = DictManifest.ResourceEntry(fileName: fileName, hash: hash, sizeBytes: fileSize)
        dictManifest.css.append(entry)
        try saveDictManifest(dictManifest)
        
        print("➕ Added CSS resource: \(fileName) to \(dictId.prefix(8))...")
        return fileName
    }
    
    /// Add CSS with overwrite if filename conflicts
    func addCSSResourceWithOverwrite(dictId: String, sourceURL: URL) async throws -> String {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        let cssDir = cssDirectoryURL(id: dictId)
        let fileName = sourceURL.lastPathComponent
        
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let hash = try await calculateSHA256(of: sourceURL)
        
        dictManifest.removeCSS(fileName: fileName)
        let destURL = cssDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destURL)
        
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        let entry = DictManifest.ResourceEntry(fileName: fileName, hash: hash, sizeBytes: fileSize)
        dictManifest.css.append(entry)
        try saveDictManifest(dictManifest)
        
        print("➕ Overwrote CSS resource: \(fileName) in \(dictId.prefix(8))...")
        return fileName
    }
    
    /// Remove a CSS file by fileName
    func removeCSSResource(dictId: String, fileName: String) throws {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        guard dictManifest.cssEntry(fileName: fileName) != nil else {
            throw ResourceError.notFound(fileName: fileName)
        }
        
        let cssDir = cssDirectoryURL(id: dictId)
        let targetURL = cssDir.appendingPathComponent(fileName)
        
        try FileManager.default.removeItem(at: targetURL)
        
        dictManifest.removeCSS(fileName: fileName)
        try saveDictManifest(dictManifest)
        
        print("➖ Removed CSS resource: \(fileName) from \(dictId.prefix(8))...")
    }
    
    /// List all CSS files for a dictionary
    func listCSSResources(dictId: String) -> [ResourceFile] {
        guard let dictManifest = loadDictManifest(id: dictId) else {
            return listResourceFilesFromDirectory(in: cssDirectoryURL(id: dictId), type: .css)
        }
        return dictManifest.css.map { ResourceFile(entry: $0, type: .css) }
    }
    
    // MARK: - JS Resource CRUD
    
    /// Add a JS file to a dictionary (preserving original filename)
    func addJSResource(dictId: String, sourceURL: URL) async throws -> String {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        let jsDir = jsDirectoryURL(id: dictId)
        let fileName = sourceURL.lastPathComponent
        
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let hash = try await calculateSHA256(of: sourceURL)
        
        if dictManifest.jsEntry(hash: hash) != nil {
            throw ResourceError.duplicateContent(fileName: fileName)
        }
        
        if let existing = dictManifest.jsEntry(fileName: fileName) {
            throw ResourceError.fileNameConflict(fileName: fileName, existingHash: existing.hash, newHash: hash)
        }
        
        let destURL = jsDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        let entry = DictManifest.ResourceEntry(fileName: fileName, hash: hash, sizeBytes: fileSize)
        dictManifest.js.append(entry)
        try saveDictManifest(dictManifest)
        
        print("➕ Added JS resource: \(fileName) to \(dictId.prefix(8))...")
        return fileName
    }
    
    /// Add JS with overwrite if filename conflicts
    func addJSResourceWithOverwrite(dictId: String, sourceURL: URL) async throws -> String {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        let jsDir = jsDirectoryURL(id: dictId)
        let fileName = sourceURL.lastPathComponent
        
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let hash = try await calculateSHA256(of: sourceURL)
        
        dictManifest.removeJS(fileName: fileName)
        let destURL = jsDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destURL)
        
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }
        
        let entry = DictManifest.ResourceEntry(fileName: fileName, hash: hash, sizeBytes: fileSize)
        dictManifest.js.append(entry)
        try saveDictManifest(dictManifest)
        
        print("➕ Overwrote JS resource: \(fileName) in \(dictId.prefix(8))...")
        return fileName
    }
    
    /// Remove a JS file by fileName
    func removeJSResource(dictId: String, fileName: String) throws {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }
        
        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }
        
        guard dictManifest.jsEntry(fileName: fileName) != nil else {
            throw ResourceError.notFound(fileName: fileName)
        }
        
        let jsDir = jsDirectoryURL(id: dictId)
        let targetURL = jsDir.appendingPathComponent(fileName)
        
        try FileManager.default.removeItem(at: targetURL)
        
        dictManifest.removeJS(fileName: fileName)
        try saveDictManifest(dictManifest)
        
        print("➖ Removed JS resource: \(fileName) from \(dictId.prefix(8))...")
    }
    
    /// List all JS files for a dictionary
    func listJSResources(dictId: String) -> [ResourceFile] {
        guard let dictManifest = loadDictManifest(id: dictId) else {
            return listResourceFilesFromDirectory(in: jsDirectoryURL(id: dictId), type: .js)
        }
        return dictManifest.js.map { ResourceFile(entry: $0, type: .js) }
    }

    // MARK: - Font Resource CRUD

    /// Add a font file to a dictionary (preserving original filename)
    func addFontResource(dictId: String, sourceURL: URL) async throws -> String {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }

        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }

        let fontsDir = fontsDirectoryURL(id: dictId)
        let fileName = sourceURL.lastPathComponent

        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ResourceError.accessDenied(sourceURL)
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let hash = try await calculateSHA256(of: sourceURL)

        if dictManifest.fontEntry(hash: hash) != nil {
            throw ResourceError.duplicateContent(fileName: fileName)
        }

        if let existing = dictManifest.fontEntry(fileName: fileName) {
            throw ResourceError.fileNameConflict(fileName: fileName, existingHash: existing.hash, newHash: hash)
        }

        // fonts/ dir may not exist on dictionaries imported before font support.
        try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        let destURL = fontsDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ResourceError.copyFailed(error)
        }

        let entry = DictManifest.ResourceEntry(fileName: fileName, hash: hash, sizeBytes: fileSize)
        dictManifest.fonts.append(entry)
        try saveDictManifest(dictManifest)

        print("➕ Added font resource: \(fileName) to \(dictId.prefix(8))...")
        return fileName
    }

    /// Remove a font file by fileName
    func removeFontResource(dictId: String, fileName: String) throws {
        guard metadataService.find(dictId: dictId) != nil else {
            throw ResourceError.dictionaryNotFound(id: dictId)
        }

        guard var dictManifest = loadDictManifest(id: dictId) else {
            throw ResourceError.dictManifestNotFound(id: dictId)
        }

        guard dictManifest.fontEntry(fileName: fileName) != nil else {
            throw ResourceError.notFound(fileName: fileName)
        }

        let targetURL = fontsDirectoryURL(id: dictId).appendingPathComponent(fileName)

        try FileManager.default.removeItem(at: targetURL)

        dictManifest.removeFont(fileName: fileName)
        try saveDictManifest(dictManifest)

        print("➖ Removed font resource: \(fileName) from \(dictId.prefix(8))...")
    }

    /// List all font files for a dictionary (manifest-driven; legacy
    /// dictionaries predate font support so there's nothing to scan).
    func listFontResources(dictId: String) -> [ResourceFile] {
        guard let dictManifest = loadDictManifest(id: dictId) else { return [] }
        return dictManifest.fonts.map { ResourceFile(entry: $0, type: .fonts) }
    }

    // MARK: - Resource Listing Helper (Legacy fallback)
    
    /// List ResourceFile objects from a directory (for legacy dictionaries without dict manifest)
    private func listResourceFilesFromDirectory(in dirURL: URL, type: ResourceFile.ResourceType) -> [ResourceFile] {
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
                let fileName = url.lastPathComponent
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
                let size = Int64(attrs?.fileSize ?? 0)
                
                return ResourceFile(
                    id: fileName,
                    type: type,
                    fileName: fileName,
                    hash: "", // Unknown for legacy
                    fileSize: size
                )
            }
            .sorted { $0.fileName < $1.fileName }
    }
    
    // MARK: - MDX Resource (Read-only)
    
    /// Get MDX file info for a dictionary (from dict manifest or fallback to file scan)
    func getMDXResource(dictId: String) -> ResourceFile? {
        // Try dict manifest first
        if let dictManifest = loadDictManifest(id: dictId) {
            return ResourceFile(mdxEntry: dictManifest.mdx)
        }
        
        // Scan directory for any .mdx file
        let dictDir = dictionaryDirectoryURL(id: dictId)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dictDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        
        if let mdxURL = contents.first(where: { $0.pathExtension.lowercased() == "mdx" }) {
            let attrs = try? mdxURL.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(attrs?.fileSize ?? 0)
            let fileName = mdxURL.lastPathComponent
            return ResourceFile(
                id: fileName,
                type: .mdx,
                fileName: fileName,
                hash: "",
                fileSize: size
            )
        }
        
        return nil
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
        resources.append(contentsOf: listFontResources(dictId: dictId))

        return resources
    }
}
