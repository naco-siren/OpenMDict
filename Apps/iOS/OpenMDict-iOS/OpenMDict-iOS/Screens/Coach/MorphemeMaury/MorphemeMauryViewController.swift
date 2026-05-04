//
//  MorphemeMauryViewController.swift
//  OpenMDict-iOS
//
//  M14 Morpheme Maury: daytime-TV-style morphology quiz.
//
//  Episode structure:
//  1. Intro — purple curtain + "Today on Morpheme Maury…"
//  2. Testimony — candidates parade one by one under the spotlight,
//     each claiming "I AM family!" User taps FAMILY! or LIAR! verdict.
//  3. Envelope — "THE RESULTS ARE IN…" drama pause, tap to open.
//  4. Reveal — one at a time, big "you ARE / you are NOT the morpheme!"
//     stacked on each candidate. User's prediction shown as ✓ or ✗.
//  5. Finale — "Case Closed. N of M verdicts correct."
//
//  Reuses MorphologyQuizEngine (same @Generable backend as Among wUrdS)
//  and the preload pipeline pattern from the other two coach modes.
//

import UIKit
import WebKit
import OpenMDictKit

#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26, *)
final class MorphemeMauryViewController: UIViewController {

    // MARK: - State

    private enum Phase {
        case loading
        case intro(MorphologyQuiz)
        case testimony(MorphologyQuiz, index: Int)
        case envelope(MorphologyQuiz)
        case revealing(MorphologyQuiz, index: Int)
        case finale(MorphologyQuiz)
        case failed(String)
        case completed
    }

    private var phase: Phase = .loading

    // MARK: - Quiz Queue

    private var queueWords: [(word: String, dictId: String)] = []
    private var queueCursor = 0
    private var preloadedQuiz: MorphologyQuiz?
    private var preloadTask: Task<MorphologyQuiz, Error>?

    // MARK: - Episode State

    private var currentQuiz: MorphologyQuiz?
    /// Map candidate.word → user's verdict (true = FAMILY, false = LIAR, nil = not yet)
    private var predictions: [String: Bool] = [:]
    /// Templates already used in the CURRENT episode, to avoid the same
    /// line appearing twice in one show. Reset per episode.
    private var usedTemplates: Set<String> = []

    /// Cap on candidates per episode to reduce testimony fatigue + template
    /// repetition. Takes the first N from the engine's shuffled output.
    private static let maxCandidatesPerEpisode = 5
    private func cappedCandidates(_ quiz: MorphologyQuiz) -> [MorphologyCandidate] {
        Array(quiz.allCandidates.prefix(Self.maxCandidatesPerEpisode))
    }

    // MARK: - UI

    private let stageView = MauryStageView()
    private let marqueeLights = MarqueeLightsView()

    // Nav title
    private let navTitleLabel = UILabel()

    // Show header: target word ("the baby") + episode banner
    private let headerContainer = UIView()
    private let babyLabel = UILabel()        // "in question: complete"
    private let episodeBanner = UILabel()     // "Today on Morpheme Maury…" or progress

    // Testimony area (center of stage)
    private let testimonyCard = TestimonyCardView()

    // Verdict buttons (pinned bottom during testimony)
    private let verdictBar = UIView()
    private let familyButton = UIButton(type: .system)
    private let liarButton = UIButton(type: .system)

    // Envelope overlay
    private let envelopeOverlay = UIView()
    private let envelopeHeadline = UILabel()
    private let envelopeView = EnvelopeView()
    private let envelopeHint = UILabel()

    // Reveal overlay (big verdict, with buildup + particle burst)
    private let revealOverlay = UIView()
    private let revealSpotlight = CAGradientLayer()  // tight radial behind verdict text
    private let revealCandidateLabel = UILabel()
    private let revealBuildupLabel = UILabel()        // "You..." buildup
    private let revealVerdictLabel = UILabel()        // "ARE\nthe morpheme!" etc.
    private let revealJudgment = UILabel()
    private let revealNextHint = UILabel()

    /// Monotonic counter. Each `showReveal` increments; async tap-unlock
    /// captures the value at dispatch time and bails if the counter has
    /// moved on (= a different reveal is now active).
    private var revealToken = 0

    // Finale overlay
    private let finaleOverlay = UIView()
    private let finaleTitle = UILabel()
    private let finaleScore = UILabel()
    private let finaleNextButton = UIButton(type: .system)

    // Loading / error placeholder (reuses stage aesthetic — no separate placeholder view)
    private let loadingIcon = UIImageView()
    private let loadingLabel = UILabel()
    private let loadingSubLabel = UILabel()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    private let loadingStack = UIStackView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark  // forced dark so the stage pops

        setupTitle()
        setupBackButton()
        setupStage()
        setupHeader()
        setupTestimonyArea()
        setupVerdictBar()
        setupEnvelopeOverlay()
        setupRevealOverlay()
        setupFinaleOverlay()
        setupLoadingUI()
        setupMarqueeLights()  // LAST so bulbs sit on top of all overlays

        buildQueueAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        preloadTask?.cancel()
        preloadTask = nil
        marqueeLights.stop()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        marqueeLights.start()
    }

    // MARK: - Title + Back

    private func setupTitle() {
        navTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        navTitleLabel.textColor = .white  // nav bar doesn't honor overrideUserInterfaceStyle
        navigationItem.titleView = navTitleLabel
        // Tint the back chevron white too
        navigationController?.navigationBar.tintColor = .white
        updateTitleProgress()
    }

    private func updateTitleProgress() {
        let attachment = NSTextAttachment()
        // `theatermasks.fill` is a multi-part SF Symbol: comedy (happy) mask
        // + tragedy (sad) mask. Palette rendering colors each part separately —
        // happy = green (success), sad = red (failure). Nicely encapsulates
        // the two outcomes of the show in the nav icon itself.
        let config = UIImage.SymbolConfiguration(paletteColors: [.systemGreen, .systemRed])
        attachment.image = UIImage(systemName: "theatermasks.fill", withConfiguration: config)?
            .withRenderingMode(.alwaysOriginal)
        let attrText = NSMutableAttributedString(attachment: attachment)
        let suffix: String
        let total = queueWords.count
        if total > 0 {
            let current = min(queueCursor + 1, total)
            suffix = " " + L10n.AICoach.Maury.title + "  \(current)/\(total)"
        } else {
            suffix = " " + L10n.AICoach.Maury.title
        }
        attrText.append(NSAttributedString(
            string: suffix,
            attributes: [.foregroundColor: UIColor.white,
                         .font: UIFont.systemFont(ofSize: 16, weight: .semibold)]))
        navTitleLabel.attributedText = attrText
        navTitleLabel.sizeToFit()
    }

    private func setupBackButton() {
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain, target: self, action: #selector(backTapped))
    }

    @objc private func backTapped() {
        switch phase {
        case .testimony, .envelope, .revealing:
            // Mid-show — confirm
            let alert = UIAlertController(
                title: L10n.AICoach.Maury.backstageTitle,
                message: L10n.AICoach.Maury.backstageMessage,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(
                title: L10n.AICoach.Maury.leaveShow, style: .destructive) { [weak self] _ in
                    self?.navigationController?.popViewController(animated: true)
                })
            alert.addAction(UIAlertAction(
                title: L10n.AICoach.Maury.stayOnStage, style: .cancel))
            present(alert, animated: true)
        default:
            navigationController?.popViewController(animated: true)
        }
    }

    // MARK: - Stage

    private func setupStage() {
        stageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stageView)
        NSLayoutConstraint.activate([
            stageView.topAnchor.constraint(equalTo: view.topAnchor),
            stageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Header

    private func setupHeader() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerContainer)

        // Episode banner on top: either "Today on Morpheme Maury…" or "Case 3 of 6"
        episodeBanner.font = .systemFont(ofSize: 13, weight: .heavy)
        episodeBanner.textColor = UIColor.systemYellow.withAlphaComponent(0.85)
        episodeBanner.textAlignment = .center
        episodeBanner.numberOfLines = 0
        episodeBanner.translatesAutoresizingMaskIntoConstraints = false
        // Letter-spacing for that marquee feel
        headerContainer.addSubview(episodeBanner)

        // "In question:" label for the baby/target word
        babyLabel.font = .systemFont(ofSize: 34, weight: .heavy)
        babyLabel.textColor = .white
        babyLabel.textAlignment = .center
        babyLabel.numberOfLines = 1
        babyLabel.adjustsFontSizeToFitWidth = true
        babyLabel.minimumScaleFactor = 0.55
        babyLabel.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(babyLabel)

        NSLayoutConstraint.activate([
            // topAnchor+24 pushes the "Case X/Y" banner below the top row
            // of marquee bulbs (at y≈10, radius 6 → extending to y≈16).
            // Prevents bulbs from obscuring the text.
            headerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 60),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -60),

            episodeBanner.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            episodeBanner.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            episodeBanner.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),

            babyLabel.topAnchor.constraint(equalTo: episodeBanner.bottomAnchor, constant: 8),
            babyLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            babyLabel.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            babyLabel.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
        ])
    }

    // MARK: - Testimony area

    private func setupTestimonyArea() {
        testimonyCard.translatesAutoresizingMaskIntoConstraints = false
        testimonyCard.alpha = 0
        view.addSubview(testimonyCard)
        NSLayoutConstraint.activate([
            testimonyCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            testimonyCard.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 40),
            // 60pt margin clears the red velvet curtain strips (~48pt wide).
            testimonyCard.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 60),
            testimonyCard.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -60),
        ])
    }

    // MARK: - Verdict bar

    private func setupVerdictBar() {
        verdictBar.translatesAutoresizingMaskIntoConstraints = false
        verdictBar.backgroundColor = .clear
        verdictBar.isHidden = true
        view.addSubview(verdictBar)

        familyButton.translatesAutoresizingMaskIntoConstraints = false
        familyButton.setTitle(L10n.AICoach.Maury.verdictFamily, for: .normal)
        familyButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .black)
        familyButton.setTitleColor(.white, for: .normal)
        familyButton.backgroundColor = UIColor(red: 0.12, green: 0.55, blue: 0.25, alpha: 1)
        familyButton.layer.cornerRadius = 14
        familyButton.layer.shadowColor = UIColor.systemGreen.cgColor
        familyButton.layer.shadowOpacity = 0.6
        familyButton.layer.shadowRadius = 14
        familyButton.layer.shadowOffset = .zero
        familyButton.addTarget(self, action: #selector(familyTapped), for: .touchUpInside)
        verdictBar.addSubview(familyButton)

        liarButton.translatesAutoresizingMaskIntoConstraints = false
        liarButton.setTitle(L10n.AICoach.Maury.verdictLiar, for: .normal)
        liarButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .black)
        liarButton.setTitleColor(.white, for: .normal)
        liarButton.backgroundColor = UIColor(red: 0.70, green: 0.12, blue: 0.18, alpha: 1)
        liarButton.layer.cornerRadius = 14
        liarButton.layer.shadowColor = UIColor.systemRed.cgColor
        liarButton.layer.shadowOpacity = 0.6
        liarButton.layer.shadowRadius = 14
        liarButton.layer.shadowOffset = .zero
        liarButton.addTarget(self, action: #selector(liarTapped), for: .touchUpInside)
        verdictBar.addSubview(liarButton)

        NSLayoutConstraint.activate([
            // Match testimony card horizontal insets — verdict bar feels
            // proportionally "part of" the card rather than stretching edge-to-edge.
            verdictBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            verdictBar.widthAnchor.constraint(equalToConstant: 320),
            // -36 clears the bottom bulb row (same 24pt "gap" as the header).
            verdictBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -36),
            verdictBar.heightAnchor.constraint(equalToConstant: 136),

            // Vertical stack: FAMILY on top, LIAR on bottom. Each button
            // fills full width, takes ~48% of the bar height with 10pt gap.
            familyButton.leadingAnchor.constraint(equalTo: verdictBar.leadingAnchor),
            familyButton.trailingAnchor.constraint(equalTo: verdictBar.trailingAnchor),
            familyButton.topAnchor.constraint(equalTo: verdictBar.topAnchor),
            familyButton.heightAnchor.constraint(equalTo: verdictBar.heightAnchor, multiplier: 0.46),

            liarButton.leadingAnchor.constraint(equalTo: verdictBar.leadingAnchor),
            liarButton.trailingAnchor.constraint(equalTo: verdictBar.trailingAnchor),
            liarButton.bottomAnchor.constraint(equalTo: verdictBar.bottomAnchor),
            liarButton.heightAnchor.constraint(equalTo: verdictBar.heightAnchor, multiplier: 0.46),
        ])
    }

    // MARK: - Envelope Overlay

    private func setupEnvelopeOverlay() {
        envelopeOverlay.translatesAutoresizingMaskIntoConstraints = false
        envelopeOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        envelopeOverlay.alpha = 0
        envelopeOverlay.isUserInteractionEnabled = false
        view.addSubview(envelopeOverlay)

        envelopeHeadline.translatesAutoresizingMaskIntoConstraints = false
        envelopeHeadline.text = L10n.AICoach.Maury.resultsAreIn
        envelopeHeadline.font = .systemFont(ofSize: 22, weight: .black)
        envelopeHeadline.textColor = UIColor.systemYellow
        envelopeHeadline.textAlignment = .center
        envelopeHeadline.numberOfLines = 0
        envelopeOverlay.addSubview(envelopeHeadline)

        envelopeView.translatesAutoresizingMaskIntoConstraints = false
        envelopeOverlay.addSubview(envelopeView)

        // Tap to reveal
        let tap = UITapGestureRecognizer(target: self, action: #selector(envelopeTapped))
        envelopeView.addGestureRecognizer(tap)
        envelopeView.isUserInteractionEnabled = true

        envelopeHint.translatesAutoresizingMaskIntoConstraints = false
        envelopeHint.text = L10n.AICoach.Maury.tapEnvelope
        envelopeHint.font = .systemFont(ofSize: 13, weight: .medium)
        envelopeHint.textColor = UIColor.white.withAlphaComponent(0.7)
        envelopeHint.textAlignment = .center
        envelopeOverlay.addSubview(envelopeHint)

        NSLayoutConstraint.activate([
            envelopeOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            envelopeOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            envelopeOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            envelopeOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            envelopeHeadline.centerXAnchor.constraint(equalTo: envelopeOverlay.centerXAnchor),
            envelopeHeadline.topAnchor.constraint(equalTo: envelopeOverlay.safeAreaLayoutGuide.topAnchor, constant: 120),
            envelopeHeadline.leadingAnchor.constraint(equalTo: envelopeOverlay.leadingAnchor, constant: 24),
            envelopeHeadline.trailingAnchor.constraint(equalTo: envelopeOverlay.trailingAnchor, constant: -24),

            envelopeView.centerXAnchor.constraint(equalTo: envelopeOverlay.centerXAnchor),
            envelopeView.centerYAnchor.constraint(equalTo: envelopeOverlay.centerYAnchor),
            envelopeView.widthAnchor.constraint(equalToConstant: 240),
            envelopeView.heightAnchor.constraint(equalToConstant: 160),

            envelopeHint.centerXAnchor.constraint(equalTo: envelopeOverlay.centerXAnchor),
            envelopeHint.topAnchor.constraint(equalTo: envelopeView.bottomAnchor, constant: 36),
        ])
    }

    // MARK: - Reveal Overlay

    private func setupRevealOverlay() {
        revealOverlay.translatesAutoresizingMaskIntoConstraints = false
        revealOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        revealOverlay.alpha = 0
        revealOverlay.isUserInteractionEnabled = false
        view.addSubview(revealOverlay)

        // ── Tight radial spotlight behind the verdict text ──
        revealSpotlight.type = .radial
        revealSpotlight.startPoint = CGPoint(x: 0.5, y: 0.5)
        revealSpotlight.endPoint = CGPoint(x: 1.0, y: 1.0)
        revealSpotlight.locations = [0.0, 0.35, 1.0]
        revealSpotlight.colors = [
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
        ]
        revealOverlay.layer.addSublayer(revealSpotlight)

        // NOTE: Particle emitter is created fresh per burst in `burstParticles`
        // and added to revealOverlay.layer — no persistent setup here.

        revealCandidateLabel.translatesAutoresizingMaskIntoConstraints = false
        revealCandidateLabel.font = .systemFont(ofSize: 24, weight: .bold)
        revealCandidateLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        revealCandidateLabel.textAlignment = .center
        revealOverlay.addSubview(revealCandidateLabel)

        // Buildup text — "You..." that fades in during the tension phase
        revealBuildupLabel.translatesAutoresizingMaskIntoConstraints = false
        revealBuildupLabel.font = .systemFont(ofSize: 54, weight: .black)
        revealBuildupLabel.textColor = UIColor.white.withAlphaComponent(0.95)
        revealBuildupLabel.textAlignment = .center
        revealBuildupLabel.text = "You\u{2026}"
        revealOverlay.addSubview(revealBuildupLabel)

        revealVerdictLabel.translatesAutoresizingMaskIntoConstraints = false
        revealVerdictLabel.font = .systemFont(ofSize: 38, weight: .black)
        revealVerdictLabel.textAlignment = .center
        revealVerdictLabel.numberOfLines = 0
        revealOverlay.addSubview(revealVerdictLabel)

        revealJudgment.translatesAutoresizingMaskIntoConstraints = false
        revealJudgment.font = .systemFont(ofSize: 16, weight: .semibold)
        revealJudgment.textAlignment = .center
        revealOverlay.addSubview(revealJudgment)

        revealNextHint.translatesAutoresizingMaskIntoConstraints = false
        revealNextHint.font = .systemFont(ofSize: 13, weight: .medium)
        revealNextHint.textColor = UIColor.white.withAlphaComponent(0.6)
        revealNextHint.textAlignment = .center
        revealNextHint.text = "Tap to continue"
        revealOverlay.addSubview(revealNextHint)

        let tap = UITapGestureRecognizer(target: self, action: #selector(revealTapped))
        revealOverlay.addGestureRecognizer(tap)

        NSLayoutConstraint.activate([
            revealOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            revealOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            revealOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            revealOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            revealCandidateLabel.centerXAnchor.constraint(equalTo: revealOverlay.centerXAnchor),
            revealCandidateLabel.centerYAnchor.constraint(equalTo: revealOverlay.centerYAnchor, constant: -120),
            revealCandidateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: revealOverlay.leadingAnchor, constant: 24),
            revealCandidateLabel.trailingAnchor.constraint(lessThanOrEqualTo: revealOverlay.trailingAnchor, constant: -24),

            // Buildup "You..." sits in the SAME slot as the verdict —
            // we swap visibility between them during the reveal flow.
            revealBuildupLabel.centerXAnchor.constraint(equalTo: revealOverlay.centerXAnchor),
            revealBuildupLabel.centerYAnchor.constraint(equalTo: revealOverlay.centerYAnchor),

            revealVerdictLabel.centerXAnchor.constraint(equalTo: revealOverlay.centerXAnchor),
            revealVerdictLabel.centerYAnchor.constraint(equalTo: revealOverlay.centerYAnchor),
            revealVerdictLabel.leadingAnchor.constraint(greaterThanOrEqualTo: revealOverlay.leadingAnchor, constant: 24),
            revealVerdictLabel.trailingAnchor.constraint(lessThanOrEqualTo: revealOverlay.trailingAnchor, constant: -24),

            revealJudgment.centerXAnchor.constraint(equalTo: revealOverlay.centerXAnchor),
            revealJudgment.topAnchor.constraint(equalTo: revealVerdictLabel.bottomAnchor, constant: 36),

            revealNextHint.centerXAnchor.constraint(equalTo: revealOverlay.centerXAnchor),
            revealNextHint.bottomAnchor.constraint(equalTo: revealOverlay.safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
    }

    /// Keep the reveal spotlight sized to the overlay. (Particle emitters
    /// are created fresh per burst with correct bounds, nothing to re-layout.)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        revealSpotlight.frame = revealOverlay.bounds
    }

    // MARK: - Finale Overlay

    private func setupFinaleOverlay() {
        finaleOverlay.translatesAutoresizingMaskIntoConstraints = false
        finaleOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        finaleOverlay.alpha = 0
        finaleOverlay.isUserInteractionEnabled = false
        view.addSubview(finaleOverlay)

        finaleTitle.translatesAutoresizingMaskIntoConstraints = false
        finaleTitle.text = L10n.AICoach.Maury.caseClosed
        finaleTitle.font = .systemFont(ofSize: 32, weight: .black)
        finaleTitle.textColor = .systemYellow
        finaleTitle.textAlignment = .center
        finaleOverlay.addSubview(finaleTitle)

        finaleScore.translatesAutoresizingMaskIntoConstraints = false
        finaleScore.font = .systemFont(ofSize: 20, weight: .semibold)
        finaleScore.textColor = .white
        finaleScore.textAlignment = .center
        finaleScore.numberOfLines = 0
        finaleOverlay.addSubview(finaleScore)

        finaleNextButton.translatesAutoresizingMaskIntoConstraints = false
        finaleNextButton.setTitle(L10n.AICoach.Maury.nextEpisode, for: .normal)
        finaleNextButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .heavy)
        finaleNextButton.setTitleColor(.white, for: .normal)
        finaleNextButton.backgroundColor = UIColor(red: 0.85, green: 0.55, blue: 0.15, alpha: 1)
        finaleNextButton.layer.cornerRadius = 14
        finaleNextButton.addTarget(self, action: #selector(nextEpisodeTapped), for: .touchUpInside)
        finaleOverlay.addSubview(finaleNextButton)

        NSLayoutConstraint.activate([
            finaleOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            finaleOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            finaleOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            finaleOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            finaleTitle.centerXAnchor.constraint(equalTo: finaleOverlay.centerXAnchor),
            finaleTitle.centerYAnchor.constraint(equalTo: finaleOverlay.centerYAnchor, constant: -60),

            finaleScore.centerXAnchor.constraint(equalTo: finaleOverlay.centerXAnchor),
            finaleScore.topAnchor.constraint(equalTo: finaleTitle.bottomAnchor, constant: 18),
            finaleScore.leadingAnchor.constraint(greaterThanOrEqualTo: finaleOverlay.leadingAnchor, constant: 24),
            finaleScore.trailingAnchor.constraint(lessThanOrEqualTo: finaleOverlay.trailingAnchor, constant: -24),

            finaleNextButton.centerXAnchor.constraint(equalTo: finaleOverlay.centerXAnchor),
            finaleNextButton.topAnchor.constraint(equalTo: finaleScore.bottomAnchor, constant: 36),
            finaleNextButton.widthAnchor.constraint(equalToConstant: 200),
            finaleNextButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    // MARK: - Loading UI

    private func setupLoadingUI() {
        loadingIcon.translatesAutoresizingMaskIntoConstraints = false
        loadingIcon.contentMode = .scaleAspectFit
        applyLoadingIcon(symbol: "theatermasks.fill",
                         palette: [.systemPurple, .systemYellow])

        loadingLabel.text = L10n.AICoach.Maury.curtainUp
        loadingLabel.font = .systemFont(ofSize: 22, weight: .heavy)
        loadingLabel.textColor = UIColor.systemYellow.withAlphaComponent(0.9)
        loadingLabel.textAlignment = .center
        loadingLabel.numberOfLines = 0

        loadingSubLabel.text = L10n.AICoach.Maury.stagehandsAtWork
        loadingSubLabel.font = .systemFont(ofSize: 15, weight: .regular)
        loadingSubLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        loadingSubLabel.textAlignment = .center
        loadingSubLabel.numberOfLines = 0

        loadingSpinner.color = UIColor.systemYellow.withAlphaComponent(0.9)

        // Vertical stack: icon → title → spinner → sub-message
        loadingStack.axis = .vertical
        loadingStack.alignment = .center
        loadingStack.spacing = 14
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        loadingStack.addArrangedSubview(loadingIcon)
        loadingStack.addArrangedSubview(loadingLabel)
        loadingStack.addArrangedSubview(loadingSpinner)
        loadingStack.addArrangedSubview(loadingSubLabel)
        loadingStack.setCustomSpacing(18, after: loadingIcon)
        loadingStack.setCustomSpacing(18, after: loadingLabel)
        view.addSubview(loadingStack)

        NSLayoutConstraint.activate([
            loadingStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loadingStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            loadingStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            loadingIcon.widthAnchor.constraint(equalToConstant: 76),
            loadingIcon.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    /// Update the loading/error icon with a palette-colored SF Symbol.
    private func applyLoadingIcon(symbol: String, palette: [UIColor]) {
        let config = UIImage.SymbolConfiguration(
            pointSize: 56, weight: .regular
        ).applying(UIImage.SymbolConfiguration(paletteColors: palette))
        loadingIcon.image = UIImage(systemName: symbol, withConfiguration: config)?
            .withRenderingMode(.alwaysOriginal)
    }

    // MARK: - Marquee Lights (game-show bulbs around screen edge)

    private func setupMarqueeLights() {
        marqueeLights.translatesAutoresizingMaskIntoConstraints = false
        marqueeLights.palette = .idle
        view.addSubview(marqueeLights)
        NSLayoutConstraint.activate([
            marqueeLights.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            marqueeLights.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            marqueeLights.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            marqueeLights.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        // Put the show header IN FRONT of the top bulbs so "Case 1/5" stays
        // readable. The outer-edge bulbs are still visible; only a few
        // central ones are occluded by the text, which is the right trade.
        view.bringSubviewToFront(headerContainer)
        marqueeLights.start()
    }

    // MARK: - Phase Transitions

    private func showLoadingState() {
        phase = .loading
        currentQuiz = nil
        predictions.removeAll()
        headerContainer.isHidden = true
        testimonyCard.alpha = 0
        verdictBar.isHidden = true
        envelopeOverlay.alpha = 0
        revealOverlay.alpha = 0
        finaleOverlay.alpha = 0

        // Loading state: theater masks in stage palette (purple + yellow),
        // with spinner active and "Curtain up..." / "Stagehands at work..."
        applyLoadingIcon(symbol: "theatermasks.fill",
                         palette: [.systemPurple, .systemYellow])
        loadingLabel.text = L10n.AICoach.Maury.curtainUp
        loadingLabel.textColor = UIColor.systemYellow.withAlphaComponent(0.9)
        loadingSubLabel.text = L10n.AICoach.Maury.stagehandsAtWork
        loadingStack.isHidden = false
        loadingSpinner.isHidden = false
        loadingSpinner.startAnimating()
    }

    private func hideLoadingUI() {
        loadingSpinner.stopAnimating()
        loadingStack.isHidden = true
    }

    private func showIntro(_ quiz: MorphologyQuiz) {
        currentQuiz = quiz
        predictions.removeAll()
        usedTemplates.removeAll()   // fresh show, fresh testimony pool
        marqueeLights.palette = .idle
        phase = .intro(quiz)
        hideLoadingUI()

        headerContainer.isHidden = false
        babyLabel.text = "\u{201C}\(quiz.targetWord)\u{201D}"
        episodeBanner.attributedText = marquee(L10n.AICoach.Maury.episodeIntro(quiz.targetWord))

        updateTitleProgress()

        // Brief intro dwell (1.5s) then → first testimony
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, case .intro = self.phase else { return }
            self.showTestimony(quiz, index: 0)
        }
    }

    private func showTestimony(_ quiz: MorphologyQuiz, index: Int) {
        let candidates = cappedCandidates(quiz)
        guard index < candidates.count else {
            // All judged — to envelope
            showEnvelope(quiz)
            return
        }
        phase = .testimony(quiz, index: index)

        // Header progress marquee
        let progress = L10n.AICoach.Maury.caseProgress(index + 1, candidates.count)
        episodeBanner.attributedText = marquee(progress)

        let candidate = candidates[index]

        // Pick a testimony line that hasn't been used yet this episode
        let testimonyText = pickUnusedTestimony(for: candidate, quiz: quiz)

        // Animate previous card out (if any), then new card in
        UIView.animate(withDuration: 0.25, animations: {
            self.testimonyCard.alpha = 0
            self.testimonyCard.transform = CGAffineTransform(translationX: -60, y: 0)
        }) { _ in
            self.testimonyCard.configure(word: candidate.word, testimony: testimonyText)
            self.testimonyCard.transform = CGAffineTransform(translationX: 60, y: 0)
            UIView.animate(withDuration: 0.35, delay: 0,
                           usingSpringWithDamping: 0.75, initialSpringVelocity: 0) {
                self.testimonyCard.alpha = 1
                self.testimonyCard.transform = .identity
            }
        }

        verdictBar.isHidden = false
        verdictBar.alpha = 1
        familyButton.isEnabled = true
        liarButton.isEnabled = true

        // Spotlight chase — slight horizontal drift based on candidate index
        let sweep = CGFloat(index) / CGFloat(max(1, candidates.count - 1))
        let nx = 0.35 + sweep * 0.3
        stageView.animateSpotlight(to: CGPoint(x: nx, y: 0.45))
    }

    /// Pick a testimony template that hasn't been used yet this episode.
    /// Tracks the raw template key (pre-substitution) in `usedTemplates`.
    /// If all templates have been used (unlikely with 50+), clear the set.
    private func pickUnusedTestimony(
        for candidate: MorphologyCandidate, quiz: MorphologyQuiz
    ) -> String {
        let available = Self.testimonyTemplates.filter { template in
            // Skip templates that need a prefix/suffix the quiz doesn't have
            if template.contains("$prefix"), quiz.prefix == nil { return false }
            if template.contains("$suffix"), quiz.suffix == nil { return false }
            return !usedTemplates.contains(template)
        }
        let pool = available.isEmpty ? {
            // All used up — reset (shouldn't happen with 5-candidate cap)
            self.usedTemplates.removeAll()
            return Self.testimonyTemplates.filter {
                (!$0.contains("$prefix") || quiz.prefix != nil) &&
                (!$0.contains("$suffix") || quiz.suffix != nil)
            }
        }() : available
        let template = pool.randomElement() ?? Self.testimonyTemplates[0]
        usedTemplates.insert(template)
        return Self.fillPlaceholders(template, candidate: candidate, quiz: quiz)
    }

    private func showEnvelope(_ quiz: MorphologyQuiz) {
        phase = .envelope(quiz)

        // Hide verdict bar + testimony card
        UIView.animate(withDuration: 0.3) {
            self.verdictBar.alpha = 0
            self.testimonyCard.alpha = 0
        } completion: { _ in
            self.verdictBar.isHidden = true
        }

        // Pulse the envelope
        envelopeOverlay.isUserInteractionEnabled = true
        envelopeView.reset()
        UIView.animate(withDuration: 0.4) {
            self.envelopeOverlay.alpha = 1
        }
        envelopeView.startPulsing()

        episodeBanner.attributedText = marquee(L10n.AICoach.Maury.resultsAreIn)
    }

    @objc private func envelopeTapped() {
        guard case .envelope(let quiz) = phase else { return }
        envelopeView.stopPulsing()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        envelopeView.open { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.4, animations: {
                self.envelopeOverlay.alpha = 0
            }) { _ in
                self.envelopeOverlay.isUserInteractionEnabled = false
                self.showReveal(quiz, index: 0)
            }
        }
    }

    private func showReveal(_ quiz: MorphologyQuiz, index: Int) {
        let candidates = cappedCandidates(quiz)
        guard index < candidates.count else {
            showFinale(quiz)
            return
        }
        phase = .revealing(quiz, index: index)

        // New reveal → bump token so any leaked async work from the previous
        // burst (stop-emitter timer, enable-tap timer) bails out.
        revealToken += 1
        let myToken = revealToken

        let candidate = candidates[index]
        let isCognate = !candidate.isImposter
        let userSaidFamily = predictions[candidate.word] ?? false
        let isCorrect = userSaidFamily == isCognate

        // Compose labels
        revealCandidateLabel.text = "\u{201C}\(candidate.word)\u{201D}"
        revealVerdictLabel.text = isCognate
            ? L10n.AICoach.Maury.youAreTheMorpheme
            : L10n.AICoach.Maury.youAreNotTheMorpheme
        revealVerdictLabel.textColor = isCognate ? .systemTeal : .systemRed

        let judgmentText: String = {
            let call = userSaidFamily
                ? L10n.AICoach.Maury.verdictFamily
                : L10n.AICoach.Maury.verdictLiar
            let mark = isCorrect ? "\u{2713}" : "\u{2717}"
            return "Your call: \(call) \(mark)"
        }()
        revealJudgment.text = judgmentText
        revealJudgment.textColor = isCorrect ? .systemGreen : .systemOrange

        // Reset animation state
        revealOverlay.isUserInteractionEnabled = false  // locked during buildup
        revealCandidateLabel.alpha = 0
        revealBuildupLabel.alpha = 0
        revealBuildupLabel.transform = .identity
        revealVerdictLabel.alpha = 0
        revealVerdictLabel.transform = CGAffineTransform(scaleX: 0.35, y: 0.35)
        revealJudgment.alpha = 0
        revealNextHint.alpha = 0
        setRevealSpotlight(open: true, animated: false)  // wide/dim at start

        // ── Stage 1: overlay fades in, candidate name appears at top ──
        UIView.animate(withDuration: 0.3) {
            self.revealOverlay.alpha = 1
            self.revealCandidateLabel.alpha = 1
        }

        // ── Stage 2: "You..." buildup — 0.9s dwell with spotlight tightening ──
        UIView.animate(withDuration: 0.45, delay: 0.35,
                       usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.revealBuildupLabel.alpha = 1
            self.revealBuildupLabel.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
        }
        // Tighten the spotlight around the "You..." label as tension builds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.setRevealSpotlight(open: false, animated: true)
        }

        // ── Stage 3: verdict boom ──
        let verdictDelay: TimeInterval = 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + verdictDelay) { [weak self] in
            guard let self, case .revealing = self.phase else { return }

            // Dismiss the "You..." buildup
            UIView.animate(withDuration: 0.2) {
                self.revealBuildupLabel.alpha = 0
                self.revealBuildupLabel.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            }

            // Verdict drops in with spring
            UIView.animate(withDuration: 0.55, delay: 0.1,
                           usingSpringWithDamping: 0.52, initialSpringVelocity: 1.0) {
                self.revealVerdictLabel.alpha = 1
                self.revealVerdictLabel.transform = .identity
            }

            // Particle burst + haptic
            self.burstParticles(celebrating: isCognate, token: myToken)

            // Marquee flips to green (correct) or red (wrong). The palette
            // signals the USER'S accuracy, not the candidate's identity —
            // tomatoes/confetti already express family/imposter.
            self.marqueeLights.palette = isCorrect ? .correct : .wrong
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            if isCognate {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }

            // User's prediction judgment + tap hint (0.7s after verdict drop)
            UIView.animate(withDuration: 0.3, delay: 0.7) {
                self.revealJudgment.alpha = 1
                self.revealNextHint.alpha = 1
            }

            // Enable tap AFTER particles have emitted (~1.5s for emit + a
            // bit of tail). User can't skip before the effects play out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
                guard let self, self.revealToken == myToken else { return }
                self.revealOverlay.isUserInteractionEnabled = true
            }
        }
    }

    /// Set the reveal spotlight — either wide/dim (during buildup) or
    /// tight/bright (at verdict drop). Animated for smooth tightening.
    private func setRevealSpotlight(open: Bool, animated: Bool) {
        let duration: CFTimeInterval = animated ? 0.9 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        if open {
            // Wide dim spotlight at start — just a hint of warmth
            revealSpotlight.locations = [0.0, 0.6, 1.0]
            revealSpotlight.colors = [
                UIColor(red: 1.0, green: 0.92, blue: 0.72, alpha: 0.08).cgColor,
                UIColor(red: 1.0, green: 0.85, blue: 0.50, alpha: 0.03).cgColor,
                UIColor.clear.cgColor,
            ]
        } else {
            // Tight bright spotlight converging on center
            revealSpotlight.locations = [0.0, 0.25, 0.55]
            revealSpotlight.colors = [
                UIColor(red: 1.0, green: 0.95, blue: 0.75, alpha: 0.55).cgColor,
                UIColor(red: 1.0, green: 0.88, blue: 0.55, alpha: 0.20).cgColor,
                UIColor.clear.cgColor,
            ]
        }
        CATransaction.commit()
    }

    // MARK: - Particles

    /// Fire a particle burst. Confetti (celebration) if `celebrating == true`,
    /// thrown food/boots (booing) otherwise.
    ///
    /// Previous approaches tried to reuse a single `revealEmitter` property
    /// across bursts — but CAEmitterLayer has subtle internal state
    /// (begin-time, cell lifecycle, emission flags) that's extremely hard
    /// to reset reliably. Every re-burst attempt failed for different
    /// reasons (wrong birthRate, stale cells, clock drift, token races).
    ///
    /// The nuclear fix: **build a fresh CAEmitterLayer for every burst**,
    /// install it, let it emit, then remove it after particles die. No
    /// state between bursts, no tokens, no races. CAEmitterLayer is cheap
    /// enough that this is fine.
    private func burstParticles(celebrating: Bool, token: Int) {
        let templates = celebrating ? Self.confettiCells : Self.booCells
        let freshCells = templates.compactMap { $0.copy() as? CAEmitterCell }

        debugLog("🎭 Maury burst: \(celebrating ? "confetti" : "boo") — \(freshCells.count) cells, token=\(token)")

        let emitter = CAEmitterLayer()
        emitter.emitterShape = .line
        emitter.emitterMode = .surface
        emitter.renderMode = .unordered
        emitter.emitterCells = freshCells
        emitter.frame = revealOverlay.bounds
        emitter.emitterPosition = CGPoint(x: revealOverlay.bounds.midX, y: -20)
        emitter.emitterSize = CGSize(width: revealOverlay.bounds.width, height: 2)
        emitter.zPosition = 100
        emitter.masksToBounds = false
        emitter.birthRate = 1
        revealOverlay.layer.addSublayer(emitter)

        // Stop emission after the initial burst (~1.4s worth of cells at
        // their configured rates). Existing particles keep animating via
        // their `lifetime` until they vanish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak emitter] in
            emitter?.birthRate = 0
        }
        // Clean up the layer once all particles have fulfilled their 4s
        // lifetime. `weak` reference means if the VC is gone, the layer
        // was already removed with its parent view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak emitter] in
            emitter?.removeFromSuperlayer()
        }
    }

    /// Cached confetti cells (gold/pink/cyan sparkles raining down).
    private static let confettiCells: [CAEmitterCell] = {
        let emojis = ["\u{1F389}", "\u{1F38A}", "\u{2728}", "\u{1F31F}"]  // 🎉🎊✨🌟
        return emojis.map { emoji in
            let cell = CAEmitterCell()
            cell.contents = emojiImage(emoji, size: 36)?.cgImage
            cell.birthRate = 14
            cell.lifetime = 4.0
            cell.velocity = 260
            cell.velocityRange = 120
            cell.yAcceleration = 140          // gravity pulling confetti down
            cell.xAcceleration = 0
            cell.emissionLongitude = .pi / 2  // downward
            cell.emissionRange = .pi / 4
            cell.spin = 3.5
            cell.spinRange = 6
            cell.scale = 0.8
            cell.scaleRange = 0.35
            cell.alphaSpeed = -0.3
            return cell
        }
    }()

    /// Cached boo cells (tomatoes, eggs, boots, stink flying in from edges).
    private static let booCells: [CAEmitterCell] = {
        let emojis = ["\u{1F345}", "\u{1F373}", "\u{1F462}", "\u{1F9C5}", "\u{1F4A9}"]  // 🍅🍳👢🧅💩
        return emojis.map { emoji in
            let cell = CAEmitterCell()
            cell.contents = emojiImage(emoji, size: 44)?.cgImage
            cell.birthRate = 8
            cell.lifetime = 3.0
            cell.velocity = 340
            cell.velocityRange = 140
            cell.yAcceleration = 220          // heavy — falls fast
            cell.xAcceleration = 0
            cell.emissionLongitude = .pi / 2  // downward, wider angle
            cell.emissionRange = .pi / 2
            cell.spin = 4.0
            cell.spinRange = 8
            cell.scale = 0.95
            cell.scaleRange = 0.4
            cell.alphaSpeed = -0.4
            return cell
        }
    }()

    /// Render an emoji to a UIImage for CAEmitterCell content.
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

    @objc private func revealTapped() {
        guard case .revealing(let quiz, let index) = phase else { return }
        revealOverlay.isUserInteractionEnabled = false
        // Marquee back to idle between verdicts (next reveal will flip it again)
        marqueeLights.palette = .idle
        UIView.animate(withDuration: 0.25, animations: {
            self.revealOverlay.alpha = 0
        }) { _ in
            self.showReveal(quiz, index: index + 1)
        }
    }

    private func showFinale(_ quiz: MorphologyQuiz) {
        phase = .finale(quiz)

        let candidates = cappedCandidates(quiz)
        // Count correct predictions across the candidates we actually played
        var correct = 0
        for candidate in candidates {
            let userSaidFamily = predictions[candidate.word] ?? false
            let isCognate = !candidate.isImposter
            if userSaidFamily == isCognate { correct += 1 }
        }
        let total = candidates.count
        finaleScore.text = L10n.AICoach.Maury.finalScore(correct, total)

        let pct = total > 0 ? (correct * 100 / total) : 0
        finaleTitle.text = pct == 100
            ? "\u{1F3AD} Perfect Episode!"
            : L10n.AICoach.Maury.caseClosed

        UIView.animate(withDuration: 0.45) {
            self.finaleOverlay.alpha = 1
        }
        finaleOverlay.isUserInteractionEnabled = true

        if pct == 100 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    @objc private func nextEpisodeTapped() {
        guard case .finale = phase else { return }
        finaleOverlay.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.3, animations: {
            self.finaleOverlay.alpha = 0
        }) { _ in
            self.resetAndStartNext()
        }
    }

    private func showError(_ message: String) {
        phase = .failed(message)
        hideLoadingUI()
        // Red + gray theater masks (the failing show), with the reason.
        applyLoadingIcon(symbol: "theatermasks.fill",
                         palette: [UIColor.systemRed.withAlphaComponent(0.85),
                                   UIColor(white: 0.55, alpha: 1)])
        loadingLabel.text = "The show can't go on"
        loadingLabel.textColor = UIColor.systemRed.withAlphaComponent(0.9)
        loadingSubLabel.text = message
        loadingSpinner.stopAnimating()
        loadingSpinner.isHidden = true
        loadingStack.isHidden = false
    }

    private func showCompleted() {
        phase = .completed
        hideLoadingUI()
        // Green + gold masks — triumphant end-of-show palette.
        applyLoadingIcon(symbol: "theatermasks.fill",
                         palette: [.systemGreen,
                                   UIColor(red: 1.0, green: 0.80, blue: 0.20, alpha: 1)])
        loadingLabel.text = "That's a wrap!"
        loadingLabel.textColor = UIColor.systemYellow
        loadingSubLabel.text = "All bookmarked guests have been on the show."
        loadingSpinner.stopAnimating()
        loadingSpinner.isHidden = true
        loadingStack.isHidden = false
    }

    // MARK: - Verdict Taps

    @objc private func familyTapped() {
        recordVerdict(familyIsTrue: true)
    }

    @objc private func liarTapped() {
        recordVerdict(familyIsTrue: false)
    }

    private func recordVerdict(familyIsTrue: Bool) {
        guard case .testimony(let quiz, let index) = phase else { return }
        let candidates = cappedCandidates(quiz)
        guard index < candidates.count else { return }
        let candidate = candidates[index]
        predictions[candidate.word] = familyIsTrue
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        familyButton.isEnabled = false
        liarButton.isEnabled = false

        // Brief "gavel strike" feedback: the verdict button flashes and
        // testimony card slides off toward that side.
        let xOffset: CGFloat = familyIsTrue ? view.bounds.width : -view.bounds.width
        UIView.animate(withDuration: 0.35, delay: 0.08, options: .curveEaseIn) {
            self.testimonyCard.transform = CGAffineTransform(translationX: xOffset, y: -12)
                .rotated(by: familyIsTrue ? 0.18 : -0.18)
            self.testimonyCard.alpha = 0
        } completion: { _ in
            self.showTestimony(quiz, index: index + 1)
        }
    }

    // MARK: - Quiz Queue

    private static let maxSkipsPerLoad = 3

    private func buildQueueAndStart() {
        showLoadingState()
        Task {
            let bookmarks = BookmarkService.shared.allBookmarks()
            let filtered = await Self.filterEnglishBookmarks(bookmarks)
            guard !filtered.isEmpty else {
                phase = .completed
                showError(L10n.AICoach.Maury.noBookmarksMessage)
                return
            }
            queueWords = filtered.shuffled()
            queueCursor = 0
            preloadedQuiz = nil
            preloadTask?.cancel()
            preloadTask = nil
            updateTitleProgress()
            loadQuizAtCursor()
        }
    }

    @concurrent
    private static func filterEnglishBookmarks(
        _ bookmarks: [BookmarkItem]
    ) async -> [(word: String, dictId: String)] {
        bookmarks
            .filter { suitableForMorphologyQuiz($0.word) }
            .map { ($0.word, $0.dictId) }
    }

    nonisolated private static func suitableForMorphologyQuiz(_ word: String) -> Bool {
        let count = word.count
        guard count >= 5, count <= 15 else { return false }
        guard !word.contains(" "), !word.contains("-") else { return false }
        for ch in word {
            guard ch.isASCII, ch.isLetter else { return false }
        }
        let lc = word.lowercased()
        let banned = ["aceous", "iform", "escent", "itis", "osis", "ology"]
        if banned.contains(where: { lc.hasSuffix($0) }) { return false }
        let prefixes = [
            "pre", "con", "com", "dis", "re", "ex", "in", "im", "un",
            "sub", "trans", "inter", "pro", "de", "ab", "ad", "per",
            "ob", "super", "over", "under", "mis", "out", "fore",
        ]
        let suffixes = [
            "tion", "sion", "ment", "ness", "able", "ible", "ive",
            "ous", "ful", "less", "ity", "ence", "ance", "ure",
            "ate", "ize", "ise", "ify", "ent", "ant",
        ]
        return prefixes.contains { lc.hasPrefix($0) }
            || suffixes.contains { lc.hasSuffix($0) }
    }

    private func loadQuizAtCursor() {
        Task {
            var skips = 0
            while queueCursor < queueWords.count, skips < Self.maxSkipsPerLoad {
                let entry = queueWords[queueCursor]
                do {
                    let quiz = try await MorphologyQuizEngine.buildMorphologyQuiz(
                        targetWord: entry.word, targetDictId: entry.dictId)
                    guard !quiz.allCandidates.isEmpty else {
                        queueCursor += 1; skips += 1; continue
                    }
                    showIntro(quiz)
                    startPreloadingNext()
                    return
                } catch {
                    debugLog("⚠️ Maury: '\(entry.word)' failed: \(error)")
                    queueCursor += 1; skips += 1
                }
            }
            showError(L10n.AICoach.Maury.episodeBusted)
        }
    }

    private func startPreloadingNext() {
        let next = queueCursor + 1
        guard next < queueWords.count else { preloadTask = nil; preloadedQuiz = nil; return }
        preloadedQuiz = nil
        preloadTask = Task {
            var cursor = next; var skips = 0
            while cursor < queueWords.count, skips < Self.maxSkipsPerLoad {
                let entry = queueWords[cursor]
                do {
                    let quiz = try await MorphologyQuizEngine.buildMorphologyQuiz(
                        targetWord: entry.word, targetDictId: entry.dictId)
                    if quiz.allCandidates.isEmpty { cursor += 1; skips += 1; continue }
                    await MainActor.run { self.queueCursor = cursor; self.preloadedQuiz = quiz }
                    return quiz
                } catch { cursor += 1; skips += 1 }
            }
            throw QuizQueueError.exhausted
        }
    }

    private enum QuizQueueError: Error { case exhausted }

    private func resetAndStartNext() {
        showLoadingState()
        if let ready = preloadedQuiz {
            preloadedQuiz = nil; preloadTask = nil
            showIntro(ready)
            startPreloadingNext()
        } else if let task = preloadTask {
            Task {
                do {
                    let quiz = try await task.value
                    preloadedQuiz = nil; preloadTask = nil
                    showIntro(quiz)
                    startPreloadingNext()
                } catch {
                    preloadTask = nil
                    queueCursor += 1
                    if queueCursor < queueWords.count { loadQuizAtCursor() }
                    else { showCompleted() }
                }
            }
        } else {
            queueCursor += 1
            if queueCursor < queueWords.count { loadQuizAtCursor() }
            else { showCompleted() }
        }
    }

    // MARK: - Helpers

    /// Letter-spaced marquee text for banner — mimics old-TV title cards.
    private func marquee(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .kern: 2.5,
                .font: UIFont.systemFont(ofSize: 12, weight: .heavy),
                .foregroundColor: UIColor.systemYellow.withAlphaComponent(0.85),
            ])
    }

    /// Randomized testimony template — all candidates claim family, symmetric
    /// so the user can't tell truth from lie by tone alone.
    /// Pool of ~40 testimony templates across Maury-show archetypes:
    /// indignant, tearful, historian, logician, deflector, desperate,
    /// smooth-talker, philosophical, catchphrase, etc.
    ///
    /// Templates are SYMMETRIC — both true cognates and imposters pick from
    /// the same pool. User can't read tone alone to judge.
    ///
    /// Placeholders: `$target`, `$self`, `$root`, `$prefix`, `$suffix` (latter
    /// two only rendered if present in the quiz).
    private static let testimonyTemplates: [String] = [
        // Indignant / offended
        "Slander! I've had enough of this! I AM $self, descendant of $root!",
        "How DARE you bring me on this show to humiliate me!",
        "This is a DISGRACE, Maury. A DIS. GRACE. $self has a good name!",
        "I will NOT sit here and let you question my lineage!",
        "$self and $target — we're practically the same word, and you know it!",

        // Tearful / pleading
        "Maury, please... I have CHILDREN at home who need to know the truth.",
        "I've been called a liar my whole life. Can't I just have THIS one thing?",
        "I just want a DNA test. That's all I'm asking. Just a simple test.",
        "Do you know how HARD it is to be $self in this world?",
        "All I've ever wanted is for $target to call me family. Is that too much?",

        // Historian / authority appeal
        "My roots go back to ANCIENT ROME, Maury. I can name every ancestor.",
        "The Latin scholars — ALL of them — agreed $self shares $root.",
        "Open ANY etymology book. You'll see $self and $target on the same page.",
        "I've been a $root-family member since the 14th century. Look it up.",
        "The Oxford English Dictionary literally CITES me, Maury. Literally.",

        // Logician / evidence
        "The prefix $prefix is right THERE. The evidence writes itself.",
        "Both of us end in $suffix. Coincidence? I don't think so.",
        "Break the word down, Maury. $self = $prefix + $root. It's not complicated.",
        "Spelling tells the truth. Just look at us side by side.",
        "Semantically, morphologically, phonologically — I check every box.",

        // Deflector / shady
        "Why are you grilling ME? Check the OTHER words on this stage!",
        "I'll take a test — with MY lawyer present, thank you very much.",
        "I don't need to prove ANYTHING to you or this audience.",
        "Fine, fine — you want the truth? You can't HANDLE the truth.",
        "Maury, can we talk off-camera for a second? I have information.",

        // Desperate / all-in
        "I SWEAR ON MY MAMA'S GRAVE I'm a $root family member!",
        "If I'm lying, may lightning strike me where I stand!",
        "Look into my eyes, Maury. LOOK. Do these eyes lie?",
        "I will take ten tests. TWENTY. Bring them ALL on!",
        "Everything I have, everything I am — it ALL comes from $root!",

        // Smooth-talker / confident
        "Maury, Maury, Maury. Let me break this down for you real quick.",
        "You and I both know I'm family. The audience knows. $target knows.",
        "I ain't worried. I ain't sweatin'. Open that envelope.",
        "The results? Already know what they say. I'm $root through and through.",
        "Call me what you want. At the end of the day, blood is blood.",

        // Philosophical / absurd
        "What even IS family, Maury? Aren't we ALL connected at the root?",
        "Labels, schmabels. $self knows who $self is.",
        "I may not LOOK like $target, but my SOUL is $root.",
        "Etymology is a social construct. I identify as $root-family.",

        // Short punch lines
        "Family. Period.",
        "Don't you dare doubt me.",
        "I AM the morpheme.",
        "$self ≠ liar. $self = family.",
        "Blood don't lie, Maury.",

        // Movie & TV catchphrases (remixed)
        // Jerry Maguire
        "You had me at $target.",
        "Show me the ROOT! SHOW ME THE ROOT!",
        "$target, you complete me. Quite literally.",
        // The Godfather
        "I'm gonna make $target an offer it can't refuse.",
        "Leave the etymology. Take the cognate.",
        // A Few Good Men
        "You can't HANDLE the truth about $root!",
        // Forrest Gump
        "Life is like a box of morphemes. You never know which one's family.",
        "Maury and me, we go together like $target and $self. Peas and carrots.",
        // Terminator
        "I'll be back. With DNA results.",
        "Hasta la vista, imposter.",
        // Star Wars
        "May the $root be with you.",
        "These aren't the cognates you're looking for. ...Wait, YES they are.",
        "Luke, I AM your root word.",
        // Sixth Sense
        "I see dead etymologies. They're everywhere.",
        // Dirty Dancing
        "Nobody puts $self in a corner.",
        // Scarface
        "Say HELLO to my little morpheme!",
        // Taxi Driver
        "You talkin' to ME, Maury? You talkin' to $self?",
        // Apollo 13
        "Houston, we have a problem — and it's my name being slandered.",
        // Gone With the Wind
        "Frankly, Maury, I don't give a damn what the paperwork says.",
        // The Princess Bride
        "My name is $self. You killed my reputation. Prepare to apologize.",
        "INCONCEIVABLE!",
        // Casablanca
        "Of all the gin joints in all the etymology books, I had to walk into Maury's.",
        // Titanic
        "I'm the king of the $root!",
        // Shawshank Redemption
        "Get busy claiming family, or get busy lying.",

        // Dynamic hooks that splice both words or use the root creatively
        "Every morning I wake up and think: $self, $target, together again.",
        "I've been writing a book about this. Title: \u{201C}$self & $target: A Love Story.\u{201D}",
        "$self is $root. $root is $self. Write that down.",
        "Look at $self. Look at $target. Now tell me we're not cousins.",
        "Same root. Same blood. Same DESTINY.",
        "People say $self and $target are 'just similar.' People are wrong.",
        "$self, $target — we're two sides of the same etymological coin.",
        "Tell the jury I said this: $self shares $root with $target. PRINT IT.",
        "Go ahead. Open the envelope. $self and $target come out on top.",
        "I grew up on stories of $target. We're the same family tree.",

        // ── Second wave of movie / TV / meme remixes ──
        // Star Wars
        "No, $self, I am your father.",
        "Help me, Maury. You're my only hope.",
        // Spider-Man
        "With great $root comes great responsibility.",
        // Jurassic Park
        "Life, uh, finds a way. $root finds a way.",
        // There Will Be Blood
        "I drink your $root. I DRINK IT UP!",
        // Jaws
        "You're gonna need a bigger etymology book.",
        // Top Gun
        "I feel the need — the need for $root!",
        // Back to the Future
        "Roads? Where we're going, we don't need roads — just $root.",
        // ET
        "E.T. phone $target.",
        // Die Hard
        "Yippee-ki-yay, etymology-denier.",
        // Cool Hand Luke
        "What we got here is failure to communicate. I AM $root.",
        // Notting Hill
        "I'm just a word, standing in front of $target, asking to be family.",
        // When Harry Met Sally
        "I'll have what $target's having.",
        // Sherlock
        "Elementary, my dear Maury. $self shares $root with $target. Obvious.",
        // Godfather II
        "I know it was you, $target. You broke my heart.",
        // Hamlet
        "To $target, or not to $target — I AM $target, that's the answer.",
        // Apocalypse Now
        "I love the smell of $root in the morning.",
        // Rocky
        "Yo, Maury. I just wanna say — $self. Made it.",
        // The Matrix
        "I know $root. I AM $root.",
        "There is no spoon. There is only $root.",
        // The Lion King
        "You are more than what you have become. You are $root.",

        // TV shows
        // Friends
        "How YOU doin'? I'm $self.",
        // The Office
        "I DECLARE — I AM $root!",
        // Seinfeld
        "NO SOUP — I mean, no doubt. I'm $root.",
        // Simpsons — Homer
        "D'OH! Of course $self is $root!",
        // Breaking Bad
        "Say my name. SAY IT. $self. You're goddamn right.",
        // Game of Thrones
        "A $self always pays its debts. I owe $target everything.",
        "You know nothing, Maury. $self IS family.",

        // Memes
        "One does not simply walk in and deny $self.",
        "Such $root. Very family. Wow.",
        "I can haz $target-family membership?",
        "But that's none of my business. (Sips tea.)",
        "This is fine. I'm $root. Everything is fine.",

        // Literature / philosophy (lightly remixed)
        "Cogito, ergo $root.",
        "Ask not what $target can do for me — ask what I can do for $target.",
        "The only thing we have to fear is fear itself. And imposters.",
    ]

    private static func testimony(
        for candidate: MorphologyCandidate, quiz: MorphologyQuiz
    ) -> String {
        let template = testimonyTemplates.randomElement() ?? testimonyTemplates[0]
        return fillPlaceholders(template, candidate: candidate, quiz: quiz)
    }

    /// Substitute `$target` / `$self` / `$root` / `$prefix` / `$suffix`.
    /// Templates that reference `$prefix` or `$suffix` are skipped at draw
    /// time if the quiz doesn't have them (handled by a second pass below).
    private static func fillPlaceholders(
        _ template: String, candidate: MorphologyCandidate, quiz: MorphologyQuiz
    ) -> String {
        // If template references $prefix but quiz has no prefix (or $suffix
        // with no suffix), fall back to a random safe template.
        if template.contains("$prefix"), quiz.prefix == nil {
            return fillPlaceholders(safeFallback(), candidate: candidate, quiz: quiz)
        }
        if template.contains("$suffix"), quiz.suffix == nil {
            return fillPlaceholders(safeFallback(), candidate: candidate, quiz: quiz)
        }

        let rootWord = quiz.root.isEmpty ? "our root" : quiz.root
        return template
            .replacingOccurrences(of: "$target", with: "\u{201C}\(quiz.targetWord)\u{201D}")
            .replacingOccurrences(of: "$self", with: "\u{201C}\(candidate.word)\u{201D}")
            .replacingOccurrences(of: "$root", with: rootWord)
            .replacingOccurrences(of: "$prefix", with: quiz.prefix ?? "")
            .replacingOccurrences(of: "$suffix", with: quiz.suffix ?? "")
    }

    /// Templates that never reference prefix/suffix — safe for any quiz.
    private static func safeFallback() -> String {
        let safe = testimonyTemplates.filter {
            !$0.contains("$prefix") && !$0.contains("$suffix")
        }
        return safe.randomElement() ?? testimonyTemplates[0]
    }
}

// MARK: - TestimonyCardView

@available(iOS 26, *)
private final class TestimonyCardView: UIView {
    private let card = UIView()
    private let wordLabel = UILabel()
    private let quoteLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .clear

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(red: 0.97, green: 0.95, blue: 0.88, alpha: 1)  // cream witness card
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.35
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(card)

        wordLabel.translatesAutoresizingMaskIntoConstraints = false
        wordLabel.font = .systemFont(ofSize: 38, weight: .black)
        wordLabel.textColor = UIColor(red: 0.18, green: 0.04, blue: 0.20, alpha: 1)
        wordLabel.textAlignment = .center
        wordLabel.adjustsFontSizeToFitWidth = true
        wordLabel.minimumScaleFactor = 0.55
        wordLabel.numberOfLines = 1
        card.addSubview(wordLabel)

        quoteLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteLabel.font = .italicSystemFont(ofSize: 19)
        quoteLabel.textColor = UIColor(red: 0.30, green: 0.08, blue: 0.30, alpha: 1)
        quoteLabel.textAlignment = .center
        quoteLabel.numberOfLines = 0
        card.addSubview(quoteLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            wordLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            wordLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            wordLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            quoteLabel.topAnchor.constraint(equalTo: wordLabel.bottomAnchor, constant: 16),
            quoteLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            quoteLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            quoteLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),

            widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    func configure(word: String, testimony: String) {
        wordLabel.text = "\u{201C}\(word)\u{201D}"
        quoteLabel.text = "\u{201C}\(testimony)\u{201D}"
    }
}

// MARK: - EnvelopeView

/// Manila envelope with a triangular flap that opens on command.
@available(iOS 26, *)
private final class EnvelopeView: UIView {
    private let body = UIView()
    private let flapLayer = CAShapeLayer()
    private let sealLayer = CAShapeLayer()  // wax seal at bottom-center of flap
    private var pulseTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        body.backgroundColor = UIColor(red: 0.94, green: 0.88, blue: 0.75, alpha: 1)
        body.layer.cornerRadius = 6
        body.layer.shadowColor = UIColor.black.cgColor
        body.layer.shadowOpacity = 0.5
        body.layer.shadowRadius = 22
        body.layer.shadowOffset = CGSize(width: 0, height: 10)
        addSubview(body)

        // Flap layer lives inside `body`, with anchorPoint at top-center so
        // it rotates around the hinge at the envelope's top edge.
        flapLayer.fillColor = UIColor(red: 0.88, green: 0.80, blue: 0.64, alpha: 1).cgColor
        flapLayer.strokeColor = UIColor(red: 0.55, green: 0.40, blue: 0.25, alpha: 1).cgColor
        flapLayer.lineWidth = 1
        flapLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        body.layer.addSublayer(flapLayer)

        // Wax seal: small red circle at the flap's point, hidden after opening
        sealLayer.fillColor = UIColor(red: 0.68, green: 0.10, blue: 0.12, alpha: 1).cgColor
        sealLayer.strokeColor = UIColor(red: 0.35, green: 0.04, blue: 0.06, alpha: 1).cgColor
        sealLayer.lineWidth = 1.5
        flapLayer.addSublayer(sealLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        body.frame = bounds

        let flapHeight = bounds.height * 0.55

        // Path coordinates are in the flap's OWN coordinate space (same size
        // as the envelope body, anchored at top-center for rotation).
        // Triangle: from top-left to top-right, point down to center.
        let flapPath = UIBezierPath()
        flapPath.move(to: CGPoint(x: 0, y: 0))
        flapPath.addLine(to: CGPoint(x: bounds.width / 2, y: flapHeight))
        flapPath.addLine(to: CGPoint(x: bounds.width, y: 0))
        flapPath.close()
        flapLayer.path = flapPath.cgPath

        // Frame: spans full width of body, height of flap only.
        // Because anchorPoint = (0.5, 0), the layer's POSITION must also be
        // at the top-center of the parent in order for the visible geometry
        // to match the raw frame. Set them consistently:
        flapLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: flapHeight)
        flapLayer.position = CGPoint(x: bounds.width / 2, y: 0)

        // Wax seal: small circle at the flap's point (bottom center of flap
        // in flap's own bounds, which is at y = flapHeight)
        let sealRadius: CGFloat = 10
        let sealCenter = CGPoint(x: bounds.width / 2, y: flapHeight - sealRadius * 0.6)
        let sealRect = CGRect(
            x: sealCenter.x - sealRadius, y: sealCenter.y - sealRadius,
            width: sealRadius * 2, height: sealRadius * 2)
        sealLayer.path = UIBezierPath(ovalIn: sealRect).cgPath
        sealLayer.frame = flapLayer.bounds
    }

    /// Full state reset — called by the VC before re-showing the envelope.
    /// Use `CATransaction.setDisableActions` so the reset happens instantly
    /// with zero implicit animation.
    func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flapLayer.transform = CATransform3DIdentity
        sealLayer.opacity = 1
        CATransaction.commit()
        alpha = 1
        transform = .identity
        stopPulsing()
    }

    func startPulsing() {
        stopPulsing()
        // Animate the whole view (self) so body + flapLayer scale as a unit.
        // Animating body.transform alone doesn't carry the scale through to
        // body's sublayers during implicit UIView animation.
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            UIView.animate(withDuration: 0.6, delay: 0,
                           options: [.autoreverse, .allowUserInteraction]) {
                self.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
            } completion: { _ in
                self.transform = .identity
            }
        }
    }

    func stopPulsing() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        transform = .identity
    }

    /// Animate the seal cracking, the flap opening, then the whole envelope
    /// flying off-screen. Final state is "faded + off-screen + flap-open" —
    /// intentionally NOT reset here to avoid the visible snap-back flash.
    /// The next `reset()` (called by the VC before re-showing) cleans up.
    func open(completion: @escaping () -> Void) {
        // Step 1: wax seal "cracks" — fade out with a tiny scale burst
        CATransaction.begin()
        let sealFade = CABasicAnimation(keyPath: "opacity")
        sealFade.fromValue = 1.0
        sealFade.toValue = 0.0
        sealFade.duration = 0.2
        sealLayer.add(sealFade, forKey: "seal-crack")
        sealLayer.opacity = 0
        CATransaction.commit()

        // Step 2: flap rotates up around its top hinge
        UIView.animate(withDuration: 0.65, delay: 0.15,
                       usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4) {
            var t = CATransform3DIdentity
            t.m34 = -1.0 / 500  // perspective
            t = CATransform3DRotate(t, .pi * 0.9, 1, 0, 0)
            self.flapLayer.transform = t
        } completion: { _ in
            // Step 3: whole envelope shoots up + fades
            UIView.animate(withDuration: 0.4, delay: 0.15,
                           options: .curveEaseIn) {
                self.transform = CGAffineTransform(translationX: 0, y: -160)
                    .scaledBy(x: 1.25, y: 1.25)
                self.alpha = 0
            } completion: { _ in
                // Just hand control off to the VC. Do NOT snap the flap
                // back to closed here — it causes a visible flash even
                // though alpha is 0, because the layer reset happens
                // during a frame where the view's alpha is still being
                // composed. State reset is deferred to `reset()`.
                completion()
            }
        }
    }
}
