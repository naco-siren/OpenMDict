//
//  OpenMDict Benchmark Tool
//
//  A reproducible benchmark that measures the sidecar-index fast-path against
//  the full parse slow-path for real MDX dictionaries. Run against your own
//  `.mdx` files to quantify cold init, warm init, lookup, and prefix-search
//  performance before vs after the sidecar cache.
//
//  Build:   swift build -c release --product openmdict-bench
//  Usage:   .build/release/openmdict-bench [options] <mdx1> [mdx2 ...]
//
//  Options:
//    --sidecar-dir PATH   Cache directory (default: /tmp/openmdict-bench-cache)
//    -n, --iterations N   Runs per phase (default: 5)
//    --lookups N          Random-key lookups per MDX (default: 200)
//    --purge              Clear the cache dir before starting
//    --verify             Compare fast-path results against slow-path results
//    -h, --help           Show this help
//

import Foundation
import OpenMDict

// MARK: - ANSI

enum ANSI {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let cyan = "\u{001B}[36m"
}

func bold(_ s: String) -> String { ANSI.bold + s + ANSI.reset }
func dim(_ s: String) -> String { ANSI.dim + s + ANSI.reset }
func green(_ s: String) -> String { ANSI.green + s + ANSI.reset }
func yellow(_ s: String) -> String { ANSI.yellow + s + ANSI.reset }
func cyan(_ s: String) -> String { ANSI.cyan + s + ANSI.reset }
func red(_ s: String) -> String { ANSI.red + s + ANSI.reset }

// MARK: - Timing & stats

@inline(__always)
func measureMs(_ block: () throws -> Void) rethrows -> Double {
    let t0 = CFAbsoluteTimeGetCurrent()
    try block()
    return (CFAbsoluteTimeGetCurrent() - t0) * 1000
}

struct Stats {
    let samples: [Double]
    let min: Double
    let max: Double
    let mean: Double
    let p50: Double
    let p95: Double
    let stddev: Double

    init(_ raw: [Double]) {
        let sorted = raw.sorted()
        samples = sorted
        if sorted.isEmpty {
            min = 0; max = 0; mean = 0; p50 = 0; p95 = 0; stddev = 0
            return
        }
        min = sorted.first!
        max = sorted.last!
        let sum = sorted.reduce(0, +)
        let meanLocal = sum / Double(sorted.count)
        mean = meanLocal
        p50 = sorted[sorted.count / 2]
        p95 = sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let variance = sorted.reduce(0.0) { $0 + ($1 - meanLocal) * ($1 - meanLocal) } / Double(sorted.count)
        stddev = variance.squareRoot()
    }

    func line() -> String {
        String(format: "mean %7.2f  p50 %7.2f  p95 %7.2f  min %7.2f  max %7.2f  σ %6.2f  (n=%d)",
               mean, p50, p95, min, max, stddev, samples.count)
    }
}

// MARK: - Options

struct BenchOptions {
    var sidecarDir: URL = URL(fileURLWithPath: "/tmp/openmdict-bench-cache")
    var iterations: Int = 5
    var lookupCount: Int = 200
    var purge: Bool = false
    var verify: Bool = false
    var mdxPaths: [String] = []
    var dictsDirs: [URL] = []
}

/// Recursively walk `dir` looking for `.mdx` files. Returns an empty array
/// if the directory cannot be enumerated.
func scanForMDXFiles(in dir: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: dir,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    var found: [String] = []
    for case let url as URL in enumerator {
        guard url.pathExtension.lowercased() == "mdx" else { continue }
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
           values.isRegularFile == true {
            found.append(url.path)
        }
    }
    // Deterministic order — sort by path so runs are reproducible.
    return found.sorted()
}

