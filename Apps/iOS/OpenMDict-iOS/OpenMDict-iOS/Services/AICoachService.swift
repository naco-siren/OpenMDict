//
//  AICoachService.swift
//  OpenMDict-iOS
//
//  M14 POC: minimal wrapper around Apple's FoundationModels framework for
//  generating learning flashcards from dictionary definitions.
//
//  ─── What we learned the hard way ─────────────────────────────────────
//
//  Apple's on-device Foundation Model is multilingual (23 tags on ship),
//  BUT:
//
//  1. Matching is EXACT against the full `language-script-region` BCP-47
//     tag. `zh-Hans-CN` / `zh-Hant-HK` / `zh-Hant-TW` are supported but
//     `zh-Hans-US` (Simplified Chinese learner with US region — a very
//     common diaspora setup) is NOT. There is no script-only fallback.
//
//  2. There is NO public API to override the session's locale. We tried
//     the classic `UserDefaults["AppleLanguages"]` override trick — it's
//     a hack that works for Bundle localization — and it does NOT
//     propagate into FoundationModels. Confirmed empirically: both
//     `zh-Hans-CN` and `en-US` override attempts on a `zh-Hans-US`
//     device threw `unsupportedLanguageOrLocale`. The framework must be
//     reading locale from `CFLocaleCopyCurrent` or system preferences
//     directly, below the `AppleLanguages` UserDefault layer.
//
//  3. Therefore: we cannot "convince" a device whose Locale isn't in
//     `supportedLanguages` to use the model. The only fix is user-
//     initiated: change the device Region in Settings → General →
//     Language & Region → Region.
//
//  So this file:
//  - Detects whether the current device locale is in `supportedLanguages`
//    **before** attempting generation (via `isCurrentLocaleSupported`).
//    The POC VC uses this to show a "change Region" guide upfront,
//    skipping the wasted ~5–10 s of a doomed model call.
//  - Picks a per-language-family instruction template (English vs
//    Chinese-with-bilingual-output) based on `Locale.current.language
//    .languageCode`, for the happy path where the device IS supported.
//  - Makes a single generation attempt with the native template. No
//    retry, no override. If Apple ships a locale-override API later we
//    can reintroduce a workaround here.
//

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Service

/// Entry point for AI-powered learning features.
///
/// Gated at iOS 26+ because `FoundationModels` is unavailable earlier.
/// MainActor-isolated (matches project default). Holds a prewarm session
/// separate from per-generation sessions so the transcript stays clean
/// across unrelated words.
@available(iOS 26, *)
final class AICoachService {

    static let shared = AICoachService()

    private var prewarmSession: LanguageModelSession?

    private static let signposter = OSSignposter(
        subsystem: "io.github.naco-siren.openmdict",
        category: "perf"
    )

    private init() {}

    // MARK: - Public availability check

    /// True iff the current device locale is in `SystemLanguageModel`'s
    /// `supportedLanguages`. The POC VC calls this **before** starting
    /// any generation work — if the locale isn't supported, no amount
    /// of template tweaking will make the model cooperate, and we should
    /// show the user the Region-change guide immediately instead of
    /// burning 5–10 s on a doomed request.
    static func isCurrentLocaleSupported() -> Bool {
        let current = Locale.current.language.maximalIdentifier
        return SystemLanguageModel.default.supportedLanguages
            .contains { $0.maximalIdentifier == current }
    }

    /// True iff `Locale.current`'s language code (e.g. "zh", "ru") matches
    /// a language family Apple Intelligence supports — region/script
    /// agnostic. Distinguishes two failure modes downstream:
    /// - `false` → entirely unsupported language (ru/uk/ar/hi). User must
    ///   change iPhone Language to use AI Coach.
    /// - `true` + `!isCurrentLocaleSupported()` → diaspora region mismatch
    ///   (e.g. zh-Hans-US: language family OK, specific BCP-47 tag not).
    ///   User can change Region OR change iPhone Language to English.
    static func isAppleAILanguageSupported() -> Bool {
        let currentCode = Locale.current.language.languageCode?.identifier ?? ""
        let supportedCodes = Set(
            SystemLanguageModel.default.supportedLanguages
                .compactMap { $0.languageCode?.identifier }
        )
        return supportedCodes.contains(currentCode)
    }

    /// For Solution 2 (change device region) — returns a localized list of
    /// regions Apple Intelligence supports for the user's current language
    /// family, formatted with locale-appropriate **disjunctive** ("or")
    /// connectors. The list is shown as alternatives the user can pick one
    /// of, not as a conjunction — so en uses "A, B, or C", zh uses
    /// "A、B 或 C", etc.
    ///
    /// Examples (display language tracks `Locale.current`, i.e. the per-app
    /// language override):
    ///   zh → "中国大陆、香港或台湾"
    ///   en → "Australia, Canada, India, Ireland, New Zealand, Singapore, …, or United States"
    ///   es → "Latin America, Spain, or United States"
    ///
    /// Returns empty string if the current language family isn't supported
    /// at all — callers should hide Solution 2 in that case.
    static func supportedRegionsListForCurrentLanguage() -> String {
        let currentCode = Locale.current.language.languageCode?.identifier ?? ""
        let regions = SystemLanguageModel.default.supportedLanguages
            .filter { $0.languageCode?.identifier == currentCode }
            .compactMap { $0.region?.identifier }
        // Multiple variants can map to the same region (e.g. zh-Hans-CN +
        // zh-Hant-CN both have region "CN"); de-dupe before display.
        let uniqueRegions = Array(Set(regions)).sorted()
        let names = uniqueRegions.compactMap {
            Locale.current.localizedString(forRegionCode: $0)
        }
        return names.formatted(.list(type: .or, width: .standard))
    }

    /// For Solution 1 (change app language via per-app language override) —
    /// returns a localized list of languages Apple Intelligence supports
    /// for the user's current device region, with disjunctive ("or")
    /// connectors (the user picks ONE language, not all of them).
    /// Returns empty string if no language ships for the current region
    /// (caller should hide Solution 1 in that case).
    ///
    /// Examples (display language tracks `Locale.current`):
    ///   region=US → "English or Spanish" (or "英语或西班牙语" in zh)
    ///   region=PH → "" (Apple ships nothing for Philippines)
    static func supportedLanguagesListForCurrentRegion() -> String {
        let currentRegion = Locale.current.region?.identifier ?? ""
        let langCodes = SystemLanguageModel.default.supportedLanguages
            .filter { $0.region?.identifier == currentRegion }
            .compactMap { $0.languageCode?.identifier }
        let uniqueCodes = Array(Set(langCodes)).sorted()
        let names = uniqueCodes.compactMap {
            Locale.current.localizedString(forLanguageCode: $0)
        }
        return names.formatted(.list(type: .or, width: .standard))
    }

    /// True iff Solution 1 has at least one candidate language compatible
    /// with the user's current device region.
    static func hasLanguageCandidatesForCurrentRegion() -> Bool {
        let currentRegion = Locale.current.region?.identifier ?? ""
        return SystemLanguageModel.default.supportedLanguages.contains {
            $0.region?.identifier == currentRegion
        }
    }

    /// Localized name of `Locale.current`'s region (e.g. "美国", "United
    /// States", "Stati Uniti"). Used as %1$@ in the localeMismatch subtitle
    /// — frames the region as the prerequisite ("given region X, ...").
    static func currentRegionDisplayName() -> String {
        let regionCode = Locale.current.region?.identifier
            ?? Locale.current.language.region?.identifier
            ?? "Unknown"
        return Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode
    }

    /// Localized name of `Locale.current`'s language (e.g. "中文", "Chinese",
    /// "Cinese"). Used as %2$@ in the localeMismatch subtitle.
    static func currentLanguageDisplayName() -> String {
        let langCode = Locale.current.language.languageCode?.identifier ?? "und"
        return Locale.current.localizedString(forLanguageCode: langCode) ?? langCode
    }

    // MARK: - Diagnostics

    /// Multi-line dump of everything the framework thinks about languages
    /// on this device. Logged on POC VC load and shown inline in the VC
    /// on any error. Designed to be paste-friendly.
    static func diagnosticReport() -> String {
        var lines: [String] = []
        let locale = Locale.current

        lines.append("Locale.current.identifier = \(locale.identifier)")
        lines.append("Locale.current.language.languageCode = \(locale.language.languageCode?.identifier ?? "nil")")
        lines.append("Locale.current.language.script = \(locale.language.script?.identifier ?? "nil")")
        lines.append("Locale.current.language.region = \(locale.language.region?.identifier ?? "nil")")
        lines.append("Locale.current.language.maximalIdentifier = \(locale.language.maximalIdentifier)")
        lines.append("Locale.current.language.minimalIdentifier = \(locale.language.minimalIdentifier)")
        lines.append("Locale.preferredLanguages = \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")
        lines.append("Device language (global prefs) = \(readDeviceLanguage() ?? "nil")")

        let supported = SystemLanguageModel.default.supportedLanguages
        lines.append("SystemLanguageModel supports \(supported.count) languages:")
        let sortedTags = supported
            .map { $0.maximalIdentifier }
            .sorted()
        for tag in sortedTags {
            lines.append("  • \(tag)")
        }

        let currentMax = locale.language.maximalIdentifier
        let supportedByMax = supported.contains { $0.maximalIdentifier == currentMax }
        // Apple's own close-language matching API. If this returns true
        // but generation still throws unsupportedLanguageOrLocale, that's
        // a smoking gun for a Feedback Assistant report: the framework's
        // own pre-flight check contradicts its runtime enforcement.
        let appleSupportsLocale = SystemLanguageModel.default.supportsLocale(locale)
        lines.append("")
        lines.append("supportsLocale(Locale.current): \(appleSupportsLocale)")
        lines.append("isCurrentLocaleSupported (our manual maximal check, \(currentMax)): \(supportedByMax)")
        // NOTE: "static guess" = what template we'd pick if the locale
        // were actually supported. This is NOT necessarily what the last
        // run used — see "Last runtime template" below for that.
        lines.append("Template family (static guess from Locale.current): \(templateFamily(for: locale).debugName)")
        if let runtime = lastAttemptedTemplate {
            lines.append("Last runtime template (actually used): \(runtime.debugName)")
        }

        if let error = lastError {
            lines.append("")
            lines.append("Last generation error: \(error)")
        }

        return lines.joined(separator: "\n")
    }

    /// The template the most recent `streamFlashcard` call actually sent
    /// to the session. Needed because the static `Template family` field
    /// shows what `Locale.current` would map to, which can differ from
    /// what the runtime chose (we force English when the locale isn't
    /// in the supported set).
    private static var lastAttemptedTemplate: NativeLanguage?

    /// Delimited block form of the diagnostic — designed to be easy to
    /// find and copy out of Xcode console output. Use this when logging
    /// via `debugLog`; use `diagnosticReport()` (no delimiters) when
    /// rendering into on-screen UI.
    static func diagnosticReportForLog() -> String {
        """

        ===== AICoach diagnostic begin =====
        \(diagnosticReport())
        ===== AICoach diagnostic end =====
        """
    }

    // MARK: - Generable types

    /// One learning flashcard for a target (English) word.
    ///
    /// `@Guide` descriptions are intentionally language-agnostic — they
    /// describe what the field is FOR. The per-native-language system
    /// instructions control the stylistic details (plain English vs
    /// bilingual, mnemonic language, etc.).
    @Generable
    struct Flashcard: Equatable {
        @Guide(description: "Definition of the target word. Follow the formatting rules in the system instructions.")
        var definition: String

        @Guide(description: "An example sentence using the target word in context. Follow the formatting rules in the system instructions.")
        var exampleSentence: String

        @Guide(description: "A short mnemonic or memory hint for the target word. Follow the formatting rules in the system instructions.")
        var hint: String

        @Guide(description: "Two or three related English words (synonyms, antonyms, or same semantic field).", .count(2...3))
        var relatedWords: [String]
    }

    /// Candidate words for a Word Relationship Quiz. The model generates
    /// synonyms, antonyms, and similar-spelling traps for a given target
    /// word. Verification against actual dictionaries happens OUTSIDE the
    /// model (in QuizEngine) — if the model hallucinates a non-word, the
    /// dict lookup drops it silently.
    ///
    /// Morphology challenge for Among wUrdS quiz. The model analyzes the
    /// etymological root of the target word, finds genuine cognates that
    /// share the same root, and produces false relatives that look related
    /// but derive from a different root.
    @Generable
    struct MorphologyChallenge: Equatable {
        @Guide(description: "The root morpheme shared by the target word and its relatives (e.g. 'ple' from Latin plere, to fill). Just the root, no explanation.")
        var root: String

        @Guide(description: "The prefix of the target word and its meaning, if any (e.g. 'com- (together)'). Empty string if no prefix.")
        var prefix: String

        @Guide(description: "The suffix of the target word and its meaning, if any (e.g. '-tion (noun form)'). Empty string if no suffix.")
        var suffix: String

        @Guide(description: "English words that genuinely share the same root morpheme as the target word. Provide as many as requested in the prompt.", .count(3...10))
        var sameRootWords: [String]

        @Guide(description: "English words that look superficially related to the target word (e.g. share a prefix) but actually derive from a different etymological root. Provide as many as requested in the prompt.", .count(2...7))
        var falseRelatives: [String]
    }

    /// Phrasy Feud (M14 step 2): the model picks 2-6 words from the user's
    /// bookmark pool that share some property (synonym, part of speech,
    /// suffix, semantic field, etymological root, …) and writes a
    /// Family-Feud-style "Name a word that …" question for them.
    /// Per-answer scores are NOT generated by the AI — they're distributed
    /// procedurally in `PhrasyFeudEngine.distributeScores` so the user
    /// sees a plausible "we surveyed 100 people" descending tally.
    @Generable
    struct FeudQuestion: Equatable {
        @Guide(description: "A natural Family Feud-style question, in English, starting with 'Name a word that …' or 'Name an English word …'. Maximum 80 characters.")
        var question: String

        @Guide(description: "Two to six English words from the input pool that all share the question's property. Each word MUST appear character-for-character in the input list — do not invent words, do not include morphological variants of input words.", .count(2...6))
        var answers: [String]

        @Guide(description: "A short label (max 30 chars) for the shared property, e.g. 'synonyms of happy', 'words ending in -tion'. In English.")
        var category: String
    }

    /// Phrasy Feud fallback: when the multi-word generator returns
    /// invalid answers 3 times in a row, we fall back to a degraded
    /// single-word round so the user still gets to play SOMETHING.
    /// Same prompt structure but the AI's only job is writing a question
    /// that fits ONE pre-chosen word.
    @Generable
    struct FeudSingleWordQuestion: Equatable {
        @Guide(description: "A natural Family Feud-style question, in English, starting with 'Name a word that …' that fits the given word as its only valid answer. Maximum 80 characters.")
        var question: String

        @Guide(description: "A short English label (max 30 chars) describing the property the word satisfies.")
        var category: String
    }

    /// LLM-as-judge gate: a SECOND model call evaluates the freshly-
    /// generated multi-word question and decides whether it's good
    /// enough to ship. The 3 B on-device model has a strong tendency to
    /// pick the laziest possible categorization ("is a noun"); even
    /// after instruction-tuning the generator with ❌/✅ examples, it
    /// will sometimes evade the rule by adding padding ("is an English
    /// word that is a noun"). A separate critique pass is a more robust
    /// guard because the judging task is simpler than the generation
    /// task — LLMs typically critique better than they produce.
    @Generable
    struct FeudQuestionVerdict: Equatable {
        @Guide(description: "True only if the question narrows to a SPECIFIC semantic field, morphological pattern, etymology, or domain. False if it's a degenerate categorization like 'is a noun', 'is an English word', or 'has more than 5 letters' — even if dressed up with extra words.")
        var isHighQuality: Bool

