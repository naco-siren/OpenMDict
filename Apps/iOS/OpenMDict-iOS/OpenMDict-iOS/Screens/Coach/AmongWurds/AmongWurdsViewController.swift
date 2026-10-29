//
//  AmongWurdsViewController.swift
//  OpenMDict-iOS
//
//  M14: Among wUrdS — Among Us-themed morphology quiz.
//
//  Game loop (single-select eject, official Among Us style):
//  - Crewmates + imposters in 2-column grid with colored card backgrounds
//  - Kill timer murders crewmates; each kill escalates SAN effects
//  - User taps ONE suspect → "EJECT" → immersive result overlay
//  - Win: all imposters ejected, ≥1 crewmate alive
//  - Lose: all crewmates eliminated
//  - Endgame: "Verify Identities" → all cards return with identity
//

import UIKit
import WebKit
import OpenMDictKit

#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26, *)
final class AmongWurdsViewController: UIViewController {

    // MARK: - State

    private enum Phase {
        case loading
        case playing(MorphologyQuiz)
        case revealing(MorphologyQuiz)  // endgame: all identities shown
        case failed(String)
        case completed
    }

    /// Endgame classification. `nil` (computed via `checkEndCondition`) means
    /// the game continues. Checked after EVERY state change — player eject,
    /// imposter kill — so transitions can't be missed.
    private enum EndCondition: Equatable {
        case victory                  // all imposters ejected, ≥1 crewmate alive
        case defeatCrewEliminated     // 0 crewmates alive
        case defeatNotEnough          // aliveCrewmates > 0 but ≤ aliveImposters (Among Us classic parity loss)

        var isVictory: Bool {
            if case .victory = self { return true } else { return false }
        }
    }

    private var phase: Phase = .loading

    // MARK: - Quiz Queue

    private var queueWords: [(word: String, dictId: String)] = []
    private var queueCursor = 0
    private var preloadedQuiz: MorphologyQuiz?
    private var preloadTask: Task<MorphologyQuiz, Error>?

    // MARK: - Game State

    private var selectedWord: String?
    private var ejectedWords = Set<String>()
    private var killedCrewmates = Set<String>()
    private var currentQuiz: MorphologyQuiz?
    private var killIndex = 0

    // MARK: - Skeleton Loading State

    /// Number of skeleton cells currently in the grid.
    private var skeletonCount = 0
    /// How many skeleton cells have "lit up" (got a crew color).
    private var skeletonLitCount = 0
    /// Crew colors assigned to lit skeleton cells during loading.
    private var skeletonColors: [Int: Int] = [:]  // item index → colorIndex

    // Kill timer — length must match SanityEffects.tiers.count (8 stages).
    // Monotonically decreasing = accelerating panic.
    private var killTimer: Timer?
    private static let killIntervals: [TimeInterval] = [15, 13, 11, 9, 7, 5, 4, 3]

    // MARK: - Collection View

    private nonisolated enum Section: Hashable, Sendable { case main }
    private nonisolated enum Item: Hashable, Sendable {
        case skeleton(Int)       // loading placeholder, index = position
        case candidate(String)   // real word
    }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private let headerContainer = UIView()
    private let quizWordCard = UIView()
    private let quizWordLabel = UILabel()
    private let rootInfoLabel = UILabel()
    private let imposterBanner = UILabel()

    private let placeholderView = UIView()
    private let placeholderIcon = UIImageView()
    private let placeholderSpinner = UIActivityIndicatorView(style: .medium)
    private let placeholderTitle = UILabel()
    private let placeholderMessage = UILabel()

    private let ctaContainer = UIView()
    private let ctaButton = UIButton(type: .system)
    private let ctaSeparator = UIView()

    /// Immersive eject result overlay (replaces system alerts).
    private let ejectOverlay = UIView()
    private let ejectLabel = UILabel()

    /// Reactor meltdown overlay (loading failure explosion).
    private let meltdownOverlay = UIView()
    private let meltdownLabel = UILabel()

    private let navTitleLabel = UILabel()
    private let sanRenderer = SanityEffectRenderer()

