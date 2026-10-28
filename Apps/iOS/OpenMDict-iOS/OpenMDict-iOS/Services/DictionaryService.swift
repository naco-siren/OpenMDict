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

    /// Cancellable for CloudKit "import completed" events: re-evaluates
    /// pending remote deletes once a mirroring reset has re-imported the zone.
    private var importCompletedCancellable: AnyCancellable?

    // MARK: Remote-change bookkeeping (see handleRemoteChange)

    /// Single-flight guard + "run again when done" flag for handleRemoteChange.
    private var isHandlingRemoteChange = false
    private var remoteChangeRerunPending = false

    /// Last known cloudSyncStatus per dictionary, remembered from every
    /// metadata pass so it is still available after a metadata row vanished.
    private var lastKnownSyncStatus: [String: CloudSyncStatus] = [:]

    /// Loaded dictionaries whose metadata row is missing, with the time the
    /// absence was first seen. They stay loaded and on disk until CloudKit
    /// confirms the deletion (see RemoteDeletePolicy).
    private var pendingRemoteDeletes: [String: Date] = [:]

    /// Per dictionary: the import end time that was current when it was last
    /// verified against CloudKit, so each is re-verified at most once per
    /// completed import.
    private var remoteDeleteVerifiedAfter: [String: Date] = [:]

    /// Dictionaries already logged as "kept — never uploaded".
    private var loggedUnrecoverable: Set<String> = []

    /// Bounded memo for step 3 (remote resource updates): attempts per
    /// (dictId, advertised counts). Metadata written by older builds can
    /// advertise files that were never uploaded; this caps the cost until
    /// the origin device re-saves its counts under the current rule.
    private var resourceReconcileAttempts: [String: Int] = [:]

    /// `true` when setupGroups found no group rows and created the default
    /// group in memory (first launch): the next persistGroups() may then
    /// insert into the empty table. Otherwise an empty group table means a
    /// CloudKit mirroring reset is in flight and inserts are refused.
    private var groupsNeedBootstrap = false

    /// Failed downloads per dictionary in this process, and when the next
    /// attempt may start. A failure does not mark the shared metadata row,
    /// so remote-change passes retry — with backoff (30 s doubling up to
    /// 30 min) rather than on every pass or never again after a few
    /// transient failures.
    private var downloadFailures: [String: (count: Int, retryAfter: Date)] = [:]

    /// Presets whose MDX is being replaced right now (see updatePresetFile).
    private var presetFileUpdatesInFlight = Set<String>()

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
        importCompletedCancellable?.cancel()
        importCompletedCancellable = nil
        isHandlingRemoteChange = false
        remoteChangeRerunPending = false
        lastKnownSyncStatus.removeAll()
        pendingRemoteDeletes.removeAll()
        remoteDeleteVerifiedAfter.removeAll()
        loggedUnrecoverable.removeAll()
        resourceReconcileAttempts.removeAll()
        downloadFailures.removeAll()
        groupsNeedBootstrap = false

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
        // 0. A preset update killed between its two file renames leaves the
        //    MDX under a temporary name; put it back before anything opens it.
        storage.recoverInterruptedMDXReplacements()

        // 1. Load dictionaries from CoreData metadata + per-dict manifests
        loadUserDictionaries()
        rememberSyncStatuses(DictMetadataService.shared.loadAll())

        // 2. Setup groups from CoreData (or create defaults)
        setupGroups()

        // Preset updates: compare installed presets with the builds this app ships.
        PresetDictionaryService.shared.startTrackingUpdates()

        // 3. Background loading
        Task {
            await loadAllMetadata()
            // Re-index Spotlight now that metadata (entry count, file size, author) is available
            await loadAllDictionaries()
            SpotlightIndexingService.shared.indexAllDictionaries()

            // Which build each installed preset's MDX is (hashed once per file).
            await PresetDictionaryService.shared.recordInstalledBuilds()

            // 4. Catch-up upload: any locally-present dictionaries that were never
            // uploaded to CloudKit (e.g. presets imported before file-sync was added),
            // and CloudKit deletions that could not be sent at the time.
            if SyncModeService.shared.isCloudSyncEnabled {
                await uploadPendingDictionaries()
                await DictionaryFileSyncService.shared.retryPendingCloudDeletions()
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
            // A completed import is what lets a pending remote delete be
            // verified (or cancelled, after a mirroring reset re-imports).
            importCompletedCancellable = CoreDataStack.shared.cloudKitImportCompletedPublisher
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.handleRemoteChange()
                }
            // Housekeeping: drop download staging left by a kill mid-download,
            // and correct metadata counts written by older builds for
            // dictionaries that hold files above the upload cap.
            storage.sweepDownloadStaging()
            resyncResourceCountsForNonSyncableEntries()
        }
    }

    /// Whether the app has dictionaries, for first-install detection.
    ///
    /// Besides metadata rows this counts dictionaries loaded in memory and,
    /// in iCloud mode, dictionary folders on disk: during a CloudKit
    /// mirroring reset the metadata table is empty for a while even though
    /// every dictionary is still present, and the onboarding picker must
    /// not appear over a library that is about to come back.
    var hasAnyDictionariesForSetup: Bool {
        if DictMetadataService.shared.hasAnyDictionaries { return true }
        if !allDictionaries.isEmpty { return true }
        if SyncModeService.shared.isCloudSyncEnabled && storage.hasAnyDictionaryOnDisk { return true }
        return false
    }

    private func rememberSyncStatuses(_ metadata: [DictMetadata]) {
        for m in metadata {
            lastKnownSyncStatus[m.dictId] = CloudSyncStatus(rawValue: m.cloudSyncStatus) ?? .pending
        }
    }

    /// One-time reconciliation for dictionaries whose manifest lists files
    /// above the upload cap. Older builds counted those files in the synced
    /// metadata, which made every other device chase an update that could
    /// never be downloaded. Only the device holding such a file (the origin)
    /// re-saves its counts; peers converge on the next remote change.
    private func resyncResourceCountsForNonSyncableEntries() {
        for dict in allDictionaries where storage.resyncResourceCountsIfNeeded(id: dict.id) {
            debugLog("☁️ Resynced resource counts for \(dict.id.prefix(16)) (manifest has non-syncable entries)")
        }
    }

    /// Upload dictionaries whose `cloudSyncStatus` is still `.pending`, or
    /// `.error` (a failed upload), or `.tooLarge` although the MDX is within
    /// the cap (older builds marked a whole dictionary too large for one big
    /// resource file; resources above the cap now simply stay local).
    /// This covers presets that were imported before file-sync was added,
    /// or any dict whose upload was interrupted.  Runs once at launch.
    private func uploadPendingDictionaries() async {
        let allMetadata = DictMetadataService.shared.loadAll()
        let pending = allMetadata.filter {
            switch CloudSyncStatus(rawValue: $0.cloudSyncStatus) {
            case .pending, .error:
                return true
            case .tooLarge:
                guard let manifest = storage.loadDictManifest(id: $0.dictId) else { return false }
                return manifest.mdx.sizeBytes <= ManifestSyncRules.maxSyncableBytes
            default:
                return false
            }
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
    /// Four concerns, in order:
    ///   1. **Remote deletes** — metadata disappeared. Never trusted on its
    ///      own: `NSPersistentCloudKitContainer` purges EVERY mirrored row
    ///      when it resets (expired history token, expired change token,
    ///      zone gone) and only then re-imports the zone. The dictionary
    ///      stays loaded and on disk until CloudKit itself confirms that
    ///      its manifest record is gone (see `RemoteDeletePolicy`).
    ///   2. **Remote adds** — new metadata with no local files → download
    ///      from CloudKit + load into memory.
    ///   3. **Remote updates** — resource counts changed on another device
    ///      → reconcile against the remote manifest.
    ///   4. **Groups** — reload group membership from CoreData.
    ///
    /// Single-flight: notifications that arrive while a pass is running
    /// (including the ones this pass's own saves post) coalesce into one
    /// follow-up pass instead of spawning concurrent passes.
    private func handleRemoteChange() {
        guard !isHandlingRemoteChange else {
            remoteChangeRerunPending = true
            return
        }
        isHandlingRemoteChange = true
        Task {
            await processRemoteChange()
            isHandlingRemoteChange = false
            if remoteChangeRerunPending {
                remoteChangeRerunPending = false
                debugLog("☁️ DictionaryService: re-running remote change pass (notifications arrived mid-pass)")
                handleRemoteChange()
            }
        }
    }

    private func processRemoteChange() async {
        let allMetadata = DictMetadataService.shared.loadAll()
        rememberSyncStatuses(allMetadata)
        let metadataIds = Set(allMetadata.map { $0.dictId })

        // --- 1. Remote deletes (evidence-based) ---
        await handleMissingMetadata(
            loadedIds: Set(allDictionaries.map { $0.id }),
            metadataIds: metadataIds
        )
        let loadedIds = Set(allDictionaries.map { $0.id })

        // --- 2. Detect remote adds ---
        // Metadata records whose dictionary files aren't loaded yet.
        let missingIds = metadataIds.subtracting(loadedIds)
        for dictId in missingIds {
            let dictDir = storage.dictionaryDirectoryURL(id: dictId)
            var hasLocalFiles = FileManager.default.fileExists(atPath: dictDir.path)
            if hasLocalFiles && !storage.hasCompleteDictionary(id: dictId) {
                // A folder without a manifest or MDX (an import killed half
                // way) would count as "installed" forever and block the
                // download. Remove it once it is clearly abandoned.
                if storage.isAbandonedIncompleteFolder(id: dictId) {
                    debugLog("🧹 Removing an incomplete folder for \(dictId.prefix(16)) so it can be downloaded")
                    try? FileManager.default.removeItem(at: dictDir)
                    storage.invalidateDictManifestCache(id: dictId)
                    hasLocalFiles = false
                } else {
                    continue
                }
            }

            if hasLocalFiles {
                // Files exist but MDict not loaded (race on launch, or the
                // metadata row came back after a mirroring reset).
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
                guard !DictionaryFileSyncService.shared.isDownloading(dictId) else { continue }
                if let failure = downloadFailures[dictId], failure.retryAfter > Date() { continue }

                // Files not on device → download from CloudKit
                DictMetadataService.shared.markDownloading(dictId)
                let downloaded = await DictionaryFileSyncService.shared
                    .downloadDictionary(dictId: dictId)
                DictMetadataService.shared.clearDownloading(dictId)
                if downloaded {
                    downloadFailures.removeValue(forKey: dictId)
                    await refreshAfterImport(dictId)
                } else {
                    let count = (downloadFailures[dictId]?.count ?? 0) + 1
                    let delay = min(30 * pow(2, Double(count - 1)), 1800)
                    downloadFailures[dictId] = (count, Date().addingTimeInterval(delay))
                }
            }
        }

        // --- 3. Detect remote updates ---
        // Already-loaded dictionaries whose files changed on another device
        // (e.g. MDD added/removed). Compare the counts of resources that can
        // exist in CloudKit (files above the upload cap are local-only by
        // definition) against the synced metadata counts.
        let existingIds = loadedIds.intersection(metadataIds)
        for dictId in existingIds {
            guard let metadata = allMetadata.first(where: { $0.dictId == dictId }) else { continue }
            let syncStatus = CloudSyncStatus(rawValue: metadata.cloudSyncStatus) ?? .pending
            guard syncStatus == .synced else { continue }

            let localManifest = self.storage.loadDictManifest(id: dictId)
            let local = localManifest.map { ManifestSyncRules.syncableCounts(of: $0) } ?? .zero
            let advertised = ManifestSyncRules.ResourceCounts(
                mdd: Int(metadata.mddCount), css: Int(metadata.cssCount),
                js: Int(metadata.jsCount), fonts: Int(metadata.fontsCount)
            )
            guard local != advertised else { continue }

            // Bounded per (dict, advertised counts): metadata written by an
            // older build can advertise files no remote manifest will ever
            // satisfy. Three attempts per process cover a genuine update
            // whose manifest upload is still in flight.
            let memoKey = "\(dictId)|\(advertised.mdd),\(advertised.css),\(advertised.js),\(advertised.fonts)"
            let attempts = resourceReconcileAttempts[memoKey, default: 0]
            guard attempts < 3 else { continue }
            resourceReconcileAttempts[memoKey] = attempts + 1

            debugLog("☁️ Remote update detected for \(dictId.prefix(16)): "
                + "mdd \(local.mdd)→\(advertised.mdd), "
                + "css \(local.css)→\(advertised.css), "
                + "js \(local.js)→\(advertised.js), "
                + "fonts \(local.fonts)→\(advertised.fonts)")

            // Per-file incremental update: fetch remote manifest → merge → download only changed files
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

    /// Step 1 of `processRemoteChange`: loaded dictionaries without a
    /// metadata row. See `RemoteDeletePolicy` for the rules; only a
    /// dictionary whose manifest record is confirmed gone from CloudKit is
    /// deleted locally.
    private func handleMissingMetadata(loadedIds: Set<String>, metadataIds: Set<String>) async {
        let stack = CoreDataStack.shared
        let recoverable = Set(lastKnownSyncStatus.filter { $0.value == .synced }.map { $0.key })

        let evaluation = RemoteDeletePolicy.evaluate(
            loadedIds: loadedIds,
            metadataIds: metadataIds,
            previousPending: pendingRemoteDeletes,
            recoverableFromCloud: recoverable,
            lastSuccessfulImportEnd: stack.lastSuccessfulImportEnd,
            resetSuspected: stack.isMirroringResetSuspected,
            lastVerifiedAfter: remoteDeleteVerifiedAfter,
            now: Date()
        )

        for id in evaluation.reappeared {
            debugLog("☁️ Metadata for \(id.prefix(16)) is back — remote delete cancelled (mirroring reset)")
            remoteDeleteVerifiedAfter.removeValue(forKey: id)
            loggedUnrecoverable.remove(id)
        }
        for (id, firstSeen) in evaluation.pending where pendingRemoteDeletes[id] == nil {
            debugLog("☁️ Metadata missing for \(id.prefix(16)) — keeping files and instance until CloudKit confirms (first seen \(firstSeen))")
        }
        pendingRemoteDeletes = evaluation.pending

        if evaluation.heldForReset {
            debugLog("☁️ Remote delete HELD for \(evaluation.pending.count) dictionaries — mirroring reset in progress")
            return
        }

        for id in evaluation.unrecoverable where !loggedUnrecoverable.contains(id) {
            loggedUnrecoverable.insert(id)
            let status = lastKnownSyncStatus[id].map { "\($0)" } ?? "unknown"
            debugLog("☁️ Metadata missing for \(id.prefix(16)) but its files were never uploaded (status \(status)) — kept on this device")
        }

        guard !evaluation.candidates.isEmpty, let importEnd = stack.lastSuccessfulImportEnd else { return }

        for id in evaluation.candidates.sorted() {
            remoteDeleteVerifiedAfter[id] = importEnd
            let exists = await DictionaryFileSyncService.shared.remoteManifestExists(dictId: id)
            switch exists {
            case .some(false):
                debugLog("☁️ Remote delete CONFIRMED for \(id.prefix(16)) — manifest no longer in CloudKit")
                pendingRemoteDeletes.removeValue(forKey: id)
                remoteDeleteVerifiedAfter.removeValue(forKey: id)
                applyRemoteDelete(id)
            case .some(true):
                debugLog("☁️ Remote delete REJECTED for \(id.prefix(16)) — manifest still in CloudKit (mirroring reset?)")
            case .none:
                // CloudKit unreachable — try again on the next pass.
                remoteDeleteVerifiedAfter.removeValue(forKey: id)
            }
        }
    }

    /// Remove a dictionary that another device deleted (confirmed).
    private func applyRemoteDelete(_ dictId: String) {
        // Drop the persistent sidecar indexes so the cache doesn't
        // accumulate orphans — before the files go, while the header can
        // still be read. `deleteDictionary(dictId:)` does the same for the
        // user-initiated delete path.
        removeSidecarCache(ofDictionary: dictId)
        // Remove local files
        let dictDir = storage.dictionaryDirectoryURL(id: dictId)
        try? FileManager.default.removeItem(at: dictDir)
        storage.invalidateDictManifestCache(id: dictId)
        // M15 Phase 3: same cleanup for the article-embedding sidecar.
        // Unconditional (runs even on iOS < 26) — see Coordinator.
        ArticleIndexCoordinator.shared.handleDictDeleted(dictId)
        // Unload from memory + remove from in-memory groups. The device that
        // deleted the dictionary already removed its GroupEntryRecords and
        // that change arrives through CloudKit (step 4 reloads the groups),
        // so nothing is written here — writing during a reset would
        // re-insert group rows with new record ids.
        refreshAfterDelete(dictId, persistGroups: false)
        // De-index from Spotlight
        SpotlightIndexingService.shared.deindexDictionary(id: dictId)
        lastKnownSyncStatus.removeValue(forKey: dictId)
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
            dict.headwordLanguage = PresetDictionaryService.headwordLanguageByFilename[metadata.originalFileName]

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
            groupsNeedBootstrap = false
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
            // First launch (no CoreData records) — create default group.
            // Exception: in iCloud mode an empty table with dictionaries
            // still on disk is the signature of a mirroring reset (the app
            // was killed before the re-import); the groups will come back
            // with the import and must not be re-created with new ids.
            let looksLikeMirroringReset = SyncModeService.shared.isCloudSyncEnabled
                && allDictionaries.isEmpty && storage.hasAnyDictionaryOnDisk
            groupsNeedBootstrap = !looksLikeMirroringReset
            if looksLikeMirroringReset {
                debugLog("☁️ No group rows but dictionaries on disk — assuming mirroring reset, not bootstrapping groups")
            }
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

        // Lookup fallbacks: saved diacritic indexes, German lemma model.
        LookupFallbackSetup.dictionariesDidLoad(allDictionaries.filter(\.isLoaded))
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
        let fontFiles = importSession.pendingFontFiles.map { SelectedFile(url: $0.url) }

        // 1. Copy files to storage
        let dictId = try await storage.importDictionary(
            mdxFile: mdxFile,
            mddFiles: mddFiles,
            cssFiles: cssFiles,
            jsFiles: jsFiles,
            fontFiles: fontFiles,
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

    // MARK: - Preset Updates

    struct PresetUpdateError: LocalizedError {
        enum Kind { case notReady, wrongBuild, copyFailed, doesNotOpen }
        let kind: Kind
        let underlying: Error?
        var errorDescription: String? {
            switch kind {
            case .notReady: return L10n.PresetUpdate.errorNotReady
            case .wrongBuild, .copyFailed, .doesNotOpen: return L10n.PresetUpdate.errorFailed
            }
        }
    }

    /// Whether the MDX of installed dictionary `dictId` can be replaced now:
    /// it is in the library, its file is on this device, and nothing else is
    /// writing to its folder (an iCloud download, another update). It need
    /// not have finished loading — the update waits for that.
    func canUpdatePresetFile(_ dictId: String) -> Bool {
        guard dict(id: dictId) != nil,
              !presetFileUpdatesInFlight.contains(dictId),
              !DictionaryFileSyncService.shared.isDownloading(dictId),
              !DictMetadataService.shared.downloadingDictIds.contains(dictId),
              let manifest = storage.loadDictManifest(id: dictId) else { return false }
        return FileManager.default.fileExists(atPath: storage.mdxURL(id: dictId, fileName: manifest.mdx.fileName).path)
    }

    /// Replace the MDX of an installed preset with the build this app ships,
    /// in place. The dictionary keeps its ID, folder and file name, so its
    /// bookmarks, history, groups, settings, the user's own resources and its
    /// iCloud records all stay as they are. Only this device's copy changes:
    /// the iCloud records are not touched, and other devices update their own
    /// copy when their app ships the build.
    ///
    /// The new file is copied next to the old one and checked against
    /// `expectedSha256` before anything changes. Then two renames swap it in
    /// (the old file is kept until the new one has opened; readers that have
    /// the old file open keep using it). If the new file does not open, the
    /// old one is put back. A kill between the renames is repaired at the
    /// next launch (`recoverInterruptedMDXReplacements`).
    func updatePresetFile(dictId: String, from sourceURL: URL, expectedSha256: String) async throws {
        guard canUpdatePresetFile(dictId), let dict = dict(id: dictId),
              let manifest = storage.loadDictManifest(id: dictId) else {
            throw PresetUpdateError(kind: .notReady, underlying: nil)
        }
        presetFileUpdatesInFlight.insert(dictId)
        defer { presetFileUpdatesInFlight.remove(dictId) }

        let fileName = manifest.mdx.fileName
        let mdxURL = storage.mdxURL(id: dictId, fileName: fileName)
        let expected = expectedSha256.lowercased()
        debugLog("🔄 Updating preset file \(fileName) (\(dictId.prefix(16))) to \(expected.prefix(16))")

        // Let a launch-time load finish first; reloading over it would race.
        if dict.state != .loaded {
            await dict.loadMetadata()
            try? await dict.load()
            if dict.state != .loaded {
                for await state in dict.$state.values where state == .loaded || state.isError { break }
            }
        }
        let oldHeaderSHA = dict.metadata?.headerSHA256

        // 1. Copy and verify (off the main actor)
        let staged: URL
        do {
            staged = try await DictionaryStorageService.stageReplacement(for: mdxURL, from: sourceURL)
        } catch {
            throw PresetUpdateError(kind: .copyFailed, underlying: error)
        }
        let actual: String
        do {
            actual = try await Task.detached(priority: .userInitiated) {
                try PresetDictionaryService.fileSHA256(staged)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw PresetUpdateError(kind: .copyFailed, underlying: error)
        }
        guard actual == expected else {
            try? FileManager.default.removeItem(at: staged)
            debugLog("⚠️ Shipped file is \(actual.prefix(16)), the catalog names \(expected.prefix(16)) — not installed")
            throw PresetUpdateError(kind: .wrongBuild, underlying: nil)
        }
        // Deleted (here or by another device) while the file was copied.
        guard self.dict(id: dictId) === dict else {
            try? FileManager.default.removeItem(at: staged)
            throw PresetUpdateError(kind: .notReady, underlying: nil)
        }

        // 2. Reset the article index BEFORE the swap: a rebuilt preset keeps
        //    its header hash, so an index of the old content would still
        //    validate if the app were killed after the swap.
        ArticleIndexCoordinator.shared.prepareForContentReplacement(dictId)

        // 3. Swap the files
        do {
            try await DictionaryStorageService.swapInReplacement(staged, for: mdxURL)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            ArticleIndexCoordinator.shared.handleDictImported(dictId)
            throw PresetUpdateError(kind: .copyFailed, underlying: error)
        }
        storage.recordMDXSha256(expected, id: dictId)
        // Local size of the MDX; re-read so resource changes made meanwhile
        // (e.g. an iCloud resource sync) are kept. Not synced: the size is
        // this device's.
        if let size = DictionaryStorageService.fileStamp(mdxURL)?.size {
            try? storage.updateDictManifest(id: dictId, syncCountsToMetadata: false) {
                $0.mdx = DictManifest.MDXEntry(fileName: fileName, sizeBytes: size)
            }
        }

        // 4. Open the new file; put the old one back if it does not open
        do {
            try await dict.reloadFromDisk()
        } catch {
            debugLog("❌ Updated \(fileName) does not open (\(error)); restoring the previous file")
            await DictionaryStorageService.restoreReplaced(mdxURL)
            if let size = DictionaryStorageService.fileStamp(mdxURL)?.size {
                try? storage.updateDictManifest(id: dictId, syncCountsToMetadata: false) {
                    $0.mdx = DictManifest.MDXEntry(fileName: fileName, sizeBytes: size)
                }
            }
            try? await dict.reloadFromDisk()
            ArticleIndexCoordinator.shared.handleDictImported(dictId)
            throw PresetUpdateError(kind: .doesNotOpen, underlying: error)
        }
        await DictionaryStorageService.discardReplaced(mdxURL)

        // 5. Bookkeeping for the new content — unless the dictionary was
        //    deleted meanwhile.
        guard self.dict(id: dictId) === dict else { return }
        if let oldHeaderSHA, oldHeaderSHA != dict.metadata?.headerSHA256 {
            MDictReader.removeSidecarCache(forHeaderSHA256: oldHeaderSHA)
        }
        LookupFallbackSetup.dictionariesDidLoad([dict])
        ArticleIndexCoordinator.shared.handleDictImported(dictId)
        SpotlightIndexingService.shared.indexDictionary(dict)
        displayNameRevision += 1
        debugLog("✅ Preset file updated: \(fileName) (\(dictId.prefix(16)))")
    }

    /// Delete a dictionary
    /// - Parameter dictId: Dictionary ID to delete
    func deleteDictionary(dictId: String) throws {
        // 1. Drop the sidecar indexes (while the MDX header can still be
        //    read), then remove from storage
        removeSidecarCache(ofDictionary: dictId)
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
            newDict.headwordLanguage = PresetDictionaryService.headwordLanguageByFilename[metadata.originalFileName]
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
            LookupFallbackSetup.dictionariesDidLoad([newDict])
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

        // 7. M15 Phase 3: notify the article-embedding coordinator so it
        //    can schedule semantic indexing. On iOS < 26 this is a
        //    silent no-op (the coordinator's availability gate handles
        //    it); on iOS 26+ Phase 3.4 will enqueue this dict for
        //    background indexing.
        ArticleIndexCoordinator.shared.handleDictImported(id)
    }
    
    /// Called after deleting a dictionary
    /// - Parameter id: The deleted dictionary's ID
    /// - Parameter persistGroups: Write the updated group membership to
    ///   CoreData. `false` on the CloudKit remote-delete path, where the
    ///   originating device already removed the entries.
    /// Remove the sidecar index and the folded-key index saved beside it of
    /// a dictionary about to be deleted. Both files are named by the MDX
    /// header's SHA-256, which is an imported dictionary's id but not a
    /// preset's (the hash of its whole file), so the hash comes from the
    /// loaded reader or, failing that, from the file's header. Call before
    /// the files are removed.
    private func removeSidecarCache(ofDictionary dictId: String) {
        let headerSHA = dict(id: dictId)?.metadata?.headerSHA256
            ?? storage.mdxURL(id: dictId).flatMap { MDictReader.loadMetadata(from: $0.path)?.headerSHA256 }
        if let headerSHA, headerSHA != dictId {
            MDictReader.removeSidecarCache(forHeaderSHA256: headerSHA)
        }
        MDictReader.removeSidecarCache(forHeaderSHA256: dictId)
    }

    private func refreshAfterDelete(_ id: String, persistGroups: Bool = true) {
        // 1. Remove from allDictionaries
        allDictionaries.removeAll { $0.id == id }
        
        // 2. Remove from all groups
        for group in groups {
            group.dictionaryIds.removeAll { $0 == id }
            group.populate(from: allDictionaries)
        }
        
        // 3. Persist updated groups
        if persistGroups {
            self.persistGroups()
        }
        
        print("🗑️ Removed dictionary from service: \(id)")
    }
    
    /// Persist current group configuration to CoreData.
    ///
    /// Group entries of dictionaries this device knows about (metadata row)
    /// but has not loaded — typically one another device just imported whose
    /// files are still on their way — are kept as they are: the in-memory
    /// groups cannot contain them, and dropping them here would remove them
    /// from the groups on every device.
    func persistGroups() {
        let loaded = Set(allDictionaries.map(\.id))
        let preserved = Set(DictMetadataService.shared.loadAll().map(\.dictId)).subtracting(loaded)
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
        if groupPersistence.saveAllGroups(savedGroups, preserving: preserved,
                                          allowBootstrapInsert: groupsNeedBootstrap) {
            groupsNeedBootstrap = false
        }
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
    
    /// Lookup in a group (returns AsyncStream for progressive results).
    /// An article a fallback found is titled "word → key".
    func lookup(_ word: String, in group: MDicts) -> AsyncStream<ArticleDisplayItem> {
        AsyncStream { continuation in
            Task {
                for await result in group.lookup(word) {
                    continuation.yield(ArticleDisplayItem(from: result, query: word))
                }
                continuation.finish()
            }
        }
    }

    /// Lookup in a single dictionary. `fallbacks` as in `MDict.lookup`; an
    /// article a fallback found is titled "word → key".
    func lookup(_ word: String, in dict: MDict,
                fallbacks: MDictLookupFallbacks = .all) -> ArticleDisplayItem? {
        guard let entry = dict.lookup(word, fallbacks: fallbacks) else { return nil }
        return ArticleDisplayItem(from: entry, dict: dict, query: word)
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
        syncAfterResourceAdd(dictId: dictId, fileName: fileName, subdirectory: AppIdentifiers.ResourceDirectory.mdd)
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
        syncAfterResourceAdd(dictId: dictId, fileName: fileName, subdirectory: AppIdentifiers.ResourceDirectory.css)
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
        syncAfterResourceAdd(dictId: dictId, fileName: fileName, subdirectory: AppIdentifiers.ResourceDirectory.js)
        return fileName
    }

    /// Add a font file to a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileURL: Source file URL (from UIDocumentPicker)
    /// - Returns: fileName of the added file
    func addFont(to dictId: String, from fileURL: URL) async throws -> String {
        let fileName = try await storage.addFontResource(dictId: dictId, sourceURL: fileURL)
        // Incremental CloudKit sync (fire-and-forget)
        syncAfterResourceAdd(dictId: dictId, fileName: fileName, subdirectory: AppIdentifiers.ResourceDirectory.fonts)
        return fileName
    }

    /// Remove a font file from a dictionary
    /// - Parameters:
    ///   - dictId: Dictionary ID
    ///   - fileName: File name to remove
    func removeFont(from dictId: String, fileName: String) throws {
        try storage.removeFontResource(dictId: dictId, fileName: fileName)
        // Incremental CloudKit sync (fire-and-forget)
        syncAfterResourceRemove(dictId: dictId, fileName: fileName)
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

    // Metadata resource counts are written by DictionaryStorageService when
    // it saves the manifest (syncable entries only — see ManifestSyncRules),
    // which is how remote devices detect resource changes.

    /// Fire-and-forget: upload a newly added resource file + updated manifest.
    private func syncAfterResourceAdd(dictId: String, fileName: String, subdirectory: String) {
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
            case AppIdentifiers.ResourceDirectory.mdd:   entries = manifest?.mdd ?? []
            case AppIdentifiers.ResourceDirectory.css:   entries = manifest?.css ?? []
            case AppIdentifiers.ResourceDirectory.js:    entries = manifest?.js ?? []
            case AppIdentifiers.ResourceDirectory.fonts: entries = manifest?.fonts ?? []
            default:                                     entries = []
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
        Task {
            await DictionaryFileSyncService.shared.deleteSingleFile(
                dictId: dictId,
                fileName: fileName
            )
        }
    }
}