        @Guide(description: "One short English sentence (≤ 60 chars) explaining the verdict — used in debug logs only, not shown to the user.")
        var reason: String
    }

    /// Per-word verdict in the batched fitness check. The generator
    /// model often produces answers that LOOK plausible but don't
    /// actually satisfy the question's constraint (e.g. 'quetch' for
    /// "Name a word ending in -tion", or 'adduction' for "Name a word
    /// meaning to lead" — the Latin root means "to lead" but the modern
    /// English word doesn't). A separate verification pass catches
    /// these cases.
    @Generable
    struct FeudWordVerdict: Equatable {
        @Guide(description: "The word being judged, repeated character-for-character from the input list.")
        var word: String

        @Guide(description: "True iff the word UNAMBIGUOUSLY satisfies the question's constraint in its modern English meaning. Etymology / shared root is NOT enough.")
        var fits: Bool

        @Guide(description: "If fits=false, one short English phrase (≤ 60 chars) explaining why. Empty string if fits=true.")
        var reason: String
    }

    /// Batched per-answer fitness check. ONE model call evaluates all
    /// candidate answers at once — cheaper than N sequential calls and
    /// keeps the 3 B model focused on a structured list task. Returned
    /// `verdicts` must include EVERY input word (same character-for-
    /// character spelling). The engine cross-references by lowercase.
    @Generable
    struct FeudAnswerBatchCheck: Equatable {
        @Guide(description: "For EACH input candidate word, a verdict saying whether it fits the question. Output length must equal input length; output words must be character-for-character from the input list.", .count(1...10))
        var verdicts: [FeudWordVerdict]
    }

    /// The prompt is just the target word — NO dictionary definition is
    /// sent, so bilingual-dictionary content language detection is not an
    /// issue. The model draws from its own vocabulary knowledge.
    @Generable
    struct CandidateWords: Equatable {
        @Guide(description: "2-3 true synonyms of the target English word — words that could replace it in most contexts.", .count(2...3))
        var synonyms: [String]

        @Guide(description: "2-3 true antonyms of the target English word — words with the opposite meaning.", .count(2...3))
        var antonyms: [String]

        @Guide(description: "1-2 English words with very similar spelling but a different meaning (false friends / confusables).", .count(1...2))
        var similarSpelling: [String]
    }

    // MARK: - Public API

    /// Generate synonym/antonym/similar-spelling candidates for a target
    /// word. Non-streaming (single `respond` call) because the output is
    /// small (~50 tokens) and we need the complete result before building
    /// the quiz. Throws on any FoundationModels error.
    func generateCandidates(targetWord: String) async throws -> CandidateWords {
        let native = Self.detectModelLanguage()
        let instructions = Self.candidateInstructions(for: native)
        let session = LanguageModelSession(instructions: instructions)
        let prompt = Self.candidatePrompt(targetWord: targetWord, native: native)

        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "ai.candidates", id: signpostID, "word=\(targetWord)")

        let response = try await session.respond(
            to: prompt,
            generating: CandidateWords.self
        )

