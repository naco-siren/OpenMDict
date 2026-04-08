# OpenMDict

A pure Swift library for parsing MDict dictionary files (.mdx/.mdd), with a companion iOS/iPadOS dictionary reader app.

## Library Features

- ✅ **MDX V2 (2.0)** - Full support with zlib decompression
- ✅ **MDX V1 (1.x)** - Full support with LZO decompression (official minilzo 2.10)
- ✅ **MDD Resources** - Images, audio, CSS, and other embedded files
- ✅ **Salted Dictionaries** - RIPEMD128 decryption for obfuscated dictionaries
- ✅ **Cross-platform** - macOS, iOS, iPadOS (Swift Package Manager)
- ⚡ **Persistent sidecar index** - Optional on-disk cache (`.idx`) that skips the full MDX decompress/parse pipeline on subsequent loads. 10–40× cold-start speedup on large dictionaries, with three-field invalidation (`fileSize` + `mtime` + `headerSHA256`) and atomic temp+rename writes. See [Persistent Sidecar Index](#persistent-sidecar-index) below.
- ⚡ **mmap-backed reader** - `BinaryReader` maps MDX/MDD files as `MAP_PRIVATE` + `PROT_READ` with `madvise(MADV_RANDOM)`. Lock-free concurrent reads; clean file-backed pages that iOS can evict for free under memory pressure instead of contributing to jetsam-critical dirty memory.

## iOS / iPadOS App

A full-featured MDict dictionary reader built with UIKit and Swift 6.

- **Article Layouts** — Three layout modes on iPadOS (Columns, Grid, List) for comparing definitions across dictionaries
- **Multi-Window & Shortcuts** — Full split-screen, multi-window, and keyboard shortcut support on iPadOS
- **Action Extension** — Look up words from any app via the share sheet
- **Smart Search** — Lemma resolution (NLTagger + inflection rules), Levenshtein-ranked suggestions, and device-adaptive search pipeline
- **Bookmarks & History** — Bookmark entries across dictionaries; lookup history with per-dictionary trophy counts
- **Unlimited Imports & Groups** — Import and manage MDX/MDD files as well as groups with no limits
- **iCloud Sync** — Dictionaries, bookmarks, lookup history, and groups sync across devices via CloudKit, with cross-device nuclear reset and built-in troubleshooting UI
- **Preset Dictionaries** — 65 curated open-source dictionaries (WordNet, JMdict, CC-CEDICT, Wiktionary, and more) for quick setup
- **13 Languages** — English, 简体中文, 繁體中文, Русский, Español, Deutsch, 日本語, Français, Português (BR), 한국어, Українська, العربية, हिन्दी

## Requirements

- Swift 6.0+
- macOS 12+ / iOS 15.6+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/naco-siren/OpenMDict.git", from: "0.1.0")
]
```

## Usage

### Basic Lookup

```swift
import OpenMDict

// Load dictionary
let dict = try MDictReader(path: "dictionary.mdx")

// Lookup a word
if let entry = dict.lookup("hello") {
    print(entry.article.html)
}

// Search by prefix
let words = dict.search(prefix: "hel", limit: 10)

// Access by index
if let first = dict[0] {
    print("\(first.key): \(first.article.html)")
}
```

### Dictionary Metadata

```swift
let dict = try MDictReader(path: "dictionary.mdx")

// `title` is Optional — some MDX files ship with placeholder titles
// (e.g. literally "Title (No HTML code allowed)"), which the parser
// resolves to nil so callers can fall back to the filename.
print("Title: \(dict.metadata.title ?? "(untitled)")")
print("Entries: \(dict.entryCount)")
print("Format: \(dict.metadata.format)")
print("Encoding: \(dict.metadata.encoding)")
```

### Resource Files (MDD)

```swift
// Resources are loaded automatically if .mdd file exists alongside .mdx
let dict = try MDictReader(path: "dictionary.mdx")

// Get CSS
if let css = dict.resourceString(for: "style.css") {
    print(css)
}

