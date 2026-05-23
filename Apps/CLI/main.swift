import Foundation
import OpenMDict

// MARK: - Output Format

/// Output style for commands that produce content.  Banners, dict info, and
/// other decoration are suppressed for non-`pretty` formats so the stdout
/// stream contains nothing but the requested payload — pipe-friendly.
enum OutputFormat: String {
    case pretty   // human-readable with colors / emojis (default)
    case raw      // plain content (e.g. raw HTML) straight to stdout
    case json     // single JSON document to stdout
}

/// stderr printer.  Errors and diagnostics belong here, never on stdout —
/// otherwise a `... --format=json | jq` pipe gets garbage prepended.
func eprintln(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// Strip the `--format=<value>`, `--format <value>`, or `-f <value>` flag
/// from the args array (mutating) so positional indexing in the rest of
/// `main()` stays unchanged.  Exits with an error on unknown / missing value.
func consumeFormatFlag(_ args: inout [String]) -> OutputFormat {
    var format: OutputFormat = .pretty
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--format" || arg == "-f" {
            guard i + 1 < args.count else {
                eprintln("Error: --format requires a value (pretty|raw|json)")
                exit(1)
            }
            guard let f = OutputFormat(rawValue: args[i + 1]) else {
                eprintln("Error: unknown format '\(args[i + 1])' (expected pretty|raw|json)")
                exit(1)
            }
            format = f
            args.removeSubrange(i...(i + 1))
            continue
        }
        if arg.hasPrefix("--format=") {
            let value = String(arg.dropFirst("--format=".count))
            guard let f = OutputFormat(rawValue: value) else {
                eprintln("Error: unknown format '\(value)' (expected pretty|raw|json)")
                exit(1)
            }
            format = f
            args.remove(at: i)
            continue
        }
        i += 1
    }
    return format
}

// MARK: - Terminal Colors