    /// Background space layer — ejected cards drift here during play.
    private let spaceFloater = SpaceFloaterView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)

        setupTitleView()
        setupBackButton()
        setupHeader()
        setupCTAView()
        setupSpaceFloater()  // behind collectionView — floaters drift underneath
        setupCollectionView()
        setupDataSource()
        setupPlaceholder()
        setupEjectOverlay()
        setupMeltdownOverlay()
        // SAN renderer LAST so overlays are foreground
        sanRenderer.install(on: view, shakeView: collectionView)

        headerContainer.isHidden = true
        ctaContainer.isHidden = true
        buildQueueAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopAllTimers()
        sanRenderer.tearDown()
        spaceFloater.pause()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        spaceFloater.resume()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sanRenderer.updateLayout()
    }

    // MARK: - Title

    private func setupTitleView() {
        navTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        navigationItem.titleView = navTitleLabel
        updateTitleProgress()
    }

    private func updateTitleProgress() {
        // Nav icon + title both tinted `.systemOrange` to match the AI Coach
        // chooser facade's StudyMode.image for this mode (bespoke
        // `AmongWurds` PNG — Among Us crewmate silhouette).
        //
        // PNG attachment needs explicit `bounds` to scale down to text
        // height — unlike SF symbols, PNGs use pixel-native size by
        // default. 18×18 with y=-3 baseline-aligns to 16pt semibold text.
        let attachment = NSTextAttachment()
        attachment.image = UIImage(named: "AmongWurds")?
            .withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
        attachment.bounds = CGRect(x: 0, y: -3, width: 18, height: 18)
        let attrText = NSMutableAttributedString(attachment: attachment)
        // Title text tinted the same `.systemOrange` as the icon — both
        // surfaces (chooser cell + nav bar) now carry the same brand color
        // for this mode.
        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.systemOrange,
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
        ]
        let total = queueWords.count
        if total > 0 {
            let current = min(queueCursor + 1, total)
            attrText.append(NSAttributedString(
                string: " " + L10n.AICoach.AmongWurds.title + "  \(current)/\(total)",
                attributes: textAttrs))
        } else {
            attrText.append(NSAttributedString(
                string: " " + L10n.AICoach.AmongWurds.title,
                attributes: textAttrs))
        }
        navTitleLabel.attributedText = attrText
        navTitleLabel.sizeToFit()
    }

    // MARK: - Back Button

    private func setupBackButton() {
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain, target: self, action: #selector(backTapped))
    }

    @objc private func backTapped() {
        switch phase {
        case .revealing, .failed, .loading, .completed:
            navigationController?.popViewController(animated: true)
        case .playing:
            // Themed Among-Us-spaceship copy: "Eject from Ship? / Your
            // crew's lives are still in danger… / Eject / Stay Aboard".
            // Destructive action reuses the existing `eject` key (same
            // verb the game's in-round buzzer uses); cancel uses a new
            // `stayAboard` key. Replaces the generic AICoach `leave*`
            // keys which read as flat boilerplate.
            let alert = UIAlertController(
                title: L10n.AICoach.AmongWurds.leaveTitle,
                message: L10n.AICoach.AmongWurds.leaveMessage,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.AICoach.AmongWurds.eject, style: .destructive) { [weak self] _ in
                self?.stopAllTimers()
                self?.navigationController?.popViewController(animated: true)
            })
            // `.default` + `preferredAction` highlights "Stay Aboard"
            // as the recommended choice per Apple HIG (tinted background
            // button on iOS 26 Liquid Glass; bold title on older iOS).
            // See PhrasyFeudViewController.backTapped for the rationale
            // re: trade-off vs `.cancel` style.
            let stayAction = UIAlertAction(title: L10n.AICoach.AmongWurds.stayAboard, style: .default)
            alert.addAction(stayAction)
            alert.preferredAction = stayAction
            present(alert, animated: true)
        }
    }

    // MARK: - Header (quiz word card + root info + banner)

    private func setupHeader() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.backgroundColor = UIColor(white: 0.06, alpha: 1)
        view.addSubview(headerContainer)

        // Quiz word card — colored background like crew cards.
        // Tappable anywhere (any phase) to push the article VC for the target word.
        quizWordCard.translatesAutoresizingMaskIntoConstraints = false
        quizWordCard.layer.cornerRadius = 14
        quizWordCard.layer.cornerCurve = .continuous
        quizWordCard.clipsToBounds = true
        quizWordCard.isUserInteractionEnabled = true
        quizWordCard.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(quizWordCardTapped)))
        headerContainer.addSubview(quizWordCard)

        quizWordLabel.font = .systemFont(ofSize: 26, weight: .bold)
        quizWordLabel.textColor = .white
        quizWordLabel.textAlignment = .center
        quizWordLabel.translatesAutoresizingMaskIntoConstraints = false
        quizWordCard.addSubview(quizWordLabel)

        rootInfoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        rootInfoLabel.textColor = UIColor(white: 0.75, alpha: 1)
        rootInfoLabel.textAlignment = .center
        rootInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        quizWordCard.addSubview(rootInfoLabel)

        imposterBanner.numberOfLines = 0
        imposterBanner.textAlignment = .center
        imposterBanner.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(imposterBanner)

        let separator = UIView()
        separator.backgroundColor = UIColor(white: 0.20, alpha: 1)
        separator.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(separator)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            quizWordCard.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 10),
            quizWordCard.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 20),
            quizWordCard.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -20),

            quizWordLabel.topAnchor.constraint(equalTo: quizWordCard.topAnchor, constant: 10),
            quizWordLabel.centerXAnchor.constraint(equalTo: quizWordCard.centerXAnchor),

            rootInfoLabel.topAnchor.constraint(equalTo: quizWordLabel.bottomAnchor, constant: 2),
            rootInfoLabel.centerXAnchor.constraint(equalTo: quizWordCard.centerXAnchor),
            rootInfoLabel.leadingAnchor.constraint(greaterThanOrEqualTo: quizWordCard.leadingAnchor, constant: 8),
            rootInfoLabel.trailingAnchor.constraint(lessThanOrEqualTo: quizWordCard.trailingAnchor, constant: -8),
            rootInfoLabel.bottomAnchor.constraint(equalTo: quizWordCard.bottomAnchor, constant: -10),

            imposterBanner.topAnchor.constraint(equalTo: quizWordCard.bottomAnchor, constant: 10),
            imposterBanner.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 20),
            imposterBanner.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -20),
            imposterBanner.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -10),

            separator.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
    }

    @objc private func quizWordCardTapped() {
        guard let quiz = currentQuiz else { return }
        // Small press feedback so it's clear the card is interactive
        UIView.animate(withDuration: 0.08, animations: {
            self.quizWordCard.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }) { _ in
            UIView.animate(withDuration: 0.15) {
                self.quizWordCard.transform = .identity
            }
        }
        pushArticle(for: quiz.targetWord)
    }

    private func updateHeader(_ quiz: MorphologyQuiz) {
        headerContainer.isHidden = false
        imposterBanner.isHidden = false
        quizWordLabel.text = quiz.targetWord

        // Quiz word is a confirmed crewmate — always use teal identity style
        quizWordCard.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.20)
        quizWordCard.layer.borderWidth = 2
        quizWordCard.layer.borderColor = UIColor.systemTeal.cgColor

        var rootParts: [String] = []
        if let prefix = quiz.prefix { rootParts.append(prefix) }
        rootParts.append(L10n.AICoach.AmongWurds.rootInfo(quiz.root))
        if let suffix = quiz.suffix { rootParts.append(suffix) }
        rootInfoLabel.text = rootParts.joined(separator: "  ·  ")

        updateBannerText(quiz)
    }

    private func updateBannerText(_ quiz: MorphologyQuiz) {
        let aliveImposters = quiz.imposters.filter { !ejectedWords.contains($0.word) }
        let count = aliveImposters.count

        let white: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
        ]
        let red: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.systemRed,
            .font: UIFont.systemFont(ofSize: 16, weight: .heavy),
        ]

        // The sentence comes from one localized plural string; the count
        // inside it is drawn in red. The count is formatted with the same
        // specifier and locale as the sentence so it can be found in it.
        let sentence = L10n.AICoach.AmongWurds.imposterBanner(count)
        let text = NSMutableAttributedString(string: sentence, attributes: white)
        let countText = String.localizedStringWithFormat("%lld", count)
        if let countRange = sentence.range(of: countText) {
            text.setAttributes(red, range: NSRange(countRange, in: sentence))
        }
        imposterBanner.attributedText = text
    }

    // MARK: - Collection View

    private func setupSpaceFloater() {
        spaceFloater.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spaceFloater)
        NSLayoutConstraint.activate([
            // Fills the area between the header and the CTA — same as collectionView.
            // The collectionView is added after this, so it renders on top; floaters
            // drift visible through the gaps between cells and below the grid.
            spaceFloater.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            spaceFloater.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            spaceFloater.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spaceFloater.bottomAnchor.constraint(equalTo: ctaContainer.topAnchor),
        ])
    }

    private func setupCollectionView() {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .absolute(72))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(72))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item, item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: ctaContainer.topAnchor),
        ])
    }

    private func setupDataSource() {
        let candidateReg = UICollectionView.CellRegistration<CrewCandidateCell, String> {
            [weak self] cell, _, word in
            guard let self else { return }
            let (state, color) = self.cellAppearance(for: word)
            cell.configure(word: word, crewColor: color, state: state)
        }
        let skeletonReg = UICollectionView.CellRegistration<CrewCandidateCell, Int> {
            [weak self] cell, _, index in
            guard let self else { return }
            if let colorIdx = self.skeletonColors[index] {
                let color = MorphologyCandidate.crewColorPalette[colorIdx % MorphologyCandidate.crewColorPalette.count]
                cell.configure(word: "", crewColor: color, state: .skeletonLit)
            } else {
                cell.configure(word: "", crewColor: .gray, state: .skeleton)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            cv, ip, item in
            switch item {
            case .skeleton(let index):
                return cv.dequeueConfiguredReusableCell(using: skeletonReg, for: ip, item: index)
            case .candidate(let word):
                return cv.dequeueConfiguredReusableCell(using: candidateReg, for: ip, item: word)
            }
        }
    }

    private func cellAppearance(for word: String) -> (CrewCandidateCell.CellState, UIColor) {
        let candidate = currentQuiz?.allCandidates.first(where: { $0.word == word })
        let color = candidate?.crewColor ?? .gray

        if case .revealing = phase {
            let isImposter = candidate?.isImposter ?? false
            if ejectedWords.contains(word) {
                return (isImposter ? .revealedEjectedImposter : .revealedEjectedCrewmate, color)
            }
            if killedCrewmates.contains(word) {
                return (.revealedMurdered, color)
            }
            return (isImposter ? .revealedImposter : .revealedCrewmate, color)
        }
        // Murdered crewmates are revealed immediately — death surfaces identity.
        if killedCrewmates.contains(word) { return (.revealedMurdered, color) }
        if selectedWord == word { return (.markedSus, color) }
        return (.normal, color)
    }

    // MARK: - CTA

    private func setupCTAView() {
        ctaContainer.translatesAutoresizingMaskIntoConstraints = false
        ctaContainer.backgroundColor = UIColor(white: 0.06, alpha: 1)
        view.addSubview(ctaContainer)

        ctaButton.translatesAutoresizingMaskIntoConstraints = false
        ctaButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .heavy)
        ctaButton.setTitleColor(.white, for: .normal)
        ctaButton.setTitleColor(.white.withAlphaComponent(0.5), for: .disabled)
        ctaButton.layer.cornerRadius = 12
        ctaButton.clipsToBounds = true
        ctaButton.addTarget(self, action: #selector(ctaTapped), for: .touchUpInside)
        ctaContainer.addSubview(ctaButton)

        ctaSeparator.backgroundColor = UIColor(white: 0.20, alpha: 1)
        ctaSeparator.translatesAutoresizingMaskIntoConstraints = false
        ctaContainer.addSubview(ctaSeparator)

        NSLayoutConstraint.activate([
            ctaContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ctaContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ctaContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ctaButton.topAnchor.constraint(equalTo: ctaContainer.topAnchor, constant: 12),
            ctaButton.leadingAnchor.constraint(equalTo: ctaContainer.leadingAnchor, constant: 20),
            ctaButton.trailingAnchor.constraint(equalTo: ctaContainer.trailingAnchor, constant: -20),
            ctaButton.bottomAnchor.constraint(equalTo: ctaContainer.bottomAnchor, constant: -8),
            ctaButton.heightAnchor.constraint(equalToConstant: 50),
            ctaSeparator.leadingAnchor.constraint(equalTo: ctaContainer.leadingAnchor),
            ctaSeparator.trailingAnchor.constraint(equalTo: ctaContainer.trailingAnchor),
            ctaSeparator.topAnchor.constraint(equalTo: ctaContainer.topAnchor),
            ctaSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
    }

    private func updateCTA() {
        switch phase {
        case .loading:
            ctaContainer.isHidden = true
        case .playing:
            ctaContainer.isHidden = false
            ctaButton.setTitle(L10n.AICoach.AmongWurds.ejectCTA, for: .normal)
            ctaButton.backgroundColor = selectedWord == nil
                ? UIColor(white: 0.25, alpha: 1) : .systemRed
            ctaButton.isEnabled = selectedWord != nil
        case .revealing:
            ctaContainer.isHidden = false
            ctaButton.setTitle(L10n.AICoach.AmongWurds.next, for: .normal)
            ctaButton.backgroundColor = .tintColor
            ctaButton.isEnabled = true
        case .failed:
            ctaContainer.isHidden = false
            ctaButton.setTitle(L10n.AICoach.AmongWurds.tryAgain, for: .normal)
            ctaButton.backgroundColor = .tintColor
            ctaButton.isEnabled = true
        case .completed:
            ctaContainer.isHidden = true
        }
    }

    @objc private func ctaTapped() {
        switch phase {
        case .playing(let quiz):
            if let word = selectedWord { performEject(word, quiz: quiz) }
        case .revealing:
            resetAndStartNext()
        case .failed:
            showLoadingState()
            loadQuizAtCursor()
        default:
            break
        }
    }

    // MARK: - Eject Overlay (immersive, not system alert)

    private func setupEjectOverlay() {
        ejectOverlay.translatesAutoresizingMaskIntoConstraints = false
        ejectOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        ejectOverlay.alpha = 0
        ejectOverlay.isUserInteractionEnabled = true
        view.addSubview(ejectOverlay)

        ejectLabel.translatesAutoresizingMaskIntoConstraints = false
        ejectLabel.font = .systemFont(ofSize: 22, weight: .heavy)
        ejectLabel.textAlignment = .center
        ejectLabel.numberOfLines = 0
        ejectOverlay.addSubview(ejectLabel)

        // Tap to dismiss
        ejectOverlay.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(dismissEjectOverlay)))

        NSLayoutConstraint.activate([
            ejectOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            ejectOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ejectOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ejectOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ejectLabel.centerXAnchor.constraint(equalTo: ejectOverlay.centerXAnchor),
            ejectLabel.centerYAnchor.constraint(equalTo: ejectOverlay.centerYAnchor),
            ejectLabel.leadingAnchor.constraint(greaterThanOrEqualTo: ejectOverlay.leadingAnchor, constant: 30),
            ejectLabel.trailingAnchor.constraint(lessThanOrEqualTo: ejectOverlay.trailingAnchor, constant: -30),
        ])
    }

    /// Show the immersive eject result overlay.
    /// `wasImposter`: true → red text "was An Imposter!", false → white "was not An Imposter..."
    // MARK: - Meltdown Overlay (loading failure)

    private func setupMeltdownOverlay() {
        meltdownOverlay.translatesAutoresizingMaskIntoConstraints = false
        meltdownOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        meltdownOverlay.alpha = 0
        meltdownOverlay.isUserInteractionEnabled = false
        view.addSubview(meltdownOverlay)

        meltdownLabel.translatesAutoresizingMaskIntoConstraints = false
        meltdownLabel.font = .systemFont(ofSize: 24, weight: .heavy)
        meltdownLabel.textColor = .systemOrange
        meltdownLabel.textAlignment = .center
        meltdownLabel.numberOfLines = 0
        meltdownOverlay.addSubview(meltdownLabel)

        NSLayoutConstraint.activate([
            meltdownOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            meltdownOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            meltdownOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            meltdownOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            meltdownLabel.centerXAnchor.constraint(equalTo: meltdownOverlay.centerXAnchor),
            meltdownLabel.centerYAnchor.constraint(equalTo: meltdownOverlay.centerYAnchor),
            meltdownLabel.leadingAnchor.constraint(greaterThanOrEqualTo: meltdownOverlay.leadingAnchor, constant: 30),
            meltdownLabel.trailingAnchor.constraint(lessThanOrEqualTo: meltdownOverlay.trailingAnchor, constant: -30),
        ])
    }

    /// Play reactor meltdown explosion: red flash, cells scatter, show message, then fade out.
    private func playMeltdownAnimation() {
        meltdownLabel.text = L10n.AICoach.AmongWurds.reactorMeltdown

        // Scatter all visible cells in random directions
        for cell in collectionView.visibleCells {
            let angle = CGFloat.random(in: -.pi...(.pi))
            let distance: CGFloat = CGFloat.random(in: 200...500)
            let tx = cos(angle) * distance
            let ty = sin(angle) * distance
            UIView.animate(withDuration: 0.5, delay: Double.random(in: 0...0.15),
                           options: .curveEaseIn) {
                cell.transform = CGAffineTransform(translationX: tx, y: ty)
                    .rotated(by: CGFloat.random(in: -1...1))
                cell.alpha = 0
            }
        }

        // Red flash → meltdown overlay
        UIView.animate(withDuration: 0.15) {
            self.view.backgroundColor = UIColor(red: 0.4, green: 0.05, blue: 0.05, alpha: 1)
        } completion: { _ in
            UIView.animate(withDuration: 0.3) {
                self.view.backgroundColor = UIColor(white: 0.06, alpha: 1)
                self.meltdownOverlay.alpha = 1
            }
        }

        // Fade out meltdown message after a beat (engine sleeps 1.5s before next attempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.meltdownLabel.text = L10n.AICoach.AmongWurds.reassemblingCrew
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            UIView.animate(withDuration: 0.3) {
                self?.meltdownOverlay.alpha = 0
            }
        }
    }

    private func showEjectResult(word: String, wasImposter: Bool) {
        // Pause kill timer during overlay
        killTimer?.invalidate()

        if wasImposter {
            ejectLabel.text = L10n.AICoach.AmongWurds.ejectedImposter(word)
            ejectLabel.textColor = .systemRed
        } else {
            ejectLabel.text = L10n.AICoach.AmongWurds.ejectedCrewmate(word)
            ejectLabel.textColor = UIColor(white: 0.7, alpha: 1)
        }

        view.bringSubviewToFront(ejectOverlay)
        UIView.animate(withDuration: 0.3) {
            self.ejectOverlay.alpha = 1
        }
    }

    @objc private func dismissEjectOverlay() {
        UIView.animate(withDuration: 0.25) {
            self.ejectOverlay.alpha = 0
        } completion: { [weak self] _ in
            guard let self, case .playing(let quiz) = self.phase else { return }

            if let condition = self.checkEndCondition(quiz) {
                self.endGame(quiz, condition: condition)
            } else {
                // Game continues — resume kill timer
                self.updateBannerText(quiz)
                self.scheduleNextKill()
            }
        }
    }

    // MARK: - Placeholder

    private func setupPlaceholder() {
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.isHidden = true
        view.addSubview(placeholderView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.addSubview(stack)

        placeholderIcon.image = UIImage(systemName: "person.crop.circle.badge.questionmark.fill")
        placeholderIcon.tintColor = .tertiaryLabel
        placeholderIcon.preferredSymbolConfiguration = .init(pointSize: 48)
        stack.addArrangedSubview(placeholderIcon)

        let row = UIStackView(arrangedSubviews: [placeholderSpinner, placeholderTitle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        stack.addArrangedSubview(row)

        placeholderTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        placeholderTitle.textColor = .secondaryLabel
        placeholderTitle.textAlignment = .center
        placeholderTitle.numberOfLines = 0

        placeholderMessage.font = .systemFont(ofSize: 14)
        placeholderMessage.textColor = .tertiaryLabel
        placeholderMessage.textAlignment = .center
        placeholderMessage.numberOfLines = 0
        stack.addArrangedSubview(placeholderMessage)

        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: ctaContainer.topAnchor),
            stack.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: placeholderView.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: placeholderView.trailingAnchor, constant: -40),
        ])
    }

    private func showPlaceholder(loading: Bool, title: String, message: String) {
        placeholderView.isHidden = false
        collectionView.isHidden = true
        if loading {
            placeholderIcon.image = UIImage(systemName: "person.crop.circle.badge.questionmark.fill")
            placeholderIcon.tintColor = .tertiaryLabel
            placeholderSpinner.startAnimating()
            placeholderSpinner.isHidden = false
        } else {
            placeholderIcon.image = UIImage(systemName: "exclamationmark.triangle")
            placeholderIcon.tintColor = .systemOrange
            placeholderSpinner.stopAnimating()
            placeholderSpinner.isHidden = true
        }
        placeholderTitle.text = title
        placeholderMessage.text = message
    }

    private func hidePlaceholder() {
        placeholderView.isHidden = true
        collectionView.isHidden = false
    }

    // MARK: - Kill Timer

    private func startKillTimer() {
        killIndex = 0
        scheduleNextKill()
    }

    private func scheduleNextKill() {
        guard killIndex < Self.killIntervals.count else { return }
        killTimer?.invalidate()
        killTimer = Timer.scheduledTimer(
            withTimeInterval: Self.killIntervals[killIndex],
            repeats: false
        ) { [weak self] _ in self?.executeKill() }
    }

    private func executeKill() {
        guard case .playing(let quiz) = phase else { return }

        let targets = quiz.crewmates.filter {
            !killedCrewmates.contains($0.word) && !ejectedWords.contains($0.word) && selectedWord != $0.word
        }
        guard let victim = targets.randomElement() else { return }

        killedCrewmates.insert(victim.word)
        reconfigureCell(for: victim.word)
        animateKill(word: victim.word)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        let tierIndex = min(killIndex, SanityEffects.tiers.count - 1)
        sanRenderer.apply(tier: SanityEffects.tiers[tierIndex])
        killIndex += 1

        // Kills can only trigger defeat (never victory). The shared helper
        // handles both allDead and notEnough parity cases.
        if let condition = checkEndCondition(quiz) {
            endGame(quiz, condition: condition)
        } else {
            scheduleNextKill()
        }
    }

    // MARK: - End Condition Check (shared)

    /// Single source of truth for "is the game over yet?" — called after
    /// every mutation to alive counts (kills, ejects). Returns nil to keep
    /// playing. Handles the Among Us classic parity rule: imposters win as
    /// soon as they match or outnumber crewmates.
    private func checkEndCondition(_ quiz: MorphologyQuiz) -> EndCondition? {
        let aliveImposters = quiz.imposters.filter { !ejectedWords.contains($0.word) }
        let aliveCrewmates = quiz.crewmates.filter {
            !killedCrewmates.contains($0.word) && !ejectedWords.contains($0.word)
        }

        // Priority 1: Victory — all imposters ejected, ≥1 crewmate alive.
        // Victory takes precedence over any defeat condition.
        if aliveImposters.isEmpty && !aliveCrewmates.isEmpty {
            return .victory
        }
        // Priority 2: All crewmates gone — classic total defeat.
        if aliveCrewmates.isEmpty && !aliveImposters.isEmpty {
            return .defeatCrewEliminated
        }
        // Priority 3: Parity — imposters match or outnumber crewmates.
        // This is the Among Us "not enough crewmates left alive" lose state.
        if !aliveImposters.isEmpty, aliveCrewmates.count <= aliveImposters.count {
            return .defeatNotEnough
        }
        return nil
    }

    private func animateKill(word: String) {
        guard let ip = dataSource.indexPath(for: .candidate(word)),
              let cell = collectionView.cellForItem(at: ip) else { return }
        UIView.animate(withDuration: 0.08, animations: {
            cell.transform = CGAffineTransform(scaleX: 1.08, y: 1.08).rotated(by: 0.03)
        }) { _ in
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.5,
                           initialSpringVelocity: 0, options: []) {
                cell.transform = CGAffineTransform(rotationAngle: 0.02)
            }
        }
    }

    private func stopAllTimers() {
        killTimer?.invalidate()
        killTimer = nil
    }

    // MARK: - Eject (single-select)

    private func performEject(_ word: String, quiz: MorphologyQuiz) {
        selectedWord = nil
        ejectedWords.insert(word)

        let candidate = quiz.allCandidates.first(where: { $0.word == word })
        let wasImposter = candidate?.isImposter ?? false
        let crewColor = candidate?.crewColor ?? .gray

        // Remember where the card was on screen so the floater can spawn
        // near that location (smooth transition from grid to space).
        var spawnRect: CGRect? = nil
        if let ip = dataSource.indexPath(for: .candidate(word)),
           let cell = collectionView.cellForItem(at: ip) {
            // Convert cell frame to spaceFloater's coordinate space
            spawnRect = collectionView.convert(cell.frame, to: spaceFloater)
            // Animate the card flying off (the floater appears during this)
            UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseIn) {
                cell.contentView.transform = CGAffineTransform(translationX: 500, y: -80).rotated(by: 0.4)
                cell.contentView.alpha = 0
            }
        }

        // Spawn the space floater immediately — it drifts behind the grid
        // while the cell's fly-off animation plays on top.
        spaceFloater.addFloater(word: word, crewColor: crewColor, fromRect: spawnRect)

        // After fly-off: remove from snapshot + show result overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            var snapshot = self.dataSource.snapshot()
            let item = Item.candidate(word)
            if snapshot.itemIdentifiers.contains(item) {
                snapshot.deleteItems([item])
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
            self.updateCTA()
            self.showEjectResult(word: word, wasImposter: wasImposter)
        }
    }

    // MARK: - Endgame

    private func endGame(_ quiz: MorphologyQuiz, condition: EndCondition) {
        stopAllTimers()

        let title: String
        let message: String
        switch condition {
        case .victory:
            title = L10n.AICoach.AmongWurds.victoryTitle
            message = L10n.AICoach.AmongWurds.victoryMessage
        case .defeatCrewEliminated:
            title = L10n.AICoach.AmongWurds.defeatTitle
            message = L10n.AICoach.AmongWurds.defeatReasonAllDead
        case .defeatNotEnough:
            title = L10n.AICoach.AmongWurds.defeatTitle
            message = L10n.AICoach.AmongWurds.defeatReasonNotEnough
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: L10n.AICoach.AmongWurds.verifyIdentities, style: .default
        ) { [weak self] _ in self?.showReveal(quiz, condition: condition) })
        present(alert, animated: true)
    }

    private func showReveal(_ quiz: MorphologyQuiz, condition: EndCondition) {
        phase = .revealing(quiz)
        sanRenderer.reset()
        spaceFloater.clear()  // debris returns to grid with identities shown

        updateRevealBanner(condition: condition)

        dataSource.apply(.init(), animatingDifferences: false)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        snapshot.appendItems(quiz.allCandidates.map { .candidate($0.word) }, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)
        updateCTA()
    }

    /// Replace "There are N imposters among us" with the endgame banner:
    /// - Victory: single-line "Victory!" in teal.
    /// - Defeat: two lines — red "Defeat" over white reason text.
    private func updateRevealBanner(condition: EndCondition) {
        imposterBanner.isHidden = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        switch condition {
        case .victory:
            imposterBanner.attributedText = NSAttributedString(
                string: L10n.AICoach.AmongWurds.victoryBanner,
                attributes: [
                    .foregroundColor: UIColor.systemTeal,
                    .font: UIFont.systemFont(ofSize: 18, weight: .heavy),
                    .paragraphStyle: paragraph,
                ]
            )

        case .defeatCrewEliminated, .defeatNotEnough:
            let reason: String = condition == .defeatCrewEliminated
                ? L10n.AICoach.AmongWurds.defeatReasonAllDead
                : L10n.AICoach.AmongWurds.defeatReasonNotEnough
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(
                string: L10n.AICoach.AmongWurds.defeatBannerTitle + "\n",
                attributes: [
                    .foregroundColor: UIColor.systemRed,
                    .font: UIFont.systemFont(ofSize: 18, weight: .heavy),
                    .paragraphStyle: paragraph,
                ]
            ))
            text.append(NSAttributedString(
                string: reason,
                attributes: [
                    .foregroundColor: UIColor.white,
                    .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                    .paragraphStyle: paragraph,
                ]
            ))
            imposterBanner.attributedText = text
        }
    }

    // MARK: - State Transitions

    /// Show skeleton loading UI: dim quiz word card + skeleton grid.
    /// Called before the engine starts generating.
    private func showLoadingState() {
        phase = .loading
        skeletonCount = 0
        skeletonLitCount = 0
        skeletonColors.removeAll()

        hidePlaceholder()
        collectionView.isHidden = false

        // Show quiz word card in dim loading style (word is known from queue)
        if queueCursor < queueWords.count {
            headerContainer.isHidden = false
            quizWordLabel.text = queueWords[queueCursor].word
            quizWordCard.backgroundColor = UIColor(white: 0.12, alpha: 1)
            quizWordCard.layer.borderWidth = 0
            rootInfoLabel.text = L10n.AICoach.AmongWurds.generatingTitle
            imposterBanner.isHidden = true
        }

        // Start with empty grid — skeletons appear via .began event
        dataSource.apply(.init(), animatingDifferences: false)
        updateCTA()
    }

    /// Show skeleton cells — called by engine's `.began(totalTarget:)` event.
    private func showSkeletonGrid(count: Int) {
        skeletonCount = count
        skeletonLitCount = 0
        skeletonColors.removeAll()

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        snapshot.appendItems((0..<count).map { .skeleton($0) }, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    /// Light up the next skeleton cell — called by engine's `.verified` event.
    private func lightUpSkeleton(count: Int, colorIndex: Int) {
        guard count > 0, count <= skeletonCount else { return }
        let idx = count - 1  // 0-based
        skeletonColors[idx] = colorIndex
        skeletonLitCount = count

        // Reconfigure that skeleton cell to show its crew color
        var snapshot = dataSource.snapshot()
        let item = Item.skeleton(idx)
        guard snapshot.itemIdentifiers.contains(item) else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Transition from skeleton grid to live game — seamless reveal.
    private func showQuiz(_ quiz: MorphologyQuiz) {
        currentQuiz = quiz
        selectedWord = nil
        ejectedWords.removeAll()
        killedCrewmates.removeAll()
        killIndex = 0
        phase = .playing(quiz)

        updateHeader(quiz)
        updateTitleProgress()
        hidePlaceholder()
        sanRenderer.reset()
        spaceFloater.clear()  // new quiz → no ejected cards yet

        // Replace skeleton items with real candidates
        dataSource.apply(.init(), animatingDifferences: false)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        snapshot.appendItems(quiz.allCandidates.map { .candidate($0.word) }, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)

        updateCTA()
        startKillTimer()
    }

    private func showError(_ message: String) {
        phase = .failed(message)
        showPlaceholder(loading: false, title: L10n.AICoach.AmongWurds.errorTitle, message: message)
        updateCTA()
    }

    private func showQueueCompleted() {
        phase = .completed
        headerContainer.isHidden = true
        stopAllTimers()
        sanRenderer.reset()
        showPlaceholder(loading: false,
                        title: L10n.AICoach.AmongWurds.completedTitle,
                        message: L10n.AICoach.AmongWurds.completedMessage)
        placeholderIcon.image = UIImage(systemName: "party.popper.fill")
        placeholderIcon.tintColor = .systemYellow
        updateCTA()
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
                showPlaceholder(loading: false,
                                title: L10n.AICoach.AmongWurds.noBookmarksTitle,
                                message: L10n.AICoach.AmongWurds.noBookmarksMessage)
                placeholderIcon.image = UIImage(systemName: "info.bubble")
                placeholderIcon.tintColor = .tertiaryLabel
                updateCTA()
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

    /// Stricter filter — only words likely to produce a good morphology quiz.
    /// Requires Latin/Greek morphological indicators (prefix OR suffix) so
    /// the on-device model has a fighting chance at etymological analysis.
    /// Rejects Germanic monosyllables ("boggy"), loanwords ("quetch"),
    /// and technical terms ("sebaceous") that lack productive root families.
    nonisolated private static func suitableForMorphologyQuiz(_ word: String) -> Bool {
        let count = word.count
        guard count >= 5, count <= 15 else { return false }
        guard !word.contains(" "), !word.contains("-") else { return false }
        for ch in word {
            guard ch.isASCII, ch.isLetter else { return false }
        }

        // Must contain at least one recognizable Latin/Greek affix.
        // These words tend to have rich etymological families the AI can work with.
        let lc = word.lowercased()

        // Reject words with rare/scientific suffixes first — these have
        // tiny root families that the on-device model can't populate.
        let bannedSuffixes = ["aceous", "iform", "escent", "itis", "osis", "ology"]
        if bannedSuffixes.contains(where: { lc.hasSuffix($0) }) { return false }

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

        let hasPrefix = prefixes.contains { lc.hasPrefix($0) }
        let hasSuffix = suffixes.contains { lc.hasSuffix($0) }
        return hasPrefix || hasSuffix
    }

    private func loadQuizAtCursor() {
        Task {
            var skips = 0
            while queueCursor < queueWords.count, skips < Self.maxSkipsPerLoad {
                let entry = queueWords[queueCursor]
                do {
                    let quiz = try await MorphologyQuizEngine.buildMorphologyQuiz(
                        targetWord: entry.word, targetDictId: entry.dictId,
                        onEvent: { [weak self] event in
                            guard let self else { return }
                            switch event {
                            case .began(let totalTarget):
                                self.showSkeletonGrid(count: totalTarget)
                            case .verified(let count, let colorIndex):
                                self.lightUpSkeleton(count: count, colorIndex: colorIndex)
                            case .attemptFailed:
                                self.playMeltdownAnimation()
                            }
                        })
                    guard !quiz.allCandidates.isEmpty else {
                        queueCursor += 1; skips += 1; continue
                    }
                    showQuiz(quiz)
                    startPreloadingNext()
                    return
                } catch {
                    debugLog("⚠️ AmongWurds: '\(entry.word)' failed: \(error)")
                    queueCursor += 1; skips += 1
                }
            }
            showError(L10n.AICoach.AmongWurds.allRetriesFailed)
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
        stopAllTimers()
        selectedWord = nil
        ejectedWords.removeAll()
        killedCrewmates.removeAll()
        currentQuiz = nil
        phase = .loading
        headerContainer.isHidden = true
        sanRenderer.reset()
        spaceFloater.clear()

        if let ready = preloadedQuiz {
            preloadedQuiz = nil; preloadTask = nil
            showQuiz(ready); startPreloadingNext()
        } else if let task = preloadTask {
            showLoadingState()
            Task {
                do {
                    let quiz = try await task.value
                    preloadedQuiz = nil; preloadTask = nil
                    showQuiz(quiz); startPreloadingNext()
                } catch {
                    preloadTask = nil; queueCursor += 1
                    if queueCursor < queueWords.count { loadQuizAtCursor() }
                    else { showQueueCompleted() }
                }
            }
        } else {
            queueCursor += 1
            if queueCursor < queueWords.count { showLoadingState(); loadQuizAtCursor() }
            else { showQueueCompleted() }
        }
    }

    // MARK: - Helpers

    private func reconfigureCell(for word: String) {
        var snapshot = dataSource.snapshot()
        let item = Item.candidate(word)
        guard snapshot.itemIdentifiers.contains(item) else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    nonisolated private static func looksEnglish(_ word: String) -> Bool {
        var hasAscii = false
        for scalar in word.unicodeScalars {
            let v = scalar.value
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { hasAscii = true; continue }
            if (0x3040...0x30FF).contains(v) || (0x3400...0x4DBF).contains(v) ||
               (0x4E00...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) ||
               (0x0600...0x06FF).contains(v) { return false }
        }
        return hasAscii
    }
}

// MARK: - UICollectionViewDelegate

@available(iOS 26, *)
extension AmongWurdsViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .skeleton:
            break  // not interactive during loading
        case .candidate(let word):
            switch phase {
            case .playing:
                guard !killedCrewmates.contains(word), !ejectedWords.contains(word) else { return }
                toggleSelection(word)
            case .revealing:
                pushArticle(for: word)
            default:
                break
            }
        }
    }

    private func toggleSelection(_ word: String) {
        let previousWord = selectedWord

        if selectedWord == word {
            // Deselect
            selectedWord = nil
        } else {
            // Select new (auto-deselects previous)
            selectedWord = word
        }

        // Reconfigure changed cells
        if let prev = previousWord { reconfigureCell(for: prev) }
        if selectedWord != nil { reconfigureCell(for: word) }

        updateCTA()
        UIImpactFeedbackGenerator(style: selectedWord != nil ? .medium : .light).impactOccurred()
    }

    fileprivate func pushArticle(for word: String) {
        guard let quiz = currentQuiz,
              let dict = DictionaryService.shared.dict(id: quiz.targetDictId) else { return }
        var entry = dict.lookup(word)
        if entry == nil {
            for lemma in EnglishInflectionRules.resolve(word) {
                if let e = dict.lookup(lemma) { entry = e; break }
            }
        }
        guard let entry else { return }
        // The article is titled with the key it is of: a base form, or the
        // key the lookup's fallbacks matched.
        let resolvedWord = entry.key

        let html = ArticleHTMLRenderer.renderArticle(
            html: entry.article.html, dictId: quiz.targetDictId, traitCollection: traitCollection)
        let dictName = DictMetadataService.shared.find(dictId: quiz.targetDictId)?.displayName
            ?? dict.displayTitle

        let articleVC = UIViewController()
        articleVC.view.backgroundColor = .systemBackground
        articleVC.title = "\"\(resolvedWord)\""

        let pageView = ArticlePageView(configuration: .init(
            features: [.bookmark, .lookupCount, .findInPage, .enhanceDarkMode],
            webViewConfiguration: WKWebViewConfiguration()))
        pageView.configure(
            word: resolvedWord, dictName: dictName, dictId: quiz.targetDictId,
            isBookmarked: BookmarkService.shared.isBookmarked(word: resolvedWord, dictId: quiz.targetDictId))
        pageView.loadHTMLContent(html)
        pageView.onBookmarkTapped = { [dictId = quiz.targetDictId] _ in
            let s = BookmarkService.shared.toggleBookmark(word: resolvedWord, dictId: dictId)
            pageView.configure(word: resolvedWord, dictName: dictName, dictId: dictId, isBookmarked: s)
        }

        pageView.translatesAutoresizingMaskIntoConstraints = false
        articleVC.view.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: articleVC.view.safeAreaLayoutGuide.topAnchor),
            pageView.leadingAnchor.constraint(equalTo: articleVC.view.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: articleVC.view.trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: articleVC.view.bottomAnchor),
        ])
        navigationController?.pushViewController(articleVC, animated: true)
    }
}
