//
//  PhrasyFeudEngine.swift
//  OpenMDict-iOS
//
//  M14 step 2: orchestrator for the Phrasy Feud quiz mode.
//
//  Pipeline:
//    0. Age process-lifetime usage tracker (multiply weights by decay,
//       drop entries below floor) — see "Repeat-word tracker" below.
//    1. Fetch all bookmarks via BookmarkService (sync, MainActor)
//    2. Filter to "looks English" words → pool
//    3. Gate: if pool < 24 words, throw .notEnoughBookmarks
//    4. Shuffle, cap to 30 (prompt-budget bound)
//    5. Multi-word phase, retry ≤ 3:
//         AICoachService.generatePhrasyFeudQuestion → validate (every
//         answer must appear in pool, case-insensitively) → if ≥ 2
//         valid, return Round.
//    6. Single-word fallback phase, retry ≤ 3:
//         pick a pool word (rejecting recently-used picks
//         probabilistically — see tracker), AICoachService
//         .generatePhrasyFeudFallback → return Round with single answer.
//    7. If both phases exhausted, throw .generationExhausted.
//
//  Repeat-word tracker: with small bookmark pools (~24 words at the
//  gate) the single-word fallback would otherwise keep picking the
//  same hot words via `pool.randomElement()` round after round. We
//  keep a process-lifetime `usageWeights` dict and apply a sharp
//  probabilistic rejection (`pow(0.30, weight)` → weight=1 rejects 70%
//  of the time, weight=2 rejects 91%). Weights age by ×0.7 each round
//  and drop out below 0.05. Soft fail after 8 picks — better to ship a
//  repeat than hang a small pool under a hard blacklist.
//
//  The VC consumes the `Round` value type. Failure cases are distinct
//  enum cases so the VC can show different placeholders (gate vs.
//  retry-friendly engine error).
//

import Foundation
import OpenMDictKit

@available(iOS 26, *)
enum PhrasyFeudEngine {

    // MARK: - Public types

    /// Result delivered to the VC. Always at least one answer.
    struct Round: Equatable {
        let question: String
        let category: String
        let answers: [ScoredAnswer]
        /// True iff this round was produced by the single-word fallback
        /// path (multi-word generation exhausted retries). The VC may
        /// want to surface this — e.g. log it, render a subtle hint,
        /// skip preloading next, etc.
        let isFallback: Bool
    }

    /// One answer slot on the board. Score is procedurally distributed
    /// (see `distributeScores`) — the AI doesn't generate scores.
    struct ScoredAnswer: Equatable {
        let word: String
        let score: Int  // 1...100, all answers in a round sum to ~100, sorted descending
    }

    /// User-distinguishable failure modes.
    enum Failure: Error {
        /// User has fewer than `bookmarkThreshold` English bookmarks. UI
        /// should show a friendly "Bookmark more English words and come
        /// back" placeholder, NOT a retry button.
        case notEnoughBookmarks
        /// FoundationModels couldn't be reached at all (locale unsupported,
        /// model not loaded, network etc.). UI should show error + retry.
        case modelUnavailable
        /// Both multi-word and single-word phases retried out without a
        /// usable result. UI should show error + retry.
        case generationExhausted
    }

    // MARK: - Tunables

    /// Minimum English bookmark count to start a round. Intentionally
    /// NEVER surfaced to the user as a number — copy says "your English
    /// bookmarks aren't ready yet" rather than naming a threshold the
    /// user could game.
    static let bookmarkThreshold = 24

    /// Hard cap on prompt size: the model only needs a varied sample to
    /// find a good cluster, not the user's entire 200+ bookmark library.
    private static let promptPoolSize = 30

    /// Number of retries for the multi-word generation phase before
    /// falling back to the single-word path.
    private static let multiWordMaxAttempts = 3

    /// Number of retries for the single-word fallback phase before
    /// surrendering with `.generationExhausted`.
    private static let fallbackMaxAttempts = 3

    /// Minimum number of validated answers a multi-word round needs to
    /// be acceptable. Below this we treat the attempt as a failure and
    /// retry / fall back. The schema's lower bound is 2.
    private static let minValidAnswers = 2

    // MARK: - Repeat-word tracker tunables

    /// Base of the probabilistic-reject exponent: `probAllow = pow(base, weight)`.
    /// - weight=1 (used once recently)  → probAllow = 0.30, reject 70%
    /// - weight=2 (used twice)          → probAllow = 0.09, reject 91%
    /// - weight=3 (used three times)    → probAllow ≈ 0.027, reject 97.3%
    /// Sharp falloff intentional — recently-used words should mostly
    /// stop showing up immediately, but `pow` never reaches zero so a
    /// repeat is always *possible*, just very unlikely.
    private static let repeatRejectBase: Double = 0.30

