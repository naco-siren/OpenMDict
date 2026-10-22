//
//  ArticleIndex.swift
//  OpenMDictCLI  (M15 Phase 3.2)
//
//  `articleindex` subcommand entry point. Two modes:
//
//    openmdict articleindex build <mdx> --model <PATH> --vocab <PATH> --out <PATH>
//        Build an article-embedding sidecar for the given MDX. Writes to
//        --out atomically.
//
//    openmdict articleindex info <sidecar.semantic.idx> [--mdx <PATH> --model <PATH>]
//        Inspect a sidecar's header. If --mdx + --model are passed,
//        also validate against them (would the sidecar be accepted?).
//
//  Phase 3.2 deliverable: prove the writer round-trips correctly.
//  Phase 3.6 will add the reader + cosine-scan query path, at which
//  point this CLI gains a `articleindex query` subcommand too.
//

import Foundation
import CryptoKit
import OpenMDict   // ArticleIndexFormat / Writer / Reader live in the core lib

func handleArticleIndexSubcommand(args: [String]) {
    guard let sub = args.first else {
        articleIndexUsage()
        exit(1)
    }
    switch sub {
    case "build":
        handleArticleIndexBuild(args: Array(args.dropFirst()))
    case "info":
        handleArticleIndexInfo(args: Array(args.dropFirst()))
    case "query":
        handleArticleIndexQuery(args: Array(args.dropFirst()))
    default:
        eprintln(colored("Unknown articleindex subcommand: \(sub)", .red))
        articleIndexUsage()
        exit(1)
    }
}

private func articleIndexUsage() {
    eprintln("Usage:")
    eprintln("  openmdict articleindex build <mdx> --model <PATH> --vocab <PATH> --out <PATH> [--limit N]")
    eprintln("  openmdict articleindex info <sidecar> [--mdx <PATH> --model <PATH>]")
    eprintln("  openmdict articleindex query <sidecar> --model <PATH> --vocab <PATH> --mdx <PATH> <query> [-k N]")
}

// MARK: - build

