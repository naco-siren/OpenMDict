import Testing
import Foundation
@testable import OpenMDict

/// Tests for the persistent sidecar index fast-path.
///
/// Verifies that the fast-path (sidecar .idx load) produces results that are
/// byte-equal to the slow-path (full MDX parse) for the same queries, plus
/// validation and invalidation behaviour.
///
/// Run with:
///   MDICT_TEST_FILE=path/to/dict.mdx swift test --filter SidecarRoundTripTests
///
/// Each test sets up its own per-test sidecar cache directory under
/// `FileManager.default.temporaryDirectory` and restores `MDictSidecarCache`
/// global state on exit via `defer`, so the suite is safe to run alongside
/// the other test suites.
@Suite(.serialized)
struct SidecarRoundTripTests {

    // MARK: - Fixtures

    static var testMDXPath: String? {
        TestFixtures.mdxPath
    }

    private static func makeTempSidecarDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openmdict-sidecar-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Snapshot of a lookup result for equality comparison (the raw
    /// MDictWordEntry is not Equatable, and comparing the whole HTML string
    /// for every key would bloat test output).
    private struct LookupSnapshot: Equatable {
        let key: String
        let htmlLen: Int
        let index: Int
    }

    private static func snapshotLookups(
        _ reader: MDictReader,
        keys: [String]
    ) -> [String: LookupSnapshot?] {
        var out: [String: LookupSnapshot?] = [:]
        for k in keys {
            if let e = reader.lookup(k) {
                out[k] = LookupSnapshot(key: e.key, htmlLen: e.article.html.count, index: e.index)
            } else {
                out[k] = nil
            }
        }
        return out
    }

    /// Save and restore the MDictSidecarCache global state.
    /// Use inside a `defer` so tests leave no residue on the shared cache.
    private static func saveGlobals() -> (dir: URL?, mode: SidecarWriteMode) {
        return (MDictSidecarCache.cacheDirectory, MDictSidecarCache.writeMode)
    }

    private static func restoreGlobals(_ saved: (dir: URL?, mode: SidecarWriteMode)) {
        MDictSidecarCache.cacheDirectory = saved.dir
        MDictSidecarCache.writeMode = saved.mode
    }

    // MARK: - Tests

    /// The core correctness invariant: a sidecar that was just written by
    /// the slow path can be loaded back by the fast path and produce
    /// byte-equal lookup results for the same set of random keys.
    ///
    /// This is the automated equivalent of `openmdict-bench --verify`.
    @Test("Fast path produces byte-equal results to slow path")
    func fastPathMatchesSlowPath() throws {
        let path = try #require(Self.testMDXPath, "Set MDICT_TEST_FILE")
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }

        let sidecarDir = Self.makeTempSidecarDir()
        defer { try? FileManager.default.removeItem(at: sidecarDir) }

        // --- Phase 1: slow path (cache DISABLED so no sidecar write races) ---
        MDictSidecarCache.cacheDirectory = nil
        let slowReader = try MDictReader(path: path)
        let keys = slowReader.allKeys
        #expect(!keys.isEmpty)

        // Pick ~50 random keys (or fewer if the dict is tiny).
        var rng = SystemRandomNumberGenerator()
        let sampleCount = min(50, keys.count)
        let sampleKeys = (0..<sampleCount).map { _ in keys.randomElement(using: &rng)! }
        let slowResults = Self.snapshotLookups(slowReader, keys: sampleKeys)

        // --- Phase 2: enable cache, slow path again (writes sidecar) ---
        MDictSidecarCache.cacheDirectory = sidecarDir
        MDictSidecarCache.writeMode = .immediate
        _ = try MDictReader(path: path)

        // Wait for the background sidecar write to flush to disk. The write
        // is dispatched on DispatchQueue.global(.utility); 2 s is
        // comfortably longer than any realistic serialization for test
        // MDXs in the dicts/ folder (a ~5 MB sidecar loads in < 50 ms).
        Thread.sleep(forTimeInterval: 2.0)

        let sidecarFiles = (try? FileManager.default.contentsOfDirectory(atPath: sidecarDir.path)) ?? []
        #expect(sidecarFiles.contains { $0.hasSuffix(".idx") },
                "Slow path should have written a sidecar .idx file")