func parseArgs() -> BenchOptions {
    var opts = BenchOptions()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--sidecar-dir":
            i += 1
            guard i < args.count else { fail("missing value for --sidecar-dir") }
            opts.sidecarDir = URL(fileURLWithPath: args[i])
        case "--dicts-dir":
            i += 1
            guard i < args.count else { fail("missing value for --dicts-dir") }
            opts.dictsDirs.append(URL(fileURLWithPath: args[i]))
        case "-n", "--iterations":
            i += 1
            guard i < args.count, let n = Int(args[i]), n > 0 else { fail("--iterations requires positive int") }
            opts.iterations = n
        case "--lookups":
            i += 1
            guard i < args.count, let n = Int(args[i]), n > 0 else { fail("--lookups requires positive int") }
            opts.lookupCount = n
        case "--purge":
            opts.purge = true
        case "--verify":
            opts.verify = true
        case "-h", "--help":
            printHelp()
            exit(0)
        default:
            if arg.hasPrefix("-") {
                fail("unknown option: \(arg)")
            }
            opts.mdxPaths.append(arg)
        }
        i += 1
    }

    // Expand --dicts-dir into the mdxPaths list (recursive scan).
    for dir in opts.dictsDirs {
        let found = scanForMDXFiles(in: dir)
        if found.isEmpty {
            FileHandle.standardError.write("warning: no .mdx files found under \(dir.path)\n".data(using: .utf8)!)
        }
        opts.mdxPaths.append(contentsOf: found)
    }

    // Deduplicate (in case both --dicts-dir and explicit path point to the same file).
    var seen = Set<String>()
    opts.mdxPaths = opts.mdxPaths.filter { seen.insert($0).inserted }

    if opts.mdxPaths.isEmpty {
        printHelp()
        exit(1)
    }
    return opts
}

func printHelp() {
    print("""
    \(bold("openmdict-bench")) — OpenMDict sidecar-index performance benchmark

    \(yellow("Usage:"))
        openmdict-bench [options] [<mdx1> <mdx2> ...]

    \(yellow("Options:"))
        --dicts-dir PATH      Recursively scan PATH for .mdx files (repeatable)
        --sidecar-dir PATH    Cache directory (default: /tmp/openmdict-bench-cache)
        -n, --iterations N    Runs per phase (default: 5)
        --lookups N           Random-key lookups per MDX (default: 200)
        --purge               Clear the cache dir before starting
        --verify              Compare fast-path lookups against slow-path lookups
        -h, --help            Show this help

    \(yellow("Examples:"))
        # Single dict (relative path)
        openmdict-bench path/to/dictionary.mdx

        # Multiple dicts via positional args + shell glob
        openmdict-bench -n 10 --verify dicts/*/*.mdx

        # Recursive scan — grab every .mdx under a directory
        openmdict-bench --dicts-dir dicts --purge --verify
    """)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("error: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Phases

/// Ensure the sidecar for `path` exists on disk and then wait for background
/// writes to flush. Used as a setup step before timing the warm-init phase.
func primeSidecar(path: String, sidecarDir: URL) throws {
    MDictSidecarCache.cacheDirectory = sidecarDir
    _ = try MDictReader(path: path)
    // Background sidecar writes are dispatched on DispatchQueue.global(.utility).
    // In a short-lived CLI process we need to wait briefly so the file lands
    // on disk before the next measurement run reads it.
    Thread.sleep(forTimeInterval: 1.5)
}

/// Delete only the sidecar(s) for this MDX — not the whole dir, so other
/// benchmarks running against the same cache dir are not disturbed.
func purgeSidecar(forMDX path: String, sidecarDir: URL) throws {
    guard let sha = MDictReader.loadMetadata(from: path)?.headerSHA256 else { return }
    let url = sidecarDir.appendingPathComponent("\(sha).idx", isDirectory: false)
    try? FileManager.default.removeItem(at: url)
    // Also purge MDD sidecars in the same directory (if the file has associated .mdd).
    let mdxURL = URL(fileURLWithPath: path)
    let dir = mdxURL.deletingLastPathComponent()
    let base = mdxURL.deletingPathExtension().lastPathComponent
    if let mdds = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        for mdd in mdds where mdd.pathExtension.lowercased() == "mdd"
            && mdd.deletingPathExtension().lastPathComponent == base {
            if let mddMeta = MDictReader.loadMetadata(from: mdd.path),
               let mddSha = mddMeta.headerSHA256 {
                let mddSidecar = sidecarDir.appendingPathComponent("\(mddSha).idx", isDirectory: false)
                try? FileManager.default.removeItem(at: mddSidecar)
            }
        }
    }
}

/// Measure cold init time: for each iteration, purge the sidecar, disable
/// caching temporarily so no sidecar is written (keeping subsequent
/// iterations clean), then time MDictReader.init.
func measureCold(path: String, iterations: Int, sidecarDir: URL) throws -> Stats {
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        try purgeSidecar(forMDX: path, sidecarDir: sidecarDir)
        // Disable cache for this measurement so no background write races.
        MDictSidecarCache.cacheDirectory = nil
        let ms = try measureMs {
            _ = try MDictReader(path: path)
        }
        samples.append(ms)
    }
    return Stats(samples)
}

