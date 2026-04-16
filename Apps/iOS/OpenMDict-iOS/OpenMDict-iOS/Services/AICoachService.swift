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

    /// Instruction template families we've tuned for this POC.
    /// `.debugName` is only used in the diagnostic report.
    private enum NativeLanguage {
        case english
        case chinese

        var debugName: String {
            switch self {
            case .english: return "English"
            case .chinese: return "Chinese (bilingual output)"
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
        let prefix = String(deviceLang.prefix(2)).lowercased()
        switch prefix {
        case "zh": return .chinese
        // Future: "ja" → .japanese, "ko" → .korean, "fr" → .french, etc.
        default:   return .english
        }
    }

    /// Pick an instruction template based on the primary language of a
    /// Locale. Used only for diagnostic display ("static guess from
    /// Locale.current"). Runtime template selection uses
    /// `detectModelLanguage()` instead.
    private static func templateFamily(for locale: Locale) -> NativeLanguage {
        let code = locale.language.languageCode?.identifier ?? "en"
        switch code {
        case "zh": return .chinese
        default:   return .english
        }
    }

    private static func systemInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english: return systemInstructionsEN
        case .chinese: return systemInstructionsZH
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
        case .chinese:
            return """
                单词：\(word)

                词典原文：
                \(definition)

                请根据上方的词典释义，为这个英文单词生成一张学习卡片。
                """
        }
    }

    // MARK: - Morphology challenge templates (Among wUrdS)

    private static func morphologyInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english: return morphologyInstructionsEN
        case .chinese: return morphologyInstructionsZH
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
        case .chinese:
            return """
                目标单词：\(targetWord)
                请生成恰好 \(crewmateCount) 个同根词和 \
                \(imposterCount) 个伪同源词。
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

    // MARK: - Candidate generation templates (Word Relationship Quiz)

    private static func candidateInstructions(for native: NativeLanguage) -> String {
        switch native {
        case .english: return candidateInstructionsEN
        case .chinese: return candidateInstructionsZH
        }
    }

    private static func candidatePrompt(targetWord: String, native: NativeLanguage) -> String {
        switch native {
        case .english:
            return "Target word: \(targetWord)"
        case .chinese:
            return "目标单词：\(targetWord)"
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
}
