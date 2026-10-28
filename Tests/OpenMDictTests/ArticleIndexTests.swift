import Testing
import Foundation
import CryptoKit
@testable import OpenMDict

/// Article-embedding sidecar: the sparse version-2 layout (vectors only for
/// real articles), the dense version-1 layout it replaces, resumable builds,
/// and query results across both. Uses the bundled fixtures and a
/// deterministic stand-in for the Core ML encoder, so no model is needed.
struct ArticleIndexTests {

    // MARK: - Fixtures

    /// Deterministic unit vectors derived from the text (FNV-1a seed →
    /// SplitMix64), so equal texts embed equally and different texts don't.
    final class FakeEncoder: ArticleIndexEncoding {
        let outputDimension: Int
        /// false: report 0 like an encoder that has not run yet and can't
        /// be probed, so the writer has to learn the dimension from a row.
        let reportsDimension: Bool
        let tokenizerMaxLength = 128
        var dimension: Int { reportsDimension ? outputDimension : 0 }
        init(dimension: Int = 16, reportsDimension: Bool = true) {
            self.outputDimension = dimension
            self.reportsDimension = reportsDimension
        }

        func encode(_ text: String) throws -> [Float] {
            var seed: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 { seed = (seed ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            if !reportsDimension, text == " " { throw CocoaError(.featureUnsupported) }
            return ArticleIndexTests.unitVector(seed: seed, dimension: outputDimension)
        }
    }

    /// A `FakeEncoder` that throws once it has encoded `encodesBeforeDeath`
    /// texts, ending the build without the final flush, as a kill would.
    final class DyingEncoder: ArticleIndexEncoding {
        struct Killed: Error {}
        let base = FakeEncoder()
        let encodesBeforeDeath: Int
        private(set) var encodes = 0
        var dimension: Int { base.dimension }
        var tokenizerMaxLength: Int { base.tokenizerMaxLength }
        init(encodesBeforeDeath: Int) { self.encodesBeforeDeath = encodesBeforeDeath }

        func encode(_ text: String) throws -> [Float] {
            guard encodes < encodesBeforeDeath else { throw Killed() }
            encodes += 1
            return try base.encode(text)
        }
    }

    struct InjectedFault: Error {}

    static func unitVector(seed: UInt64, dimension: Int) -> [Float] {
        var state = seed
        var v = (0..<dimension).map { _ -> Float in
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            z ^= z >> 31
            return Float(Double(z) / Double(UInt64.max)) * 2 - 1
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        for i in v.indices { v[i] /= norm }
        return v
    }

    /// Thread-safe recorder for the writer's `@Sendable` callbacks.
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
        var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    }

    /// One scratch directory with a stand-in model file (the writer hashes
    /// whatever file `modelURL` names).
    struct Workspace {
        let dir: URL
        let modelURL: URL

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("openmdict-articleindex-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            modelURL = dir.appendingPathComponent("fake.mlmodel")
            try Data("fake model".utf8).write(to: modelURL)
        }

        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        var modelSHA: Data { Data(SHA256.hash(data: try! Data(contentsOf: modelURL))) }
        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    static func openFixture(_ name: String) throws -> MDictReader {
        try MDictReader(path: TestFixtures.fixturesDirectory.appendingPathComponent(name).path)
    }

    static func isAlias(_ html: String) -> Bool {
        html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@@@LINK=")
    }

    /// Key indices of the records that are articles (not aliases).
    static func articleIndices(_ reader: MDictReader) -> [Int] {
        (0..<reader.entryCount).filter { i in reader[i].map { !isAlias($0.article.html) } ?? false }
    }

    static func embedding(of i: Int, in reader: MDictReader, _ encoder: FakeEncoder) throws -> [Float] {
        try encoder.encode(ArticleIndexWriter.stripHTML(reader[i]!.article.html))
    }

    static func mdxSHA(_ reader: MDictReader) -> Data {
        let hex = Array(reader.metadata.headerSHA256!.utf8)
        return Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }

    /// A sidecar in the dense version-1 layout, byte for byte what the
    /// writer produced before version 2: one row per key, zero rows for
    /// aliases. Built here independently of the production serializer.
    static func writeDenseV1(reader: MDictReader, encoder: FakeEncoder, modelSHA: Data,
                             rowCount: Int? = nil, to url: URL) throws {
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        let rows = rowCount ?? reader.entryCount
        data.append(contentsOf: Array("SIDX".utf8))
        le(UInt16(1)); le(UInt16(0))
        data.append(modelSHA); data.append(mdxSHA(reader))
        le(UInt32(encoder.outputDimension)); le(UInt32(rows)); le(UInt32(128))
        le(UInt64(1_700_000_000)); le(UInt32(0))
        precondition(data.count == 96)
        for i in 0..<rows {
            if let entry = reader[i], !isAlias(entry.article.html) {
                for v in try encoder.encode(ArticleIndexWriter.stripHTML(entry.article.html)) {
                    le(float16Bits(from: v))
                }
            } else {
                data.append(Data(count: encoder.outputDimension * 2))
            }
        }
        try data.write(to: url)
    }

    static func build<E: ArticleIndexEncoding>(
        _ reader: MDictReader, _ ws: Workspace, _ encoder: E, to url: URL,
        limit: Int? = nil, checkpointEvery: Int = 2000,
        cancelAfter: Int? = nil,
        checkpointInterrupt: (() throws -> Void)? = nil,
        progress: ArticleIndexProgress? = nil
    ) throws -> ArticleIndexBuildOutcome {
        var isCancelled: (@Sendable () -> Bool)?
        if let cancelAfter {
            let polls = Box(0)
            isCancelled = { polls.mutate { $0 += 1 }; return polls.value > cancelAfter }
        }
        var writer = ArticleIndexWriter(modelURL: ws.modelURL, outputURL: url, limit: limit, progress: progress)
        writer.checkpointInterrupt = checkpointInterrupt
        return try writer.build(reader: reader, encoder: encoder,
                                checkpointEvery: checkpointEvery, isCancelled: isCancelled)
    }

    /// Build again (resuming whatever is at `url`) and return the progress
    /// values reported.
    static func rebuild(_ reader: MDictReader, _ ws: Workspace, to url: URL,
                        checkpointEvery: Int = 2000) throws -> [Int] {
        let calls = Box<[Int]>([])
        let outcome = try build(reader, ws, FakeEncoder(), to: url, checkpointEvery: checkpointEvery,
                                progress: { done, _, _ in calls.mutate { $0.append(done) } })
        guard case .completed = outcome else { Issue.record("not completed"); return calls.value }
        return calls.value
    }

    /// Overwrite the little-endian u32 at `offset` of the file.
    static func patchU32(_ url: URL, at offset: Int, _ value: UInt32) throws {
        var data = try Data(contentsOf: url)
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) }
        try data.write(to: url)
    }

