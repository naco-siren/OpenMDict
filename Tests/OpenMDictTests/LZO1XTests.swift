import Testing
import Foundation
@testable import OpenMDict

/// Tests for the pure-Swift LZO1X decoder.
///
/// `Tests/Fixtures/lzo1x/*.lzo` were produced by the reference LZO1X-1
/// compressor from the matching `*.raw` inputs (see `make-lzo-vectors` note
/// in Tests/Fixtures/README.md) and cover every instruction class of the
/// format: short/long literal runs, M1 (both states), M2, M3, M4 (far
/// offsets), extended lengths and the end-of-stream marker.
@Suite
struct LZO1XTests {

    // MARK: - Fixtures

    static var vectorDirectory: URL {
        TestFixtures.fixturesDirectory.appendingPathComponent("lzo1x", isDirectory: true)
    }

    struct Vector: CustomStringConvertible {
        let name: String
        let raw: Data
        let compressed: Data
        var description: String { name }
    }

    static func loadVectors() throws -> [Vector] {
        let files = try FileManager.default.contentsOfDirectory(atPath: vectorDirectory.path)
        return try files.filter { $0.hasSuffix(".lzo") }.sorted().map { file in
            let name = String(file.dropLast(4))
            let dir = vectorDirectory
            return Vector(
                name: name,
                raw: try Data(contentsOf: dir.appendingPathComponent("\(name).raw")),
                compressed: try Data(contentsOf: dir.appendingPathComponent(file))
            )
        }
    }

    /// Deterministic generator so fuzz failures are reproducible.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Round trips

    @Test("Vectors decode byte-for-byte")
    func vectorsRoundTrip() throws {
        let vectors = try Self.loadVectors()
        #expect(vectors.count >= 10, "expected the full vector set in Tests/Fixtures/lzo1x")
        for v in vectors {
            let out = try LZO1X.decompress(v.compressed, expectedSize: v.raw.count)
            #expect(out == v.raw, "\(v.name): output differs from the original input")
        }
    }

    @Test("Oversized output buffer is trimmed to the decoded length")
    func oversizedBufferIsTrimmed() throws {
        for v in try Self.loadVectors() {
            let out = try LZO1X.decompress(v.compressed, expectedSize: v.raw.count + 1000)
            #expect(out == v.raw, "\(v.name)")
        }
    }

