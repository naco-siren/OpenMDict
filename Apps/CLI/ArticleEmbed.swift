//
//  ArticleEmbed.swift
//  OpenMDictCLI
//
//  M15 Phase 3.0 — `articleembed` subcommand. Provides three modes:
//
//    openmdict articleembed --model PATH --vocab PATH "some text"
//        Print a 1×D normalized embedding vector to stdout.
//
//    openmdict articleembed --model PATH --vocab PATH --pair "text1" "text2"
//        Encode both, print cosine similarity. Sanity-check mode for
//        validating model + tokenizer end-to-end.
//
//    openmdict articleembed --model PATH --vocab PATH --sanity
//        Run a built-in suite of known-good word pairs. Used during
//        bring-up to confirm the model wasn't broken during conversion.
//        Expected ranges (all-MiniLM-L6-v2, post-L2-normalize):
//          cat / dog               sim ≈ 0.55-0.75   (related)
//          cat / kitten            sim ≈ 0.55-0.75   (related, more abstract)
//          king / queen            sim ≈ 0.65-0.85   (analogical)
//          cat / calculus          sim ≈ 0.0-0.2     (unrelated)
//          happiness / sadness     sim ≈ 0.45-0.70   (opposites — both
//                                                     emotion-domain so
//                                                     still moderately
//                                                     high in word2vec
//                                                     family)
//
//  No support for batched encoding yet — the CLI is for bring-up, the
//  iOS app's `ArticleIndexWriter` (Phase 3.2) is where batching matters.
//

import Foundation
import OpenMDict   // ArticleEncoder + Tokenized live in the core lib alongside the MDX parser

func handleArticleEmbed(args: [String]) {
    var modelPath: String? = nil
    var vocabPath: String? = nil
    var pair: Bool = false
    var sanity: Bool = false
    var benchN: Int = 0   // 0 = disabled, >0 = run that many encode timings
    var maxLength: Int = 128

    var positional: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model":
            guard i + 1 < args.count else { eprintln("--model needs path"); exit(1) }
            modelPath = args[i + 1]; i += 2
        case "--vocab":
            guard i + 1 < args.count else { eprintln("--vocab needs path"); exit(1) }
            vocabPath = args[i + 1]; i += 2
        case "--max-length":
            guard i + 1 < args.count else { eprintln("--max-length needs int"); exit(1) }
            maxLength = Int(args[i + 1]) ?? 128
            i += 2
        case "--pair":
            pair = true; i += 1
        case "--sanity":
            sanity = true; i += 1
        case "--bench":
            // --bench N runs N encode iterations on stride-sampled text
            // for throughput comparison (Phase 3.1 model survey).
            guard i + 1 < args.count else { eprintln("--bench needs N"); exit(1) }
            benchN = Int(args[i + 1]) ?? 100
            i += 2
        default:
            positional.append(args[i]); i += 1
        }
    }

    guard let modelPath, let vocabPath else {
        eprintln(colored("Error: --model and --vocab are required", .red))
        eprintln("")
        eprintln("Example:")
        eprintln("  openmdict articleembed --model ./MiniLM.mlpackage --vocab ./vocab.txt \"hello world\"")
        eprintln("  openmdict articleembed --model ./MiniLM.mlpackage --vocab ./vocab.txt --pair \"cat\" \"dog\"")
        eprintln("  openmdict articleembed --model ./MiniLM.mlpackage --vocab ./vocab.txt --sanity")
        exit(1)
    }

    // Load model + tokenizer once. The CoreML compile step on first run
    // can take 5–30s on .mlpackage (Apple's tooling builds an .mlmodelc
    // cache the second time around — much faster).
    print(colored("⏳ Loading model from \(modelPath) …", .dim))
    let loadStart = CFAbsoluteTimeGetCurrent()
    let encoder: ArticleEncoder
    do {
        encoder = try ArticleEncoder(modelPath: modelPath, vocabPath: vocabPath, maxLength: maxLength)
    } catch {
        eprintln(colored("Error: \(error)", .red))
        exit(1)
    }
    let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
    print(colored("✓ Model loaded in \(String(format: "%.1f", loadMs)) ms", .green))
    print()

    // Dispatch based on mode.
    if sanity {
        runSanitySuite(encoder: encoder)
    }
    if benchN > 0 {
        runBench(encoder: encoder, count: benchN)
    }
    if sanity || benchN > 0 {
        return
    }
    if pair {
        guard positional.count == 2 else {
            eprintln(colored("--pair needs exactly two text arguments", .red))
            exit(1)
        }
        runPair(encoder: encoder, a: positional[0], b: positional[1])
        return
    }
    guard let text = positional.first else {
        eprintln(colored("Error: missing text to embed", .red))
        exit(1)
    }
    runSingle(encoder: encoder, text: text)
}

// MARK: - Modes

private func runSingle(encoder: ArticleEncoder, text: String) {
    let start = CFAbsoluteTimeGetCurrent()
    let vec: [Float]
    do { vec = try encoder.encode(text) } catch {
        eprintln(colored("Error: \(error)", .red))
        exit(1)
    }
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

    print(colored("Text:", .bold), text)
    print(colored("Dim: ", .bold), "\(vec.count)")
    print(colored("Time:", .bold), String(format: "%.2f ms", ms))
    print()
    print(colored("Vector (L2-normalized):", .bold))
    // Print first 16 + last 4 floats so the output stays readable
    // but the user can confirm it's not all zeros / not a constant.
    let head = vec.prefix(16).map { String(format: "%+.4f", $0) }
    let tail = vec.suffix(4).map { String(format: "%+.4f", $0) }
    print("  [\(head.joined(separator: ", ")) … \(tail.joined(separator: ", "))]")
    print()
    // L2 norm sanity-check — should be ~1.0 if normalization worked.
    var sq: Float = 0
    for x in vec { sq += x * x }
    print(colored("‖v‖₂ =", .dim), String(format: "%.4f", sq.squareRoot()), "(should be ≈ 1.0)")
    print()
}

