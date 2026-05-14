//
//  PhrasyFeudViewController.swift
//  OpenMDict-iOS
//
//  Family Feud parody quiz. The user's bookmarked words become the
//  hidden answers on a board; AI generates a "Name a word that …"
//  question that ties 2-6 of them together; user guesses by typing.
//
//  As of step 2:
//    - `viewDidLoad` calls `startEngine()` instead of the demo. The
//      engine fetches bookmarks via `BookmarkService`, gates on ≥ 24
//      `looksEnglish` words, and asks `AICoachService` for a Family-
//      Feud-style question + 2-6 answers from the user's own pool.
//    - Three placeholders (loading / not-enough-bookmarks / engine
//      error) cover the failure modes; loading borrows MorphemeMaury's
//      icon-+-spinner stack pattern.
//    - For step-2 verification ALL answer cards render REVEALED so the
//      validated AI output is visible end-to-end. Step 3 will flip
//      them to start blank and reveal on match (input + strike logic).
//
//  Layout (z-stacked under nav bar):
//    1. `FeudArchBackground` (full-screen) — proscenium-arch silhouette
//       with double border (dark brown outer + gold inner) framing the
//       dark-gray + yellow-dot play area.
//    2. Question banner — centered horizontally, ~half screen wide.
//    3. Answer board — wider, double-bordered card stack below banner.
//

import UIKit

@available(iOS 26, *)
final class PhrasyFeudViewController: UIViewController {

    // MARK: - Phase machine

    private enum Phase {
        case loading        // AI generating question + grouping bookmarks
        case questionReveal // banner pops in, board face-down
        case playing        // input active, cards reveal as matched
        case endRound       // 3 strikes OR all matched — flip remaining
        case finale         // total score + Next CTA
    }

    private var currentPhase: Phase = .loading

    // MARK: - UI

    private let archBackground = FeudArchBackground()
    private let banner = FeudQuestionBanner()
    private let board = FeudBoardView()
    private let buzzer = FeudBuzzerView()

    // Loading + placeholder overlay (mirrors MorphemeMaury's pattern:
    // a single centered vertical stack of icon + title + spinner +
    // subtitle, swapped between loading / placeholder by reconfiguring
    // the same subviews — no separate placeholder view).
    private let placeholderStack = UIStackView()
    private let placeholderIcon = UIImageView()
    private let placeholderTitle = UILabel()
    private let placeholderSubtitle = UILabel()
    private let placeholderSpinner = UIActivityIndicatorView(style: .large)
    private let placeholderRetryButton = UIButton(type: .system)

    /// Latest validated round, kept around so the match logic can
    /// look up the answer + score for a slot when it's revealed. The
    /// board itself only ever stores `.blank` / `.revealed` per card —
    /// the answer text isn't in the view layer at startup.
    private var currentRound: PhrasyFeudEngine.Round?

    /// Slots already revealed (so we don't waste a guess re-matching an
    /// already-flipped card). Reset whenever a new round is applied.
    /// Step 3 will consume this to drive strike-X overlay + game-over
    /// trigger; for now the only effect is "no double-credit".
    private var revealedSlots: Set<Int> = []

    /// Saved at viewWillAppear, restored at viewWillDisappear. tintColor
    /// isn't part of UINavigationBarAppearance, so we have to save +
    /// restore manually to avoid bleeding our gold tint into the AICoach
    /// facade once the user pops back.
    private var savedNavTintColor: UIColor?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.AICoach.phrasyFeud
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .black

        // Force dark appearance — show graphics expect black/dark surrounds.
        // Nav bar tint is overridden in `viewWillAppear` (UIKit reads nav
        // bar styling from the controller it's pushed onto).
        overrideUserInterfaceStyle = .dark

