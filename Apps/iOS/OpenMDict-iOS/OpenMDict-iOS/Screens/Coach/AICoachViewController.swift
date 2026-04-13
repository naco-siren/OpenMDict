//
//  AICoachViewController.swift
//  OpenMDict-iOS
//
//  M14: AI Coach facade — lists available study modes.
//  Follows the TutorialFeatureListViewController pattern
//  (DiffableDataSource + plain list layout).
//

import UIKit

@available(iOS 26, *)
final class AICoachViewController: UIViewController {

    // MARK: - Types

    private nonisolated enum Section: Hashable, Sendable {
        case main
    }

    private nonisolated enum StudyMode: Int, CaseIterable, Hashable, Sendable {
        case wordRelationship
        case flashcard

        var symbolName: String {
            switch self {
            case .wordRelationship: return "plus.forwardslash.minus"
            case .flashcard:        return "rectangle.on.rectangle"
            }
        }

        var title: String {
            switch self {
            case .wordRelationship: return L10n.AICoach.wordQuiz
            case .flashcard:        return L10n.AICoach.flashcard
            }
        }

        var description: String {
            switch self {
            case .wordRelationship: return L10n.AICoach.wordQuizDesc
            case .flashcard:        return L10n.AICoach.flashcardDesc
            }
        }
    }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, StudyMode>!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.AICoach.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground

        // Close button when presented modally
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
        applySnapshot()
    }

    // MARK: - Actions

    @objc private func dismissSelf() {
        dismiss(animated: true)
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
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, StudyMode> {
            cell, _, mode in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = mode.title
            content.secondaryText = mode.description
            content.image = UIImage(systemName: mode.symbolName)
            content.imageProperties.tintColor = .tintColor
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, mode in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: mode)
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, StudyMode>()
        snapshot.appendSections([.main])
        snapshot.appendItems(StudyMode.allCases, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - UICollectionViewDelegate

@available(iOS 26, *)
extension AICoachViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let mode = dataSource.itemIdentifier(for: indexPath) else { return }

        let vc: UIViewController
        switch mode {
        case .wordRelationship:
            vc = WordRelationshipQuizViewController()
        case .flashcard:
            vc = FlashcardPOCViewController()
        }
        navigationController?.pushViewController(vc, animated: true)
    }
}