private func handleArticleIndexBuild(args: [String]) {
    var positional: [String] = []
    var modelPath: String?
    var vocabPath: String?
    var outPath: String?
    var limit: Int = 0  // 0 = no limit

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model":
            guard i + 1 < args.count else { eprintln("--model needs path"); exit(1) }
            modelPath = args[i + 1]; i += 2
        case "--vocab":
            guard i + 1 < args.count else { eprintln("--vocab needs path"); exit(1) }
            vocabPath = args[i + 1]; i += 2
        case "--out":
            guard i + 1 < args.count else { eprintln("--out needs path"); exit(1) }
            outPath = args[i + 1]; i += 2
        case "--limit":
            // Index only the first N keys. For testing/iteration on
            // large MDX files where the full build would take many minutes.
            guard i + 1 < args.count else { eprintln("--limit needs int"); exit(1) }
            limit = Int(args[i + 1]) ?? 0; i += 2
        default:
            positional.append(args[i]); i += 1
        }
    }

    guard let mdxPath = positional.first,
          let modelPath, let vocabPath, let outPath
    else {
        eprintln(colored("Error: articleindex build needs <mdx> + --model + --vocab + --out", .red))
        articleIndexUsage()
        exit(1)
    }

    // Load reader + encoder.
    print(colored("📖 Opening MDX:", .cyan), mdxPath)
    let dict: MDictReader
    do { dict = try MDictReader(path: mdxPath) }
    catch { eprintln(colored("MDX open failed: \(error)", .red)); exit(1) }
    print("   \(dict.entryCount) entries, '\(dict.metadata.title ?? "?")'")
    print()

    print(colored("⏳ Loading encoder:", .cyan), modelPath)
    let encoderLoadStart = CFAbsoluteTimeGetCurrent()
    let encoder: ArticleEncoder
    do {
        encoder = try ArticleEncoder(modelPath: modelPath, vocabPath: vocabPath)
    } catch {
        eprintln(colored("Encoder init failed: \(error)", .red)); exit(1)
    }
    let encoderLoadMs = (CFAbsoluteTimeGetCurrent() - encoderLoadStart) * 1000
    print(colored("   ✓ Loaded in \(String(format: "%.1f", encoderLoadMs)) ms", .green))
    print()

    // Build sidecar.
    let outURL = URL(fileURLWithPath: outPath)
    let parent = outURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    print(colored("🔨 Building sidecar →", .cyan), outURL.path)
    let buildStart = CFAbsoluteTimeGetCurrent()
    let writer = ArticleIndexWriter(
        modelURL: URL(fileURLWithPath: modelPath),
        outputURL: outURL,
        limit: limit > 0 ? limit : nil,
        progress: { done, total, elapsed in
            let pct = total > 0 ? Double(done) / Double(total) * 100 : 0
            let ips = elapsed > 0 ? Double(done) / elapsed : 0
            eprintln(String(
                format: "   [%6d / %6d]  %5.1f%%  %6.1f ips  %5.1fs elapsed",
                done, total, pct, ips, elapsed
            ))
        }
    )

    let header: ArticleIndexHeader
    do {
        // build() auto-resumes from any valid partial already at --out,
        // so re-running the same command continues / no-ops. The CLI
        // passes no isCancelled, so .interrupted won't occur here.
        switch try writer.build(reader: dict, encoder: encoder) {
        case .completed(let h):
            header = h
        case .interrupted(let h, let through):
            header = h
            eprintln(colored("⚠️  interrupted at key \(through) (\(h.rowCount) articles)", .yellow))
        }
    } catch {
        eprintln(colored("Build failed: \(error)", .red)); exit(1)
    }
    let buildMs = (CFAbsoluteTimeGetCurrent() - buildStart) * 1000
    let attrs = (try? FileManager.default.attributesOfItem(atPath: outURL.path)) ?? [:]
    let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0

    print()
    print(colored("✅ Sidecar written", .green))
    print("   path:         \(outURL.path)")
    print("   size:         \(formatByteSize(bytes))")
    print("   articles:     \(header.rowCount) (rows)")
    print("   keys:         \(header.keyCount)")
    print("   dim:          \(header.embeddingDim)")
    print("   model SHA:    \(header.modelSHA256.map { String(format: "%02x", $0) }.joined().prefix(16))…")
    print("   mdx SHA:      \(header.mdxHeaderSHA256.map { String(format: "%02x", $0) }.joined().prefix(16))…")
    print("   built in:     \(String(format: "%.1f", buildMs / 1000)) s")
    print()
}

// MARK: - info