private func runPair(encoder: ArticleEncoder, a: String, b: String) {
    let va: [Float]
    let vb: [Float]
    do {
        va = try encoder.encode(a)
        vb = try encoder.encode(b)
    } catch {
        eprintln(colored("Error: \(error)", .red))
        exit(1)
    }
    let sim = ArticleEncoder.cosineSimilarity(va, vb)
    print(colored("A:", .bold), a)
    print(colored("B:", .bold), b)
    print(colored("cos:", .bold), String(format: "%+.4f", sim))
    print()
}

/// Throughput micro-bench: encode N short texts back-to-back and report
/// min / p50 / p95 / mean / max. Used by the Phase 3.1 model survey to
/// compare per-encode latency across candidate models on the same host.
/// Texts cycled from a built-in fixture so all models see the same
/// inputs in the same order.
private func runBench(encoder: ArticleEncoder, count: Int) {
    let texts: [String] = [
        // Mix of short / medium / long to exercise the tokenizer and
        // the model's full sequence-length compute. All under 128 tokens
        // (the model's max_len) so no truncation distorts the bench.
        "cat",
        "the quick brown fox jumps over the lazy dog",
        "A dictionary app can look up one word in several dictionaries at once.",
        "supercalifragilisticexpialidocious",
        "The bus was late again, so we walked the last two miles home in the rain.",
        "happy birthday",
        "I am writing to inform you that the meeting scheduled for tomorrow has been postponed.",
        "ephemeral",
        "Apple's Neural Engine accelerates machine learning workloads on-device for privacy and speed.",
        "OK",
    ]
    print(colored("⏱  Throughput bench (\(count) iterations)", .bold))
    var latencies: [Double] = []
    latencies.reserveCapacity(count)
    let totalStart = CFAbsoluteTimeGetCurrent()
    for i in 0..<count {
        let text = texts[i % texts.count]
        let start = CFAbsoluteTimeGetCurrent()
        do { _ = try encoder.encode(text) } catch {
            print(colored("Error at iter \(i): \(error)", .red))
            return
        }
        latencies.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    let totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
    let sorted = latencies.sorted()
    func pct(_ p: Double) -> Double {
        let i = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
        return sorted[i]
    }
    let mean = latencies.reduce(0, +) / Double(latencies.count)
    print(String(format: "  min  %6.2f ms", sorted.first ?? 0))
    print(String(format: "  p50  %6.2f ms", pct(0.5)))
    print(String(format: "  p95  %6.2f ms", pct(0.95)))
    print(String(format: "  mean %6.2f ms", mean))
    print(String(format: "  max  %6.2f ms", sorted.last ?? 0))
    print(String(format: "  total %.2f s for %d encodes = %.1f ips",
                  totalMs / 1000, count, Double(count) / (totalMs / 1000)))
    print()
}

/// Known-good word pairs we expect a working `all-MiniLM-L6-v2` to score
/// in characteristic ranges. The ranges are wide — exact numbers vary
/// between conversions and quantization levels — but ordering should
/// hold. If `dog` scores closer to `calculus` than to `cat`, something
/// is broken (tokenizer mismatch or model file corruption).
private func runSanitySuite(encoder: ArticleEncoder) {
    let pairs: [(String, String, ClosedRange<Float>, String)] = [
        ("cat", "dog",                 0.30...0.85, "related animals"),
        ("cat", "kitten",              0.40...0.85, "hyponym"),
        ("king", "queen",              0.40...0.90, "analogical pair"),
        ("happiness", "joy",           0.45...0.95, "synonym"),
        ("happiness", "sadness",       0.20...0.80, "opposite — same domain so often still moderate"),
        ("cat", "calculus",           -0.20...0.40, "unrelated, weak"),
        ("dog", "mathematics",        -0.20...0.40, "unrelated, weak"),
        ("apple fruit", "banana fruit",0.40...0.95, "compound text — checks pooling works"),
    ]

    print(colored("🧪 Sanity suite", .bold))
    print(colored("  (range = expected min..max for a healthy all-MiniLM-L6-v2)", .dim))
    print()

    var passes = 0
    for (a, b, range, note) in pairs {
        let va: [Float]
        let vb: [Float]
        do { va = try encoder.encode(a); vb = try encoder.encode(b) } catch {
            print(colored("✗ \(a) / \(b): \(error)", .red))
            continue
        }
        let sim = ArticleEncoder.cosineSimilarity(va, vb)
        let ok = range.contains(sim)
        let mark = ok ? colored("✓", .green) : colored("✗", .red)
        if ok { passes += 1 }
        let simStr = String(format: "%+.4f", sim)
        let rangeStr = String(format: "%+.2f..%+.2f", range.lowerBound, range.upperBound)
        print("  \(mark) \(a.padding(toLength: 14, withPad: " ", startingAt: 0)) / \(b.padding(toLength: 14, withPad: " ", startingAt: 0))  cos=\(simStr)  range=[\(rangeStr)]  \(colored(note, .dim))")
    }
    print()
    let allOk = passes == pairs.count
    let summary = "\(passes) / \(pairs.count) pairs in range"
    print(colored("Summary: " + summary, allOk ? .green : .yellow))
    if !allOk {
        print(colored("  → Some pairs out of range. Check model conversion, tokenizer vocab, and pooling.", .yellow))
    }
    print()
}
