import Testing
@testable import OpenMDictKit

@Suite
struct PresetVersioningTests {

    static let v0 = String(repeating: "a", count: 64)
    static let v1 = String(repeating: "b", count: 64)
    static let v2 = String(repeating: "c", count: 64)
    static let userImport = String(repeating: "d", count: 64)

    typealias Copy = InstalledPresetCopy

    @Test("Not installed when no dictionary has the preset's file name")
    func notInstalled() {
        #expect(PresetVersioning.state(installed: [], latestSha256: Self.v1) == .notInstalled)
        #expect(PresetVersioning.state(installed: [Copy(dictId: "", fileSha256: nil)], latestSha256: Self.v1) == .notInstalled)
    }

    @Test("Current when the file on this device is the shipped build (case-insensitive)")
    func current() {
        // Installed from this build, never updated.
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v1, fileSha256: nil)], latestSha256: Self.v1)
                == .current(dictId: Self.v1))
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v1, fileSha256: nil)], latestSha256: Self.v1.uppercased())
                == .current(dictId: Self.v1))
        // Installed from v0, updated in place to v1: the ID stays v0.
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v0, fileSha256: Self.v1)], latestSha256: Self.v1,
                                       previousSha256: [Self.v0]) == .current(dictId: Self.v0))
    }

    @Test("Catalogs without a hash never offer an update")
    func noHashNoUpdate() {
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v0, fileSha256: nil)], latestSha256: nil)
                == .current(dictId: Self.v0))
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v0, fileSha256: nil)], latestSha256: "")
                == .current(dictId: Self.v0))
    }

    @Test("Update available when the file on this device is an earlier build")
    func updateAvailable() {
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v0, fileSha256: Self.v0)], latestSha256: Self.v2,
                                       previousSha256: [Self.v0, Self.v1]) == .updateAvailable(dictIds: [Self.v0]))
        // Installed from v0, updated to v1 by an older app; this app ships v2.
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v0, fileSha256: Self.v1)], latestSha256: Self.v2,
                                       previousSha256: [Self.v0, Self.v1]) == .updateAvailable(dictIds: [Self.v0]))
        // Two copies of the preset (installed independently on two devices): both are updated.
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v0, fileSha256: Self.v0), Copy(dictId: Self.v1, fileSha256: Self.v1)],
                                       latestSha256: Self.v2, previousSha256: [Self.v0, Self.v1])
                == .updateAvailable(dictIds: [Self.v0, Self.v1]))
    }

    @Test("Nothing is offered until the file has been hashed")
    func unhashedIsNotOffered() {
        // The ID alone is not proof of the content: a copy downloaded from
        // iCloud can hold a later build under an earlier build's ID.
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v0, fileSha256: nil)], latestSha256: Self.v2,
                                       previousSha256: [Self.v0, Self.v1]) == .current(dictId: Self.v0))
    }

    @Test("A newer build on this device (from a newer app or another device) is not downgraded")
    func newerIsCurrent() {
        // ID v0 is known, but the file is a build this catalog does not list.
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.v0, fileSha256: Self.v2)], latestSha256: Self.v1,
                                       previousSha256: [Self.v0]) == .current(dictId: Self.v0))
    }

    @Test("A dictionary that is not this preset is left alone")
    func unrecognized() {
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.userImport, fileSha256: nil)], latestSha256: Self.v1,
                                       previousSha256: [Self.v0]) == .unrecognized(dictId: Self.userImport))
        // ...even if its file happens to be an earlier build of the preset.
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.userImport, fileSha256: Self.v0)], latestSha256: Self.v1,
                                       previousSha256: [Self.v0]) == .unrecognized(dictId: Self.userImport))
        // Next to a real copy of the preset, only the preset counts.
        #expect(PresetVersioning.state(installed: [Copy(dictId: Self.userImport, fileSha256: nil), Copy(dictId: Self.v0, fileSha256: Self.v0)],
                                       latestSha256: Self.v1, previousSha256: [Self.v0]) == .updateAvailable(dictIds: [Self.v0]))
    }

    @Test("Known builds are the current and the earlier ones")
    func knownBuilds() {
        #expect(PresetVersioning.isKnownBuild(Self.v1, latestSha256: Self.v1, previousSha256: []))
        #expect(PresetVersioning.isKnownBuild(Self.v0.uppercased(), latestSha256: Self.v1, previousSha256: [Self.v0]))
        #expect(!PresetVersioning.isKnownBuild(Self.userImport, latestSha256: Self.v1, previousSha256: [Self.v0]))
        #expect(!PresetVersioning.isKnownBuild(Self.userImport, latestSha256: nil, previousSha256: []))
    }

    @Test("An updated preset takes the new catalog name only when it has an earlier one")
    func adoptedDisplayName() {
        let previous = ["口語訳聖書"]
        #expect(PresetVersioning.adoptedDisplayName(current: "口語訳聖書", catalogName: "文語訳聖書",
                                                    previousNames: previous) == "文語訳聖書")
        // Renamed by the user, or already the new name: kept.
        #expect(PresetVersioning.adoptedDisplayName(current: "My Bible", catalogName: "文語訳聖書",
                                                    previousNames: previous) == nil)
        #expect(PresetVersioning.adoptedDisplayName(current: "文語訳聖書", catalogName: "文語訳聖書",
                                                    previousNames: previous) == nil)
        // No earlier names, no catalog name, no current name: nothing to do.
        #expect(PresetVersioning.adoptedDisplayName(current: "口語訳聖書", catalogName: "文語訳聖書",
                                                    previousNames: []) == nil)
        #expect(PresetVersioning.adoptedDisplayName(current: "口語訳聖書", catalogName: nil,
                                                    previousNames: previous) == nil)
        #expect(PresetVersioning.adoptedDisplayName(current: nil, catalogName: "文語訳聖書",
                                                    previousNames: previous) == nil)
    }
}

