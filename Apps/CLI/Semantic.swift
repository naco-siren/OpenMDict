//
//  Semantic.swift
//  openmdict CLI
//
//  M15 Phase 1 — Step 0 / 0.5 quality probe.
//  Usage:
//      openmdict <mdx> semantic <word>
//          [--lang auto|en|zh-Hans|ja|...]  default: auto (sample keywords)
//          [--limit N]                      default: 10
//          [--scope all|dict|both]          default: both
//          [--no-stopwords]                 disable stopword filtering
//
//  "scope=all"  → top-K from NLEmbedding's full vocabulary
//  "scope=dict" → top-K from this MDX's keyword set
//  "scope=both" → print both side-by-side
//
//  Step 0.5 fixes vs Step 0:
//  - Lemma fallback only applies to plain alphabetic keywords (no spaces,
//    hyphens, apostrophes, digits) — kills the "back / back down / back out"
//    tie bug where multi-word phrases inherit their first token's vector.
//  - English stopword filter on dict-restricted results (mirror of
//    LemmaResolver.englishStopwords + extras for generic adverbs).
//  - Auto language detection via NLLanguageRecognizer on a 200-keyword sample.
//  - NLTagger instance reused across the scan (was per-keyword init in Step 0).
//

import Foundation
import NaturalLanguage
import OpenMDict

// MARK: - Entry

func handleSemanticSubcommand(dict: MDictReader, args: [String]) {
    // args[0] = "semantic", args[1] = word OR "matrix", then flags
    guard args.count >= 2 else {
        eprintln("Error: missing word for semantic")
        eprintln("  openmdict <mdx> semantic <word> [--lang auto] [--limit 10] [--scope both] [--no-stopwords]")
        eprintln("  openmdict <mdx> semantic matrix [--lang auto] [--no-stopwords]")
        exit(1)
    }

    // Matrix mode: run the built-in test set across the threshold grid
    if args[1].lowercased() == "matrix" {
        runMatrixMode(dict: dict, args: Array(args.dropFirst(2)))
        return
    }

    let word = args[1]
    var langArg: String = "auto"
    var limit = 10
    var scope: SemScope = .both
    var useStopwords = true

    var i = 2
    while i < args.count {
        let a = args[i]
        switch a {
        case "--lang":
            guard i + 1 < args.count else { eprintln("--lang needs value"); exit(1) }
            langArg = args[i + 1]
            i += 2
        case "--limit":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else { eprintln("--limit needs int"); exit(1) }
            limit = n
            i += 2
        case "--scope":
            guard i + 1 < args.count, let s = SemScope(rawValue: args[i + 1]) else { eprintln("--scope needs all|dict|both"); exit(1) }
            scope = s
            i += 2
        case "--no-stopwords":
            useStopwords = false
            i += 1
        default:
            eprintln("Unknown flag: \(a)")
            exit(1)
        }
    }

    // Resolve language: "auto" sniffs keyword sample, otherwise user override.
    let lang: NLLanguage
    if langArg == "auto" {
        let t0 = CFAbsoluteTimeGetCurrent()
        lang = detectKeywordLanguage(dict: dict)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print(colored("Auto-detected keyword language: \(lang.rawValue)", .yellow), "(\(String(format: "%.1f", ms)) ms)")
    } else {
        lang = NLLanguage(rawValue: langArg)
    }

    runSemanticProbe(dict: dict, word: word, lang: lang, limit: limit, scope: scope, useStopwords: useStopwords)
}

enum SemScope: String {
    case all, dict, both
}

// MARK: - Probe

