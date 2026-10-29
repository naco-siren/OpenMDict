# Performance: file access, sidecar index and profiling

How the `OpenMDict` library keeps dictionary loading fast, how a host app
configures it, and how to measure it.

- [Memory-mapped file access](#memory-mapped-file-access)
- [Persistent sidecar index](#persistent-sidecar-index)
- [Signposts and Instruments](#signposts-and-instruments)
- [Benchmarking with `openmdict-bench`](#benchmarking-with-openmdict-bench)

## Memory-mapped file access

`BinaryReader` (`Sources/OpenMDict/Utils/BinaryReader.swift`) maps each
`.mdx` / `.mdd` file read-only with `mmap` (`MAP_SHARED`, `PROT_READ`) and
`madvise(MADV_RANDOM)`, so a read is a memory copy from the mapping, with
no system call or lock. The pages are clean and file-backed: iOS can evict
them under memory pressure, and they do not count toward the app's dirty
memory footprint.

If `mmap` fails (iOS can refuse to map a file of 1 GB or more), the reader
falls back to a `FileHandle` guarded by an `NSLock`. That path is slower and
serializes reads, but the dictionary and its resources stay usable.

## Persistent sidecar index

Opening a large dictionary is dominated by decompressing and parsing the
key blocks and building the record-block table. The sidecar index stores the
result of that work in a binary `.idx` file: the keyword index, the
record-block table and the sorted search index. When a valid sidecar exists,
the reader maps it and skips the parse.

### Enabling

The cache is off by default. Set a directory once at process start, before
the first `MDictReader` is created:

```swift
import OpenMDict

let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
MDictSidecarCache.cacheDirectory = caches.appendingPathComponent("MDXIndex")

let dict = try MDictReader(path: "dictionary.mdx")  // fast path on a hit;
                                                     // parses and writes a sidecar on a miss
```

The directory is created on the first write. Reads are always enabled while
`cacheDirectory` is set. Each MDX and MDD file gets its own sidecar, named
`<headerSHA256>.idx` after the SHA-256 of the file's header bytes (for an MDX,
`metadata.headerSHA256`).

A caches directory suits the files: the system may evict them and the parser
rebuilds them on the next open. The iOS app uses
`<App Group container>/Library/Caches/MDXIndex/`, which the Action Extension
reads as well.

### Write modes

`MDictSidecarCache.writeMode` decides when a sidecar is written after a
slow-path parse:

| Mode | Behavior | Use for |
|---|---|---|
| `.immediate` (default) | Each write is dispatched to `DispatchQueue.global(qos: .utility)` as soon as the parse finishes. | CLIs, tests, benchmarks; an app after its initial load |
| `.batched` | Writes are queued and run only when `MDictSidecarCache.flushPendingWrites()` is called. | An app's initial bulk load, so that the CPU stays on parsing |
| `.disabled` | Nothing is written; existing sidecars are still read. | Extensions and other short-lived processes, so that one process owns sidecar generation |

A typical app launch:

```swift
MDictSidecarCache.cacheDirectory = cacheURL
MDictSidecarCache.writeMode = .batched

// ... open every dictionary ...

MDictSidecarCache.flushPendingWrites()       // dispatch the queued writes
MDictSidecarCache.writeMode = .immediate     // later imports write straight away
```

`cacheDirectory` and `writeMode` are meant to be set at launch and then only
read; do not change them from several threads at once.

### Folded-key index

Diacritic-insensitive lookups ("cafe" finding "café") use a second index of
folded keys. A reader builds it on first use and saves it beside the
sidecar as `<headerSHA256>.fold`, the way sidecar writes are made (unless
`writeMode` is `.disabled`), so later processes read it instead of building
it. `dict.saveFoldedKeyIndexIfNeeded()` saves it without keeping it in
memory, and `dict.prepareFoldedKeyIndex()` builds it ahead of time. Set
`MDictSidecarCache.buildsFoldedKeyIndexes = false` in a short-lived process
to read saved copies only and skip diacritic-insensitive matching for
dictionaries without one.

### Removing a dictionary's cache

```swift
if let sha = dict.metadata.headerSHA256 {
    MDictReader.removeSidecarCache(forHeaderSHA256: sha)
}
```

This deletes the `.idx` file and the `.fold` file beside it. It does nothing
when no cache directory is set or no file exists. The sidecar of an MDD file
is keyed by that file's own header SHA-256; for an MDD file, pass
`MDictReader.loadMetadata(from: mddPath)?.headerSHA256`. From the command
line, `openmdict sidecar info` shows the full value for the MDX and its
same-name `.mdd` as the name of the `.idx` file in its `file:` or
`expected at:` line.

### Validation

Each sidecar header records the source file's size, its modification time
(nanoseconds) and its header SHA-256. On load the reader checks the magic
bytes (`MDIX`), the format version, these three fields and the section
bounds. On any mismatch it ignores the sidecar, parses the source file and
writes a new one. The payload carries no checksum, so damage inside it that
leaves the header and section sizes intact is not detected. Writes go to a
temporary file that is then moved into place, so an interrupted write never
leaves a partial sidecar.

The full on-disk layout is documented in
`Sources/OpenMDict/Utils/SidecarIndex.swift`.

### CLI support

The `openmdict <mdx> ...` commands use the cache when
`OPENMDICT_SIDECAR_DIR` is set, and the `sidecar info | rebuild | list`
subcommands inspect and manage cache files; see
[Command-line tools](cli.md#sidecar-cache).

## Signposts and Instruments

The library emits `OSSignposter` intervals around parser initialization.
They are always on; an `os_signpost` call costs almost nothing when no tool
is recording.

- Subsystem: `io.github.naco-siren.openmdict`
- Category: `perf`

| Interval | Emitted by | Message |
|---|---|---|
| `MDXParser.init` | library | File name. A `MDXParser.path` event inside it carries `fast` (sidecar hit) or `slow` (full parse). |
| `MDDParser.init` | library | File name, with a `MDDParser.path` event of the same form. |
| `DictionaryService.bulkLoad` | iOS app | `count=N mode=parallel` or `mode=serial`; spans the initial load, with the per-dictionary parser intervals inside it. |

The iOS app logs further intervals (for example the `ai.*` intervals of the
AI Coach) under the same subsystem and category.

To record them, profile the app (or a CLI process) in Instruments, add the
**os_signpost** instrument to the trace, and filter by the subsystem. The
`perf` category does not appear in the Points of Interest instrument, which
shows only signposts in the `PointsOfInterest` category.

Signposts are written to the device's unified log only. The library does not
use MetricKit or send any data off the device.

## Benchmarking with `openmdict-bench`

`openmdict-bench` measures cold initialization (full parse), warm
initialization (sidecar), random-key lookups and prefix searches for one or
more dictionaries. Run it from a release build:

```bash
swift run -c release openmdict-bench path/to/dictionary.mdx
swift run -c release openmdict-bench --dicts-dir dicts --purge --verify -n 5
```

| Option | Meaning |
|---|---|
| `--dicts-dir PATH` | Scan `PATH` recursively for `.mdx` files (repeatable) |
| `--sidecar-dir PATH` | Cache directory (default `/tmp/openmdict-bench-cache`) |
| `-n`, `--iterations N` | Runs per phase (default 5) |
| `--lookups N` | Random-key lookups per dictionary (default 200) |
| `--purge` | Empty the cache directory first |
| `--verify` | Check that fast-path and slow-path lookups return identical results |
| `--fallbacks` | Measure only the lookup fallbacks (folded-key index build time and memory, fallback lookup latency) |
| `-h`, `--help` | Show the built-in help |

Example: two preset dictionaries, release build on an Intel Core i7-10700K
Mac, three iterations per phase, mean times.

| Dictionary | Size | Keys | Cold init (parse) | Warm init (sidecar) |
|---|---|---|---|---|
| FreeDict German–English | 59.5 MiB | 421,991 | 2,115 ms | 48 ms |
| JMdict Japanese–English | 38.6 MiB | 583,434 | 1,736 ms | 64 ms |

Timings depend on the machine and the dictionary; measure your own files.
