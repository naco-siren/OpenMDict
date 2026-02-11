//
//  PresetDictionaryService.swift
//  OpenMDict-iOS
//
//  Manages preset (bundled + ODR) dictionary catalog and import flows.
//  Reads preset-dictionaries.json from app bundle, handles importing
//  dictionaries from bundle assets or Apple CDN (On-Demand Resources).
//
//  All imported dictionaries end up in Library/Dictionaries/{sha256}/
//  as regular .imported dictionaries — no dual-track system.
//
//  ⚠️ INTERNAL SERVICE - UI should use DictionaryService for state management.
//  This service is called by SetupViewController and PresetDictionaryPicker.
//

import Foundation
import CryptoKit
import OpenMDictKit

// MARK: - Direction Model

/// A single lookup direction: headword language → definition language(s).
/// Example: `{src: "ES", dest: ["EN"]}` means Spanish headwords with English definitions.
struct Direction: Codable, Equatable {
    let src: String
    let dest: [String]
}

// MARK: - PresetDictionary Model

/// A dictionary entry from preset-dictionaries.json (v3 schema).
/// All preset dictionaries are modeled as unidirectional: one headword language (`direction.src`)
/// with one or more definition languages (`direction.dest`).
/// Bidirectional dictionaries (e.g., FreeDict) are split into separate entries.
struct PresetDictionary: Codable, Identifiable {
    let id: String
    let filename: String
    let displayName: String
    let description: String

    /// Lookup direction: headword language → definition language(s).
    /// - Monolingual:    `{src: "EN", dest: ["EN"]}`
    /// - Unidirectional: `{src: "ES", dest: ["EN"]}`
    /// - Bilingual:      `{src: "EN", dest: ["EN", "ZH"]}` (future)
    let direction: Direction

    let entries: Int
    let sizeBytes: Int64
    let license: String
    let dataSource: String
    let source: Source
    let odrTag: String?
    /// Display tier for ordering/grouping in picker UI.
    /// 0 = core (bundled or top-priority ODR), 1 = secondary, 2 = alternative/comparison, etc.
    /// nil = unlisted/hidden.
    let tier: Int?

    /// Flag emoji for the source (headword) language, for display purposes.
    /// Stored explicitly because language codes ≠ country codes (e.g., LA → 🏛️, AR → 🇸🇦).
    let flag: String

    /// Where the .mdx file is stored before import
    enum Source: String, Codable {
        /// In app bundle (Copy Bundle Resources)
        case bundle
        /// Apple CDN via On-Demand Resources
        case odr
    }

    // MARK: - Computed: Language Analysis

    /// Set of all language codes this dictionary covers (src ∪ dest)
    var languages: Set<String> {
        var langs = Set<String>()
        langs.insert(direction.src)
        langs.formUnion(direction.dest)
        return langs
    }

    /// Whether this dictionary is monolingual (src == dest, e.g. EN → EN)
    var isMonolingual: Bool {
        direction.dest.count == 1 && direction.dest[0] == direction.src
    }

    // MARK: - Computed: Basic Properties

    /// Whether this dictionary is stored in the app bundle (not ODR)
    var isBundleAsset: Bool {
        source == .bundle
    }

    /// Human-readable file size
    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    // MARK: - Language Display Helpers

