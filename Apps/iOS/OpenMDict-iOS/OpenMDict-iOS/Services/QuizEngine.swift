//
//  QuizEngine.swift
//  OpenMDict-iOS
//
//  M14 MVP: Non-AI orchestrator for the Word Relationship Quiz.
//
//  Pipeline:
//    Phase 1 (AI)    → AICoachService.generateCandidates → @Generable CandidateWords
//    Phase 2 (non-AI)→ verify each candidate against loaded dictionaries
//    Phase 3 (non-AI)→ inject noise from user's other bookmarks, shuffle, build answer key
//
//  Everything after Phase 1 is deterministic and testable without AI.
//

import Foundation
import OpenMDictKit

@available(iOS 26, *)
enum QuizEngine {

    // MARK: - Build Quiz

    /// End-to-end quiz assembly. Async because Phase 1 calls the on-device
    /// model. Throws on AI errors; returns a fully assembled quiz on success.
    ///
    /// - Parameters:
    ///   - targetWord: the headword to quiz on.
    ///   - targetDictId: the dictionary the target came from (tried first
    ///     during verification for consistency).
    ///   - otherBookmarkedWords: the user's other bookmarked words, used to
    ///     inject noise candidates. Pass at least 5-10 for good selection;
    ///     the engine picks 1 that isn't a synonym/antonym of the target.
    /// - Parameter usedNoiseWords: Words already used as noise in previous
    ///   quizzes this session. Caller should merge the returned quiz's noise
    ///   candidates into this set after each call.
    static func buildWordRelationshipQuiz(
        targetWord: String,
        targetDictId: String,
        otherBookmarkedWords: [String],
        usedNoiseWords: Set<String> = []
    ) async throws -> WordRelationshipQuiz {

        // ── Phase 1: AI candidate generation ─────────────────────────
        let raw = try await AICoachService.shared.generateCandidates(
            targetWord: targetWord
        )
        debugLog("🧩 QuizEngine Phase 1 raw candidates for '\(targetWord)': syn=\(raw.synonyms) ant=\(raw.antonyms) sim=\(raw.similarSpelling)")

        // ── Phase 2: Dictionary verification ─────────────────────────
        // ONLY verify against the quiz word's own dictionary. This
        // guarantees data-source consistency: definitions shown in the
        // quiz come from the same dict the user bookmarked from, and
        // tapping a candidate pushes an article from that same dict.
        var verified: [QuizCandidate] = []
        var seenWords = Set<String>()       // dedup guard (case-insensitive)
        seenWords.insert(targetWord.lowercased())
        // Also exclude morphological variants of the target word so the
        // AI can't cheat by listing "deed" as a "similar-looking word"
        // for "deeds" — they're the same lemma, not a confusable pair.
        for lemma in EnglishInflectionRules.resolve(targetWord) {
            seenWords.insert(lemma.lowercased())
        }

        func tryVerify(_ word: String, relationship: WordRelationship) {
            let lc = word.lowercased()
            guard !seenWords.contains(lc) else { return }  // dedup + morphology guard
            // Also check the reverse: if the candidate's lemma matches
            // the target's lemma, skip it (e.g. candidate "deed" for
            // target "deeds" — both resolve to "deed").
            let candidateLemmas = EnglishInflectionRules.resolve(word)
            if candidateLemmas.contains(where: { seenWords.contains($0.lowercased()) }) {
                debugLog("🧩 QuizEngine: dropped '\(word)' (morphological variant of '\(targetWord)')")
                return
            }
            seenWords.insert(lc)
            if let (def, name) = lookupInSourceDict(word, dictId: targetDictId) {
                verified.append(QuizCandidate(
                    word: word, correctRelationship: relationship,
                    definition: def, dictName: name
                ))
            } else {
                debugLog("🧩 QuizEngine: dropped '\(word)' (not in source dict \(targetDictId.prefix(8))…)")
            }
        }

        for word in raw.synonyms       { tryVerify(word, relationship: .synonym) }
        for word in raw.antonyms       { tryVerify(word, relationship: .antonym) }
        for word in raw.similarSpelling { tryVerify(word, relationship: .similarSpelling) }

        // Drop similarSpelling candidates whose Levenshtein distance is
        // too large — they don't actually look similar.
        let maxDist = max(1, targetWord.count / 5)  // ~20% of target length
        verified = verified.filter { c in
            guard c.correctRelationship == .similarSpelling else { return true }
            return levenshtein(targetWord.lowercased(), c.word.lowercased()) <= maxDist
        }

        debugLog("🧩 QuizEngine Phase 2: \(verified.count) candidates after verification + Levenshtein filter")

        // ── Phase 2b: Randomize counts ──────────────────────────────
        // Break the symmetric pattern so users can't infer antonym count
        // from synonym count. For each relationship group with ≥2 items,
        // randomly keep all or drop one.
        verified = randomizeCounts(verified)

        // ── Phase 3: Multi-source irrelevant words + shuffle ────────
        // Gather noise candidates from 3 sources (0–N each, randomized),
        // merge, cap at 5, then LLM-verify they're truly unrelated.
        var noiseCandidates = gatherNoiseCandidates(
            targetWord: targetWord,
            dictId: targetDictId,
            otherBookmarkedWords: otherBookmarkedWords,
            seenWords: seenWords,
            usedNoiseWords: usedNoiseWords
        )
        // LLM double-check: ask the model to filter out any that are
        // actually related to the target. Fail silently → keep all.
        noiseCandidates = await filterUnrelatedCandidates(
            noiseCandidates, targetWord: targetWord
        )
        verified.append(contentsOf: noiseCandidates)

        // Final dedup by word (case-insensitive) — belt-and-suspenders
        // guard against duplicate section identifiers in DiffableDataSource.
        var finalSeen = Set<String>()
        verified = verified.filter { finalSeen.insert($0.word.lowercased()).inserted }

        let shuffled = verified.shuffled()

        // ── Target definition ────────────────────────────────────────
        let (targetDef, targetDictName) = targetDefinition(
            word: targetWord, dictId: targetDictId
        )

        return WordRelationshipQuiz(
            targetWord: targetWord,
            targetDefinition: targetDef,
            targetDictName: targetDictName,
            candidates: shuffled
        )
    }

