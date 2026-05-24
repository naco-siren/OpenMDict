//
//  SemanticSearchService.swift
//  OpenMDict-iOS
//
//  M15 Phase 1 — NLEmbedding-backed semantic neighbor lookup.
//
//  Architecture: per-dict vector cache, lazily populated. First call to
//  `relatedKeywords` for a given dict triggers a Task.detached pre-scan
//  (~2.5s for 10k keywords). Subsequent queries hit the in-memory cache
//  with just a cosine sweep + sort + lemma dedup → <100ms typical.
//
//  Algorithm (mirrors the CLI semantic-bench probe, validated against the
//  Kangoo et al. ESL dataset + Ogden Basic English):
//
//    1. Per-dict vectors: for each keyword, take the conservative candidate
//       form (raw, plus NLTagger lemma only for plain-alphabetic tokens) and
//       store its NLEmbedding vector + canonical lemma.
//    2. At query time: expand the query's lemmas, look up its vector, then
//       for every cached entry compute cosine sim.
//    3. Sort descending, lemma-dedup (seed seen-set with query's own lemma
//       so morphological self-matches like loans→loan get suppressed).
//    4. Filter by tier's floor (0.45 uniform in Plan B), take prefix(k).
//
//  Cross-group: caller passes [MDictReader], each contributes from its own
//  NLEmbedding language space (auto-detected per dict during preload). Only
//  dicts whose detected language matches the query's available NLEmbedding
//  vector contribute. Per-dict lemma dedup so identical lemmas in different
//  dicts both surface.
//

import Foundation
import NaturalLanguage
import OpenMDict
import OpenMDictKit

// MARK: - Public input / output

/// Caller-supplied (id, reader) pair. The id is whatever string the caller
/// uses elsewhere in the app to refer to the dictionary (in OpenMDict-iOS
/// that's `MDict.id` — usually the storage directory's SHA256 for imported
/// dicts, but filename-based for some bundled/preset paths). We trust the
/// caller's id rather than re-deriving from `MDictReader.metadata.headerSHA256`
/// so result.dictId always round-trips to whatever lookup table the caller
/// is using for navigation.
struct SemanticDictRef: Sendable {
    let id: String
    let reader: MDictReader
}

/// One semantic neighbor returned by the service.
struct SemanticMatch: Sendable, Hashable {
    /// Display form of the dict keyword that matched (preserving original case).
    let key: String
    /// Caller-supplied dictionary id (from `SemanticDictRef.id`). Round-trips
    /// directly into `WordDisplayItem.dictId` so taps route correctly.
    let dictId: String
    /// Cosine similarity in the dict's NLEmbedding language space (0…1).
    let similarity: Double
}

// MARK: - Service

@MainActor
final class SemanticSearchService {

    static let shared = SemanticSearchService()
    private init() { /* observers wired up by Step 1.5 (mem warning, settings) */ }

    // MARK: - Cache

    /// Pre-scanned vectors for a single dict. Immutable after construction
    /// so we can hand it across actor boundaries safely (it's a struct of value
    /// types + Sendable arrays).
    private struct DictVectors: Sendable {
        let dictId: String
        let language: NLLanguage
        let entries: [VectorEntry]
    }

    struct VectorEntry: Sendable {
        let key: String        // original display form (preserves case)
        let keyLower: String   // lowercased — used for stopword + trivial dedup
        let vec: [Double]
        // No `lemma` field: lemma extraction is ~50–100µs per call via
        // NLTagger and pre-computing it across millions of keywords blew the
        // pre-scan budget (60s+ wall clock on a 13-dict group). We now compute
        // lemmas lazily at query time — only for the ~K candidates that
        // actually make it through floor + take-K, ~50 calls per query.
    }

    private var cache: [String: DictVectors] = [:]
    /// De-duplicates concurrent preloads of the same dict. Multiple awaiters
    /// share one in-flight Task.
    private var inFlight: [String: Task<DictVectors?, Never>] = [:]

    // MARK: - Public API

