//
//  MorphologyQuizEngine.swift
//  OpenMDict-iOS
//
//  M14: Non-AI orchestrator for the Among wUrdS morphology quiz.
//
//  Pipeline (with retry):
//    1. Pick random crewmate count (4...10) and imposter count (2...70% of crewmates)
//    2. Report target count via .began event (VC shows skeleton grid)
//    3. Call AI, verify each candidate, report .verified events (VC lights up cells)
//    4. If insufficient: report .attemptFailed (VC plays explosion), retry
//    5. On success: return quiz. On exhaustion: return empty quiz (skip word).
//

import Foundation
import OpenMDictKit

/// Progress events for the skeleton-loading UI. Each event triggers
/// a visual update in the VC without blocking the generation pipeline.
nonisolated enum GenerationEvent: Sendable {
    /// A new attempt begins. `totalTarget` = crewmates + imposters the AI
    /// was asked for. VC creates that many skeleton cells.
    case began(totalTarget: Int)
    /// One more candidate passed dictionary verification for this attempt.
    /// `count` is cumulative within the attempt (1, 2, 3...). `colorIndex`
    /// is the crew-color palette index for the cell to "light up."
    case verified(count: Int, colorIndex: Int)
    /// This attempt failed (insufficient candidates). VC plays reactor
    /// meltdown explosion and resets the skeleton grid for the next attempt.
    case attemptFailed
}

@available(iOS 26, *)
enum MorphologyQuizEngine {

    private static let maxAttempts = 5
    private static let minCrewmates = 3
    private static let minImposters = 1

    static let crewColors: [Int] = Array(0..<10)

    // MARK: - Build Quiz

    static func buildMorphologyQuiz(
        targetWord: String,
        targetDictId: String,
        onEvent: (@MainActor (GenerationEvent) -> Void)? = nil
    ) async throws -> MorphologyQuiz {

        let crewmateTarget = Int.random(in: 4...10)
        let imposterTarget = Int.random(in: 2...max(2, crewmateTarget * 7 / 10))
        let totalTarget = crewmateTarget + imposterTarget

        debugLog("🔪 MorphologyEngine: '\(targetWord)' target crew=\(crewmateTarget) imp=\(imposterTarget) total=\(totalTarget)")

        for attempt in 1...maxAttempts {
            // Tell VC a new attempt is starting (show/reset skeletons)
            await onEvent?(.began(totalTarget: totalTarget))

            do {
                let result = try await attemptBuild(
                    targetWord: targetWord,
                    targetDictId: targetDictId,
                    crewmateTarget: crewmateTarget,
                    imposterTarget: imposterTarget,
                    onEvent: onEvent
                )
                if let quiz = result {
                    debugLog("🔪 MorphologyEngine: '\(targetWord)' succeeded on attempt \(attempt) — \(quiz.allCandidates.count) candidates")
                    return quiz
                }
                debugLog("⚠️ MorphologyEngine: '\(targetWord)' attempt \(attempt)/\(maxAttempts) insufficient candidates")
            } catch {
                debugLog("⚠️ MorphologyEngine: '\(targetWord)' attempt \(attempt)/\(maxAttempts) error: \(error)")
            }

            // Tell VC this attempt failed
            if attempt < maxAttempts {
                await onEvent?(.attemptFailed)
                // Brief pause so the explosion animation plays before next attempt
                try? await Task.sleep(for: .seconds(1.5))
            }
        }

        debugLog("⚠️ MorphologyEngine: '\(targetWord)' all \(maxAttempts) attempts failed — skipping")
        return MorphologyQuiz(
            targetWord: targetWord, targetDictId: targetDictId, targetDictName: "",
            root: "", prefix: nil, suffix: nil, allCandidates: [], imposterCount: 0
        )
    }

