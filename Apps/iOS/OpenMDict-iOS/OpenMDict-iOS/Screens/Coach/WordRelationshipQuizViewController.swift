//
//  WordRelationshipQuizViewController.swift
//  OpenMDict-iOS
//
//  M14 MVP: Word relationship classification quiz.
//  Quiz word pinned at top, CTA button pinned at bottom,
//  candidates scroll in the middle collection view.
//

import UIKit
import WebKit
import OpenMDictKit

#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26, *)
final class WordRelationshipQuizViewController: UIViewController {

    // MARK: - State

    private enum Phase {
        case loading
        case answering(WordRelationshipQuiz)
        case graded(WordRelationshipQuiz, [GradedCandidate])
        case failed(String)
        case completed   // all quiz words exhausted
    }

    private static let menuOverlayTag = 8888

    private var phase: Phase = .loading
    private var userAnswers: [String: UserAnswer] = [:]
    private var quizDictId: String = ""

    // MARK: - Quiz Queue (preload pipeline)

    private var queueWords: [(word: String, dictId: String)] = []
    private var queueCursor = 0
    private var preloadedQuiz: WordRelationshipQuiz?
    private var preloadTask: Task<WordRelationshipQuiz, Error>?
    private var usedNoiseWords = Set<String>()

    // MARK: - Collection View types

    private nonisolated enum Section: Hashable, Sendable {
        case candidate(String)
    }

    private nonisolated enum Item: Hashable, Sendable {
        case candidate(String)
    }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    // Placeholder (loading / error) — ContentUnavailableView-style
    private let placeholderView = UIView()
    private let placeholderIcon = UIImageView()
    private let placeholderSpinner = UIActivityIndicatorView(style: .medium)
    private let placeholderTitle = UILabel()
    private let placeholderMessage = UILabel()

    // Pinned top: quiz word card
    private let navTitleLabel = UILabel()
    private let quizWordContainer = UIView()
    private let quizWordCard = UIView()
    private let quizWordIcon = UIImageView()
    private let quizWordLabel = UILabel()
    private let quizWordSubtitle = UILabel()
    private let quizWordInstruction = UILabel()
    private let quizWordDisclosure = UIImageView()
    private let quizWordSeparator = UIView()

    // Pinned bottom: CTA
    private let ctaContainer = UIView()
    private let ctaButton = UIButton(type: .system)
    private let ctaSeparator = UIView()

    /// Current quiz, kept for grading + article push.
    private var currentQuiz: WordRelationshipQuiz?
    private var gradedResults: [GradedCandidate]?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemGroupedBackground
        setupTitleView()
        setupBackButton()
        setupQuizWordView()
        setupQuizWordTap()
        setupCTAView()
        setupCollectionView()
        setupDataSource()
        setupPlaceholder()

        quizWordContainer.isHidden = true
        ctaContainer.isHidden = true