    /// Cross-group semantic search. Each supplied dict contributes neighbors
    /// from its own NLEmbedding language space; results merge into one sorted
    /// list, lemma-deduped per-dict, capped at `tier.k` total.
    ///
    /// Slow path: preloads any dicts not yet in cache (parallel). Subsequent
    /// queries hit cache.
    func relatedKeywords(query: String,
                         in dicts: [SemanticDictRef],
                         tier: RelatedWordsTier) async -> [SemanticMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !dicts.isEmpty else { return [] }

        // Entry log — useful when the per-dict preload logs below stay quiet
        // because everything was already cached and we'd otherwise have zero
        // diagnostic output between the session's `🧠 Semantic '...'` line and
        // the eventual match count.
        let totalCached = dicts.filter { cache[$0.id] != nil }.count
        print("🧠 relatedKeywords: \(dicts.count) dicts (\(totalCached) cached, \(dicts.count - totalCached) to preload)")

        // Preload all dicts in parallel. Each preload de-dupes against any
        // already-in-flight scan, and noop's if the cache hit already exists.
        let t0 = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { group in
            for ref in dicts {
                group.addTask { [weak self] in
                    await self?.preload(ref: ref)
                }
            }
        }
        let preloadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if preloadMs > 50 {
            print("🧠 preload wave done in \(String(format: "%.0f", preloadMs)) ms")
        }

        // Snapshot the per-dict caches we'll work against (after preloads).
        let snapshots: [DictVectors] = dicts.compactMap { cache[$0.id] }
        guard !snapshots.isEmpty else { return [] }

        // Heavy compute (cosine + sort + dedup) detaches off main so a 5-dict
        // group query (~500ms) doesn't stall the search-bar typing pipeline.
        return await Task.detached { [trimmed, tier] in
            Self.computeMatches(query: trimmed, snapshots: snapshots, tier: tier)
        }.value
    }

    /// Single-dict convenience. Forwards to the cross-group variant.
    func relatedKeywords(query: String,
                         in dict: SemanticDictRef,
                         tier: RelatedWordsTier) async -> [SemanticMatch] {
        await relatedKeywords(query: query, in: [dict], tier: tier)
    }

    /// Pre-warm the vector cache for `ref`. Called explicitly e.g. when the
    /// user is reading an article (we can anticipate they may flip to semantic
    /// scope). Concurrent calls for the same dict id share one underlying scan.
    func preload(ref: SemanticDictRef) async {
        if cache[ref.id] != nil { return }

        if let existing = inFlight[ref.id] {
            _ = await existing.value
            return
        }

        // Diagnostic — first-time preload on a big dict can take many seconds
        // in debug builds. Surface progress so users / devs don't think it
        // hung silently.
        let title = ref.reader.metadata.title ?? "(no title)"
        let keyCount = ref.reader.allKeys.count
        print("🧠 Preloading vectors: '\(title)' (\(keyCount) keys)")
        let t0 = CFAbsoluteTimeGetCurrent()

        let task = Task.detached { [ref] () -> DictVectors? in
            Self.computeVectors(for: ref)
        }
        inFlight[ref.id] = task
        let vectors = await task.value
        inFlight[ref.id] = nil
        if let vectors {
            cache[ref.id] = vectors
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("🧠   ✓ '\(title)': \(vectors.entries.count) / \(keyCount) vectorized in \(String(format: "%.0f", ms)) ms (lang=\(vectors.language.rawValue))")
        } else {
            print("🧠   ✗ '\(title)': preload failed (no NLEmbedding for detected language?)")
        }
    }

    /// Drop all cached vectors. Wire to `UIApplication.didReceiveMemoryWarning`
    /// once Step 1.5 lands.
    func evictAll() {
        cache.removeAll()
    }

    /// Drop a single dict's cache (e.g. when the dict is unloaded by the user
    /// or removed via iCloud delete).
    func evict(dictId: String) {
        cache[dictId] = nil
    }

    // MARK: - Compute (background-safe)