enum ANSIColor: String {
    case reset = "\u{001B}[0m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case bold = "\u{001B}[1m"
    case dim = "\u{001B}[2m"
}

func colored(_ text: String, _ color: ANSIColor) -> String {
    "\(color.rawValue)\(text)\(ANSIColor.reset.rawValue)"
}

// MARK: - Main

func printUsage() {
    print("""

    \(colored("OpenMDict", .bold)) - MDict MDX/MDD Parser

    \(colored("Usage:", .yellow))
        openmdict <mdx_file>                        Show dictionary info
        openmdict <mdx_file> lookup <word>          Look up a word
        openmdict <mdx_file> search <prefix>        Search by prefix
        openmdict <mdx_file> list [count]           List first N entries
        openmdict <mdx_file> resources [count]      List resources from MDD
        openmdict <mdx_file> resource <path>        Get a specific resource

    \(colored("Output Format (--format / -f):", .yellow))
        --format=pretty   Human-readable (default; colors, emojis, truncated).
        --format=raw      Plain content to stdout — for `lookup`, full HTML.
                          Banner / dict info suppressed.  Pipe-friendly.
        --format=json     Single JSON document to stdout — includes parsed
                          cross-refs (with #fragment), audio, image, and
                          weblink references.  Pipe-friendly.

    \(colored("Debug Commands:", .yellow))
        openmdict <mdx_file> header                 Show raw header XML
        openmdict <mdx_file> describe               Parse description (test extraction)
        openmdict <mdx_file> debug <word>           Debug key lookup (hex bytes)

    \(colored("Experimental (M15 — semantic search probe):", .yellow))
        openmdict <mdx_file> semantic <word> [--lang en] [--limit 10] [--scope both]
            Print top-K semantically similar words via NLEmbedding.
            --scope all  = NLEmbedding vocab-wide top-K
            --scope dict = top-K restricted to this MDX's keywords
            --scope both = both (default)

    \(colored("Sidecar Index Commands:", .yellow))
        openmdict sidecar info <mdx_file>           Show sidecar status for a dictionary
        openmdict sidecar rebuild <mdx_file>        Force rebuild the sidecar (delete + reload)
        openmdict sidecar list <cache_dir>          List all .idx files in a sidecar cache directory

    \(colored("Environment:", .yellow))
        OPENMDICT_SIDECAR_DIR   Enable sidecar fast-path for normal commands.
                                Required for sidecar info/rebuild to locate existing cache.

    \(colored("Examples:", .yellow))
        openmdict MyDict.mdx
        openmdict MyDict.mdx lookup hello
        openmdict MyDict.mdx lookup hello --format=raw  > hello.html
        openmdict MyDict.mdx lookup hello --format=json | jq '.links[] | select(.type == "entry")'
        openmdict MyDict.mdx search happ
        openmdict MyDict.mdx list 20
        openmdict MyDict.mdx resources 10
        openmdict MyDict.mdx resource mydict.css
        openmdict MyDict.mdx header
        openmdict MyDict.mdx describe

        OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache openmdict sidecar info MyDict.mdx
        OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache openmdict sidecar rebuild MyDict.mdx
        openmdict sidecar list /tmp/mdx-cache

    """)
}

func main() {
    var args = CommandLine.arguments

    // Pull `--format=...` out first so the positional indexing below
    // (args[1] = mdx path, args[2] = subcommand, ...) stays clean.
    let format = consumeFormatFlag(&args)

    guard args.count >= 2 else {
        printUsage()
        exit(1)
    }

    // Top-level sidecar subcommand branch:
    // `openmdict sidecar <subcommand> <arg>` bypasses the
    // `openmdict <mdx_file> [command]` form because "list" takes a
    // directory argument instead of an MDX file, and "info"/"rebuild"
    // should print diagnostic output rather than loading the full dict.
    if args[1] == "sidecar" {
        guard args.count >= 4 else {
            eprintln(colored("Error: Missing arguments for sidecar command", .red))
            eprintln("  openmdict sidecar info <mdx_file>")
            eprintln("  openmdict sidecar rebuild <mdx_file>")
            eprintln("  openmdict sidecar list <cache_dir>")
            exit(1)
        }
        handleSidecarSubcommand(subcommand: args[2], arg: args[3])
        exit(0)
    }

    let mdxPath = args[1]

    guard FileManager.default.fileExists(atPath: mdxPath) else {
        eprintln(colored("Error: File not found: \(mdxPath)", .red))
        exit(1)
    }

    // Optional: enable persistent sidecar index cache via env var
    // (export OPENMDICT_SIDECAR_DIR=/some/dir before running). The cache
    // dramatically speeds up cold-load of large dictionaries by skipping
    // the decompress/parse/calculate pipeline on subsequent launches.
    if let envDir = ProcessInfo.processInfo.environment["OPENMDICT_SIDECAR_DIR"] {
        let dirURL = URL(fileURLWithPath: envDir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        MDictSidecarCache.cacheDirectory = dirURL
    }

    if format == .pretty {
        print()
        print(colored("📖 Opening:", .cyan), mdxPath)
        print()
    }

    let startTime = CFAbsoluteTimeGetCurrent()

    do {
        let dict = try MDictReader(path: mdxPath)
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime

        if format == .pretty {
            // Dictionary info — only in pretty mode; raw/json should emit
            // nothing but the requested content so stdout is pipe-friendly.
            print(colored("Dictionary Info:", .bold))
            print("  Title:          ", dict.metadata.title ?? "(no title)")
            print("  Entries:        ", colored("\(dict.entryCount)", .green))
            print("  Format:         ", dict.metadata.format)
            print("  Encoding:       ", dict.metadata.encoding)
            print("  Engine Version: ", dict.metadata.engineVersion)
            print("  Encrypted:      ", dict.metadata.isEncrypted ? colored("Yes", .yellow) : colored("No", .green))
            print("  Case Sensitive: ", dict.metadata.isCaseSensitive ? "Yes" : "No")
            if !dict.metadata.creationDate.isEmpty {
                print("  Created:        ", dict.metadata.creationDate)
            }
            if !dict.metadata.description.isEmpty {
                let cleanDesc = cleanDescription(dict.metadata.description)
                let truncated = cleanDesc.count > 100 ? String(cleanDesc.prefix(100)) + "..." : cleanDesc
                print("  Description:    ", colored(truncated, .dim))
            }
            print()

            // Resource info
            print(colored("Resource Info:", .bold))
            if dict.resourceCount > 0 {
                print("  MDD Resources:  ", colored("\(dict.resourceCount)", .green))

                // Show resource types summary
                let paths = dict.allResourcePaths
                let extensions = Dictionary(grouping: paths) { path in
                    (path as NSString).pathExtension.lowercased()
                }.mapValues { $0.count }

                let summary = extensions.sorted { $0.value > $1.value }
                    .prefix(5)
                    .map { "\($0.key.isEmpty ? "other" : $0.key): \($0.value)" }
                    .joined(separator: ", ")
                print("  Types:          ", colored(summary, .dim))
            } else {
                print("  MDD Resources:  ", colored("None (no .mdd file found)", .yellow))
            }
            print()

            print("  Load Time:      ", colored(String(format: "%.2f ms", loadTime * 1000), .yellow))
            print()
        }

        if args.count >= 3 {
            let command = args[2].lowercased()

            switch command {
            case "lookup":
                guard args.count >= 4 else {
                    eprintln(colored("Error: Missing word for lookup", .red))
                    exit(1)
                }
                performLookup(dict: dict, mdxPath: mdxPath, word: args[3], format: format)

            case "search":
                guard args.count >= 4 else {
                    eprintln(colored("Error: Missing prefix for search", .red))
                    exit(1)
                }
                performSearch(dict: dict, prefix: args[3])

            case "list":
                let count = args.count >= 4 ? Int(args[3]) ?? 20 : 20
                listEntries(dict: dict, count: count)

            case "resources":
                let count = args.count >= 4 ? Int(args[3]) ?? 20 : 20
                listResources(dict: dict, count: count)

            case "resource":
                guard args.count >= 4 else {
                    eprintln(colored("Error: Missing resource path", .red))
                    exit(1)
                }
                getResource(dict: dict, path: args[3])

            case "debug":
                guard args.count >= 4 else {
                    eprintln(colored("Error: Missing prefix for debug", .red))
                    exit(1)
                }
                debugKey(dict: dict, prefix: args[3])

            case "header":
                debugHeader(path: mdxPath)

            case "describe":
                debugDescribe(dict: dict)

            case "semantic":
                // Pass ["semantic", word, ...flags] so the handler can parse positionally.
                handleSemanticSubcommand(dict: dict, args: Array(args.dropFirst(2)))

            default:
                eprintln(colored("Unknown command: \(command)", .red))
                if format == .pretty { printUsage() }
                exit(1)
            }
        } else if format == .pretty {
            // Default: show sample entries
            print(colored("First 10 entries:", .bold))
            for (i, entry) in dict.allKeys.prefix(10).enumerated() {
                print("  \(i + 1). \(entry)")
            }
            print()
            print(colored("Tip:", .yellow), "Use 'lookup <word>' to look up a word")
        }

    } catch {
        eprintln(colored("Error: \(error)", .red))
        exit(1)
    }
}

// MARK: - Commands

func performLookup(dict: MDictReader, mdxPath: String, word: String, format: OutputFormat) {
    switch format {
    case .pretty:
        performLookupPretty(dict: dict, word: word)
    case .raw:
        performLookupRaw(dict: dict, word: word)
    case .json:
        performLookupJSON(dict: dict, mdxPath: mdxPath, word: word)
    }
}

func performLookupPretty(dict: MDictReader, word: String) {
    print(colored("🔍 Looking up:", .cyan), word)
    print()

    let startTime = CFAbsoluteTimeGetCurrent()

    if let entry = dict.lookup(word) {
        let lookupTime = CFAbsoluteTimeGetCurrent() - startTime
        let content = entry.article.html

        // Extract referenced resources from HTML
        let resourceRefs = extractResourceRefs(from: content)

        let displayContent = content.count > 2000
            ? String(content.prefix(2000)) + "\n... [truncated, \(content.count) chars total — re-run with --format=raw or --format=json for full HTML]"
            : content

        print(colored("Result:", .green))
        print(String(repeating: "─", count: 60))
        print(displayContent)
        print(String(repeating: "─", count: 60))
        print()

        // Show navigation
        print(colored("Navigation:", .bold))
        if entry.index > 0, let prev = dict[entry.index - 1] {
            print("  ← Previous: ", colored(prev.key, .cyan))
        }
        if let next = dict[entry.index + 1] {
            print("  → Next:     ", colored(next.key, .cyan))
        }
        print()

        // Show referenced resources by type
        if !resourceRefs.isEmpty {
            showResourceRefs(refs: resourceRefs, dict: dict)
        }

        print(colored("✓", .green), "Found in", colored(String(format: "%.2f ms", lookupTime * 1000), .yellow))
    } else {
        print(colored("✗ Not found:", .red), word)

        let suggestions = dict.suggestions(for: word, limit: 5)
        if !suggestions.isEmpty {
            print()
            print(colored("Did you mean:", .yellow))
            for s in suggestions { print("  • \(s.word) (distance: \(s.distance))") }
        }
    }
    print()
}

/// Plain-HTML mode.  Stdout = the raw untruncated HTML.  Nothing else.
/// Not-found goes to stderr + exit 1 so shell scripts can short-circuit.
func performLookupRaw(dict: MDictReader, word: String) {
    guard let entry = dict.lookup(word) else {
        eprintln("Not found: \(word)")
        exit(1)
    }
    print(entry.article.html)
}

/// Structured JSON mode.  Always exits 0 with a JSON document on stdout —
/// the `found` field tells consumers whether to look at `entry` or
/// `suggestions`.  Pipe to `jq` or any other JSON tool.
func performLookupJSON(dict: MDictReader, mdxPath: String, word: String) {
    let startTime = CFAbsoluteTimeGetCurrent()
    let entry = dict.lookup(word)
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

    let response = buildLookupResponse(
        dict: dict,
        mdxPath: mdxPath,
        word: word,
        entry: entry,
        lookupTimeMs: elapsedMs
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(response)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        eprintln("Error: JSON encoding failed: \(error)")
        exit(1)
    }
}

func performSearch(dict: MDictReader, prefix: String) {
    print(colored("🔎 Searching prefix:", .cyan), prefix)
    print()
    
    let startTime = CFAbsoluteTimeGetCurrent()
    let results = dict.search(prefix: prefix, limit: 20)
    let searchTime = CFAbsoluteTimeGetCurrent() - startTime
    
    if results.isEmpty {
        print(colored("No matches found", .yellow))
    } else {
        print(colored("Matches (\(results.count)):", .green))
        for (i, result) in results.enumerated() {
            print("  \(i + 1). \(result)")
        }
    }
    
    print()
    print(colored("✓", .green), "Search completed in", colored(String(format: "%.2f ms", searchTime * 1000), .yellow))
    print()
}

func debugKey(dict: MDictReader, prefix: String) {
    print(colored("🔬 Debug key:", .cyan), prefix)
    print()
    
    let results = dict.search(prefix: prefix, limit: 5)
    if results.isEmpty {
        print(colored("No matches found", .yellow))
        return
    }
    
    for result in results {
        print("Key: \"\(result)\"")
        print("  Length: \(result.count) characters")
        print("  UTF-8 bytes: \(result.utf8.count)")
        print("  Hex dump: ", terminator: "")
        for byte in result.utf8 {
            print(String(format: "%02X ", byte), terminator: "")
        }
        print()
        
        // Show any non-printable characters
        var nonPrintable: [(Int, UInt8)] = []
        for (i, byte) in result.utf8.enumerated() {
            if byte < 32 || byte > 126 {
                nonPrintable.append((i, byte))
            }
        }
        if !nonPrintable.isEmpty {
            print(colored("  ⚠️ Non-printable bytes:", .yellow))
            for (pos, byte) in nonPrintable {
                print("    Position \(pos): 0x\(String(format: "%02X", byte)) (\(byte))")
            }
        }
        print()
    }
}

func debugHeader(path: String) {
    print(colored("🔬 Debug header:", .cyan), path)
    print()
    
    guard let (encoding, xml) = MDictReader.readRawHeader(from: path) else {
        print(colored("Error: Cannot read header", .red))
        return
    }
    
    print("Encoding: \(encoding)")
    print()
    print(colored("Raw header XML:", .yellow))
    print(xml)
    print()
}

func listEntries(dict: MDictReader, count: Int) {
    print(colored("📝 First \(count) entries:", .bold))
    print()
    
    for (i, entry) in dict.allKeys.prefix(count).enumerated() {
        print("  \(String(format: "%4d", i + 1)). \(entry)")
    }
    print()
}

func listResources(dict: MDictReader, count: Int) {
    print(colored("📦 Resources:", .bold))
    print()
    
    let paths = dict.allResourcePaths
    
    if paths.isEmpty {
        print(colored("  No MDD resources found", .yellow))
        print()
        return
    }
    
    for (i, path) in paths.prefix(count).enumerated() {
        let ext = (path as NSString).pathExtension.lowercased()
        let icon: String
        switch ext {
        case "css": icon = "🎨"
        case "js": icon = "📜"
        case "png", "jpg", "jpeg", "gif", "svg": icon = "🖼️"
        case "mp3", "wav", "ogg", "spx": icon = "🔊"
        case "ttf", "otf", "woff", "woff2": icon = "🔤"
        default: icon = "📄"
        }
        print("  \(String(format: "%4d", i + 1)). \(icon) \(path)")
    }
    
    if paths.count > count {
        print()
        print(colored("  ... and \(paths.count - count) more resources", .dim))
    }
    print()
}

func getResource(dict: MDictReader, path: String) {
    print(colored("📦 Resource:", .cyan), path)
    print()
    
    guard let data = dict.resource(for: path) else {
        print(colored("✗ Resource not found:", .red), path)
        print()
        
        // Try to find similar resources
        let similar = dict.allResourcePaths.filter {
            $0.lowercased().contains(path.lowercased())
        }.prefix(5)
        
        if !similar.isEmpty {
            print(colored("Similar resources:", .yellow))
            for s in similar { print("  • \(s)") }
        }
        print()
        return
    }
    
    let ext = (path as NSString).pathExtension.lowercased()
    let mime = ResourceProvider.mimeType(for: path)
    
    print(colored("Info:", .bold))
    print("  Size:      ", colored("\(data.count) bytes", .green))
    print("  MIME Type: ", mime)
    print()
    
    // Show content preview for text types
    let textTypes = ["css", "js", "html", "htm", "xml", "json", "txt", "svg"]
    if textTypes.contains(ext) {
        if let content = String(data: data, encoding: .utf8) {
            let preview = content.count > 1000
                ? String(content.prefix(1000)) + "\n... [truncated]"
                : content
            
            print(colored("Content Preview:", .bold))
            print(String(repeating: "─", count: 60))
            print(preview)
            print(String(repeating: "─", count: 60))
        }
    } else {
        // Show hex dump for binary
        print(colored("Hex Preview (first 64 bytes):", .bold))
        let hexBytes = data.prefix(64).map { String(format: "%02X", $0) }
        for row in stride(from: 0, to: hexBytes.count, by: 16) {
            let slice = hexBytes[row..<min(row + 16, hexBytes.count)]
            print("  \(slice.joined(separator: " "))")
        }
    }
    print()
}

// MARK: - Sidecar Subcommands

/// Entry point for `openmdict sidecar <info|rebuild|list> <arg>`.
func handleSidecarSubcommand(subcommand: String, arg: String) {
    switch subcommand {
    case "info":
        sidecarInfo(mdxPath: arg)
    case "rebuild":
        sidecarRebuild(mdxPath: arg)
    case "list":
        sidecarList(cacheDir: arg)
    default:
        print(colored("Unknown sidecar subcommand: \(subcommand)", .red))
        print("  Valid subcommands: info, rebuild, list")
        exit(1)
    }
}

/// Resolve the effective sidecar cache directory for info/rebuild operations.
/// Reads `OPENMDICT_SIDECAR_DIR` env var. Returns nil + prints an error if unset.
private func resolveSidecarCacheDir() -> URL? {
    guard let envDir = ProcessInfo.processInfo.environment["OPENMDICT_SIDECAR_DIR"] else {
        print(colored("Error: OPENMDICT_SIDECAR_DIR environment variable is not set.", .red))
        print("  Example: OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache openmdict sidecar info MyDict.mdx")
        return nil
    }
    let url = URL(fileURLWithPath: envDir)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Format bytes as KB / MB for display.
private func formatByteSize(_ bytes: Int64) -> String {
    if bytes >= 1024 * 1024 {
        return String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
    }
    if bytes >= 1024 {
        return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }
    return "\(bytes) B"
}

/// `openmdict sidecar info <mdx_file>` — report whether a sidecar exists
/// for the given MDX, how old it is, how big it is, and whether its
/// three-field identity (fileSize + mtime + headerSHA256) matches the
/// current MDX. Also prints the same info for any paired .mdd files.
func sidecarInfo(mdxPath: String) {
    guard FileManager.default.fileExists(atPath: mdxPath) else {
        print(colored("Error: File not found: \(mdxPath)", .red))
        exit(1)
    }
    guard let cacheDir = resolveSidecarCacheDir() else { exit(1) }

    // Report MDX + any paired MDD in the same directory.
    let mdxURL = URL(fileURLWithPath: mdxPath)
    let base = mdxURL.deletingPathExtension().lastPathComponent
    let parent = mdxURL.deletingLastPathComponent()
    var targets: [(label: String, path: String)] = [("MDX", mdxPath)]
    if let siblings = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
        for s in siblings where s.pathExtension.lowercased() == "mdd"
            && s.deletingPathExtension().lastPathComponent == base {
            targets.append(("MDD", s.path))
        }
    }

    print()
    print(colored("📇 Sidecar info", .bold))
    print(colored("  cache dir:", .dim), cacheDir.path)
    print()

    for target in targets {
        print(colored("\(target.label): \(target.path)", .cyan))
        guard let meta = MDictReader.loadMetadata(from: target.path),
              let sha = meta.headerSHA256 else {
            print(colored("  ✗ Could not read header (unsupported encryption?)", .red))
            print()
            continue
        }
        print("  header sha256: \(sha.prefix(32))…")

        let sidecarURL = cacheDir.appendingPathComponent("\(sha).idx", isDirectory: false)
        let sidecarPath = sidecarURL.path

        guard FileManager.default.fileExists(atPath: sidecarPath) else {
            print(colored("  ✗ No sidecar on disk", .yellow))
            print("    expected at: \(sidecarPath)")
            print()
            continue
        }

        // File size + mtime
        let attrs = (try? FileManager.default.attributesOfItem(atPath: sidecarPath)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date
        let ageString: String = {
            guard let mtime else { return "?" }
            let interval = Date().timeIntervalSince(mtime)
            if interval < 60 { return String(format: "%.0fs", interval) }
            if interval < 3600 { return String(format: "%.0fm", interval / 60) }
            if interval < 86400 { return String(format: "%.1fh", interval / 3600) }
            return String(format: "%.1fd", interval / 86400)
        }()

        print(colored("  ✓ Sidecar present", .green))
        print("    file:  \(sidecarPath)")
        print("    size:  \(formatByteSize(size))")
        print("    age:   \(ageString) (modified \(mtime.map { "\($0)" } ?? "?"))")

        // Validate by actually asking the loader to accept it — this runs
        // the full three-field identity check exactly as the parser would.
        MDictSidecarCache.cacheDirectory = cacheDir
        MDictSidecarCache.writeMode = .disabled  // don't rewrite on parse
        let before = Date()
        do {
            _ = try MDictReader(path: target.path)
            let ms = Date().timeIntervalSince(before) * 1000
            print(colored("    valid: ✓ (reader init succeeded in \(String(format: "%.1f", ms)) ms)", .green))
        } catch {
            print(colored("    valid: ✗ \(error)", .red))
        }
        MDictSidecarCache.cacheDirectory = nil  // reset for next iteration
        print()
    }
}

/// `openmdict sidecar rebuild <mdx_file>` — delete the existing sidecar
/// (if any) and construct a fresh `MDictReader`, triggering the slow path
/// and writing a new sidecar. Waits for the background write to flush.
func sidecarRebuild(mdxPath: String) {
    guard FileManager.default.fileExists(atPath: mdxPath) else {
        print(colored("Error: File not found: \(mdxPath)", .red))
        exit(1)
    }
    guard let cacheDir = resolveSidecarCacheDir() else { exit(1) }

    guard let meta = MDictReader.loadMetadata(from: mdxPath),
          let sha = meta.headerSHA256 else {
        print(colored("Error: Could not compute header SHA256", .red))
        exit(1)
    }

    let sidecarURL = cacheDir.appendingPathComponent("\(sha).idx", isDirectory: false)

    print()
    print(colored("🔨 Rebuilding sidecar for", .cyan), mdxPath)
    print(colored("  target:", .dim), sidecarURL.path)

    // Delete existing
    if FileManager.default.fileExists(atPath: sidecarURL.path) {
        try? FileManager.default.removeItem(at: sidecarURL)
        print(colored("  deleted existing sidecar", .dim))
    }

    // Slow-path parse with immediate write
    MDictSidecarCache.cacheDirectory = cacheDir
    MDictSidecarCache.writeMode = .immediate
    let before = Date()
    do {
        let reader = try MDictReader(path: mdxPath)
        let parseMs = Date().timeIntervalSince(before) * 1000
        print("  parsed \(reader.entryCount) entries in \(String(format: "%.1f", parseMs)) ms")
    } catch {
        print(colored("Error during parse: \(error)", .red))
        exit(1)
    }

    // Wait for the background write to flush
    print(colored("  waiting for background sidecar write …", .dim))
    Thread.sleep(forTimeInterval: 2.0)

    // Confirm
    if FileManager.default.fileExists(atPath: sidecarURL.path) {
        let size = (try? FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? Int64) ?? 0
        print(colored("  ✓ sidecar written", .green), "(\(formatByteSize(size)))")
    } else {
        print(colored("  ✗ sidecar did NOT appear on disk (write may have failed)", .red))
    }
    print()
}

/// `openmdict sidecar list <cache_dir>` — enumerate all `.idx` files in a
/// sidecar cache directory with size + age. Distinguishes valid sidecars
/// (magic + format version OK) from orphaned / corrupt files.
func sidecarList(cacheDir: String) {
    let url = URL(fileURLWithPath: cacheDir)
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
    ) else {
        print(colored("Error: Could not read directory: \(cacheDir)", .red))
        exit(1)
    }

    let idxFiles = files.filter { $0.pathExtension == "idx" }.sorted {
        $0.lastPathComponent < $1.lastPathComponent
    }
    let tmpFiles = files.filter { $0.lastPathComponent.contains(".tmp-") }

    print()
    print(colored("📇 Sidecar index files in", .bold), cacheDir)
    print()

    if idxFiles.isEmpty && tmpFiles.isEmpty {
        print(colored("  (empty)", .dim))
        print()
        return
    }

    var totalBytes: Int64 = 0
    var validCount = 0
    var invalidCount = 0

    for f in idxFiles {
        let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(vals?.fileSize ?? 0)
        totalBytes += size
        let mtime = vals?.contentModificationDate
        let ageString: String = {
            guard let mtime else { return "?" }
            let interval = Date().timeIntervalSince(mtime)
            if interval < 3600 { return String(format: "%.0fm ago", interval / 60) }
            if interval < 86400 { return String(format: "%.1fh ago", interval / 3600) }
            return String(format: "%.1fd ago", interval / 86400)
        }()

        // Quick magic-byte check — we don't have the source MDX here so
        // we can't validate the 3-field identity, only the format magic.
        let isValidMagic: Bool = {
            guard let handle = try? FileHandle(forReadingFrom: f),
                  let data = try? handle.read(upToCount: 8) else { return false }
            defer { try? handle.close() }
            guard data.count == 8 else { return false }
            // "MDIX" bytes: 0x4D 0x44 0x49 0x58
            return data[0] == 0x4D && data[1] == 0x44 && data[2] == 0x49 && data[3] == 0x58
        }()

        let status = isValidMagic ? colored("✓", .green) : colored("✗", .red)
        if isValidMagic { validCount += 1 } else { invalidCount += 1 }

        let sha = f.deletingPathExtension().lastPathComponent
        print("  \(status) \(sha.prefix(16))…   \(formatByteSize(size).padding(toLength: 10, withPad: " ", startingAt: 0))  \(ageString)")
    }

    print()
    print(colored("Summary:", .bold))
    print("  valid:   \(validCount)")
    if invalidCount > 0 {
        print(colored("  invalid: \(invalidCount)", .yellow))
    }
    if !tmpFiles.isEmpty {
        print(colored("  orphan .tmp-*: \(tmpFiles.count)", .yellow))
    }
    print("  total:   \(formatByteSize(totalBytes))")
    print()
}

// MARK: - Helpers

/// Clean description using MDictDescriptionParser
func cleanDescription(_ description: String) -> String {
    MDictDescriptionParser.cleanDescription(description)
}

/// Debug describe command - test description extraction
func debugDescribe(dict: MDictReader) {
    print(colored("🔬 Description Parsing Test", .bold))
    print()
    
    let rawDesc = dict.metadata.description
    let title = dict.metadata.title ?? "(no title)"
    
    // Raw description
    print(colored("Raw Title:", .yellow))
    print("  \(title)")
    print()
    
    print(colored("Raw Description (first 1000 chars):", .yellow))
    let truncatedRaw = rawDesc.count > 1000 ? String(rawDesc.prefix(1000)) + "..." : rawDesc
    print("  \(truncatedRaw)")
    print()
    
    // Extracted title
    print(colored("Extracted Title:", .green))
    if let extracted = MDictDescriptionParser.tryExtractTitle(from: rawDesc) {
        print("  ✓ \(extracted)")
    } else {
        print("  ✗ (extraction failed)")
    }
    print()
    
    // Extracted author
    print(colored("Extracted Author:", .green))
    if let author = MDictDescriptionParser.tryExtractAuthor(from: rawDesc) {
        print("  ✓ \(author)")
    } else {
        print("  ✗ (extraction failed)")
    }
    print()
    
    // Cleaned description
    print(colored("Cleaned Description:", .green))
    let cleaned = MDictDescriptionParser.cleanDescription(rawDesc)
    if cleaned.isEmpty {
        print("  (empty)")
    } else {
        let truncatedClean = cleaned.count > 500 ? String(cleaned.prefix(500)) + "..." : cleaned
        print("  \(truncatedClean.debugDescription)")
    }
    print()
    
    // Summary
    print(colored("Summary:", .bold))
    let isPlaceholder = title == "Title (No HTML code allowed)" || title == "(no title)" || title.isEmpty
    print("  Title is placeholder: ", isPlaceholder ? colored("Yes", .yellow) : colored("No", .green))
    print("  Has extractable title: ", MDictDescriptionParser.tryExtractTitle(from: rawDesc) != nil ? colored("Yes", .green) : colored("No", .yellow))
    print("  Has author: ", MDictDescriptionParser.tryExtractAuthor(from: rawDesc) != nil ? colored("Yes", .green) : colored("No", .yellow))
    print()
}

struct ResourceRef {
    enum RefType: String {
        case localResource    // CSS, images in MDD or external
        case audio            // sound:// protocol
        case entryLink        // entry:// cross-reference
        case webLink          // website links like /definition/
    }

    let path: String
    let type: RefType
}

// MARK: - JSON Schema for `lookup --format=json`

/// Top-level response.  `found` discriminates between the populated `entry` /
/// `links` branch and the populated `suggestions` branch.
struct LookupResponse: Codable {
    let dict: DictInfo
    let word: String
    let found: Bool
    let lookupTimeMs: Double
    let entry: EntryDetail?
    let links: [Link]?
    let suggestions: [Suggestion]?

    struct DictInfo: Codable {
        let path: String
        let title: String?
        let headerSHA256: String?
        let entryCount: Int
    }

    struct EntryDetail: Codable {
        let index: Int
        let html: String
        let navigation: Navigation

        struct Navigation: Codable {
            let previous: String?
            let next: String?
        }
    }

    /// One classified reference extracted from the article HTML.
    /// `word` + `fragment` are populated only when `type == "entry"`;
    /// `path` is the resolved resource path when `type == "audio"` /
    /// `"localResource"` (the sound:// or relative-path-stripped form).
    struct Link: Codable {
        let raw: String
        let type: String
        let word: String?
        let fragment: String?
        let path: String?
    }

    struct Suggestion: Codable {
        let word: String
        let distance: Int
    }
}

/// Parse `entry://word#fragment` (or `entry://word`, or even a bare
/// `word#fragment`) into its two parts.  Returns nil for the fragment if
/// the `#` is absent or empty.  Doesn't rely on `URL(string:)` because
/// MDX cross-ref values aren't always RFC-3986-clean.
func parseEntryLink(_ raw: String) -> (word: String, fragment: String?) {
    let stripped = raw.hasPrefix("entry://")
        ? String(raw.dropFirst("entry://".count))
        : raw
    guard let hashIdx = stripped.firstIndex(of: "#") else {
        return (stripped, nil)
    }
    let word = String(stripped[..<hashIdx])
    let frag = String(stripped[stripped.index(after: hashIdx)...])
    return (word, frag.isEmpty ? nil : frag)
}

/// Map a `ResourceRef` to the JSON-shaped `Link`, extracting word/fragment
/// for `entry://` URLs and the resolved path for `sound://` audios.
private func toJSONLink(_ ref: ResourceRef) -> LookupResponse.Link {
    switch ref.type {
    case .entryLink:
        let (word, fragment) = parseEntryLink(ref.path)
        return LookupResponse.Link(
            raw: ref.path, type: "entry",
            word: word, fragment: fragment, path: nil
        )
    case .audio:
        // ResourceRef.path for audio is already stripped of `sound://`
        return LookupResponse.Link(
            raw: "sound://\(ref.path)", type: "audio",
            word: nil, fragment: nil, path: ref.path
        )
    case .localResource:
        return LookupResponse.Link(
            raw: ref.path, type: "localResource",
            word: nil, fragment: nil, path: ref.path
        )
    case .webLink:
        return LookupResponse.Link(
            raw: ref.path, type: "webLink",
            word: nil, fragment: nil, path: nil
        )
    }
}

func buildLookupResponse(
    dict: MDictReader,
    mdxPath: String,
    word: String,
    entry: MDictWordEntry?,
    lookupTimeMs: Double
) -> LookupResponse {
    let dictInfo = LookupResponse.DictInfo(
        path: mdxPath,
        title: dict.metadata.title,
        headerSHA256: dict.metadata.headerSHA256,
        entryCount: dict.entryCount
    )

    guard let entry else {
        let suggestions = dict.suggestions(for: word, limit: 5).map {
            LookupResponse.Suggestion(word: $0.word, distance: $0.distance)
        }
        return LookupResponse(
            dict: dictInfo, word: word, found: false,
            lookupTimeMs: lookupTimeMs,
            entry: nil, links: nil,
            suggestions: suggestions
        )
    }

    let html = entry.article.html
    let links = extractResourceRefs(from: html).map(toJSONLink)

    let prevKey = entry.index > 0 ? dict[entry.index - 1]?.key : nil
    let nextKey = dict[entry.index + 1]?.key
    let nav = LookupResponse.EntryDetail.Navigation(previous: prevKey, next: nextKey)

    let detail = LookupResponse.EntryDetail(
        index: entry.index, html: html, navigation: nav
    )

    return LookupResponse(
        dict: dictInfo, word: word, found: true,
        lookupTimeMs: lookupTimeMs,
        entry: detail, links: links,
        suggestions: nil
    )
}

func extractResourceRefs(from html: String) -> [ResourceRef] {
    var refs: [String: ResourceRef] = [:]
    
    // Match href="..." and src="..."
    let patterns = [
        #"href\s*=\s*"([^"]+)""#,
        #"src\s*=\s*"([^"]+)""#,
        #"url\s*\(\s*'?([^')]+)'?\s*\)"#
    ]
    
    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, range: range)
            
            for match in matches {
                if let refRange = Range(match.range(at: 1), in: html) {
                    let path = String(html[refRange])
                    
                    // Classify the reference
                    let ref: ResourceRef?
                    
                    if path.hasPrefix("http://") || path.hasPrefix("https://") {
                        // Skip external URLs
                        ref = nil
                    } else if path.hasPrefix("#") {
                        // Skip anchors
                        ref = nil
                    } else if path.hasPrefix("entry://") {
                        ref = ResourceRef(path: path, type: .entryLink)
                    } else if path.hasPrefix("sound://") {
                        // Extract path after sound://
                        let audioPath = String(path.dropFirst("sound://".count))
                        ref = ResourceRef(path: audioPath, type: .audio)
                    } else if path.hasPrefix("/definition/") ||
                              path.hasPrefix("/pronunciation/") ||
                              path.hasPrefix("/mywordlist") ||
                              path.hasPrefix("/wordlist/") ||
                              path.hasPrefix("/topic/") {
                        // Website links, not local resources
                        ref = ResourceRef(path: path, type: .webLink)
                    } else if path.hasSuffix(".css") || path.hasSuffix(".js") ||
                              path.hasSuffix(".png") || path.hasSuffix(".jpg") ||
                              path.hasSuffix(".gif") || path.hasSuffix(".svg") ||
                              path.hasSuffix(".ttf") || path.hasSuffix(".woff") {
                        ref = ResourceRef(path: path, type: .localResource)
                    } else {
                        // Unknown - could be resource or link
                        ref = ResourceRef(path: path, type: .webLink)
                    }
                    
                    if let ref = ref, refs[path] == nil {
                        refs[path] = ref
                    }
                }
            }
        }
    }
    
    return Array(refs.values).sorted { $0.path < $1.path }
}