private func runSemanticProbe(dict: MDictReader, word: String, lang: NLLanguage, limit: Int, scope: SemScope, useStopwords: Bool) {
    print()
    print(colored("🧠 Semantic probe", .bold))
    print("  word:      \(word)")
    print("  lang:      \(lang.rawValue)")
    print("  limit:     \(limit)")
    print("  scope:     \(scope.rawValue)")
    print("  stopwords: \(useStopwords ? "filter" : "off")")
    print()

    // 1. Acquire embedding
    let t0 = CFAbsoluteTimeGetCurrent()
    guard let embedding = NLEmbedding.wordEmbedding(for: lang) else {
        eprintln(colored("Error: NLEmbedding has no word-level model for language '\(lang.rawValue)'", .red))
        eprintln("Built-in coverage (per Apple docs): en, es, fr, de, it, pt, ru, ja, ko, zh-Hans, zh-Hant")
        exit(1)
    }
    let loadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(colored("NLEmbedding loaded", .green), "(\(String(format: "%.1f", loadMs)) ms)")
    print("  vocabulary: \(embedding.vocabularySize)")
    print("  dimension:  \(embedding.dimension)")
    print()

    // 2. Try query embedding — for the QUERY we keep aggressive lemma fallback
    //    (user types "ran" expecting "run"). For KEYWORDS later we'll be stricter.
    let queryCandidates = candidateFormsExpanded(of: word)
    print(colored("Query candidates:", .yellow), queryCandidates.joined(separator: ", "))

    var queryVec: [Double]? = nil
    var queryHit: String? = nil
    for c in queryCandidates {
        if let v = embedding.vector(for: c) {
            queryVec = v
            queryHit = c
            break
        }
    }

    guard let qv = queryVec, let qhit = queryHit else {
        print(colored("✗ No NLEmbedding vector for any candidate form", .red))
        print("  → this word is out-of-vocabulary for the chosen language model")
        return
    }
    print(colored("✓ Embedded as", .green), "\"\(qhit)\"  (\(qv.count) dims)")
    print()

    // 3. NLEmbedding's own top-K (broad — vocabulary-wide)
    if scope == .all || scope == .both {
        let t1 = CFAbsoluteTimeGetCurrent()
        let neighbors = embedding.neighbors(for: qhit, maximumCount: limit)
        let ms = (CFAbsoluteTimeGetCurrent() - t1) * 1000

        print(colored("Top \(limit) NLEmbedding-vocab neighbors:", .cyan), "(\(String(format: "%.1f", ms)) ms)")
        print(colored("  (cos-dist; lower = closer.  ✓ = in this dict)", .dim))
        for (i, (nWord, dist)) in neighbors.enumerated() {
            let inDict = dict.contains(nWord)
            let mark = inDict ? colored("✓", .green) : " "
            print("  \(String(format: "%2d", i + 1)). \(mark) \(nWord)  \(colored(String(format: "(%.4f)", dist), .dim))")
        }
        print()
    }

    // 4. Dict-restricted nearest (what the app would actually surface)
    if scope == .dict || scope == .both {
        let t2 = CFAbsoluteTimeGetCurrent()
        let allKeys = dict.allKeys
        var covered = 0
        var oov = 0
        var scored: [(String, Double)] = []
        scored.reserveCapacity(allKeys.count)

        for key in allKeys {
            // CONSERVATIVE: only allow lemma fallback for plain alphabetic words.
            // Multi-word phrases / hyphenated keep raw form only (no lemma).
            var v: [Double]? = nil
            for c in candidateFormsConservative(of: key) {
                if let vec = embedding.vector(for: c) { v = vec; break }
            }
            guard let v else { oov += 1; continue }
            covered += 1
            let sim = cosineSimilarity(qv, v)
            scored.append((key, sim))
        }
        scored.sort { $0.1 > $1.1 }
        let scanMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000

        // Apply stopword filter on the way out. Keep the unfiltered count for telemetry.
        let stopwords = useStopwords ? stopwordsFor(lang) : Set<String>()
        let qhitLower = qhit.lowercased()
        let displayed = scored.lazy
            .filter { key, _ in
                let lk = key.lowercased()
                if lk == qhitLower { return false }      // skip self
                if stopwords.contains(lk) { return false } // skip stopwords
                return true
            }
            .prefix(limit)
            .map { $0 }

        print(colored("Top \(limit) dict-restricted neighbors:", .cyan), "(\(String(format: "%.1f", scanMs)) ms scan)")
        print(colored("  (cosine sim; higher = closer)", .dim))
        for (i, (key, sim)) in Array(displayed).enumerated() {
            print("  \(String(format: "%2d", i + 1)). \(key)  \(colored(String(format: "(%.4f)", sim), .dim))")
        }
        print()

        let pct = covered + oov == 0 ? 0 : Int(100.0 * Double(covered) / Double(covered + oov))
        print(colored("Coverage:", .yellow))
        print("  \(covered) / \(covered + oov) dict keywords had an NLEmbedding vector (\(pct)%)")
        print("  \(oov) out-of-vocabulary (typical: multi-word phrases, proper nouns, very rare/technical)")
        if useStopwords {
            let filteredCount = scored.prefix(limit * 3).filter { stopwords.contains($0.0.lowercased()) }.count
            print("  ~\(filteredCount) of top-\(limit * 3) suppressed as stopwords")
        }
        print()
    }
}

// MARK: - Matrix mode

/// Built-in English test set spanning common/rare × adjective/verb/noun.
/// Picked to expose the "common word = noisy / rare word = clean" axis.
private let matrixTestCases: [(word: String, note: String)] = [
    ("happy",        "common adjective"),
    ("sad",          "common adjective (near-antonym to happy)"),
    ("good",         "very high-frequency adjective"),
    ("beautiful",    "common adjective"),
    ("melancholy",   "rare adjective"),
    ("exquisite",    "rare adjective"),
    ("intelligent",  "evaluative adjective"),
    ("run",          "very common verb"),
    ("contemplate",  "specific verb"),
    ("destroy",      "transitive verb"),
    ("house",        "concrete common noun"),
    ("freedom",      "abstract noun"),
]