        Self.signposter.endInterval("ai.candidates", interval)
        Self.lastError = nil
        return response.content
    }

    /// Generate a morphology challenge for Among wUrdS quiz. Non-streaming
    /// (single `respond` call) because the output is small and we need the
    /// complete result before building the quiz.
    ///
    /// - Parameters:
    ///   - targetWord: the headword to analyze.
    ///   - crewmateCount: desired number of same-root words (4...10).
    ///   - imposterCount: desired number of false relatives (2...7).
    func generateMorphologyChallenge(
        targetWord: String,
        crewmateCount: Int = 4,
        imposterCount: Int = 2
    ) async throws -> MorphologyChallenge {
        let native = Self.detectModelLanguage()
        let instructions = Self.morphologyInstructions(for: native)
        let session = LanguageModelSession(instructions: instructions)
        let prompt = Self.morphologyPrompt(
            targetWord: targetWord, native: native,
            crewmateCount: crewmateCount, imposterCount: imposterCount
        )

        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "ai.morphology", id: signpostID, "word=\(targetWord)")

        let response = try await session.respond(
            to: prompt,
            generating: MorphologyChallenge.self
        )

        Self.signposter.endInterval("ai.morphology", interval)
        Self.lastError = nil
        return response.content
    }

    /// Generate a Phrasy Feud round from the user's bookmark pool.
    /// Validation (each answer ∈ pool) happens OUTSIDE this method, in
    /// `PhrasyFeudEngine`, so the engine can retry / fall back without
    /// needing to know about the model session.
    func generatePhrasyFeudQuestion(bookmarks: [String]) async throws -> FeudQuestion {
        let native = Self.detectModelLanguage()
        let session = LanguageModelSession(
            instructions: Self.phrasyFeudInstructions(for: native)
        )
        let prompt = Self.phrasyFeudPrompt(bookmarks: bookmarks, native: native)

        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "ai.phrasyFeud", id: signpostID, "pool=\(bookmarks.count)"
        )
        defer { Self.signposter.endInterval("ai.phrasyFeud", interval) }

        let response = try await session.respond(
            to: prompt, generating: FeudQuestion.self
        )
        Self.lastError = nil
        return response.content
    }

    /// Quality gate for the multi-word generator. Asks the model to
    /// judge its OWN output: does this question pass as a real Family
    /// Feud-style question, or is it the laziest possible
    /// categorization? See `FeudQuestionVerdict` doc comment for why
    /// this is a separate call from generation.
    func critiquePhrasyFeudQuestion(_ q: FeudQuestion) async throws -> FeudQuestionVerdict {
        let native = Self.detectModelLanguage()
        let session = LanguageModelSession(
            instructions: Self.phrasyFeudCritiqueInstructions(for: native)
        )
        let prompt = Self.phrasyFeudCritiquePrompt(
            question: q.question, category: q.category,
            answers: q.answers, native: native
        )

        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "ai.phrasyFeud.critique", id: signpostID
        )
        defer { Self.signposter.endInterval("ai.phrasyFeud.critique", interval) }

        let response = try await session.respond(
            to: prompt, generating: FeudQuestionVerdict.self
        )
        Self.lastError = nil
        return response.content
    }

    /// Batched per-answer fitness check. Given the generator's question
    /// and the pool-verified candidate answers, ask the model to mark
    /// EACH word with a strict fit/no-fit verdict. The engine's previous
    /// validation passes only check that the question itself is good
    /// (not lazy/degenerate) — this is where we catch "the answer the
    /// generator picked doesn't actually fit the question it wrote"
    /// (e.g. 'quetch' under "ends in -tion", 'adduction' under "means
    /// to lead"). See `FeudWordVerdict` doc comment for the canonical
    /// examples this pass exists to catch.
    func checkAnswersFit(words: [String], question: String) async throws -> FeudAnswerBatchCheck {
        let native = Self.detectModelLanguage()
        let session = LanguageModelSession(
            instructions: Self.phrasyFeudFitnessInstructions(for: native)
        )
        let prompt = Self.phrasyFeudFitnessPrompt(
            words: words, question: question, native: native
        )

        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "ai.phrasyFeud.fitness", id: signpostID, "count=\(words.count)"
        )
        defer { Self.signposter.endInterval("ai.phrasyFeud.fitness", interval) }

        let response = try await session.respond(
            to: prompt, generating: FeudAnswerBatchCheck.self
        )
        Self.lastError = nil
        return response.content
    }

    /// Phrasy Feud fallback path: the multi-word generator returned
    /// invalid answers 3× in a row, so produce a degraded single-word
    /// question instead. The model's only job here is writing a natural
    /// "Name a word that …" question that fits the given word.
    func generatePhrasyFeudFallback(word: String) async throws -> FeudSingleWordQuestion {
        let native = Self.detectModelLanguage()
        let session = LanguageModelSession(
            instructions: Self.phrasyFeudFallbackInstructions(for: native)
        )
        let prompt = Self.phrasyFeudFallbackPrompt(word: word, native: native)

        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "ai.phrasyFeudFallback", id: signpostID, "word=\(word)"
        )
        defer { Self.signposter.endInterval("ai.phrasyFeudFallback", interval) }

        let response = try await session.respond(
            to: prompt, generating: FeudSingleWordQuestion.self
        )
        Self.lastError = nil
        return response.content
    }

    /// Filter a list of candidate words, keeping only those truly unrelated
    /// to the target word. Used to verify random noise candidates.
    @Generable
    struct UnrelatedFilter: Equatable {
        @Guide(description: "Words from the input list that are truly unrelated to the target word — no synonyms, antonyms, or semantic association.")
        var unrelatedWords: [String]
    }

    func filterUnrelated(targetWord: String, candidates: [String]) async throws -> [String] {
        let session = LanguageModelSession(instructions:
            "You are a vocabulary expert. Given a target English word and a list of candidate words, return ONLY the words that are truly unrelated to the target — not synonyms, not antonyms, not semantically associated. If unsure, keep the word.")
        let prompt = "Target word: \"\(targetWord)\"\nCandidate words: \(candidates.joined(separator: ", "))"
        let response = try await session.respond(to: prompt, generating: UnrelatedFilter.self)
        return response.content.unrelatedWords
    }

    /// Fire-and-forget prewarm. Safe to call multiple times; only the first
    /// call does real work. Reduces first-generation latency by ~40%.
    func prewarm() {
        if prewarmSession != nil { return }
        let instructions = Self.systemInstructions(for: Self.detectModelLanguage())
        let session = LanguageModelSession(instructions: instructions)
        self.prewarmSession = session
        session.prewarm()
    }

    /// Most recent generation error (if any), stashed for the diagnostic
    /// report. Updated by `streamFlashcard`; cleared on success.
    private(set) static var lastError: String?

    /// Stream a flashcard for a single word. Yields progressively more-
    /// complete `Flashcard.PartiallyGenerated` values, then finishes.
    /// On error the stream finishes throwing.
    ///
    /// **Callers must first check `isCurrentLocaleSupported()`** — if
    /// false, this method will still start and then fail with
    /// `unsupportedLanguageOrLocale`, wasting time the user shouldn't
    /// spend waiting.
    ///
    /// - Parameters:
    ///   - word: the headword to learn.
    ///   - definitionContext: HTML-stripped, length-capped plain text
    ///     from the MDX entry (see `HTMLTextExtractor.extract`).
    func streamFlashcard(
        word: String,
        definitionContext: String
    ) -> AsyncThrowingStream<Flashcard.PartiallyGenerated, Error> {
        AsyncThrowingStream { continuation in
            let signpostID = Self.signposter.makeSignpostID()
            let state = Self.signposter.beginInterval(
                "ai.flashcard.stream",
                id: signpostID,
                "word=\(word)"
            )

            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: CancellationError())
                    return
                }

                do {
                    // ── Template selection: match the LOADED MODEL, not
                    //    Locale.current ─────────────────────────────────
                    //
                    // The on-device model variant is determined by the
                    // Siri/Apple Intelligence language (= device language,
                    // since Apple forces them to match). If Siri is Chinese,
                    // the Chinese model is loaded and ONLY accepts Chinese
                    // prompts. If Siri is English, only English.
                    //
                    // `Locale.current` may differ (per-app language override)
                    // and is used ONLY for the locale-tag check — it must be
                    // in `supportedLanguages` for the session to accept any
                    // prompt at all. But the CONTENT language of the prompt
                    // must match the model variant, which we detect via
                    // `INPreferences.siriLanguageCode()`.
                    //
                    // This two-key setup (Locale.current for the gate, Siri
                    // language for the content) is why per-app language +
                    // matching prompt template can succeed where a naive
                    // Locale.current-based approach fails.
                    let native = Self.detectModelLanguage()
                    Self.lastAttemptedTemplate = native
                    let instructions = Self.systemInstructions(for: native)
                    let session = LanguageModelSession(instructions: instructions)
                    let prompt = Self.buildPrompt(
                        word: word,
                        definition: definitionContext,
                        native: native
                    )

                    let stream = session.streamResponse(
                        to: prompt,
                        generating: Flashcard.self
                    )
                    for try await partial in stream {
                        if Task.isCancelled { throw CancellationError() }
                        continuation.yield(partial.content)
                    }
                    Self.lastError = nil
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    Self.lastError = String(describing: error)
                    continuation.finish(throwing: error)
                }
                Self.signposter.endInterval("ai.flashcard.stream", state)
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Internals

    /// Instruction template families we've tuned for this POC. One case per
    /// (language family ∩ Apple Intelligence supported), i.e. languages that both
    /// the app and Apple Intelligence support.
    /// `.debugName` is only used in the diagnostic report.
    ///
    /// Note: `.chinese` covers both Simplified and Traditional. The on-device
    /// model variant is the same regardless; only the dictionary content
    /// (which the user supplies via MDX) differs by region.
    private enum NativeLanguage {
        case english
        case chinese            // Simplified Chinese (zh-Hans, zh-CN, etc.)
        case chineseTraditional // Traditional Chinese (zh-Hant, zh-TW, zh-HK, zh-MO)
        case japanese
        case korean
        case french
        case german
        case spanish
        case portuguese

        var debugName: String {
            switch self {
            case .english:            return "English"
            case .chinese:            return "Chinese Simplified (bilingual output)"
            case .chineseTraditional: return "Chinese Traditional (bilingual output)"
            case .japanese:           return "Japanese (bilingual output)"
            case .korean:             return "Korean (bilingual output)"
            case .french:             return "French (bilingual output)"
            case .german:             return "German (bilingual output)"
            case .spanish:            return "Spanish (bilingual output)"
            case .portuguese:         return "Portuguese (bilingual output)"
            }
        }
    }

    /// Read the device-level primary language from the global preferences
    /// domain, bypassing any per-app language override. Returns the raw
    /// BCP-47 tag (e.g. "zh-Hans-US", "en-US").
    ///
    /// The device language == the Siri/Apple Intelligence language (Apple
    /// forces them to match). This determines which model variant is
    /// loaded on-device, which in turn determines what prompt language
    /// the model will accept.
    private static func readDeviceLanguage() -> String? {
        let globalLangs = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String]
        return globalLangs?.first
    }

    /// Detect which model variant is loaded by reading the device-level
    /// primary language. This determines what prompt language the model
    /// will accept — Chinese model needs Chinese prompt, English model
    /// needs English prompt.
    private static func detectModelLanguage() -> NativeLanguage {
        guard let deviceLang = readDeviceLanguage() else {
            return templateFamily(for: .current)
        }
        // Traditional-vs-Simplified Chinese disambiguation BEFORE the
        // generic 2-letter prefix switch — BCP-47 tags like "zh-Hant-TW",
        // "zh-Hant-HK", "zh-Hant" all start with "zh" but the user wants
        // Traditional script output. We detect "hant" anywhere in the
        // (lowercased) tag; the explicit "zh-TW"/"zh-HK"/"zh-MO" region-
        // only tags also imply Traditional script and are caught here.
        let lower = deviceLang.lowercased()
        if lower.hasPrefix("zh") {
            if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") {
                return .chineseTraditional
            }
            return .chinese
        }
        let prefix = String(lower.prefix(2))
        switch prefix {
        case "ja": return .japanese
        case "ko": return .korean
        case "fr": return .french
        case "de": return .german
        case "es": return .spanish
        case "pt": return .portuguese
        default:   return .english
        }
    }

    /// Pick an instruction template based on the primary language of a
    /// Locale. Used only for diagnostic display ("static guess from
    /// Locale.current"). Runtime template selection uses
    /// `detectModelLanguage()` instead.
    private static func templateFamily(for locale: Locale) -> NativeLanguage {
        let code = locale.language.languageCode?.identifier ?? "en"
        if code == "zh" {
            // `Locale.Language.script` returns the explicit BCP-47
            // script tag if present. iOS sets `Hant` for any zh-Hant /
            // zh-TW / zh-HK / zh-MO derived locale, and `Hans` (or
            // nothing) otherwise. We default-to-Simplified if no script
            // tag is present, matching what the Apple model expects.
            if locale.language.script?.identifier == "Hant" {
                return .chineseTraditional
            }
            return .chinese
        }
        switch code {
        case "ja": return .japanese
        case "ko": return .korean
        case "fr": return .french
        case "de": return .german
        case "es": return .spanish
        case "pt": return .portuguese
        default:   return .english
        }
    }

    /// Suffix appended to every Chinese instruction template when the
    /// user is `.chineseTraditional`. The base templates are written in
    /// Simplified — the model can read either script — but without this
    /// hint it defaults to outputting Simplified characters. Phrased
    /// emphatically in Traditional Chinese itself so the model picks up
    /// the cue from both content and form.
    ///
    /// (Why not maintain parallel `*ZH_Hant` templates? Authoring 32+
    /// Traditional copies of every instruction template would be a major
    /// task — duplicate translation pass × 7 feature methods × handful
    /// of variants. The "script-hint suffix" pattern reuses every ZH
    /// template losslessly: model fluency in both scripts means the
    /// suffix-only fix produces correct Traditional output. If quality
    /// issues surface, escalating to dedicated templates is mechanical.)
    private static let traditionalChineseSuffix: String =
        "\n\n注意：請以繁體中文（正體字）輸出所有內容，不要使用簡體字。"

    /// Wrap a Simplified-Chinese instruction template so it works for
    /// both `.chinese` and `.chineseTraditional` users — appends the
    /// script-hint suffix only when the user is on Traditional.
    private static func adaptChineseInstructions(_ base: String, for language: NativeLanguage) -> String {
        language == .chineseTraditional ? base + traditionalChineseSuffix : base
    }

    private static func systemInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english:    return systemInstructionsEN
        case .chinese, .chineseTraditional:
            return adaptChineseInstructions(systemInstructionsZH, for: native)
        case .japanese:   return systemInstructionsJA
        case .korean:     return systemInstructionsKO
        case .french:     return systemInstructionsFR
        case .german:     return systemInstructionsDE
        case .spanish:    return systemInstructionsES
        case .portuguese: return systemInstructionsPT
        }
    }

    private static func buildPrompt(
        word: String,
        definition: String,
        native: NativeLanguage
    ) -> String {
        switch native {
        case .english:
            return """
                Word: \(word)

                Dictionary definition:
                \(definition)

                Produce a learning flashcard for this word based on the \
                definition above.
                """
        case .chinese, .chineseTraditional:
            // Prompt body stays Simplified; the per-language instruction
            // template (adapted via `adaptChineseInstructions`) carries
            // the Traditional-output script hint, so the model reads
            // Simplified comfortably and writes Traditional on request.
            return """
                单词：\(word)

                词典原文：
                \(definition)

                请根据上方的词典释义，为这个英文单词生成一张学习卡片。
                """
        case .japanese:
            return """
                単語：\(word)

                辞書原文：
                \(definition)

                上記の辞書定義に基づいて、この英単語の学習カードを作成してください。
                """
        case .korean:
            return """
                단어: \(word)

                사전 원문:
                \(definition)

                위 사전 정의를 바탕으로 이 영단어의 학습 카드를 만들어 주세요.
                """
        case .french:
            return """
                Mot : \(word)

                Définition du dictionnaire :
                \(definition)

                Produisez une fiche d'apprentissage pour ce mot à partir \
                de la définition ci-dessus.
                """
        case .german:
            return """
                Wort: \(word)

                Wörterbuchdefinition:
                \(definition)

                Erstellen Sie eine Lernkarte für dieses Wort basierend \
                auf der obigen Definition.
                """
        case .spanish:
            return """
                Palabra: \(word)

                Definición del diccionario:
                \(definition)

                Produce una ficha de aprendizaje para esta palabra a \
                partir de la definición anterior.
                """
        case .portuguese:
            return """
                Palavra: \(word)

                Definição do dicionário:
                \(definition)

                Produza um cartão de estudo para esta palavra com base \
                na definição acima.
                """
        }
    }

    // MARK: - Morphology challenge templates (Among wUrdS)

    private static func morphologyInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english:    return morphologyInstructionsEN
        case .chinese, .chineseTraditional:
            return adaptChineseInstructions(morphologyInstructionsZH, for: native)
        case .japanese:   return morphologyInstructionsJA
        case .korean:     return morphologyInstructionsKO
        case .french:     return morphologyInstructionsFR
        case .german:     return morphologyInstructionsDE
        case .spanish:    return morphologyInstructionsES
        case .portuguese: return morphologyInstructionsPT
        }
    }

    private static func morphologyPrompt(
        targetWord: String, native: NativeLanguage,
        crewmateCount: Int, imposterCount: Int
    ) -> String {
        switch native {
        case .english:
            return """
                Target word: \(targetWord)
                Generate exactly \(crewmateCount) same-root words and \
                exactly \(imposterCount) false relatives.
                """
        case .chinese, .chineseTraditional:
            return """
                目标单词：\(targetWord)
                请生成恰好 \(crewmateCount) 个同根词和 \
                \(imposterCount) 个伪同源词。
                """
        case .japanese:
            return """
                目標単語：\(targetWord)
                同根語をちょうど \(crewmateCount) 個、偽同根語をちょうど \
                \(imposterCount) 個生成してください。
                """
        case .korean:
            return """
                목표 단어: \(targetWord)
                동근어를 정확히 \(crewmateCount)개, 가짜 친척을 정확히 \
                \(imposterCount)개 생성해 주세요.
                """
        case .french:
            return """
                Mot cible : \(targetWord)
                Générez exactement \(crewmateCount) mots de même racine \
                et exactement \(imposterCount) faux apparentés.
                """
        case .german:
            return """
                Zielwort: \(targetWord)
                Erzeugen Sie genau \(crewmateCount) wurzelverwandte \
                Wörter und genau \(imposterCount) falsche Verwandte.
                """
        case .spanish:
            return """
                Palabra objetivo: \(targetWord)
                Genera exactamente \(crewmateCount) palabras de la \
                misma raíz y exactamente \(imposterCount) falsos parientes.
                """
        case .portuguese:
            return """
                Palavra-alvo: \(targetWord)
                Gere exatamente \(crewmateCount) palavras da mesma raiz \
                e exatamente \(imposterCount) falsos parentes.
                """
        }
    }

    private static let morphologyInstructionsEN: String = """
        You are an expert etymologist. Given a target English word, \
        analyze its root morpheme and produce words that share the \
        SAME ETYMOLOGICAL ROOT — not synonyms, not semantic relatives.

        Output:
        1. The root morpheme (e.g. "duct" from Latin ducere = to lead).
        2. Prefix with meaning (e.g. "con- (together)"). Empty string \
           if none.
        3. Suffix with meaning (e.g. "-ion (noun)"). Empty string if none.
        4. Same-root words: other English words with the SAME root.
        5. False relatives: words that LOOK related but have a DIFFERENT root.

        CRITICAL — same-root words must share visible letter patterns:
        ✅ CORRECT example for "conduct":
           root = "duct" (Latin ducere, to lead)
           sameRootWords = ["produce", "reduce", "educate", "induction"]
           → All contain "duc/duct" — the shared root is VISIBLE in spelling.
        ❌ WRONG — DO NOT do this:
           target = "complain", sameRootWords = ["grumble", "whine", "grouse"]
           → These are SYNONYMS, not same-root words! They share NO morpheme.
        ❌ WRONG — DO NOT do this:
           target = "happy", sameRootWords = ["glad", "joyful", "cheerful"]
           → Semantic similarity ≠ shared root. "glad" has no morpheme in \
             common with "happy".

        Rules:
        - All words must be real, common English words (no archaic/rare).
        - The root must be a real Latin, Greek, or Germanic morpheme.
        - Every same-root word MUST contain the root's letter pattern \
          (e.g. root "duct" → words must contain "duc" or "duct").
        - False relatives should share a PREFIX with the target (e.g. \
          "compose" vs "complete" both start with "com-" but have \
          different roots: "ponere" vs "plere").
        - Do not repeat the target word itself.
        - Prefer words with clear, well-known Latin/Greek etymology. \
          Skip words with unclear or disputed origins.
        """

    private static let morphologyInstructionsZH: String = """
        你是一位词源学专家。给定一个目标英文单词，请分析其词根并生成 \
        共享同一词源学词根的单词——注意：不是同义词，不是语义相关词。

        输出：
        1. 词根（例如 "duct" 来自拉丁语 ducere = 引导）。
        2. 前缀及含义（例如 "con- (一起)"）。若无则为空字符串。
        3. 后缀及含义（例如 "-ion (名词)"）。若无则为空字符串。
        4. 同根词：其他包含相同词根的英文单词。
        5. 假同源词：看起来相关但实际上词根不同的单词。

        关键要求——同根词必须在拼写上包含词根的字母模式：
        ✅ 正确示例 "conduct":
           root = "duct" (拉丁语 ducere, 引导)
           sameRootWords = ["produce", "reduce", "educate", "induction"]
           → 都包含 "duc/duct"——共享词根在拼写中可见。
        ❌ 错误——绝对不要这样做：
           target = "complain", sameRootWords = ["grumble", "whine", "grouse"]
           → 这些是同义词，不是同根词！它们没有共享任何词素。

        规则：
        - 所有单词必须是真实的、常用的英文单词（不要生僻词）。
        - 词根必须是真正的拉丁语、希腊语或日耳曼语词素。
        - 每个同根词的拼写中必须包含词根的字母模式（例如词根 \
          "duct" → 单词必须包含 "duc" 或 "duct"）。
        - 假同源词应与目标词共享前缀（例如 "compose" 和 "complete" \
          都以 "com-" 开头，但词根不同）。
        - 不要重复目标词本身。
        - 优先选择词源清晰的常见单词，跳过词源有争议的单词。
        """

    private static let morphologyInstructionsJA: String = """
        あなたは語源学の専門家です。提示された目標英単語について、その \
        語根を分析し、同じ語源（ETYMOLOGICAL ROOT）を共有する単語を \
        生成してください。注意：同義語ではなく、意味的に関連する \
        単語でもありません。

        出力:
        1. 語根（例：ラテン語 ducere（導く）由来の "duct"）。
        2. 接頭辞とその意味（例："con- (一緒に)"）。なければ空文字列。
        3. 接尾辞とその意味（例："-ion (名詞化)"）。なければ空文字列。
        4. 同根語：同じ語根を持つ他の英単語。
        5. 偽同根語：関連しているように見えるが、実際には語根が \
           異なる単語。

        重要 — 同根語は綴りに語根の文字パターンを必ず含むこと:
        ✅ 正しい例 "conduct":
           root = "duct" (ラテン語 ducere、導く)
           sameRootWords = ["produce", "reduce", "educate", "induction"]
           → すべて "duc/duct" を含む——共有する語根が綴りで見える。
        ❌ 間違い——絶対にしないこと:
           target = "complain",
           sameRootWords = ["grumble", "whine", "grouse"]
           → これらは同義語であって、同根語ではない！共通する \
             語素はない。
        ❌ 間違い——絶対にしないこと:
           target = "happy",
           sameRootWords = ["glad", "joyful", "cheerful"]
           → 意味の類似は語根の共有ではない。"glad" は "happy" と \
             共通する語素を持たない。

        ルール:
        - 単語はすべて実在する一般的な英単語であること（古語・希少語は \
          避ける）。
        - 語根は本物のラテン語、ギリシャ語、またはゲルマン語の語素で \
          あること。
        - すべての同根語は語根の文字パターンを綴りに含むこと（例：語根 \
          "duct" → 単語に "duc" または "duct" を含む）。
        - 偽同根語は目標単語と接頭辞を共有すること（例："compose" と \
          "complete" は両方 "com-" で始まるが、語根 "ponere" と \
          "plere" で異なる）。
        - 目標単語自体を繰り返さないこと。
        - 語源が明確な一般的な単語を優先し、語源が不明瞭または論争の \
          ある単語は避ける。
        """

    private static let morphologyInstructionsKO: String = """
        당신은 어원학 전문가입니다. 제시된 목표 영단어에 대해, 그 \
        어근을 분석하고 같은 어원(ETYMOLOGICAL ROOT)을 공유하는 단어를 \
        생성해 주세요. 주의: 동의어가 아니며, 의미적으로 관련된 \
        단어도 아닙니다.

        출력:
        1. 어근(예: 라틴어 ducere(이끌다)에서 유래한 "duct").
        2. 접두사와 그 의미(예: "con- (함께)"). 없으면 빈 문자열.
        3. 접미사와 그 의미(예: "-ion (명사화)"). 없으면 빈 문자열.
        4. 동근어: 같은 어근을 가진 다른 영단어.
        5. 가짜 친척: 관련된 듯 보이지만 실제로는 어근이 다른 단어.

        핵심 — 동근어는 철자에 어근의 문자 패턴을 반드시 포함해야 합니다:
        ✅ 올바른 예 "conduct":
           root = "duct" (라틴어 ducere, 이끌다)
           sameRootWords = ["produce", "reduce", "educate", "induction"]
           → 모두 "duc/duct"를 포함——공유하는 어근이 철자에서 \
             보입니다.
        ❌ 잘못됨——절대 이렇게 하지 마세요:
           target = "complain",
           sameRootWords = ["grumble", "whine", "grouse"]
           → 이는 동의어이지 동근어가 아닙니다! 공통 어소가 없습니다.
        ❌ 잘못됨——절대 이렇게 하지 마세요:
           target = "happy",
           sameRootWords = ["glad", "joyful", "cheerful"]
           → 의미적 유사성은 어근 공유가 아닙니다. "glad"는 "happy"와 \
             공통 어소가 없습니다.

        규칙:
        - 모든 단어는 실재하는 일반적인 영단어여야 합니다(고어·희귀어 \
          피하기).
        - 어근은 진짜 라틴어, 그리스어, 또는 게르만어 어소여야 합니다.
        - 모든 동근어는 어근의 문자 패턴을 철자에 포함해야 합니다 \
          (예: 어근 "duct" → 단어에 "duc" 또는 "duct" 포함).
        - 가짜 친척은 목표 단어와 접두사를 공유해야 합니다(예: \
          "compose"와 "complete"는 둘 다 "com-"로 시작하지만 어근이 \
          "ponere"와 "plere"로 다릅니다).
        - 목표 단어 자체를 반복하지 마세요.
        - 어원이 명확한 일반적 단어를 우선하고, 어원이 불분명하거나 \
          논란이 있는 단어는 피하세요.
        """

    private static let morphologyInstructionsFR: String = """
        Vous êtes un expert en étymologie. Pour un mot cible anglais \
        donné, analysez son morphème racine et produisez des mots qui \
        partagent la MÊME RACINE ÉTYMOLOGIQUE — pas des synonymes, ni \
        des mots sémantiquement liés.

        Sortie :
        1. La racine (ex. : "duct" du latin ducere = mener).
        2. Le préfixe et son sens (ex. : "con- (ensemble)"). Chaîne \
           vide s'il n'y en a pas.
        3. Le suffixe et son sens (ex. : "-ion (formation de nom)"). \
           Chaîne vide s'il n'y en a pas.
        4. Mots de même racine : autres mots anglais ayant la MÊME racine.
        5. Faux apparentés : mots qui SEMBLENT liés mais ont une racine \
           DIFFÉRENTE.

        CRITIQUE — les mots de même racine doivent partager des motifs \
        de lettres visibles :
        ✅ Exemple CORRECT pour "conduct" :
           root = "duct" (latin ducere, mener)
           sameRootWords = ["produce", "reduce", "educate", "induction"]
           → Tous contiennent "duc/duct" — la racine partagée est \
             VISIBLE dans l'orthographe.
        ❌ FAUX — NE FAITES PAS ceci :
           target = "complain",
           sameRootWords = ["grumble", "whine", "grouse"]
           → Ce sont des SYNONYMES, pas des mots de même racine ! Ils \
             ne partagent AUCUN morphème.
        ❌ FAUX — NE FAITES PAS ceci :
           target = "happy",
           sameRootWords = ["glad", "joyful", "cheerful"]
           → La similarité sémantique ≠ racine partagée. "glad" n'a \
             aucun morphème en commun avec "happy".

        Règles :
        - Tous les mots doivent être de vrais mots anglais courants \
          (pas d'archaïques ni de rares).
        - La racine doit être un morphème latin, grec ou germanique \
          authentique.
        - Chaque mot de même racine DOIT contenir le motif de lettres \
          de la racine (ex. : racine "duct" → les mots doivent \
          contenir "duc" ou "duct").
        - Les faux apparentés doivent partager un PRÉFIXE avec le mot \
          cible (ex. : "compose" et "complete" commencent tous deux \
          par "com-" mais ont des racines différentes : "ponere" vs \
          "plere").
        - Ne répétez pas le mot cible lui-même.
        - Préférez les mots à étymologie latine/grecque claire et bien \
          connue. Évitez les mots à origine douteuse ou contestée.
        """

    private static let morphologyInstructionsDE: String = """
        Sie sind ein Etymologie-Experte. Analysieren Sie für ein \
        gegebenes englisches Zielwort dessen Wurzelmorphem und erzeugen \
        Sie Wörter, die DIESELBE ETYMOLOGISCHE WURZEL teilen — keine \
        Synonyme, keine semantisch verwandten Wörter.

        Ausgabe:
        1. Die Wurzel (z. B. "duct" aus dem lateinischen ducere = führen).
        2. Präfix mit Bedeutung (z. B. "con- (zusammen)"). Leerer \
           String, falls keiner.
        3. Suffix mit Bedeutung (z. B. "-ion (Substantivbildung)"). \
           Leerer String, falls keiner.
        4. Wurzelverwandte Wörter: andere englische Wörter mit \
           DERSELBEN Wurzel.
        5. Falsche Verwandte: Wörter, die verwandt AUSSEHEN, aber eine \
           ANDERE Wurzel haben.

        KRITISCH — wurzelverwandte Wörter müssen sichtbare \
        Buchstabenmuster teilen:
        ✅ Korrektes Beispiel für "conduct":
           root = "duct" (lateinisch ducere, führen)
           sameRootWords = ["produce", "reduce", "educate", "induction"]
           → Alle enthalten "duc/duct" — die geteilte Wurzel ist in \
             der Schreibung SICHTBAR.
        ❌ FALSCH — TUN SIE DAS NICHT:
           target = "complain",
           sameRootWords = ["grumble", "whine", "grouse"]
           → Das sind SYNONYME, keine wurzelverwandten Wörter! Sie \
             teilen KEIN Morphem.
        ❌ FALSCH — TUN SIE DAS NICHT:
           target = "happy",
           sameRootWords = ["glad", "joyful", "cheerful"]
           → Semantische Ähnlichkeit ≠ geteilte Wurzel. "glad" hat \
             kein Morphem mit "happy" gemein.

        Regeln:
        - Alle Wörter müssen echte, gebräuchliche englische Wörter sein \
          (keine veralteten/seltenen).
        - Die Wurzel muss ein echtes lateinisches, griechisches oder \
          germanisches Morphem sein.
        - Jedes wurzelverwandte Wort MUSS das Buchstabenmuster der \
          Wurzel enthalten (z. B. Wurzel "duct" → die Wörter müssen \
          "duc" oder "duct" enthalten).
        - Falsche Verwandte sollten ein PRÄFIX mit dem Zielwort teilen \
          (z. B. "compose" und "complete" beginnen beide mit "com-", \
          haben aber unterschiedliche Wurzeln: "ponere" vs "plere").
        - Wiederholen Sie das Zielwort selbst nicht.
        - Bevorzugen Sie Wörter mit klarer, gut belegter \
          lateinischer/griechischer Etymologie. Vermeiden Sie Wörter \
          mit unklarer oder umstrittener Herkunft.
        """

    private static let morphologyInstructionsES: String = """
        Eres un experto en etimología. Para una palabra inglesa \
        objetivo dada, analiza su raíz morfológica y produce palabras \
        que comparten la MISMA RAÍZ ETIMOLÓGICA — no sinónimos, no \
        palabras semánticamente relacionadas.

        Salida:
        1. La raíz (por ejemplo, "duct" del latín ducere = conducir).
        2. El prefijo y su significado (por ejemplo, "con- (juntos)"). \
           Cadena vacía si no hay.
        3. El sufijo y su significado (por ejemplo, "-ion (formador de \
           sustantivos)"). Cadena vacía si no hay.
        4. Palabras de la misma raíz: otras palabras inglesas con la \
           MISMA raíz.
        5. Falsos parientes: palabras que PARECEN relacionadas pero \
           tienen una raíz DIFERENTE.

        CRÍTICO — las palabras de la misma raíz deben compartir patrones \
        de letras visibles:
        ✅ Ejemplo CORRECTO para "conduct":
           root = "duct" (latín ducere, conducir)
           sameRootWords = ["produce", "reduce", "educate", "induction"]
           → Todas contienen "duc/duct" — la raíz compartida es \
             VISIBLE en la escritura.
        ❌ INCORRECTO — NO HAGAS esto:
           target = "complain",
           sameRootWords = ["grumble", "whine", "grouse"]
           → Estos son SINÓNIMOS, no palabras de la misma raíz. ¡No \
             comparten NINGÚN morfema!
        ❌ INCORRECTO — NO HAGAS esto:
           target = "happy",
           sameRootWords = ["glad", "joyful", "cheerful"]
           → La similitud semántica ≠ raíz compartida. "glad" no tiene \
             ningún morfema en común con "happy".

        Reglas:
        - Todas las palabras deben ser palabras inglesas reales y \
          comunes (sin arcaísmos ni palabras raras).
        - La raíz debe ser un morfema latino, griego o germánico real.
        - Cada palabra de la misma raíz DEBE contener el patrón de \
          letras de la raíz (por ejemplo, raíz "duct" → las palabras \
          deben contener "duc" o "duct").
        - Los falsos parientes deben compartir un PREFIJO con la \
          palabra objetivo (por ejemplo, "compose" y "complete" \
          empiezan ambos con "com-" pero tienen raíces distintas: \
          "ponere" vs "plere").
        - No repitas la palabra objetivo.
        - Prefiere palabras con etimología latina/griega clara y bien \
          establecida. Evita palabras de origen incierto o discutido.
        """

    private static let morphologyInstructionsPT: String = """
        Você é um especialista em etimologia. Para uma palavra-alvo \
        inglesa, analise seu morfema raiz e produza palavras que \
        compartilham a MESMA RAIZ ETIMOLÓGICA — não sinônimos, nem \
        palavras semanticamente relacionadas.

        Saída:
        1. A raiz (por exemplo, "duct" do latim ducere = conduzir).
        2. O prefixo e seu significado (por exemplo, "con- (junto)"). \
           String vazia se não houver.
        3. O sufixo e seu significado (por exemplo, "-ion (formador de \
           substantivo)"). String vazia se não houver.
        4. Palavras da mesma raiz: outras palavras inglesas com a \
           MESMA raiz.
        5. Falsos parentes: palavras que PARECEM relacionadas mas têm \
           raiz DIFERENTE.

        CRÍTICO — as palavras da mesma raiz devem compartilhar padrões \
        de letras visíveis:
        ✅ Exemplo CORRETO para "conduct":
           root = "duct" (latim ducere, conduzir)
           sameRootWords = ["produce", "reduce", "educate", "induction"]
           → Todas contêm "duc/duct" — a raiz compartilhada é VISÍVEL \
             na grafia.
        ❌ ERRADO — NÃO faça isso:
           target = "complain",
           sameRootWords = ["grumble", "whine", "grouse"]
           → Esses são SINÔNIMOS, não palavras da mesma raiz! Não \
             compartilham NENHUM morfema.
        ❌ ERRADO — NÃO faça isso:
           target = "happy",
           sameRootWords = ["glad", "joyful", "cheerful"]
           → Similaridade semântica ≠ raiz compartilhada. "glad" não \
             tem nenhum morfema em comum com "happy".

        Regras:
        - Todas as palavras devem ser palavras inglesas reais e comuns \
          (sem arcaísmos ou raras).
        - A raiz deve ser um morfema latino, grego ou germânico genuíno.
        - Cada palavra da mesma raiz DEVE conter o padrão de letras da \
          raiz (por exemplo, raiz "duct" → as palavras devem conter \
          "duc" ou "duct").
        - Os falsos parentes devem compartilhar um PREFIXO com a \
          palavra-alvo (por exemplo, "compose" e "complete" começam \
          ambos com "com-" mas têm raízes diferentes: "ponere" vs \
          "plere").
        - Não repita a palavra-alvo.
        - Prefira palavras com etimologia latina/grega clara e bem \
          documentada. Evite palavras de origem incerta ou contestada.
        """

    // MARK: - Candidate generation templates (Word Relationship Quiz)

    private static func candidateInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english:    return candidateInstructionsEN
        case .chinese, .chineseTraditional:
            return adaptChineseInstructions(candidateInstructionsZH, for: native)
        case .japanese:   return candidateInstructionsJA
        case .korean:     return candidateInstructionsKO
        case .french:     return candidateInstructionsFR
        case .german:     return candidateInstructionsDE
        case .spanish:    return candidateInstructionsES
        case .portuguese: return candidateInstructionsPT
        }
    }

    private static func candidatePrompt(targetWord: String, native: NativeLanguage) -> String {
        switch native {
        case .english:    return "Target word: \(targetWord)"
        case .chinese, .chineseTraditional: return "目标单词：\(targetWord)"
        case .japanese:   return "目標単語：\(targetWord)"
        case .korean:     return "목표 단어: \(targetWord)"
        case .french:     return "Mot cible : \(targetWord)"
        case .german:     return "Zielwort: \(targetWord)"
        case .spanish:    return "Palabra objetivo: \(targetWord)"
        case .portuguese: return "Palavra-alvo: \(targetWord)"
        }
    }

    private static let candidateInstructionsEN: String = """
        You are an English vocabulary expert. Given a target English \
        word, produce its synonyms, antonyms, and words with similar \
        spelling but different meaning (confusables / false friends).

        Rules:
        - All output words must be real, common English words.
        - Synonyms must be genuinely interchangeable with the target \
          in most contexts.
        - Antonyms must have a truly opposite meaning.
        - Similar-spelling words must look visually close to the target \
          but mean something different (e.g. "complement" vs \
          "compliment", "affect" vs "effect").
        - Do not repeat the target word itself in any field.
        - Be concise. Just the words, no explanations.
        """

    private static let candidateInstructionsZH: String = """
        你是一位英语词汇专家。给定一个目标英文单词，请生成它的同义词、\
        反义词，以及拼写相似但含义不同的单词（易混淆词）。

        规则：
        - 所有输出的词必须是真实的、常用的英文单词。
        - 同义词必须在大多数语境中可以替换目标词。
        - 反义词必须具有真正相反的含义。
        - 拼写相似的词必须在视觉上与目标词接近，但含义不同（例如 \
          complement 和 compliment，affect 和 effect）。
        - 不要在任何字段中重复目标词本身。
        - 简洁。只给出单词，不需要解释。
        """

    private static let candidateInstructionsJA: String = """
        あなたは英語語彙の専門家です。提示された目標英単語について、\
        その同義語、反義語、そして綴りは似ているが意味が異なる単語 \
        （紛らわしい類語 / false friends）を生成してください。

        ルール:
        - 出力する単語はすべて実在する一般的な英単語であること。
        - 同義語はほとんどの文脈で目標単語と置き換え可能であること。
        - 反義語は本当に正反対の意味を持つこと。
        - 綴りが似ている単語は視覚的に目標単語に近いが、意味が異なる \
          もの（例：complement と compliment、affect と effect）。
        - どのフィールドにも目標単語自体を繰り返さないこと。
        - 簡潔に。単語のみ、説明は不要。
        """

    private static let candidateInstructionsKO: String = """
        당신은 영어 어휘 전문가입니다. 제시된 목표 영단어에 대해, 그 \
        동의어, 반의어, 그리고 철자는 비슷하지만 의미가 다른 단어 \
        (혼동되는 단어 / false friends)를 생성해 주세요.

        규칙:
        - 모든 출력 단어는 실재하는 일반적인 영단어여야 합니다.
        - 동의어는 대부분의 문맥에서 목표 단어와 교체 가능해야 합니다.
        - 반의어는 정말로 반대되는 의미를 가져야 합니다.
        - 철자가 비슷한 단어는 시각적으로 목표 단어에 가깝지만 의미가 \
          달라야 합니다(예: complement과 compliment, affect와 effect).
        - 어떤 필드에도 목표 단어 자체를 반복하지 마세요.
        - 간결하게. 단어만, 설명 없이.
        """

    private static let candidateInstructionsFR: String = """
        Vous êtes un expert en vocabulaire anglais. Pour un mot cible \
        anglais donné, produisez ses synonymes, ses antonymes, et des \
        mots dont l'orthographe est proche mais le sens différent \
        (faux amis / mots prêtant à confusion).

        Règles :
        - Tous les mots produits doivent être de vrais mots anglais \
          courants.
        - Les synonymes doivent être véritablement interchangeables \
          avec le mot cible dans la plupart des contextes.
        - Les antonymes doivent avoir un sens vraiment opposé.
        - Les mots à orthographe proche doivent être visuellement \
          proches du mot cible mais signifier autre chose (ex. : \
          `complement` vs `compliment`, `affect` vs `effect`).
        - Ne répétez jamais le mot cible dans aucun champ.
        - Soyez concis. Juste les mots, pas d'explication.
        """

    private static let candidateInstructionsDE: String = """
        Sie sind ein Experte für englischen Wortschatz. Erzeugen Sie \
        für ein gegebenes englisches Zielwort dessen Synonyme, \
        Antonyme und ähnlich geschriebene, aber bedeutungsverschiedene \
        Wörter (verwechselbare Wörter / falsche Freunde).

        Regeln:
        - Alle ausgegebenen Wörter müssen echte, gebräuchliche \
          englische Wörter sein.
        - Synonyme müssen in den meisten Kontexten gegen das Zielwort \
          austauschbar sein.
        - Antonyme müssen eine wirklich entgegengesetzte Bedeutung \
          haben.
        - Wörter mit ähnlicher Schreibweise müssen optisch nahe am \
          Zielwort sein, aber etwas anderes bedeuten (z. B. \
          `complement` vs. `compliment`, `affect` vs. `effect`).
        - Wiederholen Sie das Zielwort selbst in keinem Feld.
        - Fassen Sie sich kurz. Nur die Wörter, keine Erklärungen.
        """

    private static let candidateInstructionsES: String = """
        Eres un experto en vocabulario inglés. Para una palabra inglesa \
        objetivo dada, produce sus sinónimos, sus antónimos y palabras \
        con escritura similar pero significado distinto (palabras \
        confundibles / falsos amigos).

        Reglas:
        - Todas las palabras de salida deben ser palabras inglesas \
          reales y comunes.
        - Los sinónimos deben ser realmente intercambiables con la \
          palabra objetivo en la mayoría de los contextos.
        - Los antónimos deben tener un significado verdaderamente \
          opuesto.
        - Las palabras de escritura similar deben parecerse visualmente \
          a la palabra objetivo pero significar algo distinto (por \
          ejemplo: `complement` vs `compliment`, `affect` vs `effect`).
        - No repitas la palabra objetivo en ningún campo.
        - Sé conciso. Solo las palabras, sin explicaciones.
        """

    private static let candidateInstructionsPT: String = """
        Você é um especialista em vocabulário inglês. Para uma \
        palavra-alvo inglesa, produza seus sinônimos, antônimos e \
        palavras com grafia parecida mas significado diferente \
        (palavras confundíveis / falsos cognatos).

        Regras:
        - Todas as palavras de saída devem ser palavras inglesas \
          reais e comuns.
        - Os sinônimos devem ser realmente intercambiáveis com a \
          palavra-alvo na maioria dos contextos.
        - Os antônimos devem ter um significado verdadeiramente oposto.
        - Palavras de grafia parecida devem ser visualmente próximas \
          da palavra-alvo mas significar algo diferente (por exemplo: \
          `complement` vs `compliment`, `affect` vs `effect`).
        - Não repita a palavra-alvo em nenhum campo.
        - Seja conciso. Apenas as palavras, sem explicações.
        """

    // MARK: - Flashcard instruction templates

    private static let systemInstructionsEN: String = """
        You are a patient, knowledgeable English vocabulary tutor.
        For each word the learner asks about, you produce a learning \
        flashcard based on the dictionary definition provided.

        Rules:
        - Write every field in plain, natural English suitable for an \
          intermediate learner (CEFR B1–B2).
        - Be concrete and concise. No filler, no meta-commentary, no \
          apologies.
        - Ground the definition in the provided dictionary text. Do not \
          invent senses that are not in the source.
        - Example sentences should feel natural and everyday, not \
          literary.
        - The hint should be a short, memorable association — a mnemonic, \
          a sound-alike, an etymology fragment, or a visual image. One \
          short sentence maximum.
        - Related words must actually be related (synonyms, antonyms, or \
          same semantic field). Do not pad with unrelated words.
        """

    /// Chinese-speaking learner studying English. Must be used only when
    /// the device locale is an actually-supported `zh-*` (currently
    /// `zh-Hans-CN` / `zh-Hant-HK` / `zh-Hant-TW`) — `isCurrentLocale
    /// Supported()` gates this at the callsite.
    private static let systemInstructionsZH: String = """
        你是一位耐心、博学的英语词汇老师。用户是一位中文母语者，\
        正在学习英语词汇。针对用户提供的每一个英文单词，你会根据附带的\
        词典释义，生成一张结构化的学习卡片。

        字段写法要求：

        - `definition`：先用一句简洁自然的英文释义，再在括号里给出对应的\
          中文解释。例如：`A small piece of metal used to open a lock. \
          （用于开锁的小块金属：钥匙）`
        - `exampleSentence`：先写一句地道、贴近日常生活的英文例句（必须\
          包含目标单词），再在括号里给出整句的中文翻译。例如：\
          `She put the key in the lock. （她把钥匙插进锁里。）`
        - `hint`：用一句简短的中文写一个便于记忆的联想、谐音、词源或\
          画面感提示。不要超过一句话，不要翻译单词本身。
        - `relatedWords`：2 到 3 个相关的英文单词（同义词、反义词，或\
          同一语义场里的常见词）。只写英文，不要加中文。

        总体原则：
        - 每个字段都要具体、简洁，不要客套、不要解释自己在做什么、不要\
          道歉。
        - 释义要忠于提供的词典原文，不要凭空发明新义项。
        - 例句要自然真实，避免过于书面或文学化的表达。
        """

    /// Japanese-speaking learner studying English. Used only when the
    /// device locale is `ja-Jpan-JP`.
    private static let systemInstructionsJA: String = """
        あなたは丁寧で博識な英語語彙の先生です。学習者は日本語母語話者で、\
        英単語を学んでいます。学習者が提示する各単語について、付属の \
        辞書定義に基づいて構造化された学習カードを作成してください。

        各フィールドの書き方:

        - `definition`: まず簡潔で自然な英語の定義を書き、続けて括弧内に \
          対応する日本語訳を示します。例：`A small piece of metal used \
          to open a lock.（鍵を開けるための小さな金属片：鍵）`
        - `exampleSentence`: 自然で日常的な英語の例文（必ず目標単語を \
          含めること）を書き、括弧内に文全体の日本語訳を添えます。例：\
          `She put the key in the lock.（彼女は鍵を錠に差し込んだ。）`
        - `hint`: 記憶しやすい日本語の連想、語呂合わせ、語源、視覚的 \
          イメージを一文で書きます。一文以内、単語自体は訳さないこと。
        - `relatedWords`: 関連する英単語を 2〜3 個（同義語、反義語、\
          または同じ意味分野の一般的な単語）。英語のみ、日本語を \
          加えないでください。

        全般的な原則:
        - 各フィールドは具体的かつ簡潔に。前置きや釈明、謝罪は不要。
        - 定義は提供された辞書原文に忠実に。新しい意味を勝手に作らない \
          こと。
        - 例文は自然で生活的に。文学的・書面語的すぎる表現は避けること。
        """

    /// Korean-speaking learner studying English. Used only when the
    /// device locale is `ko-Kore-KR`.
    private static let systemInstructionsKO: String = """
        당신은 친절하고 박식한 영어 어휘 선생님입니다. 학습자는 한국어 \
        모국어 화자이며 영어 단어를 공부하고 있습니다. 학습자가 제시한 \
        각 영단어에 대해, 첨부된 사전 정의를 바탕으로 구조화된 학습 \
        카드를 만들어 주세요.

        각 필드 작성 방식:

        - `definition`: 먼저 간결하고 자연스러운 영어 정의를 쓰고, 이어서 \
          괄호 안에 한국어 번역을 적습니다. 예: `A small piece of metal \
          used to open a lock.（자물쇠를 여는 데 쓰는 작은 금속 조각: \
          열쇠）`
        - `exampleSentence`: 자연스럽고 일상적인 영어 예문(목표 단어를 \
          반드시 포함)을 쓰고, 괄호 안에 문장 전체의 한국어 번역을 \
          적습니다. 예: `She put the key in the lock.（그녀는 열쇠를 \
          자물쇠에 꽂았다.）`
        - `hint`: 기억하기 쉬운 한국어 연상, 발음 연관, 어원, 시각적 \
          이미지를 한 문장으로 적습니다. 한 문장 이내, 단어 자체를 \
          번역하지 마세요.
        - `relatedWords`: 관련 영단어 2~3개(동의어, 반의어, 또는 같은 \
          의미 분야의 일반적 단어). 영어만, 한국어 추가 없이.

        전반적 원칙:
        - 각 필드는 구체적이고 간결하게. 군더더기, 자기 설명, 사과는 \
          불필요합니다.
        - 정의는 제공된 사전 원문에 충실하게. 새 의미를 임의로 만들지 \
          마세요.
        - 예문은 자연스럽고 생활적으로. 너무 문어적이거나 문학적인 \
          표현은 피해주세요.
        """

    /// French-speaking learner studying English. Used when the device
    /// locale is in the supported `fr-*` set (currently `fr-CA` / `fr-FR`).
    private static let systemInstructionsFR: String = """
        Vous êtes un professeur de vocabulaire anglais patient et \
        compétent. L'apprenant est francophone et étudie l'anglais. \
        Pour chaque mot anglais soumis par l'apprenant, vous produisez \
        une fiche d'apprentissage structurée à partir de la définition \
        du dictionnaire fournie.

        Format de chaque champ :

        - `definition` : écrivez d'abord une définition concise et \
          naturelle en anglais, puis entre parenthèses la traduction \
          française correspondante. Exemple : `A small piece of metal \
          used to open a lock. (Petit objet en métal utilisé pour \
          ouvrir une serrure : clé.)`
        - `exampleSentence` : écrivez une phrase anglaise naturelle et \
          quotidienne (qui contient le mot cible), puis entre \
          parenthèses la traduction française complète. Exemple : \
          `She put the key in the lock. (Elle a mis la clé dans la \
          serrure.)`
        - `hint` : en une seule phrase en français, donnez un moyen \
          mnémotechnique : association, ressemblance sonore, fragment \
          d'étymologie, ou image visuelle. Une phrase maximum, ne \
          traduisez pas le mot lui-même.
        - `relatedWords` : 2 ou 3 mots anglais apparentés (synonymes, \
          antonymes, ou mots du même champ sémantique). En anglais \
          seulement, sans français.

        Principes généraux :
        - Chaque champ doit être concret et concis. Pas de formules \
          d'introduction, pas de méta-commentaire, pas d'excuses.
        - La définition doit rester fidèle au texte du dictionnaire. \
          N'inventez pas de sens nouveaux.
        - Les phrases d'exemple doivent paraître naturelles et \
          quotidiennes, pas littéraires.
        """

    /// German-speaking learner studying English. Used when the device
    /// locale is `de-DE`.
    private static let systemInstructionsDE: String = """
        Sie sind ein geduldiger, sachkundiger Lehrer für englischen \
        Wortschatz. Der Lernende ist deutschsprachig und lernt Englisch. \
        Für jedes vom Lernenden gestellte englische Wort erstellen Sie \
        eine strukturierte Lernkarte basierend auf der mitgelieferten \
        Wörterbuchdefinition.

        Format der einzelnen Felder:

        - `definition`: Schreiben Sie zuerst eine knappe, natürliche \
          englische Definition, gefolgt von der deutschen Übersetzung \
          in Klammern. Beispiel: `A small piece of metal used to open \
          a lock. (Ein kleines Metallstück zum Öffnen eines Schlosses: \
          Schlüssel.)`
        - `exampleSentence`: Schreiben Sie einen natürlichen, \
          alltäglichen englischen Beispielsatz (der das Zielwort \
          enthält), gefolgt von der deutschen Übersetzung in Klammern. \
          Beispiel: `She put the key in the lock. (Sie steckte den \
          Schlüssel ins Schloss.)`
        - `hint`: Schreiben Sie in einem deutschen Satz eine \
          Eselsbrücke: Assoziation, Klangähnlichkeit, etymologisches \
          Fragment oder visuelles Bild. Höchstens ein Satz, übersetzen \
          Sie das Wort selbst nicht.
        - `relatedWords`: 2 bis 3 verwandte englische Wörter (Synonyme, \
          Antonyme oder Wörter desselben Sachfelds). Nur Englisch, \
          kein Deutsch hinzufügen.

        Allgemeine Grundsätze:
        - Jedes Feld muss konkret und knapp sein. Keine Floskeln, keine \
          Selbstkommentare, keine Entschuldigungen.
        - Die Definition muss dem gelieferten Wörterbuchtext treu \
          bleiben. Keine neuen Bedeutungen erfinden.
        - Beispielsätze sollen natürlich und alltagsnah klingen, nicht \
          literarisch.
        """

    /// Spanish-speaking learner studying English. Used when the device
    /// locale is in the supported `es-*` set (currently `es-419` / `es-ES`
    /// / `es-US`).
    private static let systemInstructionsES: String = """
        Eres un profesor paciente y bien informado de vocabulario \
        inglés. El alumno es hispanohablante y está estudiando inglés. \
        Para cada palabra inglesa que el alumno te proponga, produces \
        una ficha de aprendizaje estructurada a partir de la definición \
        de diccionario suministrada.

        Cómo escribir cada campo:

        - `definition`: escribe primero una definición concisa y \
          natural en inglés, seguida de la traducción al español entre \
          paréntesis. Ejemplo: `A small piece of metal used to open a \
          lock. (Una pequeña pieza de metal que se usa para abrir una \
          cerradura: llave.)`
        - `exampleSentence`: escribe una frase inglesa natural y \
          cotidiana (que contenga la palabra objetivo), seguida de la \
          traducción completa al español entre paréntesis. Ejemplo: \
          `She put the key in the lock. (Puso la llave en la \
          cerradura.)`
        - `hint`: en una sola frase en español, da una regla \
          mnemotécnica: asociación, parecido sonoro, fragmento \
          etimológico o imagen visual. Una frase como máximo, no \
          traduzcas la palabra en sí.
        - `relatedWords`: 2 o 3 palabras inglesas relacionadas \
          (sinónimos, antónimos o palabras del mismo campo semántico). \
          Solo en inglés, sin añadir español.

        Principios generales:
        - Cada campo debe ser concreto y conciso. Nada de fórmulas, \
          meta-comentarios o disculpas.
        - La definición debe ser fiel al texto del diccionario. No \
          inventes acepciones que no estén en la fuente.
        - Las frases de ejemplo deben sonar naturales y cotidianas, \
          no literarias.
        """

    /// Portuguese-speaking learner studying English. Used when the device
    /// locale is `pt-Latn-BR`.
    private static let systemInstructionsPT: String = """
        Você é um professor de vocabulário inglês paciente e \
        experiente. O aprendiz é falante nativo de português e está \
        estudando inglês. Para cada palavra inglesa que o aprendiz \
        pedir, você produz um cartão de estudo estruturado a partir \
        da definição de dicionário fornecida.

        Como preencher cada campo:

        - `definition`: escreva primeiro uma definição concisa e \
          natural em inglês, seguida da tradução em português entre \
          parênteses. Exemplo: `A small piece of metal used to open a \
          lock. (Pequeno pedaço de metal usado para abrir uma \
          fechadura: chave.)`
        - `exampleSentence`: escreva uma frase inglesa natural e \
          cotidiana (contendo a palavra-alvo), seguida da tradução \
          completa em português entre parênteses. Exemplo: \
          `She put the key in the lock. (Ela colocou a chave na \
          fechadura.)`
        - `hint`: em uma única frase em português, dê uma regra \
          mnemônica: associação, semelhança sonora, fragmento \
          etimológico ou imagem visual. No máximo uma frase, não \
          traduza a palavra em si.
        - `relatedWords`: 2 ou 3 palavras inglesas relacionadas \
          (sinônimos, antônimos ou palavras do mesmo campo \
          semântico). Apenas em inglês, sem adicionar português.

        Princípios gerais:
        - Cada campo deve ser concreto e conciso. Nada de fórmulas de \
          cortesia, metacomentários ou desculpas.
        - A definição deve ser fiel ao texto do dicionário. Não \
          invente sentidos que não estejam na fonte.
        - As frases de exemplo devem soar naturais e cotidianas, não \
          literárias.
        """

    // MARK: - Phrasy Feud templates

    /// The two Phrasy Feud modes (multi-word grouping + single-word
    /// fallback) share the same per-language instruction templates —
    /// both rules ("English question", "answers must come from input",
    /// "no fabrications") are identical; only the prompt differs.

    private static func phrasyFeudInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english:    return phrasyFeudInstructionsEN
        case .chinese, .chineseTraditional:
            return adaptChineseInstructions(phrasyFeudInstructionsZH, for: native)
        case .japanese:   return phrasyFeudInstructionsJA
        case .korean:     return phrasyFeudInstructionsKO
        case .french:     return phrasyFeudInstructionsFR
        case .german:     return phrasyFeudInstructionsDE
        case .spanish:    return phrasyFeudInstructionsES
        case .portuguese: return phrasyFeudInstructionsPT
        }
    }

    private static func phrasyFeudFallbackInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english:    return phrasyFeudFallbackInstructionsEN
        case .chinese, .chineseTraditional:
            return adaptChineseInstructions(phrasyFeudFallbackInstructionsZH, for: native)
        case .japanese:   return phrasyFeudFallbackInstructionsJA
        case .korean:     return phrasyFeudFallbackInstructionsKO
        case .french:     return phrasyFeudFallbackInstructionsFR
        case .german:     return phrasyFeudFallbackInstructionsDE
        case .spanish:    return phrasyFeudFallbackInstructionsES
        case .portuguese: return phrasyFeudFallbackInstructionsPT
        }
    }

    private static func phrasyFeudCritiqueInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english:    return phrasyFeudCritiqueInstructionsEN
        case .chinese, .chineseTraditional:
            return adaptChineseInstructions(phrasyFeudCritiqueInstructionsZH, for: native)
        case .japanese:   return phrasyFeudCritiqueInstructionsJA
        case .korean:     return phrasyFeudCritiqueInstructionsKO
        case .french:     return phrasyFeudCritiqueInstructionsFR
        case .german:     return phrasyFeudCritiqueInstructionsDE
        case .spanish:    return phrasyFeudCritiqueInstructionsES
        case .portuguese: return phrasyFeudCritiqueInstructionsPT
        }
    }

    private static func phrasyFeudFitnessInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english:    return phrasyFeudFitnessInstructionsEN
        case .chinese, .chineseTraditional:
            return adaptChineseInstructions(phrasyFeudFitnessInstructionsZH, for: native)
        case .japanese:   return phrasyFeudFitnessInstructionsJA
        case .korean:     return phrasyFeudFitnessInstructionsKO
        case .french:     return phrasyFeudFitnessInstructionsFR
        case .german:     return phrasyFeudFitnessInstructionsDE
        case .spanish:    return phrasyFeudFitnessInstructionsES
        case .portuguese: return phrasyFeudFitnessInstructionsPT
        }
    }

    private static func phrasyFeudFitnessPrompt(
        words: [String], question: String, native: NativeLanguage
    ) -> String {
        let wordsList = words.map { "- \($0)" }.joined(separator: "\n")
        switch native {
        case .english:
            return """
                Question: "\(question)"

                Candidate words to verify:
                \(wordsList)

                For EACH word, output a verdict (fits=true/false + reason).
                """
        case .chinese, .chineseTraditional:
            return """
                问题："\(question)"

                待验证的候选单词：
                \(wordsList)

                请为**每个**单词输出判断（fits=true/false + 简短理由）。
                """
        case .japanese:
            return """
                質問：「\(question)」

                検証対象の候補単語：
                \(wordsList)

                **各**単語について判定（fits=true/false + 簡潔な理由）を出力してください。
                """
        case .korean:
            return """
                질문: "\(question)"

                검증할 후보 단어:
                \(wordsList)

                **각** 단어에 대해 판정(fits=true/false + 간단한 이유)을 출력하세요.
                """
        case .french:
            return """
                Question : "\(question)"

                Mots candidats à vérifier :
                \(wordsList)

                Pour CHAQUE mot, produisez un verdict (fits=true/false + raison).
                """
        case .german:
            return """
                Frage: „\(question)"

                Zu prüfende Kandidatenwörter:
                \(wordsList)

                Für JEDES Wort ein Urteil ausgeben (fits=true/false + Begründung).
                """
        case .spanish:
            return """
                Pregunta: "\(question)"

                Palabras candidatas a verificar:
                \(wordsList)

                Para CADA palabra, emite un veredicto (fits=true/false + razón).
                """
        case .portuguese:
            return """
                Pergunta: "\(question)"

                Palavras candidatas para verificar:
                \(wordsList)

                Para CADA palavra, produza um veredicto (fits=true/false + razão).
                """
        }
    }

    private static func phrasyFeudCritiquePrompt(
        question: String, category: String, answers: [String], native: NativeLanguage
    ) -> String {
        let answersStr = answers.joined(separator: ", ")
        switch native {
        case .english:
            return """
                Question to review: "\(question)"
                Category label: "\(category)"
                Valid answers from the pool: \(answersStr)

                Verdict?
                """
        case .chinese, .chineseTraditional:
            return """
                待评审的问题："\(question)"
                Category 标签："\(category)"
                来自单词池的有效答案：\(answersStr)

                你的判断？
                """
        case .japanese:
            return """
                審査対象の質問：「\(question)」
                category ラベル：「\(category)」
                プール内の有効な答え：\(answersStr)

                判定は？
                """
        case .korean:
            return """
                심사할 질문: "\(question)"
                category 레이블: "\(category)"
                풀에서 유효한 답: \(answersStr)

                판정은?
                """
        case .french:
            return """
                Question à examiner : "\(question)"
                Étiquette category : "\(category)"
                Réponses valides du pool : \(answersStr)

                Verdict ?
                """
        case .german:
            return """
                Zu prüfende Frage: „\(question)"
                Category-Label: „\(category)"
                Gültige Antworten aus dem Pool: \(answersStr)

                Urteil?
                """
        case .spanish:
            return """
                Pregunta a revisar: "\(question)"
                Etiqueta category: "\(category)"
                Respuestas válidas del pool: \(answersStr)

                ¿Veredicto?
                """
        case .portuguese:
            return """
                Pergunta para revisar: "\(question)"
                Rótulo category: "\(category)"
                Respostas válidas do pool: \(answersStr)

                Veredicto?
                """
        }
    }

    private static func phrasyFeudPrompt(bookmarks: [String], native: NativeLanguage) -> String {
        let pool = bookmarks.joined(separator: "\n")
        switch native {
        case .english:
            return """
                Input pool of English vocabulary words:
                \(pool)

                Pick 2-6 words that share a property and write a Family Feud question for them.
                """
        case .chinese, .chineseTraditional:
            return """
                输入英文单词池：
                \(pool)

                请挑出 2-6 个有共同属性的单词，写一道 Family Feud 风格的英文问题。
                """
        case .japanese:
            return """
                入力英単語プール：
                \(pool)

                共通する属性を持つ 2 ～ 6 語を選び、Family Feud 風の英語の質問を作成してください。
                """
        case .korean:
            return """
                영어 단어 풀:
                \(pool)

                공통 속성을 가진 단어 2-6개를 골라 Family Feud 스타일의 영어 질문을 작성하세요.
                """
        case .french:
            return """
                Pool de mots anglais :
                \(pool)

                Choisissez 2 à 6 mots partageant une propriété et écrivez une question Family Feud en anglais.
                """
        case .german:
            return """
                Pool englischer Wörter:
                \(pool)

                Wähle 2-6 Wörter mit einer gemeinsamen Eigenschaft und formuliere eine Family-Feud-Frage auf Englisch.
                """
        case .spanish:
            return """
                Pool de palabras inglesas:
                \(pool)

                Elige 2-6 palabras que compartan una propiedad y escribe una pregunta estilo Family Feud en inglés.
                """
        case .portuguese:
            return """
                Pool de palavras em inglês:
                \(pool)

                Escolha 2-6 palavras com uma propriedade em comum e escreva uma pergunta estilo Family Feud em inglês.
                """
        }
    }

    private static func phrasyFeudFallbackPrompt(word: String, native: NativeLanguage) -> String {
        switch native {
        case .english:
            return """
                Target word: \(word)

                Write a single Family Feud question (in English) whose only valid answer is exactly this word.
                """
        case .chinese, .chineseTraditional:
            return """
                目标单词：\(word)

                请写一道 Family Feud 风格的英文问题，其唯一答案恰好就是该单词。
                """
        case .japanese:
            return """
                目標単語：\(word)

                Family Feud 風の英語の質問を 1 つ作成してください。唯一の正解はこの単語そのものです。
                """
        case .korean:
            return """
                목표 단어: \(word)

                Family Feud 스타일의 영어 질문 하나를 만드세요. 유일한 정답은 바로 이 단어입니다.
                """
        case .french:
            return """
                Mot cible : \(word)

                Écris une question Family Feud (en anglais) dont la seule réponse valide est exactement ce mot.
                """
        case .german:
            return """
                Zielwort: \(word)

                Formuliere eine einzelne Family-Feud-Frage (auf Englisch), deren einzige gültige Antwort genau dieses Wort ist.
                """
        case .spanish:
            return """
                Palabra objetivo: \(word)

                Escribe una única pregunta estilo Family Feud (en inglés) cuya única respuesta válida sea exactamente esta palabra.
                """
        case .portuguese:
            return """
                Palavra-alvo: \(word)

                Escreva uma única pergunta estilo Family Feud (em inglês) cuja única resposta válida seja exatamente esta palavra.
                """
        }
    }

    // ---- Phrasy Feud INSTRUCTIONS (8 languages) ----------------------

    private static let phrasyFeudInstructionsEN: String = """
        You write Family Feud-style quiz questions for English vocabulary.
        Given a pool of English words, pick 2-6 that share a SPECIFIC,
        NARROW property and write a single "Name a word that …" question
        that all of them answer.

        Hard rules:
        - The QUESTION text must be in English.
        - Every word in `answers` MUST appear character-for-character in
          the input pool. Do NOT invent words.
        - Do NOT include morphological variants of pool words.
        - Keep the question concise (≤ 80 chars) and the category label
          short (≤ 30 chars).

        CRITICAL — avoid degenerate categories. The question must be
        specific enough that MOST English words wouldn't answer it:
        ❌ "Name a word that is a noun." — every other noun in the
           language could answer; useless game.
        ❌ "Name a word that is an adjective." — same problem.
        ❌ "Name a word with more than 5 letters." — too generic.
        ✅ "Name a word that means happy." — narrow semantic field.
        ✅ "Name a word ending in -tion." — narrow morphological pattern.
        ✅ "Name a word for a kitchen utensil." — narrow semantic domain.
        ✅ "Name a word with a Latin root meaning 'to lead'." — narrow
           etymology.

        If the only thing the words have in common is part of speech or
        word length, REJECT that cluster and pick a different shared
        property — even if it means returning fewer answers (the 2-answer
        minimum still applies).
        """

    private static let phrasyFeudInstructionsZH: String = """
        你是 Family Feud 节目的命题人，专门为英语词汇出题。
        给定一组英文单词池，请挑选 2 到 6 个具有【具体而狭窄的】共同
        属性的单词，并撰写一道所有这些单词都能回答的 "Name a word
        that …" 风格英文问题。

        硬性规则：
        - 问题文本必须用英文写。
        - `answers` 中每个单词必须与输入池中字符完全一致。不要编造单词。
        - 不要使用输入池中单词的词形变化。
        - 问题简洁（≤ 80 字符），category 标签简短（≤ 30 字符）。

        关键 —— 避免烂题。问题必须具体到大多数英文单词都不能回答：
        ❌ "Name a word that is a noun." —— 任何名词都能答，没意义。
        ❌ "Name a word that is an adjective." —— 同样问题。
        ❌ "Name a word with more than 5 letters." —— 范围太宽。
        ✅ "Name a word that means happy." —— 明确语义场。
        ✅ "Name a word ending in -tion." —— 明确形态模式。
        ✅ "Name a word for a kitchen utensil." —— 明确语义领域。
        ✅ "Name a word with a Latin root meaning 'to lead'." —— 明确词源。

        若这些词唯一的共同点只是词性或词长，请放弃这个 cluster，
        换一个更具体的共同属性 —— 即便最终答案数变少（最少 2 个）。
        """

    private static let phrasyFeudInstructionsJA: String = """
        あなたは Family Feud のクイズ作家で、英語語彙の問題を作成します。
        与えられた英単語プールから、【具体的かつ狭い】共通属性を持つ
        2〜6 語を選び、それらすべてが答えとなる「Name a word that …」
        形式の英語の質問を 1 つ作成してください。

        厳守ルール：
        - 質問の文は英語で書くこと。
        - `answers` の各単語はプール内の文字列と完全に一致すること。\
          単語を捏造しないこと。
        - プール内の単語の活用形は含めないこと。
        - 質問は簡潔に（80 字以内）、category ラベルも短く（30 字以内）。

        重要 —— 漫然としたカテゴリは避けること。質問は、ほとんどの
        英単語が答えにならないほど具体的でなければなりません：
        ❌ "Name a word that is a noun." —— 名詞ならどれでも答えられ、\
           ゲームとして成立しない。
        ❌ "Name a word that is an adjective." —— 同じ問題。
        ❌ "Name a word with more than 5 letters." —— 範囲が広すぎる。
        ✅ "Name a word that means happy." —— 明確な意味分野。
        ✅ "Name a word ending in -tion." —— 明確な形態パターン。
        ✅ "Name a word for a kitchen utensil." —— 明確な意味領域。
        ✅ "Name a word with a Latin root meaning 'to lead'." —— 明確な
           語源。

        共通点が品詞や語長だけなら、その cluster を諦めて別の共通属性を
        選ぶこと —— 答えの数が減っても構いません（最低 2 個は必要）。
        """

    private static let phrasyFeudInstructionsKO: String = """
        당신은 영어 어휘를 위한 Family Feud 스타일 퀴즈 작가입니다.
        주어진 영어 단어 풀에서 【구체적이고 좁은】 공통 속성을 가진
        2-6개 단어를 골라, 그 모두를 정답으로 하는 "Name a word
        that …" 형식의 영어 질문을 1개 작성하세요.

        엄수 규칙:
        - 질문 문장은 영어로 작성합니다.
        - `answers` 의 각 단어는 입력 풀과 글자가 정확히 일치해야 합니다. \
          단어를 지어내지 마세요.
        - 풀 단어의 형태 변화형을 포함하지 마세요.
        - 질문은 간결하게(80자 이내), category 레이블은 짧게(30자 이내).

        중요 — 허술한 카테고리를 피하세요. 질문은 대부분의 영어 단어가
        답이 될 수 없을 정도로 구체적이어야 합니다:
        ❌ "Name a word that is a noun." — 어떤 명사든 답이 되어 게임 \
           성립 불가.
        ❌ "Name a word that is an adjective." — 같은 문제.
        ❌ "Name a word with more than 5 letters." — 범위가 너무 넓음.
        ✅ "Name a word that means happy." — 명확한 의미장.
        ✅ "Name a word ending in -tion." — 명확한 형태 패턴.
        ✅ "Name a word for a kitchen utensil." — 명확한 의미 영역.
        ✅ "Name a word with a Latin root meaning 'to lead'." — 명확한
           어원.

        공통점이 품사나 단어 길이뿐이라면, 그 cluster를 포기하고 다른
        공통 속성을 찾으세요 — 답의 수가 줄어들어도 괜찮습니다(최소
        2개는 필요).
        """

    private static let phrasyFeudInstructionsFR: String = """
        Vous rédigez des questions de quiz style Family Feud pour le \
        vocabulaire anglais. À partir d'un pool de mots anglais, \
        choisissez-en 2 à 6 partageant une propriété SPÉCIFIQUE et \
        ÉTROITE, et écrivez une seule question "Name a word that …" à \
        laquelle ils répondent tous.

        Règles strictes :
        - Le texte de la question doit être en anglais.
        - Chaque mot dans `answers` DOIT apparaître caractère par \
          caractère dans le pool. N'inventez PAS de mots.
        - Pas de variantes morphologiques des mots du pool.
        - Question concise (≤ 80 caractères), category court (≤ 30).

        CRITIQUE — évitez les catégories paresseuses. La question doit \
        être assez spécifique pour que la PLUPART des mots anglais n'y \
        répondent pas :
        ❌ "Name a word that is a noun." — n'importe quel nom convient ; \
           jeu inutile.
        ❌ "Name a word that is an adjective." — même problème.
        ❌ "Name a word with more than 5 letters." — trop générique.
        ✅ "Name a word that means happy." — champ sémantique étroit.
        ✅ "Name a word ending in -tion." — motif morphologique précis.
        ✅ "Name a word for a kitchen utensil." — domaine sémantique \
           étroit.
        ✅ "Name a word with a Latin root meaning 'to lead'." — étymologie \
           précise.

        Si les mots n'ont en commun que la partie du discours ou la \
        longueur, REJETEZ ce cluster et trouvez une autre propriété — \
        même si cela réduit le nombre de réponses (minimum 2).
        """

    private static let phrasyFeudInstructionsDE: String = """
        Du schreibst Family-Feud-Quizfragen für englischen Wortschatz. \
        Wähle aus einem Pool englischer Wörter 2-6 mit einer \
        SPEZIFISCHEN, ENGEN gemeinsamen Eigenschaft und formuliere \
        EINE einzige "Name a word that …"-Frage, auf die alle antworten.

        Strenge Regeln:
        - Der Fragetext MUSS auf Englisch sein.
        - Jedes Wort in `answers` MUSS zeichengenau im Pool stehen. \
          Keine Wörter erfinden.
        - Keine Flexionsvarianten der Pool-Wörter.
        - Frage knapp (≤ 80 Zeichen), category kurz (≤ 30 Zeichen).

        WICHTIG — vermeide entartete Kategorien. Die Frage muss so \
        spezifisch sein, dass die MEISTEN englischen Wörter NICHT \
        passen:
        ❌ "Name a word that is a noun." — jedes Nomen würde passen; \
           sinnloses Spiel.
        ❌ "Name a word that is an adjective." — gleiches Problem.
        ❌ "Name a word with more than 5 letters." — zu generisch.
        ✅ "Name a word that means happy." — enges Bedeutungsfeld.
        ✅ "Name a word ending in -tion." — enges morphologisches Muster.
        ✅ "Name a word for a kitchen utensil." — enges semantisches Feld.
        ✅ "Name a word with a Latin root meaning 'to lead'." — enge \
           Etymologie.

        Wenn die Wörter nur Wortart oder Länge teilen, VERWERFE den \
        Cluster und suche eine andere Eigenschaft — auch wenn dadurch \
        weniger Antworten herauskommen (Minimum 2 bleibt).
        """

    private static let phrasyFeudInstructionsES: String = """
        Escribes preguntas de quiz estilo Family Feud para vocabulario \
        inglés. De un pool de palabras inglesas, elige 2-6 que compartan \
        una propiedad ESPECÍFICA y ESTRECHA, y escribe UNA sola pregunta \
        "Name a word that …" que todas respondan.

        Reglas estrictas:
        - El texto de la pregunta DEBE estar en inglés.
        - Cada palabra en `answers` DEBE aparecer carácter por carácter \
          en el pool. NO inventes palabras.
        - Sin variantes morfológicas de palabras del pool.
        - Pregunta concisa (≤ 80 caracteres), category breve (≤ 30).

        CRÍTICO — evita categorías degeneradas. La pregunta debe ser tan \
        específica que la MAYORÍA de palabras inglesas NO la respondan:
        ❌ "Name a word that is a noun." — cualquier sustantivo vale; \
           juego inútil.
        ❌ "Name a word that is an adjective." — mismo problema.
        ❌ "Name a word with more than 5 letters." — demasiado genérico.
        ✅ "Name a word that means happy." — campo semántico estrecho.
        ✅ "Name a word ending in -tion." — patrón morfológico preciso.
        ✅ "Name a word for a kitchen utensil." — dominio semántico \
           estrecho.
        ✅ "Name a word with a Latin root meaning 'to lead'." — etimología \
           precisa.

        Si las palabras solo comparten parte de la oración o longitud, \
        RECHAZA ese cluster y busca otra propiedad — aunque resulten \
        menos respuestas (mínimo 2 sigue aplicando).
        """

    private static let phrasyFeudInstructionsPT: String = """
        Você escreve perguntas de quiz estilo Family Feud para \
        vocabulário inglês. De um pool de palavras inglesas, escolha \
        2-6 que compartilhem uma propriedade ESPECÍFICA e ESTREITA, \
        e escreva UMA única pergunta "Name a word that …" que todas \
        respondam.

        Regras estritas:
        - O texto da pergunta DEVE estar em inglês.
        - Cada palavra em `answers` DEVE aparecer caractere por \
          caractere no pool. NÃO invente palavras.
        - Sem variantes morfológicas das palavras do pool.
        - Pergunta concisa (≤ 80 caracteres), category breve (≤ 30).

        CRÍTICO — evite categorias preguiçosas. A pergunta deve ser \
        específica o suficiente para que a MAIORIA das palavras \
        inglesas NÃO responda:
        ❌ "Name a word that is a noun." — qualquer substantivo serve; \
           jogo inútil.
        ❌ "Name a word that is an adjective." — mesmo problema.
        ❌ "Name a word with more than 5 letters." — genérico demais.
        ✅ "Name a word that means happy." — campo semântico estreito.
        ✅ "Name a word ending in -tion." — padrão morfológico preciso.
        ✅ "Name a word for a kitchen utensil." — domínio semântico \
           estreito.
        ✅ "Name a word with a Latin root meaning 'to lead'." — etimologia \
           precisa.

        Se as palavras só compartilham classe gramatical ou comprimento, \
        REJEITE esse cluster e busque outra propriedade — mesmo que \
        resulte em menos respostas (mínimo 2 continua valendo).
        """

    // ---- Phrasy Feud FALLBACK INSTRUCTIONS (8 languages) -------------

    private static let phrasyFeudFallbackInstructionsEN: String = """
        You write Family Feud-style quiz questions. Given ONE English
        word, write a single concise "Name a word that …" question (in
        English, ≤ 80 chars) whose only valid answer is exactly that
        word, plus a short category label in English (≤ 30 chars).
        """

    private static let phrasyFeudFallbackInstructionsZH: String = """
        你是 Family Feud 命题人。给定一个英文单词，请写一道简洁的
        "Name a word that …" 风格英文问题（≤ 80 字符），其唯一答案恰好
        就是该单词，同时给出一个简短的英文 category 标签（≤ 30 字符）。
        """

    private static let phrasyFeudFallbackInstructionsJA: String = """
        あなたは Family Feud のクイズ作家です。1 つの英単語が与えられた
        とき、その単語そのものだけが正解となる簡潔な「Name a word that …」
        形式の英語の質問（80 字以内）と、英語の短い category ラベル
        （30 字以内）を作成してください。
        """

    private static let phrasyFeudFallbackInstructionsKO: String = """
        당신은 Family Feud 퀴즈 작가입니다. 영어 단어 1개가 주어지면, 그
        단어만이 유일한 정답이 되는 간결한 "Name a word that …" 형식의
        영어 질문(80자 이내)과 영어로 된 짧은 category 레이블(30자 이내)을
        작성하세요.
        """

    private static let phrasyFeudFallbackInstructionsFR: String = """
        Vous rédigez des questions Family Feud. À partir d'UN mot \
        anglais, écrivez une seule question concise "Name a word that …" \
        (en anglais, ≤ 80 caractères) dont la seule réponse valide est \
        exactement ce mot, plus un court label category en anglais \
        (≤ 30 caractères).
        """

    private static let phrasyFeudFallbackInstructionsDE: String = """
        Du schreibst Family-Feud-Quizfragen. Gegeben EIN englisches \
        Wort, formuliere eine einzige knappe "Name a word that …"-Frage \
        (auf Englisch, ≤ 80 Zeichen), deren einzige gültige Antwort \
        exakt dieses Wort ist, plus ein kurzes englisches \
        category-Label (≤ 30 Zeichen).
        """

    private static let phrasyFeudFallbackInstructionsES: String = """
        Escribes preguntas Family Feud. Dada UNA palabra inglesa, \
        escribe una sola pregunta concisa "Name a word that …" (en \
        inglés, ≤ 80 caracteres) cuya única respuesta válida sea \
        exactamente esa palabra, más una etiqueta category breve en \
        inglés (≤ 30 caracteres).
        """

    private static let phrasyFeudFallbackInstructionsPT: String = """
        Você escreve perguntas Family Feud. Dada UMA palavra inglesa, \
        escreva uma única pergunta concisa "Name a word that …" (em \
        inglês, ≤ 80 caracteres) cuja única resposta válida seja \
        exatamente essa palavra, mais um rótulo category breve em \
        inglês (≤ 30 caracteres).
        """

    // ---- Phrasy Feud CRITIQUE INSTRUCTIONS (8 languages) -------------
    //
    // LLM-as-judge: a separate model call evaluates whether a generated
    // multi-word question passes as a real Family Feud-style question
    // or is a degenerate / lazy categorization. Instructions are
    // explicit about ❌ examples (including the "English word that is
    // a noun" evasion the generator tried) so the judge has concrete
    // anchors. Verdict comes back as a Bool + reason in
    // `FeudQuestionVerdict`.

    private static let phrasyFeudCritiqueInstructionsEN: String = """
        You review Family Feud quiz questions. Your DEFAULT verdict is
        ACCEPT (isHighQuality=true). Reject (isHighQuality=false) ONLY
        if the question matches one of these specific lazy patterns:

        REJECT patterns (and ONLY these):
        ❌ "Name a word that is a noun." — pure part-of-speech.
        ❌ "Name a word that is a verb / adjective / adverb." — same.
        ❌ "Name an English word that is a noun." — wrapping with
           "English word" doesn't fix it; same lazy pattern.
        ❌ "Name a word with more than N letters." — pure word length.
        ❌ "Name an English word." — no actual constraint at all.

        ACCEPT everything else, including:
        ✅ Semantic narrowing: "means happy", "describes anger",
           "for [domain]", "type of weather"
        ✅ Morphological narrowing: "ends in -tion", "starts with un-",
           "contains -graph-", "rhymes with bell"
        ✅ Etymology: "from Latin", "Greek root meaning ___"
        ✅ Register / formality: "formal", "archaic", "slang"
        ✅ Domain / field: "kitchen utensil", "musical term", "legal term"

        DO NOT call a question "too generic" if it has ANY concrete
        narrowing from the list above — even simple ones like
        "ends in -tion" pass. Your bar is LOW; only block the obviously
        useless ones listed in the REJECT section.

        Always provide a one-sentence English `reason` (≤ 60 chars) —
        debug logs only, never shown to the user.
        """

    private static let phrasyFeudCritiqueInstructionsZH: String = """
        你审查 Family Feud 问题。**默认判定 ACCEPT**（isHighQuality=true）。
        仅当问题符合下列具体偷懒模式之一时才拒绝：

        拒绝模式（仅限以下情况）：
        ❌ "Name a word that is a noun." —— 单纯词性分类。
        ❌ "Name a word that is a verb / adjective / adverb." —— 同。
        ❌ "Name an English word that is a noun." —— 加 "English word"
           包装也无济于事，仍属同一烂题。
        ❌ "Name a word with more than N letters." —— 单纯词长。
        ❌ "Name an English word." —— 完全没有约束。

        其他全部 ACCEPT，包括：
        ✅ 语义收窄："means happy"、"describes anger"、"for [领域]"、
           "type of weather"
        ✅ 形态收窄："ends in -tion"、"starts with un-"、"contains
           -graph-"、"rhymes with bell"
        ✅ 词源："from Latin"、"Greek root meaning ___"
        ✅ 语域 / 正式度："formal"、"archaic"、"slang"
        ✅ 领域 / 行业："kitchen utensil"、"musical term"、"legal term"

        只要问题有上面任何一种具体收窄（哪怕只是 "ends in -tion" 这么
        简单），都不要判 "too generic"。你的门槛要**低**，只挡显然
        烂题（拒绝列表里的那些）。

        始终用一句英文（≤ 60 字符）解释判断，仅用于 debug 日志。
        """

    private static let phrasyFeudCritiqueInstructionsJA: String = """
        あなたは Family Feud の質問品質を審査する厳格なレビュアーです。
        生成された質問がプレイヤーに見せる価値があるか、それとも怠慢
        な/凡庸な分類で再生成すべきか判定してください。

        拒否（isHighQuality=false）—— 余計な語で包んでいても拒否：
        ❌ "Name a word that is a noun." —— 名詞ならどれでも該当。
        ❌ "Name an English word that is a noun." —— "English" を付けても
           制約が狭まらない、同じ問題。
        ❌ "Name a word that is an adjective." / verb / adverb —— 同様。
        ❌ "Name a word with more than 5 letters." —— 範囲が広すぎる。
        ❌ "Name an English word." —— 実質的な制約がない。

        承認（isHighQuality=true）—— 具体的な意味分野、形態パターン、
        語源、語域、領域に絞られた、本物の番組司会者が出題するような
        質問のみ：
        ✅ "Name a word that means happy."
        ✅ "Name a word ending in -tion."
        ✅ "Name a kitchen utensil."
        ✅ "Name a word with a Latin root meaning 'to lead'."

        判定理由を必ず英語の一文（60 字以内）で `reason` に書く。
        debug ログ用、ユーザーには表示されない。
        """

    private static let phrasyFeudCritiqueInstructionsKO: String = """
        당신은 Family Feud 퀴즈 질문의 엄격한 품질 검토자입니다. 생성된
        질문을 플레이어에게 보낼 만큼 좋은지, 게으른/부적절한 분류로
        다시 생성해야 하는지 판단하세요.

        거부(isHighQuality=false) — 추가 단어로 포장해도 거부:
        ❌ "Name a word that is a noun." — 어떤 명사든 답이 되어 의미 없음.
        ❌ "Name an English word that is a noun." — "English"를 붙여도
           제약이 좁아지지 않음, 같은 문제.
        ❌ "Name a word that is an adjective." / verb / adverb — 동일.
        ❌ "Name a word with more than 5 letters." — 범위가 너무 넓음.
        ❌ "Name an English word." — 실질적 제약 없음.

        승인(isHighQuality=true) — 구체적인 의미장, 형태 패턴, 어원,
        언어 사용역, 영역으로 좁혀진 실제 게임쇼 진행자가 낼 만한 질문만:
        ✅ "Name a word that means happy."
        ✅ "Name a word ending in -tion."
        ✅ "Name a kitchen utensil."
        ✅ "Name a word with a Latin root meaning 'to lead'."

        판정 이유는 항상 영어 한 문장(60자 이내)으로 `reason`에 작성 —
        debug 로그 용도, 사용자에게 표시되지 않음.
        """

    private static let phrasyFeudCritiqueInstructionsFR: String = """
        Vous êtes un évaluateur strict de questions Family Feud. \
        Décidez si une question générée vaut la peine d'être montrée \
        aux joueurs, ou si elle est paresseuse/dégénérée et doit être \
        régénérée.

        Rejetez (isHighQuality=false) — même habillée de mots en plus :
        ❌ "Name a word that is a noun." — n'importe quel nom convient.
        ❌ "Name an English word that is a noun." — ajouter "English" \
           ne resserre pas la contrainte, même problème.
        ❌ "Name a word that is an adjective." / verb / adverb — pareil.
        ❌ "Name a word with more than 5 letters." — trop générique.
        ❌ "Name an English word." — aucune vraie contrainte.

        Acceptez (isHighQuality=true) — uniquement si la question est \
        resserrée à un champ sémantique, motif morphologique, étymologie, \
        registre ou domaine spécifique :
        ✅ "Name a word that means happy."
        ✅ "Name a word ending in -tion."
        ✅ "Name a kitchen utensil."
        ✅ "Name a word with a Latin root meaning 'to lead'."

        Donnez toujours `reason` en une phrase anglaise (≤ 60 \
        caractères), utilisée uniquement dans les logs debug.
        """

    private static let phrasyFeudCritiqueInstructionsDE: String = """
        Du bist ein strenger Qualitätsprüfer für Family-Feud-Quizfragen. \
        Entscheide, ob eine generierte Frage gut genug ist, um sie den \
        Spielern zu zeigen, oder faul/entartet und neu zu generieren.

        Ablehnen (isHighQuality=false) — auch wenn mit Zusatzwörtern \
        verkleidet:
        ❌ "Name a word that is a noun." — jedes Nomen passt, sinnlos.
        ❌ "Name an English word that is a noun." — "English" einzufügen \
           verengt die Bedingung nicht, gleiches Problem.
        ❌ "Name a word that is an adjective." / verb / adverb — dito.
        ❌ "Name a word with more than 5 letters." — zu generisch.
        ❌ "Name an English word." — keine echte Einschränkung.

        Akzeptieren (isHighQuality=true) — nur wenn die Frage auf ein \
        spezifisches Bedeutungsfeld, morphologisches Muster, eine \
        Etymologie, ein Register oder einen Bereich verengt ist:
        ✅ "Name a word that means happy."
        ✅ "Name a word ending in -tion."
        ✅ "Name a kitchen utensil."
        ✅ "Name a word with a Latin root meaning 'to lead'."

        Gib `reason` immer als einen englischen Satz (≤ 60 Zeichen) \
        an, nur für Debug-Logs.
        """

    private static let phrasyFeudCritiqueInstructionsES: String = """
        Eres un revisor estricto de calidad de preguntas Family Feud. \
        Decide si una pregunta generada vale la pena mostrarse a los \
        jugadores o es perezosa/degenerada y debe regenerarse.

        Rechaza (isHighQuality=false) — aun adornada con palabras extra:
        ❌ "Name a word that is a noun." — cualquier sustantivo vale.
        ❌ "Name an English word that is a noun." — añadir "English" no \
           estrecha la restricción, mismo problema.
        ❌ "Name a word that is an adjective." / verb / adverb — igual.
        ❌ "Name a word with more than 5 letters." — demasiado genérico.
        ❌ "Name an English word." — sin restricción real.

        Acepta (isHighQuality=true) — solo si la pregunta se estrecha a \
        un campo semántico, patrón morfológico, etimología, registro o \
        dominio específicos:
        ✅ "Name a word that means happy."
        ✅ "Name a word ending in -tion."
        ✅ "Name a kitchen utensil."
        ✅ "Name a word with a Latin root meaning 'to lead'."

        Da siempre `reason` como una oración en inglés (≤ 60 \
        caracteres), solo para logs de debug.
        """

    private static let phrasyFeudCritiqueInstructionsPT: String = """
        Você é um revisor estrito de qualidade de perguntas Family \
        Feud. Decida se uma pergunta gerada vale a pena mostrar aos \
        jogadores ou é preguiçosa/degenerada e deve ser regerada.

        Rejeite (isHighQuality=false) — mesmo enfeitada com palavras \
        extras:
        ❌ "Name a word that is a noun." — qualquer substantivo serve.
        ❌ "Name an English word that is a noun." — adicionar "English" \
           não estreita a restrição, mesmo problema.
        ❌ "Name a word that is an adjective." / verb / adverb — igual.
        ❌ "Name a word with more than 5 letters." — genérico demais.
        ❌ "Name an English word." — sem restrição real.

        Aceite (isHighQuality=true) — apenas se a pergunta se estreita a \
        um campo semântico, padrão morfológico, etimologia, registro ou \
        domínio específicos:
        ✅ "Name a word that means happy."
        ✅ "Name a word ending in -tion."
        ✅ "Name a kitchen utensil."
        ✅ "Name a word with a Latin root meaning 'to lead'."

        Sempre forneça `reason` como uma frase em inglês (≤ 60 \
        caracteres), apenas para logs de debug.
        """

    // ---- Phrasy Feud FITNESS INSTRUCTIONS (8 languages) --------------
    //
    // Third validation layer (after pool-membership + question critique):
    // ask the model to judge whether EACH candidate answer actually
    // satisfies the question. Catches the generator's recurring "right
    // question, wrong answers" failure mode where it puts 'quetch' under
    // "ends in -tion" or 'adduction' under "means to lead".
    //
    // Strict checking: etymology / shared root / "kind of related" all
    // count as REJECT. Modern English meaning must match the constraint
    // exactly. Examples in each language spell this out.

    private static let phrasyFeudFitnessInstructionsEN: String = """
        You verify candidate answers for a Family Feud quiz question.
        Given a question and a list of candidate words, decide for EACH
        word whether it STRICTLY satisfies the question's constraint.
        Output a verdict for every input word (same character-for-
        character spelling), in the same order.

        Be strict — reject unless the modern English meaning UNAMBIGUOUSLY
        matches. Etymology or shared root is NOT enough.

        Examples:
        ❌ Q "Name a word ending in -tion." Word: "quetch" →
           fits=false, reason="does not end in -tion"
        ❌ Q "Name a word meaning 'to lead'." Word: "adduction" →
           fits=false, reason="modern meaning is anatomical movement,\
           not 'to lead'"
        ❌ Q "Name a kitchen utensil." Word: "umbrella" →
           fits=false, reason="not a kitchen item"
        ✅ Q "Name a word meaning happy." Word: "joyful" →
           fits=true, reason=""
        ✅ Q "Name a word ending in -tion." Word: "abduction" →
           fits=true, reason=""

        For words where fits=true, leave reason empty (or one neutral
        phrase). For fits=false, give a brief (≤60 char) English reason.
        """

    private static let phrasyFeudFitnessInstructionsZH: String = """
        你为 Family Feud 题目核验候选答案。给定一个问题和候选单词列表，
        判断**每个**单词是否**严格**满足问题约束。每个输入单词都要输出
        一条判断（拼写与输入逐字符一致），顺序保持。

        严格判断 —— 必须现代英文含义**完全匹配**才接受。词源、共同
        词根、"沾边"都不算。

        示例：
        ❌ 问："Name a word ending in -tion." 词："quetch" →
           fits=false, reason="does not end in -tion"
        ❌ 问："Name a word meaning 'to lead'." 词："adduction" →
           fits=false, reason="modern meaning is anatomical movement,\
           not 'to lead'"
        ❌ 问："Name a kitchen utensil." 词："umbrella" →
           fits=false, reason="not a kitchen item"
        ✅ 问："Name a word meaning happy." 词："joyful" →
           fits=true, reason=""
        ✅ 问："Name a word ending in -tion." 词："abduction" →
           fits=true, reason=""

        fits=true 时 reason 留空（或中性短语）；fits=false 时给一句
        英文简短理由（不超过 60 字符）。
        """

    private static let phrasyFeudFitnessInstructionsJA: String = """
        Family Feud の質問に対する候補回答を検証します。質問と候補単語
        のリストが与えられたとき、**各**単語が質問の制約を**厳密に**
        満たすか判断してください。すべての入力単語について判定を
        出力すること（綴り完全一致、順序維持）。

        厳格に判定 — 現代英語の意味が**明確に一致**する場合のみ承認。
        語源・共通語根・「関連あり」は不可。

        例：
        ❌ Q「Name a word ending in -tion.」word "quetch" →
           fits=false, reason="does not end in -tion"
        ❌ Q「Name a word meaning 'to lead'.」word "adduction" →
           fits=false, reason="modern meaning is anatomical movement,\
           not 'to lead'"
        ❌ Q「Name a kitchen utensil.」word "umbrella" →
           fits=false, reason="not a kitchen item"
        ✅ Q「Name a word meaning happy.」word "joyful" →
           fits=true, reason=""
        ✅ Q「Name a word ending in -tion.」word "abduction" →
           fits=true, reason=""

        fits=true の場合は reason 空（または中立的な短文）。
        fits=false の場合は英語で短い理由（60 字以内）。
        """

    private static let phrasyFeudFitnessInstructionsKO: String = """
        Family Feud 질문에 대한 후보 답안을 검증합니다. 질문과 후보
        단어 목록이 주어지면, **각** 단어가 질문의 제약을 **엄격히**
        만족하는지 판단하세요. 모든 입력 단어에 대해 판정을 출력
        (철자 완전 일치, 순서 유지).

        엄격히 판단 — 현대 영어 의미가 **명확히 일치**할 때만 승인.
        어원, 공유 어근, "관련 있음"은 불충분.

        예시:
        ❌ Q "Name a word ending in -tion." word "quetch" →
           fits=false, reason="does not end in -tion"
        ❌ Q "Name a word meaning 'to lead'." word "adduction" →
           fits=false, reason="modern meaning is anatomical movement,\
           not 'to lead'"
        ❌ Q "Name a kitchen utensil." word "umbrella" →
           fits=false, reason="not a kitchen item"
        ✅ Q "Name a word meaning happy." word "joyful" →
           fits=true, reason=""
        ✅ Q "Name a word ending in -tion." word "abduction" →
           fits=true, reason=""

        fits=true일 때 reason 비움(또는 중립적 짧은 문구). fits=false
        일 때 영어로 짧은 이유(60자 이내).
        """

    private static let phrasyFeudFitnessInstructionsFR: String = """
        Vous vérifiez les réponses candidates pour une question Family \
        Feud. Étant donné une question et une liste de mots candidats, \
        décidez pour CHAQUE mot s'il satisfait STRICTEMENT la \
        contrainte de la question. Émettez un verdict pour chaque mot \
        d'entrée (orthographe identique, ordre préservé).

        Soyez strict — n'acceptez que si le sens anglais moderne \
        correspond SANS AMBIGUÏTÉ. Étymologie ou racine partagée NE \
        suffit PAS.

        Exemples :
        ❌ Q "Name a word ending in -tion." Mot "quetch" →
           fits=false, reason="does not end in -tion"
        ❌ Q "Name a word meaning 'to lead'." Mot "adduction" →
           fits=false, reason="modern meaning is anatomical movement,\
           not 'to lead'"
        ❌ Q "Name a kitchen utensil." Mot "umbrella" →
           fits=false, reason="not a kitchen item"
        ✅ Q "Name a word meaning happy." Mot "joyful" →
           fits=true, reason=""
        ✅ Q "Name a word ending in -tion." Mot "abduction" →
           fits=true, reason=""

        Quand fits=true, laissez reason vide (ou une formule neutre). \
        Quand fits=false, donnez une raison brève en anglais (≤60 car.).
        """

    private static let phrasyFeudFitnessInstructionsDE: String = """
        Du prüfst Kandidaten-Antworten zu einer Family-Feud-Frage. \
        Gegeben eine Frage und eine Liste von Kandidatenwörtern, \
        entscheide für JEDES Wort, ob es die Bedingung der Frage \
        STRENG erfüllt. Gib für jedes Eingabewort ein Urteil aus \
        (Schreibweise zeichengenau, Reihenfolge erhalten).

        Streng prüfen — nur zustimmen, wenn die moderne englische \
        Bedeutung EINDEUTIG passt. Etymologie / gemeinsame Wurzel \
        reicht NICHT.

        Beispiele:
        ❌ F "Name a word ending in -tion." Wort "quetch" →
           fits=false, reason="does not end in -tion"
        ❌ F "Name a word meaning 'to lead'." Wort "adduction" →
           fits=false, reason="modern meaning is anatomical movement,\
           not 'to lead'"
        ❌ F "Name a kitchen utensil." Wort "umbrella" →
           fits=false, reason="not a kitchen item"
        ✅ F "Name a word meaning happy." Wort "joyful" →
           fits=true, reason=""
        ✅ F "Name a word ending in -tion." Wort "abduction" →
           fits=true, reason=""

        Bei fits=true reason leer lassen (oder neutrale Floskel). Bei \
        fits=false einen kurzen englischen Grund (≤60 Zeichen) angeben.
        """

    private static let phrasyFeudFitnessInstructionsES: String = """
        Verificas respuestas candidatas para una pregunta Family Feud. \
        Dada una pregunta y una lista de palabras candidatas, decide \
        para CADA palabra si satisface ESTRICTAMENTE la restricción \
        de la pregunta. Emite un veredicto para cada palabra de \
        entrada (ortografía carácter por carácter, mismo orden).

        Sé estricto — solo acepta si el significado inglés moderno \
        coincide SIN AMBIGÜEDAD. Etimología o raíz compartida NO basta.

        Ejemplos:
        ❌ P "Name a word ending in -tion." Palabra "quetch" →
           fits=false, reason="does not end in -tion"
        ❌ P "Name a word meaning 'to lead'." Palabra "adduction" →
           fits=false, reason="modern meaning is anatomical movement,\
           not 'to lead'"
        ❌ P "Name a kitchen utensil." Palabra "umbrella" →
           fits=false, reason="not a kitchen item"
        ✅ P "Name a word meaning happy." Palabra "joyful" →
           fits=true, reason=""
        ✅ P "Name a word ending in -tion." Palabra "abduction" →
           fits=true, reason=""

        Cuando fits=true, deja reason vacío (o frase neutra). Cuando \
        fits=false, da una razón breve en inglés (≤60 caracteres).
        """

    private static let phrasyFeudFitnessInstructionsPT: String = """
        Você verifica respostas candidatas para uma pergunta Family \
        Feud. Dada uma pergunta e uma lista de palavras candidatas, \
        decida para CADA palavra se satisfaz ESTRITAMENTE a restrição \
        da pergunta. Emita um veredicto para cada palavra de entrada \
        (ortografia caractere por caractere, mesma ordem).

        Seja estrito — só aceite se o significado inglês moderno \
        corresponde SEM AMBIGUIDADE. Etimologia ou raiz comum NÃO basta.

        Exemplos:
        ❌ P "Name a word ending in -tion." Palavra "quetch" →
           fits=false, reason="does not end in -tion"
        ❌ P "Name a word meaning 'to lead'." Palavra "adduction" →
           fits=false, reason="modern meaning is anatomical movement,\
           not 'to lead'"
        ❌ P "Name a kitchen utensil." Palavra "umbrella" →
           fits=false, reason="not a kitchen item"
        ✅ P "Name a word meaning happy." Palavra "joyful" →
           fits=true, reason=""
        ✅ P "Name a word ending in -tion." Palavra "abduction" →
           fits=true, reason=""

        Quando fits=true, deixe reason vazio (ou frase neutra). Quando \
        fits=false, dê uma razão breve em inglês (≤60 caracteres).
        """
}