@Suite
struct GroupOrderTests {

    @Test("Without preserved IDs the incoming order is written as is")
    func plain() {
        #expect(GroupOrder.merge(incoming: ["a", "b"], existing: ["b", "x", "a"], preserved: []) == ["a", "b"])
    }

    @Test("An entry for a dictionary that is not loaded here survives in place")
    func keepsUnloadedEntry() {
        // Another device replaced "o" with "n" in this group; "n" has not
        // been downloaded here yet.
        #expect(GroupOrder.merge(incoming: ["a", "b"], existing: ["a", "n", "b"], preserved: ["n"]) == ["a", "n", "b"])
        #expect(GroupOrder.merge(incoming: ["a", "b"], existing: ["n", "a", "b"], preserved: ["n"]) == ["n", "a", "b"])
        #expect(GroupOrder.merge(incoming: ["a", "b"], existing: ["a", "b", "n"], preserved: ["n"]) == ["a", "b", "n"])
    }

    @Test("The user's reordering of loaded dictionaries is kept")
    func reorderAroundPreserved() {
        #expect(GroupOrder.merge(incoming: ["b", "a"], existing: ["a", "n", "b"], preserved: ["n"]) == ["b", "a", "n"])
    }

    @Test("Neighbours that were removed are skipped when placing a preserved entry")
    func removedNeighbour() {
        #expect(GroupOrder.merge(incoming: ["a"], existing: ["a", "r", "n"], preserved: ["n"]) == ["a", "n"])
        #expect(GroupOrder.merge(incoming: ["a"], existing: ["r", "n", "a"], preserved: ["n"]) == ["n", "a"])
    }

    @Test("Preserved IDs without an existing entry are not added; duplicates are not created")
    func noInsertion() {
        #expect(GroupOrder.merge(incoming: ["a"], existing: ["a"], preserved: ["n"]) == ["a"])
        #expect(GroupOrder.merge(incoming: ["n", "a"], existing: ["a", "n"], preserved: ["n"]) == ["n", "a"])
    }

    @Test("Several preserved entries keep their relative order")
    func severalPreserved() {
        #expect(GroupOrder.merge(incoming: ["a", "b"], existing: ["m", "a", "n", "b", "p"], preserved: ["m", "n", "p"])
                == ["m", "a", "n", "b", "p"])
    }
}

@Suite
struct CloudSyncStatusMergeTests {

    typealias M = CloudSyncStatusMerge

    @Test("Synced always wins")
    func syncedWins() {
        for s in [M.pending, M.synced, M.tooLarge, M.error] {
            #expect(M.best(M.synced, s) == M.synced)
            #expect(M.best(s, M.synced) == M.synced)
        }
    }

    @Test("Otherwise too large > pending > error")
    func order() {
        #expect(M.best(M.pending, M.error) == M.pending)
        #expect(M.best(M.error, M.pending) == M.pending)
        #expect(M.best(M.tooLarge, M.pending) == M.tooLarge)
        #expect(M.best(M.error, M.error) == M.error)
    }
}
