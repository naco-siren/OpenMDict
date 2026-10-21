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

import Combine
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
    /// SHA-256 of the MDX file this app ships. Optional: catalogs before
    /// 2026-10 had no hash.
    let sha256: String?
    /// SHA-256 of every earlier build that shipped. An installed copy whose
    /// file is one of these is offered an update (see `PresetVersioning`).
    let previousSha256: [String]?
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
        case "DE": return "🇩🇪"
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

    // MARK: - Region / Hierarchical Picker

    /// Geographic/cultural region for hierarchical picker grouping.
    enum Region: String, CaseIterable {
        case farEast    = "Far East"
        case europe     = "Europe"
        case middleEast = "Middle East"
        case classical  = "Classical"
        case bible      = "Bible"

        var sortOrder: Int {
            switch self {
            case .farEast:    return 0
            case .europe:     return 1
            case .middleEast: return 2
            case .classical:  return 3
            case .bible:      return 4
            }
        }

        var headerEmoji: String {
            switch self {
            case .farEast:    return "🌏"
            case .europe:     return "🌍"
            case .middleEast: return "🕌"
            case .classical:  return "🏛️"
            case .bible:      return "✝️"
            }
        }
    }

    /// The region this dictionary belongs to in the hierarchical picker.
    var region: Region {
        // Bible dicts always go to the Bible region
        if filename.hasPrefix("Bible-") { return .bible }

        // Classical: Ancient Greek (LSJ) + Latin (Lewis-Short)
        // Note: Kaikki-LA, WikDict-LA, etc. are modern teaching tools → Classical
        // Note: LSJ uses "EL" in direction.src but is Ancient Greek
        if filename.hasPrefix("LSJ-") || filename.hasPrefix("Lewis-Short-") { return .classical }

        // Use the primary language to determine region
        switch primaryLanguage {
        case "ZH", "JA", "KO",
             "CJK", "YUE":         return .farEast
        case "AR", "TR":           return .middleEast
        case "LA", "GRC":          return .classical
        default:                   return .europe   // EN, FR, DE, ES, IT, PT, RU, EL
        }
    }

    /// The primary language for grouping within a region.
    /// - Monolingual (EN→EN): src
    /// - Bilingual X→EN: X (the non-English language is what defines the dict)
    /// - Bilingual EN→X: X (English users looking up language X)
    /// - Cross-pair X→Y: src (e.g., FR→ES goes under French)
    /// - Special: Unihan (src=ZH but serves CJK) → "CJK"
    var primaryLanguage: String {
        // Special cases first
        if filename.hasPrefix("Unihan-") { return "CJK" }
        // CC-Canto: Cantonese is a Chinese dialect → group under ZH
        // LSJ: Ancient Greek → use GRC (not modern "EL")
        if filename.hasPrefix("LSJ-") { return "GRC" }

        // EN→X bilingual: group under the target language X
        if direction.src == "EN" && !isMonolingual {
            return direction.dest[0]
        }

        // Everything else: group by source language
        return direction.src
    }

    /// Flag emoji for the primary language (may differ from direction.src flag).
    var primaryFlag: String {
        switch primaryLanguage {
        case "CJK": return "🇨🇳🇹🇼🇭🇰🇯🇵🇰🇷"
        case "YUE": return "🇭🇰"
        case "GRC": return "🏛️"
        default:    return Self.flagEmoji(for: primaryLanguage)
        }
    }

    /// Localized display name for the primary language.
    var primaryLanguageName: String {
        switch primaryLanguage {
        case "CJK": return "CJK (Unihan)"
        case "YUE": return NSLocalizedString("Cantonese", comment: "Language name for Cantonese")
        case "GRC": return NSLocalizedString("Ancient Greek", comment: "Language name for Ancient Greek")
        default:    return Self.localizedLanguageName(primaryLanguage)
        }
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
    /// Imported, but the MDX on this device is an earlier build than the
    /// one this app ships (the IDs of the copies to update)
    case updateAvailable(libraryIds: [String])
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
    /// Catalog config bug — the preset entry in `preset-dictionaries.json`
    /// lacks an `odrTag` field. NOT an ODR-domain error; can't fix at
    /// runtime, ship-blocking only. Kept separate from `.odr` for clarity.
    case odrTagMissing(presetId: String)
    /// Any On-Demand Resource acquisition failure — download, post-download
    /// file-missing, storage, network, etc. The detail lives in `ODRError`
    /// (see `Services/ODRError.swift`) which carries user-facing strings +
    /// classification logic. Previously two separate cases
    /// (`odrDownloadFailed(Error)` + `odrFileNotFound(tag:)`); merged here
    /// so all ODR-domain failures route through one place.
    case odr(ODRError)
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
        case .odr(let odrError):
            return odrError.errorDescription
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

    private var libraryCancellable: AnyCancellable?

    private init() {}

    /// Compute update status now and keep it current as the library changes
    /// (imports, deletions, iCloud sync, downloads finishing). Called once
    /// from DictionaryService.setup().
    func startTrackingUpdates() {
        refreshUpdateStatus()
        guard libraryCancellable == nil else { return }
        let metadataChanges = DictMetadataService.shared.$revision.dropFirst().map { _ in () }
        let libraryChanges = DictionaryService.shared.$allDictionaries.dropFirst().map { _ in () }
        libraryCancellable = metadataChanges.merge(with: libraryChanges)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.catalog.isEmpty else { return }
                self.refreshImportStatus()
                // New copies (an import, an iCloud download) get their
                // build recorded; cheap when there is nothing to hash.
                Task { await self.recordInstalledBuilds() }
            }
    }

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

    /// Refresh import status for all preset dictionaries by checking CoreData metadata.
    /// Matches by originalFileName; an update is offered when the MDX on this
    /// device is an earlier build this catalog lists (see PresetVersioning)
    /// and the copy can be updated right now.
    func refreshImportStatus() {
        let metadataList = DictMetadataService.shared.loadAll()
        let dictionaryService = DictionaryService.shared

        for preset in catalog {
            // Skip if already in a transient state (importing/failed)
            if case .importing = importStatus[preset.id] { continue }

            let copies = metadataList
                .filter { $0.originalFileName == preset.filename }
                .map { InstalledPresetCopy(dictId: $0.dictId, fileSha256: storage.recordedMDXSha256(id: $0.dictId)) }
            switch PresetVersioning.state(installed: copies,
                                          latestSha256: preset.sha256,
                                          previousSha256: preset.previousSha256 ?? []) {
            case .notInstalled:
                importStatus[preset.id] = .notImported
            case .current(let dictId), .unrecognized(let dictId):
                importStatus[preset.id] = .imported(libraryId: dictId)
            case .updateAvailable(let dictIds):
                let ready = dictIds.filter { dictionaryService.canUpdatePresetFile($0) }
                importStatus[preset.id] = ready.isEmpty
                    ? .imported(libraryId: dictIds[0])
                    : .updateAvailable(libraryIds: ready)
            }
        }
        let builds = Set(updatablePresets.map { "\($0.id)=\($0.sha256 ?? "")" })
        if builds != lastPostedUpdates {
            lastPostedUpdates = builds
            NotificationCenter.default.post(name: Self.updatesDidChangeNotification, object: self)
        }
    }

    // MARK: - Updates

    /// Posted (on the main actor) when the set of presets with an available
    /// update changes.
    static let updatesDidChangeNotification = Notification.Name("PresetDictionaryService.updatesDidChange")
    private var lastPostedUpdates: Set<String> = []

    /// The installed copies of a preset that can be updated now.
    func installedIdsWithUpdate(_ presetId: String) -> [String] {
        if case .updateAvailable(let ids) = importStatus[presetId] { return ids }
        return []
    }

    func isUpdateAvailable(_ presetId: String) -> Bool {
        !installedIdsWithUpdate(presetId).isEmpty
    }

    /// Installed presets for which this app ships a newer build.
    var updatablePresets: [PresetDictionary] {
        catalog.filter { isUpdateAvailable($0.id) }
    }

    /// Whether the preset is being imported or updated right now.
    func isInProgress(_ presetId: String) -> Bool {
        if case .importing = importStatus[presetId] { return true }
        return false
    }

    /// Load the catalog if needed and recompute statuses. Cheap; safe to call
    /// at launch and whenever dictionary metadata changes.
    func refreshUpdateStatus() {
        if catalog.isEmpty {
            do { try loadCatalog() } catch {
                debugLog("⚠️ Preset catalog unavailable: \(error.localizedDescription)")
                return
            }
        } else {
            refreshImportStatus()
        }
    }

    /// Record which build each installed preset's MDX is, for files that have
    /// no record yet (installed before this was recorded, or downloaded from
    /// iCloud). Until then the dictionary ID stands in for it — correct for
    /// every file that was never updated in place. Hashing runs off the main
    /// actor, once per file.
    func recordInstalledBuilds() async {
        guard !isRecordingBuilds else { return }
        isRecordingBuilds = true
        defer { isRecordingBuilds = false }
        refreshUpdateStatus()
        let names = Set(catalog.map(\.filename))
        let pending = DictMetadataService.shared.loadAll().filter {
            names.contains($0.originalFileName) && storage.recordedMDXSha256(id: $0.dictId) == nil
        }
        var recorded = 0
        for metadata in pending {
            // Stamp first: if the file is replaced while it is hashed (an
            // update), the hash is not recorded against the new file.
            guard let mdx = storage.mdxURL(id: metadata.dictId),
                  let stamp = DictionaryStorageService.fileStamp(mdx) else { continue }
            guard let sha = try? await Task.detached(priority: .utility, operation: {
                try Self.fileSHA256(mdx)
            }).value else { continue }
            storage.recordMDXSha256(sha, id: metadata.dictId, stamp: stamp)
            recorded += 1
        }
        if recorded > 0 {
            debugLog("📋 Recorded the build of \(recorded) installed preset file(s)")
            refreshImportStatus()
        }
    }

    private var isRecordingBuilds = false

    /// Update the installed copies of a preset to the build this app ships
    /// (fetched from the bundle or ODR). Each copy keeps its dictionary ID;
    /// see `DictionaryService.updatePresetFile`.
    func updatePreset(
        _ preset: PresetDictionary,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await performUpdate(preset, ids: installedIdsWithUpdate(preset.id), onProgress: onProgress)
    }

    /// `updatePreset` with the copies captured by the caller (the batch flips
    /// the status to `.importing` before its task runs).
    private func performUpdate(
        _ preset: PresetDictionary,
        ids: [String],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard !ids.isEmpty, let expected = preset.sha256 else {
            throw DictionaryService.PresetUpdateError(kind: .notReady, underlying: nil)
        }
        try await withPresetFile(preset, onProgress: onProgress) { sourceURL in
            for dictId in ids {
                try await DictionaryService.shared.updatePresetFile(dictId: dictId, from: sourceURL,
                                                                    expectedSha256: expected)
            }
        }
        importStatus[preset.id] = .imported(libraryId: ids[0])
        refreshImportStatus()
    }

    /// Make the preset's shipped MDX available (bundle, or ODR download) for
    /// the duration of `body`.
    private func withPresetFile(
        _ preset: PresetDictionary,
        onProgress: @escaping @Sendable (Double) -> Void,
        _ body: (URL) async throws -> Void
    ) async throws {
        let baseName = (preset.filename as NSString).deletingPathExtension
        if preset.isBundleAsset {
            guard let url = Bundle.main.url(forResource: baseName, withExtension: "mdx") else {
                throw PresetImportError.bundleFileNotFound(filename: preset.filename)
            }
            try await body(url)
            return
        }
        guard let tag = preset.odrTag else { throw PresetImportError.odrTagMissing(presetId: preset.id) }
        let request = NSBundleResourceRequest(tags: [tag])
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent
        activeODRRequests[preset.id] = request
        defer { activeODRRequests.removeValue(forKey: preset.id) }
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            Task { @MainActor in onProgress(progress.fractionCompleted) }
        }
        defer { observation.invalidate() }
        do {
            try await request.beginAccessingResources()
        } catch {
            throw PresetImportError.odr(ODRError.classify(error))
        }
        defer { request.endAccessingResources() }
        guard let url = Bundle.main.url(forResource: baseName, withExtension: "mdx") else {
            throw PresetImportError.odr(.fileNotFoundAfterDownload(tag: tag, filename: "\(baseName).mdx"))
        }
        try await body(url)
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
    ///   - onProgress: Progress callback (fraction 0.0–1.0)
    /// - Returns: The library dictionary ID (SHA256 hash)
    func importFromODR(
        _ preset: PresetDictionary,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        guard let tag = preset.odrTag else {
            throw PresetImportError.odrTagMissing(presetId: preset.id)
        }

        let request = NSBundleResourceRequest(tags: [tag])
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent

        // Track active request for potential cancellation
        activeODRRequests[preset.id] = request
        defer { activeODRRequests.removeValue(forKey: preset.id) }

        // Observe download progress
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            Task { @MainActor in
                onProgress(progress.fractionCompleted)
            }
        }
        defer { observation.invalidate() }

        // Download from Apple CDN
        do {
            try await request.beginAccessingResources()
        } catch {
            throw PresetImportError.odr(ODRError.classify(error))
        }

        // Find the downloaded file in bundle
        let baseName = (preset.filename as NSString).deletingPathExtension
        guard let sourceURL = Bundle.main.url(forResource: baseName, withExtension: "mdx") else {
            request.endAccessingResources()
            throw PresetImportError.odr(.fileNotFoundAfterDownload(
                tag: tag, filename: "\(baseName).mdx"
            ))
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
    ///   - onProgress: Progress callback (presetId, fraction 0.0–1.0)
    ///   - onComplete: Called when each individual import finishes (may be called concurrently)
    /// - Returns: Array of import results (order matches completion order, not input order)
    func importBatch(
        _ presets: [PresetDictionary],
        onProgress: @escaping @Sendable (String, Double) -> Void,
        onComplete: @escaping @Sendable (PresetImportResult) -> Void
    ) async -> [PresetImportResult] {

        var results: [PresetImportResult] = []

        // Launch all imports concurrently as independent Tasks.
        // Each Task runs on @MainActor (inheriting from this @MainActor class).
        // Suspension points (SHA256, ODR download) allow true concurrency.
        var tasks: [(PresetDictionary, Task<PresetImportResult, Never>)] = []

        // Decide from the current library, not from a status left by an
        // earlier attempt (a failed update must not turn into a second copy).
        refreshImportStatus()

        for preset in presets {
            // Skip a preset that an earlier batch is still working on, and
            // one that is installed and up to date.
            let updateIds = installedIdsWithUpdate(preset.id)
            if isInProgress(preset.id) || (updateIds.isEmpty && isImported(preset.id)) {
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
                    if !updateIds.isEmpty {
                        // Installed with an earlier build: replace the file in place.
                        try await performUpdate(preset, ids: updateIds) { progress in
                            onProgress(preset.id, progress)
                        }
                        dictId = updateIds[0]
                    } else if preset.isBundleAsset {
                        dictId = try await importFromBundle(preset)
                    } else {
                        dictId = try await importFromODR(preset) { progress in
                            onProgress(preset.id, progress)
                        }
                    }

                    importStatus[preset.id] = .imported(libraryId: dictId)
                    let result = PresetImportResult(presetId: preset.id, libraryId: dictId, errorMessage: nil)
                    onComplete(result)
                    print("✅ Imported preset: \(preset.displayName) → \(dictId.prefix(16))...")
                    return result

                } catch {
                    importStatus[preset.id] = .failed(error: error)
                    // An update that failed is still offered (the old file is in place).
                    if !updateIds.isEmpty { refreshImportStatus() }
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
        // 1. Calculate SHA256 hash of the MDX file (used as directory name / ID).
        //    Off the main actor: presets are tens of MB.
        let headerSHA256: String
        do {
            headerSHA256 = try await Task.detached(priority: .userInitiated) {
                try Self.fileSHA256(sourceURL)
            }.value
        } catch {
            throw PresetImportError.sha256CalculationFailed(error)
        }

        let dictId = headerSHA256
        let dictDir = storage.dictionaryDirectoryURL(id: dictId)
        let fm = FileManager.default

        // 2. Check for duplicate (same file already imported)
        if storage.isDuplicateImport(headerSHA256: headerSHA256) {
            if let manifest = storage.loadDictManifest(id: dictId),
               fm.fileExists(atPath: storage.mdxURL(id: dictId, fileName: manifest.mdx.fileName).path) {
                // Already imported — just update status and return
                importStatus[preset.id] = .imported(libraryId: headerSHA256)
                print("ℹ️ Preset \(preset.displayName) already in Library (dedup): \(headerSHA256.prefix(16))...")
                return headerSHA256
            }
            // A folder without a manifest (or MDX) is what a kill in the middle
            // of an earlier import leaves behind; nothing can load it.
            debugLog("🧹 Removing an incomplete library folder for \(dictId.prefix(16)) before installing \(preset.filename)")
            storage.invalidateDictManifestCache(id: dictId)
            try? fm.removeItem(at: dictDir)
        }

        // 3. Create directory structure: Library/Dictionaries/{sha256}/

        do {
            try fm.createDirectory(at: dictDir, withIntermediateDirectories: true)
            // Create standard subdirectories
            try fm.createDirectory(at: storage.mddDirectoryURL(id: dictId), withIntermediateDirectories: true)
            try fm.createDirectory(at: storage.cssDirectoryURL(id: dictId), withIntermediateDirectories: true)
            try fm.createDirectory(at: storage.jsDirectoryURL(id: dictId), withIntermediateDirectories: true)
            try fm.createDirectory(at: storage.fontsDirectoryURL(id: dictId), withIntermediateDirectories: true)

            // Exclude from iCloud backup — large dictionary files should not
            // consume the user's backup quota; future sync uses CloudKit instead.
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

        // 7. Save metadata to CoreData
        let now = Date()
        let metadata = DictMetadata(
            dictId: dictId,
            displayName: preset.displayName,
            originalFileName: preset.filename,
            importedAt: now,
            updatedAt: now,
            totalSizeKB: fileSize / 1024,
            mddCount: 0,
            cssCount: 0,
            jsCount: 0,
            fontsCount: 0,
            cloudSyncStatus: CloudSyncStatus.pending.rawValue,
            enhanceDarkMode: false,
            enhanceDarkModeStrength: EnhanceDarkModeStrength.standard.rawValue
        )
        storage.addDictionaryMetadata(metadata)
        storage.recordMDXSha256(dictId, id: dictId)

        return dictId
    }

    /// SHA-256 of a file, lowercase hex (a preset's dictionary ID, and the
    /// build identity of an installed preset's MDX).
    nonisolated static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