/// User-facing tier presets — what each "相关词查询结果量" setting maps to.
/// K = top-K cap, floor = minimum cosine sim. Scheme X (quality over quantity):
/// if fewer than K candidates are ≥ floor, we return fewer than K (no dilution).
///
/// Plan B (post-real-data bench): single uniform floor across all tiers. The
/// floor is purely a noise gate; the tier knob is K (how many to display).
/// Mental model: "floor = noise threshold (engineering), K = result count (UX)".
private struct RelatedTier {
    let label: String
    let k: Int
    let floor: Double
}
private let relatedTiers: [RelatedTier] = [
    RelatedTier(label: "严格", k: 5,  floor: 0.45),
    RelatedTier(label: "默认", k: 10, floor: 0.45),
    RelatedTier(label: "宽松", k: 20, floor: 0.45),
]

private func runMatrixMode(dict: MDictReader, args: [String]) {
    var langArg: String = "auto"
    var useStopwords = true
    var wordsFile: String? = nil
    var outJSON: String? = nil
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--lang":
            guard i + 1 < args.count else { eprintln("--lang needs value"); exit(1) }
            langArg = args[i + 1]; i += 2
        case "--no-stopwords":
            useStopwords = false; i += 1
        case "--words-file":
            guard i + 1 < args.count else { eprintln("--words-file needs path"); exit(1) }
            wordsFile = args[i + 1]; i += 2
        case "--out-json":
            guard i + 1 < args.count else { eprintln("--out-json needs path"); exit(1) }
            outJSON = args[i + 1]; i += 2
        default:
            eprintln("Unknown flag: \(args[i])"); exit(1)
        }
    }

    // Load test cases — either from --words-file, or fall back to the built-in 12-word set.
    let testCases: [(word: String, note: String)]
    if let wordsFile {
        testCases = loadWordsFile(wordsFile)
        eprintln("Loaded \(testCases.count) words from \(wordsFile)")
    } else {
        testCases = matrixTestCases
    }

    let lang: NLLanguage
    if langArg == "auto" {
        lang = detectKeywordLanguage(dict: dict)
        print(colored("Auto-detected keyword language: \(lang.rawValue)", .yellow))
    } else {
        lang = NLLanguage(rawValue: langArg)
    }

    guard let embedding = NLEmbedding.wordEmbedding(for: lang) else {
        eprintln(colored("Error: NLEmbedding has no model for '\(lang.rawValue)'", .red))
        exit(1)
    }

    // Precompute all keyword vectors ONCE — reused across every test case.
    // This is the same scan we'll eventually want to persist as sidecar.
    // We also bake in the canonical lemma per key so the dedup pass at query
    // time doesn't have to re-run NLTagger over 10k keywords.
    print()
    print(colored("⏳ Pre-scanning dictionary vectors …", .dim))
    let t0 = CFAbsoluteTimeGetCurrent()
    let allKeys = dict.allKeys
    var keyVectors: [(key: String, vec: [Double], lemma: String)] = []
    keyVectors.reserveCapacity(allKeys.count)
    for key in allKeys {
        let candidates = candidateFormsConservative(of: key)
        var v: [Double]? = nil
        for c in candidates {
            if let vec = embedding.vector(for: c) { v = vec; break }
        }
        if let v {
            // candidateFormsConservative returns [raw] or [raw, lemma]; .last is
            // the canonical lemma (or the raw form when no lemma was extracted).
            let lemma = candidates.last ?? key.lowercased()
            keyVectors.append((key, v, lemma))
        }
    }
    let scanMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(colored("  scanned \(allKeys.count) keys, \(keyVectors.count) vectorized (\(String(format: "%.0f", scanMs)) ms)", .dim))

    let stopwords = useStopwords ? stopwordsFor(lang) : Set<String>()

    // JSON output path: collect everything, write once at the end, skip pretty print.
    if let outJSON {
        let benchOutput = collectBenchJSON(
            testCases: testCases,
            embedding: embedding,
            keyVectors: keyVectors,
            stopwords: stopwords,
            dict: dict,
            allKeysCount: allKeys.count,
            vectorizedCount: keyVectors.count,
            language: lang.rawValue
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(benchOutput)
            try data.write(to: URL(fileURLWithPath: outJSON))
            eprintln(colored("✓ wrote \(benchOutput.results.count) results → \(outJSON)", .green))
        } catch {
            eprintln(colored("✗ JSON write failed: \(error)", .red))
            exit(1)
        }
        return
    }

    print()
    print(colored("═══ Matrix: thresholds × test cases ═══", .bold))
    print("  Dict: \(dict.metadata.title ?? "(no title)") · \(allKeys.count) entries")
    print("  Stopword filter: \(useStopwords ? "on" : "off")")
    print()

    // Per-test-case pretty output
    for (word, note) in testCases {
        runOneMatrixCase(
            word: word, note: note,
            embedding: embedding, keyVectors: keyVectors,
            stopwords: stopwords
        )
    }

    // Summary table at the end
    printMatrixSummary(
        embedding: embedding,
        keyVectors: keyVectors,
        stopwords: stopwords,
        testCases: testCases
    )
}

// MARK: - Words file + JSON

