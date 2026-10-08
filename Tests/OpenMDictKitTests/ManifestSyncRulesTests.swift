import Testing
import Foundation
@testable import OpenMDictKit

@Suite
struct ManifestSyncRulesTests {

    typealias Entry = DictManifest.ResourceEntry

    static let cap = ManifestSyncRules.maxSyncableBytes
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func entry(_ name: String, hash: String = "h", size: Int64 = 1024) -> Entry {
        Entry(fileName: name, hash: hash, sizeBytes: size, importedAt: date)
    }

    static func manifest(
        mdd: [Entry] = [], css: [Entry] = [], js: [Entry] = [], fonts: [Entry] = []
    ) -> DictManifest {
        DictManifest(
            id: "dict",
            mdx: DictManifest.MDXEntry(fileName: "dict.mdx", sizeBytes: 4096, importedAt: date),
            mdd: mdd, css: css, js: js, fonts: fonts
        )
    }

    /// The large-MDD case from the 2026-10-08 incident: an 834 MB MDD
    /// that exists only on the origin device.
    static let bigMDD = entry("large.mdd", hash: "big", size: 834_391_632)

    @Test("Oversized entries are not syncable; counts exclude them")
    func syncableCounts() {
        let local = Self.manifest(mdd: [Self.bigMDD, Self.entry("small.mdd", size: 10 * 1024 * 1024)],
                                  css: [Self.entry("a.css")], fonts: [Self.entry("f.ttf")])
        #expect(!ManifestSyncRules.isSyncable(Self.bigMDD))
        #expect(ManifestSyncRules.syncableCounts(of: local)
                == ManifestSyncRules.ResourceCounts(mdd: 1, css: 1, js: 0, fonts: 1))
        #expect(ManifestSyncRules.hasNonSyncableEntries(local))
        #expect(!ManifestSyncRules.hasNonSyncableEntries(Self.manifest(css: [Self.entry("a.css")])))
    }

    @Test("Exactly the cap is still syncable")
    func capIsInclusive() {
        #expect(ManifestSyncRules.isSyncable(Self.entry("x.mdd", size: Self.cap)))
        #expect(!ManifestSyncRules.isSyncable(Self.entry("x.mdd", size: Self.cap + 1)))
    }

    @Test("Upload subset drops oversized entries and keeps everything else")
    func syncableSubset() {
        let local = Self.manifest(mdd: [Self.bigMDD, Self.entry("small.mdd")],
                                  js: [Self.entry("a.js")])
        let subset = ManifestSyncRules.syncableSubset(of: local)
        #expect(subset.mdd == [Self.entry("small.mdd")])
        #expect(subset.js == [Self.entry("a.js")])
        #expect(subset.mdx == local.mdx)
        #expect(subset.id == local.id)
    }

    @Test("Large MDD: remote manifest without the MDD never deletes the local MDD")
    func mergeKeepsLocalOversized() {
        let local = Self.manifest(mdd: [Self.bigMDD], css: [Self.entry("c.css")], fonts: Array(repeating: Self.entry("f.ttf"), count: 1))
        let remote = Self.manifest(css: [Self.entry("c.css")], fonts: [Self.entry("f.ttf")])
        let plan = ManifestSyncRules.merge(local: local, remote: remote)
        #expect(plan.download.isEmpty)
        #expect(plan.delete.isEmpty)
        #expect(plan.changeCount == 0)
        #expect(plan.merged.mdd == [Self.bigMDD])
        #expect(ManifestSyncRules.syncableCounts(of: plan.merged) == ManifestSyncRules.syncableCounts(of: remote))
    }

    @Test("A remote oversized entry (old build uploaded it) is never downloaded or written")
    func mergeIgnoresRemoteOversized() {
        let remote = Self.manifest(mdd: [Self.bigMDD, Self.entry("small.mdd")])
        let plan = ManifestSyncRules.merge(local: nil, remote: remote)
        #expect(plan.download.mdd == [Self.entry("small.mdd")])
        #expect(plan.merged.mdd == [Self.entry("small.mdd")])
    }

    @Test("Hash change downloads; missing remote syncable file deletes")
    func mergeDetectsChanges() {
        let local = Self.manifest(css: [Self.entry("c.css", hash: "old")],
                                  fonts: [Self.entry("gone.ttf"), Self.entry("keep.ttf")])
        let remote = Self.manifest(css: [Self.entry("c.css", hash: "new")],
                                   fonts: [Self.entry("keep.ttf"), Self.entry("added.ttf")])
        let plan = ManifestSyncRules.merge(local: local, remote: remote)
        #expect(plan.download.css == [Self.entry("c.css", hash: "new")])
        #expect(plan.download.fonts == [Self.entry("added.ttf")])
        #expect(plan.delete.fonts == [Self.entry("gone.ttf")])
        #expect(plan.delete.css.isEmpty)
        #expect(plan.changeCount == 3)
        #expect(plan.merged.css == [Self.entry("c.css", hash: "new")])
        #expect(plan.merged.fonts == [Self.entry("keep.ttf"), Self.entry("added.ttf")])
    }

    @Test("Legitimate small MDD added on another device is downloaded")
    func mergeDownloadsNewSmallMDD() {
        let local = Self.manifest()
        let remote = Self.manifest(mdd: [Self.entry("new.mdd", size: 1024 * 1024)])
        let plan = ManifestSyncRules.merge(local: local, remote: remote)
        #expect(plan.download.mdd.count == 1)
        #expect(plan.merged.mdd.count == 1)
    }

    @Test("Merged manifest keeps the remote mdx entry and id")
    func mergedUsesRemoteBase() {
        let remote = Self.manifest(css: [Self.entry("c.css")])
        let plan = ManifestSyncRules.merge(local: nil, remote: remote)
        #expect(plan.merged.mdx == remote.mdx)
        #expect(plan.merged.id == remote.id)
    }
}
