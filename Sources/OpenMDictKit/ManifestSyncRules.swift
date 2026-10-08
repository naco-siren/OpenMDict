//
//  ManifestSyncRules.swift
//  OpenMDictKit
//
//  Pure rules for reconciling a dictionary's local `manifest.json` with the
//  copy stored in CloudKit.
//
//  Background: individual resource files larger than `maxSyncableBytes` are
//  never uploaded (CloudKit quota protection). Before these rules existed the
//  app still counted such files in the synced metadata (`mddCount` etc.) and
//  uploaded manifests that listed them, so peers kept detecting a "remote
//  update" that could never be downloaded, and a manifest fetched from
//  CloudKit could delete the origin device's local-only file.
//
//  Everything here is Foundation-only and side-effect free so it can run
//  under `swift test` on macOS.
//

import Foundation

public enum ManifestSyncRules {

    /// Largest single file the app is willing to upload to CloudKit.
    /// Must match the cap used by the uploader.
    public static let maxSyncableBytes: Int64 = 500 * 1024 * 1024

    /// Whether a resource entry is eligible for upload / download.
    public static func isSyncable(
        _ entry: DictManifest.ResourceEntry,
        maxBytes: Int64 = maxSyncableBytes
    ) -> Bool {
        entry.sizeBytes <= maxBytes
    }

    // MARK: - Counts

    /// Per-kind resource counts.
    public struct ResourceCounts: Equatable, Sendable {
        public var mdd: Int
        public var css: Int
        public var js: Int
        public var fonts: Int

        public init(mdd: Int = 0, css: Int = 0, js: Int = 0, fonts: Int = 0) {
            self.mdd = mdd
            self.css = css
            self.js = js
            self.fonts = fonts
        }

        public static let zero = ResourceCounts()
    }

    /// Counts of the entries that exist (or can exist) in CloudKit.
    /// This is what `DictionaryMetadataRecord` should advertise to peers.
    public static func syncableCounts(
        of manifest: DictManifest,
        maxBytes: Int64 = maxSyncableBytes
    ) -> ResourceCounts {
        ResourceCounts(
            mdd: manifest.mdd.filter { isSyncable($0, maxBytes: maxBytes) }.count,
            css: manifest.css.filter { isSyncable($0, maxBytes: maxBytes) }.count,
            js: manifest.js.filter { isSyncable($0, maxBytes: maxBytes) }.count,
            fonts: manifest.fonts.filter { isSyncable($0, maxBytes: maxBytes) }.count
        )
    }

    /// `true` when the manifest lists at least one file that is never uploaded.
    public static func hasNonSyncableEntries(
        _ manifest: DictManifest,
        maxBytes: Int64 = maxSyncableBytes
    ) -> Bool {
        (manifest.mdd + manifest.css + manifest.js + manifest.fonts)
            .contains { !isSyncable($0, maxBytes: maxBytes) }
    }

    /// The manifest as it should be stored in CloudKit: only entries whose
    /// files are actually uploaded.
    public static func syncableSubset(
        of manifest: DictManifest,
        maxBytes: Int64 = maxSyncableBytes
    ) -> DictManifest {
        var copy = manifest
        copy.mdd = manifest.mdd.filter { isSyncable($0, maxBytes: maxBytes) }
        copy.css = manifest.css.filter { isSyncable($0, maxBytes: maxBytes) }
        copy.js = manifest.js.filter { isSyncable($0, maxBytes: maxBytes) }
        copy.fonts = manifest.fonts.filter { isSyncable($0, maxBytes: maxBytes) }
        return copy
    }

    // MARK: - Merge

    /// A set of resource entries, grouped by kind.
    public struct ResourceSet: Equatable, Sendable {
        public var mdd: [DictManifest.ResourceEntry] = []
        public var css: [DictManifest.ResourceEntry] = []
        public var js: [DictManifest.ResourceEntry] = []
        public var fonts: [DictManifest.ResourceEntry] = []

        public init(
            mdd: [DictManifest.ResourceEntry] = [],
            css: [DictManifest.ResourceEntry] = [],
            js: [DictManifest.ResourceEntry] = [],
            fonts: [DictManifest.ResourceEntry] = []
        ) {
            self.mdd = mdd
            self.css = css
            self.js = js
            self.fonts = fonts
        }

        public var count: Int { mdd.count + css.count + js.count + fonts.count }
        public var isEmpty: Bool { count == 0 }
    }

    /// Result of reconciling a local manifest against the CloudKit copy.
    public struct MergePlan: Equatable, Sendable {
        /// Remote entries that must be fetched (new, or hash changed).
        public var download: ResourceSet
        /// Local entries whose files must be removed (deleted on the origin).
        public var delete: ResourceSet
        /// The manifest to write locally once `download`/`delete` are applied:
        /// the remote syncable entries plus every local non-syncable entry.
        public var merged: DictManifest

        public var changeCount: Int { download.count + delete.count }
    }

    /// Reconcile `local` (may be nil when nothing is on disk yet) with `remote`.
    ///
    /// Invariants:
    /// - Remote entries above the size cap are ignored: they cannot exist as
    ///   CloudKit assets, so they are neither downloaded nor written locally.
    /// - Local entries above the size cap are never deleted and always survive
    ///   in `merged`, because CloudKit has no copy of them.
    public static func merge(
        local: DictManifest?,
        remote: DictManifest,
        maxBytes: Int64 = maxSyncableBytes
    ) -> MergePlan {
        func reconcile(
            _ localEntries: [DictManifest.ResourceEntry],
            _ remoteEntries: [DictManifest.ResourceEntry]
        ) -> (download: [DictManifest.ResourceEntry],
              delete: [DictManifest.ResourceEntry],
              merged: [DictManifest.ResourceEntry]) {
            let remoteSyncable = remoteEntries.filter { isSyncable($0, maxBytes: maxBytes) }
            let localSyncable = localEntries.filter { isSyncable($0, maxBytes: maxBytes) }
            let localKept = localEntries.filter { !isSyncable($0, maxBytes: maxBytes) }

            let localByName = Dictionary(localSyncable.map { ($0.fileName, $0) },
                                         uniquingKeysWith: { first, _ in first })
            let remoteNames = Set(remoteSyncable.map { $0.fileName })

            let download = remoteSyncable.filter { remoteEntry in
                guard let localEntry = localByName[remoteEntry.fileName] else { return true }
                return localEntry.hash != remoteEntry.hash
            }
            let delete = localSyncable.filter { !remoteNames.contains($0.fileName) }
            let merged = remoteSyncable + localKept.filter { !remoteNames.contains($0.fileName) }
            return (download, delete, merged)
        }

        let mdd = reconcile(local?.mdd ?? [], remote.mdd)
        let css = reconcile(local?.css ?? [], remote.css)
        let js = reconcile(local?.js ?? [], remote.js)
        let fonts = reconcile(local?.fonts ?? [], remote.fonts)

        var merged = remote
        merged.mdd = mdd.merged
        merged.css = css.merged
        merged.js = js.merged
        merged.fonts = fonts.merged

        return MergePlan(
            download: ResourceSet(mdd: mdd.download, css: css.download,
                                  js: js.download, fonts: fonts.download),
            delete: ResourceSet(mdd: mdd.delete, css: css.delete,
                                js: js.delete, fonts: fonts.delete),
            merged: merged
        )
    }
}