/// Load words from a plain text file. One word per line. Lines starting with #
/// or blank are ignored. Notes are dropped — the JSON output doesn't need them.
private func loadWordsFile(_ path: String) -> [(word: String, note: String)] {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        eprintln("Error: cannot read words file \(path)")
        exit(1)
    }
    var out: [(word: String, note: String)] = []
    for rawLine in raw.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        out.append((String(line), ""))
    }
    return out
}

// JSON DTOs — kept inside this file because they're CLI-specific.
private struct BenchOutput: Encodable {
    let dict: DictInfo
    let tiers: [TierInfo]
    let results: [QueryResult]

    struct DictInfo: Encodable {
        let title: String?
        let path: String
        let entryCount: Int
        let vectorizedCount: Int
        let language: String
    }
    struct TierInfo: Encodable {
        let label: String
        let k: Int
        let floor: Double
    }
    struct QueryResult: Encodable {
        let query: String
        let embeddedAs: String?
        let oov: Bool
        let maxSim: Double?
        let tiers: [TierResult]
    }
    struct TierResult: Encodable {
        let label: String
        let returnedCount: Int
        let underfilled: Bool
        let words: [Match]
    }
    struct Match: Encodable {
        let key: String
        let sim: Double
    }
}

private func collectBenchJSON(
    testCases: [(word: String, note: String)],
    embedding: NLEmbedding,
    keyVectors: [(key: String, vec: [Double], lemma: String)],
    stopwords: Set<String>,
    dict: MDictReader,
    allKeysCount: Int,
    vectorizedCount: Int,
    language: String
) -> BenchOutput {
    var results: [BenchOutput.QueryResult] = []
    results.reserveCapacity(testCases.count)

    for (word, _) in testCases {
        var qv: [Double]? = nil
        var qhit: String? = nil
        for c in candidateFormsExpanded(of: word) {
            if let v = embedding.vector(for: c) { qv = v; qhit = c; break }
        }
        guard let qv, let qhit else {
            results.append(BenchOutput.QueryResult(
                query: word, embeddedAs: nil, oov: true, maxSim: nil, tiers: []
            ))
            continue
        }
        let queryLemma = canonicalLemma(of: qhit)

        // Score → sort → lemma dedup → tier slice. Same pipeline as runOneMatrixCase.
        var scored: [(key: String, sim: Double, lemma: String)] = []
        scored.reserveCapacity(keyVectors.count)
        for (key, vec, lemma) in keyVectors {
            if stopwords.contains(key.lowercased()) { continue }
            scored.append((key, cosineSimilarity(qv, vec), lemma))
        }
        scored.sort { $0.sim > $1.sim }

        // Lemma dedup (query's lemma pre-inserted so morphological self-matches drop)
        var seenLemmas: Set<String> = [queryLemma]
        var deduped: [(key: String, sim: Double)] = []
        for item in scored {
            if seenLemmas.contains(item.lemma) { continue }
            seenLemmas.insert(item.lemma)
            deduped.append((item.key, item.sim))
        }

        var tierResults: [BenchOutput.TierResult] = []
        for tier in relatedTiers {
            var picks: [BenchOutput.Match] = []
            picks.reserveCapacity(tier.k)
            for item in deduped {
                if item.sim < tier.floor { break }
                if picks.count >= tier.k { break }
                picks.append(BenchOutput.Match(key: item.key, sim: item.sim))
            }
            tierResults.append(BenchOutput.TierResult(
                label: tier.label,
                returnedCount: picks.count,
                underfilled: picks.count < tier.k,
                words: picks
            ))
        }

        results.append(BenchOutput.QueryResult(
            query: word,
            embeddedAs: qhit,
            oov: false,
            maxSim: deduped.first?.sim,   // post-dedup max (skips morphological dupes)
            tiers: tierResults
        ))
    }

    let tierInfos = relatedTiers.map { BenchOutput.TierInfo(label: $0.label, k: $0.k, floor: $0.floor) }
    return BenchOutput(
        dict: BenchOutput.DictInfo(
            title: dict.metadata.title,
            path: dict.metadata.path,
            entryCount: allKeysCount,
            vectorizedCount: vectorizedCount,
            language: language
        ),
        tiers: tierInfos,
        results: results
    )
}