private func handleArticleIndexInfo(args: [String]) {
    var positional: [String] = []
    var mdxPath: String?
    var modelPath: String?

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--mdx":
            guard i + 1 < args.count else { eprintln("--mdx needs path"); exit(1) }
            mdxPath = args[i + 1]; i += 2
        case "--model":
            guard i + 1 < args.count else { eprintln("--model needs path"); exit(1) }
            modelPath = args[i + 1]; i += 2
        default:
            positional.append(args[i]); i += 1
        }
    }
    guard let sidecarPath = positional.first else {
        eprintln(colored("Error: articleindex info needs a sidecar path", .red))
        exit(1)
    }
    guard FileManager.default.fileExists(atPath: sidecarPath) else {
        eprintln(colored("File not found: \(sidecarPath)", .red))
        exit(1)
    }
    let sidecarURL = URL(fileURLWithPath: sidecarPath)

    let data: Data
    do { data = try Data(contentsOf: sidecarURL) }
    catch { eprintln(colored("Read failed: \(error)", .red)); exit(1) }

    guard let header = ArticleIndexHeader.parse(data) else {
        eprintln(colored("✗ Not an article-embedding sidecar (magic mismatch)", .red))
        exit(1)
    }

    print()
    print(colored("📇 Sidecar:", .cyan), sidecarPath)
    print()
    print(colored("Header:", .bold))
    let versionNote: String
    if header.formatVersion == ArticleIndexFormat.currentVersion {
        versionNote = colored("(current)", .green)
    } else if ArticleIndexFormat.isReadable(header.formatVersion) {
        versionNote = colored("(dense legacy layout, still readable; current = \(ArticleIndexFormat.currentVersion))", .yellow)
    } else {
        versionNote = colored("(unsupported, expected \(ArticleIndexFormat.currentVersion))", .yellow)
    }
    print("  format version:    \(header.formatVersion) " + versionNote)
    print("  embedding_dim:     \(header.embeddingDim)")
    print("  row_count:         \(header.rowCount)")
    print("  key_count:         \(header.keyCount)")
    print("  tokenizer_max_len: \(header.tokenizerMaxLen)")
    print("  model SHA256:      \(header.modelSHA256.map { String(format: "%02x", $0) }.joined())")
    print("  mdx SHA256:        \(header.mdxHeaderSHA256.map { String(format: "%02x", $0) }.joined())")
    print("  created at:        \(Date(timeIntervalSince1970: TimeInterval(header.createdAt)))")
    print()
    print(colored("File:", .bold))
    print("  actual size:       \(formatByteSize(Int64(data.count)))")
    print("  expected size:     \(formatByteSize(Int64(header.expectedFileSize)))")
    print("  body bytes:        \(data.count - header.headerSize) (\(header.rowStride) per row)")
    print()

    // Optional validation against current MDX + model.
    guard let mdxPath, let modelPath else {
        print(colored("Tip:", .yellow), "pass --mdx <path> --model <path> to validate against current files")
        print()
        return
    }
    print(colored("Validation:", .bold))
    // Reuse the writer's SHA computation via a quick MDictReader load.
    let reader: MDictReader
    do { reader = try MDictReader(path: mdxPath) }
    catch { eprintln(colored("  ✗ MDX load failed: \(error)", .red)); return }

    guard let currMDXHashHex = reader.metadata.headerSHA256 else {
        print(colored("  ✗ Current MDX has no header SHA256 (encrypted?)", .red))
        return
    }
    guard let currMDXHash = hexToData(currMDXHashHex), currMDXHash.count == 32 else {
        print(colored("  ✗ Could not parse current MDX SHA256", .red))
        return
    }
    let currModelHash: Data
    do { currModelHash = try computeModelSHA(modelPath: modelPath) }
    catch { eprintln(colored("  ✗ Model hash failed: \(error)", .red)); return }

    let result = header.validate(
        expectedModelSHA256: currModelHash,
        expectedMDXHeaderSHA256: currMDXHash,
        expectedEmbeddingDim: header.embeddingDim,  // we don't know dim a priori; accept whatever was written
        actualFileSize: data.count
    )
    switch result {
    case .ok:
        print(colored("  ✓ valid — sidecar matches current MDX + model", .green))
    case .notASidecar:
        print(colored("  ✗ magic mismatch (impossible — we already parsed)", .red))
    case .wrongVersion(let v):
        print(colored("  ✗ unsupported format version \(v) (current = \(ArticleIndexFormat.currentVersion))", .yellow))
    case .modelMismatch:
        print(colored("  ✗ model SHA256 mismatch — rebuild needed", .yellow))
    case .mdxMismatch:
        print(colored("  ✗ MDX SHA256 mismatch — rebuild needed", .yellow))
    case .dimMismatch(let d):
        print(colored("  ✗ dim mismatch (header says \(d))", .yellow))
    case .sizeMismatch(let exp, let act):
        print(colored("  ✗ size mismatch: header expects \(exp) bytes, file is \(act)", .red))
    }
    print()
}

// MARK: - query

