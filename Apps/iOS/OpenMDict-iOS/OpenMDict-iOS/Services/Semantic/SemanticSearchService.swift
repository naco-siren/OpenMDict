//
//  SemanticSearchService.swift
//  OpenMDict-iOS
//
//  M15 Phase 2 — NLEmbedding-direct semantic neighbor lookup. No per-dict
//  vector cache. Decided after the `openmdict neighbors-bench` perf probe
//  showed `NLEmbedding.neighbors(for:maximumCount:)` at p95 ≈ 1 ms on Mac
//  / ~3 ms estimated iOS, leaving a 50× margin under the Phase 2 design
//  gate of 200 ms.
//
//  Old (Phase 1) architecture maintained a `[dictId: DictVectors]` cache
//  with one `[Double]` (300 dims = 2.4 KB) per vectorized keyword. On a
//  13-dict group this ballooned RAM from ~300 MB baseline to >1 GB — an
//  occasional jetsam kill. Phase 2 deletes that entire layer.
//
//  Per-query path now is:
//
//    1. Group active dicts by detected keyword language (one-time per-dict
//       detection cached at the service level — a couple hundred bytes
//       total, vs the ~845 MB the vector cache used).
//    2. For each language in the active set, hand the query to
//       `NLEmbedding.wordEmbedding(for: lang).neighbors(for:maximumCount:)`
//       (with the existing query-side lemma expansion so "ran" → "run").
//       The framework already has the vocab + vectors loaded internally
//       and returns up to ~50 closest neighbors via its built-in distance
//       threshold.
//    3. Filter the neighbors to those that exist as keywords in at least
//       one dict in the group (cheap O(log N) `MDictReader.lookup`).
//    4. Merge across languages, sort by similarity, lemma-dedup with the
//       query's own lemma seeded, take the user's tier.k.
//
//  Stopword filter + cross-dict word/lemma dedup logic carry over from
//  Phase 1 unchanged.
//

import Foundation
import NaturalLanguage
import OpenMDict
import OpenMDictKit

// MARK: - Public input / output

/// Caller-supplied (id, reader) pair. The id is whatever string the caller
/// uses elsewhere in the app to refer to the dictionary (in OpenMDict-iOS
/// that's `MDict.id` — the SHA256 of the MDX header for imported dicts).
/// The service round-trips this id back through `SemanticMatch.dictId` so
/// taps in the UI can route to the right dict.
struct SemanticDictRef: Sendable {
    let id: String
    let reader: MDictReader
}

/// One semantic neighbor returned by the service.
struct SemanticMatch: Sendable, Hashable {
    /// Display form of the dict keyword that matched. Preserves original case
    /// as the dict stored it (e.g. "Nice" vs "nice").
    let key: String
    /// Caller-supplied dictionary id. Empty in Phase 2 since the candidate
    /// list is deduped to one row per unique word and the UI doesn't surface
    /// a "from dict X" tag — tap routing uses the active SearchContext, not
    /// the source dict.
    let dictId: String
    /// Cosine similarity in [0, 1], converted from NLEmbedding's cosine
    /// distance metric (`sim = 1 - distance / 2`). Higher = closer.
    let similarity: Double
}

// MARK: - Service

@MainActor
final class SemanticSearchService {

    static let shared = SemanticSearchService()
    private init() {}

    /// Per-dict detected keyword language. Computed lazily on first sight of
    /// a dict and never invalidated; MDX content (and therefore detected
    /// language) doesn't change for a given dictId. Total memory cost: ~16 B
    /// per dict × number of dicts the user ever queries semantically against,
    /// negligible.
    private var languageCache: [String: NLLanguage] = [:]

    /// Drop all cached language detections. Cheap — only here for symmetry
    /// with the protocol contract; there's nothing significant to evict
    /// anymore since the per-dict vector cache is gone.
    func evictAll() { languageCache.removeAll() }
    func evict(dictId: String) { languageCache[dictId] = nil }

    // MARK: - Public API

