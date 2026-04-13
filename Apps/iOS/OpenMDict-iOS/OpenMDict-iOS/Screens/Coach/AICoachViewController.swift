//
//  AICoachViewController.swift
//  OpenMDict-iOS
//
//  M14: AI Coach facade — lists available study modes.
//  Checks AI availability on every viewWillAppear and shows a triage
//  placeholder if the model isn't ready (device, toggle, download).
//

import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26, *)
final class AICoachViewController: UIViewController {

    // MARK: - Types

    private nonisolated enum Section: Hashable, Sendable {
        case localeWarning
        case main
    }

    private nonisolated enum ListItem: Hashable, Sendable {
        case localeWarning
        case mode(StudyMode)
    }

    private nonisolated enum StudyMode: Int, CaseIterable, Hashable, Sendable {
        case wordTinder
        case flashcard

        var symbolName: String {
            switch self {
            case .wordTinder: return "plus.forwardslash.minus"
            case .flashcard:        return "rectangle.on.rectangle"
            }
        }

        var title: String {
            switch self {
            case .wordTinder: return L10n.AICoach.wordTinder
            case .flashcard:        return L10n.AICoach.flashcard
            }
        }

        var description: String {
            switch self {
            case .wordTinder: return L10n.AICoach.wordTinderDesc
            case .flashcard:        return L10n.AICoach.flashcardDesc
            }
        }
    }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, ListItem>!

    // Triage placeholder (ContentUnavailableView style)
    private let triageView = UIView()
    private let triageIcon = UIImageView()
    private let triageTitle = UILabel()
    private let triageMessage = UILabel()
    private let triageButton = UIButton(type: .system)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.AICoach.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground

        if navigationController?.presentingViewController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(dismissSelf)
            )
            navigationController?.isModalInPresentation = true
        }

        setupCollectionView()
        setupDataSource()
        setupTriagePlaceholder()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateAvailabilityState()
    }

    // MARK: - Actions

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    // MARK: - Availability Check

    private func updateAvailabilityState() {
        guard AICoach.isGenerationReady else {
            showTriage()
            return
        }
        hideTriage()
        applySnapshot()
    }

    // MARK: - Triage Placeholder

    private func setupTriagePlaceholder() {
        triageView.translatesAutoresizingMaskIntoConstraints = false
        triageView.isHidden = true
        view.addSubview(triageView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        triageView.addSubview(stack)

        triageIcon.preferredSymbolConfiguration = .init(pointSize: 48)
        triageIcon.tintColor = .tertiaryLabel
        stack.addArrangedSubview(triageIcon)

        triageTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        triageTitle.textColor = .secondaryLabel
        triageTitle.textAlignment = .center
        triageTitle.numberOfLines = 0
        stack.addArrangedSubview(triageTitle)

        triageMessage.font = .systemFont(ofSize: 14)
        triageMessage.textColor = .tertiaryLabel
        triageMessage.textAlignment = .center
        triageMessage.numberOfLines = 0
        stack.addArrangedSubview(triageMessage)

        triageButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        triageButton.isHidden = true
        triageButton.addTarget(self, action: #selector(triageButtonTapped), for: .touchUpInside)
        stack.addArrangedSubview(triageButton)
        stack.setCustomSpacing(16, after: triageMessage)

        NSLayoutConstraint.activate([
            triageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            triageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            triageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            triageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: triageView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: triageView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: triageView.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: triageView.trailingAnchor, constant: -40),
        ])
    }

    private enum TriageAction {
        case none
        case openSettings
        case learnMore
    }

    private var triageAction: TriageAction = .none

    private func showTriage() {
        collectionView.isHidden = true
        triageView.isHidden = false

        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                triageIcon.image = UIImage(systemName: isPad
                    ? "ipad.gen2.landscape.slash" : "iphone.gen2.slash")
                triageTitle.text = L10n.AICoach.Triage.deviceTitle
                triageMessage.text = L10n.AICoach.Triage.deviceMessage
                triageButton.setTitle(L10n.AICoach.Triage.learnMore, for: .normal)
                triageButton.isHidden = false
                triageAction = .learnMore

            case .appleIntelligenceNotEnabled:
                triageIcon.image = UIImage(systemName: "apple.intelligence.badge.xmark")
                triageTitle.text = L10n.AICoach.Triage.notEnabledTitle
                triageMessage.text = L10n.AICoach.Triage.notEnabledMessage
                triageButton.setTitle(L10n.AICoach.openSettings, for: .normal)
                triageButton.isHidden = false
                triageAction = .openSettings

            case .modelNotReady:
                triageIcon.image = UIImage(systemName: "apple.intelligence.badge.xmark")
                triageTitle.text = L10n.AICoach.Triage.downloadingTitle
                triageMessage.text = L10n.AICoach.Triage.downloadingMessage
                triageButton.isHidden = true
                triageAction = .none

            @unknown default:
                triageIcon.image = UIImage(systemName: "questionmark.circle")
                triageTitle.text = L10n.AICoach.Triage.unknownTitle
                triageMessage.text = L10n.AICoach.Triage.unknownMessage
                triageButton.isHidden = true
                triageAction = .none
            }
        default:
            // Shouldn't reach here if isGenerationReady is false,
            // but handle defensively
            triageIcon.image = UIImage(systemName: "questionmark.circle")
            triageTitle.text = L10n.AICoach.Triage.unknownTitle
            triageMessage.text = L10n.AICoach.Triage.unknownMessage
            triageButton.isHidden = true
            triageAction = .none
        }
        #endif
    }

    private func hideTriage() {
        triageView.isHidden = true
        collectionView.isHidden = false
    }

    @objc private func triageButtonTapped() {
        switch triageAction {
        case .none:
            break
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .learnMore:
            let url = Self.appleIntelligenceSupportURL()
            UIApplication.shared.open(url)
        }
    }

    /// Build localized Apple Support URL for AI device compatibility.
    /// Format: https://support.apple.com/{lang}-{region}/121115
    private static func appleIntelligenceSupportURL() -> URL {
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        let regionCode = Locale.current.region?.identifier.lowercased() ?? "us"
        let urlString = "https://support.apple.com/\(langCode)-\(regionCode)/121115"
        return URL(string: urlString) ?? URL(string: "https://support.apple.com/en-us/121115")!
    }

    // MARK: - Collection View

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfig.headerMode = .none
        let layout = UICollectionViewCompositionalLayout.list(using: listConfig)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    // MARK: - Data Source

    private func setupDataSource() {
        let modeReg = UICollectionView.CellRegistration<UICollectionViewListCell, StudyMode> {
            cell, _, mode in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = mode.title
            content.secondaryText = mode.description
            content.image = UIImage(systemName: mode.symbolName)
            content.imageProperties.tintColor = .tintColor
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let warningReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> {
            cell, _, _ in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = L10n.AICoach.Triage.localeWarning
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "globe")
            content.imageProperties.tintColor = .systemYellow
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .localeWarning:
                return collectionView.dequeueConfiguredReusableCell(using: warningReg, for: indexPath, item: ())
            case .mode(let mode):
                return collectionView.dequeueConfiguredReusableCell(using: modeReg, for: indexPath, item: mode)
            }
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, ListItem>()

        // Locale warning (non-blocking)
        if !AICoachService.isCurrentLocaleSupported() {
            snapshot.appendSections([.localeWarning])
            snapshot.appendItems([.localeWarning], toSection: .localeWarning)
        }

        snapshot.appendSections([.main])
        snapshot.appendItems(StudyMode.allCases.map { .mode($0) }, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - UICollectionViewDelegate

@available(iOS 26, *)
extension AICoachViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .localeWarning:
            break  // not tappable
        case .mode(let mode):
            let vc: UIViewController
            switch mode {
            case .wordTinder:
                vc = WordTinderViewController()
            case .flashcard:
                vc = FlashcardPOCViewController()
            }
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        if case .mode = item { return true }
        return false
    }
}
