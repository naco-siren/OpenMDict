//
//  CompactManagementViewController.swift
//  OpenMDict-iOS
//
//  Root view controller for the Management tab in compact (iPhone) layout.
//  Shows only the management actions from the sidebar's management section:
//  Add New Group, Import Dictionary, Download Presets, App Settings.
//
//  Dictionary and group browsing is handled by the sidebar sheet
//  (DictionaryListViewController) presented from the Lookup tab.
//

import UIKit
import OpenMDictKit

// MARK: - Data Model (nonisolated for NSDiffableDataSourceSnapshot Sendable requirement)

private nonisolated enum MgmtSection: Int, Hashable, CaseIterable, Sendable {
    case actions
}

/// Order matches the sidebar's management section (after Bookmarks and History
/// which have their own tabs): Add New Group, Import Dictionary, Download Presets, Settings.
private nonisolated enum MgmtItem: Hashable, Sendable {
    case addGroup
    case importDictionary
    case downloadPresets
    case appSettings
}

// MARK: - CompactManagementViewController

class CompactManagementViewController: UIViewController {

    // MARK: - Callbacks

    /// "Import Dictionary" tapped
    var onImportSelected: (() -> Void)?

    /// "Add New Group" tapped
    var onAddGroupSelected: (() -> Void)?

    /// "Download Presets" tapped
    var onDownloadPresetsSelected: (() -> Void)?

    /// "App Settings" tapped
    var onAppSettingsSelected: (() -> Void)?

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<MgmtSection, MgmtItem>!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.TabBar.management
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .always

        setupCollectionView()
        setupDataSource()
        rebuildSnapshot()
    }

    // MARK: - Collection View Setup

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfig.headerMode = .none
        let layout = UICollectionViewCompositionalLayout.list(using: listConfig)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    // MARK: - Data Source

    private func setupDataSource() {
        let actionCell = UICollectionView.CellRegistration<UICollectionViewListCell, MgmtItem> {
            (cell: UICollectionViewListCell, _: IndexPath, item: MgmtItem) in
            var config = cell.defaultContentConfiguration()
            // Icons match ManagementActionCell in the sidebar exactly.
            switch item {
            case .addGroup:
                config.text = L10n.Sidebar.addNewGroup
                config.image = UIImage(systemName: "folder.badge.plus")
            case .importDictionary:
                config.text = L10n.Sidebar.importDictionary
                config.image = UIImage(systemName: "plus.circle")
            case .downloadPresets:
                config.text = L10n.Sidebar.downloadPresets
                config.image = UIImage(systemName: "icloud.and.arrow.down")
            case .appSettings:
                config.text = L10n.Sidebar.appSettings
                config.image = UIImage(systemName: "gearshape")
            }
            cell.contentConfiguration = config
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = UICollectionViewDiffableDataSource<MgmtSection, MgmtItem>(
            collectionView: collectionView
        ) { (collectionView: UICollectionView, indexPath: IndexPath, item: MgmtItem) -> UICollectionViewCell? in
            collectionView.dequeueConfiguredReusableCell(
                using: actionCell, for: indexPath, item: item
            )
        }
    }

    // MARK: - Snapshot

    private func rebuildSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<MgmtSection, MgmtItem>()
        snapshot.appendSections([.actions])
        snapshot.appendItems([.addGroup, .importDictionary, .downloadPresets, .appSettings],
                            toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Force reload (called after management operations complete).
    /// Items are static so this is effectively a no-op, kept for API compatibility.
    func reload() {
        // Static content — nothing to rebuild.
    }
}

// MARK: - UICollectionViewDelegate

extension CompactManagementViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .importDictionary:
            onImportSelected?()
        case .addGroup:
            onAddGroupSelected?()
        case .downloadPresets:
            onDownloadPresetsSelected?()
        case .appSettings:
            onAppSettingsSelected?()
        }
    }
}