// Get image data
if let imageData = dict.resource(for: "logo.png") {
    // Use image data
}

// Check if resource exists
if dict.hasResource("sound.mp3") {
    // ...
}
```

### Static Metadata (Fast)

```swift
// Load only header info without parsing full dictionary
if let metadata = MDictReader.loadMetadata(from: "dictionary.mdx") {
    print("Title: \(metadata.title ?? "(untitled)")")
    print("Entries: \(metadata.entryCount ?? 0)")  // nil for header-only loads
}
```

## Persistent Sidecar Index

The sidecar index is an optional persistent cache that dramatically speeds
up cold-start dictionary loads. The first time a dictionary is opened, the
parser writes a binary `.idx` file containing the post-parse keyword
index + record-block table + sorted search index. On subsequent loads the
reader memory-maps the sidecar and skips the entire decompress / parse /
`calculateRecordInfo` pipeline, which is the actual bottleneck for large
dictionaries (~760 ms out of a 920 ms slow path on a 159k-entry dict).

### Enabling

The cache is **disabled by default**. Hosts opt in by setting a directory:

```swift
import OpenMDict

// Configure once at process startup, before any MDictReader is constructed.
MDictSidecarCache.cacheDirectory = URL(fileURLWithPath: "/path/to/cache")

// Normal reader construction — automatically uses the fast path on hit,
// falls back to the slow path on miss (and writes a fresh sidecar).
let dict = try MDictReader(path: "dictionary.mdx")
```

On iOS, the main app stores sidecars under
`AppGroup/Library/Caches/MDXIndex/` so they can be evicted by the system
under disk pressure, are not iCloud-backed up, and are shared with the
Action Extension.

### Write modes

`MDictSidecarCache.writeMode` controls when sidecars are *written*. Reads
are always enabled when `cacheDirectory` is set. Three mutually exclusive
modes:

```swift
public enum SidecarWriteMode: Sendable {
    /// Never write. Only reads work. Use for read-only processes (e.g.
    /// share-sheet extensions) so the main app stays the single source
    /// of truth for sidecar generation.
    case disabled

    /// Queue writes in an internal FIFO; the host must call
    /// `flushPendingWrites()` to drain. Use during bulk dictionary load
    /// so all CPU stays on parsing and user-perceived load time is
    /// minimised.
    case batched

    /// Dispatch each write on `DispatchQueue.global(qos: .utility)` as
    /// soon as the parser hands it over. Default — matches CLI / tests /
    /// benches and post-bulk-load host behaviour.
    case immediate
}
```

Typical iOS main-app lifecycle:

```swift
// At launch, before any MDictReader:
MDictSidecarCache.cacheDirectory = cacheURL
MDictSidecarCache.writeMode = .batched

// Bulk load — every slow-path sidecar write is queued, not dispatched.
for dict in dictsToLoad {
    try await dict.load()
}

