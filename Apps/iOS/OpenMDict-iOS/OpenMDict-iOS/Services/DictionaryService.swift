//
//  DictionaryService.swift
//  OpenMDict-iOS
//
//  App-level singleton managing dictionary loading, groups, and queries.
//  Uses Combine for reactive state management with switchToLatest for query cancellation.
//
//  Data flow:
//  ```
//  searchQuery$ ─────┐
//                    ├──► CombineLatest ──► map to lookupPublisher ──► switchToLatest ──► results$
//  searchContext$ ───┘
//  ```
//

import Foundation
import Combine
import os
import OpenMDictKit

/// iOS app-level signposter for dictionary bulk-load performance.
/// Shares the same subsystem as the core lib's `mdictPerfSignposter` so
/// Instruments groups all OpenMDict-related intervals together.
private let iosBulkLoadSignposter = OSSignposter(
    subsystem: "io.github.naco-siren.openmdict",
    category: "perf"
)

// MARK: - Search Context

/// Current search context - group or single dictionary
enum SearchContext: Equatable {
    case group(MDicts)
    case dictionary(MDict)
    case none
    
    /// Get the Lookupable for this context
    var lookupable: (any Lookupable)? {
        switch self {
        case .group(let group): return group
        case .dictionary(let dict): return dict
        case .none: return nil
        }
    }
    
    static func == (lhs: SearchContext, rhs: SearchContext) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.group(let a), .group(let b)): return a.id == b.id
        case (.dictionary(let a), .dictionary(let b)): return a.id == b.id
        default: return false
        }
    }
}

// MARK: - SpellingLookupSession (defined in SpellingLookupSession.swift)

// SpellingLookupSession is a per-scene search handler.
// DictionaryService provides factory method to create them.
// See SpellingLookupSession.swift for implementation.

// MARK: - DictionaryService

@MainActor
final class DictionaryService: ObservableObject {
    
    static let shared = DictionaryService()
    
    // MARK: - Dependencies
    
    private let storage = DictionaryStorageService.shared
    
    // MARK: - State
    
    /// All loaded dictionary instances
    @Published private(set) var allDictionaries: [MDict] = []

    /// All groups (including default + user-defined)
    @Published private(set) var groups: [MDicts] = []

    /// Bumped whenever dictionary resources (MDD/CSS/JS) change.
    /// DictResourceEditorVC subscribes to this to refresh its UI.
    @Published private(set) var resourceRevision: UInt = 0

    /// Bumped when in-memory MDict display names are synced from remote metadata.
    /// DictionaryListVC subscribes to refresh sidebar cells after remote renames.
    @Published private(set) var displayNameRevision: UInt = 0
    
    /// Cancellable for CloudKit remote change subscription (groups).
    private var remoteChangeCancellable: AnyCancellable?

    private init() {}

    // MARK: - Sidecar Index Cache Bootstrap

    /// Configure the OpenMDict core lib's sidecar index cache.
    ///
    /// Must be called once per host process, **before any `MDictReader` is
    /// constructed**, so the parsers can use the sidecar fast-path on first
    /// dictionary load.
    ///
    /// - Parameter writeMode: How the parser should handle sidecar *write*
    ///   work. Reads are always enabled when the cache directory is set.
    ///     - `.disabled` — never write (use for Action Extensions, so the
    ///       main app is the single source of truth for sidecar generation).
    ///     - `.batched` — queue writes and drain them on a later
    ///       `MDictSidecarCache.flushPendingWrites()` call. The main app
    ///       uses this during its initial bulk dictionary load so all CPU
    ///       goes into parsing.
    ///     - `.immediate` — dispatch each write as soon as the parser hands
    ///       it over (default, used by CLI / tests / benches, and by the
    ///       main app once its bulk load is done).
    ///
    /// The storage location is owned by `DictionaryStorageService` — this
    /// method just wires that path into the core lib.
    ///
    /// Also opportunistically sweeps orphan `.tmp-*` sidecar files that
    /// may have been left behind if a previous sidecar write was killed
    /// mid-rename. iOS will eventually evict them under disk pressure, but
    /// doing it up-front is essentially free and keeps `Caches` tidy.
    func bootstrapSidecarCache(writeMode: SidecarWriteMode) {
        let dir = storage.sidecarIndexCacheURL
        // Best-effort creation. The writer will also create it lazily, but
        // doing it up-front surfaces permission problems at launch time.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MDictSidecarCache.cacheDirectory = dir
        MDictSidecarCache.writeMode = writeMode

        // Detached background sweep — we don't want to block launch on
        // filesystem enumeration even for a few ms.
        Task.detached(priority: .background) {
            Self.sweepOrphanSidecarTempFiles(in: dir)
        }
    }

    /// Remove orphan `.idx.tmp-*` files that are older than one hour.
    /// These can only come from a `SidecarWriter.write` call that was
    /// killed between `Data.write(.atomic)` and the `replaceItemAt` /
    /// `moveItem` rename — the rename is atomic so a successful write
    /// never leaves a tmp file behind. One hour is a generous threshold
    /// to avoid racing an in-flight write from another concurrently
    /// running process (e.g. the Action Extension — though it's
    /// configured with `.disabled` writeMode and should never produce
    /// these files).
    nonisolated private static func sweepOrphanSidecarTempFiles(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let oneHourAgo = Date().addingTimeInterval(-3600)
        var removed = 0
        for f in files where f.lastPathComponent.contains(".tmp-") {
            if let mtime = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mtime < oneHourAgo {
                try? FileManager.default.removeItem(at: f)
                removed += 1
            }
        }
        if removed > 0 {
            debugLog("🗑️ Swept \(removed) orphan sidecar tmp file(s)")
        }
    }

    // MARK: - Reset

    /// Discard all in-memory dictionaries and groups.
    /// Called during iCloud nuclear reset after the CoreData store and
    /// dictionary files have been deleted.
    func resetAllState() {
        remoteChangeCancellable?.cancel()
        remoteChangeCancellable = nil

        allDictionaries.removeAll()
        groups.removeAll()

        resourceRevision &+= 1
        displayNameRevision &+= 1
    }