    /// Scan a dict's keywords, compute their NLEmbedding vectors, and return
    /// the cache payload. Returns nil if language detection or NLEmbedding
    /// loading fails.
    ///
    /// Hot loop intentionally does NOT call NLTagger — that's where the bulk
    /// of pre-scan cost came from. Lemma-aware dedup happens at query time
    /// instead, over the small set of candidates that survive sort + floor.
    nonisolated private static func computeVectors(for ref: SemanticDictRef) -> DictVectors? {
        let dict = ref.reader
        let language = Self.detectKeywordLanguage(dict: dict)
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else {
            return nil   // No NLEmbedding model for this language
        }

        let allKeys = dict.allKeys
        var entries: [VectorEntry] = []
        entries.reserveCapacity(allKeys.count)
        // Cooperative cancellation: if the user types another query (or flips
        // scope back to spelling) while a big dict is mid-scan, the surrounding
        // detached task gets cancelled. Bail out promptly rather than running
        // the loop to completion just to throw the result away.
        for (i, key) in allKeys.enumerated() {
            if i & 0x3FF == 0, Task.isCancelled { return nil }   // check every 1024 keys
            let lower = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if lower.isEmpty { continue }
            // Single hash lookup — NLEmbedding's vocabulary covers most
            // inflected forms directly ("ran" + "run" both have vectors),
            // so skipping lemma fallback here costs us only a few percent
            // of coverage on rare inflections and saves 60×+ on pre-scan.
            guard let vec = embedding.vector(for: lower) else { continue }
            entries.append(VectorEntry(key: key, keyLower: lower, vec: vec))
        }
        return DictVectors(dictId: ref.id, language: language, entries: entries)
    }

    /// Score → sort → lemma-dedup → floor + take-K. Called from a detached
    /// Task so it's nonisolated and pure on its inputs.
    nonisolated private static func computeMatches(query: String,
                                                   snapshots: [DictVectors],
                                                   tier: RelatedWordsTier) -> [SemanticMatch] {
        // For each dict's language, try to embed the query (with lemma expansion).
        // Cache embeddings per language so cross-group with 5 dicts in the same
        // language only does the lookup once.
        var queryVecByLang: [NLLanguage: (vec: [Double], hit: String)] = [:]
        var loadedEmbeddings: [NLLanguage: NLEmbedding] = [:]
        let tagger = NLTagger(tagSchemes: [.lemma])

        for snap in snapshots {
            if queryVecByLang[snap.language] != nil { continue }
            guard let embedding = NLEmbedding.wordEmbedding(for: snap.language) else { continue }
            loadedEmbeddings[snap.language] = embedding
            for c in Self.candidateFormsExpanded(query, tagger: tagger) {
                if let v = embedding.vector(for: c) {
                    queryVecByLang[snap.language] = (v, c)
                    break
                }
            }
        }
        guard !queryVecByLang.isEmpty else { return [] }   // Query OOV everywhere

        // Build the lemma-dedup seed set once per query: the query's lemma in
        // every embedded language (different languages may produce different
        // lemmas for the same query text).
        var queryLemmas: Set<String> = []
        for (_, hit) in queryVecByLang {
            queryLemmas.insert(Self.canonicalLemma(hit.hit, tagger: tagger))
        }

        // GLOBAL TOP-K of unique words. The UI surfaces the candidate set as a
        // single deduplicated "you might mean…" list (one row per word, no
        // dictionary tag); tapping a candidate then routes to either article
        // navigation (single-dict context) or a per-dict lookup of that word
        // (group context). So per-dict contribution doesn't matter at this
        // layer — we want the K best UNIQUE WORDS across the whole group.
        //
        // Algorithm: score every entry from every matching-language dict into
        // one merged list, sort descending, walk top-down with three dedup
        // gates (query lemma, case-folded word, NLTagger lemma) until we've
        // collected `tier.k` candidates or run below the floor.
        struct ScoredHit {
            let key: String
            let keyLower: String
            let sim: Double
        }
        var scored: [ScoredHit] = []
        scored.reserveCapacity(snapshots.reduce(0) { $0 + $1.entries.count })

        for snap in snapshots {
            guard let (qv, _) = queryVecByLang[snap.language] else { continue }
            let stopwords = Self.stopwordsFor(snap.language)
            for e in snap.entries {
                if stopwords.contains(e.keyLower) { continue }
                let sim = Self.cosineSimilarity(qv, e.vec)
                scored.append(ScoredHit(key: e.key, keyLower: e.keyLower, sim: sim))
            }
        }
        scored.sort { $0.sim > $1.sim }

        // Walk + dedup. `dictId` on SemanticMatch is now empty — the UI doesn't
        // need it (candidates are displayed as bare words and tap routing uses
        // the search context, not the source dict).
        var seenWords: Set<String> = []
        var seenLemmas: Set<String> = queryLemmas
        var picks: [SemanticMatch] = []
        picks.reserveCapacity(tier.k)
        for hit in scored {
            if hit.sim < tier.floor { break }
            if picks.count >= tier.k { break }
            if seenWords.contains(hit.keyLower) { continue }
            let lemma = Self.canonicalLemma(hit.key, tagger: tagger)
            if seenLemmas.contains(lemma) { continue }
            seenWords.insert(hit.keyLower)
            seenLemmas.insert(lemma)
            picks.append(SemanticMatch(key: hit.key, dictId: "", similarity: hit.sim))
        }
        return picks
    }