// Bulk load done. Drain the queue onto the utility queue, then switch
// to .immediate so any later single-dict imports write straight away.
MDictSidecarCache.flushPendingWrites()
MDictSidecarCache.writeMode = .immediate
```

### Cleanup

```swift
// Drop the sidecar for a specific dictionary (e.g. when the user
// deletes it). dictId is typically the MDX header SHA256, which
// doubles as the sidecar filename.
MDictReader.removeSidecarCache(forHeaderSHA256: sha256)
```

### Invalidation

Each sidecar embeds a three-field identity in its header:
`(sourceFileSize, sourceMTimeNanos, sourceHeaderSHA256)`. Any mismatch
causes the loader to silently reject the sidecar and fall through to the
slow path (which then overwrites it). A corrupt sidecar (wrong magic bytes
or format version) is rejected the same way — corruption never causes a
crash or incorrect lookup results.

## Performance Profiling

The core lib emits `OSSignposter` intervals around the parser hot paths so
you can profile dictionary loading in Instruments without adding any
custom timing code. Always-on; `os_signpost` is essentially free when
nobody is collecting events.

**Subsystem**: `io.github.naco-siren.openmdict`
**Category**: `perf`

Three nested intervals:

| Name | Tag | Where | Notes |
|---|---|---|---|
| `MDXParser.init` | filename | core lib | Fires `MDXParser.path` event with payload `"fast"` or `"slow"` after the sidecar branch resolves. |
| `MDDParser.init` | filename | core lib | Same shape; tags resource files. |
| `DictionaryService.bulkLoad` | `count=N mode=parallel\|serial` | iOS app | Umbrella span for the initial bulk load. Per-dict parser intervals nest inside it. |

### Collecting from Instruments

1. Profile the iOS app in **Instruments**.
2. Pick the **Points of Interest** template (or *os_signpost*).
3. Filter the timeline by subsystem `io.github.naco-siren.openmdict`.

The bulk-load span shows up as a single bar with the per-dict parser
intervals nested as children. The `path` event lets you tell at a glance
whether each dict went through the fast or slow path.

### Collecting from a connected device via the command line

```bash
log stream --device --predicate 'subsystem == "io.github.naco-siren.openmdict"'
```

### Production aggregation via MetricKit (optional, opt-in)

The signposts are automatically picked up by `MXMetricManager` **if the
host app explicitly subscribes**. The data then flows back to App Store
Connect / Xcode Organizer's Metrics panel as anonymized aggregates from
real users on TestFlight / App Store builds — no server of your own
required. See Apple's
[`MetricKit` documentation](https://developer.apple.com/documentation/metrickit)
for the subscription boilerplate (`MXMetricManager.shared.add(subscriber)`).

### Privacy posture

`os_signpost` events emitted by this library are written to the device's
**local** unified log only. They are never transmitted off the device on
their own — local-only diagnostic instrumentation does not constitute
"data collection" for the purposes of the App Store privacy nutrition
label. An app that uses this library and does **not** subscribe to
`MXMetricManager` can still legitimately answer "Data Not Collected"
on App Store Connect.

If a host app **does** subscribe to MetricKit, the standard MetricKit
disclosure rules apply (typically "Diagnostics → Performance Data" and
"Diagnostics → Crash Data"); this library doesn't subscribe on its own,
so the choice is the host app's.

## CLI Tools

Two executables ship with the package: `openmdict` (general-purpose reader)
and `openmdict-bench` (performance benchmark).

### `openmdict` — reader

```bash
# Build
swift build -c release

# Dictionary info (default — no subcommand needed)
swift run openmdict dict.mdx

# Lookup a word
swift run openmdict dict.mdx lookup hello

# Prefix search
swift run openmdict dict.mdx search hel

# List first N entries
swift run openmdict dict.mdx list 20

# List / read MDD resources
swift run openmdict dict.mdx resources 10
swift run openmdict dict.mdx resource mydict.css

# Debug: raw header XML / per-key hex dump
swift run openmdict dict.mdx header
swift run openmdict dict.mdx debug hello
```

Set `OPENMDICT_SIDECAR_DIR` to enable the sidecar fast-path for normal
commands (useful for benchmarking warm vs cold init on the same dict):

```bash
OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache swift run openmdict dict.mdx lookup hello
```

### `openmdict` sidecar subcommands

Manage the persistent sidecar index cache directly from the CLI. All three
operations require `OPENMDICT_SIDECAR_DIR` to be set (except `list`, which
takes the cache directory as a positional argument).

```bash
# Show sidecar status for a dict (reports age, size, validity + MDD pair)
OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache swift run openmdict sidecar info MyDict.mdx

# Delete + rebuild a sidecar (e.g. after a suspected corruption)
OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache swift run openmdict sidecar rebuild MyDict.mdx

# Enumerate every .idx file in a cache directory with size + age + magic-byte check
swift run openmdict sidecar list /tmp/mdx-cache
```

### `openmdict-bench` — performance benchmark

Measure cold init / warm init / lookup latency / prefix search across one
or more dictionaries, with an optional `--verify` mode that compares fast-
path and slow-path lookup results for byte-equality.

```bash
# Build
swift build -c release --product openmdict-bench