    // MARK: - Search Session Factory
    
    /// Create a new search session for a scene
    /// Each scene should hold its own SpellingLookupSession instance
    func createSpellingLookupSession() -> SpellingLookupSession {
        SpellingLookupSession()
    }
    
    // MARK: - Sessions (App-wide)
    
    /// Shared import session for dictionary import workflow
    let importSession = ImportSession()
    
    /// Shared group management session for group create/edit workflow
    let groupSession = GroupManagementSession()
    
    // MARK: - Computed
    
    var defaultGroup: MDicts? {
        groups.first { $0.isDefault }
    }
    
    func group(id: String) -> MDicts? {
        groups.first { $0.id == id }
    }
    
    func dict(id: String) -> MDict? {
        allDictionaries.first { $0.id == id }
    }
    
    /// Get the import date for a dictionary (from CoreData metadata)
    func importedDate(_ dictId: String) -> Date? {
        DictMetadataService.shared.find(dictId: dictId)?.importedAt
    }
    
    // MARK: - Setup
    
    /// Call from AppDelegate on launch.
    /// Loads dictionary metadata from CoreData → user dictionaries → groups → background loading.
    /// If no metadata exists (fresh install), dictionaries will be empty until
    /// SetupViewController imports preset dictionaries.
    func setup() {
        // 1. Load dictionaries from CoreData metadata + per-dict manifests
        loadUserDictionaries()

        // 2. Setup groups from CoreData (or create defaults)
        setupGroups()

        // 3. Background loading
        Task {
            await loadAllMetadata()
            // Re-index Spotlight now that metadata (entry count, file size, author) is available
            await loadAllDictionaries()
            SpotlightIndexingService.shared.indexAllDictionaries()

            // 4. Catch-up upload: any locally-present dictionaries that were never
            // uploaded to CloudKit (e.g. presets imported before file-sync was added).
            if SyncModeService.shared.isCloudSyncEnabled {
                await uploadPendingDictionaries()
            }
        }

        // 5. CloudKit remote change — download missing dicts, then reload groups.
        // Only subscribe when cloud sync is active; in offline mode there are
        // no remote changes to process.
        if SyncModeService.shared.isCloudSyncEnabled {
            remoteChangeCancellable = CoreDataStack.shared.remoteChangePublisher
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak self] in
                    self?.handleRemoteChange()
                }
        }
    }

    /// Upload dictionaries whose `cloudSyncStatus` is still `.pending`.
    /// This covers presets that were imported before file-sync was added,
    /// or any dict whose upload was interrupted.  Runs once at launch.
    private func uploadPendingDictionaries() async {
        let allMetadata = DictMetadataService.shared.loadAll()
        let pending = allMetadata.filter {
            CloudSyncStatus(rawValue: $0.cloudSyncStatus) == .pending
        }

        guard !pending.isEmpty else { return }
        debugLog("☁️ Catch-up upload: \(pending.count) pending dictionaries")

        for metadata in pending {
            let dictDir = storage.dictionaryDirectoryURL(id: metadata.dictId)
            guard FileManager.default.fileExists(atPath: dictDir.path) else { continue }
            await DictionaryFileSyncService.shared.uploadDictionary(dictId: metadata.dictId)
        }
    }

    /// Handle a CloudKit remote change.
    ///
    /// Three concerns, in order:
    ///   1. **Remote deletes** — metadata disappeared → clean up local
    ///      files + unload MDict instance.
    ///   2. **Remote adds** — new metadata with no local files → download
    ///      from CloudKit + load into memory.
    ///   3. **Groups** — reload group membership from CoreData.
    ///
    /// Dictionaries must be resolved *before* groups, because group
    /// entries reference dictIds.
    private func handleRemoteChange() {
        Task {
            let allMetadata = DictMetadataService.shared.loadAll()
            let metadataIds = Set(allMetadata.map { $0.dictId })
            let loadedIds = Set(allDictionaries.map { $0.id })

            // --- 1. Detect remote deletes ---
            // Dictionaries loaded locally but whose metadata was deleted
            // on another device.  Clean up files + unload.
            let deletedIds = loadedIds.subtracting(metadataIds)
            for dictId in deletedIds {
                debugLog("☁️ Remote delete detected for \(dictId.prefix(16))")
                // Remove local files
                let dictDir = storage.dictionaryDirectoryURL(id: dictId)
                try? FileManager.default.removeItem(at: dictDir)
                storage.invalidateDictManifestCache(id: dictId)
                // Drop the persistent sidecar index so the cache doesn't
                // accumulate orphans. dictId == MDX header SHA256 in this
                // app, so it doubles as the sidecar file name.
                // `DictionaryStorageService.deleteDictionary()` already does
                // this for the user-initiated delete path — mirror it here
                // for the iCloud remote-delete path.
                MDictReader.removeSidecarCache(forHeaderSHA256: dictId)
                // Unload from memory + remove from groups
                refreshAfterDelete(dictId)
                // De-index from Spotlight
                SpotlightIndexingService.shared.deindexDictionary(id: dictId)
            }

            // --- 2. Detect remote adds ---
            // Metadata records whose dictionary files aren't loaded yet.
            let missingIds = metadataIds.subtracting(loadedIds)
            for dictId in missingIds {
                let dictDir = storage.dictionaryDirectoryURL(id: dictId)
                let hasLocalFiles = FileManager.default.fileExists(atPath: dictDir.path)

                if hasLocalFiles {
                    // Files exist but MDict not loaded (race on launch)
                    await refreshAfterImport(dictId)
                } else {
                    // Check cloudSyncStatus before attempting download.
                    // If the originating device hasn't finished uploading yet
                    // (status == .pending), the CKRecord doesn't exist —
                    // skip to avoid pointless "Record not found" errors.
                    let metadata = allMetadata.first { $0.dictId == dictId }
                    let syncStatus = metadata.flatMap {
                        CloudSyncStatus(rawValue: $0.cloudSyncStatus)
                    } ?? .pending

                    guard syncStatus == .synced else {
                        debugLog("☁️ Skipping download for \(dictId.prefix(16)): cloudSyncStatus=\(syncStatus)")
                        continue
                    }

                    // Files not on device → download from CloudKit
                    DictMetadataService.shared.markDownloading(dictId)
                    let downloaded = await DictionaryFileSyncService.shared
                        .downloadDictionary(dictId: dictId)
                    DictMetadataService.shared.clearDownloading(dictId)
                    if downloaded {
                        await refreshAfterImport(dictId)
                    }
                }
            }

            // --- 3. Detect remote updates ---
            // Already-loaded dictionaries whose files changed on another device
            // (e.g. MDD added/removed).  Compare local manifest against synced metadata.
            let existingIds = loadedIds.intersection(metadataIds)
            for dictId in existingIds {
                guard let metadata = allMetadata.first(where: { $0.dictId == dictId }) else { continue }
                let syncStatus = CloudSyncStatus(rawValue: metadata.cloudSyncStatus) ?? .pending
                guard syncStatus == .synced else { continue }

                // Compare local resource counts against metadata from CoreData
                let localManifest = self.storage.loadDictManifest(id: dictId)
                let localMddCount = Int32(localManifest?.mdd.count ?? 0)
                let localCssCount = Int32(localManifest?.css.count ?? 0)
                let localJsCount  = Int32(localManifest?.js.count ?? 0)

                let changed = localMddCount != metadata.mddCount
                    || localCssCount != metadata.cssCount
                    || localJsCount  != metadata.jsCount

                guard changed else { continue }

                debugLog("☁️ Remote update detected for \(dictId.prefix(16)): "
                    + "mdd \(localMddCount)→\(metadata.mddCount), "
                    + "css \(localCssCount)→\(metadata.cssCount), "
                    + "js \(localJsCount)→\(metadata.jsCount)")

                // Per-file incremental update: fetch remote manifest → diff → download only changed files
                DictMetadataService.shared.markDownloading(dictId)

                guard let remoteManifest = await DictionaryFileSyncService.shared
                        .fetchRemoteManifest(dictId: dictId) else {
                    DictMetadataService.shared.clearDownloading(dictId)
                    debugLog("❌ Remote manifest fetch failed for \(dictId.prefix(16))")
                    continue
                }

                let updated = await DictionaryFileSyncService.shared
                    .downloadUpdatedFiles(dictId: dictId, remoteManifest: remoteManifest)

                DictMetadataService.shared.clearDownloading(dictId)

                if updated {
                    self.storage.invalidateDictManifestCache(id: dictId)
                    // Reload MDD/CSS/JS resources from the updated files
                    self.reloadMDDResources(for: dictId)
                    debugLog("☁️ Remote update applied for \(dictId.prefix(16))")
                } else {
                    debugLog("❌ Remote incremental update failed for \(dictId.prefix(16))")
                }
            }

            // --- 3b. Sync metadata fields (displayName) to live MDict instances ---
            var anyNameChanged = false
            for dictId in existingIds {
                guard let metadata = allMetadata.first(where: { $0.dictId == dictId }),
                      let dict = self.dict(id: dictId) else { continue }
                if dict.userDisplayName != metadata.displayName {
                    debugLog("☁️ displayName updated: \(dictId.prefix(16))… "
                        + "\"\(dict.userDisplayName ?? "nil")\" → \"\(metadata.displayName)\"")
                    dict.userDisplayName = metadata.displayName
                    anyNameChanged = true
                }
            }
            if anyNameChanged {
                displayNameRevision += 1
            }

            // --- 4. Reload groups ---
            reloadGroupsFromCoreData()
        }
    }

    /// Reload groups from CoreData after a CloudKit remote change.
    /// Preserves loaded MDict instances — only group membership changes.
    private func reloadGroupsFromCoreData() {
        let loadedGroups = groupPersistence.loadGroups()
        guard !loadedGroups.isEmpty else { return }

        groups = loadedGroups.map { loaded in
            let validIds = loaded.dictionaryIds.filter { id in
                allDictionaries.contains { $0.id == id }
            }
            let group = MDicts(
                id: loaded.groupId,
                name: loaded.isDefault ? L10n.GroupInfo.allDictionaries : loaded.name,
                isDefault: loaded.isDefault,
                dictionaryIds: validIds,
                createdAt: loaded.createdAt,
                modifiedAt: loaded.modifiedAt
            )
            group.populate(from: allDictionaries)
            return group
        }

        debugLog("☁️ DictionaryService: reloaded \(groups.count) groups from CoreData")
    }

    private func loadUserDictionaries() {
        let metadataList = DictMetadataService.shared.loadAll()

        let importedDicts: [MDict] = metadataList.compactMap { metadata -> MDict? in
            // Load dict manifest to get actual MDX filename
            guard let dictManifest = storage.loadDictManifest(id: metadata.dictId) else {
                print("⚠️ Dict manifest not found for: \(metadata.displayName) (id: \(metadata.dictId))")
                return nil
            }

            // Use MDX filename from dict manifest
            let mdxPath = storage.mdxURL(id: metadata.dictId, fileName: dictManifest.mdx.fileName).path
            guard FileManager.default.fileExists(atPath: mdxPath) else {
                print("⚠️ Imported dictionary MDX not found: \(metadata.displayName) at \(mdxPath)")
                return nil
            }

            // Build MDD paths from dict manifest
            let mddDir = storage.mddDirectoryURL(id: metadata.dictId)
            let mddPaths: [String] = dictManifest.mdd.map { mddEntry in
                mddDir.appendingPathComponent(mddEntry.fileName).path
            }

            // Use metadata's dictId (SHA256) as the MDict id
            let dict = MDict(path: mdxPath, id: metadata.dictId, mddPaths: mddPaths)
            // Inject user display name from CoreData
            dict.userDisplayName = metadata.displayName

            if !mddPaths.isEmpty {
                print("📦 Loaded \(metadata.displayName) with \(mddPaths.count) MDD files")
            }

            return dict
        }

        allDictionaries.append(contentsOf: importedDicts)
        print("📚 Found \(importedDicts.count) dictionaries in Library")
    }
    
    private let groupPersistence = GroupPersistenceService.shared

    private func setupGroups() {
        let loadedGroups = groupPersistence.loadGroups()

        if !loadedGroups.isEmpty {
            // Restore from CoreData
            groups = loadedGroups.map { loaded in
                // Filter to only IDs that exist in allDictionaries
                let validIds = loaded.dictionaryIds.filter { id in
                    allDictionaries.contains { $0.id == id }
                }
                let group = MDicts(
                    id: loaded.groupId,
                    name: loaded.isDefault ? L10n.GroupInfo.allDictionaries : loaded.name,
                    isDefault: loaded.isDefault,
                    dictionaryIds: validIds,
                    createdAt: loaded.createdAt,
                    modifiedAt: loaded.modifiedAt
                )
                group.populate(from: allDictionaries)
                return group
            }
        } else {
            // First launch (no CoreData records) — create default group
            let now = Date()
            let allGroup = MDicts(
                id: "all",
                name: L10n.GroupInfo.allDictionaries,
                isDefault: true,
                dictionaryIds: allDictionaries.map { $0.id },
                createdAt: now,
                modifiedAt: now
            )
            allGroup.populate(from: allDictionaries)
            groups = [allGroup]

            // Persist the newly created default group
            if !allDictionaries.isEmpty {
                persistGroups()
            }
        }

        print("📂 Setup \(groups.count) groups")
    }
    
    // MARK: - Loading
    /// Load only metadata for all dictionaries (fast, parallel)
    /// After this, sidebar can display dictionary names
    func loadAllMetadata() async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await withTaskGroup(of: Void.self) { group in
            for dict in allDictionaries {
                group.addTask {
                    await dict.loadMetadata()
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("📖 All metadata loaded in \(String(format: "%.0f", elapsed))ms")
    }

    /// Load full reader for all dictionaries.
    ///
    /// On **high-RAM devices** (`DeviceCapability.ramTier == .high`, i.e.
    /// ≥ 6 GB physical RAM — roughly iPhone 13 Pro / iPad M1 and above)
    /// loads are dispatched concurrently via `TaskGroup` with bounded
    /// parallelism, so an 8-performance-core chip can load 10 dictionaries
    /// in roughly the time of the single slowest one. On mid- and low-RAM
    /// devices we stay sequential to avoid piling several dicts' parse
    /// buffers into memory simultaneously — jetsam on a 2 GB iPhone 8 is
    /// unforgiving and sequential loads never exceed one dict's worth of
    /// transient heap at a time.
    ///
    /// Concurrency is safe because the mmap-backed `BinaryReader` has no
    /// cross-reader shared state, and `MDictSidecarCache.enqueueWrite` is
    /// protected by its own `NSLock`.
    ///
    /// **Note on Top-1 ordering**: under parallel mode, the first dict in
    /// `sortedLoadSequence()` (the user's Top-1 in `.auto` mode) is still
    /// the first task *dispatched* — it starts loading at t=0 alongside
    /// the rest of the first `maxConcurrent` batch — but its *completion*
    /// is no longer guaranteed to be first. If Top-1 happens to be the
    /// largest dict and it's a cold launch (slow path), faster dicts may
    /// finish before it. Sequential mode preserves the strict ordering.
    /// The trade-off favours parallel because (a) warm launches dominate
    /// once the sidecar exists, (b) on warm launches the per-dict init
    /// is sub-25ms so completion order is imperceptible, and (c) inserting
    /// a serial preamble for Top-1 would hurt everyone to fix a rare cold-
    /// launch edge case.
    ///
    /// `MDict.$state` changes notify subscribers regardless of path.
    func loadAllDictionaries() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        let loadSequence = sortedLoadSequence()

        // Umbrella signpost — wraps the whole bulk load so Instruments
        // shows one span containing all nested MDXParser/MDDParser.init
        // intervals. Tagged with dict count + execution mode for quick
        // interpretation in the timeline.
        let bulkSignpostID = iosBulkLoadSignposter.makeSignpostID()
        let parallel = DeviceCapability.ramTier == .high
        let bulkState = iosBulkLoadSignposter.beginInterval(
            "DictionaryService.bulkLoad",
            id: bulkSignpostID,
            "count=\(loadSequence.count) mode=\(parallel ? "parallel" : "serial")"
        )

        if parallel {
            // Bounded concurrency: up to `maxConcurrent` dicts loading at
            // once. Cap at the min of (dict count, physical CPU count, 6)
            // so we neither spin off idle slots nor oversubscribe a device
            // with only 2 P-cores. The ceiling of 6 exists because dict
            // parsing is mostly LZO/zlib decompression (CPU-bound) and
            // diminishing returns kick in quickly past 4–6 concurrent.
            let maxConcurrent = Swift.min(
                loadSequence.count,
                Swift.max(2, ProcessInfo.processInfo.activeProcessorCount),
                6
            )

            await withTaskGroup(of: Void.self) { group in
                var iterator = loadSequence.makeIterator()
                var inFlight = 0

                // Prime the pipe with `maxConcurrent` initial tasks.
                while inFlight < maxConcurrent, let next = iterator.next() {
                    group.addTask { await Self.loadOne(next) }
                    inFlight += 1
                }
                // Keep the pipe full: whenever one task finishes, spawn
                // the next dict in the sorted load order.
                while await group.next() != nil {
                    if let next = iterator.next() {
                        group.addTask { await Self.loadOne(next) }
                    }
                }
            }
        } else {
            // Sequential fallback: identical semantics, lower peak memory.
            for dict in loadSequence {
                await Self.loadOne(dict)
            }
        }

        iosBulkLoadSignposter.endInterval("DictionaryService.bulkLoad", bulkState)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("📚 All dictionaries loaded in \(String(format: "%.0f", elapsed))ms (\(parallel ? "parallel" : "serial"))")

        // Bulk load phase is done. Flush any sidecar writes that were queued
        // while `writeMode == .batched`, then switch to `.immediate` so any
        // subsequently imported / downloaded dictionaries write their
        // sidecars as soon as the parser finishes (no batch to join).
        let pending = MDictSidecarCache.pendingWriteCount
        if pending > 0 {
            print("📝 Flushing \(pending) pending sidecar write(s)")
        }
        MDictSidecarCache.flushPendingWrites()
        MDictSidecarCache.writeMode = .immediate
    }

    /// Single-dict load wrapper used by both the parallel TaskGroup path
    /// and the sequential fallback. Kept as a static helper so the
    /// TaskGroup closure doesn't have to capture `self`.
    private static func loadOne(_ dict: MDict) async {
        do {
            try await dict.load()
            print("✅ Loaded: \(dict.loggingTitle)")
        } catch {
            print("❌ Failed to load \(dict.id): \(error)")
        }
    }

    // MARK: - Load Order

    private enum DictionaryLoadOrder: Int {
        case byGroupOrder      = 0
        case auto              = 1  // Top-1 guaranteed + tiered lexicographic (bookmark >> lookup > order ≈ size)
        case smallestFirst     = 2
        case byUsageFrequency  = 3  // Tiered lexicographic, no Top-1 guarantee
    }

    /// Log-base-5 tier bucketing. ~5× difference needed to jump a tier.
    /// tier(0)=0, tier(3)=0, tier(4)=1, tier(23)=1, tier(24)=2, tier(123)=2, tier(124)=3, ...
    private static func tier(_ count: Int) -> Int {
        count <= 0 ? 0 : Int(log(Double(count) + 1) / log(5.0))
    }

    /// Sort `allDictionaries` for loading based on user setting.
    /// Does NOT mutate `allDictionaries` — display/search order is unaffected.
    private func sortedLoadSequence() -> [MDict] {
        let raw = UserDefaults.standard.integer(forKey: "dictionaryLoadOrder")
        let order = DictionaryLoadOrder(rawValue: raw) ?? .auto
        let defaultIds = defaultGroup?.dictionaryIds ?? []

        switch order {
        case .byGroupOrder:
            return allDictionaries.sorted { a, b in
                let ai = defaultIds.firstIndex(of: a.id) ?? Int.max
                let bi = defaultIds.firstIndex(of: b.id) ?? Int.max
                return ai < bi
            }

        case .auto:
            // Top-1 always loads first; rest sorted by tiered lexicographic priority.
            // Version-number model: bookmarkTier >> lookupTier > orderIndex ≈ sizeKB
            let topId = defaultIds.first
            let rest = allDictionaries.filter { $0.id != topId }
            let sorted = Self.sortByEngagementThenOrder(rest, defaultIds: defaultIds, dictCount: allDictionaries.count)
            if let topDict = allDictionaries.first(where: { $0.id == topId }) {
                return [topDict] + sorted
            }
            return sorted

        case .byUsageFrequency:
            // Same tiered lexicographic sort, but no Top-1 guarantee.
            return Self.sortByEngagementThenOrder(allDictionaries, defaultIds: defaultIds, dictCount: allDictionaries.count)

        case .smallestFirst:
            let metadataMap = Dictionary(
                uniqueKeysWithValues: DictMetadataService.shared.loadAll().map { ($0.dictId, $0) }
            )
            return allDictionaries.sorted { a, b in
                (metadataMap[a.id]?.totalSizeKB ?? 0) < (metadataMap[b.id]?.totalSizeKB ?? 0)
            }
        }
    }

    /// Tiered lexicographic sort: bookmarkTier DESC → lookupTier DESC → orderIndex ASC → sizeKB ASC.
    /// Cold start (all trophies = 0): degrades to orderIndex + sizeKB.
    private static func sortByEngagementThenOrder(_ dicts: [MDict], defaultIds: [String], dictCount: Int) -> [MDict] {
        let bookmarks = BookmarkCountService.shared.allDictBookmarkCounts()
        let lookups = LookupCountService.shared.allDictLookupCounts()
        let metadataMap = Dictionary(
            uniqueKeysWithValues: DictMetadataService.shared.loadAll().map { ($0.dictId, $0) }
        )

        return dicts.sorted { a, b in
            // Tier 1: bookmark trophy tier (higher = load first)
            let bkA = tier(Int(bookmarks[a.id] ?? 0))
            let bkB = tier(Int(bookmarks[b.id] ?? 0))
            if bkA != bkB { return bkA > bkB }

            // Tier 2: lookup trophy tier (higher = load first)
            let lkA = tier(Int(lookups[a.id] ?? 0))
            let lkB = tier(Int(lookups[b.id] ?? 0))
            if lkA != lkB { return lkA > lkB }

            // Tier 3: group order index (lower = load first)
            let oA = defaultIds.firstIndex(of: a.id) ?? dictCount
            let oB = defaultIds.firstIndex(of: b.id) ?? dictCount
            if oA != oB { return oA < oB }

            // Tier 4: file size in KB (smaller = load first)
            let sA = metadataMap[a.id]?.totalSizeKB ?? 0
            let sB = metadataMap[b.id]?.totalSizeKB ?? 0
            return sA < sB
        }
    }
    
    // MARK: - Import / Delete / Persist

    /// Check if a dictionary with this header SHA256 is already imported
    func isDuplicateImport(headerSHA256: String) -> Bool {
        storage.isDuplicateImport(headerSHA256: headerSHA256)
    }

    /// Import a dictionary using data from the current ImportSession.
    /// The session must have an MDX file set. Resource files (MDD/CSS/JS) are read from the session.
    /// - Parameter displayName: Display name for the dictionary
    /// - Returns: The new dictionary's ID
    func importDictionary(displayName: String) async throws -> String {
        guard let mdxPendingFile = importSession.mdxPendingFile,
              let headerSHA256 = importSession.mdxMetadata?.headerSHA256 else {
            throw NSError(domain: "DictionaryService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No MDX file selected in ImportSession"])
        }
        
        let mdxFile = SelectedFile(url: mdxPendingFile.url)
        let mddFiles = importSession.pendingMDDFiles.map { SelectedFile(url: $0.url) }
        let cssFiles = importSession.pendingCSSFiles.map { SelectedFile(url: $0.url) }
        let jsFiles = importSession.pendingJSFiles.map { SelectedFile(url: $0.url) }
        
        // 1. Copy files to storage
        let dictId = try await storage.importDictionary(
            mdxFile: mdxFile,
            mddFiles: mddFiles,
            cssFiles: cssFiles,
            jsFiles: jsFiles,
            displayName: displayName,
            headerSHA256: headerSHA256
        )

        // 2. Load into memory and update groups (also triggers CloudKit upload)
        await refreshAfterImport(dictId)

        // 3. Index for Spotlight search
        if let newDict = dict(id: dictId) {
            SpotlightIndexingService.shared.indexDictionary(newDict)
        }

        // 4. Reset import session
        importSession.reset()

        return dictId
    }

    /// Delete a dictionary
    /// - Parameter dictId: Dictionary ID to delete
    func deleteDictionary(dictId: String) throws {
        // 1. Remove from storage
        try storage.deleteDictionary(id: dictId)

        // 2. Remove from memory and update groups
        refreshAfterDelete(dictId)

        // 3. Remove from Spotlight index
        SpotlightIndexingService.shared.deindexDictionary(id: dictId)

        // 4. Remove CloudKit records in the background (fire-and-forget)
        Task {
            await DictionaryFileSyncService.shared.deleteCloudRecords(dictId: dictId)
        }
    }
    
    /// Update display name for a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - newName: New display name
    func updateDisplayName(dictId: String, newName: String) {
        // 1. Update in-memory MDict instance
        guard let dict = dict(id: dictId) else {
            print("⚠️ Dictionary not found for rename: \(dictId)")
            return
        }
        dict.userDisplayName = newName

        // 2. Persist to CoreData
        storage.updateDisplayName(id: dictId, newName: newName)
    }
    
    /// Update default group order (e.g., after reordering in sidebar)
    func updateDefaultOrder(_ newOrder: [String]) {
        guard let defaultGroup = defaultGroup else { return }
        defaultGroup.dictionaryIds = newOrder
        defaultGroup.populate(from: allDictionaries)
        defaultGroup.modifiedAt = Date()
        persistGroups()
    }
    
    // MARK: - Internal Refresh (called by methods above)
    
    /// Load a newly imported dictionary into memory and add it to groups.
    /// Called after importing a new dictionary (either from ImportSession or PresetDictionaryService).
    /// - Parameter id: The new dictionary's ID (SHA256 hash)
    func refreshAfterImport(_ id: String) async {
        debugLog("🔄 refreshAfterImport: \(id.prefix(16))...")

        // Safety check: don't add if already exists
        if allDictionaries.contains(where: { $0.id == id }) {
            debugLog("⚠️ Dictionary already in allDictionaries, skipping")
            return
        }

        // 1. Create MDict instance with MDD paths from dict manifest
        guard let mdxPath = storage.mdxURL(id: id)?.path else {
            debugLog("⚠️ MDX file not found! skipping")
            return
        }

        // Build MDD paths from dict manifest (same as loadImportedDictionaries)
        var mddPaths: [String] = []
        if let dictManifest = storage.loadDictManifest(id: id) {
            let mddDir = storage.mddDirectoryURL(id: id)
            mddPaths = dictManifest.mdd.map { mddEntry in
                mddDir.appendingPathComponent(mddEntry.fileName).path
            }
            if !mddPaths.isEmpty {
                debugLog("📦 refreshAfterImport: found \(mddPaths.count) MDD files")
            }
        }

        let newDict = MDict(path: mdxPath, id: id, mddPaths: mddPaths)

        // Inject user display name from CoreData metadata
        if let metadata = DictMetadataService.shared.find(dictId: id) {
            newDict.userDisplayName = metadata.displayName
        }

        // 2. Add to dictionary list
        allDictionaries.append(newDict)
        debugLog("📚 allDictionaries count: \(allDictionaries.count)")

        // 3. Add to default group
        if let defaultGroup = defaultGroup {
            // Check before append to prevent duplicates
            if !defaultGroup.dictionaryIds.contains(id) {
                defaultGroup.dictionaryIds.append(id)
                debugLog("✅ Added to dictionaryIds, count: \(defaultGroup.dictionaryIds.count)")
            } else {
                debugLog("⚠️ ID already in dictionaryIds, skipping")
            }
            defaultGroup.populate(from: allDictionaries)
            debugLog("📋 defaultGroup.items count: \(defaultGroup.items.count)")
        }
        
        // 4. Persist updated default group order.
        // Skip when the dictionary was downloaded from CloudKit (status == .synced):
        // its group membership is managed by CloudKit sync, and writing the
        // in-memory groups array back would delete user groups that CloudKit
        // has synced into CoreData but aren't loaded in memory yet.
        let isCloudDownloaded: Bool = {
            guard let meta = DictMetadataService.shared.find(dictId: id) else { return false }
            return CloudSyncStatus(rawValue: meta.cloudSyncStatus) == .synced
        }()
        if !isCloudDownloaded {
            persistGroups()
        }
        
        // 5. Load metadata + full reader
        await newDict.loadMetadata()

        do {
            try await newDict.load()
            // Debug: show raw title vs resolved title
            if let meta = newDict.metadata {
                debugLog("✅ Loaded imported dictionary:")
                debugLog("  id: \(id.prefix(16))...")
                debugLog("  loggingTitle: \(newDict.loggingTitle)")
                debugLog("  description prefix: \(meta.description.prefix(100))...")
            }
        } catch {
            debugLog("❌ Failed to load imported dictionary \(id): \(error)")
        }

        // 6. Upload to CloudKit if not already synced (fire-and-forget).
        //    Covers both user-imported and preset dictionaries.
        //    Skipped when the dict was just downloaded from CloudKit
        //    (cloudSyncStatus already set to .synced before calling this method).
        if let metadata = DictMetadataService.shared.find(dictId: id) {
            let status = CloudSyncStatus(rawValue: metadata.cloudSyncStatus) ?? .pending
            if status == .pending {
                Task {
                    await DictionaryFileSyncService.shared.uploadDictionary(dictId: id)
                }
            }
        }
    }
    
    /// Called after deleting a dictionary
    /// - Parameter id: The deleted dictionary's ID
    private func refreshAfterDelete(_ id: String) {
        // 1. Remove from allDictionaries
        allDictionaries.removeAll { $0.id == id }
        
        // 2. Remove from all groups
        for group in groups {
            group.dictionaryIds.removeAll { $0 == id }
            group.populate(from: allDictionaries)
        }
        
        // 3. Persist updated groups
        persistGroups()
        
        print("🗑️ Removed dictionary from service: \(id)")
    }
    
    /// Persist current group configuration to CoreData.
    func persistGroups() {
        let savedGroups = groups.map { group in
            GroupPersistenceService.SavedGroup(
                groupId: group.id,
                name: group.name,
                isDefault: group.isDefault,
                createdAt: group.createdAt,
                modifiedAt: group.modifiedAt,
                dictionaryIds: group.dictionaryIds
            )
        }
        groupPersistence.saveAllGroups(savedGroups)
    }
    
    // MARK: - Group CRUD
    
    /// Create a new user group
    /// - Parameter name: Display name for the group (auto-deduplicated if conflict)
    /// - Returns: The new MDicts group instance (already added to `groups` and persisted)
    @discardableResult
    func createGroup(name: String = L10n.GroupInfo.newGroup) -> MDicts {
        let finalName = uniqueGroupName(from: name)
        
        let now = Date()
        let group = MDicts(
            id: UUID().uuidString,
            name: finalName,
            isDefault: false,
            dictionaryIds: [],
            createdAt: now,
            modifiedAt: now
        )
        groups.append(group)
        
        persistGroups()
        
        print("➕ Created group: \(finalName) (\(group.id.prefix(8))...)")
        return group
    }
    
    /// Rename a user group
    /// - Throws: `GroupNameConflictError` if another group already has this name
    func renameGroup(id: String, newName: String) throws {
        guard let group = groups.first(where: { $0.id == id && !$0.isDefault }) else {
            print("⚠️ User group not found: \(id)")
            return
        }
        
        // Check for name conflict (excluding self)
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if groups.contains(where: { $0.id != id && !$0.isDefault && $0.name == trimmedName }) {
            throw GroupNameConflictError(name: trimmedName)
        }
        
        group.name = trimmedName
        group.modifiedAt = Date()
        
        persistGroups()
        displayNameRevision += 1
        debugLog("✏️ Renamed group \(id.prefix(8))... to: \(trimmedName)")
    }
    
    /// Error thrown when a group name already exists
    struct GroupNameConflictError: LocalizedError {
        let name: String
        var errorDescription: String? {
            "A group named \"\(name)\" already exists."
        }
    }
    
    /// Generate a unique group name by appending a suffix if needed
    /// Internal (not private) so GroupManagementSession can use it
    func uniqueGroupName(from baseName: String) -> String {
        let existingNames = Set(groups.filter { !$0.isDefault }.map { $0.name })
        
        if !existingNames.contains(baseName) {
            return baseName
        }
        
        // Append " 2", " 3", etc.
        var counter = 2
        while existingNames.contains("\(baseName) \(counter)") {
            counter += 1
        }
        return "\(baseName) \(counter)"
    }
    
    /// Delete a user group (does NOT delete dictionaries)
    func deleteGroup(id: String) {
        groups.removeAll { $0.id == id && !$0.isDefault }

        // Persist all groups (removing the deleted group from CoreData)
        persistGroups()
        
        print("🗑️ Deleted group: \(id.prefix(8))...")
    }
    
    /// Reorder user groups (default group is excluded from reordering).
    /// `newOrder` contains user group IDs in the desired order.
    func reorderUserGroups(newOrder: [String]) {
        let defaultGroups = groups.filter { $0.isDefault }
        let reordered = newOrder.compactMap { id in groups.first { $0.id == id } }
        
        // Default group(s) first, then reordered user groups
        groups = defaultGroups + reordered
        
        persistGroups()
        print("🔄 Reordered \(newOrder.count) user groups")
    }
    
    /// Add a dictionary to a user group
    func addDictionaryToGroup(groupId: String, dictId: String) {
        guard let group = groups.first(where: { $0.id == groupId && !$0.isDefault }) else {
            print("⚠️ User group not found: \(groupId)")
            return
        }
        guard !group.dictionaryIds.contains(dictId) else {
            print("⚠️ Dictionary \(dictId.prefix(8))... already in group")
            return
        }
        
        group.dictionaryIds.append(dictId)
        group.populate(from: allDictionaries)
        group.modifiedAt = Date()
        
        persistGroups()
        print("➕ Added dict \(dictId.prefix(8))... to group \(groupId.prefix(8))...")
    }
    
    /// Remove a dictionary from a user group (does NOT delete dictionary)
    func removeDictionaryFromGroup(groupId: String, dictId: String) {
        guard let group = groups.first(where: { $0.id == groupId && !$0.isDefault }) else {
            print("⚠️ User group not found: \(groupId)")
            return
        }
        
        group.dictionaryIds.removeAll { $0 == dictId }
        group.populate(from: allDictionaries)
        group.modifiedAt = Date()
        
        persistGroups()
        print("➖ Removed dict \(dictId.prefix(8))... from group \(groupId.prefix(8))...")
    }
    
    /// Reorder dictionaries within a user group
    func reorderDictionariesInGroup(groupId: String, newOrder: [String]) {
        guard let group = groups.first(where: { $0.id == groupId }) else {
            print("⚠️ Group not found: \(groupId)")
            return
        }
        
        group.dictionaryIds = newOrder
        group.populate(from: allDictionaries)
        group.modifiedAt = Date()
        
        persistGroups()
        print("🔄 Reordered \(newOrder.count) dicts in group \(groupId.prefix(8))...")
    }
    
    // MARK: - Lookup API (for article display)
    
    /// Lookup in a group (returns AsyncStream for progressive results)
    func lookup(_ word: String, in group: MDicts) -> AsyncStream<ArticleDisplayItem> {
        AsyncStream { continuation in
            Task {
                for await result in group.lookup(word) {
                    continuation.yield(ArticleDisplayItem(from: result))
                }
                continuation.finish()
            }
        }
    }
    
    /// Lookup in a single dictionary
    func lookup(_ word: String, in dict: MDict) -> ArticleDisplayItem? {
        guard let entry = dict.lookup(word) else { return nil }
        return ArticleDisplayItem(from: entry, dict: dict)
    }
    
    // MARK: - Resource Management (Public API)
    
    /// Get all resources for a dictionary (MDX + MDD + CSS + JS)
    /// - Parameter dictId: Dictionary ID
    /// - Returns: List of ResourceFile for UI display
    func resources(for dictId: String) -> [ResourceFile] {
        storage.allResources(for: dictId)
    }

    /// Add an MDD file to a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileURL: Source file URL (from UIDocumentPicker)
    /// - Returns: fileName of the added file
    func addMDD(to dictId: String, from fileURL: URL) async throws -> String {
        let fileName = try await storage.addMDDResource(dictId: dictId, sourceURL: fileURL)
        // Reload MDD resources in MDict instance
        reloadMDDResources(for: dictId)
        // Incremental CloudKit sync (fire-and-forget)
        syncAfterResourceAdd(dictId: dictId, fileName: fileName, subdirectory: "mdd")
        return fileName
    }

    /// Remove an MDD file from a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileName: File name to remove
    func removeMDD(from dictId: String, fileName: String) throws {
        try storage.removeMDDResource(dictId: dictId, fileName: fileName)
        // Reload MDD resources in MDict instance
        reloadMDDResources(for: dictId)
        // Incremental CloudKit sync (fire-and-forget)
        syncAfterResourceRemove(dictId: dictId, fileName: fileName)
    }
    
    /// Reload MDD resources for a dictionary after add/remove.
    /// Also bumps `resourceRevision` so DictResourceEditorVC can refresh.
    private func reloadMDDResources(for dictId: String) {
        guard let dict = dict(id: dictId) else { return }
        let mddPaths = storage.listMDDFiles(for: dictId).map { $0.path }
        dict.reloadResources(mddPaths: mddPaths)
        resourceRevision += 1
    }

    /// Add a CSS file to a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileURL: Source file URL (from UIDocumentPicker)
    /// - Returns: fileName of the added file
    func addCSS(to dictId: String, from fileURL: URL) async throws -> String {
        let fileName = try await storage.addCSSResource(dictId: dictId, sourceURL: fileURL)
        // Incremental CloudKit sync (fire-and-forget)
        syncAfterResourceAdd(dictId: dictId, fileName: fileName, subdirectory: "css")
        return fileName
    }

    /// Remove a CSS file from a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileName: File name to remove
    func removeCSS(from dictId: String, fileName: String) throws {
        try storage.removeCSSResource(dictId: dictId, fileName: fileName)
        // Incremental CloudKit sync (fire-and-forget)
        syncAfterResourceRemove(dictId: dictId, fileName: fileName)
    }

    /// Add a JS file to a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileURL: Source file URL (from UIDocumentPicker)
    /// - Returns: fileName of the added file
    func addJS(to dictId: String, from fileURL: URL) async throws -> String {
        let fileName = try await storage.addJSResource(dictId: dictId, sourceURL: fileURL)
        // Incremental CloudKit sync (fire-and-forget)
        syncAfterResourceAdd(dictId: dictId, fileName: fileName, subdirectory: "js")
        return fileName
    }

    /// Remove a JS file from a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileName: File name to remove
    func removeJS(from dictId: String, fileName: String) throws {
        try storage.removeJSResource(dictId: dictId, fileName: fileName)
        // Incremental CloudKit sync (fire-and-forget)
        syncAfterResourceRemove(dictId: dictId, fileName: fileName)
    }

    // MARK: - Incremental CloudKit Sync Helpers

    /// Sync resource counts from manifest into metadata (CoreData).
    /// This ensures the remote device's `handleRemoteChange` Phase 3
    /// can detect resource changes by comparing metadata counts.
    private func syncMetadataResourceCounts(dictId: String) {
        guard let manifest = storage.loadDictManifest(id: dictId) else { return }
        DictMetadataService.shared.syncResourceCounts(
            dictId: dictId,
            mddCount: manifest.mdd.count,
            cssCount: manifest.css.count,
            jsCount: manifest.js.count,
            totalSizeKB: manifest.totalSizeKB
        )
    }

    /// Fire-and-forget: upload a newly added resource file + updated manifest.
    private func syncAfterResourceAdd(dictId: String, fileName: String, subdirectory: String) {
        // Update metadata counts so remote devices detect the change
        syncMetadataResourceCounts(dictId: dictId)
        Task {
            let dictDir = storage.dictionaryDirectoryURL(id: dictId)
            let fileURL = dictDir.appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent(fileName)

            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attrs?[.size] as? Int64) ?? 0

            // Read hash from manifest entry (just written by storage)
            let manifest = storage.loadDictManifest(id: dictId)
            let entries: [DictManifest.ResourceEntry]
            switch subdirectory {
            case "mdd": entries = manifest?.mdd ?? []
            case "css": entries = manifest?.css ?? []
            case "js":  entries = manifest?.js ?? []
            default:    entries = []
            }
            let hash = entries.first(where: { $0.fileName == fileName })?.hash ?? ""

            await DictionaryFileSyncService.shared.uploadSingleFile(
                dictId: dictId,
                fileName: fileName,
                fileURL: fileURL,
                fileHash: hash,
                fileSizeBytes: fileSize
            )
        }
    }

    /// Fire-and-forget: delete a removed resource file's CKRecord + re-upload manifest.
    private func syncAfterResourceRemove(dictId: String, fileName: String) {
        // Update metadata counts so remote devices detect the change
        syncMetadataResourceCounts(dictId: dictId)
        Task {
            await DictionaryFileSyncService.shared.deleteSingleFile(
                dictId: dictId,
                fileName: fileName
            )
        }
    }
}
