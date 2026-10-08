import Testing
import Foundation
@testable import OpenMDict

/// Opt-in throughput measurement for the LZO1X decoder. Prints MB/s per
/// vector; makes no assertions about speed (timings are machine-specific).
///
///     MDICT_LZO_BENCH=1 swift test -c release --filter LZO1XBenchmark
@Suite
struct LZO1XBenchmark {

    @Test("Decode throughput per vector")
    func throughput() throws {
        guard ProcessInfo.processInfo.environment["MDICT_LZO_BENCH"] == "1" else {
            return  // opt-in only
        }
        let dir = TestFixtures.fixturesDirectory.appendingPathComponent("lzo1x", isDirectory: true)
        for name in ["text-6k", "zeros-100k", "near-repeat-10k", "mixed-300k", "random-5k"] {
            let raw = try Data(contentsOf: dir.appendingPathComponent("\(name).raw"))
            let lzo = try Data(contentsOf: dir.appendingPathComponent("\(name).lzo"))
            for _ in 0..<3 { _ = try Decompressor.decompressLZO(lzo, outputSize: raw.count) }  // warm-up
            let iterations = max(20, 20_000_000 / max(raw.count, 1))
            let started = DispatchTime.now().uptimeNanoseconds
            var produced = 0
            for _ in 0..<iterations {
                produced &+= try Decompressor.decompressLZO(lzo, outputSize: raw.count).count
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            let megabytes = Double(produced) / 1_048_576
            let padded = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("BENCH \(padded) \(iterations) iters  \(String(format: "%.1f", megabytes)) MB  "
                  + "\(String(format: "%.3f", seconds)) s  \(String(format: "%.1f", megabytes / seconds)) MB/s")
            #expect(produced == raw.count * iterations)
        }
    }
}