    /// Per-round multiplier on all tracker weights. After one round:
    /// weight=1 → 0.7 (probAllow 0.42), after 5 rounds weight=0.17
    /// (probAllow 0.81). Recovers ~linearly over 5–10 rounds, so the
    /// tracker has a "memory" of ~one playing session, not forever.
    private static let perRoundDecay: Double = 0.7

    /// Entries with weight below this are dropped from `usageWeights`
    /// at age time. Bounds the dict size and stops tracking words the
    /// user hasn't seen in many rounds — they're effectively "fresh"
    /// again, no point spending probAllow cycles on them.
    private static let usageWeightFloor: Double = 0.05

    /// Number of random picks fallback selection will attempt before
    /// giving up and shipping a possibly-repeated word. Higher = better
    /// chance of finding a fresh word but slower under hot pools; lower
    /// = faster but more repeats. 8 lands well empirically: at pool=24
    /// with 6 already-hot words, P(all 8 picks rejected) ≈ 0.0025.
    private static let fallbackPickAttempts = 8

    /// Process-lifetime usage tracker keyed by lowercased word. Higher
    /// weight = more recently / more frequently shipped → more likely
    /// to be rejected by `shouldRejectAsRepeat`. Reset on app kill —
    /// no persistence is the right call here (don't want "this word
    /// hasn't shown up in months because we wrote a 0.001 weight to
    /// disk in 2026").
    nonisolated(unsafe) private static var usageWeights: [String: Double] = [:]

    // MARK: - Build Round

    static func buildRound() async throws -> Round {

        // 0. Age the repeat-word tracker BEFORE any work. Even if the
        //    rest of buildRound throws (gate failure, model unavailable
        //    etc.), aging on every entry point keeps the decay running
        //    on a per-user-action basis rather than only on success.
        ageUsageHistory()

        // 1-3. Bookmark fetch + filter + gate
        let bookmarks = await MainActor.run {
            BookmarkService.shared.allBookmarks()
        }
        let englishWords = bookmarks
            .map { $0.word }
            .filter { Self.looksEnglish($0) }
        debugLog("🎯 PhrasyFeud: \(bookmarks.count) total bookmarks, \(englishWords.count) look English")

        guard englishWords.count >= bookmarkThreshold else {
            throw Failure.notEnoughBookmarks
        }

        // 4. Shuffle + cap
        let pool = Array(englishWords.shuffled().prefix(promptPoolSize))
        let poolLowercased = Set(pool.map { $0.lowercased() })

        // 5. Multi-word phase
        for attempt in 1...multiWordMaxAttempts {
            do {
                let q = try await AICoachService.shared.generatePhrasyFeudQuestion(bookmarks: pool)
                let valid = q.answers.filter { poolLowercased.contains($0.lowercased()) }
                let unique = Array(NSOrderedSet(array: valid)) as? [String] ?? valid
                let rejected = q.answers.filter { !poolLowercased.contains($0.lowercased()) }

                debugLog("🎯   attempt \(attempt) Q=\"\(q.question)\"")
                debugLog("🎯   attempt \(attempt) cat=\"\(q.category)\" answers=\(q.answers)")
                if !rejected.isEmpty {
                    debugLog("⚠️   attempt \(attempt) hallucinated (not in pool): \(rejected)")
                }

                if unique.count >= minValidAnswers {
                    // ── Validation layer 2: question critique ──────
                    // Ask the model to judge its OWN question — is it
                    // meaningful, or a degenerate "is a noun"-class
                    // lazy categorization? Default ACCEPT, blacklist
                    // narrow. Critique failure modes:
                    //   - judge says reject → retry generation
                    //   - judge call itself errors → fail-open (better
                    //     to ship a possibly-weak question than block)
                    do {
                        let verdict = try await AICoachService.shared.critiquePhrasyFeudQuestion(q)
                        debugLog("🧐   attempt \(attempt) critique: isHighQuality=\(verdict.isHighQuality) reason=\"\(verdict.reason)\"")
                        if !verdict.isHighQuality {
                            debugLog("⚠️   attempt \(attempt) rejected by judge — retrying")
                            continue
                        }
                    } catch {
                        debugLog("⚠️   attempt \(attempt) critique errored (\(error)) — accepting question without judgment")
                    }

                    // ── Validation layer 3: per-answer fitness ─────
                    // Ask the model to mark EACH candidate answer with
                    // strict fit/no-fit against the question. Catches
                    // the "right question, wrong answer" failure mode
                    // (e.g. 'quetch' under "ends in -tion", 'adduction'
                    // under "means to lead"). Filters `unique` down to
                    // only the words the model considers a real fit.
                    let fitAnswers = await Self.filterByFitness(
                        words: unique, question: q.question, attempt: attempt
                    )
                    if fitAnswers.count < minValidAnswers {
                        debugLog("⚠️   attempt \(attempt) rejected — fitness filter left only \(fitAnswers.count) valid, need ≥\(minValidAnswers)")
                        continue
                    }

                    debugLog("✅   attempt \(attempt) accepted with \(fitAnswers.count) valid: \(fitAnswers)")
                    // Record usage for the tracker BEFORE returning, so
                    // the next round's fallback selection (if reached)
                    // already knows these words are "hot".
                    for w in fitAnswers { recordUsage(w) }
                    return Round(
                        question: q.question,
                        category: q.category,
                        answers: distributeScores(across: fitAnswers),
                        isFallback: false
                    )
                }
                debugLog("⚠️   attempt \(attempt) rejected — only \(unique.count) valid in pool, need ≥\(minValidAnswers)")
            } catch {
                debugLog("⚠️   attempt \(attempt) errored: \(error)")
                // Distinguish "model unavailable" from transient generation
                // errors. The first error type we just bail on; transient
                // errors get the full retry budget.
                if Self.isModelUnavailable(error) {
                    throw Failure.modelUnavailable
                }
            }
        }

        // 6. Single-word fallback phase
        debugLog("🎯 PhrasyFeud: multi-word exhausted, falling back to single-word")
        for attempt in 1...fallbackMaxAttempts {
            let chosen = pickFallbackWord(from: pool, attempt: attempt)
            do {
                let q = try await AICoachService.shared.generatePhrasyFeudFallback(word: chosen)
                debugLog("🎯   fallback attempt \(attempt) word=\"\(chosen)\" Q=\"\(q.question)\" cat=\"\(q.category)\"")
                // Record usage AFTER the model successfully produces a
                // question — we don't want to penalize words that the
                // model errored on (they didn't actually ship).
                recordUsage(chosen)
                return Round(
                    question: q.question,
                    category: q.category,
                    answers: [ScoredAnswer(word: chosen, score: 100)],
                    isFallback: true
                )
            } catch {
                debugLog("⚠️   fallback attempt \(attempt) errored: \(error)")
                if Self.isModelUnavailable(error) {
                    throw Failure.modelUnavailable
                }
            }
        }

        debugLog("⚠️ PhrasyFeud: all \(multiWordMaxAttempts) + \(fallbackMaxAttempts) attempts failed")
        throw Failure.generationExhausted
    }