    private static func attemptBuild(
        targetWord: String,
        targetDictId: String,
        crewmateTarget: Int,
        imposterTarget: Int,
        onEvent: (@MainActor (GenerationEvent) -> Void)?
    ) async throws -> MorphologyQuiz? {

        let raw = try await AICoachService.shared.generateMorphologyChallenge(
            targetWord: targetWord,
            crewmateCount: crewmateTarget,
            imposterCount: imposterTarget
        )
        debugLog("🔪   AI returned: root=\"\(raw.root)\" sameRoot=\(raw.sameRootWords) (\(raw.sameRootWords.count)) false=\(raw.falseRelatives) (\(raw.falseRelatives.count))")

        // ── Degenerate output detection ─────────────────────────────
        // If the model just repeats the target word or produces mostly
        // duplicates, it's completely lost — don't waste time verifying.
        let allReturned = raw.sameRootWords + raw.falseRelatives
        let uniqueReturned = Set(allReturned.map { $0.lowercased() })
        let targetLc = targetWord.lowercased()
        let uniqueNonTarget = uniqueReturned.subtracting([targetLc])
        if uniqueNonTarget.count < 3 {
            debugLog("⚠️   Degenerate output: only \(uniqueNonTarget.count) unique non-target words returned — model is stuck")
            return nil
        }

        var seenWords = Set<String>()
        seenWords.insert(targetLc)
        for lemma in EnglishInflectionRules.resolve(targetWord) {
            seenWords.insert(lemma.lowercased())
        }

        var crewmates: [MorphologyCandidate] = []
        var imposters: [MorphologyCandidate] = []
        var colorPool = crewColors.shuffled()
        var verifiedInAttempt = 0

        for word in raw.sameRootWords {
            if let c = verifyCandidate(word, isImposter: false, dictId: targetDictId, seenWords: &seenWords) {
                let color = colorPool.isEmpty ? Int.random(in: 0..<10) : colorPool.removeFirst()
                crewmates.append(MorphologyCandidate(
                    word: c.word, isImposter: false,
                    definition: c.definition, dictName: c.dictName,
                    crewColorIndex: color))
                verifiedInAttempt += 1
                await onEvent?(.verified(count: verifiedInAttempt, colorIndex: color))
            }
        }

        for word in raw.falseRelatives {
            if let c = verifyCandidate(word, isImposter: true, dictId: targetDictId, seenWords: &seenWords) {
                let color = colorPool.isEmpty ? Int.random(in: 0..<10) : colorPool.removeFirst()
                imposters.append(MorphologyCandidate(
                    word: c.word, isImposter: true,
                    definition: c.definition, dictName: c.dictName,
                    crewColorIndex: color))
                verifiedInAttempt += 1
                await onEvent?(.verified(count: verifiedInAttempt, colorIndex: color))
            }
        }

        debugLog("🔪   Verified: \(crewmates.count) crewmates (need \(minCrewmates)), \(imposters.count) imposters (need \(minImposters))")

        guard crewmates.count >= minCrewmates, imposters.count >= minImposters else {
            return nil
        }

        var allCandidates = crewmates + imposters
        allCandidates.shuffle()

        let dictName = DictMetadataService.shared.find(dictId: targetDictId)?.displayName
            ?? DictionaryService.shared.dict(id: targetDictId)?.displayTitle ?? "—"

        return MorphologyQuiz(
            targetWord: targetWord, targetDictId: targetDictId, targetDictName: dictName,
            root: raw.root,
            prefix: raw.prefix.isEmpty ? nil : raw.prefix,
            suffix: raw.suffix.isEmpty ? nil : raw.suffix,
            allCandidates: allCandidates, imposterCount: imposters.count)
    }

    private static func verifyCandidate(
        _ word: String, isImposter: Bool, dictId: String, seenWords: inout Set<String>
    ) -> (word: String, definition: String, dictName: String)? {
        let lc = word.lowercased()
        guard !seenWords.contains(lc) else {
            debugLog("🔪   skip '\(word)' (duplicate)")
            return nil
        }
        let lemmas = EnglishInflectionRules.resolve(word)
        if lemmas.contains(where: { seenWords.contains($0.lowercased()) }) {
            debugLog("🔪   skip '\(word)' (morphological variant)")
            return nil
        }
        seenWords.insert(lc)
        guard let (def, name) = lookupInSourceDict(word, dictId: dictId) else {
            debugLog("🔪   skip '\(word)' (not in dict)")
            return nil
        }
        debugLog("🔪   ✓ '\(word)' verified (\(isImposter ? "imposter" : "crewmate"))")
        return (word, def, name)
    }

    // MARK: - Grading

    static func grade(
        quiz: MorphologyQuiz,
        markedImposters: Set<String>
    ) -> [MorphologyGradedCandidate] {
        quiz.allCandidates.map { candidate in
            let userMarked = markedImposters.contains(candidate.word)
            return MorphologyGradedCandidate(
                candidate: candidate, userMarkedImposter: userMarked,
                isCorrect: userMarked == candidate.isImposter)
        }
    }

    // MARK: - Dictionary Lookup

    private static func lookupInSourceDict(_ word: String, dictId: String) -> (definition: String, dictName: String)? {
        var forms = [word]
        forms.append(contentsOf: EnglishInflectionRules.resolve(word))
        for form in forms {
            if let result = lookupInDict(form, dictId: dictId) { return result }
        }
        return nil
    }

    private static func lookupInDict(_ word: String, dictId: String) -> (String, String)? {
        guard let dict = DictionaryService.shared.dict(id: dictId), dict.isLoaded,
              let entry = dict.lookup(word) else { return nil }
        let text = HTMLTextExtractor.extract(from: entry.article.html, maxLength: 200)
        guard !text.isEmpty else { return nil }
        let name = DictMetadataService.shared.find(dictId: dict.id)?.displayName ?? dict.displayTitle
        return (text, name)
    }
}
