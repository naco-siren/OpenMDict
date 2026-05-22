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
        case notStarted     // round loaded; banner reads "TAP TO START", timer paused at full
        case playing        // banner flipped to question, timer counting down, input live
        case finale         // round over (all slots revealed OR timer hit 0)
    }

    private var currentPhase: Phase = .loading

    // MARK: - UI

    private let archBackground = FeudArchBackground()
    private let banner = FeudQuestionBanner()
    private let board = FeudBoardView()
    private let buzzer = FeudBuzzerView()

    /// Custom nav-bar title — gold "Phrasy Feud" text + bespoke
    /// `PhrasyFeud` PNG icon (matches the AI Coach chooser facade).
    /// Replaces what the system title text rendered via
    /// `navigationItem.standardAppearance.titleTextAttributes`; titleView
    /// always wins over the appearance's title attributes.
    private let navTitleLabel = UILabel()

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
    /// Drives both the no-double-credit rule and the all-slots-revealed
    /// finale trigger.
    private var revealedSlots: Set<Int> = []

    // Finale overlay (shown when all slots revealed). Borrows
    // MorphemeMaury's pattern: a dimming view filling the screen, with
    // headline + score line + a "Next Round" button.
    private let finaleOverlay = UIView()
    private let finaleTitle = UILabel()
    private let finaleScore = UILabel()
    private let finaleNextButton = UIButton(type: .system)

    // LCD displays flanking the buzzer.
    //   Left  = remaining seconds (3-digit, ticks down).
    //   Right = TOTAL points scored so far (3-digit, ticks up as cards reveal).
    // Each timer is a self-contained card with its caption ("TIME" /
    // "TOTAL") baked into the same black-bg view as the digits — see
    // FeudLCDTimer for the rationale. Both freeze on round end.
    private let leftTimer = FeudLCDTimer(caption: L10n.AICoach.PhrasyFeud.timerLabel)
    private let rightTimer = FeudLCDTimer(caption: L10n.AICoach.PhrasyFeud.scoreLabel)
    private var gameTimer: Timer?
    private var remainingSeconds: Int = 0

    /// Seconds the user gets PER answer in the round. Total round
    /// budget = `round.answers.count * secondsPerAnswer` so difficulty
    /// scales with how many answers the AI produced.
    private static let secondsPerAnswer = 30

    /// Big red X that flashes over the board on a wrong submit —
    /// broadcast-show feedback channel (the cards shake too, but the
    /// X is the unambiguous "strike" the show uses).
    private let strikeOverlay = UIImageView()

    // START curtain (shown when a fresh round is loaded — engine has
    // returned and the board is face-down, but the user hasn't
    // committed to starting yet). Full-screen dim + a centered
    // "TAP TO START" card. Captures all taps so the buzzer can't be
    // opened prematurely; dismissed on tap → real question banner
    // fades in + timer starts.
    private let startCurtain = UIView()
    // 24pt vertical padding (vs the top banner's default 12pt) so the
    // centered prompt reads as a beefier hero card, not a tighter
    // info pill.
    private let startPromptBanner = FeudQuestionBanner(verticalPadding: 24)

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
        setupFinaleOverlay()
        setupStartCurtain()
        setupBackButton()
        setupTitleView()
        startEngine()
    }

    // MARK: - Title view

    /// Build the custom nav title: bespoke `PhrasyFeud` PNG (template-
    /// rendered, tinted `.systemYellow` to match the AI Coach chooser
    /// facade's StudyMode.iconTint) + gold "Phrasy Feud" text in the
    /// `bannerFont`. The system `title = …` was the OLD behavior;
    /// `navigationItem.standardAppearance.titleTextAttributes` styled
    /// that, but had no icon — chooser-facade-to-this-VC felt visually
    /// disconnected. Now both surfaces share the same icon + tint
    /// language.
    ///
    /// NOTE: `title` is intentionally KEPT (set in viewDidLoad as
    /// `L10n.AICoach.phrasyFeud`) because it drives the back-button
    /// label on any further pushed VC, plus VoiceOver fallback. titleView
    /// just overrides the *visual* rendering of the title slot.
    private func setupTitleView() {
        // 18×18 with y=-3 baseline-aligns the PNG icon to the 17pt
        // bannerFont's cap height. Same recipe the other 3 quiz VCs use,
        // just with a Feud-themed font instead of system semibold.
        //
        // Icon AND text both tinted `.systemYellow` to match the AI Coach
        // chooser facade's StudyMode.iconTint for this mode. Previously
        // used `FeudPalette.goldText` (a dimmer custom gold) for the
        // text — but per the "tint icon and text together" rule, both
        // surfaces (chooser cell + nav bar title) should now share the
        // same brand color. The brighter systemYellow also reads better
        // on the transparent nav bar over the dark arch backdrop.
        let attachment = NSTextAttachment()
        attachment.image = UIImage(named: "PhrasyFeud")?
            .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
        attachment.bounds = CGRect(x: 0, y: -3, width: 18, height: 18)
        let attrText = NSMutableAttributedString(attachment: attachment)
        attrText.append(NSAttributedString(
            string: " " + L10n.AICoach.phrasyFeud,
            attributes: [
                .foregroundColor: UIColor.systemYellow,
                .font: FeudPalette.bannerFont(size: 17),
            ]
        ))
        navTitleLabel.attributedText = attrText
        navTitleLabel.sizeToFit()
        navigationItem.titleView = navTitleLabel
    }

    // MARK: - Start curtain

    private func setupStartCurtain() {
        startCurtain.translatesAutoresizingMaskIntoConstraints = false
        startCurtain.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        startCurtain.alpha = 0
        startCurtain.isUserInteractionEnabled = false  // toggled in show/hide
        view.addSubview(startCurtain)

        startPromptBanner.translatesAutoresizingMaskIntoConstraints = false
        startPromptBanner.setQuestion(L10n.AICoach.PhrasyFeud.tapToStart, animated: false)
        // 3× the top banner's 17pt font (the overlay was
        // too subtle as a focal CTA at 17pt). Banner also gets ~80% view
        // width below so "TAP TO START" can sit on 1-2 lines comfortably.
        startPromptBanner.setFont(FeudPalette.bannerFont(size: 51))
        startCurtain.addSubview(startPromptBanner)

        // Tap target = the PROMPT BANNER ONLY, not the whole curtain.
        // Earlier impl put the tap on `startCurtain`, which made tapping
        // the dim area also start the round by accident. The curtain
        // still blocks touches to layers behind
        // (buzzer etc.) because `isUserInteractionEnabled = true`
        // silently absorbs them when there's no gesture; only taps
        // INSIDE the prompt banner trigger the start.
        let tap = UITapGestureRecognizer(target: self, action: #selector(startCurtainTapped))
        startPromptBanner.isUserInteractionEnabled = true
        startPromptBanner.addGestureRecognizer(tap)

        // The morph-and-flip animation rotates the prompt 180° around X
        // axis. We don't want to see the back face (which would render
        // as a mirrored copy by default) — `isDoubleSided = false`
        // makes the layer invisible when facing away. Set once at setup
        // and left in place: the back-face hide also applies on each
        // subsequent round's flip.
        startPromptBanner.layer.isDoubleSided = false

        NSLayoutConstraint.activate([
            startCurtain.topAnchor.constraint(equalTo: view.topAnchor),
            startCurtain.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            startCurtain.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            startCurtain.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Prompt banner centered + ~80% view width. Enough to host
            // "TAP TO START" at 51pt on one or two lines without
            // cramping on iPhone-portrait safe widths.
            startPromptBanner.centerXAnchor.constraint(equalTo: startCurtain.centerXAnchor),
            startPromptBanner.centerYAnchor.constraint(equalTo: startCurtain.centerYAnchor),
            startPromptBanner.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
        ])
    }

    private func showStartCurtain() {
        view.bringSubviewToFront(startCurtain)
        startCurtain.isUserInteractionEnabled = true
        // Reset state in case this is a SECOND round — the previous
        // hide-curtain animation left bg transparent + prompt at the
        // top-banner transform; both have to be back to the start
        // state before fading in again.
        startCurtain.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        startPromptBanner.layer.transform = CATransform3DIdentity
        UIView.animate(withDuration: 0.25) {
            self.startCurtain.alpha = 1
            self.banner.alpha = 0    // top banner stays hidden until user dismisses
        }
    }

    /// Dismiss the curtain with a combined morph-and-flip:
    ///   - The prompt banner's `layer.transform` animates to a target
    ///     CATransform3D that simultaneously TRANSLATES it to the top
    ///     banner's center, SCALES it to the top banner's bounds, and
    ///     ROTATES 180° around the X axis.
    ///   - At ~50% rotation (90° edge-on) the prompt becomes invisible
    ///     (`isDoubleSided = false`), so the back face never shows.
    ///   - The real top banner cross-fades in over the same window —
    ///     by the time the prompt is hidden behind its rotation, the
    ///     question banner is already in place reading like the
    ///     prompt has "morphed into" it.
    private func hideStartCurtain() {
        startCurtain.isUserInteractionEnabled = false

        // Compute target transform. Both banners' centers live in the
        // view's coord space (or coord spaces aligned to view's, since
        // banner is a direct child of view and startPromptBanner is
        // centered inside the full-screen startCurtain).
        let topCenter = view.convert(banner.center, from: banner.superview ?? view)
        let promptCenter = view.convert(startPromptBanner.center, from: startPromptBanner.superview ?? view)
        let dx = topCenter.x - promptCenter.x
        let dy = topCenter.y - promptCenter.y

        let promptW = max(1, startPromptBanner.bounds.width)
        let promptH = max(1, startPromptBanner.bounds.height)
        let sx = banner.bounds.width / promptW
        let sy = banner.bounds.height / promptH

        var target = CATransform3DIdentity
        target.m34 = -1.0 / 800  // subtle perspective so the flip has depth
        target = CATransform3DTranslate(target, dx, dy, 0)
        target = CATransform3DScale(target, sx, sy, 1)
        target = CATransform3DRotate(target, .pi, 1, 0, 0)

        // UIView.animate can't drive `layer.transform` (CATransform3D);
        // it only animates the 2D `view.transform` (CGAffineTransform).
        // Drop down to CABasicAnimation for the 3D combo. The model
        // layer is set to `target` BEFORE the animation runs, so when
        // the animation auto-removes at completion the presentation
        // matches the model — no `fillMode=.forwards` /
        // `isRemovedOnCompletion=false` needed (and in fact those
        // would BREAK the next-round curtain: a lingering animation
        // pins the presentation to the off-screen rotated target
        // forever, hiding the prompt when round 2's showStartCurtain
        // resets `layer.transform = identity`).
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        anim.toValue = NSValue(caTransform3D: target)
        anim.duration = 0.6
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        startPromptBanner.layer.add(anim, forKey: "morphFlip")
        startPromptBanner.layer.transform = target

        // Top banner fades in starting at 50% of the animation, so it's
        // fully visible by the time the prompt finishes its rotation.
        UIView.animate(withDuration: 0.3, delay: 0.3) {
            self.banner.alpha = 1
        }

        // Curtain bg fades out over the same 0.6s. Completion handler
        // resets the curtain state so the NEXT round's show-curtain
        // starts clean (bg color + alpha back to defaults).
        UIView.animate(
            withDuration: 0.6, delay: 0, options: [.curveEaseInOut],
            animations: { self.startCurtain.backgroundColor = .black.withAlphaComponent(0) },
            completion: { _ in
                self.startCurtain.alpha = 0
                self.startCurtain.backgroundColor = .black.withAlphaComponent(0.78)
            }
        )
    }

    @objc private func startCurtainTapped() {
        guard currentPhase == .notStarted else { return }
        debugLog("🏁 PhrasyFeud start curtain tapped — beginning round")
        currentPhase = .playing
        hideStartCurtain()
        startTimer()
        // Kick off background generation of the NEXT round while the
        // user plays the current one. Most rounds take 30s-3min to
        // play, the AI call takes 3-8s — so by the time the user taps
        // Next Round, the preloaded round is almost always ready.
        // Mirrors AmongWurds/Maury's queue pattern.
        preloadNextRound()
    }

    // MARK: - Next-round preloading

    /// Set when a background preload task completes successfully.
    /// Consumed by `nextRoundTapped`. Cleared when applied so the next
    /// round-end triggers a fresh preload via `startCurtainTapped`.
    private var preloadedRound: PhrasyFeudEngine.Round?

    /// In-flight preload task. Used to (a) avoid double-firing if
    /// `preloadNextRound` is called twice and (b) allow `nextRoundTapped`
    /// to await the in-flight result instead of starting a duplicate
    /// engine call. Set to nil at the end of the task body so its
    /// nilness reliably signals "no work happening right now".
    private var preloadingTask: Task<Void, Never>?

    private func preloadNextRound() {
        guard preloadingTask == nil, preloadedRound == nil else { return }
        debugLog("🔄 PhrasyFeud preload: kicking off background round")
        preloadingTask = Task { @MainActor [weak self] in
            do {
                let round = try await PhrasyFeudEngine.buildRound()
                self?.preloadedRound = round
                debugLog("🔄 PhrasyFeud preload: ready — \(round.answers.count) answers, isFallback=\(round.isFallback)")
            } catch {
                debugLog("⚠️ PhrasyFeud preload errored: \(error) — Next Round will start fresh")
            }
            self?.preloadingTask = nil
        }
    }

    // MARK: - Back navigation

    /// Replace the system back chevron with our own so we can intercept
    /// the tap and show the double-check alert when the user is mid-
    /// round. Pop is still routed through `navigationController` —
    /// nothing custom about the actual navigation.
    private func setupBackButton() {
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain, target: self, action: #selector(backTapped))
    }

    @objc private func backTapped() {
        if shouldConfirmLeave() {
            let alert = UIAlertController(
                title: L10n.AICoach.PhrasyFeud.leaveTitle,
                message: L10n.AICoach.PhrasyFeud.leaveMessage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: L10n.AICoach.PhrasyFeud.leaveShow, style: .destructive
            ) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            })
            // Stay action gets `.default` style + `preferredAction`
            // marker — Apple HIG mechanism for highlighting the
            // recommended choice. iOS renders this as the prominent
            // tinted-background button on iOS 26 Liquid Glass; on
            // older iOS it still bolds the title. The trade-off
            // versus `.cancel`-style: outside-tap-to-dismiss on iPad
            // doesn't fire automatically. Acceptable — alert is
            // modal and the user has to make a deliberate choice
            // anyway, which is the whole point of the confirm.
            let stayAction = UIAlertAction(
                title: L10n.AICoach.PhrasyFeud.stayOnShow, style: .default)
            alert.addAction(stayAction)
            alert.preferredAction = stayAction
            present(alert, animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    /// Pure phase-driven gate, mapping directly to the 3-state rule:
    ///
    ///   1. While the engine is generating a round (first round on
    ///      launch OR any subsequent regeneration after a finale tap)
    ///      → silent pop. Nothing's been earned; nothing's wasted.
    ///   2. Once a round is loaded — whether the user is still looking
    ///      at "TAP TO START" (`.notStarted`) or actively answering
    ///      (`.playing`) — the back-nav MUST confirm. The user could
    ///      otherwise spend 5-10s waiting for generation and then
    ///      lose the validated round to a stray finger.
    ///   3. Once the finale screen is up, the round is done. Even if
    ///      the next round is preloading in the background, silent
    ///      pop is fine — the user already earned this round's points
    ///      and any preload is for a round they haven't committed to.
    ///
    /// Two earlier versions of this got this wrong:
    ///   - Original: only confirmed during `.playing` AND with progress.
    ///     "Just-started, zero answers" silently popped — bug.
    ///   - First fix: removed the `revealedSlots.isEmpty` check but kept
    ///     `currentPhase == .playing`. Still missed `.notStarted` — the
    ///     "TAP TO START" state. Same bug from a different angle.
    private func shouldConfirmLeave() -> Bool {
        switch currentPhase {
        case .loading, .finale:     return false
        case .notStarted, .playing: return true
        }
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

        // LCD displays flanking the buzzer — single-player twist on
        // the broadcast "two opposing families" score boards. Left
        // counts time DOWN; right counts score UP. Each timer's
        // caption ("TIME" / "TOTAL") lives INSIDE the LCD's own black-
        // bg card; no separate labels here.
        leftTimer.translatesAutoresizingMaskIntoConstraints = false
        rightTimer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(leftTimer)
        view.addSubview(rightTimer)

        // Strike overlay — red X+box SF Symbol, briefly flashed over
        // the board's center when the user submits a wrong answer.
        let strikeConfig = UIImage.SymbolConfiguration(pointSize: 140, weight: .black)
        strikeOverlay.image = UIImage(systemName: "xmark.app.fill", withConfiguration: strikeConfig)?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        strikeOverlay.translatesAutoresizingMaskIntoConstraints = false
        strikeOverlay.alpha = 0
        strikeOverlay.isUserInteractionEnabled = false
        view.addSubview(strikeOverlay)

        // Note: the top banner has NO tap target anymore. Pre-start
        // gating is owned by `startCurtain` (centered overlay), which
        // is set up in `setupStartCurtain` and dismissed by tap to
        // commit to `.playing`.

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
            // Buzzer shrunk from 225→180 so the flanking timers fit on
            // iPhone-portrait safe widths (393pt available × 0.95 ≈ 373
            // accommodates 70 + 8 + 180 + 8 + 70 = 336).
            buzzer.widthAnchor.constraint(equalToConstant: 180),
            buzzer.heightAnchor.constraint(equalToConstant: 170),

            // Timer centerY = top of buzzer + 25 (= dome's vertical
            // center inside the buzzer's 170pt frame). Width + height
            // come from the LCD's intrinsic (label + 4pt insets) so the
            // digits get equal 4pt padding on all four sides instead
            // of the asymmetric "centered text in fixed 80×36 box"
            // result the previous explicit constraints gave.
            leftTimer.trailingAnchor.constraint(equalTo: buzzer.leadingAnchor, constant: -8),
            leftTimer.centerYAnchor.constraint(equalTo: buzzer.topAnchor, constant: 25),

            rightTimer.leadingAnchor.constraint(equalTo: buzzer.trailingAnchor, constant: 8),
            rightTimer.centerYAnchor.constraint(equalTo: buzzer.topAnchor, constant: 25),

            // Strike overlay (red X) centered over the answer board.
            strikeOverlay.centerXAnchor.constraint(equalTo: board.centerXAnchor),
            strikeOverlay.centerYAnchor.constraint(equalTo: board.centerYAnchor),
        ])
    }

    // MARK: - Input

    private func presentAnswerInput() {
        let alert = UIAlertController(
            title: nil,
            message: L10n.AICoach.PhrasyFeud.submitAnswerMessage,
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = L10n.AICoach.PhrasyFeud.answerPlaceholder
            tf.autocorrectionType = .no
            // `.none` (NOT `.allCharacters`) because matching is
            // case-insensitive anyway, and `.allCharacters` looked
            // like the system was force-toggling caps-lock back on
            // after every keystroke.
            tf.autocapitalizationType = .none
            tf.font = FeudPalette.answerFont(size: 17)
        }
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.AICoach.PhrasyFeud.submit, style: .default) { [weak self, weak alert] _ in
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
        // Reject submits outside the actual play window — covers both
        // pre-start (user mashed buzzer before tapping START) and
        // post-finale (Next Round was tapped but engine hasn't returned
        // yet, so we're temporarily back in `.loading`).
        guard currentPhase == .playing else {
            debugLog("🎯 PhrasyFeud submit ignored: phase=\(currentPhase)")
            return
        }
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
                    board.pulseCard(at: i)
                    return
                }
                revealedSlots.insert(i)
                debugLog("✅ PhrasyFeud reveal slot \(i): \(answer.word) (\(answer.score))")
                board.setCardState(
                    at: i,
                    .revealed(answer: answer.word, score: answer.score),
                    animated: true
                )
                updateTimerDisplay()  // right LCD ticks up to the new total
                // Delay the celebration burst by ~300ms so the user
                // first registers the card flip (which swaps content at
                // its midpoint ~0.22s), THEN sees the particles —
                // otherwise particles fire while the card is still
                // showing its blank face and the visual cause-and-
                // effect ("right answer revealed → confetti") is muddy.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.celebrateReveal(slot: i)
                }
                if revealedSlots.count == round.answers.count {
                    // All slots revealed → schedule the finale after the
                    // flip animation (0.45s) + particle burst (starts at
                    // 0.3, runs ~0.4s active emission, ~2.5s with fade)
                    // has had a moment to play before the overlay dims
                    // everything behind it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.showFinale()
                    }
                }
                return
            }
        }

        debugLog("❌ PhrasyFeud no match for \"\(trimmed)\"")
        shakeBoard()
        showStrike()
    }

    /// Broadcast strike: red X+box flashes over the board center,
    /// scales up briefly, fades out. Pairs with the board shake (the
    /// shake conveys "kinetic-bad"; the X conveys "official miss" —
    /// two channels of feedback for the same wrong-answer event).
    private func showStrike() {
        view.bringSubviewToFront(strikeOverlay)
        strikeOverlay.alpha = 0
        strikeOverlay.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
        UIView.animate(
            withDuration: 0.14,
            delay: 0,
            usingSpringWithDamping: 0.5,
            initialSpringVelocity: 0.6
        ) {
            self.strikeOverlay.alpha = 1
            self.strikeOverlay.transform = .identity
        }
        UIView.animate(
            withDuration: 0.35, delay: 0.45,
            options: [.curveEaseIn]
        ) {
            self.strikeOverlay.alpha = 0
        }
    }

    // MARK: - Wrong-answer feedback

    /// Brief horizontal shake on the board, ~0.4s. Intentionally NOT a
    /// particle burst — that's the "success" channel; wrong answers
    /// should feel kinetic-bad (jolted), not festive-anything. Mirrors
    /// the standard iOS "password wrong" shake.
    private func shakeBoard() {
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.duration = 0.4
        anim.values = [-12, 12, -10, 10, -6, 6, 0]
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        board.layer.add(anim, forKey: "shake")
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

    // MARK: - Finale

    private func setupFinaleOverlay() {
        finaleOverlay.translatesAutoresizingMaskIntoConstraints = false
        finaleOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        finaleOverlay.alpha = 0
        finaleOverlay.isUserInteractionEnabled = false
        view.addSubview(finaleOverlay)

        finaleTitle.translatesAutoresizingMaskIntoConstraints = false
        // Title text is populated dynamically in `showFinale` (it's now
        // "%d POINTS"); leaving the initial label empty avoids flashing
        // a "0 POINTS" or stale value before the finale fires.
        finaleTitle.text = nil
        finaleTitle.font = .systemFont(ofSize: 38, weight: .black)
        finaleTitle.textColor = FeudPalette.goldText
        finaleTitle.textAlignment = .center
        finaleTitle.numberOfLines = 0
        finaleOverlay.addSubview(finaleTitle)

        finaleScore.translatesAutoresizingMaskIntoConstraints = false
        finaleScore.font = .systemFont(ofSize: 18, weight: .semibold)
        finaleScore.textColor = .white
        finaleScore.textAlignment = .center
        finaleScore.numberOfLines = 0
        finaleOverlay.addSubview(finaleScore)

        finaleNextButton.translatesAutoresizingMaskIntoConstraints = false
        finaleNextButton.setTitle(L10n.AICoach.PhrasyFeud.nextRound, for: .normal)
        finaleNextButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .heavy)
        finaleNextButton.setTitleColor(.black, for: .normal)
        finaleNextButton.backgroundColor = FeudPalette.goldText
        finaleNextButton.layer.cornerRadius = 14
        finaleNextButton.addAction(UIAction { [weak self] _ in
            self?.nextRoundTapped()
        }, for: .touchUpInside)
        finaleOverlay.addSubview(finaleNextButton)

        NSLayoutConstraint.activate([
            finaleOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            finaleOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            finaleOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            finaleOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            finaleTitle.centerXAnchor.constraint(equalTo: finaleOverlay.centerXAnchor),
            finaleTitle.centerYAnchor.constraint(equalTo: finaleOverlay.centerYAnchor, constant: -56),
            finaleTitle.leadingAnchor.constraint(greaterThanOrEqualTo: finaleOverlay.leadingAnchor, constant: 28),
            finaleTitle.trailingAnchor.constraint(lessThanOrEqualTo: finaleOverlay.trailingAnchor, constant: -28),

            finaleScore.centerXAnchor.constraint(equalTo: finaleOverlay.centerXAnchor),
            finaleScore.topAnchor.constraint(equalTo: finaleTitle.bottomAnchor, constant: 14),
            finaleScore.leadingAnchor.constraint(greaterThanOrEqualTo: finaleOverlay.leadingAnchor, constant: 28),
            finaleScore.trailingAnchor.constraint(lessThanOrEqualTo: finaleOverlay.trailingAnchor, constant: -28),

            finaleNextButton.centerXAnchor.constraint(equalTo: finaleOverlay.centerXAnchor),
            finaleNextButton.topAnchor.constraint(equalTo: finaleScore.bottomAnchor, constant: 32),
            finaleNextButton.widthAnchor.constraint(equalToConstant: 200),
            finaleNextButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    private func showFinale() {
        guard let round = currentRound else { return }
        currentPhase = .finale
        stopTimer()  // freeze the LCD display on the elapsed value
        let correct = revealedSlots.count
        let total = round.answers.count
        let points = currentPoints()
        // Title carries the points (hero text), message carries the
        // answer-count line. Swapped from the previous layout:
        // points are the "score" you brag about,
        // so they deserve the big-text slot.
        finaleTitle.text = L10n.AICoach.PhrasyFeud.finaleTitle(points)
        finaleScore.text = L10n.AICoach.PhrasyFeud.finaleScore(correct, total)
        debugLog("🏁 PhrasyFeud finale: \(correct)/\(total) answers, \(points) points")

        finaleOverlay.isUserInteractionEnabled = true
        view.bringSubviewToFront(finaleOverlay)
        UIView.animate(withDuration: 0.35) {
            self.finaleOverlay.alpha = 1
        }
    }

    private func hideFinale() {
        finaleOverlay.isUserInteractionEnabled = false
        finaleOverlay.alpha = 0
    }

    private func nextRoundTapped() {
        debugLog("🏁 PhrasyFeud finale → next round")
        hideFinale()
        // Three paths for delivering the next round:
        //   1. Preload finished while user was playing this round →
        //      instant apply, no loading state, smoothest UX.
        //   2. Preload still in-flight (user finished fast or AI is
        //      slow) → show loading state + await the task, then apply.
        //   3. Preload errored or never ran (e.g. went straight from
        //      finale on round 1 to Next without playing — shouldn't
        //      happen given current flow but guarded anyway) → fall
        //      back to a fresh `startEngine` call.
        if let preloaded = preloadedRound {
            debugLog("🔄 PhrasyFeud nextRound: using preloaded round (instant)")
            preloadedRound = nil
            apply(round: preloaded)
        } else if let task = preloadingTask {
            debugLog("🔄 PhrasyFeud nextRound: awaiting in-flight preload")
            showLoadingState()
            Task { @MainActor [weak self] in
                _ = await task.value
                guard let self else { return }
                if let preloaded = self.preloadedRound {
                    self.preloadedRound = nil
                    self.apply(round: preloaded)
                } else {
                    // Preload errored — fall back to a fresh engine call.
                    self.startEngine()
                }
            }
        } else {
            debugLog("🔄 PhrasyFeud nextRound: no preload available, fresh startEngine")
            startEngine()
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
        // `.notStarted` (NOT .playing) — round loaded but the START
        // curtain covers everything. Tapping the curtain commits to
        // `.playing` + starts the timer. Gives the user a beat to
        // compose themselves before the clock runs AND prevents
        // premature buzzer taps (curtain captures all interaction).
        currentPhase = .notStarted
        hidePlaceholder()
        // Top banner is pre-loaded with the real question (instant set,
        // no flip — flip would happen during dismissal, but user has
        // never seen the content so there's nothing to dramatize) and
        // hidden behind the curtain. Fades in when curtain dismisses.
        banner.setQuestion(round.question, animated: false)
        banner.alpha = 0
        // Broadcast contract: every card starts FACE-DOWN (blank).
        // Answer text lives only in `currentRound`, never written to
        // the view layer at startup. `handleSubmit` flips a card when
        // (and only when) the user lands a correct match.
        board.setSlotCount(round.answers.count)
        for i in round.answers.indices {
            board.setCardState(at: i, .blank)
        }
        resetTimer()
        showStartCurtain()
    }

    // MARK: - Timer

    private func resetTimer() {
        stopTimer()
        // Total round budget scales with answer count: more answers,
        // more time. 30s per answer hits the sweet spot in testing —
        // a 2-answer fallback round is a tight 60s, a 6-answer full
        // round gets 180s.
        let answerCount = currentRound?.answers.count ?? 0
        remainingSeconds = answerCount * Self.secondsPerAnswer
        updateTimerDisplay()
    }

    private func startTimer() {
        stopTimer()
        gameTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Foundation Timer's closure is non-isolated even though
            // it fires on the main RunLoop here — hop back to the main
            // actor explicitly for the strict-concurrency build.
            Task { @MainActor [weak self] in
                self?.tickTimer()
            }
        }
    }

    private func stopTimer() {
        gameTimer?.invalidate()
        gameTimer = nil
    }

    private func tickTimer() {
        guard currentPhase == .playing else { return }
        remainingSeconds = max(0, remainingSeconds - 1)
        updateTimerDisplay()
        if remainingSeconds == 0 {
            debugLog("⏱️ PhrasyFeud timer hit 0 — forcing finale")
            stopTimer()
            showFinale()
        }
    }

    private func updateTimerDisplay() {
        leftTimer.value = max(0, remainingSeconds)
        rightTimer.value = currentPoints()
    }

    /// Sum of `score` for every revealed slot in the current round.
    /// Drives the right LCD ("TOTAL"). Counts up as cards reveal and
    /// freezes on round end.
    private func currentPoints() -> Int {
        guard let round = currentRound else { return 0 }
        return revealedSlots.reduce(0) { $0 + round.answers[$1].score }
    }

    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        if parent == nil {
            // Being popped off the nav stack. Stop the timer + cancel
            // any in-flight preload here instead of deinit — Swift 6
            // forbids touching MainActor-isolated properties from the
            // nonisolated deinit, and willMove is conveniently
            // MainActor-isolated by the VC's actor.
            stopTimer()
            preloadingTask?.cancel()
            preloadingTask = nil
            preloadedRound = nil
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
        // Parent into the BOARD's black interior (NOT the VC's view).
        // Earlier the stack centered on `view` and floated over the
        // arch backdrop's yellow-dotted black — gold-on-yellow-dots is
        // unreadable. Inside `board.contentArea` (the interior, behind
        // the brown + gold rings) the gold title + white-75% subtitle
        // read cleanly against pure black.
        board.contentArea.addSubview(placeholderStack)

        NSLayoutConstraint.activate([
            // Center in the board's interior. The interior's bounds
            // are decided by the board's chrome insets, which solve as
            // soon as autolayout runs — no need to special-case the
            // first layout pass.
            placeholderStack.centerXAnchor.constraint(equalTo: board.contentArea.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: board.contentArea.centerYAnchor),
            // 16pt edge clearance (vs 40 against `view` previously) —
            // the interior is much narrower than the screen, so we
            // need a smaller margin to avoid clipping the title at
            // narrow widths.
            placeholderStack.leadingAnchor.constraint(greaterThanOrEqualTo: board.contentArea.leadingAnchor, constant: 16),
            placeholderStack.trailingAnchor.constraint(lessThanOrEqualTo: board.contentArea.trailingAnchor, constant: -16),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 76),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func showLoadingState() {
        currentPhase = .loading
        banner.isHidden = true
        // Board chrome stays VISIBLE — only the card grid hides. The
        // placeholderStack is now parented INSIDE board.contentArea
        // (the black interior), so the loading text reads against
        // the same black surface that hosts the cards once they're
        // ready. Single visual anchor across loading/playing/finale.
        board.setCardsHidden(true)
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
        board.setCardsHidden(true)
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
        board.setCardsHidden(false)
        buzzer.isHidden = false
    }

    private func applyPlaceholderIcon(symbol: String, palette: [UIColor]) {
        let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: palette))
        placeholderIcon.image = UIImage(systemName: symbol, withConfiguration: config)?
            .withRenderingMode(.alwaysOriginal)
    }
}