# Single dict
swift run openmdict-bench path/to/dictionary.mdx

# Recursive scan, 5 iterations per phase, with verify
swift run openmdict-bench --dicts-dir dicts --purge --verify -n 5

# Options:
#   --dicts-dir PATH      Recursively scan for .mdx (repeatable)
#   --sidecar-dir PATH    Cache directory (default: /tmp/openmdict-bench-cache)
#   -n, --iterations N    Runs per phase (default: 5)
#   --lookups N           Random-key lookups per MDX (default: 200)
#   --purge               Clear the cache dir before starting
#   --verify              Compare fast-path vs slow-path lookup results
```

## Testing

The test suite covers the `MDXParser` / `MDDParser` facade APIs, the
`MDictReader` integration layer, and the sidecar index fast-path round-trip
(slow-path + fast-path must produce byte-equal lookup results, plus
invalidation and write-mode behaviour). An MDX file must be supplied via
the `MDICT_TEST_FILE` environment variable — tests are skipped without it.

```bash
# Full test suite against a real MDX
MDICT_TEST_FILE=path/to/dict.mdx swift test

# Only the sidecar round-trip suite (fast feedback loop when iterating on SidecarIndex.swift)
MDICT_TEST_FILE=path/to/dict.mdx swift test --filter SidecarRoundTripTests

# MDXParserTests supports a specific word + custom sample size
MDICT_TEST_FILE=path/to/dict.mdx MDICT_TEST_WORD=hello swift test --filter MDXParserTests
MDICT_TEST_FILE=path/to/dict.mdx MDICT_TEST_SAMPLE=10 swift test --filter MDXParserTests
```

## Project Structure

```
OpenMDict/
├── Sources/
│   ├── OpenMDict/                # Core library (pure Swift + CLZ)
│   │   ├── MDictReader.swift     # Public facade
│   │   ├── Parsers/
│   │   │   ├── MDXParser.swift
│   │   │   ├── MDDParser.swift
│   │   │   ├── MDictDescriptionParser.swift
│   │   │   └── ResourceProvider.swift
│   │   └── Utils/
│   │       ├── BinaryReader.swift    # mmap-backed random access
│   │       ├── SidecarIndex.swift    # Persistent index cache + write modes
│   │       ├── Decompressor.swift    # zlib + LZO
│   │       ├── HTMLEntityDecoder.swift
│   │       ├── Levenshtein.swift
│   │       └── RIPEMD128.swift
│   ├── OpenMDictKit/             # ViewModel layer for iOS/macOS hosts
│   └── CLZ/                      # LZO C library (minilzo 2.10)
├── Apps/
│   ├── CLI/                      # openmdict — general-purpose reader
│   ├── Bench/                    # openmdict-bench — sidecar A/B benchmark
│   └── iOS/                      # iOS/iPadOS app (UIKit, Swift 6)
├── Tests/
│   └── OpenMDictTests/
│       ├── MDictReaderTests.swift
│       ├── SidecarRoundTripTests.swift
│       └── Parsers/
└── Package.swift
```

## Format Support

| Format | Compression | Status |
|--------|-------------|--------|
| MDX V2 (2.0) | zlib | ✅ Full support |
| MDX V1 (1.x) | LZO | ✅ Full support |
| MDX V1 (1.x) | zlib | ✅ Supported |
| MDD V2 | zlib | ✅ Full support |
| MDD V1 | LZO/zlib | ✅ Supported |
| Salted (obfuscated) | - | ✅ Supported |

## License

MIT License

## Acknowledgments

- [minilzo](http://www.oberhumer.com/opensource/lzo/) - LZO compression library by Markus F.X.J. Oberhumer
- [readmdict](https://github.com/zhansliu/writemdict) - Python MDict reference implementation