    // MARK: - Per-answer fitness filter

    /// Validation layer 3: ask the model to judge whether EACH input
    /// word actually fits the question. Returns the subset where
    /// `fits=true`. Falls back to returning all input words if the
    /// model call errors (better to ship a possibly-weak round than
    /// block on a meta-error) — same fail-open philosophy as the
    /// question critique.
    private static func filterByFitness(
        words: [String], question: String, attempt: Int
    ) async -> [String] {
        do {
            let check = try await AICoachService.shared.checkAnswersFit(
                words: words, question: question
            )
            // The model's verdicts may not match input exactly (case
            // drift, omitted entries). Cross-reference by lowercased
            // word: keep an input word iff there's a verdict with
            // `fits == true` whose `word.lowercased()` matches.
            let approvedLowered: Set<String> = Set(
                check.verdicts
                    .filter { $0.fits }
                    .map { $0.word.lowercased() }
            )
            let approved = words.filter { approvedLowered.contains($0.lowercased()) }
            let rejected = words.filter { !approvedLowered.contains($0.lowercased()) }
            for v in check.verdicts {
                debugLog("🔍   attempt \(attempt) fitness: \(v.word) fits=\(v.fits) reason=\"\(v.reason)\"")
            }
            if !rejected.isEmpty {
                debugLog("🔍   attempt \(attempt) fitness rejected: \(rejected)")
            }
            return approved
        } catch {
            debugLog("⚠️   attempt \(attempt) fitness errored (\(error)) — accepting all answers without per-word check")
            return words
        }
    }

    // MARK: - Repeat-word tracker

    /// Record that `word` was just shipped as part of a Round. Each
    /// invocation adds 1.0 to that word's weight, so a word used
    /// twice in a single round (theoretically possible if multi-word
    /// answers duplicate, though `unique` filters that) accumulates
    /// faster. Keyed by lowercased word to match the
    /// case-insensitive matching the rest of the engine uses.
    private static func recordUsage(_ word: String) {
        let key = word.lowercased()
        usageWeights[key, default: 0] += 1
    }