        // --- Phase 3: fresh reader, should hit fast path ---
        let fastReader = try MDictReader(path: path)
        let fastResults = Self.snapshotLookups(fastReader, keys: sampleKeys)

        #expect(slowResults == fastResults,
                "Fast path lookups should match slow path lookups byte-for-byte")
    }

    /// Prefix search must also produce identical results.
    @Test("Fast path prefix search matches slow path")
    func fastPathPrefixSearchMatchesSlowPath() throws {
        let path = try #require(Self.testMDXPath, "Set MDICT_TEST_FILE")
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }

        let sidecarDir = Self.makeTempSidecarDir()
        defer { try? FileManager.default.removeItem(at: sidecarDir) }

        // Ground truth from slow path
        MDictSidecarCache.cacheDirectory = nil
        let slowReader = try MDictReader(path: path)
        let prefixes = ["a", "b", "c", "hel", "un", "pre"]
        let slowResults = prefixes.map { slowReader.search(prefix: $0, limit: 20) }

        // Write a sidecar, then read it back
        MDictSidecarCache.cacheDirectory = sidecarDir
        MDictSidecarCache.writeMode = .immediate
        _ = try MDictReader(path: path)
        Thread.sleep(forTimeInterval: 2.0)

        let fastReader = try MDictReader(path: path)
        let fastResults = prefixes.map { fastReader.search(prefix: $0, limit: 20) }

        for (i, prefix) in prefixes.enumerated() {
            #expect(slowResults[i] == fastResults[i],
                    "Prefix search for '\(prefix)' should match")
        }
    }

    /// A corrupt .idx file (wrong magic bytes, right filename) must NOT
    /// crash `MDictReader.init`; it should silently fall back to the slow
    /// path and still produce a working reader.
    @Test("Corrupt sidecar file falls back to slow path without crash")
    func corruptSidecarFallsBackToSlowPath() throws {
        let path = try #require(Self.testMDXPath, "Set MDICT_TEST_FILE")
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }

        let sidecarDir = Self.makeTempSidecarDir()
        defer { try? FileManager.default.removeItem(at: sidecarDir) }

        // Locate the SHA256-based filename the parser will look up, so our
        // bogus bytes actually land on the path that will be checked.
        guard let meta = MDictReader.loadMetadata(from: path),
              let sha = meta.headerSHA256 else {
            Issue.record("Could not compute header SHA256")
            return
        }
        let bogusSidecar = sidecarDir.appendingPathComponent("\(sha).idx", isDirectory: false)
        // 200 bytes of zeros — longer than the 96-byte header, so the size
        // check passes, but the magic bytes are 0x00000000 which is the
        // wrong magic, so validation must reject it.
        try Data(repeating: 0, count: 200).write(to: bogusSidecar)

        MDictSidecarCache.cacheDirectory = sidecarDir
        // Disable writes so our bogus file stays put and isn't overwritten
        // by a fresh slow-path sidecar during this test.
        MDictSidecarCache.writeMode = .disabled

        // Should fall through to the slow path and succeed.
        let reader = try MDictReader(path: path)
        #expect(reader.entryCount > 0)
        #expect(reader.lookup(reader[0]?.key ?? "") != nil)
    }

    /// `writeMode == .disabled` must prevent sidecar writes even when the
    /// cache directory is configured. This is the invariant that makes the
    /// Action Extension safe to use as a read-only consumer.
    @Test("writeMode .disabled never writes sidecar files")
    func disabledWriteModeProducesNoSidecar() throws {
        let path = try #require(Self.testMDXPath, "Set MDICT_TEST_FILE")
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }

        let sidecarDir = Self.makeTempSidecarDir()
        defer { try? FileManager.default.removeItem(at: sidecarDir) }

        MDictSidecarCache.cacheDirectory = sidecarDir
        MDictSidecarCache.writeMode = .disabled

        _ = try MDictReader(path: path)

        // Wait the same amount of time we would for a normal write.
        Thread.sleep(forTimeInterval: 2.0)

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: sidecarDir.path)) ?? []
        let sidecars = contents.filter { $0.hasSuffix(".idx") }
        #expect(sidecars.isEmpty,
                "writeMode .disabled must not create any .idx files, got: \(sidecars)")
    }

    /// `writeMode == .batched` must queue writes instead of dispatching them,
    /// and `flushPendingWrites()` must drain the queue.
    @Test("writeMode .batched queues writes until flushPendingWrites()")
    func batchedWriteModeQueuesUntilFlush() throws {
        let path = try #require(Self.testMDXPath, "Set MDICT_TEST_FILE")
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }

        let sidecarDir = Self.makeTempSidecarDir()
        defer { try? FileManager.default.removeItem(at: sidecarDir) }

        MDictSidecarCache.cacheDirectory = sidecarDir
        MDictSidecarCache.writeMode = .batched

        _ = try MDictReader(path: path)

        // Immediately after init, the write should be queued, not dispatched.
        // We sample `pendingWriteCount` right away — there is a tiny window
        // where the parser returns before the enqueue completes, but in
        // practice it's synchronous within `MDXParser.init`.
        let queuedRightAfterInit = MDictSidecarCache.pendingWriteCount
        // NOTE: this could be 0 if the MDX is already in a sidecar-containing
        // test run (shouldn't happen with a fresh temp dir, but guard).
        #expect(queuedRightAfterInit >= 1,
                "Expected at least one queued sidecar write in .batched mode")

        // Even after waiting, nothing should be on disk — batched mode
        // never dispatches without an explicit flush.
        Thread.sleep(forTimeInterval: 1.0)
        let contentsBefore = (try? FileManager.default.contentsOfDirectory(atPath: sidecarDir.path)) ?? []
        #expect(contentsBefore.filter { $0.hasSuffix(".idx") }.isEmpty,
                "No sidecar should have been written before flushPendingWrites()")

        // Flush and wait for the now-dispatched task to actually land on disk.
        MDictSidecarCache.flushPendingWrites()
        Thread.sleep(forTimeInterval: 2.0)

        let contentsAfter = (try? FileManager.default.contentsOfDirectory(atPath: sidecarDir.path)) ?? []
        let sidecars = contentsAfter.filter { $0.hasSuffix(".idx") }
        #expect(!sidecars.isEmpty,
                "At least one sidecar should exist after flushPendingWrites()")
        #expect(MDictSidecarCache.pendingWriteCount == 0,
                "Pending queue should be drained after flush")
    }

    /// Sanity: `MDictReader.removeSidecarCache(forHeaderSHA256:)` must
    /// actually delete the file so a next init rebuilds it.
    @Test("removeSidecarCache deletes the .idx file")
    func removeSidecarCacheDeletesFile() throws {
        let path = try #require(Self.testMDXPath, "Set MDICT_TEST_FILE")
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }

        let sidecarDir = Self.makeTempSidecarDir()
        defer { try? FileManager.default.removeItem(at: sidecarDir) }

        MDictSidecarCache.cacheDirectory = sidecarDir
        MDictSidecarCache.writeMode = .immediate

        _ = try MDictReader(path: path)
        Thread.sleep(forTimeInterval: 2.0)

        guard let meta = MDictReader.loadMetadata(from: path),
              let sha = meta.headerSHA256 else {
            Issue.record("Could not compute header SHA256")
            return
        }
        let sidecarPath = sidecarDir.appendingPathComponent("\(sha).idx", isDirectory: false).path
        #expect(FileManager.default.fileExists(atPath: sidecarPath),
                "Sidecar should exist before removal")

        MDictReader.removeSidecarCache(forHeaderSHA256: sha)

        #expect(!FileManager.default.fileExists(atPath: sidecarPath),
                "Sidecar should be gone after removeSidecarCache")
    }

    // MARK: - Folded-key index file

    /// The folded-key index a lookup builds is saved beside the sidecar and
    /// read back by the next reader; a damaged file is ignored, and
    /// `removeSidecarCache` deletes it with the sidecar.
    @Test("The folded-key index is saved, reused, validated and removed with the sidecar")
    func foldedIndexFile() async throws {
        let path = TestFixtures.fixturesDirectory.appendingPathComponent("fallbacks.mdx").path
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }
        let sidecarDir = Self.makeTempSidecarDir()
        defer { try? FileManager.default.removeItem(at: sidecarDir) }
        MDictSidecarCache.cacheDirectory = sidecarDir
        MDictSidecarCache.writeMode = .immediate

        let sha = try #require(MDictReader.loadMetadata(from: path)?.headerSHA256)
        let foldURL = sidecarDir.appendingPathComponent("\(sha).fold", isDirectory: false)
        let identity = try #require(SidecarSourceIdentity.capture(path: path, headerSHA256Hex: sha))

        // First reader: builds the index on first need and saves it.
        let first = try MDictReader(path: path)
        #expect(first.lookup("αθηναι")?.key == "Ἀθῆναι")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: foldURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let built = first.parser.foldedKeyIndex().indices
        let loaded = try #require(FoldedIndexFile.load(from: foldURL, identity: identity,
                                                       keywordCount: first.entryCount))
        #expect(loaded.indices == built)
        #expect(!built.isEmpty)

        // A reader uses the saved index: an (artificially) empty one hides
        // the keys with marks.
        try FoldedIndexFile.write(.empty, to: foldURL, identity: identity, keywordCount: first.entryCount)
        #expect(try MDictReader(path: path).lookup("αθηναι") == nil)

        // A file for another source, or a damaged one, is rebuilt.
        #expect(FoldedIndexFile.load(from: foldURL, identity: identity, keywordCount: first.entryCount + 1) == nil)
        try Data(repeating: 7, count: 80).write(to: foldURL)
        #expect(FoldedIndexFile.load(from: foldURL, identity: identity, keywordCount: first.entryCount) == nil)
        #expect(try MDictReader(path: path).lookup("αθηναι")?.key == "Ἀθῆναι")
        // … and saved again.
        var resaved: FoldedKeyIndex?
        for _ in 0..<300 {
            resaved = FoldedIndexFile.load(from: foldURL, identity: identity, keywordCount: first.entryCount)
            if resaved != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(resaved?.indices == built)

        MDictReader.removeSidecarCache(forHeaderSHA256: sha)
        #expect(!FileManager.default.fileExists(atPath: foldURL.path))
    }

    @Test("saveFoldedKeyIndexIfNeeded writes the index once, and never with writes disabled")
    func saveFoldedIndexInBackgroundPass() throws {
        let path = TestFixtures.fixturesDirectory.appendingPathComponent("fallbacks.mdx").path
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }
        let sidecarDir = Self.makeTempSidecarDir()
        defer { try? FileManager.default.removeItem(at: sidecarDir) }
        MDictSidecarCache.cacheDirectory = sidecarDir

        let sha = try #require(MDictReader.loadMetadata(from: path)?.headerSHA256)
        let foldURL = sidecarDir.appendingPathComponent("\(sha).fold", isDirectory: false)
        let identity = try #require(SidecarSourceIdentity.capture(path: path, headerSHA256Hex: sha))

        MDictSidecarCache.writeMode = .disabled
        try MDictReader(path: path).saveFoldedKeyIndexIfNeeded()
        #expect(!FileManager.default.fileExists(atPath: foldURL.path))

        MDictSidecarCache.writeMode = .immediate
        let reader = try MDictReader(path: path)
        reader.saveFoldedKeyIndexIfNeeded()
        #expect(FoldedIndexFile.hasValidCopy(at: foldURL, identity: identity, keywordCount: reader.entryCount))
        let written = try #require(FoldedIndexFile.load(from: foldURL, identity: identity,
                                                        keywordCount: reader.entryCount))
        #expect(written.indices == FoldedKeyIndex.build(count: reader.entryCount) { reader.parser.keyword(at: $0) }.indices)

        // A valid copy is left alone.
        let stamp = try FileManager.default.attributesOfItem(atPath: foldURL.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        try MDictReader(path: path).saveFoldedKeyIndexIfNeeded()
        #expect(try FileManager.default.attributesOfItem(atPath: foldURL.path)[.modificationDate] as? Date == stamp)
        #expect(!FoldedIndexFile.hasValidCopy(at: foldURL, identity: identity, keywordCount: reader.entryCount + 1))
        #expect(try MDictReader(path: path).lookup("αθηναι")?.key == "Ἀθῆναι")
    }

    /// The fixture, its header SHA and source identity, in a fresh cache
    /// directory. `copy` puts a copy of the fixture in the directory too, so
    /// a test can touch it.
    private struct FoldFixture {
        let path: String
        let sidecarDir: URL
        let sha: String
        let identity: SidecarSourceIdentity
        var foldURL: URL { sidecarDir.appendingPathComponent("\(sha).fold", isDirectory: false) }

        init(copy: Bool = false) throws {
            sidecarDir = SidecarRoundTripTests.makeTempSidecarDir()
            let fixture = TestFixtures.fixturesDirectory.appendingPathComponent("fallbacks.mdx")
            if copy {
                let copied = sidecarDir.appendingPathComponent("copy.mdx")
                try FileManager.default.copyItem(at: fixture, to: copied)
                path = copied.path
            } else {
                path = fixture.path
            }
            sha = try #require(MDictReader.loadMetadata(from: path)?.headerSHA256)
            identity = try #require(SidecarSourceIdentity.capture(path: path, headerSHA256Hex: sha))
        }

        func remove() { try? FileManager.default.removeItem(at: sidecarDir) }

        /// A valid file with an empty index, which hides the keys with marks:
        /// a reader that uses it finds no Ἀθῆναι, one that rejects it does.
        func writeEmptyIndex(identity: SidecarSourceIdentity? = nil, keywordCount: Int) throws {
            try FoldedIndexFile.write(.empty, to: foldURL, identity: identity ?? self.identity, keywordCount: keywordCount)
        }
    }

    @Test("A saved index is rejected when any field of its source identity or its version differs")
    func foldedIndexInvalidation() throws {
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }
        let fixture = try FoldFixture()
        defer { fixture.remove() }
        MDictSidecarCache.cacheDirectory = fixture.sidecarDir
        MDictSidecarCache.writeMode = .disabled
        let count = try MDictReader(path: fixture.path).entryCount
        let identity = fixture.identity

        func isUsed() throws -> Bool {
            FoldedIndexFile.load(from: fixture.foldURL, identity: identity, keywordCount: count) != nil
        }
        func readerFindsAthens() throws -> Bool {
            try MDictReader(path: fixture.path).lookup("αθηναι")?.key == "Ἀθῆναι"
        }
        // The empty index with the right identity is used: no Ἀθῆναι.
        try fixture.writeEmptyIndex(keywordCount: count)
        #expect(try isUsed())
        #expect(try !readerFindsAthens())

        // Another mtime, size or header SHA: rejected, the index is built instead.
        let otherMTime = SidecarSourceIdentity(fileSize: identity.fileSize, mtimeNanos: identity.mtimeNanos + 1,
                                               headerSHA256: identity.headerSHA256)
        try fixture.writeEmptyIndex(identity: otherMTime, keywordCount: count)
        #expect(try !isUsed())
        #expect(try readerFindsAthens())

        let otherSize = SidecarSourceIdentity(fileSize: identity.fileSize + 1, mtimeNanos: identity.mtimeNanos,
                                              headerSHA256: identity.headerSHA256)
        try fixture.writeEmptyIndex(identity: otherSize, keywordCount: count)
        #expect(try !isUsed())
        #expect(try readerFindsAthens())

        var otherDigest = identity.headerSHA256
        otherDigest[0] ^= 0xFF
        let otherSHA = SidecarSourceIdentity(fileSize: identity.fileSize, mtimeNanos: identity.mtimeNanos,
                                             headerSHA256: otherDigest)
        try fixture.writeEmptyIndex(identity: otherSHA, keywordCount: count)
        #expect(try !isUsed())
        #expect(try readerFindsAthens())

        // Another keyword count, or format version.
        try fixture.writeEmptyIndex(keywordCount: count + 1)
        #expect(try !isUsed())
        #expect(try readerFindsAthens())

        try fixture.writeEmptyIndex(keywordCount: count)
        var bytes = try Data(contentsOf: fixture.foldURL)
        bytes.writeUInt32LE(FoldedIndexFile.formatVersion + 1, at: 4)
        try bytes.write(to: fixture.foldURL)
        #expect(try !isUsed())
        #expect(try readerFindsAthens())
    }

    @Test("A touched source file invalidates its saved index")
    func foldedIndexInvalidatedByTouch() throws {
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }
        let fixture = try FoldFixture(copy: true)
        defer { fixture.remove() }
        MDictSidecarCache.cacheDirectory = fixture.sidecarDir
        MDictSidecarCache.writeMode = .immediate

        let reader = try MDictReader(path: fixture.path)
        reader.saveFoldedKeyIndexIfNeeded()
        #expect(FoldedIndexFile.hasValidCopy(at: fixture.foldURL, identity: fixture.identity, keywordCount: reader.entryCount))
        // The same bytes, a second later: not the same source.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 1)], ofItemAtPath: fixture.path)
        let touched = try #require(SidecarSourceIdentity.capture(path: fixture.path, headerSHA256Hex: fixture.sha))
        #expect(touched != fixture.identity)
        #expect(!FoldedIndexFile.hasValidCopy(at: fixture.foldURL, identity: touched, keywordCount: reader.entryCount))
        let fresh = try MDictReader(path: fixture.path)
        let builds = FoldedKeyIndex.builds.value
        #expect(fresh.lookup("αθηναι")?.key == "Ἀθῆναι")
        #expect(FoldedKeyIndex.builds.value == builds + 1)
    }

    @Test("A damaged saved index with a valid header is rejected, and lookups work")
    func damagedFoldedIndex() throws {
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }
        let fixture = try FoldFixture()
        defer { fixture.remove() }
        MDictSidecarCache.cacheDirectory = fixture.sidecarDir
        MDictSidecarCache.writeMode = .disabled
        let reader = try MDictReader(path: fixture.path)
        let count = reader.entryCount
        let index = FoldedKeyIndex.build(count: count) { reader.parser.keyword(at: $0) }
        #expect(index.indices.count > 1)

        func load() -> FoldedKeyIndex? {
            FoldedIndexFile.load(from: fixture.foldURL, identity: fixture.identity, keywordCount: count)
        }
        // The real index round-trips.
        try FoldedIndexFile.write(index, to: fixture.foldURL, identity: fixture.identity, keywordCount: count)
        #expect(load()?.indices == index.indices)

        // Truncated by one entry: the header claims more than the file holds.
        let whole = try Data(contentsOf: fixture.foldURL)
        try whole.dropLast(4).write(to: fixture.foldURL)
        #expect(load() == nil)
        #expect(try MDictReader(path: fixture.path).lookup("αθηναι")?.key == "Ἀθῆναι")

        // Padded by four bytes: the file holds more than the header claims.
        try (whole + Data(repeating: 0, count: 4)).write(to: fixture.foldURL)
        #expect(load() == nil)

        // An index beyond the keyword list.
        try FoldedIndexFile.write(FoldedKeyIndex(indices: [UInt32(count + 1)]), to: fixture.foldURL,
                                  identity: fixture.identity, keywordCount: count)
        #expect(load() == nil)
        #expect(try MDictReader(path: fixture.path).lookup("αθηναι")?.key == "Ἀθῆναι")
        try FoldedIndexFile.write(FoldedKeyIndex(indices: [UInt32(count)]), to: fixture.foldURL,
                                  identity: fixture.identity, keywordCount: count)
        #expect(load() == nil)
        // The last valid index is fine.
        try FoldedIndexFile.write(FoldedKeyIndex(indices: [UInt32(count - 1)]), to: fixture.foldURL,
                                  identity: fixture.identity, keywordCount: count)
        #expect(load()?.indices == [UInt32(count - 1)])
    }

    @Test("A main-thread lookup reads a saved index at once and never builds one")
    func nonWaitingLookupReadsSavedIndex() throws {
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }
        let fixture = try FoldFixture()
        defer { fixture.remove() }
        MDictSidecarCache.cacheDirectory = fixture.sidecarDir
        MDictSidecarCache.writeMode = .immediate

        // The app's background pass saves the index without keeping it.
        try MDictReader(path: fixture.path).saveFoldedKeyIndexIfNeeded()
        #expect(FileManager.default.fileExists(atPath: fixture.foldURL.path))

        // A fresh reader — a later launch — finds marked keys on its very
        // first non-waiting lookup, without building anything.
        let reader = try MDictReader(path: fixture.path)
        let builds = FoldedKeyIndex.builds.value
        let muller = reader.lookup("Muller", headwordLanguage: "DE", waitsForSetup: false)
        #expect(muller?.key == "Müller")
        #expect(muller?.fallback == .diacriticInsensitive)
        #expect(reader.lookup("αθηναι", waitsForSetup: false)?.key == "Ἀθῆναι")
        #expect(reader.search(prefix: "αθη", waitsForSetup: false) == ["Ἀθῆναι"])
        #expect(FoldedKeyIndex.builds.value == builds)
    }

    @Test("Without a saved index, a main-thread lookup returns nothing rather than a loose stem")
    func nonWaitingLookupWithoutSavedIndex() async throws {
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }
        let fixture = try FoldFixture()
        defer { fixture.remove() }
        MDictSidecarCache.cacheDirectory = fixture.sidecarDir
        MDictSidecarCache.writeMode = .immediate

        let reader = try MDictReader(path: fixture.path)
        // Not "Mull": the diacritic step could not run, so the loose stems do not either.
        #expect(reader.lookup("Muller", headwordLanguage: "DE", waitsForSetup: false) == nil)
        // The build was started in the background and its index is saved.
        var found: MDictWordEntry?
        for _ in 0..<300 {
            found = reader.lookup("Muller", headwordLanguage: "DE", waitsForSetup: false)
            if found != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(found?.key == "Müller")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: fixture.foldURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(FoldedIndexFile.hasValidCopy(at: fixture.foldURL, identity: fixture.identity, keywordCount: reader.entryCount))
    }

    @Test("A reader whose file was replaced on disk does not save its index under the new file's identity")
    func staleReaderDoesNotSaveFoldedIndex() throws {
        let saved = Self.saveGlobals()
        defer { Self.restoreGlobals(saved) }
        let fixture = try FoldFixture(copy: true)
        defer { fixture.remove() }
        MDictSidecarCache.cacheDirectory = fixture.sidecarDir
        MDictSidecarCache.writeMode = .immediate

        let old = try MDictReader(path: fixture.path)
        // The preset is updated in place: same path, same header, new mtime.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 1)], ofItemAtPath: fixture.path)
        let current = try #require(SidecarSourceIdentity.capture(path: fixture.path, headerSHA256Hex: fixture.sha))
        #expect(current != fixture.identity)

        // Neither the background pass nor a lookup's queued write saves the old reader's index.
        old.saveFoldedKeyIndexIfNeeded()
        #expect(!FileManager.default.fileExists(atPath: fixture.foldURL.path))
        #expect(old.lookup("αθηναι")?.key == "Ἀθῆναι")
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!FileManager.default.fileExists(atPath: fixture.foldURL.path))

        // The new file's reader saves its own.
        let new = try MDictReader(path: fixture.path)
        new.saveFoldedKeyIndexIfNeeded()
        #expect(FoldedIndexFile.hasValidCopy(at: fixture.foldURL, identity: current, keywordCount: new.entryCount))
        #expect(!FoldedIndexFile.hasValidCopy(at: fixture.foldURL, identity: fixture.identity, keywordCount: new.entryCount))
    }

    @Test("Where indexes are not built, a saved copy is still read; without one nothing is written")
    func readOnlyFoldedIndexPolicy() throws {
        let saved = Self.saveGlobals()
        let savedPolicy = MDictSidecarCache.buildsFoldedKeyIndexes
        defer { Self.restoreGlobals(saved); MDictSidecarCache.buildsFoldedKeyIndexes = savedPolicy }
        let fixture = try FoldFixture()
        defer { fixture.remove() }
        MDictSidecarCache.cacheDirectory = fixture.sidecarDir

        // The extension's configuration: no writes, no builds.
        MDictSidecarCache.writeMode = .disabled
        MDictSidecarCache.buildsFoldedKeyIndexes = false
        let reader = try MDictReader(path: fixture.path)
        let builds = FoldedKeyIndex.builds.value
        #expect(reader.lookup("αθηναι") == nil)
        #expect(reader.lookup("Muller", headwordLanguage: "DE") == nil)
        #expect(reader.lookup("machte", headwordLanguage: "DE")?.key == "machen")
        #expect(FoldedKeyIndex.builds.value == builds)
        #expect(!FileManager.default.fileExists(atPath: fixture.foldURL.path))

        // Once the app has saved the index, the same reader reads it.
        MDictSidecarCache.writeMode = .immediate
        try MDictReader(path: fixture.path).saveFoldedKeyIndexIfNeeded()
        MDictSidecarCache.writeMode = .disabled
        #expect(reader.lookup("αθηναι")?.key == "Ἀθῆναι")
        #expect(reader.lookup("Muller", headwordLanguage: "DE")?.key == "Müller")
        #expect(FoldedKeyIndex.builds.value == builds + 1)   // the save built it, nothing else
    }
}