    @Test("Undersized output buffer throws outputOverrun")
    func undersizedBufferThrows() throws {
        for v in try Self.loadVectors() where !v.raw.isEmpty {
            #expect(throws: LZO1XError.outputOverrun, "\(v.name)") {
                try LZO1X.decompress(v.compressed, expectedSize: v.raw.count - 1)
            }
        }
    }

    // MARK: - Hand-built streams (known answers)

    @Test("Bare end-of-stream marker decodes to nothing")
    func emptyStream() throws {
        let out = try LZO1X.decompress(Data([0x11, 0x00, 0x00]), expectedSize: 0)
        #expect(out.isEmpty)
        // Zero-capacity raw-buffer path as well.
        let n = try Data([0x11, 0x00, 0x00]).withUnsafeBytes { src in
            try LZO1X.decompress(src, into: UnsafeMutableRawBufferPointer(start: nil, count: 0))
        }
        #expect(n == 0)
    }

    @Test("M1 two-byte match after a short literal run")
    func m1TwoByteMatch() throws {
        // 18 → copy 1 literal ('a'), state 1; 0x00 + 0x00 → M1: distance 1,
        // length 2, no trailing literals; 0x11 0x00 0x00 → end.
        let stream = Data([18, 0x61, 0x00, 0x00, 0x11, 0x00, 0x00])
        let out = try LZO1X.decompress(stream, expectedSize: 3)
        #expect(out == Data("aaa".utf8))
    }

    @Test("M1 three-byte match after a long literal run")
    func m1ThreeByteMatch() throws {
        // 22 → copy 5 literals, state 4. Then an M1 instruction with
        // state 4 is a 3-byte match at distance ≥ 2049, which is impossible
        // with only 5 bytes written → lookbehindOverrun.
        var stream = Data([22])
        stream.append(contentsOf: Data("hello".utf8))
        stream.append(contentsOf: [0x00, 0x00])
        #expect(throws: LZO1XError.lookbehindOverrun) {
            try LZO1X.decompress(stream, expectedSize: 64)
        }
    }

    @Test("End marker is accepted with any M4 length field (liblzo2 behaviour)")
    func endMarkerLengthIsIgnored() throws {
        // The reference compressor always emits 0x11 0x00 0x00, but liblzo2's
        // decoder (unlike lzokay) ends the stream on any M4 whose distance is
        // zero. 0x17 carries a length field of 7; it must still mean "end".
        var stream = Data([22])
        stream.append(contentsOf: Data("hello".utf8))
        stream.append(contentsOf: [0x17, 0x00, 0x00])
        #expect(try LZO1X.decompress(stream, expectedSize: 5) == Data("hello".utf8))
    }

    @Test("Trailing bytes after the end marker are rejected")
    func trailingBytesRejected() {
        #expect(throws: LZO1XError.inputNotConsumed(trailingBytes: 2)) {
            try LZO1X.decompress(Data([0x11, 0x00, 0x00, 0xAA, 0xBB]), expectedSize: 0)
        }
    }

    @Test("Match before the start of output is rejected")
    func lookbehindOverrun() {
        // A first byte of 18 or more starts a literal run, so the only match
        // that can appear first is M4 (0x10/0x11). 0x11 + LE16 0x0004 is a
        // 3-byte match at distance 16385 with nothing written yet.
        #expect(throws: LZO1XError.lookbehindOverrun) {
            try LZO1X.decompress(Data([0x11, 0x04, 0x00]), expectedSize: 16)
        }
        // M2 after a one-byte literal run reaching back two bytes.
        #expect(throws: LZO1XError.lookbehindOverrun) {
            try LZO1X.decompress(Data([18, 0x61, 0x44, 0x00, 0x11, 0x00, 0x00]), expectedSize: 16)
        }
        // A first byte ≥ 22 that promises more literals than the stream holds.
        #expect(throws: LZO1XError.inputOverrun) {
            try LZO1X.decompress(Data([0x40, 0x00, 0x11, 0x00, 0x00]), expectedSize: 16)
        }
    }

    @Test("Too-short input is rejected")
    func tooShortInput() {
        for bytes in [[], [0x11], [0x11, 0x00]] as [[UInt8]] {
            #expect(throws: LZO1XError.inputOverrun) {
                try LZO1X.decompress(Data(bytes), expectedSize: 16)
            }
        }
    }

    // MARK: - Robustness

    @Test("Every truncation of a valid stream throws and never crashes")
    func truncationsThrow() throws {
        for v in try Self.loadVectors() {
            let n = v.compressed.count
            // Exhaustive for small streams, sampled for large ones.
            let cuts: [Int] = n <= 600
                ? Array(0..<n)
                : (0..<n).filter { $0 < 300 || $0 > n - 300 || $0 % 97 == 0 }
            for cut in cuts {
                let truncated = v.compressed.prefix(cut)
                #expect(throws: (any Error).self, "\(v.name) cut at \(cut)") {
                    try LZO1X.decompress(truncated, expectedSize: v.raw.count)
                }
            }
        }
    }

    @Test("Randomly corrupted streams never crash")
    func corruptedStreamsDoNotCrash() throws {
        var rng = SplitMix64(seed: 0x5EED_1234)
        let vectors = try Self.loadVectors().filter { $0.compressed.count > 3 }
        var succeeded = 0, failed = 0
        for _ in 0..<4000 {
            let v = vectors[Int(rng.next() % UInt64(vectors.count))]
            var bytes = [UInt8](v.compressed)
            let flips = 1 + Int(rng.next() % 3)
            for _ in 0..<flips {
                let i = Int(rng.next() % UInt64(bytes.count))
                bytes[i] = UInt8(truncatingIfNeeded: rng.next())
            }
            let slack = Int(rng.next() % 64)
            do {
                _ = try LZO1X.decompress(Data(bytes), expectedSize: v.raw.count + slack)
                succeeded += 1
            } catch {
                failed += 1
            }
        }
        // A corrupted stream usually fails, but the point is that it never traps.
        #expect(succeeded + failed == 4000)
    }

    @Test("Random garbage never crashes")
    func garbageDoesNotCrash() {
        var rng = SplitMix64(seed: 0xBAD_F00D)
        for _ in 0..<3000 {
            let len = Int(rng.next() % 96)
            let bytes = (0..<len).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            _ = try? LZO1X.decompress(Data(bytes), expectedSize: Int(rng.next() % 512))
        }
    }
}