    // MARK: - Noise Candidate Sourcing

    /// Gather irrelevant/noise candidates from multiple sources:
    /// 1. Random dictionary entries (0–2)
    /// 2. Random bookmarks (0–3)
    /// 3. Random lookup history (0–4)
    /// Merged, deduped, capped at 5.
    private static func gatherNoiseCandidates(
        targetWord: String,
        dictId: String,
        otherBookmarkedWords: [String],
        seenWords: Set<String>,
        usedNoiseWords: Set<String>
    ) -> [QuizCandidate] {
        var pool: [String] = []
        var seen = seenWords.union(usedNoiseWords)

        // Source 1: Random dictionary entries (0–2)
        let dictSampleCount = Int.random(in: 0...2)
        if dictSampleCount > 0,
           let dict = DictionaryService.shared.dict(id: dictId),
           let reader = dict.reader {
            let allKeys = reader.allKeys
            if !allKeys.isEmpty {
                for _ in 0..<dictSampleCount {
                    let idx = Int.random(in: 0..<allKeys.count)
                    let word = allKeys[idx]
                    if !seen.contains(word.lowercased()) {
                        pool.append(word)
                        seen.insert(word.lowercased())
                    }
                }
            }
        }

        // Source 2: Random bookmarks (0–3)
        let bookmarkSampleCount = Int.random(in: 0...3)
        if bookmarkSampleCount > 0 {
            let available = otherBookmarkedWords.filter { !seen.contains($0.lowercased()) }
            for word in available.shuffled().prefix(bookmarkSampleCount) {
                pool.append(word)
                seen.insert(word.lowercased())
            }
        }

        // Source 3: Random lookup history (0–4)
        let historySampleCount = Int.random(in: 0...4)
        if historySampleCount > 0 {
            let history = LookupHistoryService.shared.allGroupedHistory()
                .flatMap(\.records)
                .filter { $0.isDictAvailable && !seen.contains($0.word.lowercased()) }
            for item in history.shuffled().prefix(historySampleCount) {
                pool.append(item.word)
                seen.insert(item.word.lowercased())
            }
        }

        // Plausibility filter: drop candidates that look obviously wrong
        pool = pool.filter { isPlausibleNoise($0, targetWord: targetWord) }

        // Shuffle and cap at 5
        pool.shuffle()
        if pool.count > 5 { pool = Array(pool.prefix(5)) }

        // Verify each exists in the source dictionary
        return pool.compactMap { word in
            if let (def, name) = lookupInSourceDict(word, dictId: dictId) {
                return QuizCandidate(
                    word: word, correctRelationship: .noise,
                    definition: def, dictName: name
                )
            }
            return nil
        }
    }

    /// Ask the on-device model to filter out any noise candidates that are
    /// actually related to the target word. Fails silently → returns input.
    private static func filterUnrelatedCandidates(
        _ candidates: [QuizCandidate],
        targetWord: String
    ) async -> [QuizCandidate] {
        guard !candidates.isEmpty else { return candidates }
        do {
            let words = candidates.map(\.word)
            let filtered = try await AICoachService.shared.filterUnrelated(
                targetWord: targetWord, candidates: words
            )
            let kept = Set(filtered.map { $0.lowercased() })
            let result = candidates.filter { kept.contains($0.word.lowercased()) }
            debugLog("🧩 QuizEngine: noise filter kept \(result.count)/\(candidates.count)")
            return result
        } catch {
            debugLog("⚠️ QuizEngine: noise filter failed, keeping all: \(error)")
            return candidates
        }
    }