        buildQueueAndStart()
    }

    // MARK: - Title View

    private func setupTitleView() {
        navTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        navigationItem.titleView = navTitleLabel
        updateTitleProgress()
    }

    private func updateTitleProgress() {
        let attachment = NSTextAttachment()
        attachment.image = UIImage(systemName: "plus.forwardslash.minus")?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
        let attrText = NSMutableAttributedString(attachment: attachment)

        let total = queueWords.count
        if total > 0 {
            let current = min(queueCursor + 1, total)
            attrText.append(NSAttributedString(
                string: " " + L10n.AICoach.Quiz.titleShort + "  \(current)/\(total)"))
        } else {
            attrText.append(NSAttributedString(string: " " + L10n.AICoach.Quiz.titleShort))
        }
        navTitleLabel.attributedText = attrText
        navTitleLabel.sizeToFit()
    }

    // MARK: - Back button + dismiss guard

    private func setupBackButton() {
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain,
            target: self, action: #selector(backTapped)
        )
    }

    @objc private func backTapped() {
        switch phase {
        case .graded, .failed, .loading, .completed:
            navigationController?.popViewController(animated: true)
        case .answering:
            let alert = UIAlertController(
                title: L10n.AICoach.leaveTitle,
                message: L10n.AICoach.leaveMessage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.AICoach.leaveAction, style: .destructive) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            })
            alert.addAction(UIAlertAction(title: L10n.AICoach.stayAction, style: .cancel))
            present(alert, animated: true)
        }
    }

    // MARK: - Quiz Word View (pinned top)

    private func setupQuizWordView() {
        quizWordContainer.translatesAutoresizingMaskIntoConstraints = false
        quizWordContainer.backgroundColor = .systemGroupedBackground
        view.addSubview(quizWordContainer)

        // White card with insetGrouped-style rounding
        quizWordCard.translatesAutoresizingMaskIntoConstraints = false
        quizWordCard.backgroundColor = .secondarySystemGroupedBackground
        quizWordCard.layer.cornerRadius = 10
        quizWordCard.clipsToBounds = true
        quizWordContainer.addSubview(quizWordCard)

        // Leading icon
        quizWordIcon.image = UIImage(systemName: "append.page")
        quizWordIcon.tintColor = .secondaryLabel
        quizWordIcon.translatesAutoresizingMaskIntoConstraints = false
        quizWordIcon.setContentHuggingPriority(.required, for: .horizontal)
        quizWordCard.addSubview(quizWordIcon)

        // Text stack inside card: word + subtitle
        quizWordLabel.font = .systemFont(ofSize: 28, weight: .bold)
        quizWordSubtitle.font = .preferredFont(forTextStyle: .footnote)
        quizWordSubtitle.textColor = .tertiaryLabel

        let textStack = UIStackView(arrangedSubviews: [quizWordLabel, quizWordSubtitle])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        quizWordCard.addSubview(textStack)

        // Trailing disclosure
        quizWordDisclosure.image = UIImage(systemName: "chevron.right")
        quizWordDisclosure.tintColor = .tertiaryLabel
        quizWordDisclosure.translatesAutoresizingMaskIntoConstraints = false
        quizWordDisclosure.setContentHuggingPriority(.required, for: .horizontal)
        quizWordDisclosure.isHidden = true  // shown after grading
        quizWordCard.addSubview(quizWordDisclosure)

        // Message label below card (instruction → result hint)
        quizWordInstruction.font = .preferredFont(forTextStyle: .subheadline)
        quizWordInstruction.textColor = .secondaryLabel
        quizWordInstruction.numberOfLines = 0
        quizWordInstruction.translatesAutoresizingMaskIntoConstraints = false
        quizWordContainer.addSubview(quizWordInstruction)

        // Bottom separator
        quizWordSeparator.backgroundColor = .separator
        quizWordSeparator.translatesAutoresizingMaskIntoConstraints = false
        quizWordContainer.addSubview(quizWordSeparator)

        NSLayoutConstraint.activate([
            quizWordContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            quizWordContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            quizWordContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            quizWordCard.topAnchor.constraint(equalTo: quizWordContainer.topAnchor, constant: 10),
            quizWordCard.leadingAnchor.constraint(equalTo: quizWordContainer.leadingAnchor, constant: 20),
            quizWordCard.trailingAnchor.constraint(equalTo: quizWordContainer.trailingAnchor, constant: -20),

            quizWordIcon.leadingAnchor.constraint(equalTo: quizWordCard.leadingAnchor, constant: 16),
            quizWordIcon.centerYAnchor.constraint(equalTo: quizWordCard.centerYAnchor),
            quizWordIcon.widthAnchor.constraint(equalToConstant: 24),
            quizWordIcon.heightAnchor.constraint(equalToConstant: 24),

            textStack.topAnchor.constraint(equalTo: quizWordCard.topAnchor, constant: 12),
            textStack.leadingAnchor.constraint(equalTo: quizWordIcon.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: quizWordDisclosure.leadingAnchor, constant: -8),
            textStack.bottomAnchor.constraint(equalTo: quizWordCard.bottomAnchor, constant: -12),

            quizWordDisclosure.trailingAnchor.constraint(equalTo: quizWordCard.trailingAnchor, constant: -16),
            quizWordDisclosure.centerYAnchor.constraint(equalTo: quizWordCard.centerYAnchor),

            quizWordInstruction.topAnchor.constraint(equalTo: quizWordCard.bottomAnchor, constant: 8),
            quizWordInstruction.leadingAnchor.constraint(equalTo: quizWordContainer.leadingAnchor, constant: 24),
            quizWordInstruction.trailingAnchor.constraint(equalTo: quizWordContainer.trailingAnchor, constant: -24),
            quizWordInstruction.bottomAnchor.constraint(equalTo: quizWordContainer.bottomAnchor, constant: -8),

            quizWordSeparator.leadingAnchor.constraint(equalTo: quizWordContainer.leadingAnchor),
            quizWordSeparator.trailingAnchor.constraint(equalTo: quizWordContainer.trailingAnchor),
            quizWordSeparator.bottomAnchor.constraint(equalTo: quizWordContainer.bottomAnchor),
            quizWordSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
    }

    private func updateQuizWordView(_ quiz: WordRelationshipQuiz) {
        quizWordLabel.text = quiz.targetWord
        quizWordSubtitle.text = "from \(quiz.targetDictName)"
        quizWordInstruction.text = L10n.AICoach.Quiz.classifyInstruction(quiz.targetWord)
        quizWordDisclosure.isHidden = true
        quizWordContainer.isHidden = false
    }

    // MARK: - CTA View (pinned bottom)

    private func setupCTAView() {
        ctaContainer.translatesAutoresizingMaskIntoConstraints = false
        ctaContainer.backgroundColor = .systemGroupedBackground
        view.addSubview(ctaContainer)

        ctaButton.translatesAutoresizingMaskIntoConstraints = false
        ctaButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        ctaButton.setTitleColor(.white, for: .normal)
        ctaButton.setTitleColor(.white.withAlphaComponent(0.5), for: .disabled)
        ctaButton.layer.cornerRadius = 12
        ctaButton.clipsToBounds = true
        ctaButton.addTarget(self, action: #selector(ctaTapped), for: .touchUpInside)
        ctaContainer.addSubview(ctaButton)

        ctaSeparator.backgroundColor = .separator
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

        case .answering(let quiz):
            ctaContainer.isHidden = false
            let remaining = quiz.candidates.count - userAnswers.count
            if remaining > 0 {
                ctaButton.setTitle(L10n.AICoach.Quiz.questionsToGo(remaining), for: .normal)
                ctaButton.isEnabled = false
                ctaButton.backgroundColor = .systemGray3
            } else {
                ctaButton.setTitle(L10n.AICoach.Quiz.checkAnswers, for: .normal)
                ctaButton.isEnabled = true
                ctaButton.backgroundColor = .systemBlue
            }

        case .graded:
            ctaContainer.isHidden = false
            ctaButton.setTitle(L10n.AICoach.Quiz.next, for: .normal)
            ctaButton.isEnabled = true
            ctaButton.backgroundColor = .systemBlue

        case .failed:
            ctaContainer.isHidden = false
            ctaButton.setTitle(L10n.AICoach.Quiz.tryAgain, for: .normal)
            ctaButton.isEnabled = true
            ctaButton.backgroundColor = .systemBlue

        case .completed:
            ctaContainer.isHidden = true
        }
    }

    @objc private func ctaTapped() {
        switch phase {
        case .answering(let quiz):
            let results = QuizEngine.grade(quiz: quiz, userAnswers: userAnswers)
            showResults(quiz, results)
        case .graded:
            resetAndStartNext()
        case .failed:
            // Retry from current cursor position (don't rebuild queue)
            phase = .loading
            showLoadingState()
            loadQuizAtCursor()
        default:
            break
        }
    }

    // MARK: - Collection View Setup

    private func setupCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        config.footerMode = .none
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: quizWordContainer.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: ctaContainer.topAnchor),
        ])
    }

    // MARK: - Data Source

    private func setupDataSource() {
        let candidateReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, word in
            guard let self else { return }
            self.configureCandidateCell(cell, word: word)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .candidate(let word):
                return collectionView.dequeueConfiguredReusableCell(using: candidateReg, for: indexPath, item: word)
            }
        }
    }

    // MARK: - Placeholder (loading / error)

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

        placeholderIcon.image = UIImage(systemName: "cup.and.saucer.fill")
        placeholderIcon.tintColor = .tertiaryLabel
        placeholderIcon.preferredSymbolConfiguration = .init(pointSize: 48)
        stack.addArrangedSubview(placeholderIcon)

        // Spinner + title row
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
            placeholderView.topAnchor.constraint(equalTo: quizWordContainer.bottomAnchor),
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
            placeholderIcon.image = UIImage(systemName: "cup.and.saucer.fill")
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

    // MARK: - Candidate cell configuration

    private func configureCandidateCell(_ cell: UICollectionViewListCell, word: String) {
        var content = UIListContentConfiguration.sidebarCell()
        content.text = word
        content.textProperties.font = .systemFont(ofSize: 17, weight: .semibold)

        // Leading icon (diamond = status)
        let answered = userAnswers[word]
        let graded = gradedResults?.first(where: { $0.candidate.word == word })

        if let graded {
            content.image = UIImage(systemName: graded.isCorrect ? "checkmark.diamond.fill" : "xmark.diamond.fill")
            content.imageProperties.tintColor = graded.isCorrect ? .systemGreen : .systemRed
            content.secondaryText = gradedSubtitle(correct: graded.isCorrect,
                                                   relationship: graded.candidate.correctRelationship)
            content.secondaryTextProperties.color = graded.isCorrect ? .systemGreen : .systemRed
        } else if let answered {
            let (_, answerTint) = answerIcon(answered)
            content.image = UIImage(systemName: "inset.filled.diamond")
            content.imageProperties.tintColor = answerTint
            let (_, tint) = answerIcon(answered)
            content.secondaryText = answerDisplayName(answered)
            content.secondaryTextProperties.color = tint
        } else {
            content.image = UIImage(systemName: "questionmark.diamond")
            content.imageProperties.tintColor = .tertiaryLabel
            content.secondaryText = L10n.AICoach.Quiz.selectAnswer
            content.secondaryTextProperties.color = .quaternaryLabel
        }

        cell.contentConfiguration = content

        // Background tint
        if let graded {
            var bg = UIBackgroundConfiguration.listGroupedCell()
            bg.backgroundColor = graded.isCorrect
                ? UIColor.systemGreen.withAlphaComponent(0.08)
                : UIColor.systemRed.withAlphaComponent(0.08)
            cell.backgroundConfiguration = bg
        } else {
            cell.backgroundConfiguration = .listGroupedCell()
        }

        // Trailing accessories
        var accessories: [UICellAccessory] = []
        let (iconName, tint) = answerIcon(answered)

        let icon = UIImageView(image: UIImage(systemName: iconName))
        icon.tintColor = tint
        accessories.append(.customView(configuration: .init(
            customView: icon,
            placement: .trailing(displayed: .always),
            reservedLayoutWidth: .actual
        )))

        cell.viewWithTag(Self.menuOverlayTag)?.removeFromSuperview()

        if graded != nil {
            accessories.append(.disclosureIndicator())
        } else {
            let overlay = CellWideMenuButton(type: .system)
            overlay.tag = Self.menuOverlayTag
            overlay.showsMenuAsPrimaryAction = true
            overlay.menu = makeMenu(for: word)
            overlay.backgroundColor = .clear
            overlay.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                overlay.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                overlay.widthAnchor.constraint(equalToConstant: 44),
                overlay.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        cell.accessories = accessories
    }

    private func answerIcon(_ answer: UserAnswer?) -> (name: String, tint: UIColor) {
        guard let answer else {
            return ("questionmark.circle", .tertiaryLabel)
        }
        switch answer {
        case .synonym:    return ("plus.circle", .systemIndigo)
        case .unrelated:  return ("asterisk.circle", .secondaryLabel)
        case .antonym:    return ("minus.circle", .systemOrange)
        case .notAnswered: return ("questionmark.circle", .tertiaryLabel)
        }
    }

    private func setAnswer(word: String, answer: UserAnswer) {
        userAnswers[word] = answer
        guard let quiz = currentQuiz else { return }
        var snapshot = dataSource.snapshot()
        let items = quiz.candidates
            .map { Item.candidate($0.word) }
            .filter { snapshot.itemIdentifiers.contains($0) }
        snapshot.reconfigureItems(items.filter {
            if case .candidate(let w) = $0 { return w == word }
            return false
        })
        dataSource.apply(snapshot, animatingDifferences: false)
        updateCTA()
    }

    // MARK: - Snapshots

    private func showLoadingState(attempt: Int = 0, word: String? = nil) {
        let title: String
        let msg: String
        if attempt == 0 {
            title = L10n.AICoach.Quiz.generatingTitle
            msg = L10n.AICoach.Quiz.generatingMessage
        } else if let word {
            title = L10n.AICoach.Quiz.retryingTitle
            msg = L10n.AICoach.Quiz.retrying(attempt, word)
        } else {
            title = L10n.AICoach.Quiz.retryingTitle
            msg = L10n.AICoach.Quiz.retryingGeneric(attempt)
        }
        showPlaceholder(loading: true, title: title, message: msg)
        updateCTA()
    }

    private func showQuiz(_ quiz: WordRelationshipQuiz) {
        currentQuiz = quiz
        phase = .answering(quiz)
        updateQuizWordView(quiz)
        updateTitleProgress()
        hidePlaceholder()

        // Track noise words so future quizzes don't repeat them
        for c in quiz.candidates where c.correctRelationship == .noise {
            usedNoiseWords.insert(c.word.lowercased())
        }

        // Flush stale cells from previous quiz — without this,
        // DiffableDataSource reuses cells for same-named candidates
        // (e.g. "deeds" appearing in consecutive quizzes) and their
        // old graded visual state bleeds through.
        dataSource.apply(.init(), animatingDifferences: false)

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        for candidate in quiz.candidates {
            let section = Section.candidate(candidate.word)
            snapshot.appendSections([section])
            snapshot.appendItems([.candidate(candidate.word)], toSection: section)
        }

        dataSource.apply(snapshot, animatingDifferences: true)
        updateCTA()
    }

    private func showResults(_ quiz: WordRelationshipQuiz, _ results: [GradedCandidate]) {
        gradedResults = results
        phase = .graded(quiz, results)

        let correct = results.filter(\.isCorrect).count
        let total = results.count

        var snapshot = dataSource.snapshot()
        let candidateItems = quiz.candidates.map { Item.candidate($0.word) }
        snapshot.reconfigureItems(candidateItems)
        dataSource.apply(snapshot, animatingDifferences: true)
        updateCTA()

        // Show disclosure on quiz word card + update message
        quizWordDisclosure.isHidden = false
        quizWordInstruction.text = L10n.AICoach.Quiz.viewDefinitions

        // Score alert with Duolingo-style encouragement
        let pct = total > 0 ? (correct * 100 / total) : 0
        let title = scoreTitle(percentage: pct)
        let message = L10n.AICoach.Quiz.scoreMessage(correct, total)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)

        debugLog("📝 Word Quiz: '\(quiz.targetWord)' → \(correct)/\(total)")
        for r in results {
            debugLog("   \(r.isCorrect ? "✅" : "❌") \(r.candidate.word) (\(r.candidate.correctRelationship.rawValue))")
        }
    }

    private func showError(_ message: String) {
        phase = .failed(message)
        showPlaceholder(loading: false, title: L10n.AICoach.Quiz.errorTitle, message: message)
        updateCTA()
    }

    private func showQueueCompleted() {
        phase = .completed
        quizWordContainer.isHidden = true
        showPlaceholder(loading: false,
                        title: L10n.AICoach.Quiz.completedTitle,
                        message: L10n.AICoach.Quiz.completedMessage)
        // Override icon to celebration
        placeholderIcon.image = UIImage(systemName: "party.popper.fill")
        placeholderIcon.tintColor = .systemYellow
        updateCTA()
    }

    // MARK: - Quiz Queue Lifecycle

    private static let maxSkipsPerLoad = 3

    /// Build the shuffled word queue from bookmarks and start the first quiz.
    private func buildQueueAndStart() {
        let bookmarks = BookmarkService.shared.allBookmarks()
        let englishBookmarks = bookmarks.filter { looksEnglish($0.word) }

        guard !englishBookmarks.isEmpty else {
            phase = .completed
            showPlaceholder(loading: false,
                            title: L10n.AICoach.Quiz.noBookmarksTitle,
                            message: L10n.AICoach.Quiz.noBookmarksMessage)
            placeholderIcon.image = UIImage(systemName: "info.bubble")
            placeholderIcon.tintColor = .tertiaryLabel
            updateCTA()
            return
        }

        queueWords = englishBookmarks
            .map { ($0.word, $0.dictId) }
            .shuffled()
        queueCursor = 0
        preloadedQuiz = nil
        preloadTask?.cancel()
        preloadTask = nil

        updateTitleProgress()
        showLoadingState()
        loadQuizAtCursor()
    }

    /// Load the quiz for queueWords[cursor], with skip-on-failure.
    private func loadQuizAtCursor() {
        Task {
            var skips = 0
            while queueCursor < queueWords.count, skips < Self.maxSkipsPerLoad {
                let entry = queueWords[queueCursor]
                let otherWords = queueWords
                    .filter { $0.word.lowercased() != entry.word.lowercased() }
                    .map(\.word)

                if skips > 0 {
                    showLoadingState(attempt: skips, word: entry.word)
                }

                do {
                    let quiz = try await QuizEngine.buildWordRelationshipQuiz(
                        targetWord: entry.word,
                        targetDictId: entry.dictId,
                        otherBookmarkedWords: otherWords,
                        usedNoiseWords: usedNoiseWords
                    )
                    guard !quiz.candidates.isEmpty else {
                        debugLog("⚠️ QuizQueue: '\(entry.word)' yielded 0 candidates, skipping")
                        queueCursor += 1
                        skips += 1
                        continue
                    }
                    self.quizDictId = entry.dictId
                    showQuiz(quiz)
                    startPreloadingNext()
                    return
                } catch {
                    debugLog("⚠️ QuizQueue: '\(entry.word)' failed: \(error)")
                    queueCursor += 1
                    skips += 1
                }
            }
            showError(L10n.AICoach.Quiz.allRetriesFailed(""))
        }
    }

    /// Preload the NEXT quiz in the background while user answers the current one.
    private func startPreloadingNext() {
        let nextCursor = queueCursor + 1
        guard nextCursor < queueWords.count else {
            // No more words — clear stale task so resetAndStartNext
            // doesn't re-consume the old completed task.
            preloadTask = nil
            preloadedQuiz = nil
            return
        }

        preloadedQuiz = nil
        preloadTask = Task {
            var cursor = nextCursor
            var skips = 0
            while cursor < queueWords.count, skips < Self.maxSkipsPerLoad {
                let entry = queueWords[cursor]
                let otherWords = queueWords
                    .filter { $0.word.lowercased() != entry.word.lowercased() }
                    .map(\.word)

                do {
                    let quiz = try await QuizEngine.buildWordRelationshipQuiz(
                        targetWord: entry.word,
                        targetDictId: entry.dictId,
                        otherBookmarkedWords: otherWords,
                        usedNoiseWords: usedNoiseWords
                    )
                    if quiz.candidates.isEmpty {
                        cursor += 1; skips += 1; continue
                    }
                    // Update cursor + store preloaded result
                    await MainActor.run {
                        self.queueCursor = cursor
                        self.preloadedQuiz = quiz
                    }
                    return quiz
                } catch {
                    debugLog("⚠️ QuizQueue preload: '\(entry.word)' failed: \(error)")
                    cursor += 1; skips += 1
                }
            }
            throw QuizQueueError.exhausted
        }
    }

    private enum QuizQueueError: Error { case exhausted }

    /// User tapped "Next" — consume preloaded quiz or await it.
    private func resetAndStartNext() {
        userAnswers.removeAll()
        gradedResults = nil
        currentQuiz = nil
        phase = .loading
        quizWordContainer.isHidden = true

        if let ready = preloadedQuiz {
            // Instant — preload completed while user was answering
            preloadedQuiz = nil
            preloadTask = nil  // consumed — don't re-await the stale task
            quizDictId = queueWords[queueCursor].dictId
            showQuiz(ready)
            startPreloadingNext()
        } else if let task = preloadTask {
            // Preload still running — show loading, await result
            showLoadingState()
            Task {
                do {
                    let quiz = try await task.value
                    preloadedQuiz = nil
                    preloadTask = nil
                    quizDictId = queueWords[queueCursor].dictId
                    showQuiz(quiz)
                    startPreloadingNext()
                } catch {
                    preloadTask = nil
                    // Try advancing further in the queue
                    queueCursor += 1
                    if queueCursor < queueWords.count {
                        loadQuizAtCursor()
                    } else {
                        showQueueCompleted()
                    }
                }
            }
        } else {
            // No preload task (queue was short) — advance and load
            queueCursor += 1
            if queueCursor < queueWords.count {
                showLoadingState()
                loadQuizAtCursor()
            } else {
                showQueueCompleted()
            }
        }
    }

    // MARK: - Article push

    private func relationshipIcon(_ r: WordRelationship) -> (name: String, tint: UIColor) {
        switch r {
        case .synonym:         return ("plus.circle.fill", .systemIndigo)
        case .antonym:         return ("minus.circle.fill", .systemOrange)
        case .similarSpelling: return ("asterisk.circle.fill", .secondaryLabel)
        case .noise:           return ("asterisk.circle.fill", .secondaryLabel)
        }
    }

    private func pushArticle(for word: String, relationship: WordRelationship?,
                             isQuizWord: Bool = false) {
        guard let quiz = currentQuiz,
              let dict = DictionaryService.shared.dict(id: quizDictId) else { return }
        var resolvedWord = word
        var entry = dict.lookup(word)
        if entry == nil {
            for lemma in EnglishInflectionRules.resolve(word) {
                if let e = dict.lookup(lemma) { entry = e; resolvedWord = lemma; break }
            }
        }
        guard let entry else { return }

        let html = ArticleHTMLRenderer.renderArticle(
            html: entry.article.html,
            dictId: quizDictId,
            traitCollection: traitCollection
        )
        let dictName = DictMetadataService.shared.find(dictId: quizDictId)?.displayName
            ?? dict.displayTitle

        let articleVC = UIViewController()
        articleVC.view.backgroundColor = .systemBackground

        if let relationship {
            let (iconName, tint) = relationshipIcon(relationship)
            let label = relationshipLabel(relationship)
            let titleLabel = UILabel()
            titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            titleLabel.textColor = tint

            let attachment = NSTextAttachment()
            attachment.image = UIImage(systemName: iconName)?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
            let attrText = NSMutableAttributedString(attachment: attachment)
            attrText.append(NSAttributedString(string: " \(label) \"\(quiz.targetWord)\""))
            titleLabel.attributedText = attrText
            articleVC.navigationItem.titleView = titleLabel
        } else {
            articleVC.title = "\"\(resolvedWord)\""
        }

        let pageView = ArticlePageView(configuration: .init(
            features: [.bookmark, .lookupCount, .findInPage, .enhanceDarkMode],
            webViewConfiguration: WKWebViewConfiguration()
        ))
        pageView.configure(
            word: resolvedWord, dictName: dictName, dictId: quizDictId,
            isBookmarked: BookmarkService.shared.isBookmarked(word: resolvedWord, dictId: quizDictId)
        )
        pageView.loadHTMLContent(html)

        if isQuizWord {
            pageView.onBookmarkTapped = { _ in }
        } else {
            pageView.onBookmarkTapped = { [quizDictId] isCurrentlyBookmarked in
                let newState = BookmarkService.shared.toggleBookmark(
                    word: resolvedWord, dictId: quizDictId)
                pageView.configure(
                    word: resolvedWord, dictName: dictName, dictId: quizDictId,
                    isBookmarked: newState)
            }
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

    private func makeMenu(for word: String) -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.AICoach.Quiz.synonym,
                image: UIImage(systemName: "plus.circle")?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal)
            ) { [weak self] _ in
                self?.setAnswer(word: word, answer: .synonym)
            },
            UIAction(
                title: L10n.AICoach.Quiz.irrelevant,
                image: UIImage(systemName: "asterisk.circle")
            ) { [weak self] _ in
                self?.setAnswer(word: word, answer: .unrelated)
            },
            UIAction(
                title: L10n.AICoach.Quiz.antonym,
                image: UIImage(systemName: "minus.circle")?.withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
            ) { [weak self] _ in
                self?.setAnswer(word: word, answer: .antonym)
            },
        ])
    }

    // MARK: - Score feedback

    /// Duolingo-inspired playful title based on score percentage.
    private func scoreTitle(percentage: Int) -> String {
        switch percentage {
        case 100:     return "Perfect! 🎯"
        case 80...:   return "Awesome! 🌟"
        case 60...:   return "Nice work! 👏"
        case 40...:   return "Not bad! 💪"
        case 20...:   return "Keep going! 📚"
        default:      return "Tough one! 🧠"
        }
    }

    // MARK: - Helpers

    private func answerDisplayName(_ answer: UserAnswer?) -> String {
        guard let answer else { return "–" }
        switch answer {
        case .synonym:    return L10n.AICoach.Quiz.synonym
        case .antonym:    return L10n.AICoach.Quiz.antonym
        case .unrelated:  return L10n.AICoach.Quiz.irrelevant
        case .notAnswered: return "–"
        }
    }

    private func relationshipLabel(_ r: WordRelationship) -> String {
        switch r {
        case .synonym: return "Synonym of"
        case .antonym: return "Antonym of"
        case .similarSpelling: return "Similar to"
        case .noise: return "Unrelated to"
        }
    }

    private func relationshipArticle(_ r: WordRelationship) -> String {
        switch r {
        case .synonym: return L10n.AICoach.Quiz.aSynonym
        case .antonym: return L10n.AICoach.Quiz.anAntonym
        case .similarSpelling: return L10n.AICoach.Quiz.aSimilarWord
        case .noise: return L10n.AICoach.Quiz.unrelated
        }
    }

    private func gradedSubtitle(correct: Bool, relationship: WordRelationship) -> String {
        switch relationship {
        case .similarSpelling:
            return correct
                ? "Correct! It only looks similar."
                : "It only looks similar but is another word."
        case .noise:
            return correct
                ? "Correct! It's a random word."
                : "Actually, it's a totally random word."
        default:
            let article = relationshipArticle(relationship)
            return correct
                ? "Correct! It is \(article)."
                : "Actually, it is \(article)."
        }
    }

    private func looksEnglish(_ word: String) -> Bool {
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
extension WordRelationshipQuizViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .candidate(let word):
            guard gradedResults != nil else { return }
            if let result = gradedResults?.first(where: { $0.candidate.word == word }) {
                pushArticle(for: word, relationship: result.candidate.correctRelationship)
            }
        default:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch item {
        case .candidate: return true
        default: return false
        }
    }
}

// MARK: - Quiz Word Tap (graded → push article)

@available(iOS 26, *)
extension WordRelationshipQuizViewController: UIGestureRecognizerDelegate {

    private func setupQuizWordTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(quizWordTapped))
        quizWordContainer.addGestureRecognizer(tap)
    }

    @objc private func quizWordTapped() {
        guard case .graded = phase, let quiz = currentQuiz else { return }
        pushArticle(for: quiz.targetWord, relationship: nil, isQuizWord: true)
    }
}

// MARK: - CellWideMenuButton

@available(iOS 26, *)
private final class CellWideMenuButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let cell = superview else { return super.point(inside: point, with: event) }
        let pointInCell = convert(point, to: cell)
        return cell.bounds.contains(pointInCell)
    }
}