private func runOneMatrixCase(
    word: String, note: String,
    embedding: NLEmbedding,
    keyVectors: [(key: String, vec: [Double], lemma: String)],
    stopwords: Set<String>
) {
    print(colored("─── \(word) ───", .cyan), colored("(\(note))", .dim))

    // Query vector (with expanded lemma fallback for queries)
    var qv: [Double]? = nil
    var qhit: String? = nil
    for c in candidateFormsExpanded(of: word) {
        if let v = embedding.vector(for: c) { qv = v; qhit = c; break }
    }
    guard let qv, let qhit else {
        print(colored("  ✗ query OOV — skipping", .red))
        print()
        return
    }
    let queryLemma = canonicalLemma(of: qhit)

    // Score every keyword (skip stopwords). Self-skip happens via lemma dedup below.
    var scored: [(key: String, sim: Double, lemma: String)] = []
    scored.reserveCapacity(keyVectors.count)
    for (key, vec, lemma) in keyVectors {
        if stopwords.contains(key.lowercased()) { continue }
        scored.append((key, cosineSimilarity(qv, vec), lemma))
    }
    scored.sort { $0.sim > $1.sim }

    // Lemma dedup pass — seed with the query's lemma so "loans" → top "loan"
    // is suppressed. Within results, "myth" + "myths" collapse to the higher-sim one.
    var seenLemmas: Set<String> = [queryLemma]
    var deduped: [(String, Double)] = []
    for item in scored {
        if seenLemmas.contains(item.lemma) { continue }
        seenLemmas.insert(item.lemma)
        deduped.append((item.key, item.sim))
    }
    // From here on, work with deduped list; tier slicing is just floor + prefix.
    let resultList = deduped

    // Top-20 reference list (so we can see the actual similarity distribution)
    print(colored("  Top 20 (lemma-deduped, reference):", .yellow))
    let top20 = Array(resultList.prefix(20))
    for chunk in top20.chunked(into: 4) {
        let cells = chunk.map { "\(padded($0.0, 14)) \(colored(String(format: "(%.3f)", $0.1), .dim))" }
        print("    " + cells.joined(separator: "  "))
    }

    // By tier — what each user-facing setting would actually return.
    // Single-pass: filter floor, take prefix(k). Under-fill OK (scheme X).
    print(colored("  By tier (algorithm = top-K with floor):", .yellow))
    for tier in relatedTiers {
        let passing = resultList.lazy.filter { $0.1 >= tier.floor }.prefix(tier.k).map { $0 }
        let count = passing.count
        let label = colored(padded("\(tier.label) (K=\(tier.k), ≥\(String(format: "%.2f", tier.floor)))", 28), .green)
        let returned = colored("[\(count)/\(tier.k)]", count == tier.k ? .dim : .yellow)
        if passing.isEmpty {
            print("    \(label) \(returned)  \(colored("(none — under-filled)", .red))")
        } else {
            let words = passing.map { $0.0 }.joined(separator: " · ")
            print("    \(label) \(returned)  \(words)")
        }
    }
    print()
}

private func printMatrixSummary(
    embedding: NLEmbedding,
    keyVectors: [(key: String, vec: [Double], lemma: String)],
    stopwords: Set<String>,
    testCases: [(word: String, note: String)]
) {
    print(colored("═══ Summary: actual returned count per tier ═══", .bold))
    print(colored("  (under-fill marked in yellow — query couldn't fill K at this floor)", .dim))
    print()

    // Header row
    let caseCol = padded("case", 14)
    let tierCols = relatedTiers.map { padded("\($0.label) /\($0.k)", 12) }.joined()
    print("  " + caseCol + tierCols)
    print("  " + String(repeating: "─", count: 14 + relatedTiers.count * 12))

    for (word, _) in testCases {
        var qv: [Double]? = nil
        var qhit: String? = nil
        for c in candidateFormsExpanded(of: word) {
            if let v = embedding.vector(for: c) { qv = v; qhit = c; break }
        }
        guard let qv, let qhit else {
            print("  " + padded(word, 14) + colored("(OOV)", .dim))
            continue
        }
        let queryLemma = canonicalLemma(of: qhit)

        // Same path as runOneMatrixCase: score → sort → lemma dedup → tier slice
        var scored: [(sim: Double, lemma: String)] = []
        scored.reserveCapacity(keyVectors.count)
        for (key, vec, lemma) in keyVectors {
            if stopwords.contains(key.lowercased()) { continue }
            scored.append((cosineSimilarity(qv, vec), lemma))
        }
        scored.sort { $0.sim > $1.sim }

        var seenLemmas: Set<String> = [queryLemma]
        var dedupedSims: [Double] = []
        for item in scored {
            if seenLemmas.contains(item.lemma) { continue }
            seenLemmas.insert(item.lemma)
            dedupedSims.append(item.sim)
        }

        var row = padded(word, 14)
        for tier in relatedTiers {
            let n = min(tier.k, dedupedSims.lazy.filter { $0 >= tier.floor }.count)
            let cell = "\(n)/\(tier.k)"
            row += padded(n < tier.k ? colored(cell, .yellow) : cell, 12 + (n < tier.k ? colored("", .yellow).count : 0))
        }
        print("  " + row)
    }
    print()
}