    /// Probabilistic reject: words with higher weights get rejected
    /// more often. Pure function of `usageWeights[word]` and a
    /// per-call `Double.random` — no state mutation.
    /// Returns false for words never seen (`weight ≤ 0`).
    private static func shouldRejectAsRepeat(_ word: String) -> Bool {
        let weight = usageWeights[word.lowercased()] ?? 0
        if weight <= 0 { return false }
        let probAllow = pow(repeatRejectBase, weight)
        return Double.random(in: 0..<1) >= probAllow
    }

    /// Age all tracked weights toward zero, dropping anything below
    /// the floor. Called at the top of `buildRound` so the decay
    /// runs once per user-initiated round (not per attempt — we
    /// don't want failed model calls to artificially age the
    /// tracker).
    private static func ageUsageHistory() {
        // Two passes: scale, then prune. Doing both inline with a
        // single mapValues + filter would allocate twice; the
        // explicit loop is cheaper and the dict is tiny anyway
        // (bounded by O(pool size × rounds played)).
        for key in usageWeights.keys {
            usageWeights[key] = (usageWeights[key] ?? 0) * perRoundDecay
        }
        usageWeights = usageWeights.filter { $0.value >= usageWeightFloor }
    }

    /// Pick a fallback word from `pool`, probabilistically rejecting
    /// recently-used picks. Up to `fallbackPickAttempts` random
    /// draws; first one that passes wins. If all rejected, returns
    /// the LAST pick anyway (soft fail) — better to ship a possibly
    /// repeated word than hang on small pools.
    private static func pickFallbackWord(from pool: [String], attempt: Int) -> String {
        // `pool` is post-gate, so always non-empty; the fallback is
        // belt-and-suspenders against a future regression.
        guard !pool.isEmpty else { return "" }

        var lastPick = pool[0]
        for tryIdx in 1...fallbackPickAttempts {
            let candidate = pool.randomElement() ?? pool[0]
            lastPick = candidate
            if !shouldRejectAsRepeat(candidate) {
                if tryIdx > 1 {
                    debugLog("🎲   fallback attempt \(attempt) accepted on pick \(tryIdx): \"\(candidate)\"")
                }
                return candidate
            }
            let weight = usageWeights[candidate.lowercased()] ?? 0
            debugLog("🎲   fallback attempt \(attempt) pick \(tryIdx) rejected as repeat: \"\(candidate)\" (weight=\(String(format: "%.2f", weight)))")
        }
        debugLog("🎲   fallback attempt \(attempt) exhausted \(fallbackPickAttempts) picks — soft-failing with \"\(lastPick)\"")
        return lastPick
    }

    // MARK: - Score distribution

    /// Procedurally generate a "we surveyed 100 people" descending tally.
    /// Each answer gets a random weight; weights are normalized to sum
    /// to 100, rounded, and the rounding drift is absorbed into the top
    /// answer so the displayed scores still total exactly 100.
    private static func distributeScores(across answers: [String]) -> [ScoredAnswer] {
        guard !answers.isEmpty else { return [] }
        let weights = answers.map { _ in Double.random(in: 0.3...1.0) }
        let total = weights.reduce(0, +)
        var scores = weights.map { Int(($0 / total * 100).rounded()) }
        // Absorb rounding drift into whatever ends up at index 0 after sort.
        scores[0] += 100 - scores.reduce(0, +)
        let pairs = zip(answers, scores).sorted { $0.1 > $1.1 }
        return pairs.map { ScoredAnswer(word: $0.0, score: $0.1) }
    }

    // MARK: - English heuristic

    /// Cheap "looks like an English word" classifier — accepts ASCII
    /// letters, rejects CJK / Hangul / Arabic. Matches the duplicate
    /// helper in `AmongWurdsViewController` and `WordTinderViewController`
    /// (project convention is each VC owns its own copy; extracting to
    /// a shared util is a separate cleanup).
    private static func looksEnglish(_ word: String) -> Bool {
        var hasAscii = false
        for scalar in word.unicodeScalars {
            let v = scalar.value
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                hasAscii = true
                continue
            }
            if (0x3040...0x30FF).contains(v) ||  // Hiragana + Katakana
               (0x3400...0x4DBF).contains(v) ||  // CJK Ext-A
               (0x4E00...0x9FFF).contains(v) ||  // CJK Unified Ideographs
               (0xAC00...0xD7AF).contains(v) ||  // Hangul Syllables
               (0x0600...0x06FF).contains(v) {   // Arabic
                return false
            }
        }
        return hasAscii
    }

    // MARK: - Error classification

    /// Heuristically detect "model isn't going to work no matter how
    /// much we retry" errors so we can fail fast instead of grinding
    /// through the retry budget.
    private static func isModelUnavailable(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("unsupported") ||
               s.contains("unavailable") ||
               s.contains("not enabled") ||
               s.contains("not loaded")
    }
}