    /// Cross-group semantic search. Each active dict in the supplied group
    /// contributes via its detected keyword language; dicts whose detected
    /// language can't embed the query (e.g. a Chinese dict for an English
    /// query) silently skip.
    ///
    /// Returns up to `tier.k` matches, lemma-deduplicated against the
    /// query's canonical lemma, sorted by similarity descending.
    func relatedKeywords(query: String,
                         in dicts: [SemanticDictRef],
                         tier: RelatedWordsTier) async -> [SemanticMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !dicts.isEmpty else { return [] }

        // Group dicts by detected language. First-sight detection samples
        // 200 keywords and runs NLLanguageRecognizer (~5 ms per dict);
        // subsequent calls hit the cache.
        var dictsByLang: [NLLanguage: [SemanticDictRef]] = [:]
        for ref in dicts {
            let lang: NLLanguage
            if let cached = languageCache[ref.id] {
                lang = cached
            } else {
                lang = Self.detectKeywordLanguage(ref: ref)
                languageCache[ref.id] = lang
            }
            dictsByLang[lang, default: []].append(ref)
        }

        print("🧠 relatedKeywords '\(trimmed)' across \(dicts.count) dicts in \(dictsByLang.count) lang(s)")

        // Heavy lifting (NLEmbedding.neighbors + dict.lookup filter + sort +
        // dedup) detached off main. MDictReader is @unchecked Sendable so
        // it's safe to pass into the detached task.
        let langDicts = dictsByLang
        return await Task.detached { [trimmed, tier] in
            Self.computeMatches(query: trimmed, byLang: langDicts, tier: tier)
        }.value
    }

    /// Single-dict convenience.
    func relatedKeywords(query: String,
                         in dict: SemanticDictRef,
                         tier: RelatedWordsTier) async -> [SemanticMatch] {
        await relatedKeywords(query: query, in: [dict], tier: tier)
    }

    // MARK: - Core compute (nonisolated, runs off-main)

    nonisolated private static func computeMatches(
        query: String,
        byLang: [NLLanguage: [SemanticDictRef]],
        tier: RelatedWordsTier
    ) -> [SemanticMatch] {
        let tagger = NLTagger(tagSchemes: [.lemma])

        // Seed the lemma-dedup set with the query's own canonical lemma so
        // morphological self-matches (loans→loan when the user typed "loans")
        // don't crowd out real synonyms.
        var seenLemmas: Set<String> = [Self.canonicalLemma(of: query, tagger: tagger)]

        struct Hit {
            let key: String
            let keyLower: String
            let sim: Double
        }
        var allHits: [Hit] = []

        for (lang, dicts) in byLang {
            guard let embedding = NLEmbedding.wordEmbedding(for: lang) else { continue }
            let stopwords = Self.stopwordsFor(lang)

            // Lemma-expanded query candidates: try raw query first, fall
            // back to the NLTagger lemma if the raw form is OOV. First form
            // with a non-empty neighbor list wins. Per-language because the
            // same surface word may behave differently across languages.
            var neighbors: [(String, NLDistance)] = []
            for candidate in Self.candidateFormsExpanded(query, tagger: tagger) {
                let n = embedding.neighbors(for: candidate, maximumCount: Self.neighborsPerQuery)
                if !n.isEmpty {
                    neighbors = n
                    // Also seed the lemma of whichever candidate form actually
                    // resolved (in case it differs from the raw query's lemma).
                    seenLemmas.insert(Self.canonicalLemma(of: candidate, tagger: tagger))
                    break
                }
            }

            // Filter neighbors to those that exist as keywords in at least
            // one dict in this language group. `MDictReader.lookup` is the
            // existing O(log N) binary-search-backed call; cheap.
            for (word, distance) in neighbors {
                let lower = word.lowercased()
                if stopwords.contains(lower) { continue }

                var found = false
                for ref in dicts {
                    if ref.reader.lookup(word) != nil {
                        found = true; break
                    }
                    // Try lowercased too — some dicts index lowercased, some preserve case.
                    if word != lower, ref.reader.lookup(lower) != nil {
                        found = true; break
                    }
                }
                if !found { continue }

                // NLEmbedding's cosine distance is in [0, 2] (0 = identical,
                // 2 = opposite). Convert to similarity in [0, 1].
                let sim = max(0, 1 - distance / 2.0)
                allHits.append(Hit(key: word, keyLower: lower, sim: sim))
            }
        }

        // Global sort + dedup (case-folded word + canonical lemma), take top K.
        allHits.sort { $0.sim > $1.sim }
        var seenWords: Set<String> = []
        var picks: [SemanticMatch] = []
        picks.reserveCapacity(tier.k)
        for hit in allHits {
            if picks.count >= tier.k { break }
            if seenWords.contains(hit.keyLower) { continue }
            let lemma = Self.canonicalLemma(of: hit.key, tagger: tagger)
            if seenLemmas.contains(lemma) { continue }
            seenWords.insert(hit.keyLower)
            seenLemmas.insert(lemma)
            picks.append(SemanticMatch(key: hit.key, dictId: "", similarity: hit.sim))
        }
        return picks
    }

