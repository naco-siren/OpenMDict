//
//  PhrasyFeudEngine.swift
//  OpenMDict-iOS
//
//  M14 step 2: orchestrator for the Phrasy Feud quiz mode.
//
//  Pipeline:
//    1. Fetch all bookmarks via BookmarkService (sync, MainActor)
//    2. Filter to "looks English" words → pool
//    3. Gate: if pool < 24 words, throw .notEnoughBookmarks
//    4. Shuffle, cap to 30 (prompt-budget bound)
//    5. Multi-word phase, retry ≤ 3:
//         AICoachService.generatePhrasyFeudQuestion → validate (every
//         answer must appear in pool, case-insensitively) → if ≥ 2
//         valid, return Round.
//    6. Single-word fallback phase, retry ≤ 3:
//         pick a random pool word w, AICoachService.generatePhrasyFeudFallback
//         → return Round with single answer.
//    7. If both phases exhausted, throw .generationExhausted.
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

    // MARK: - Build Round

    static func buildRound() async throws -> Round {

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
                    // Quality gate: ask the SAME model (LLM-as-judge) whether
                    // its own question is meaningful, or a degenerate "is a
                    // noun"-class lazy categorization. The judging task is
                    // simpler than the generation task, so the small on-
                    // device model is more reliable here. Critique failure
                    // modes:
                    //   - judge says reject → retry generation
                    //   - judge call itself errors → fail-open (accept the
                    //     question; better to ship something than block on
                    //     a meta-error)
                    let validatedAnswers = unique
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
                    debugLog("✅   attempt \(attempt) accepted with \(validatedAnswers.count) valid: \(validatedAnswers)")
                    return Round(
                        question: q.question,
                        category: q.category,
                        answers: distributeScores(across: validatedAnswers),
                        isFallback: false
                    )
                }
                debugLog("⚠️   attempt \(attempt) rejected — only \(unique.count) valid, need ≥\(minValidAnswers)")
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
            let chosen = pool.randomElement() ?? pool[0]
            do {
                let q = try await AICoachService.shared.generatePhrasyFeudFallback(word: chosen)
                debugLog("🎯   fallback attempt \(attempt) word=\"\(chosen)\" Q=\"\(q.question)\" cat=\"\(q.category)\"")
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