/// Pad a string to a fixed width (right-pad with spaces). For column alignment.
private func padded(_ s: String, _ width: Int) -> String {
    if s.count >= width { return s }
    return s + String(repeating: " ", count: width - s.count)
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - Candidate forms

/// Reused across the scan — NLTagger init is expensive enough that calling it
/// per-keyword (159k times) dominated the Step 0 probe.  Single-threaded CLI
/// so no lock needed; revisit if we ever parallelize this.
/// `nonisolated(unsafe)` because NLTagger isn't Sendable in Swift 6 but the
/// CLI is genuinely single-threaded here.
nonisolated(unsafe) private let sharedLemmaTagger: NLTagger = NLTagger(tagSchemes: [.lemma])

/// EXPANDED: always try lemma fallback. Use for USER QUERIES — "ran" → "run".
private func candidateFormsExpanded(of word: String) -> [String] {
    let lower = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !lower.isEmpty else { return [] }
    var out = [lower]
    extractLemmas(into: &out, lower: lower)
    return out
}

/// CONSERVATIVE: lemma fallback ONLY for plain alphabetic single tokens.
/// Multi-word phrases ("back down"), hyphenated ("happy-go-lucky"), contractions
/// ("don't"), and anything with digits keep raw form only — preventing the
/// "all 4 'back X' phrases get back's vector" bug seen in Step 0.
private func candidateFormsConservative(of word: String) -> [String] {
    let lower = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !lower.isEmpty else { return [] }
    var out = [lower]
    // `.isLetter` is true for ASCII letters, accented Latin, AND CJK — all fine.
    // It's false for space, hyphen, apostrophe, digit, punct — which is what we want.
    if lower.allSatisfy(\.isLetter) {
        extractLemmas(into: &out, lower: lower)
    }
    return out
}

/// Single canonical lemma for dedup purposes. Returns the NLTagger lemma if
/// available, else the input itself. Multi-word / non-letter strings stay as-is
/// (we don't want "back down" lemmatized to "back").
///
/// Used to suppress morphological duplicates in the result set:
///   query "loans" → lemma "loan"  → skip "loan" result + skip "loans" result
///   results "myth" + "myths" in top-K → keep only the higher-sim one
private func canonicalLemma(of word: String) -> String {
    let lower = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if lower.isEmpty { return lower }
    if !lower.allSatisfy(\.isLetter) { return lower }
    var forms = [lower]
    extractLemmas(into: &forms, lower: lower)
    // extractLemmas appends the lemma at the end (after the raw form) if found.
    return forms.last ?? lower
}

/// Shared lemma extraction. Wraps input in "I <word>" for verb-form disambiguation.
private func extractLemmas(into out: inout [String], lower: String) {
    let sentence = "I \(lower)"
    sharedLemmaTagger.string = sentence
    sharedLemmaTagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lemma) { tag, range in
        let token = String(sentence[range]).lowercased()
        if token != "i", let tag {
            let lemma = tag.rawValue.lowercased()
            if !lemma.isEmpty, lemma != lower, !out.contains(lemma) {
                out.append(lemma)
            }
        }
        return true
    }
}

// MARK: - Language detection

/// Stride-sample ~200 keywords, run NLLanguageRecognizer on their concatenation,
/// return dominant language constrained to the set NLEmbedding actually supports.
/// Returns `.english` as a safe default if recognition fails.
private func detectKeywordLanguage(dict: MDictReader, sampleSize: Int = 200) -> NLLanguage {
    let allKeys = dict.allKeys
    guard !allKeys.isEmpty else { return .english }

    let step = max(1, allKeys.count / sampleSize)
    var sample: [String] = []
    sample.reserveCapacity(sampleSize)
    var i = 0
    while i < allKeys.count && sample.count < sampleSize {
        sample.append(allKeys[i])
        i += step
    }

    let recognizer = NLLanguageRecognizer()
    // Constrain to languages with NLEmbedding word-level coverage. Listing them
    // as hints (not constraints) — constraints would force a pick from this set,
    // which is what we want, but the hints API is `processString` + dominantLanguage.
    recognizer.languageHints = [
        .english: 0.3, .spanish: 0.1, .french: 0.1, .german: 0.1,
        .italian: 0.1, .portuguese: 0.1, .russian: 0.1,
        .japanese: 0.1, .korean: 0.1,
        .simplifiedChinese: 0.1, .traditionalChinese: 0.1
    ]
    recognizer.processString(sample.joined(separator: " "))
    return recognizer.dominantLanguage ?? .english
}

// MARK: - Stopwords

/// Stopwords to suppress from the dict-restricted top-K. Generic high-frequency
/// words (functional and common adverbs) get NLEmbedding vectors that sit near
/// the centroid of the vector space, making them spuriously "close" to many
/// queries. Removing them dramatically improves perceived quality.
///
/// English list mirrors LemmaResolver.englishStopwords with additions for
/// adverbs that showed up as noise in Step 0 ("really", "just", "always", ...).
private func stopwordsFor(_ lang: NLLanguage) -> Set<String> {
    if lang == .english { return englishStopwords }
    // CJK / others: no curated list yet. Empty set = no filtering.
    // This is fine for early probe; revisit when we ship.
    return []
}