    /// How many neighbors to request per NLEmbedding call. The framework
    /// applies an internal cosine-distance threshold ≈ 1.0 that caps the
    /// returned set around 50 regardless of what we ask for, so 500 is
    /// effectively "no cap" — same cost, easier to reason about.
    nonisolated private static let neighborsPerQuery: Int = 500

    // MARK: - Language detection

    /// Stride-sample ~200 keywords, run NLLanguageRecognizer on their
    /// concatenation, return dominant language constrained (via hints) to
    /// the set NLEmbedding actually has word-level coverage for. Returns
    /// `.english` as a safe default if recognition fails.
    nonisolated private static func detectKeywordLanguage(
        ref: SemanticDictRef, sampleSize: Int = 200
    ) -> NLLanguage {
        let allKeys = ref.reader.allKeys
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

    /// Aggressive lemma fallback for QUERY inputs: returns the raw lowercased
    /// form first, then NLTagger's lemma if different ("ran" → ["ran", "run"]).
    /// First-with-vector wins at the callsite.
    nonisolated private static func candidateFormsExpanded(_ word: String, tagger: NLTagger) -> [String] {
        let lower = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return [] }
        var out = [lower]
        Self.extractLemmas(into: &out, lower: lower, tagger: tagger)
        return out
    }

    /// One canonical lemma for dedup — last element of the candidate list,
    /// which is the NLTagger lemma if one was returned, else the raw lower
    /// form. Multi-word or non-letter strings stay as-is (no lemma try) —
    /// we don't want "back down" lemmatized to "back".
    nonisolated private static func canonicalLemma(of word: String, tagger: NLTagger) -> String {
        let lower = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return lower }
        if !lower.allSatisfy(\.isLetter) { return lower }
        var forms = [lower]
        Self.extractLemmas(into: &forms, lower: lower, tagger: tagger)
        return forms.last ?? lower
    }

    /// Wraps input in "I <word>" for verb-form disambiguation context.
    /// NLTagger lemma extraction on a bare word often returns the word
    /// itself; wrapping it as a sentence gets it to recognize verbs.
    nonisolated private static func extractLemmas(
        into out: inout [String], lower: String, tagger: NLTagger
    ) {
        let sentence = "I \(lower)"
        tagger.string = sentence
        tagger.enumerateTags(
            in: sentence.startIndex..<sentence.endIndex,
            unit: .word, scheme: .lemma
        ) { tag, range in
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

    /// Per-language stopword set. Returns empty for languages where we
    /// haven't curated a list yet (non-English semantic search returns raw
    /// neighbors, which is still better than nothing).
    nonisolated private static func stopwordsFor(_ lang: NLLanguage) -> Set<String> {
        if lang == .english { return englishStopwords }
        return []
    }

    /// English stopwords. Two groups:
    ///   1. Classic function words (determiners / prepositions / pronouns /
    ///      auxiliaries / conjunctions).
    ///   2. High-frequency adverbs / quantifiers / generic referents that
    ///      NLEmbedding gives near-centroidal vectors to — they look
    ///      spuriously close to almost any query and would crowd out real
    ///      synonyms if left in.
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
        // Generic referents — near-centroidal vectors, "look close" to almost
        // anything. Found via the "happy → 10× something" dogfood case.
        "thing", "things", "stuff", "way", "ways",
        "something", "anything", "everything", "nothing",
        "someone", "anyone", "everyone",
        "somebody", "anybody", "everybody", "nobody",
    ]
}
