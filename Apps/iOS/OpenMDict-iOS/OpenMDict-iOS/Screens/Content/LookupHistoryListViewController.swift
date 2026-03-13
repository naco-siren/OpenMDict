//
//  LookupHistoryListViewController.swift
//  OpenMDict-iOS
//
//  Centralized lookup history list — shows ALL history records across
//  all lookup contexts, deduplicated by (word, dictId) and grouped by date.
//
//  Used as the supplementary column when "My Lookup History" is selected
//  in the sidebar.
//

import Combine
import UIKit

class LookupHistoryListViewController: UIViewController {

    // MARK: - Callbacks

    var onHistorySelected: ((HistoryItem) -> Void)?

    // MARK: - State

    private var historyCancellable: AnyCancellable?
    private var metadataCancellable: AnyCancellable?

    private var dataSource: UICollectionViewDiffableDataSource<String, HistoryItem>!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = L10n.LookupHistory.title
        navigationItem.largeTitleDisplayMode = .automatic
        setupNavigationBar()

        view.backgroundColor = .systemGroupedBackground
        view.addSubview(collectionView)
        view.addSubview(emptyView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureDataSource()
        reload()

        // React to lookup history changes (e.g., new lookups from other VCs)
        historyCancellable = LookupHistoryService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }

        // React to dictionary metadata changes (e.g., dict renamed locally or on another device)
        metadataCancellable = DictMetadataService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }
    }

    // MARK: - Public Reload

    /// Reload history from the data layer and refresh the snapshot.
    /// Called externally by MainSplitVC when first showing the list.
    func reload() {
        // dataSource is configured in viewDidLoad; if called before that
        // (e.g. from MainSplitVC.showLookupHistoryList before the view
        // hierarchy triggers loadView), force-load the view first.
        loadViewIfNeeded()

        // Resolve dictName from DictMetadataService (authoritative) and set availability.
        let rawGroups = LookupHistoryService.shared.allGroupedHistory()
        let groups = rawGroups.map { section in
            HistorySection(title: section.title, records: section.records.map { item in
                let metadata = DictMetadataService.shared.find(dictId: item.dictId)
                return HistoryItem(
                    objectID: item.objectID,
                    word: item.word,
                    dictId: item.dictId,
                    dictName: metadata?.displayName ?? item.dictName,
                    isDictAvailable: metadata != nil,
                    lastLookedUpAt: item.lastLookedUpAt
                )
            })
        }
        applySnapshot(groups: groups, animated: true)
        updateEmptyState(groups: groups)
        rebuildMenus()
    }

    // MARK: - Data Source Configuration

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, HistoryItem> {
            cell, indexPath, item in

            var content = cell.defaultContentConfiguration()
            content.text = item.word
            if item.isDictAvailable {
                content.secondaryText = item.dictName
                content.secondaryTextProperties.color = .secondaryLabel
                content.textProperties.color = .label
                content.image = UIImage(systemName: "clock")
                content.imageProperties.tintColor = .secondaryLabel
            } else {
                content.secondaryText = item.dictName.isEmpty
                    ? L10n.dictUnavailable
                    : "\(item.dictName) · \(L10n.dictUnavailable)"
                content.secondaryTextProperties.color = .tertiaryLabel
                content.textProperties.color = .secondaryLabel
                content.image = UIImage(systemName: "clock")
                content.imageProperties.tintColor = .tertiaryLabel
            }
            cell.contentConfiguration = content
            cell.accessories = []
        }

        // Section header registration
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, _, indexPath in
            guard let self,
                  let sectionTitle = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }

            var config = UIListContentConfiguration.groupedHeader()
            config.text = sectionTitle
            headerView.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    // MARK: - Snapshot

    private func applySnapshot(groups: [HistorySection], animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<String, HistoryItem>()
        for group in groups {
            snapshot.appendSections([group.title])
            snapshot.appendItems(group.records, toSection: group.title)
        }
        // Force cell reconfiguration even when item identity hasn't changed,
        // because dictName (resolved from DictMetadataService) lives outside
        // HistoryItem's Hashable identity (word + dictId).
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: - UI

    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self,
                  let item = self.dataSource.itemIdentifier(for: indexPath) else {
                return nil
            }
            let deleteAction = UIContextualAction(style: .destructive, title: L10n.delete) { [weak self] _, _, completion in
                if let objectID = item.objectID {
                    LookupHistoryService.shared.deleteRecord(objectID: objectID)
                }
                self?.reload()
                completion(true)
            }
            deleteAction.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }

        let layout = UICollectionViewCompositionalLayout.list(using: config)

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
        return cv
    }()

    private lazy var emptyView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        let img = UIImageView(image: UIImage(systemName: "clock"))
        img.tintColor = .tertiaryLabel
        img.preferredSymbolConfiguration = .init(pointSize: 48)

        let titleLabel = UILabel()
        titleLabel.text = L10n.LookupHistory.empty
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .secondaryLabel

        let subtitleLabel = UILabel()
        subtitleLabel.text = L10n.LookupHistory.emptySubtitle
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .tertiaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        stack.addArrangedSubview(img)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -32),
        ])
        return v
    }()

    // MARK: - Navigation Bar Buttons

    /// Clear all button (used as standalone item in iOS 16+ trailingItemGroups)
    private lazy var clearAllButton: UIBarButtonItem = {
        .init(
            title: L10n.History.clearAll,
            image: UIImage(systemName: "trash"),
            primaryAction: UIAction(attributes: .destructive) { [weak self] _ in
                self?.confirmClearAll()
            }
        )
    }()

    // MARK: - Navigation Bar Menus

    /// Overflow menu containing "Clear All" (iOS 15 fallback)
    private var overflowMenu: UIMenu {
        let clearAction = UIAction(
            title: L10n.History.clearAll,
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmClearAll()
        }
        return UIMenu(children: [clearAction])
    }

    // MARK: - Navigation Bar Setup

    private func setupNavigationBar() {
        if #available(iOS 16, *) {
            navigationItem.style = .navigator
            navigationItem.leadingItemGroups = []
            navigationItem.centerItemGroups = []
            navigationItem.trailingItemGroups = [
                .optionalGroup(
                    customizationIdentifier: "clearAll",
                    representativeItem: UIBarButtonItem(
                        title: L10n.History.clearAll,
                        image: UIImage(systemName: "trash"),
                        primaryAction: UIAction(attributes: .destructive) { [weak self] _ in
                            self?.confirmClearAll()
                        }
                    ),
                    items: [clearAllButton]
                ),
            ]
        } else {
            navigationItem.leftBarButtonItems = []
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(
                    image: UIImage(systemName: "ellipsis.circle"),
                    menu: overflowMenu
                ),
            ]
        }
    }

    /// Rebuild all menus to reflect current state.
    private func rebuildMenus() {
        setupNavigationBar()
    }

    // MARK: - Empty State

    private func updateEmptyState(groups: [HistorySection]) {
        let isEmpty = groups.isEmpty
        emptyView.isHidden = !isEmpty
        collectionView.isHidden = isEmpty
        clearAllButton.isEnabled = !isEmpty
    }

    // MARK: - Actions

    private func confirmClearAll() {
        let alert = UIAlertController(
            title: L10n.LookupHistory.clearAllConfirmTitle,
            message: L10n.LookupHistory.clearAllConfirmMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
            LookupHistoryService.shared.clearAllHistory()
            self?.reload()
        })
        present(alert, animated: true)

        rebuildMenus()
    }
}

// MARK: - UICollectionViewDelegate

extension LookupHistoryListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        onHistorySelected?(item)
    }
}