func showResourceRefs(refs: [ResourceRef], dict: MDictReader) {
    let grouped = Dictionary(grouping: refs) { $0.type }
    
    // Local resources (CSS, images)
    if let local = grouped[.localResource], !local.isEmpty {
        print(colored("Local Resources:", .bold))
        for ref in local.prefix(5) {
            let exists = dict.hasResource(ref.path)
            let status = exists ? colored("✓", .green) : colored("✗", .yellow)
            print("  \(status) \(ref.path)")
        }
        if local.count > 5 {
            print("  ... and \(local.count - 5) more")
        }
        print()
    }
    
    // Audio files
    if let audio = grouped[.audio], !audio.isEmpty {
        print(colored("Audio Files:", .bold))
        for ref in audio.prefix(5) {
            let exists = dict.hasResource(ref.path)
            let status = exists ? colored("✓", .green) : colored("✗", .yellow)
            print("  \(status) 🔊 \(ref.path)")
        }
        if audio.count > 5 {
            print("  ... and \(audio.count - 5) more")
        }
        print()
    }
    
    // Entry cross-references
    if let entries = grouped[.entryLink], !entries.isEmpty {
        print(colored("Cross-references:", .bold))
        for ref in entries.prefix(5) {
            let entryName = ref.path.replacingOccurrences(of: "entry://", with: "")
            print("  → \(entryName)")
        }
        if entries.count > 5 {
            print("  ... and \(entries.count - 5) more")
        }
        print()
    }
}

main()

// When sidecar caching is enabled (smoke testing), give background writes
// time to flush before exiting the short-lived CLI process. iOS apps don't
// need this — they live long enough for the dispatch to complete naturally.
if ProcessInfo.processInfo.environment["OPENMDICT_SIDECAR_DIR"] != nil {
    Thread.sleep(forTimeInterval: 2.0)
}