private func handleArticleIndexQuery(args: [String]) {
    var positional: [String] = []
    var modelPath: String?
    var vocabPath: String?
    var mdxPath: String?
    var topK: Int = 10

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model":
            guard i + 1 < args.count else { eprintln("--model needs path"); exit(1) }
            modelPath = args[i + 1]; i += 2
        case "--vocab":
            guard i + 1 < args.count else { eprintln("--vocab needs path"); exit(1) }
            vocabPath = args[i + 1]; i += 2
        case "--mdx":
            guard i + 1 < args.count else { eprintln("--mdx needs path"); exit(1) }
            mdxPath = args[i + 1]; i += 2
        case "-k", "--topk":
            guard i + 1 < args.count else { eprintln("-k needs int"); exit(1) }
            topK = Int(args[i + 1]) ?? 10; i += 2
        default:
            positional.append(args[i]); i += 1
        }
    }
    guard positional.count >= 2, let modelPath, let vocabPath, let mdxPath else {
        eprintln(colored(
            "Error: articleindex query needs <sidecar> + --model + --vocab + --mdx + <query>",
            .red
        ))
        articleIndexUsage()
        exit(1)
    }
    let sidecarPath = positional[0]
    // Allow multi-word queries: join everything after the sidecar path.
    let queryText = positional.dropFirst().joined(separator: " ")

    print(colored("🔎 Query:", .cyan), queryText)
    print(colored("   sidecar:", .dim), sidecarPath)
    print()

    // Load the MDX so we can map article indices → headwords for display.
    let reader: MDictReader
    do { reader = try MDictReader(path: mdxPath) }
    catch { eprintln(colored("MDX open failed: \(error)", .red)); exit(1) }
    let allKeys = reader.allKeys

    // Run encode + scan.
    let result: (header: ArticleIndexHeader, hits: [ArticleIndexHit], queryEncodeMs: Double, scanMs: Double)
    do {
        result = try runArticleSemanticQuery(
            sidecarURL: URL(fileURLWithPath: sidecarPath),
            query: queryText,
            modelPath: modelPath,
            vocabPath: vocabPath,
            topK: topK
        )
    } catch {
        eprintln(colored("Query failed: \(error)", .red))
        exit(1)
    }

    print(colored("Top \(result.hits.count) (cosine similarity):", .bold))
    for (rank, hit) in result.hits.enumerated() {
        let key = hit.articleIndex < allKeys.count
            ? allKeys[hit.articleIndex]
            : "?"
        print(String(format: "  %2d.  %.4f  %@", rank + 1, hit.cosineSimilarity, key))
    }
    print()
    print(colored("Timings:", .bold))
    print(String(format: "  query encode:  %6.2f ms", result.queryEncodeMs))
    print(String(format: "  sidecar scan:  %6.2f ms over %d rows",
                  result.scanMs, result.header.rowCount))
    print(String(format: "  ips equiv:     %.1f rows/sec",
                  Double(result.header.rowCount) / (result.scanMs / 1000)))
    print()
}

// MARK: - small local helpers

/// SHA256 of the model's inner mlmodel protobuf. Mirrors
/// ArticleIndexWriter.computeModelSHA256 — duplicated here because the
/// writer's version is private and this CLI mode is read-only.
private func computeModelSHA(modelPath: String) throws -> Data {
    let url = URL(fileURLWithPath: modelPath)
    let candidates = [
        url.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"),
        url.appendingPathComponent("model.mil"),
        url,
    ]
    for c in candidates {
        if FileManager.default.fileExists(atPath: c.path),
           let data = try? Data(contentsOf: c) {
            return Data(SHA256.hash(data: data))
        }
    }
    throw NSError(domain: "ArticleIndex", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Could not find inner model.mlmodel in \(modelPath)"
    ])
}

/// Parse a hex string into bytes. Returns nil if the input isn't
/// well-formed hex of even length.
private func hexToData(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data(capacity: hex.count / 2)
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
        data.append(byte)
        idx = next
    }
    return data
}

/// Format bytes for display (mirror main.swift's helper).
private func formatByteSize(_ bytes: Int64) -> String {
    if bytes >= 1024 * 1024 {
        return String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
    }
    if bytes >= 1024 {
        return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }
    return "\(bytes) B"
}