private let englishStopwords: Set<String> = [
    // Determiners / articles
    "the", "a", "an", "this", "that", "these", "those",
    "my", "your", "his", "her", "its", "our", "their",
    // Prepositions
    "to", "of", "in", "on", "at", "for", "with", "from",
    "by", "about", "into", "through", "during", "before",
    "after", "above", "below", "between", "under", "over",
    // Auxiliaries / modals
    "is", "am", "are", "was", "were", "be", "been", "being",
    "do", "does", "did",
    "have", "has", "had",
    "will", "would", "shall", "should",
    "can", "could", "may", "might", "must",
    // Pronouns
    "i", "me", "you", "he", "him", "she", "we", "us", "they", "them",
    "it", "who", "whom", "what", "which",
    // Conjunctions / particles
    "and", "or", "but", "not", "no", "if", "so", "as", "than",
    // High-frequency adverbs / quantifiers that polluted Step 0 results
    "really", "just", "always", "very", "also", "still", "yet",
    "even", "only", "ever", "never", "many", "much", "more", "most",
    "such", "some", "any", "all", "each", "every", "both",
    "now", "then", "here", "there", "when", "where", "why", "how",
    "thing", "things", "way", "ways"
]

// MARK: - Math

/// Plain cosine similarity.  300-dim vectors so the loop is short; no
/// Accelerate import here — keep the probe self-contained.
private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
    precondition(a.count == b.count, "dim mismatch")
    var dot = 0.0
    var na = 0.0
    var nb = 0.0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let denom = sqrt(na) * sqrt(nb)
    return denom == 0 ? 0 : dot / denom
}

// MARK: - Phase 2 perf probe: NLEmbedding.neighbors() latency

