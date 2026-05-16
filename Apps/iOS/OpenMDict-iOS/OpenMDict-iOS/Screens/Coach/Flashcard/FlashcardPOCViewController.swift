//
//  FlashcardPOCViewController.swift
//  OpenMDict-iOS
//
//  M14 POC: minimal one-at-a-time flashcard review driven by Apple's
//  on-device Foundation Models.
//
//  Scope (deliberately minimal):
//  - Picks up to 5 English-looking words from BookmarkService (falls back to
//    a short default vocabulary list if the user has no bookmarks yet).
//  - For each word: MDict lookup → HTML-strip → AICoachService stream →
//    progressively fill the visible fields.
//  - "Reveal" and Again/Good/Easy buttons that ONLY print to debugLog. No
//    persistence, no SM-2 scheduling — that's deferred to real M14.
//  - Close button in the nav bar dismisses the modal.
//
//  What this POC is explicitly designed to answer:
//  - Does streaming hide the 20–30s latency acceptably?
//  - Is the AI output quality good enough to be useful for learning?
//  - Are there pathological cases (empty definitions, non-English content)
//    we need to guard against in real M14?
//

import UIKit
import OpenMDictKit

#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26, *)
final class FlashcardPOCViewController: UIViewController {

    // MARK: - Model

    private struct CardSource: Sendable {
        let word: String
        /// Plain-text, HTML-stripped, length-capped definition to feed the model.
        let definitionContext: String
        /// Human-readable dictionary name, shown as a footnote.
        let dictName: String
    }

    private enum LoadState {
        case idle
        case loading
        case streaming(AICoachService.Flashcard.PartiallyGenerated)
        case done(AICoachService.Flashcard.PartiallyGenerated)
        case failed(String)
    }

    // MARK: - State

    private var sources: [CardSource] = []
    private var currentIndex: Int = 0
    private var state: LoadState = .idle
    private var revealed: Bool = false
    private var generationTask: Task<Void, Never>?

    // MARK: - Views

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let headerLabel = UILabel()       // "Card X of Y"
    private let wordLabel = UILabel()         // the headword itself
    private let dictFootnote = UILabel()      // "from <dictionary name>"
    /// Status text / error messages / diagnostic reports. A UITextView,
    /// not a UILabel, specifically so the user can long-press-select-copy
    /// on-device when things go wrong — no Xcode console tethering, no
    /// screenshot-then-OCR gymnastics.
    private let statusView = UITextView()

    private let definitionTitle = UILabel()
    private let definitionBody = UILabel()

    private let exampleTitle = UILabel()
    private let exampleBody = UILabel()

    private let hintTitle = UILabel()
    private let hintBody = UILabel()

    private let relatedTitle = UILabel()
    private let relatedBody = UILabel()

