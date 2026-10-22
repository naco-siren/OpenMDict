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

    static func build(_ reader: MDictReader, _ ws: Workspace, _ encoder: FakeEncoder, to url: URL,
                      limit: Int? = nil, checkpointEvery: Int = 2000,
                      cancelAfter: Int? = nil,
                      progress: ArticleIndexProgress? = nil) throws -> ArticleIndexBuildOutcome {
        var isCancelled: (@Sendable () -> Bool)?
        if let cancelAfter {
            let polls = Box(0)
            isCancelled = { polls.mutate { $0 += 1 }; return polls.value > cancelAfter }
        }
        let writer = ArticleIndexWriter(modelURL: ws.modelURL, outputURL: url, limit: limit, progress: progress)
        return try writer.build(reader: reader, encoder: encoder,
                                checkpointEvery: checkpointEvery, isCancelled: isCancelled)
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

    @Test("Resume after a torn checkpoint or trailing bytes adds no duplicate rows")
    func resumeAfterCrash() throws {
        let ws = try Workspace(); defer { ws.remove() }
        let reader = try Self.openFixture("homographs.mdx")
        let encoder = FakeEncoder()
        let reference = ws.url("reference.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: reference)

        let url = ws.url("crashed.semantic.idx")
        _ = try Self.build(reader, ws, encoder, to: url, cancelAfter: 30)
        var data = try Data(contentsOf: url)
        // row_count was written, key_count was not (still the previous
        // checkpoint's), and a half-written row trails the committed ones.
        data.replaceSubrange(100..<104, with: Data(count: 4))
        data.append(Data(repeating: 0xAB, count: 7))
        try data.write(to: url)

        guard case .completed = try Self.build(reader, ws, encoder, to: url) else {
            Issue.record("not completed"); return
        }
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
}