    /// Get a localized language name for an ISO 639-1 code using the device locale.
    /// Falls back to the code itself if localization is unavailable.
    static func localizedLanguageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code.lowercased())?.localizedCapitalized ?? code
    }

    /// Flag emoji for a given language code.
    /// Language codes are not country codes, so a manual mapping is required.
    /// Dual flags represent languages with two major national traditions
    /// (ordered by historical origin first, then largest population).
    static func flagEmoji(for code: String) -> String {
        switch code {
        case "EN": return "🇬🇧🇺🇸"
        case "ZH": return "🇨🇳🇹🇼"
        case "JA": return "🇯🇵"
        case "KO": return "🇰🇷"
        case "ES": return "🇪🇸"
        case "FR": return "🇫🇷"
        case "DE": return "🇩🇪🇦🇹"
        case "IT": return "🇮🇹"
        case "PT": return "🇵🇹🇧🇷"
        case "RU": return "🇷🇺"
        case "AR": return "🇸🇦"
        case "TR": return "🇹🇷"
        case "EL": return "🇬🇷"
        case "LA": return "🏛️"
        default:   return "🏳️"
        }
    }

    // MARK: - Language Pair Display

    /// Flexible language pair display string.
    /// - Parameters:
    ///   - abbreviated: `true` → "JA → EN", `false` → "Japanese → English"
    ///   - withEmoji: `true` → prepend/append flag emoji
    /// - Returns: Formatted language pair string
    func languagePair(abbreviated: Bool = true, withEmoji: Bool = false) -> String {
        // Monolingual dictionaries (e.g., WordNet EN → EN)
        if isMonolingual {
            let name = abbreviated ? direction.src : Self.localizedLanguageName(direction.src)
            return withEmoji ? "\(flag) \(name)" : name
        }

        let srcName = abbreviated ? direction.src : Self.localizedLanguageName(direction.src)
        let destNames = direction.dest.map { abbreviated ? $0 : Self.localizedLanguageName($0) }
        let pair = "\(srcName) \u{2192} \(destNames.joined(separator: ", "))"

        guard withEmoji else { return pair }

        let destFlags = direction.dest.map { Self.flagEmoji(for: $0) }.joined(separator: " ")
        return "\(flag) \(pair) \(destFlags)".trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - PresetDictionaryCatalog

/// Root structure for preset-dictionaries.json
struct PresetDictionaryCatalog: Codable {
    let version: Int
    let dictionaries: [PresetDictionary]
}

// MARK: - Import Status

/// Status of a preset dictionary relative to the user's Library
enum PresetDictionaryStatus {
    /// Not yet imported to Library/Dictionaries/
    case notImported
    /// Already imported (matched by filename in Library manifest)
    case imported(libraryId: String)
    /// Currently being downloaded/imported
    case importing(progress: Double)
    /// Import failed
    case failed(error: Error)
}

// MARK: - Import Error

enum PresetImportError: LocalizedError {
    case catalogNotFound
    case catalogDecodingFailed(Error)
    case bundleFileNotFound(filename: String)
    case odrTagMissing(presetId: String)
    case odrDownloadFailed(Error)
    case odrFileNotFound(tag: String)
    case sha256CalculationFailed(Error)
    case directoryCreationFailed(Error)
    case fileCopyFailed(Error)
    case manifestSaveFailed(Error)
    case alreadyImported(presetId: String)

    var errorDescription: String? {
        switch self {
        case .catalogNotFound:
            return "preset-dictionaries.json not found in app bundle"
        case .catalogDecodingFailed(let error):
            return "Failed to decode preset catalog: \(error.localizedDescription)"
        case .bundleFileNotFound(let filename):
            return "Bundle asset not found: \(filename)"
        case .odrTagMissing(let presetId):
            return "ODR tag missing for preset: \(presetId)"
        case .odrDownloadFailed(let error):
            return "ODR download failed: \(error.localizedDescription)"
        case .odrFileNotFound(let tag):
            return "ODR file not found after download (tag: \(tag))"
        case .sha256CalculationFailed(let error):
            return "SHA256 calculation failed: \(error.localizedDescription)"
        case .directoryCreationFailed(let error):
            return "Failed to create directory: \(error.localizedDescription)"
        case .fileCopyFailed(let error):
            return "Failed to copy file: \(error.localizedDescription)"
        case .manifestSaveFailed(let error):
            return "Failed to save manifest: \(error.localizedDescription)"
        case .alreadyImported(let presetId):
            return "Dictionary already imported: \(presetId)"
        }
    }
}

// MARK: - Import Result

/// Result of a single preset dictionary import
struct PresetImportResult: Sendable {
    let presetId: String
    let libraryId: String?  // SHA256 hash (nil if failed)
    let errorMessage: String?

    var isSuccess: Bool { libraryId != nil }
}

// MARK: - PresetDictionaryService

@MainActor
final class PresetDictionaryService {

    static let shared = PresetDictionaryService()

    // MARK: - Dependencies

    private let storage = DictionaryStorageService.shared

    // MARK: - State

    /// Loaded catalog from preset-dictionaries.json
    private(set) var catalog: [PresetDictionary] = []

    /// Import status for each preset dictionary (keyed by preset ID)
    private(set) var importStatus: [String: PresetDictionaryStatus] = [:]

    /// Active ODR requests (keyed by preset ID, for cancellation)
    private var activeODRRequests: [String: NSBundleResourceRequest] = [:]

    private init() {}

    // MARK: - Catalog Loading

    /// Load the preset dictionary catalog from app bundle.
    /// Call this once during app startup or when presenting the picker.
    func loadCatalog() throws {
        guard let url = Bundle.main.url(forResource: "preset-dictionaries", withExtension: "json") else {
            throw PresetImportError.catalogNotFound
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PresetDictionaryCatalog.self, from: data)
            catalog = decoded.dictionaries
            print("📋 Loaded preset catalog: \(catalog.count) dictionaries")
        } catch {
            throw PresetImportError.catalogDecodingFailed(error)
        }

        // Compute initial import status by checking Library manifest
        refreshImportStatus()
    }

    // MARK: - Import Status

    /// Refresh import status for all preset dictionaries by checking Library manifest.
    /// Matches by originalFileName in Library's root manifest.
    func refreshImportStatus() {
        let libraryEntries = storage.manifest.dictionaries

        for preset in catalog {
            // Skip if already in a transient state (importing/failed)
            if case .importing = importStatus[preset.id] { continue }

            // Check if this preset's .mdx filename matches any imported dictionary's originalFileName
            if let existingEntry = libraryEntries.first(where: { $0.originalFileName == preset.filename }) {
                importStatus[preset.id] = .imported(libraryId: existingEntry.id)
            } else {
                importStatus[preset.id] = .notImported
            }
        }
    }

    /// Check if a specific preset dictionary is already imported
    func isImported(_ presetId: String) -> Bool {
        if case .imported = importStatus[presetId] {
            return true
        }
        return false
    }

    /// Get preset dictionaries that haven't been imported yet
    var notImportedPresets: [PresetDictionary] {
        catalog.filter { !isImported($0.id) }
    }

    /// Get preset dictionaries that are bundle assets (always available)
    var bundleAssetPresets: [PresetDictionary] {
        catalog.filter { $0.isBundleAsset }
    }

    /// Get preset dictionaries by tier
    func presets(tier: Int) -> [PresetDictionary] {
        catalog.filter { $0.tier == tier }
    }

    /// Get preset dictionaries with a given headword (source) language
    func presets(src: String) -> [PresetDictionary] {
        catalog.filter { $0.direction.src == src }
    }

    // MARK: - Import from Bundle

    /// Import a preset dictionary from the app bundle into Library/Dictionaries/.
    /// The .mdx file is copied from Bundle.main to Library/{sha256}/.
    ///
    /// - Parameter preset: The preset dictionary to import
    /// - Returns: The library dictionary ID (SHA256 hash)
    func importFromBundle(_ preset: PresetDictionary) async throws -> String {
        guard preset.source == .bundle else {
            throw PresetImportError.bundleFileNotFound(filename: preset.filename)
        }

        // Find the file in app bundle
        let baseName = (preset.filename as NSString).deletingPathExtension
        guard let sourceURL = Bundle.main.url(forResource: baseName, withExtension: "mdx") else {
            throw PresetImportError.bundleFileNotFound(filename: preset.filename)
        }

        return try await importMDXFile(from: sourceURL, preset: preset)
    }

    // MARK: - Import from ODR

    /// Import a preset dictionary via On-Demand Resources from Apple CDN.
    /// Downloads the .mdx file, copies to Library/{sha256}/, then releases ODR cache.
    ///
    /// - Parameters:
    ///   - preset: The preset dictionary to import
    ///   - onProgress: Progress callback (fraction 0.0–1.0, completedBytes, totalBytes)
    /// - Returns: The library dictionary ID (SHA256 hash)
    func importFromODR(
        _ preset: PresetDictionary,
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void
    ) async throws -> String {
        guard let tag = preset.odrTag else {
            throw PresetImportError.odrTagMissing(presetId: preset.id)
        }

        let request = NSBundleResourceRequest(tags: [tag])
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent

        // Track active request for potential cancellation
        activeODRRequests[preset.id] = request
        defer { activeODRRequests.removeValue(forKey: preset.id) }

        // Observe download progress (fraction + byte counts)
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            Task { @MainActor in
                onProgress(progress.fractionCompleted, progress.completedUnitCount, progress.totalUnitCount)
            }
        }
        defer { observation.invalidate() }

        // Download from Apple CDN
        do {
            try await request.beginAccessingResources()
        } catch {
            throw PresetImportError.odrDownloadFailed(error)
        }

        // Find the downloaded file in bundle
        let baseName = (preset.filename as NSString).deletingPathExtension
        guard let sourceURL = Bundle.main.url(forResource: baseName, withExtension: "mdx") else {
            request.endAccessingResources()
            throw PresetImportError.odrFileNotFound(tag: tag)
        }

        // Import the file (copy to Library)
        let dictId: String
        do {
            dictId = try await importMDXFile(from: sourceURL, preset: preset)
        } catch {
            request.endAccessingResources()
            throw error
        }

        // Release ODR cache — the Library copy persists independently
        request.endAccessingResources()

        return dictId
    }

    /// Cancel an active ODR download
    func cancelODRDownload(presetId: String) {
        if let request = activeODRRequests[presetId] {
            request.progress.cancel()
            request.endAccessingResources()
            activeODRRequests.removeValue(forKey: presetId)
            importStatus[presetId] = .notImported
            print("❌ Cancelled ODR download for: \(presetId)")
        }
    }

    // MARK: - Batch Import

    /// Import multiple preset dictionaries with maximum concurrency.
    ///
    /// All imports (bundle + ODR) run concurrently. Bundle assets are instant
    /// disk copies; ODR assets download from Apple CDN in parallel.
    /// Each completed import immediately triggers `onComplete` so the caller
    /// can piggyback dictionary loading into RAM while other imports continue.
    ///
    /// - Parameters:
    ///   - presets: List of preset dictionaries to import
    ///   - onProgress: Progress callback (presetId, fraction 0.0–1.0, completedBytes, totalBytes)
    ///   - onComplete: Called when each individual import finishes (may be called concurrently)
    /// - Returns: Array of import results (order matches completion order, not input order)
    func importBatch(
        _ presets: [PresetDictionary],
        onProgress: @escaping @Sendable (String, Double, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (PresetImportResult) -> Void
    ) async -> [PresetImportResult] {

        var results: [PresetImportResult] = []

        // Launch all imports concurrently as independent Tasks.
        // Each Task runs on @MainActor (inheriting from this @MainActor class).
        // Suspension points (SHA256, ODR download) allow true concurrency.
        var tasks: [(PresetDictionary, Task<PresetImportResult, Never>)] = []

        for preset in presets {
            // Skip if already imported
            if isImported(preset.id) {
                let result = PresetImportResult(
                    presetId: preset.id,
                    libraryId: nil,
                    errorMessage: PresetImportError.alreadyImported(presetId: preset.id).localizedDescription
                )
                results.append(result)
                onComplete(result)
                continue
            }

            importStatus[preset.id] = .importing(progress: 0)

            let task = Task { @MainActor [self] () -> PresetImportResult in
                do {
                    let dictId: String
                    if preset.isBundleAsset {
                        dictId = try await importFromBundle(preset)
                    } else {
                        dictId = try await importFromODR(preset) { progress, completed, total in
                            onProgress(preset.id, progress, completed, total)
                        }
                    }

                    importStatus[preset.id] = .imported(libraryId: dictId)
                    let result = PresetImportResult(presetId: preset.id, libraryId: dictId, errorMessage: nil)
                    onComplete(result)
                    print("✅ Imported preset: \(preset.displayName) → \(dictId.prefix(16))...")
                    return result

                } catch {
                    importStatus[preset.id] = .failed(error: error)
                    let result = PresetImportResult(presetId: preset.id, libraryId: nil, errorMessage: error.localizedDescription)
                    onComplete(result)
                    print("❌ Failed to import preset \(preset.displayName): \(error.localizedDescription)")
                    return result
                }
            }

            tasks.append((preset, task))
        }

        // Await all concurrent tasks
        for (_, task) in tasks {
            let result = await task.value
            results.append(result)
        }

        return results
    }

    // MARK: - Private: Core Import Logic

    /// Core import logic: copy an MDX file from a source URL to Library/Dictionaries/{sha256}/
    /// This reuses the existing DictionaryStorageService import pipeline.
    ///
    /// - Parameters:
    ///   - sourceURL: URL to the .mdx file (in bundle or ODR cache)
    ///   - preset: The preset dictionary metadata
    /// - Returns: Library dictionary ID (SHA256 hash)
    private func importMDXFile(from sourceURL: URL, preset: PresetDictionary) async throws -> String {
        // 1. Calculate SHA256 hash of the MDX file (used as directory name / ID)
        let headerSHA256: String
        do {
            headerSHA256 = try await storage.calculateSHA256(of: sourceURL)
        } catch {
            throw PresetImportError.sha256CalculationFailed(error)
        }

        // 2. Check for duplicate (same file already imported)
        if storage.isDuplicateImport(headerSHA256: headerSHA256) {
            // Already imported — just update status and return
            importStatus[preset.id] = .imported(libraryId: headerSHA256)
            print("ℹ️ Preset \(preset.displayName) already in Library (dedup): \(headerSHA256.prefix(16))...")
            return headerSHA256
        }

        let dictId = headerSHA256

        // 3. Create directory structure: Library/Dictionaries/{sha256}/
        let dictDir = storage.dictionaryDirectoryURL(id: dictId)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dictDir, withIntermediateDirectories: true)
            // Create standard subdirectories
            try fm.createDirectory(at: storage.mddDirectoryURL(id: dictId), withIntermediateDirectories: true)
            try fm.createDirectory(at: storage.cssDirectoryURL(id: dictId), withIntermediateDirectories: true)
            try fm.createDirectory(at: storage.jsDirectoryURL(id: dictId), withIntermediateDirectories: true)
            try fm.createDirectory(at: storage.fontsDirectoryURL(id: dictId), withIntermediateDirectories: true)

            // Exclude from iCloud backup
            var mutableDir = dictDir
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableDir.setResourceValues(resourceValues)
        } catch {
            throw PresetImportError.directoryCreationFailed(error)
        }

        // 4. Copy MDX file to Library/{sha256}/{filename}.mdx
        let destURL = storage.mdxURL(id: dictId, fileName: preset.filename)
        do {
            try fm.copyItem(at: sourceURL, to: destURL)
        } catch {
            // Rollback: remove the directory we just created
            try? fm.removeItem(at: dictDir)
            throw PresetImportError.fileCopyFailed(error)
        }

        // 5. Get file size
        let fileSize: Int64
        if let attrs = try? fm.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = preset.sizeBytes
        }

        // 6. Create and save per-dictionary manifest (dict manifest)
        let mdxEntry = DictManifest.MDXEntry(
            fileName: preset.filename,
            sizeBytes: fileSize
        )
        let dictManifest = DictManifest(
            id: dictId,
            mdx: mdxEntry,
            mdd: [],
            css: [],
            js: []
        )

        do {
            try storage.saveDictManifest(dictManifest)
        } catch {
            try? fm.removeItem(at: dictDir)
            throw PresetImportError.manifestSaveFailed(error)
        }

        // 7. Add entry to root manifest
        let entry = DictionaryManifest.DictionaryEntry(
            id: dictId,
            displayName: preset.displayName,
            originalFileName: preset.filename,
            totalSizeKB: fileSize / 1024
        )
        storage.addDictionaryEntry(entry)

        do {
            try storage.saveManifest()
        } catch {
            try? fm.removeItem(at: dictDir)
            throw PresetImportError.manifestSaveFailed(error)
        }

        return dictId
    }
}