/// Measure warm init time: sidecar must exist and be valid. Cache directory
/// stays configured so the fast path engages on every iteration.
func measureWarm(path: String, iterations: Int, sidecarDir: URL) throws -> Stats {
    MDictSidecarCache.cacheDirectory = sidecarDir
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let ms = try measureMs {
            _ = try MDictReader(path: path)
        }
        samples.append(ms)
    }
    return Stats(samples)
}

func measureLookups(reader: MDictReader, count: Int) -> Stats {
    let keys = reader.allKeys
    guard !keys.isEmpty else { return Stats([]) }
    var rng = SystemRandomNumberGenerator()
    let samples = (0..<count).map { _ -> Double in
        let key = keys.randomElement(using: &rng)!
        return measureMs { _ = reader.lookup(key) }
    }
    return Stats(samples)
}

func measurePrefixSearch(reader: MDictReader) -> Stats {
    // Mix of short and long prefixes across common letter distributions.
    let prefixes = ["a", "b", "c", "e", "hel", "th", "un", "pre", "com", "inter"]
    let samples = prefixes.map { prefix in
        measureMs { _ = reader.search(prefix: prefix, limit: 20) }
    }
    return Stats(samples)
}

/// Compare fast-path vs slow-path lookups for the same set of random keys.
/// Returns number of mismatches (0 = perfect parity).
func verifyCorrectness(path: String, sidecarDir: URL, sampleCount: Int = 100) throws -> (total: Int, mismatches: Int) {
    // Get ground truth (slow path)
    MDictSidecarCache.cacheDirectory = nil
    let slowReader = try MDictReader(path: path)
    let keys = slowReader.allKeys
    guard !keys.isEmpty else { return (0, 0) }

    var rng = SystemRandomNumberGenerator()
    let samples = (0..<Swift.min(sampleCount, keys.count)).map { _ in keys.randomElement(using: &rng)! }

    struct Snapshot: Equatable {
        let key: String
        let htmlLen: Int
        let index: Int
    }
    let slowResults: [String: Snapshot] = samples.reduce(into: [:]) { acc, key in
        if let e = slowReader.lookup(key) {
            acc[key] = Snapshot(key: e.key, htmlLen: e.article.html.count, index: e.index)
        }
    }
    // Prefix search parity
    let prefixes = ["a", "hel", "th", "un", "pre"]
    let slowPrefixResults: [String: [String]] = prefixes.reduce(into: [:]) { acc, p in
        acc[p] = slowReader.search(prefix: p, limit: 20)
    }

    // Now fast path
    try primeSidecar(path: path, sidecarDir: sidecarDir)
    MDictSidecarCache.cacheDirectory = sidecarDir
    let fastReader = try MDictReader(path: path)

    var mismatches = 0
    var total = 0
    for key in samples {
        total += 1
        let expected = slowResults[key]
        if let e = fastReader.lookup(key) {
            let actual = Snapshot(key: e.key, htmlLen: e.article.html.count, index: e.index)
            if expected != actual { mismatches += 1 }
        } else {
            if expected != nil { mismatches += 1 }
        }
    }
    for p in prefixes {
        total += 1
        let expected = slowPrefixResults[p] ?? []
        let actual = fastReader.search(prefix: p, limit: 20)
        if expected != actual { mismatches += 1 }
    }
    return (total, mismatches)
}

// MARK: - Report

func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / (1024 * 1024)
    if mb >= 1 { return String(format: "%.2f MB", mb) }
    let kb = Double(bytes) / 1024
    return String(format: "%.1f KB", kb)
}