        setupLayout()
        setupPlaceholderUI()
        startEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Per-VC nav appearance — confined to this VC, no bleed into the
        // AICoach facade or any other parent in the stack. We use the
        // dimmer banner-text yellow (NOT the brighter bulb yellow of the
        // dots/bands) because text reads better in a slightly more muted
        // gold against the transparent bar.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [
            .foregroundColor: FeudPalette.goldText,
            .font: FeudPalette.bannerFont(size: 17),
        ]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance

        // tintColor (back chevron) isn't covered by `UINavigationBarAppearance`
        // — it's a UINavigationBar property, not an item one. Save + restore
        // around our window of override.
        savedNavTintColor = navigationController?.navigationBar.tintColor
        navigationController?.navigationBar.tintColor = FeudPalette.goldText
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Restore the parent's nav-bar tint so popping back to the AICoach
        // facade doesn't leave its back chevron painted gold. The standard
        // appearance auto-reverts because it's per-VC.
        navigationController?.navigationBar.tintColor = savedNavTintColor
    }

    // MARK: - Layout

    private func setupLayout() {
        // Arch backdrop fills the whole view, including under the nav bar
        // (the arch curves at the very top). Pin to view, NOT safe area.
        archBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(archBackground)

        // Question banner + board sit INSIDE the arch's content area.
        // Adding them as siblings of archBackground (not children of its
        // contentContainer) gives them direct constraints to the safe
        // area without wrestling with the arch's frame extending below.
        banner.translatesAutoresizingMaskIntoConstraints = false
        board.translatesAutoresizingMaskIntoConstraints = false
        // Banner must NEVER yield vertical space — the cards live inside
        // a scroll view, so vertical pressure should push card overflow
        // into the scroller, not collapse the banner. Default
        // compression resistance is .defaultHigh, which would lose to
        // any required constraint that needs a smaller banner.
        banner.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(banner)
        view.addSubview(board)

        buzzer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buzzer)
        buzzer.addAction(UIAction { [weak self] _ in
            self?.presentAnswerInput()
        }, for: .touchUpInside)

        let safe = view.safeAreaLayoutGuide

        // Banner width = `min(200, safe.width × 0.5)`. The two `<=` caps
        // bind the upper bound; the `=200` at .defaultHigh pulls the
        // banner up to 200pt when the wider cap allows. This keeps the
        // banner narrow on every device — the typical question is wider
        // than 172pt of label space at 17pt, so `numberOfLines = 0`
        // wraps it to multiple lines. Reads like a vintage TV monitor
        // rather than a stretched pill.
        let bannerPreferredWidth = banner.widthAnchor.constraint(equalToConstant: 200)
        bannerPreferredWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Arch starts at the safe-area top (BELOW the nav bar) — the
            // broadcast set has no chrome above the proscenium, and the
            // arch peak should sit just above the question banner, not be
            // hidden behind the iOS nav bar.
            archBackground.topAnchor.constraint(equalTo: safe.topAnchor),
            archBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            archBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            archBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Banner sits just below the arch curve at its sides. With
            // archDepth=60, the curve at the banner's left/right edges
            // (x≈W/4) descends to y≈15, and the bands extend ~8pt below
            // that (≈y=23). banner.top at safe.top+30 stays clear of the
            // bands but is close enough that the arch reads as "framing"
            // the banner.
            banner.topAnchor.constraint(equalTo: safe.topAnchor, constant: 30),
            banner.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            banner.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.5),
            bannerPreferredWidth,

            // Board — wider than banner, framed by its own double border.
            // bottom is `equalTo` (not `<=`) so board takes a fixed slice
            // of the available vertical space; cards inside scroll if they
            // overflow.
            board.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 24),
            board.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28),
            board.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -28),
            board.bottomAnchor.constraint(equalTo: buzzer.topAnchor, constant: -16),

            // Buzzer centered horizontally at the bottom; cylinder
            // extends DOWN past view.bottom so it appears cropped (the
            // metal pipe disappears off the bottom of the screen, like
            // the podium continues out of frame). Pin bottom past view
            // bottom AND fix height — the dome lands at top of buzzer
            // (50pt above buzzer.bottom).
            buzzer.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            buzzer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 30),
            buzzer.widthAnchor.constraint(equalToConstant: 225),
            buzzer.heightAnchor.constraint(equalToConstant: 170),
        ])
    }

    // MARK: - Input

    private func presentAnswerInput() {
        let alert = UIAlertController(
            title: nil,
            message: "Submit your answer",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "Your answer…"
            tf.autocorrectionType = .no
            // `.none` (NOT `.allCharacters`) because matching is
            // case-insensitive anyway, and `.allCharacters` looked
            // like the system was force-toggling caps-lock back on
            // after every keystroke.
            tf.autocapitalizationType = .none
            tf.font = FeudPalette.answerFont(size: 17)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Submit", style: .default) { [weak self, weak alert] _ in
            self?.handleSubmit(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    /// Match a user-submitted guess against `currentRound.answers`.
    /// Case-insensitive + lemma-aware (so "cats" matches an answer of
    /// "cat", "running" matches "run", etc. — same `EnglishInflectionRules`
    /// used by Among wUrdS, Word Tinder, and QuizEngine).
    ///
    /// Step 3 will add: strike-X overlay on miss, end-of-round when
    /// all slots revealed OR 3 strikes accumulated, flip animation on
    /// reveal. For now this is the bare minimum to make data flow
    /// visible end-to-end.
    private func handleSubmit(_ rawInput: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let round = currentRound else {
            debugLog("🎯 PhrasyFeud submit ignored: no current round")
            return
        }

        let userLemmas = lemmaSet(for: trimmed)
        debugLog("🎯 PhrasyFeud submit: \"\(trimmed)\" lemmas=\(userLemmas)")

        for (i, answer) in round.answers.enumerated() {
            let answerLemmas = lemmaSet(for: answer.word)
            if !userLemmas.isDisjoint(with: answerLemmas) {
                if revealedSlots.contains(i) {
                    debugLog("🎯   matched slot \(i) (\(answer.word)) — but ALREADY revealed")
                    return
                }
                revealedSlots.insert(i)
                debugLog("✅ PhrasyFeud reveal slot \(i): \(answer.word) (\(answer.score))")
                board.setCardState(at: i, .revealed(answer: answer.word, score: answer.score))
                celebrateReveal(slot: i)
                return
            }
        }

        debugLog("❌ PhrasyFeud no match for \"\(trimmed)\"")
    }

    /// Lemma + lowercased original, all in one set, suitable for
    /// `Set.isDisjoint(with:)` comparison against another lemma set.
    private func lemmaSet(for word: String) -> Set<String> {
        var set: Set<String> = [word.lowercased()]
        for lemma in EnglishInflectionRules.resolve(word) {
            set.insert(lemma.lowercased())
        }
        return set
    }

    // MARK: - Celebration

    /// Fire a star/coin particle burst FROM the just-revealed card's
    /// center. Modeled on MorphemeMaury's `burstParticles` but
    /// intentionally distinct:
    ///   - Maury rains confetti DOWN from the screen top in a wide line;
    ///     this bursts UP from a single card-center point in a 180° fan.
    ///   - Maury uses generic celebration emojis (🎉🎊✨🌟); this is
    ///     star + coin themed (⭐💫✨💰💎) to evoke "you just won
    ///     points on the game show!"
    ///   - Maury's burst lingers ~6s for a round-end finale;
    ///     this is a snappier ~2.5s per-card-match celebration.
    ///
    /// Each burst gets a FRESH `CAEmitterLayer` (Maury learned the hard
    /// way that reusing one emitter across bursts is racy — birthRate,
    /// begin-time, cell lifecycle state all drift across plays).
    private func celebrateReveal(slot: Int) {
        guard board.cards.indices.contains(slot) else { return }
        let card = board.cards[slot]
        let cardCenter = view.convert(card.center, from: card.superview)

        let freshCells = Self.celebrationCells.compactMap { $0.copy() as? CAEmitterCell }
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .point
        emitter.emitterMode = .points
        emitter.renderMode = .unordered
        emitter.emitterCells = freshCells
        emitter.frame = view.bounds
        emitter.emitterPosition = cardCenter
        emitter.emitterSize = CGSize(width: 4, height: 4)
        emitter.zPosition = 200
        emitter.masksToBounds = false
        emitter.birthRate = 1
        view.layer.addSublayer(emitter)

        // Stop emitting after the initial burst; existing particles
        // keep animating via their `lifetime` until they fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak emitter] in
            emitter?.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak emitter] in
            emitter?.removeFromSuperlayer()
        }
    }

    /// Cached celebration cells — star + coin theme, upward burst.
    /// `private static` because CAEmitterCell rasterizes the emoji
    /// content into an image at first access; doing it per-burst was
    /// wasteful (Maury learned this too).
    private static let celebrationCells: [CAEmitterCell] = {
        let emojis = ["\u{2B50}", "\u{1F4AB}", "\u{2728}", "\u{1F4B0}", "\u{1F48E}"]  // ⭐💫✨💰💎
        return emojis.map { emoji in
            let cell = CAEmitterCell()
            cell.contents = emojiImage(emoji, size: 28)?.cgImage
            cell.birthRate = 18
            cell.lifetime = 1.4
            cell.velocity = 420
            cell.velocityRange = 150
            // Slight upward drift (NEGATIVE y in CG coords) so particles
            // float a bit before gravity wins. Maury's confetti uses
            // POSITIVE yAcceleration (gravity); we invert the sign for
            // the "score popped up off the card" feel.
            cell.yAcceleration = -60
            cell.xAcceleration = 0
            cell.emissionLongitude = -.pi / 2  // UPWARD (negative y in CG)
            cell.emissionRange = .pi           // 180° fan, upward semicircle
            cell.spin = 3.0
            cell.spinRange = 6
            cell.scale = 0.85
            cell.scaleRange = 0.3
            cell.alphaSpeed = -0.55            // fade out in ~1.8s
            return cell
        }
    }()

    /// Render an emoji to a UIImage for `CAEmitterCell.contents`.
    /// Mirror of MorphemeMaury's helper (project convention: each VC
    /// owns its own copy; a shared util can come in a later cleanup if
    /// a third feature needs the same).
    private static func emojiImage(_ emoji: String, size: CGFloat) -> UIImage? {
        let font = UIFont.systemFont(ofSize: size)
        let attr: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (emoji as NSString).size(withAttributes: attr)
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: ceil(textSize.width), height: ceil(textSize.height)))
        return renderer.image { _ in
            (emoji as NSString).draw(at: .zero, withAttributes: attr)
        }
    }

    // MARK: - Engine pipeline

    private func startEngine() {
        showLoadingState()
        Task { @MainActor in
            do {
                let round = try await PhrasyFeudEngine.buildRound()
                apply(round: round)
            } catch PhrasyFeudEngine.Failure.notEnoughBookmarks {
                showPlaceholder(
                    iconSymbol: "info.bubble",
                    iconPalette: [FeudPalette.goldText, .systemGray3],
                    title: L10n.AICoach.PhrasyFeud.notEnoughBookmarksTitle,
                    subtitle: L10n.AICoach.PhrasyFeud.notEnoughBookmarksMessage,
                    showRetry: false
                )
            } catch {
                debugLog("⚠️ PhrasyFeudVC: engine failed — \(error)")
                showPlaceholder(
                    iconSymbol: "exclamationmark.triangle.fill",
                    iconPalette: [.systemOrange, FeudPalette.goldText],
                    title: L10n.AICoach.PhrasyFeud.engineErrorTitle,
                    subtitle: L10n.AICoach.PhrasyFeud.engineErrorMessage,
                    showRetry: true
                )
            }
        }
    }

    private func apply(round: PhrasyFeudEngine.Round) {
        currentRound = round
        revealedSlots.removeAll()
        currentPhase = .playing
        hidePlaceholder()
        banner.setQuestion(round.question)
        // Broadcast contract: every card starts FACE-DOWN (blank). Step 3's
        // input-matching logic will look up the answer + score in
        // `currentRound.answers` and call `board.setCardState(at:.revealed)`
        // when the user nails one. The answer text is held only in
        // `currentRound`, never written to the view layer at startup —
        // otherwise the user (or anyone glancing at the screen) would see
        // every answer immediately, defeating the game.
        board.setSlotCount(round.answers.count)
        for i in round.answers.indices {
            board.setCardState(at: i, .blank)
        }
    }

    // MARK: - Loading / placeholder UI

    private func setupPlaceholderUI() {
        // Icon — palette-tinted SF Symbol; resized when content swaps.
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.contentMode = .scaleAspectFit

        // Title — gold, heavy, centered.
        placeholderTitle.translatesAutoresizingMaskIntoConstraints = false
        placeholderTitle.font = .systemFont(ofSize: 22, weight: .heavy)
        placeholderTitle.textColor = FeudPalette.goldText
        placeholderTitle.textAlignment = .center
        placeholderTitle.numberOfLines = 0

        placeholderSubtitle.translatesAutoresizingMaskIntoConstraints = false
        placeholderSubtitle.font = .systemFont(ofSize: 15, weight: .regular)
        placeholderSubtitle.textColor = UIColor.white.withAlphaComponent(0.75)
        placeholderSubtitle.textAlignment = .center
        placeholderSubtitle.numberOfLines = 0

        placeholderSpinner.color = FeudPalette.goldText

        placeholderRetryButton.translatesAutoresizingMaskIntoConstraints = false
        placeholderRetryButton.setTitle(L10n.AICoach.PhrasyFeud.tryAgain, for: .normal)
        placeholderRetryButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        placeholderRetryButton.setTitleColor(FeudPalette.goldText, for: .normal)
        placeholderRetryButton.addAction(UIAction { [weak self] _ in
            self?.startEngine()
        }, for: .touchUpInside)

        placeholderStack.axis = .vertical
        placeholderStack.alignment = .center
        placeholderStack.spacing = 14
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        placeholderStack.addArrangedSubview(placeholderIcon)
        placeholderStack.addArrangedSubview(placeholderTitle)
        placeholderStack.addArrangedSubview(placeholderSpinner)
        placeholderStack.addArrangedSubview(placeholderSubtitle)
        placeholderStack.addArrangedSubview(placeholderRetryButton)
        placeholderStack.setCustomSpacing(18, after: placeholderIcon)
        placeholderStack.setCustomSpacing(18, after: placeholderTitle)
        placeholderStack.setCustomSpacing(18, after: placeholderSubtitle)
        placeholderStack.isHidden = true
        view.addSubview(placeholderStack)

        NSLayoutConstraint.activate([
            placeholderStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            placeholderStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 76),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func showLoadingState() {
        currentPhase = .loading
        banner.isHidden = true
        board.isHidden = true
        buzzer.isHidden = true

        applyPlaceholderIcon(symbol: "tv.fill", palette: [FeudPalette.goldText, .systemRed])
        placeholderTitle.text = L10n.AICoach.PhrasyFeud.loadingTitle
        placeholderTitle.textColor = FeudPalette.goldText
        placeholderSubtitle.text = L10n.AICoach.PhrasyFeud.loadingMessage
        placeholderSpinner.isHidden = false
        placeholderSpinner.startAnimating()
        placeholderRetryButton.isHidden = true
        placeholderStack.isHidden = false
    }

    private func showPlaceholder(
        iconSymbol: String,
        iconPalette: [UIColor],
        title: String,
        subtitle: String,
        showRetry: Bool
    ) {
        banner.isHidden = true
        board.isHidden = true
        buzzer.isHidden = true

        applyPlaceholderIcon(symbol: iconSymbol, palette: iconPalette)
        placeholderTitle.text = title
        placeholderTitle.textColor = FeudPalette.goldText
        placeholderSubtitle.text = subtitle
        placeholderSpinner.stopAnimating()
        placeholderSpinner.isHidden = true
        placeholderRetryButton.isHidden = !showRetry
        placeholderStack.isHidden = false
    }

    private func hidePlaceholder() {
        placeholderSpinner.stopAnimating()
        placeholderStack.isHidden = true
        banner.isHidden = false
        board.isHidden = false
        buzzer.isHidden = false
    }

    private func applyPlaceholderIcon(symbol: String, palette: [UIColor]) {
        let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: palette))
        placeholderIcon.image = UIImage(systemName: symbol, withConfiguration: config)?
            .withRenderingMode(.alwaysOriginal)
    }
}