    // MARK: - Language detection

    /// Auto-detect a dict's keyword language by sampling ~200 keywords and
    /// running them through NLLanguageRecognizer. Constrained via hints to
    /// the set of languages NLEmbedding actually has word-level coverage for.
    nonisolated private static func detectKeywordLanguage(dict: MDictReader,
                                                          sampleSize: Int = 200) -> NLLanguage {
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
        recognizer.languageHints = [
            .english: 0.3, .spanish: 0.1, .french: 0.1, .german: 0.1,
            .italian: 0.1, .portuguese: 0.1, .russian: 0.1,
            .japanese: 0.1, .korean: 0.1,
            .simplifiedChinese: 0.1, .traditionalChinese: 0.1,
        ]
        recognizer.processString(sample.joined(separator: " "))
        return recognizer.dominantLanguage ?? .english
    }

    // MARK: - Lemma helpers

    /// Aggressive: always try NLTagger lemma fallback. Used for the user's QUERY
    /// (so "ran" → "run" / "running" all find their canonical vector).
    nonisolated private static func candidateFormsExpanded(_ word: String, tagger: NLTagger) -> [String] {
        let lower = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return [] }
        var out = [lower]
        Self.extractLemmas(into: &out, lower: lower, tagger: tagger)
        return out
    }

    /// One canonical lemma for dedup — last element of the candidate list, which
    /// is the NLTagger lemma if one was returned, else the raw lower form.
    nonisolated private static func canonicalLemma(_ word: String, tagger: NLTagger) -> String {
        let lower = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return lower }
        if !lower.allSatisfy(\.isLetter) { return lower }
        var forms = [lower]
        Self.extractLemmas(into: &forms, lower: lower, tagger: tagger)
        return forms.last ?? lower
    }

    /// Wraps input in "I <word>" for verb-form disambiguation context.
    nonisolated private static func extractLemmas(into out: inout [String],
                                                  lower: String,
                                                  tagger: NLTagger) {
        let sentence = "I \(lower)"
        tagger.string = sentence
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex,
                             unit: .word, scheme: .lemma) { tag, range in
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

    // MARK: - Stopwords

    /// Per-language stopword set. Returns empty for languages where we haven't
    /// curated a list yet (so non-English semantic search returns raw results,
    /// which is still better than nothing).
    nonisolated private static func stopwordsFor(_ lang: NLLanguage) -> Set<String> {
        if lang == .english { return englishStopwords }
        return []
    }

    /// English stopwords + generic high-frequency adverbs that NLEmbedding gives
    /// near-centroidal vectors to. Mirrors the CLI probe's set (which is in turn
    /// `LemmaResolver.englishStopwords` + the adverb extensions we found polluted
    /// Step 0 results).
    nonisolated private static let englishStopwords: Set<String> = [
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
        // Generic referents — NLEmbedding gives these near-centroidal vectors
        // that "look close" to almost anything. Found via the "happy → 10×
        // something" dogfood case.
        "thing", "things", "stuff", "way", "ways",
        "something", "anything", "everything", "nothing",
        "someone", "anyone", "everyone",
        "somebody", "anybody", "everybody", "nobody",
    ]

    // MARK: - Math

    /// Plain cosine similarity. 300-dim NLEmbedding vectors so the inner loop
    /// is short; revisit with `Accelerate.vDSP_dotpr` if we ever hit a perf wall.
    nonisolated private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count, "dim mismatch")
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        return denom == 0 ? 0 : dot / denom
    }
}
