//
//  AppIconChooserViewController.swift
//  OpenMDict-iOS
//
//  Lets the user choose an alternate app icon from a list of variants.
//  Uses UIApplication.setAlternateIconName(_:) to apply the selection.
//
//  iOS 18+: .icon bundles → 7 cells (light/dark/tinted handled by system).
//  iOS 15–17: PNG fallback → 14 cells (light + dark for each variant,
//             because iOS <18 has no system dark-mode icon support).
//

import UIKit

// MARK: - Data Model (nonisolated for NSDiffableDataSourceSnapshot Sendable)

private nonisolated enum Section: Int, Hashable, CaseIterable, Sendable {
    case standard
    case classic
}

// MARK: - AppIconChooserViewController

final class AppIconChooserViewController: UIViewController {

    // MARK: - State

    private var selectedItem: AppIconItem = {
        let (icon, isDark) = AppIcon.from(alternateIconName: UIApplication.shared.alternateIconName)
        return AppIconItem(icon: icon, isDark: isDark)
    }()

    /// iOS 18+ .icon files handle dark mode automatically → single cell per variant.
    /// iOS 15–17 needs manual light/dark selection → two cells per variant.
    private var useDualAppearanceCells: Bool {
        if #available(iOS 18.0, *) { return false }
        return true
    }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, AppIconItem>!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.AppIcon.title
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
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, AppIconItem> {
            [weak self] (cell: UICollectionViewListCell, _: IndexPath, item: AppIconItem) in
            guard let self else { return }

            var content = UIListContentConfiguration.cell()
            content.text = item.displayName
            content.image = item.previewImage
            content.imageProperties.maximumSize = CGSize(width: 60, height: 60)
            content.imageProperties.cornerRadius = 13
            cell.contentConfiguration = content

            cell.accessories = item == self.selectedItem
                ? [.checkmark(displayed: .always)]
                : []

            // On iOS 18+, show the appearance-matched preview for the single cell.
            // On iOS 15–17 each cell has a fixed appearance, no dynamic switching.
            if !self.useDualAppearanceCells {
                cell.configurationUpdateHandler = { cell, state in
                    guard var updated = cell.contentConfiguration as? UIListContentConfiguration else { return }
                    let dark = state.traitCollection.userInterfaceStyle == .dark
                    updated.image = (dark ? item.icon.darkPreviewImage : item.icon.previewImage)
                        ?? item.icon.previewImage
                    cell.contentConfiguration = updated
                }
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { (supplementaryView: UICollectionViewListCell, _: String, indexPath: IndexPath) in
            var config = UIListContentConfiguration.groupedHeader()
            let section = Section(rawValue: indexPath.section)!
            switch section {
            case .standard: config.text = L10n.AppIcon.sectionStandard
            case .classic:  config.text = L10n.AppIcon.sectionClassic
            }
            supplementaryView.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource<Section, AppIconItem>(
            collectionView: collectionView
        ) { (collectionView: UICollectionView, indexPath: IndexPath, item: AppIconItem) in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }

        dataSource.supplementaryViewProvider = { (collectionView, kind, indexPath) in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    // MARK: - Snapshot

    private func rebuildSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, AppIconItem>()

        let standardIcons = AppIcon.standardIcons
        if !standardIcons.isEmpty {
            snapshot.appendSections([.standard])
            snapshot.appendItems(makeItems(from: standardIcons), toSection: .standard)
        }

        let classicIcons = AppIcon.easterEggIcons
        if !classicIcons.isEmpty {
            snapshot.appendSections([.classic])
            snapshot.appendItems(makeItems(from: classicIcons), toSection: .classic)
        }

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Build items: one per icon on iOS 18+, two (light + dark) on iOS 15–17.
    private func makeItems(from icons: [AppIcon]) -> [AppIconItem] {
        if useDualAppearanceCells {
            return icons.flatMap { icon in
                [AppIconItem(icon: icon, isDark: false),
                 AppIconItem(icon: icon, isDark: true)]
            }
        } else {
            return icons.map { AppIconItem(icon: $0, isDark: false) }
        }
    }
}

// MARK: - UICollectionViewDelegate

extension AppIconChooserViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let item = dataSource.itemIdentifier(for: indexPath),
              item != selectedItem else { return }

        UIApplication.shared.setAlternateIconName(item.alternateIconName) { [weak self] error in
            guard let self else { return }
            if let error {
                debugLog("❌ setAlternateIconName failed: \(error.localizedDescription)")
                return
            }

            self.selectedItem = item

            // Refresh all cells to update checkmark
            var snapshot = self.dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            self.dataSource.apply(snapshot, animatingDifferences: true)
        }
    }
}
