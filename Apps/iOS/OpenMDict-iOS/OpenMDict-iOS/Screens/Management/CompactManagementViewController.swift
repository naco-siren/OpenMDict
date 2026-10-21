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
    case newUserGuide
    case changeAppIcon
    case iCloudTroubleshoot
    case aiCoach
    case articleEmbedPOC   // M15 Phase 3.0.5: DEBUG-only entry to article-embed POC
    case articleIndex      // M15: article-content search indexing (iOS 26+ only)
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

    /// "New User Guide" tapped
    var onNewUserGuideSelected: (() -> Void)?

    /// "App Icon" tapped
    var onChangeAppIconSelected: (() -> Void)?

    /// "iCloud Troubleshooting" tapped
    var onTroubleshootSelected: (() -> Void)?

    /// "AI Coach" tapped (iOS 26+, only visible when AICoach.isVisible)
    var onAICoachSelected: (() -> Void)?

    /// "Article Embed POC" tapped — DEBUG-only sidebar/tab entry to the
    /// M15 Phase 3.0.5 throughput POC. Wired in CompactTabBarController.
    var onArticleEmbedPOCSelected: (() -> Void)?

    /// "Article Search Indexing" tapped (iOS 26+ only)
    var onArticleIndexSelected: (() -> Void)?

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

        // M14 POC: the AI Coach row is gated by a Settings.bundle toggle
        // the user flips in Settings.app, outside our process. Observe
        // scene activation so the row appears/disappears immediately when
        // the user comes back — `rebuildSnapshot()` is idempotent and
        // cheap (static items, DiffableDataSource no-ops on equal diffs).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIScene.didActivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePresetUpdatesChanged),
            name: PresetDictionaryService.updatesDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleDidBecomeActive() {
        debugLog("🪄 management didBecomeActive → \(AICoach.diagnosticSummary)")
        rebuildSnapshot()
    }

    /// The "Download Presets" row shows how many presets have an update.
    @objc private func handlePresetUpdatesChanged() {
        guard var snapshot = dataSource?.snapshot(), snapshot.indexOfItem(.downloadPresets) != nil else { return }
        snapshot.reconfigureItems([.downloadPresets])
        dataSource.apply(snapshot, animatingDifferences: false)
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
            case .newUserGuide:
                config.text = L10n.Tutorial.title
                config.image = UIImage(systemName: "graduationcap")
            case .changeAppIcon:
                config.text = L10n.AppIcon.title
                config.image = UIImage(systemName: "app.badge.checkmark")
            case .iCloudTroubleshoot:
                config.text = L10n.Troubleshoot.title
                config.image = UIImage(systemName: "key.icloud")
            case .aiCoach:
                config.text = L10n.Sidebar.aiCoach
                config.image = UIImage(systemName: "apple.intelligence")
            case .articleEmbedPOC:
                config.text = "Article Embed POC"  // no L10n, DEBUG only
                config.image = UIImage(systemName: "waveform.path.ecg")
            case .articleIndex:
                config.text = L10n.ArticleIndex.title
                // `mail.and.text.magnifyingglass` (iOS 17+) — fine, this
                // entry only shows on the feature's iOS 26+ floor.
                config.image = UIImage(systemName: "mail.and.text.magnifyingglass")
            case .appSettings:
                config.text = L10n.Sidebar.appSettings
                config.image = UIImage(systemName: "gearshape")
            }
            cell.contentConfiguration = config
            let updateCount = item == .downloadPresets
                ? PresetDictionaryService.shared.updatablePresets.count : 0
            cell.accessories = updateCount > 0
                ? [ManagementActionCell.badgeAccessory(count: updateCount, isActive: false), .disclosureIndicator()]
                : [.disclosureIndicator()]
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
        var items: [MgmtItem] = []
        // M14 POC: AI Coach at the top of the tab when enabled.
        if AICoach.isVisible {
            items.append(.aiCoach)
        }
        items.append(contentsOf: [
            .addGroup, .importDictionary, .downloadPresets,
            .newUserGuide, .iCloudTroubleshoot, .changeAppIcon,
        ])
        // M15: article-content search indexing (iOS 26+ + feature available).
        if ArticleIndexCoordinator.shared.isAvailable {
            items.append(.articleIndex)
        }
        items.append(.appSettings)
        // M15 Phase 3.0.5 article-embedding POC entry. DEBUG-only; never
        // appears in Release builds. Same `#if DEBUG` gating as the
        // regular-layout sidebar in DictionaryListViewController.
        #if DEBUG
        items.append(.articleEmbedPOC)
        #endif
        snapshot.appendItems(items, toSection: .actions)
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
        case .newUserGuide:
            onNewUserGuideSelected?()
        case .changeAppIcon:
            onChangeAppIconSelected?()
        case .iCloudTroubleshoot:
            onTroubleshootSelected?()
        case .aiCoach:
            onAICoachSelected?()
        case .articleEmbedPOC:
            onArticleEmbedPOCSelected?()
        case .articleIndex:
            onArticleIndexSelected?()
        case .appSettings:
            onAppSettingsSelected?()
        }
    }
}