    /// Randomly drop one item from relationship groups with ≥2 verified
    /// candidates. This breaks the "3 synonyms = 3 antonyms" symmetry so
    /// users can't game the quiz by counting.
    private static func randomizeCounts(_ candidates: [QuizCandidate]) -> [QuizCandidate] {
        var result: [QuizCandidate] = []
        let grouped = Dictionary(grouping: candidates, by: \.correctRelationship)
        for (_, group) in grouped {
            if group.count >= 2 && Bool.random() {
                // Drop one random item from this group
                var mutable = group
                mutable.remove(at: Int.random(in: 0..<mutable.count))
                result.append(contentsOf: mutable)
            } else {
                result.append(contentsOf: group)
            }
        }
        return result
    }

    // MARK: - Grading

    /// Grade the user's answers against the quiz's answer key.
    /// Pure function — no side effects, no persistence.
    static func grade(
        quiz: WordRelationshipQuiz,
        userAnswers: [String: UserAnswer]   // keyed by candidate word
    ) -> [GradedCandidate] {
        quiz.candidates.map { candidate in
            let answer = userAnswers[candidate.word] ?? .notAnswered
            let correct: Bool
            switch (candidate.correctRelationship, answer) {
            case (.synonym, .synonym):         correct = true
            case (.antonym, .antonym):          correct = true
            case (.similarSpelling, .unrelated): correct = true
            case (.noise, .unrelated):          correct = true
            default:                            correct = false
            }
            return GradedCandidate(
                candidate: candidate,
                userAnswer: answer,
                isCorrect: correct
            )
        }
    }

    // MARK: - Dictionary Lookup

    /// Search for a word in a SPECIFIC dictionary (the quiz word's source).
    /// Tries exact match first, then lemmatized forms via
    /// `EnglishInflectionRules.resolve` (e.g. "deeds" → "deed").
    ///
    /// Restricting to the source dict guarantees that definitions shown in
    /// the quiz come from the same dictionary the user bookmarked from, so
    /// tapping disclosure pushes a consistent ArticlePageView.
    private static func lookupInSourceDict(
        _ word: String,
        dictId: String
    ) -> (definition: String, dictName: String)? {
        var forms = [word]
        let lemmas = EnglishInflectionRules.resolve(word)
        forms.append(contentsOf: lemmas)

        for form in forms {
            if let result = lookupInDict(form, dictId: dictId) {
                return result
            }
        }
        return nil
    }

    private static func lookupInDict(
        _ word: String, dictId: String
    ) -> (String, String)? {
        guard let dict = DictionaryService.shared.dict(id: dictId) else { return nil }
        return lookupInDict(word, dict: dict)
    }

    private static func lookupInDict(
        _ word: String, dict: MDict
    ) -> (String, String)? {
        guard dict.isLoaded else { return nil }
        guard let entry = dict.lookup(word) else { return nil }
        let text = HTMLTextExtractor.extract(from: entry.article.html, maxLength: 200)
        guard !text.isEmpty else { return nil }
        let name = DictMetadataService.shared.find(dictId: dict.id)?.displayName
            ?? dict.displayTitle
        return (text, name)
    }

    private static func targetDefinition(
        word: String, dictId: String
    ) -> (definition: String, dictName: String) {
        if let result = lookupInSourceDict(word, dictId: dictId) {
            return result
        }
        return ("(definition not available)", "—")
    }

    // MARK: - Plausibility Filter

    /// Drop noise candidates that look obviously mismatched with the target:
    /// - Length too different (< 60% or > 140% of target)
    /// - Different word count (single word vs phrase)
    /// - Capitalization style mismatch (proper noun vs lowercase)
    /// - Too short (< 2 chars)
    private static func isPlausibleNoise(_ candidate: String, targetWord: String) -> Bool {
        let cLen = candidate.count
        let tLen = targetWord.count
        guard cLen >= 2 else { return false }

        // Length ratio
        let minLen = max(2, Int(Double(tLen) * 0.6))
        let maxLen = Int(Double(tLen) * 1.4)
        guard cLen >= minLen, cLen <= maxLen else { return false }

        // Word count must match (single word vs phrase)
        let cWords = candidate.split(separator: " ").count
        let tWords = targetWord.split(separator: " ").count
        guard cWords == tWords else { return false }

        // Capitalization style: both start uppercase or both start lowercase
        let cUpper = candidate.first?.isUppercase ?? false
        let tUpper = targetWord.first?.isUppercase ?? false
        guard cUpper == tUpper else { return false }

        return true
    }

    // MARK: - Levenshtein Distance

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        let aChars = Array(a)
        let bChars = Array(b)
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