    private let revealButton = UIButton(type: .system)
    private let ratingStack = UIStackView()
    private let againButton = UIButton(type: .system)
    private let goodButton = UIButton(type: .system)
    private let easyButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    /// Only shown in the failure / unsupported-locale state. Opens the
    /// OpenMDict page in Settings.app so the user can flip its per-app
    /// Preferred Language without navigating through Settings manually.
    private let openSettingsButton = UIButton(type: .system)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.AICoach.Flashcard.title
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )

        buildLayout()

        // One consolidated diagnostic dump per VC lifetime. Xcode console
        // will show a clearly delimited block that's easy to spot and
        // copy-paste.
        debugLog("🪄 AICoach POC viewDidLoad → \(AICoach.diagnosticSummary)")
        debugLog(AICoachService.diagnosticReportForLog())

        // Hard-fail early if the system reports the model isn't available
        // at all (Apple Intelligence off, model downloading, etc.)
        if let reason = AICoach.unavailableDescription {
            showDiagnosticState(
                header: L10n.AICoach.Flashcard.notReady,
                emoji: "⚠️",
                message: reason + "\n\n" + AICoachService.diagnosticReport()
            )
            return
        }

        // Note: we used to hard-fail here when `isCurrentLocaleSupported()`
        // was false, to avoid burning 5–10 s on a doomed request. That
        // gate has been removed — we now AT LEAST TRY an
        // English attempt when the device locale isn't on Apple's
        // support list, since English is always available and we never
        // actually tried a plain English session (only overridden ones).
        // `AICoachService.streamFlashcard` now force-picks the English
        // template when the device locale isn't supported.
        if !AICoachService.isCurrentLocaleSupported() {
            debugLog("⚠️ AICoach: Locale.current not in supportedLanguages — will attempt English anyway")
        }

        loadSources()
        if sources.isEmpty {
            showEmptyState()
        } else {
            beginCurrentCard()
        }
    }

    /// Paint the VC into an "error / not ready" layout: custom header,
    /// custom big emoji instead of the headword, multi-line selectable
    /// diagnostic in the status area, and all bottom buttons hidden.
    /// Used by every error path (unavailable, locale unsupported,
    /// generation failure) so the UX is consistent.
    private func showDiagnosticState(header: String, emoji: String, message: String) {
        headerLabel.text = header
        wordLabel.text = emoji
        dictFootnote.text = ""
        setStatusText(message, monospaced: true)
        definitionBody.text = " "
        exampleBody.text = " "
        hintBody.text = " "
        relatedBody.text = " "
        state = .failed(message)
        sources = []
        updateButtonVisibility()
    }

    /// Update the selectable status text view, optionally switching to a
    /// monospaced font (useful for the multi-line locale diagnostic so
    /// the columns don't smear together).
    private func setStatusText(_ text: String, monospaced: Bool = false) {
        statusView.text = text
        statusView.font = monospaced
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .preferredFont(forTextStyle: .footnote)
    }

    /// Canonical error message for "device locale not in supportedLanguages".
    ///
    /// Suggests **per-app language change** as the primary fix — this is
    /// the least-invasive workaround because:
    /// - Does NOT affect iCloud / App Store region
    /// - Does NOT affect device-wide Language (other apps stay as-is)
    /// - Does NOT affect Region (date/currency/measurement formats stay
    ///   as-is, appropriate for wherever the user physically lives)
    /// - Only affects OpenMDict itself — the user can even revert it
    ///   immediately after the AI Coach session ends
    ///
    /// Requires that the app declares the target language in its
    /// `CFBundleLocalizations` / xcstrings — OpenMDict does (13 locs).
    ///
    /// Includes the full diagnostic report at the end for easy copy-out.
    private static func unsupportedLocaleMessage() -> String {
        """
        Apple’s on-device language model doesn’t support your current \
        device locale.

        Apple Intelligence matches locales against the full language+\
        script+region tag. Even when your language IS supported, the \
        particular combination with your Region may not be. Example: \
        Simplified Chinese + United States → locale “zh-Hans-US”, \
        which isn’t in Apple’s supported list — Apple only supports \
        “zh-Hans-CN”, “zh-Hant-HK”, “zh-Hant-TW” for Chinese. Users \
        living outside China/HK/TW are stuck. (This is an Apple \
        Intelligence oversight — English and Spanish have diaspora-\
        friendly region variants, Chinese does not.)

        Best workaround — per-app language (only affects OpenMDict, \
        leaves all other apps alone):

        1. Tap the button below to jump to OpenMDict’s system settings.
        2. Find “Preferred Language” near the top.
        3. Pick English.
        4. Come back here. AI Coach will now run English flashcards.

        You can revert step 3 any time — the setting is per-app, so \
        your other apps, device-wide language, Region, iCloud, and App \
        Store account are all unaffected.

        ─── Full diagnostic (long-press to copy) ───

        \(AICoachService.diagnosticReport())
        """
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        generationTask?.cancel()
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentStack.isLayoutMarginsRelativeArrangement = true
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // Header + word block
        headerLabel.font = .preferredFont(forTextStyle: .footnote)
        headerLabel.textColor = .secondaryLabel

        wordLabel.font = .systemFont(ofSize: 36, weight: .bold)
        wordLabel.numberOfLines = 0
        wordLabel.textColor = .label

        dictFootnote.font = .preferredFont(forTextStyle: .caption1)
        dictFootnote.textColor = .tertiaryLabel
        dictFootnote.numberOfLines = 0

        statusView.font = .preferredFont(forTextStyle: .footnote)
        statusView.textColor = .secondaryLabel
        statusView.backgroundColor = .clear
        statusView.isEditable = false
        statusView.isSelectable = true               // long-press to copy
        statusView.isScrollEnabled = false           // let the outer UIScrollView handle it
        statusView.textContainer.lineFragmentPadding = 0
        statusView.textContainerInset = .zero
        statusView.dataDetectorTypes = []

        let headerStack = UIStackView(arrangedSubviews: [headerLabel, wordLabel, dictFootnote])
        headerStack.axis = .vertical
        headerStack.spacing = 4

        contentStack.addArrangedSubview(headerStack)
        contentStack.addArrangedSubview(statusView)

        // Body sections
        contentStack.addArrangedSubview(makeSection(title: definitionTitle,
                                                    body: definitionBody,
                                                    titleText: L10n.AICoach.Flashcard.sectionDefinition))
        contentStack.addArrangedSubview(makeSection(title: exampleTitle,
                                                    body: exampleBody,
                                                    titleText: L10n.AICoach.Flashcard.sectionExample))
        contentStack.addArrangedSubview(makeSection(title: hintTitle,
                                                    body: hintBody,
                                                    titleText: L10n.AICoach.Flashcard.sectionMnemonic))
        contentStack.addArrangedSubview(makeSection(title: relatedTitle,
                                                    body: relatedBody,
                                                    titleText: L10n.AICoach.Flashcard.sectionRelated))

        // Reveal button
        revealButton.configuration = .filled()
        revealButton.setTitle(L10n.AICoach.Flashcard.reveal, for: .normal)
        revealButton.addTarget(self, action: #selector(revealTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(revealButton)

        // Ratings
        configureRatingButton(againButton, title: L10n.AICoach.Flashcard.again, color: .systemRed)
        configureRatingButton(goodButton,  title: L10n.AICoach.Flashcard.good,  color: .systemBlue)
        configureRatingButton(easyButton,  title: L10n.AICoach.Flashcard.easy,  color: .systemGreen)
        againButton.addTarget(self, action: #selector(againTapped), for: .touchUpInside)
        goodButton.addTarget(self, action: #selector(goodTapped),  for: .touchUpInside)
        easyButton.addTarget(self, action: #selector(easyTapped),  for: .touchUpInside)

        ratingStack.axis = .horizontal
        ratingStack.distribution = .fillEqually
        ratingStack.spacing = 12
        ratingStack.addArrangedSubview(againButton)
        ratingStack.addArrangedSubview(goodButton)
        ratingStack.addArrangedSubview(easyButton)
        contentStack.addArrangedSubview(ratingStack)

        // Next
        nextButton.configuration = .gray()
        nextButton.setTitle(L10n.AICoach.Flashcard.nextCard, for: .normal)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(nextButton)

        // Open-settings (error state only)
        var openSettingsConfig = UIButton.Configuration.filled()
        openSettingsConfig.title = L10n.AICoach.openSettings
        openSettingsConfig.image = UIImage(systemName: "gearshape")
        openSettingsConfig.imagePadding = 8
        openSettingsButton.configuration = openSettingsConfig
        openSettingsButton.addTarget(self, action: #selector(openSettingsTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(openSettingsButton)

        updateButtonVisibility()
    }

    private func makeSection(title: UILabel, body: UILabel, titleText: String) -> UIView {
        title.text = titleText
        title.font = .preferredFont(forTextStyle: .caption1).bold()
        title.textColor = .secondaryLabel
        body.font = .preferredFont(forTextStyle: .body)
        body.numberOfLines = 0
        body.textColor = .label

        let stack = UIStackView(arrangedSubviews: [title, body])
        stack.axis = .vertical
        stack.spacing = 4

        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        return card
    }

    private func configureRatingButton(_ button: UIButton, title: String, color: UIColor) {
        var cfg = UIButton.Configuration.tinted()
        cfg.baseForegroundColor = color
        cfg.baseBackgroundColor = color
        cfg.title = title
        button.configuration = cfg
    }

    // MARK: - Source selection

    /// Pick up to 5 words to review. Priority order:
    ///   1. User bookmarks (most recent first) whose heuristic "looks English".
    ///   2. If <5 after filtering, top up from recent lookup history.
    ///   3. If still <5 and sources is still empty, show the empty state
    ///      (we deliberately don't fall back to a canned word list — the
    ///      POC's value comes from reviewing YOUR real data).
    private func loadSources() {
        let wantCount = 5
        var picked: [CardSource] = []

        let bookmarks = BookmarkService.shared.allBookmarks()
        for bookmark in bookmarks {
            if picked.count >= wantCount { break }
            guard looksEnglish(bookmark.word) else { continue }
            guard let source = buildSource(word: bookmark.word, dictId: bookmark.dictId) else { continue }
            picked.append(source)
        }

        self.sources = picked
    }

    /// Coarse English filter: the word must contain at least one ASCII
    /// letter and must not contain any CJK / Arabic / Hangul characters.
    /// We don't care about false positives — mixed-script words are fine to
    /// skip in a POC, because the @Generable prompt assumes English.
    private func looksEnglish(_ word: String) -> Bool {
        var hasAscii = false
        for scalar in word.unicodeScalars {
            let value = scalar.value
            // ASCII letter
            if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
                hasAscii = true
                continue
            }
            // CJK Unified, CJK Ext-A, Hangul, Hiragana, Katakana, Arabic
            if (0x3040...0x30FF).contains(value) { return false }
            if (0x3400...0x4DBF).contains(value) { return false }
            if (0x4E00...0x9FFF).contains(value) { return false }
            if (0xAC00...0xD7AF).contains(value) { return false }
            if (0x0600...0x06FF).contains(value) { return false }
        }
        return hasAscii
    }

    private func buildSource(word: String, dictId: String) -> CardSource? {
        guard let dict = DictionaryService.shared.dict(id: dictId) else { return nil }
        guard let entry = dict.lookup(word) else { return nil }
        let plain = HTMLTextExtractor.extract(from: entry.article.html, maxLength: 400)
        guard !plain.isEmpty else { return nil }
        let name = DictMetadataService.shared.find(dictId: dictId)?.displayName ?? dict.displayTitle
        return CardSource(word: word, definitionContext: plain, dictName: name)
    }

    // MARK: - Per-card lifecycle

    private func beginCurrentCard() {
        guard sources.indices.contains(currentIndex) else {
            showAllDoneState()
            return
        }
        revealed = false
        state = .loading
        let source = sources[currentIndex]

        headerLabel.text = L10n.AICoach.Flashcard.cardProgress(currentIndex + 1, sources.count)
        wordLabel.text = source.word
        dictFootnote.text = "from \(source.dictName)"
        setStatusText(L10n.AICoach.Flashcard.generating)
        definitionBody.text = " "
        exampleBody.text = " "
        hintBody.text = " "
        relatedBody.text = " "
        updateButtonVisibility()

        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self else { return }
            let stream = AICoachService.shared.streamFlashcard(
                word: source.word,
                definitionContext: source.definitionContext
            )
            do {
                var lastPartial: AICoachService.Flashcard.PartiallyGenerated?
                for try await partial in stream {
                    if Task.isCancelled { return }
                    lastPartial = partial
                    self.state = .streaming(partial)
                    self.applyPartialToLabels(partial)
                }
                if let final = lastPartial {
                    self.state = .done(final)
                    self.setStatusText(L10n.AICoach.Flashcard.ready)
                } else {
                    self.state = .failed(L10n.AICoach.Flashcard.noContent)
                    self.setStatusText(L10n.AICoach.Flashcard.noContent)
                }
                self.updateButtonVisibility()
            } catch is CancellationError {
                // Silent
            } catch {
                let friendly = Self.friendlyErrorMessage(for: error)
                self.state = .failed(friendly)
                // Monospaced so the multi-line locale diagnostic stays
                // aligned. The user can long-press-select-copy from the
                // UITextView directly — no screenshot gymnastics needed.
                self.setStatusText(friendly, monospaced: true)
                debugLog("❌ AICoach generation failed: \(error)")
                debugLog(AICoachService.diagnosticReportForLog())
                self.updateButtonVisibility()
            }
        }
    }

    private func applyPartialToLabels(_ partial: AICoachService.Flashcard.PartiallyGenerated) {
        // Only show the body fields if the user has already tapped Reveal.
        // Until then, we still stream internally so Reveal is instant.
        guard revealed else { return }
        definitionBody.text = partial.definition ?? "…"
        exampleBody.text = partial.exampleSentence ?? "…"
        hintBody.text = partial.hint ?? "…"
        if let related = partial.relatedWords, !related.isEmpty {
            relatedBody.text = related.joined(separator: " · ")
        } else {
            relatedBody.text = "…"
        }
    }

    private func showEmptyState() {
        headerLabel.text = L10n.AICoach.Flashcard.noCardsHeader
        wordLabel.text = "🎴"
        dictFootnote.text = ""
        setStatusText(L10n.AICoach.Flashcard.noCards)
        definitionBody.text = " "
        exampleBody.text = " "
        hintBody.text = " "
        relatedBody.text = " "
        state = .idle
        updateButtonVisibility()
    }

    private func showAllDoneState() {
        headerLabel.text = L10n.done
        wordLabel.text = "✓"
        dictFootnote.text = ""
        setStatusText(L10n.AICoach.Flashcard.allDone(sources.count))
        definitionBody.text = " "
        exampleBody.text = " "
        hintBody.text = " "
        relatedBody.text = " "
        state = .idle
        updateButtonVisibility()
    }

    private func updateButtonVisibility() {
        let hasSources = !sources.isEmpty
        let atEnd = currentIndex >= sources.count
        let canReveal: Bool
        var isFailed = false
        switch state {
        case .streaming, .done:
            canReveal = hasSources && !atEnd && !revealed
        case .failed:
            canReveal = false
            isFailed = true
        default:
            canReveal = false
        }

        revealButton.isHidden = !canReveal
        ratingStack.isHidden = !(revealed && hasSources && !atEnd)
        nextButton.isHidden = !(revealed && hasSources && !atEnd)
        openSettingsButton.isHidden = !isFailed
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func openSettingsTapped() {
        // `UIApplication.openSettingsURLString` drops the user into THIS
        // app's page in Settings.app, where per-app Preferred Language
        // lives (when the app has multiple localizations declared —
        // OpenMDict has 13).
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    @objc private func revealTapped() {
        revealed = true
        if case .streaming(let partial) = state {
            applyPartialToLabels(partial)
        } else if case .done(let partial) = state {
            applyPartialToLabels(partial)
        }
        updateButtonVisibility()
    }

    @objc private func againTapped() { recordRating("again") }
    @objc private func goodTapped()  { recordRating("good")  }
    @objc private func easyTapped()  { recordRating("easy")  }

    private func recordRating(_ rating: String) {
        guard sources.indices.contains(currentIndex) else { return }
        let word = sources[currentIndex].word
        debugLog("📝 AI Coach POC: rated '\(word)' as \(rating)")
    }

    @objc private func nextTapped() {
        currentIndex += 1
        beginCurrentCard()
    }

    // MARK: - Error translation

    /// Convert a raw `LanguageModelSession.GenerationError` (or any other
    /// throwable) into a user-facing string. We special-case the cases
    /// a language-learning app is most likely to hit so the user gets
    /// actionable guidance instead of Apple's terse framework text.
    private static func friendlyErrorMessage(for error: Error) -> String {
        #if canImport(FoundationModels)
        if let genError = error as? LanguageModelSession.GenerationError {
            switch genError {
            case .unsupportedLanguageOrLocale:
                // Should not normally reach here because we pre-check
                // `isCurrentLocaleSupported()` in viewDidLoad, but if
                // the device locale somehow changes between the pre-
                // check and generation, fall back to the same canonical
                // message used by the pre-check.
                return unsupportedLocaleMessage()
            case .exceededContextWindowSize:
                return L10n.AICoach.contextTooLong
            case .guardrailViolation:
                return L10n.AICoach.guardrail
            case .assetsUnavailable:
                return L10n.AICoach.assetsUnavailable
            case .rateLimited:
                return L10n.AICoach.rateLimited
            default:
                break
            }
        }
        #endif
        return "Generation failed: \(error.localizedDescription)"
    }
}

// MARK: - UIFont helper

private extension UIFont {
    func bold() -> UIFont {
        guard let desc = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: desc, size: 0)
    }
}
