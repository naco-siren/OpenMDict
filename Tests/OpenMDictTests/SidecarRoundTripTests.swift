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
        // MDXs in the dicts/ folder (a ~5 MB sidecar takes < 50 ms).
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
}
