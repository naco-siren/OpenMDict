//
//  TutorialFeatureListViewController.swift
//  OpenMDict-iOS
//
//  Lists tutorial levels in the New User Guide.
//  Follows the DiffableDataSource form-style pattern (AppIconChooserVC).
//

import UIKit

// MARK: - Item

private nonisolated struct TutorialItem: Hashable, Sendable {
    let level: TutorialLevel
    let isCompleted: Bool
}

// MARK: - TutorialFeatureListViewController

final class TutorialFeatureListViewController: UIViewController {

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<TutorialSection, TutorialItem>!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.Tutorial.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        // Close button when presented modally (iPad formSheet)
        if navigationController?.presentingViewController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(dismissSelf)
            )
        }

        setupCollectionView()
        setupDataSource()
        rebuildSnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh completion state when returning from a tutorial
        rebuildSnapshot()
    }

    // MARK: - Actions

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    // MARK: - Collection View

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfig.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: listConfig)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    // MARK: - Data Source

    private func setupDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, TutorialItem> {
            (cell: UICollectionViewListCell, _: IndexPath, item: TutorialItem) in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.level.title
            content.secondaryText = item.level.description
            content.image = UIImage(systemName: item.level.symbolName(traitCollection: cell.traitCollection))
            content.imageProperties.tintColor = .tintColor
            cell.contentConfiguration = content

            var accessories: [UICellAccessory] = [.disclosureIndicator()]
            if item.isCompleted {
                let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
                checkmark.tintColor = .systemGreen
                checkmark.frame = CGSize(width: 22, height: 22).asRect
                accessories.insert(
                    .customView(configuration: .init(
                        customView: checkmark,
                        placement: .trailing(displayed: .always)
                    )),
                    at: 0
                )
            }
            cell.accessories = accessories
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { (supplementaryView: UICollectionViewListCell, _: String, indexPath: IndexPath) in
            var config = UIListContentConfiguration.groupedHeader()
            let section = TutorialSection(rawValue: indexPath.section)!
            config.text = section.title
            supplementaryView.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource<TutorialSection, TutorialItem>(
            collectionView: collectionView
        ) { (collectionView: UICollectionView, indexPath: IndexPath, item: TutorialItem) in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }

        dataSource.supplementaryViewProvider = { (collectionView, kind, indexPath) in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    // MARK: - Snapshot

    private func rebuildSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<TutorialSection, TutorialItem>()

        for section in TutorialSection.allCases {
            let levels = TutorialLevel.allCases.filter { $0.section == section }
            guard !levels.isEmpty else { continue }
            snapshot.appendSections([section])
            let items = levels.map { TutorialItem(level: $0, isCompleted: TutorialProgressService.isCompleted($0)) }
            snapshot.appendItems(items, toSection: section)
        }

        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - UICollectionViewDelegate

extension TutorialFeatureListViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let tutorialVC = TutorialViewController(level: item.level)
        navigationController?.pushViewController(tutorialVC, animated: true)
    }
}

// MARK: - CGSize Helper

private extension CGSize {
    var asRect: CGRect { CGRect(origin: .zero, size: self) }
}