    static func appendBytes(_ url: URL, _ bytes: Data) throws {
        var data = try Data(contentsOf: url)
        data.append(bytes)
        try data.write(to: url)
    }

    static func createdAt(_ url: URL) throws -> UInt64 {
        try Data(contentsOf: url).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 84, as: UInt64.self)) }
    }

    /// File bytes with `created_at` (offset 84..<92) zeroed, for comparing
    /// builds started at different times.
    static func bytesIgnoringCreatedAt(_ url: URL) throws -> Data {
        var data = try Data(contentsOf: url)
        data.replaceSubrange(84..<92, with: Data(count: 8))
        return data
    }

    static func u32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    /// Query vectors: every article's own embedding plus random directions.
    static func queryVectors(_ reader: MDictReader, _ encoder: FakeEncoder) throws -> [[Float]] {
        try articleIndices(reader).map { try embedding(of: $0, in: reader, encoder) }
            + (0..<25).map { unitVector(seed: UInt64($0) &* 7919 &+ 1, dimension: encoder.outputDimension) }
    }

    // MARK: - Version-2 layout

    @Test("Only articles get a row; each row carries its key index", arguments: ["homographs.mdx", "tiny.mdx"])
    func compactLayout(fixture: String) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture(fixture)
        let encoder = FakeEncoder()
        let articles = Self.articleIndices(reader)
        #expect(articles.count < reader.entryCount)   // the fixture has aliases

        let url = ws.url("v2.semantic.idx")
        let calls = Box<[(Int, Int)]>([])
        let outcome = try Self.build(reader, ws, encoder, to: url, progress: { done, total, _ in
            calls.mutate { $0.append((done, total)) }
        })
        guard case .completed(let header) = outcome else { Issue.record("not completed"); return }
        #expect(header.formatVersion == 2)
        #expect(Int(header.rowCount) == articles.count)
        #expect(Int(header.keyCount) == reader.entryCount)

        // Progress counts keys, aliases included.
        #expect(calls.value.first.map { $0 == (0, reader.entryCount) } == true)
        #expect(calls.value.last.map { $0 == (reader.entryCount, reader.entryCount) } == true)

        let data = try Data(contentsOf: url)
        #expect(data.count == 128 + articles.count * (4 + 2 * encoder.outputDimension))
        #expect(data.count == header.expectedFileSize)
        #expect(Self.u32(data, at: 76) == 0)   // a version-1 reader sees no rows
        #expect(ArticleIndexHeader.parse(data) == header)

        let index = try ArticleIndexReader(sidecarURL: url)
        #expect(index.header == header)
        for (r, keyIndex) in articles.enumerated() {
            let row = index.storedRow(r)
            #expect(row.keyIndex == keyIndex)
            let expected = try Self.embedding(of: keyIndex, in: reader, encoder)
            #expect(zip(row.vector, expected).allSatisfy { abs($0 - $1) < 1e-3 })
        }
        #expect(index.validate(expectedModelSHA256: ws.modelSHA,
                               expectedMDXHeaderSHA256: Self.mdxSHA(reader)) == .ok)
    }

    @Test("Queries return article key indices and never an alias")
    func queriesSkipAliases() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let articles = Self.articleIndices(reader)
        let url = ws.url("v2.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: url)
        let index = try ArticleIndexReader(sidecarURL: url)

        for a in articles {
            let hits = try index.query(try Self.embedding(of: a, in: reader, encoder), topK: 3)
            #expect(hits.first?.articleIndex == a)
            #expect((hits.first?.cosineSimilarity ?? 0) > 0.99)
        }
        let all = try index.query(try Self.embedding(of: articles[0], in: reader, encoder), topK: reader.entryCount)
        #expect(all.map(\.articleIndex).sorted() == articles)
        let aliasKeys = Set(reader.allKeys.indices.filter { !articles.contains($0) }.map { reader.allKeys[$0] })
        #expect(aliasKeys.isSuperset(of: ["am", "Am"]))
    }

    // MARK: - Version-1 compatibility

    @Test("A dense version-1 index is still read and answers exactly like version 2")
    func denseIndexSameHits() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let v1URL = ws.url("v1.semantic.idx"), v2URL = ws.url("v2.semantic.idx")
        try Self.writeDenseV1(reader: reader, encoder: encoder, modelSHA: ws.modelSHA, to: v1URL)
        _ = try Self.build(reader, ws, encoder, to: v2URL)

        let v1 = try ArticleIndexReader(sidecarURL: v1URL)
        let v2 = try ArticleIndexReader(sidecarURL: v2URL)
        #expect(v1.header.formatVersion == 1 && v1.header.isDense)
        #expect(Int(v1.header.rowCount) == reader.entryCount && v1.header.keyCount == v1.header.rowCount)
        #expect(v1.validate(expectedModelSHA256: ws.modelSHA,
                            expectedMDXHeaderSHA256: Self.mdxSHA(reader)) == .ok)
        // v1 pays a full row per alias, v2 four bytes per article.
        let rowBytes = 2 * encoder.outputDimension
        #expect(try Data(contentsOf: v1URL).count == 96 + reader.entryCount * rowBytes)
        #expect(try Data(contentsOf: v2URL).count == 128 + Self.articleIndices(reader).count * (4 + rowBytes))

        for q in try Self.queryVectors(reader, encoder) {
            for k in [1, 5, 10, reader.entryCount] {
                let a = try v1.query(q, topK: k), b = try v2.query(q, topK: k)
                #expect(a.map(\.articleIndex) == b.map(\.articleIndex))
                #expect(a.map(\.cosineSimilarity) == b.map(\.cosineSimilarity))
            }
        }
    }

    @Test("A version-1 file at the output path is rebuilt in the current format, not resumed")
    func densePartialRebuilt() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let reference = ws.url("reference.semantic.idx"), url = ws.url("out.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: reference)

        for rows in [20, reader.entryCount] {
            try Self.writeDenseV1(reader: reader, encoder: encoder, modelSHA: ws.modelSHA,
                                  rowCount: rows, to: url)
            guard case .completed(let header) = try Self.build(reader, ws, encoder, to: url) else {
                Issue.record("not completed"); continue
            }
            #expect(header.formatVersion == ArticleIndexFormat.currentVersion)
            #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference))
        }
    }

    @Test("An unknown format version is refused by the reader")
    func unknownVersionRefused() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let url = ws.url("v3.semantic.idx")
        _ = try Self.build(reader, ws, FakeEncoder(), to: url)
        var data = try Data(contentsOf: url)
        data[4] = 3
        try data.write(to: url)

        let header = try #require(ArticleIndexHeader.parse(data))
        #expect(header.validate(expectedModelSHA256: ws.modelSHA,
                                expectedMDXHeaderSHA256: Self.mdxSHA(reader),
                                expectedEmbeddingDim: header.embeddingDim,
                                actualFileSize: data.count) == .wrongVersion(3))
        #expect(throws: ArticleIndexReaderError.self) { _ = try ArticleIndexReader(sidecarURL: url) }
    }

    // MARK: - Resumable builds

    @Test("A cancelled build resumes to the same file as an uninterrupted one")
    func resumeAfterCancel() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let reference = ws.url("reference.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: reference)
        let articles = Self.articleIndices(reader)
        // Stop points before, at, and right after aliases, and mid-run.
        let aliasIndices = (0..<reader.entryCount).filter { !articles.contains($0) }
        let stops = Set([1, 5, 40] + aliasIndices + aliasIndices.map { $0 + 1 })
            .filter { $0 < reader.entryCount }.sorted()

        for stop in stops {
            let url = ws.url("partial-\(stop).semantic.idx")
            let first = try Self.build(reader, ws, encoder, to: url, checkpointEvery: 4, cancelAfter: stop)
            guard case .interrupted(let header, let through) = first else {
                Issue.record("stop \(stop): not interrupted"); continue
            }
            #expect(through == stop)
            #expect(Int(header.keyCount) == stop)
            #expect(Int(header.rowCount) == articles.filter { $0 < stop }.count)
            let partial = try Data(contentsOf: url)
            #expect(Int(Self.u32(partial, at: 100)) == stop)
            #expect(partial.count == header.expectedFileSize)

            let calls = Box<[Int]>([])
            let second = try Self.build(reader, ws, encoder, to: url, checkpointEvery: 4,
                                        progress: { done, _, _ in calls.mutate { $0.append(done) } })
            guard case .completed(let done) = second else { Issue.record("stop \(stop): not completed"); continue }
            #expect(calls.value.first == stop)   // resumed, not restarted
            #expect(Int(done.rowCount) == articles.count)
            #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference))
        }
    }

    enum CrashDamage: String, CaseIterable {
        /// row_count was written, key_count was not (still the previous
        /// checkpoint's, here 0).
        case tornCheckpoint
        /// A half-written row trails the committed ones.
        case trailingBytes
        case both
    }

    @Test("Resume after a torn checkpoint or trailing bytes continues where it stopped, without duplicate rows",
          arguments: CrashDamage.allCases)
    func resumeAfterCrash(damage: CrashDamage) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let reference = ws.url("reference.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: reference)

        let url = ws.url("crashed.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: url, cancelAfter: 30)
        // A distinctive start time: a restarted build would write "now".
        var data = try Data(contentsOf: url)
        withUnsafeBytes(of: UInt64(1_600_000_000).littleEndian) { data.replaceSubrange(84..<92, with: $0) }
        if damage != .trailingBytes { data.replaceSubrange(100..<104, with: Data(count: 4)) }
        if damage != .tornCheckpoint { data.append(Data(repeating: 0xAB, count: 7)) }
        try data.write(to: url)

        // A torn checkpoint resumes after the last committed row's key.
        let lastRowKey = try #require(Self.articleIndices(reader).last { $0 < 30 })
        let resumePoint = damage == .trailingBytes ? 30 : lastRowKey + 1
        #expect(resumePoint > 0)

        let calls = Box<[Int]>([])
        guard case .completed(let header) = try Self.build(reader, ws, encoder, to: url, progress: { done, _, _ in
            calls.mutate { $0.append(done) }
        }) else { Issue.record("not completed"); return }
        #expect(calls.value.first == resumePoint)   // resumed, not restarted
        #expect(try Self.createdAt(url) == 1_600_000_000)
        #expect(ArticleIndexHeader.parse(try Data(contentsOf: url)) == header)
        #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference))
    }

    @Test("The dimension is taken from the first row when the encoder can't report it")
    func dimensionFromFirstRow() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let reference = ws.url("reference.semantic.idx"), url = ws.url("probed.semantic.idx")
        _ = try Self.build(reader, ws, FakeEncoder(), to: reference)
        guard case .completed(let header) = try Self.build(
            reader, ws, FakeEncoder(reportsDimension: false), to: url, checkpointEvery: 4
        ) else { Issue.record("not completed"); return }
        #expect(header.embeddingDim == 16)
        #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference))
    }

    @Test("A limit covers that many keys from the start")
    func limitCoversKeyPrefix() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let limit = 12
        let url = ws.url("limited.semantic.idx")
        guard case .completed(let header) = try Self.build(reader, ws, encoder, to: url, limit: limit) else {
            Issue.record("not completed"); return
        }
        #expect(Int(header.keyCount) == limit)
        #expect(Int(header.rowCount) == Self.articleIndices(reader).filter { $0 < limit }.count)
        let index = try ArticleIndexReader(sidecarURL: url)
        #expect((0..<Int(header.rowCount)).allSatisfy { index.storedRow($0).keyIndex < limit })
    }

    @Test("A build killed between periodic checkpoints resumes from the last one",
          arguments: [3, 10, 37, 69, 71])
    func resumeAfterKillBetweenCheckpoints(encodesBeforeDeath: Int) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let articles = Self.articleIndices(reader)
        guard encodesBeforeDeath < articles.count else { return }
        let reference = ws.url("reference.semantic.idx")
        _ = try Self.build(reader, ws, FakeEncoder(), to: reference)

        let url = ws.url("killed.semantic.idx")
        let every = 4
        #expect(throws: ArticleIndexWriterError.self) {
            _ = try Self.build(reader, ws, DyingEncoder(encodesBeforeDeath: encodesBeforeDeath), to: url,
                               checkpointEvery: every)
        }
        // The kill came while encoding articles[encodesBeforeDeath]; the
        // last checkpoint covered the keys before the last multiple of 4.
        let checkpointed = articles[encodesBeforeDeath] / every * every
        let data = try Data(contentsOf: url)
        #expect(Int(Self.u32(data, at: 100)) == checkpointed)
        #expect(Int(Self.u32(data, at: 96)) == articles.filter { $0 < checkpointed }.count)

        let calls = try Self.rebuild(reader, ws, to: url, checkpointEvery: every)
        #expect(calls.first == checkpointed)
        #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference))
    }

    @Test("A kill between a checkpoint's row_count and key_count writes loses no article")
    func killInsideCheckpoint() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let articles = Self.articleIndices(reader)
        let reference = ws.url("reference.semantic.idx")
        _ = try Self.build(reader, ws, FakeEncoder(), to: reference)

        let every = 4
        // Every periodic checkpoint plus the final flush.
        let checkpoints = reader.entryCount / every + 1
        for fault in 1...checkpoints {
            let url = ws.url("torn-\(fault).semantic.idx")
            let calls = Box(0)
            #expect(throws: InjectedFault.self) {
                _ = try Self.build(reader, ws, FakeEncoder(), to: url, checkpointEvery: every,
                                   checkpointInterrupt: {
                                       calls.mutate { $0 += 1 }
                                       if calls.value == fault { throw InjectedFault() }
                                   })
            }
            // Torn as the order makes it: the new row_count, the previous key_count.
            let keys = min(fault * every, reader.entryCount)
            let data = try Data(contentsOf: url)
            #expect(Int(Self.u32(data, at: 96)) == articles.filter { $0 < keys }.count)
            #expect(Int(Self.u32(data, at: 100)) == (fault - 1) * every)

            _ = try Self.rebuild(reader, ws, to: url, checkpointEvery: every)
            #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference),
                    "fault in checkpoint \(fault)")
        }
    }

    @Test("Building over a complete index changes nothing, apart from cutting trailing bytes",
          arguments: [0, 9])
    func rerunOnCompleteIndex(trailingBytes: Int) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let url = ws.url("complete.semantic.idx")
        _ = try Self.build(reader, ws, FakeEncoder(), to: url)
        let original = try Data(contentsOf: url)
        try Self.appendBytes(url, Data(repeating: 0xEE, count: trailingBytes))

        let calls = try Self.rebuild(reader, ws, to: url)
        #expect(calls.first == reader.entryCount)   // nothing re-encoded
        #expect(try Data(contentsOf: url) == original)
    }

    enum PartialDamage: String, CaseIterable {
        case lastKeyIndexPastEnd, lastKeyIndexMax, lastKeyIndexZero, keyCountPastEnd
    }

    @Test("A partial whose counts or last key index can't be right is built over, not resumed",
          arguments: PartialDamage.allCases)
    func implausiblePartialRebuilt(damage: PartialDamage) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let reference = ws.url("reference.semantic.idx")
        _ = try Self.build(reader, ws, FakeEncoder(), to: reference)

        let url = ws.url("partial.semantic.idx")
        guard case .interrupted(let header, _) = try Self.build(reader, ws, FakeEncoder(), to: url,
                                                                checkpointEvery: 4, cancelAfter: 40)
        else { Issue.record("not interrupted"); return }
        let rows = Int(header.rowCount)
        #expect(rows > 1)
        let lastRow = 128 + (rows - 1) * header.rowStride
        switch damage {
        case .lastKeyIndexPastEnd: try Self.patchU32(url, at: lastRow, UInt32(reader.entryCount))
        case .lastKeyIndexMax:     try Self.patchU32(url, at: lastRow, .max)
        case .lastKeyIndexZero:    try Self.patchU32(url, at: lastRow, 0)
        case .keyCountPastEnd:     try Self.patchU32(url, at: 100, UInt32(reader.entryCount + 5))
        }

        let calls = try Self.rebuild(reader, ws, to: url)
        #expect(calls.first == 0)   // started over
        #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference))
    }

    @Test("A version-1 partial is never resumed, even when its last row reads as a plausible key index")
    func densePartialNotResumed() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let reference = ws.url("reference.semantic.idx"), url = ws.url("v1-partial.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: reference)
        let rows = 20
        try Self.writeDenseV1(reader: reader, encoder: encoder, modelSHA: ws.modelSHA, rowCount: rows, to: url)
        // Read as a version-2 row, the last row's first 4 bytes would be key 25.
        try Self.patchU32(url, at: 96 + (rows - 1) * 2 * encoder.outputDimension, 25)

        let calls = try Self.rebuild(reader, ws, to: url)
        #expect(calls.first == 0)
        #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference))
    }

    // MARK: - File size and corrupted headers

    @Test("A file shorter than its rows is refused; trailing bytes are tolerated", arguments: [1, 2])
    func fileSizeChecks(version: Int) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let url = ws.url("v\(version).semantic.idx")
        if version == 1 {
            try Self.writeDenseV1(reader: reader, encoder: encoder, modelSHA: ws.modelSHA, to: url)
        } else {
            _ = try Self.build(reader, ws, encoder, to: url)
        }
        let original = try Data(contentsOf: url)
        let header = try #require(ArticleIndexHeader.parse(original))
        func validate(_ data: Data) -> ArticleIndexValidationResult {
            header.validate(expectedModelSHA256: ws.modelSHA, expectedMDXHeaderSHA256: Self.mdxSHA(reader),
                            expectedEmbeddingDim: header.embeddingDim, actualFileSize: data.count)
        }
        let queries = try Self.queryVectors(reader, encoder)
        let expectedHits = try { () throws -> [[Int]] in
            let index = try ArticleIndexReader(sidecarURL: url)
            return try queries.map { try index.query($0, topK: 5).map(\.articleIndex) }
        }()

        // One byte short.
        let short = original.dropLast()
        try short.write(to: url)
        #expect(validate(short) == .sizeMismatch(expected: original.count, actual: original.count - 1))
        #expect(throws: ArticleIndexReaderError.self) { _ = try ArticleIndexReader(sidecarURL: url) }
        guard case .unusable = ArticleIndexSidecar.inspect(url) else {
            Issue.record("short file not reported unusable"); return
        }

        // Trailing bytes past the committed rows.
        let long = original + Data(repeating: 0xCD, count: 13)
        try long.write(to: url)
        #expect(validate(long) == .ok)
        let index = try ArticleIndexReader(sidecarURL: url)
        #expect(try queries.map { try index.query($0, topK: 5).map(\.articleIndex) } == expectedHits)
    }

    struct HeaderCorruption: CustomStringConvertible, Sendable {
        let version: Int
        let fields: [(offset: Int, value: UInt32)]
        /// row_count × row stride exceeds `Int`.
        var overflows = false
        var description: String { "v\(version) " + fields.map { "@\($0.offset)=\($0.value)" }.joined(separator: " ") }
    }

    static let headerCorruptions: [HeaderCorruption] = [
        HeaderCorruption(version: 2, fields: [(72, .max), (96, .max)], overflows: true),
        HeaderCorruption(version: 2, fields: [(72, 1 << 31), (96, .max)], overflows: true),
        HeaderCorruption(version: 2, fields: [(72, 0)]),
        HeaderCorruption(version: 2, fields: [(72, ArticleIndexFormat.maxEmbeddingDim + 1), (96, 0), (100, 0)]),
        HeaderCorruption(version: 1, fields: [(72, .max), (76, .max)], overflows: true),
        HeaderCorruption(version: 1, fields: [(72, 0)]),
    ]

    @Test("A corrupted header is refused with an error, never an arithmetic trap",
          arguments: headerCorruptions)
    func corruptedHeaderRefused(corruption: HeaderCorruption) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let reference = ws.url("reference.semantic.idx"), url = ws.url("corrupt.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: reference)
        if corruption.version == 1 {
            try Self.writeDenseV1(reader: reader, encoder: encoder, modelSHA: ws.modelSHA, to: url)
        } else {
            try FileManager.default.copyItem(at: reference, to: url)
        }
        for field in corruption.fields { try Self.patchU32(url, at: field.offset, field.value) }
        let data = try Data(contentsOf: url)
        let header = try #require(ArticleIndexHeader.parse(data))
        #expect((header.expectedFileSize == nil) == corruption.overflows)

        guard case .headerInvalid = header.checkLayout(fileSize: data.count) else {
            Issue.record("layout not reported invalid: \(header.checkLayout(fileSize: data.count))"); return
        }
        let error = #expect(throws: ArticleIndexReaderError.self) { _ = try ArticleIndexReader(sidecarURL: url) }
        guard case .headerInvalid = error else { Issue.record("unexpected error \(String(describing: error))"); return }
        guard case .unusable = ArticleIndexSidecar.inspect(url) else {
            Issue.record("corrupt file not reported unusable"); return
        }

        // The writer builds over it instead of resuming from it.
        let calls = try Self.rebuild(reader, ws, to: url)
        #expect(calls.first == 0)
        #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(reference))
    }

    // MARK: - Launch check and version-1 conversion

    @Test("Inspection tells current, dense, missing and unusable files apart")
    func inspection() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let v2 = ws.url("v2.semantic.idx"), v1 = ws.url("v1.semantic.idx"), other = ws.url("other.semantic.idx")
        guard case .completed(let header) = try Self.build(reader, ws, encoder, to: v2) else {
            Issue.record("not completed"); return
        }
        try Self.writeDenseV1(reader: reader, encoder: encoder, modelSHA: ws.modelSHA, to: v1)

        #expect(ArticleIndexSidecar.inspect(ws.url("absent.semantic.idx")) == .missing)
        #expect(ArticleIndexSidecar.inspect(v2) == .current(header))
        guard case .dense(let dense) = ArticleIndexSidecar.inspect(v1) else {
            Issue.record("v1 not dense"); return
        }
        #expect(Int(dense.keyCount) == reader.entryCount)

        var future = try Data(contentsOf: v2)
        future[4] = 3
        try future.write(to: other)
        #expect(ArticleIndexSidecar.inspect(other) == .unusable("\(ArticleIndexValidationResult.wrongVersion(3))"))
        try Data("not a sidecar at all, but long enough to hold a header ............................................................".utf8)
            .write(to: other)
        guard case .unusable = ArticleIndexSidecar.inspect(other) else { Issue.record("text file not unusable"); return }
    }

    @Test("Launch decisions: keep current files, convert complete version-1 indexes, discard the rest")
    func launchActions() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let v2 = ws.url("v2.semantic.idx"), v1 = ws.url("v1.semantic.idx")
        guard case .completed(let current) = try Self.build(reader, ws, FakeEncoder(), to: v2) else {
            Issue.record("not completed"); return
        }
        try Self.writeDenseV1(reader: reader, encoder: FakeEncoder(), modelSHA: ws.modelSHA, to: v1)
        guard case .dense(let dense) = ArticleIndexSidecar.inspect(v1) else { Issue.record("v1 not dense"); return }

        let table: [(ArticleIndexSidecarCondition, Bool, ArticleIndexSidecarAction)] = [
            (.current(current), true, .keep), (.current(current), false, .keep),
            (.dense(dense), true, .convert), (.dense(dense), false, .discard),
            (.unusable("x"), true, .discard), (.unusable("x"), false, .discard),
            (.missing, true, .discard), (.missing, false, .discard),
        ]
        for (condition, indexed, action) in table {
            #expect(ArticleIndexSidecar.launchAction(for: condition, recordIsIndexed: indexed) == action,
                    "\(condition), indexed: \(indexed)")
        }
    }

    @Test("A complete version-1 index converts to exactly what a fresh build writes",
          arguments: ["homographs.mdx", "tiny.mdx"])
    func denseConversion(fixture: String) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture(fixture)
        let encoder = FakeEncoder()
        let fresh = ws.url("fresh.semantic.idx"), url = ws.url("converted.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: fresh)
        try Self.writeDenseV1(reader: reader, encoder: encoder, modelSHA: ws.modelSHA, to: url)
        let queries = try Self.queryVectors(reader, encoder)
        let denseHits = try { () throws -> [[ArticleIndexHit]] in
            let index = try ArticleIndexReader(sidecarURL: url)
            return try queries.map { try index.query($0, topK: reader.entryCount) }
        }()

        let header = try ArticleIndexSidecar.convertDenseInPlace(at: url, reader: reader)
        #expect(header.formatVersion == ArticleIndexFormat.currentVersion)
        #expect(Int(header.rowCount) == Self.articleIndices(reader).count)
        #expect(Int(header.keyCount) == reader.entryCount)
        #expect(header.createdAt == 1_700_000_000)   // when the version-1 build started
        #expect(try Self.bytesIgnoringCreatedAt(url) == Self.bytesIgnoringCreatedAt(fresh))
        #expect(!FileManager.default.fileExists(atPath: ArticleIndexSidecar.conversionURL(for: url).path))
        #expect(ArticleIndexSidecar.inspect(url) == .current(header))

        let converted = try ArticleIndexReader(sidecarURL: url), rebuilt = try ArticleIndexReader(sidecarURL: fresh)
        for (q, before) in zip(queries, denseHits) {
            for k in [1, 5, reader.entryCount] {
                let a = try converted.query(q, topK: k), b = try rebuilt.query(q, topK: k)
                #expect(a.map(\.articleIndex) == b.map(\.articleIndex))
                #expect(a.map(\.cosineSimilarity) == b.map(\.cosineSimilarity))
                #expect(a.map(\.articleIndex) == before.prefix(k).map(\.articleIndex))
            }
        }
    }

    enum DenseDefect: String, CaseIterable {
        /// Alias rows hold their target's vector (writers that embedded lookup(key)).
        case aliasRowsHoldVectors
        /// Both "bank" records carry the first one's vector.
        case homographsShareVector
        /// An article row is zero.
        case articleRowZero
        case incomplete
        case otherMDX
    }

    @Test("A version-1 index whose rows don't match the records is not converted and stays untouched",
          arguments: DenseDefect.allCases)
    func denseConversionRefused(defect: DenseDefect) throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let url = ws.url("v1.semantic.idx")
        let dim = encoder.outputDimension
        let articles = Self.articleIndices(reader)
        try Self.writeDenseV1(reader: reader, encoder: encoder, modelSHA: ws.modelSHA,
                              rowCount: defect == .incomplete ? 20 : nil, to: url)
        var data = try Data(contentsOf: url)
        func row(_ i: Int) -> Range<Int> { (96 + i * dim * 2) ..< (96 + (i + 1) * dim * 2) }
        switch defect {
        case .aliasRowsHoldVectors:
            let alias = try #require((0..<reader.entryCount).first { !articles.contains($0) })
            data.replaceSubrange(row(alias), with: data[row(articles[0])])
        case .homographsShareVector:
            let banks = articles.filter { reader.allKeys[$0] == "bank" }
            #expect(banks.count == 2)
            data.replaceSubrange(row(banks[1]), with: data[row(banks[0])])
        case .articleRowZero:
            data.replaceSubrange(row(articles[3]), with: Data(count: dim * 2))
        case .incomplete:
            break
        case .otherMDX:
            data[40] ^= 0xFF
        }
        try data.write(to: url)

        let error = #expect(throws: ArticleIndexConversionError.self) {
            try ArticleIndexSidecar.convertDenseInPlace(at: url, reader: reader)
        }
        switch (defect, error) {
        case (.aliasRowsHoldVectors, .rowsDisagreeWithRecords?), (.homographsShareVector, .rowsDisagreeWithRecords?),
             (.articleRowZero, .rowsDisagreeWithRecords?), (.incomplete, .incomplete?), (.otherMDX, .mdxMismatch?):
            break
        default:
            Issue.record("unexpected error \(String(describing: error))")
        }
        #expect(error?.requiresRebuild == true)
        #expect(try Data(contentsOf: url) == data)
        #expect(!FileManager.default.fileExists(atPath: ArticleIndexSidecar.conversionURL(for: url).path))
    }

    @Test("Walking records with a block cache returns what the subscript returns")
    func recordWalker() throws {
        for fixture in ["homographs.mdx", "tiny.mdx"] {
            let reader = try Self.openFixture(fixture)
            let walker = reader.recordWalker()
            // In order, then backwards (every block change drops the cache).
            for i in Array(0..<reader.entryCount) + (0..<reader.entryCount).reversed() {
                #expect(walker[i]?.article.html == reader[i]?.article.html)
                #expect(walker[i]?.key == reader[i]?.key)
            }
            #expect(walker[reader.entryCount] == nil && walker[-1] == nil)
        }
        // The walker's cache holds one block; a lookup's keeps them all.
        let one = MDXParser.BlockCache(capacity: 1), all = MDXParser.BlockCache()
        for cache in [one, all] {
            cache.store(Data([1]), at: 0)
            cache.store(Data([2]), at: 1)
        }
        #expect(one.blocks == [1: Data([2])])
        #expect(all.blocks == [0: Data([1]), 1: Data([2])])
    }
}