func sidecarSize(forMDX path: String, sidecarDir: URL) -> Int64 {
    guard let sha = MDictReader.loadMetadata(from: path)?.headerSHA256 else { return 0 }
    let url = sidecarDir.appendingPathComponent("\(sha).idx", isDirectory: false)
    return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
}

func fileSize(_ path: String) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
}

func runOne(_ path: String, opts: BenchOptions, index: Int, total: Int) {
    let filename = URL(fileURLWithPath: path).lastPathComponent
    print()
    print(bold("[\(index + 1)/\(total)] \(filename)"))

    guard FileManager.default.fileExists(atPath: path) else {
        print(red("  skip: file not found"))
        return
    }

    let metadata = MDictReader.loadMetadata(from: path)
    let title = metadata?.title ?? filename
    let mdxSize = fileSize(path)
    print(dim("    \(title) — \(formatBytes(mdxSize))"))

    do {
        // Phase 0: optional verification
        if opts.verify {
            print(cyan("    Verifying fast-path correctness..."), terminator: "")
            let result = try verifyCorrectness(path: path, sidecarDir: opts.sidecarDir)
            if result.mismatches == 0 {
                print(green(" ✓ \(result.total)/\(result.total) match"))
            } else {
                print(red(" ✗ \(result.mismatches) mismatch(es) out of \(result.total)"))
            }
        }

        // Phase 1: cold init (slow path)
        print(cyan("    Measuring cold init..."), terminator: "")
        fflush(stdout)
        let coldStats = try measureCold(path: path, iterations: opts.iterations, sidecarDir: opts.sidecarDir)
        print(" done")
        print(String(format: "      cold init (slow):  %@", coldStats.line()))

        // Phase 2: warm init (fast path) — prime sidecar first
        print(cyan("    Priming sidecar + measuring warm init..."), terminator: "")
        fflush(stdout)
        try primeSidecar(path: path, sidecarDir: opts.sidecarDir)
        let warmStats = try measureWarm(path: path, iterations: opts.iterations, sidecarDir: opts.sidecarDir)
        print(" done")
        print(String(format: "      warm init (fast):  %@", warmStats.line()))

        // Speedup
        if warmStats.mean > 0 {
            let speedup = coldStats.mean / warmStats.mean
            print(String(format: "      %@ %.1fx", green("speedup:"), speedup))
        }

        // Phase 3: per-lookup latency (fast path reader)
        MDictSidecarCache.cacheDirectory = opts.sidecarDir
        let reader = try MDictReader(path: path)
        print(dim("    Entries: \(reader.entryCount), Resources: \(reader.resourceCount)"))
        let lookupStats = measureLookups(reader: reader, count: opts.lookupCount)
        print(String(format: "      lookup (random):   %@", lookupStats.line()))

        let prefixStats = measurePrefixSearch(reader: reader)
        print(String(format: "      prefix search:     %@", prefixStats.line()))

        // Sidecar size
        let sidecar = sidecarSize(forMDX: path, sidecarDir: opts.sidecarDir)
        let ratio = mdxSize > 0 ? Double(sidecar) / Double(mdxSize) * 100 : 0
        print(String(format: "      sidecar size:      %@ (%.1f%% of MDX)",
                     formatBytes(sidecar), ratio))
    } catch {
        print(red("    error: \(error)"))
    }
}

// MARK: - Main

let opts = parseArgs()

if opts.purge {
    try? FileManager.default.removeItem(at: opts.sidecarDir)
}
try? FileManager.default.createDirectory(at: opts.sidecarDir, withIntermediateDirectories: true)

print(bold("=== OpenMDict Sidecar Benchmark ==="))
print(dim("  iterations: \(opts.iterations)"))
print(dim("  lookups/mdx: \(opts.lookupCount)"))
print(dim("  sidecar dir: \(opts.sidecarDir.path)"))
if opts.verify { print(dim("  verify: enabled")) }

for (i, path) in opts.mdxPaths.enumerated() {
    runOne(path, opts: opts, index: i, total: opts.mdxPaths.count)
}

// Allow any pending background sidecar writes to flush before exit.
Thread.sleep(forTimeInterval: 1.0)
print()