/// `openmdict neighbors-bench` — measure `NLEmbedding.wordEmbedding(for:).neighbors`
/// latency across a representative CEFR-stratified set. Designed to settle the
/// Phase 2 design question: can we drop our per-dict vector cache and call
/// NLEmbedding at query time instead?
///
/// Output is per-query latency stats (min / p50 / mean / p95 / p99 / max).
/// Decision gate is **p95 < 200 ms** for Option C (drop cache); above that we
/// fall back to Option A (folded per-language cache).
///
/// Caveat: runs on the dev machine (Mac), which has more CPU than any iOS
/// target. As a rule of thumb, expect iOS to be 2–4× slower depending on
/// the device tier. The bench output annotates this so the reader can
/// translate the number.
func handleNeighborsBench(args: [String]) {
    var wordsFile: String? = nil
    var langArg = "en"
    var maxNeighbors = 500
    var passes = 3
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--words-file":
            guard i + 1 < args.count else { eprintln("--words-file needs a path"); exit(1) }
            wordsFile = args[i + 1]; i += 2
        case "--lang":
            guard i + 1 < args.count else { eprintln("--lang needs a value"); exit(1) }
            langArg = args[i + 1]; i += 2
        case "--max-neighbors":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else {
                eprintln("--max-neighbors needs an integer"); exit(1)
            }
            maxNeighbors = n; i += 2
        case "--passes":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else {
                eprintln("--passes needs an integer"); exit(1)
            }
            passes = n; i += 2
        default:
            eprintln("Unknown flag: \(args[i])"); exit(1)
        }
    }

    let lang = NLLanguage(rawValue: langArg)
    let words: [String]
    if let path = wordsFile {
        words = loadNeighborsBenchWords(from: path)
    } else {
        words = defaultNeighborsBenchWords
    }

    print()
    print(colored("🧪 NLEmbedding.neighbors() latency probe", .bold))
    print("  language:       \(lang.rawValue)")
    print("  maxNeighbors:   \(maxNeighbors)")
    print("  source set:     \(wordsFile ?? "(built-in 30-word CEFR-stratified set)")")
    print("  N queries:      \(words.count)  × passes \(passes) = \(words.count * passes) samples")
    print()

    let t0 = CFAbsoluteTimeGetCurrent()
    guard let embedding = NLEmbedding.wordEmbedding(for: lang) else {
        eprintln(colored("Error: NLEmbedding has no word model for '\(langArg)'", .red))
        eprintln("Built-in coverage: en, es, fr, de, it, pt, ru, ja, ko, zh-Hans, zh-Hant")
        exit(1)
    }
    let embLoadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print("  embedding loaded in \(String(format: "%.1f", embLoadMs)) ms")
    print("  vocab size:     \(embedding.vocabularySize)")
    print("  dimension:      \(embedding.dimension)")
    print()

    // Warm-up pass — the very first .neighbors() call may pay one-time
    // initialization costs that we don't want polluting our stats.
    print(colored("Warming up …", .dim))
    var oovCount = 0
    var maxObservedNeighbors = 0
    for w in words {
        let result = embedding.neighbors(for: w.lowercased(), maximumCount: maxNeighbors)
        if result.isEmpty { oovCount += 1 }
        maxObservedNeighbors = max(maxObservedNeighbors, result.count)
    }
    // Sanity-check the cap: if asking for 500 but never got more than ~50
    // neighbors back, NLEmbedding is filtering by an implicit max distance.
    // The bound matters for Option C (do we have enough candidates to
    // filter by dict membership and still hit tier.k=48?).
    if maxObservedNeighbors < maxNeighbors {
        print(colored("  Note: max observed neighbors per query = \(maxObservedNeighbors)", .yellow))
        print(colored("  (asked for \(maxNeighbors); NLEmbedding applies an internal distance threshold ≈1.0)", .yellow))
        print(colored("  This isn't a hard problem for Option C: 50 candidates per query is", .dim))
        print(colored("  plenty after dict-membership filter to fill tier.k = 12 / 24 / 48.", .dim))
    }
    if oovCount > 0 {
        print(colored("  (\(oovCount) of \(words.count) queries OOV — no neighbors returned)", .dim))
    }

    // Timed passes
    print(colored("Benching …", .dim))
    var latenciesMs: [Double] = []
    latenciesMs.reserveCapacity(words.count * passes)
    var sampleResults: [(word: String, ms: Double, count: Int)] = []
    for pass in 0..<passes {
        for w in words {
            let lower = w.lowercased()
            let t = CFAbsoluteTimeGetCurrent()
            let neighbors = embedding.neighbors(for: lower, maximumCount: maxNeighbors)
            let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
            latenciesMs.append(ms)
            if pass == 0, sampleResults.count < 5 {
                sampleResults.append((w, ms, neighbors.count))
            }
        }
    }

    // Stats
    let sorted = latenciesMs.sorted()
    func pct(_ p: Double) -> Double {
        let i = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return sorted[i]
    }
    let mean = latenciesMs.reduce(0, +) / Double(latenciesMs.count)
    let minLat = sorted.first ?? 0
    let maxLat = sorted.last ?? 0
    let p50 = pct(0.50)
    let p95 = pct(0.95)
    let p99 = pct(0.99)

    print()
    print(colored("Sample queries (first 5 of pass 1):", .yellow))
    for s in sampleResults {
        print("    \(padded(s.word, 20)) → \(String(format: "%6.2f", s.ms)) ms (\(s.count) neighbors)")
    }

    print()
    print(colored("Latency statistics  (\(latenciesMs.count) samples)", .bold))
    print("  min:            \(String(format: "%6.2f", minLat)) ms")
    print("  p50 (median):   \(String(format: "%6.2f", p50)) ms")
    print("  mean:           \(String(format: "%6.2f", mean)) ms")
    print("  p95:            \(String(format: "%6.2f", p95)) ms")
    print("  p99:            \(String(format: "%6.2f", p99)) ms")
    print("  max:            \(String(format: "%6.2f", maxLat)) ms")
    print()

    // Decision gate
    let gateMs = 200.0
    let macToIosFactor = 3.0   // rough rule of thumb; A15+ closer to 2×, A12 closer to 4×
    let estimatedIosP95 = p95 * macToIosFactor
    print(colored("Decision gate (Phase 2 plan):", .bold))
    print("  Mac p95         = \(String(format: "%.1f", p95)) ms")
    print("  Est. iOS p95    ≈ \(String(format: "%.1f", estimatedIosP95)) ms  (Mac × \(String(format: "%.0f", macToIosFactor)), rough)")
    print()
    if estimatedIosP95 < gateMs {
        print(colored("  ✓ p95 estimate (\(String(format: "%.1f", estimatedIosP95)) ms) is well under \(Int(gateMs)) ms.", .green))
        print(colored("    → Option C (no vector cache, call neighbors at query time) is viable.", .green))
    } else if estimatedIosP95 < gateMs * 1.5 {
        print(colored("  ⚠ p95 estimate (\(String(format: "%.1f", estimatedIosP95)) ms) is in the borderline zone.", .yellow))
        print(colored("    → Recommend an on-device measurement before committing to Option C.", .yellow))
    } else {
        print(colored("  ✗ p95 estimate (\(String(format: "%.1f", estimatedIosP95)) ms) is well over \(Int(gateMs)) ms.", .red))
        print(colored("    → Option A (folded per-language cache) is the safer bet.", .red))
    }
    print()
}

/// Built-in 30-word CEFR-stratified probe set. Mix of common (A1–A2),
/// mid-range (B1–B2), academic / rare (C1–C2), and a handful of NLEmbedding
/// OOV (callipygian, sesquipedalian) so the bench exercises both
/// hot-path and edge-case paths.
private let defaultNeighborsBenchWords: [String] = [
    // A1 / A2 — common
    "happy", "sad", "run", "walk", "eat", "sleep", "house", "car",
    "weekend", "family", "kitchen", "garden",
    // B1 / B2 — mid frequency
    "contemplate", "persuade", "contain", "ambiguous",
    "candid", "profound", "vigilant",
    // C1 / C2 — academic
    "cogent", "ostensible", "vehement", "succinct",
    "lugubrious", "perspicacious", "perfidious",
    // OOV / rare — exercise the "no neighbors" path
    "sesquipedalian", "callipygian", "eldritch", "antediluvian",
]

private func loadNeighborsBenchWords(from path: String) -> [String] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        eprintln("Cannot read words file: \(path)")
        exit(1)
    }
    return content
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}
