//
//  GroupDictionaryEditorViewController.swift
//  OpenMDict-iOS
//
//  Third column in Group Management mode - add/remove dictionaries from a group.
//
//  Dual behavior:
//  - Creating mode: reads/writes GroupManagementSession.pendingDictionaryIds (in-memory only)
//  - Managing mode: calls DictionaryService add/remove directly (immediate persist)
//  - ReorderOnly mode: reorder-only list for the default group (no add/remove controls)
//
//  Layout:
//  - Section "In This Group": dictionaries currently in the group (tap ⊖ to remove)
//  - Section "Available": dictionaries not in the group (tap ⊕ to add)
//  - ReorderOnly: single section with reorder handles, no ⊖/⊕ controls
//

import UIKit
import OpenMDictKit

class GroupDictionaryEditorViewController: UIViewController {
    
    // MARK: - Types
    
    private nonisolated enum Section: Int, CaseIterable {
        case inGroup       // Dictionaries in this group
        case available     // Dictionaries not in this group
        
        var title: String {
            switch self {
            case .inGroup: return L10n.DictEditor.inThisGroup
            case .available: return L10n.DictEditor.available
            }
        }
    }
    
    /// Single section used for reorderOnly mode
    private nonisolated enum ReorderSection: Int, CaseIterable {
        case dictionaries
        
        var title: String { L10n.DictEditor.sectionDictionaries }
    }
    
    private nonisolated enum Item: Hashable {
        case dict(id: String, inGroup: Bool)
        case emptyInGroup        // "No dictionaries" placeholder
        case emptyAvailable      // "All dictionaries added" placeholder
    }
    
    /// Item type for reorderOnly mode (simpler, no inGroup flag)
    private nonisolated enum ReorderItem: Hashable {
        case dict(id: String)
        case empty
    }
    
    enum Mode: Equatable {
        case empty
        case creating                       // New group — reads/writes session.pendingDictionaryIds
        case managing(groupId: String)      // Existing group — immediate persist via service
        case reorderOnly(groupId: String)   // Default group — reorder only, no add/remove
    }
    
    // MARK: - Data Source

    /// Abstracted service dependencies. Defaults to production singletons.
    var serviceDataSource: GroupManagementDataSource = DefaultGroupManagementDataSource.shared

    // MARK: - State

    private(set) var mode: Mode = .empty {
        didSet {
            if oldValue != mode && isViewLoaded {
                switchDataSource()
                reloadData()
            }
        }
    }
    
    private var session: GroupManagementSession {
        serviceDataSource.groupSession
    }
    
    // MARK: - UI
    
    private var collectionView: UICollectionView!
    
    /// Data source for creating/managing modes (two sections: inGroup + available)
    private var fullDataSource: UICollectionViewDiffableDataSource<Section, Item>!
    
    /// Data source for reorderOnly mode (single section: dictionaries)
    private var reorderDataSource: UICollectionViewDiffableDataSource<ReorderSection, ReorderItem>!
    
    private lazy var emptyStateView: UIView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .thin)
        let image = UIImage(systemName: "books.vertical", withConfiguration: config)
        let iv = UIImageView(image: image)
        iv.tintColor = .tertiaryLabel
        iv.contentMode = .scaleAspectFit
        stack.addArrangedSubview(iv)
        
        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.text = L10n.DictEditor.noSelection
        stack.addArrangedSubview(titleLabel)
        
        let subtitleLabel = UILabel()
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .tertiaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = L10n.DictEditor.noSelectionSubtitle
        stack.addArrangedSubview(subtitleLabel)
        
        stack.setCustomSpacing(24, after: iv)
        
        return stack
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupUI()
        setupCollectionView()
        setupFullDataSource()
        setupReorderDataSource()
        switchDataSource()
        reloadData()
    }
    
    // MARK: - Setup
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = L10n.DictEditor.dictionaries
        
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
    
    private func setupCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.delegate = self
        collectionView.dragInteractionEnabled = true
        
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    // MARK: - Full Data Source (creating / managing)
    
    private func setupFullDataSource() {
        // MARK: Dictionary Cell
        let dictReg = UICollectionView.CellRegistration<UICollectionViewListCell, (String, Bool)> {
            [weak self] cell, indexPath, tuple in
            let (dictId, inGroup) = tuple
            let dict = self?.serviceDataSource.dict(id: dictId)
            
            var content = cell.defaultContentConfiguration()
            content.text = dict?.preferredTitle ?? dictId.prefix(8).description
            
            if inGroup {
                content.image = UIImage(systemName: "book.closed.fill")
                content.imageProperties.tintColor = .systemBlue
                
                // ⊖ remove button (red minus circle) + reorder handle
                let minusImage = UIImageView(image: UIImage(systemName: "minus.circle.fill"))
                minusImage.tintColor = .systemRed
                cell.accessories = [
                    .customView(configuration: .init(customView: minusImage, placement: .leading())),
                    .reorder(displayed: .always),
                ]
            } else {
                content.image = UIImage(systemName: "book.closed")
                content.imageProperties.tintColor = .secondaryLabel
                
                // ⊕ add button (green plus circle)
                let plusImage = UIImageView(image: UIImage(systemName: "plus.circle.fill"))
                plusImage.tintColor = .systemGreen
                cell.accessories = [
                    .customView(configuration: .init(customView: plusImage, placement: .leading()))
                ]
            }
            
            // Show load state
            let loadState = dict?.state ?? .unloaded
            switch loadState {
            case .unloaded, .loading:
                content.textProperties.color = .secondaryLabel
            case .error:
                content.textProperties.color = .systemRed
            case .metadataLoaded, .loaded:
                content.textProperties.color = .label
            }
            
            cell.contentConfiguration = content
        }
        
        // MARK: Empty Placeholder
        let emptyReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            cell, indexPath, text in
            var content = cell.defaultContentConfiguration()
            content.text = text
            content.textProperties.color = .tertiaryLabel
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Header
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, _, indexPath in
            guard let section = self?.fullDataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = headerView.defaultContentConfiguration()
            content.text = section.title
            headerView.contentConfiguration = content
        }
        
        // MARK: Provider
        fullDataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .dict(let id, let inGroup):
                return collectionView.dequeueConfiguredReusableCell(using: dictReg, for: indexPath, item: (id, inGroup))
            case .emptyInGroup:
                return collectionView.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: L10n.DictEditor.noDictionariesInGroup)
            case .emptyAvailable:
                return collectionView.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: L10n.DictEditor.allAdded)
            }
        }
        
        fullDataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
        
        // MARK: Reordering (inGroup section only)
        fullDataSource.reorderingHandlers.canReorderItem = { item in
            if case .dict(_, inGroup: true) = item { return true }
            return false
        }
        
        fullDataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.commitFullReorder(transaction)
        }
    }
    
    // MARK: - Reorder Data Source (reorderOnly mode)
    
    private func setupReorderDataSource() {
        // MARK: Dictionary Cell (reorder only — no ⊖/⊕, just book + reorder handle)
        let reorderDictReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, indexPath, dictId in
            let dict = self?.serviceDataSource.dict(id: dictId)
            
            var content = cell.defaultContentConfiguration()
            content.text = dict?.preferredTitle ?? dictId.prefix(8).description
            content.image = UIImage(systemName: "book.closed.fill")
            content.imageProperties.tintColor = .systemBlue
            
            // Show load state
            let loadState = dict?.state ?? .unloaded
            switch loadState {
            case .unloaded, .loading:
                content.textProperties.color = .secondaryLabel
            case .error:
                content.textProperties.color = .systemRed
            case .metadataLoaded, .loaded:
                content.textProperties.color = .label
            }
            
            cell.contentConfiguration = content
            cell.accessories = [.reorder(displayed: .always)]
        }
        
        // MARK: Empty Placeholder
        let emptyReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            cell, indexPath, text in
            var content = cell.defaultContentConfiguration()
            content.text = text
            content.textProperties.color = .tertiaryLabel
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Header
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, _, indexPath in
            guard let section = self?.reorderDataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = headerView.defaultContentConfiguration()
            content.text = section.title
            headerView.contentConfiguration = content
        }
        
        // MARK: Provider
        reorderDataSource = UICollectionViewDiffableDataSource<ReorderSection, ReorderItem>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .dict(let id):
                return collectionView.dequeueConfiguredReusableCell(using: reorderDictReg, for: indexPath, item: id)
            case .empty:
                return collectionView.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: L10n.DictEditor.noDictionaries)
            }
        }
        
        reorderDataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
        
        // MARK: Reordering
        reorderDataSource.reorderingHandlers.canReorderItem = { item in
            if case .dict = item { return true }
            return false
        }
        
        reorderDataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.commitReorderOnly(transaction)
        }
    }
    
    // MARK: - Data Source Switching
    
    /// Assign the correct data source to the collection view based on current mode.
    private func switchDataSource() {
        guard isViewLoaded else { return }
        
        switch mode {
        case .reorderOnly:
            collectionView.dataSource = reorderDataSource
        default:
            collectionView.dataSource = fullDataSource
        }
    }
    
    // MARK: - Data
    
    private func reloadData() {
        switch mode {
        case .empty:
            emptyStateView.isHidden = false
            collectionView.isHidden = true
            
        case .creating, .managing:
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            applyFullSnapshot()
            
        case .reorderOnly:
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            applyReorderSnapshot()
        }
    }
    
    private func applyFullSnapshot(animated: Bool = true) {
        let inGroupIds: [String]
        
        switch mode {
        case .empty, .reorderOnly:
            return
        case .creating:
            inGroupIds = session.pendingDictionaryIds
        case .managing(let groupId):
            guard let group = serviceDataSource.group(id: groupId) else { return }
            inGroupIds = group.dictionaryIds
        }
        
        let inGroupSet = Set(inGroupIds)
        let allDicts = serviceDataSource.allDictionaries
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        
        // In group section (ordered)
        let inGroupItems = inGroupIds.map { Item.dict(id: $0, inGroup: true) }
        if inGroupItems.isEmpty {
            snapshot.appendItems([.emptyInGroup], toSection: .inGroup)
        } else {
            snapshot.appendItems(inGroupItems, toSection: .inGroup)
        }
        
        // Available section - all dicts NOT in this group
        let availableItems = allDicts
            .filter { !inGroupSet.contains($0.id) }
            .map { Item.dict(id: $0.id, inGroup: false) }
        if availableItems.isEmpty {
            snapshot.appendItems([.emptyAvailable], toSection: .available)
        } else {
            snapshot.appendItems(availableItems, toSection: .available)
        }
        
        fullDataSource.apply(snapshot, animatingDifferences: animated)
    }
    
    private func applyReorderSnapshot(animated: Bool = true) {
        guard case .reorderOnly(let groupId) = mode,
              let group = serviceDataSource.group(id: groupId) else { return }
        
        var snapshot = NSDiffableDataSourceSnapshot<ReorderSection, ReorderItem>()
        snapshot.appendSections(ReorderSection.allCases)
        
        let items = group.dictionaryIds.map { ReorderItem.dict(id: $0) }
        if items.isEmpty {
            snapshot.appendItems([.empty], toSection: .dictionaries)
        } else {
            snapshot.appendItems(items, toSection: .dictionaries)
        }
        
        reorderDataSource.apply(snapshot, animatingDifferences: animated)
    }
    
    // MARK: - Actions
    
    /// Persist the new order after a drag-and-drop reorder in the full data source (inGroup section).
    private func commitFullReorder(_ transaction: NSDiffableDataSourceTransaction<Section, Item>) {
        let newOrder = transaction.finalSnapshot.itemIdentifiers(inSection: .inGroup).compactMap { item -> String? in
            if case .dict(let id, inGroup: true) = item { return id }
            return nil
        }
        
        guard !newOrder.isEmpty else { return }
        
        switch mode {
        case .creating:
            session.pendingDictionaryIds = newOrder
        case .managing(let groupId):
            serviceDataSource.reorderDictionariesInGroup(groupId: groupId, newOrder: newOrder)
        default:
            break
        }
    }
    
    /// Persist the new order after a drag-and-drop reorder in the reorder-only data source.
    private func commitReorderOnly(_ transaction: NSDiffableDataSourceTransaction<ReorderSection, ReorderItem>) {
        let newOrder = transaction.finalSnapshot.itemIdentifiers(inSection: .dictionaries).compactMap { item -> String? in
            if case .dict(let id) = item { return id }
            return nil
        }
        
        guard !newOrder.isEmpty, case .reorderOnly(let groupId) = mode else { return }
        
        serviceDataSource.reorderDictionariesInGroup(groupId: groupId, newOrder: newOrder)
    }
    
    private func addDictionary(_ dictId: String) {
        switch mode {
        case .creating:
            session.pendingDictionaryIds.append(dictId)
            applyFullSnapshot()
        case .managing(let groupId):
            serviceDataSource.addDictionaryToGroup(groupId: groupId, dictId: dictId)
            applyFullSnapshot()
        default:
            break
        }
    }
    
    private func removeDictionary(_ dictId: String) {
        switch mode {
        case .creating:
            session.pendingDictionaryIds.removeAll { $0 == dictId }
            applyFullSnapshot()
        case .managing(let groupId):
            serviceDataSource.removeDictionaryFromGroup(groupId: groupId, dictId: dictId)
            applyFullSnapshot()
        default:
            break
        }
    }
    
    // MARK: - Public API
    
    func showEmptyState() {
        mode = .empty
        if isViewLoaded { reloadData() }
    }
    
    /// Show editor for an existing group (managing mode — immediate persist)
    func showEditor(for groupId: String) {
        mode = .managing(groupId: groupId)
        if isViewLoaded {
            switchDataSource()
            reloadData()
        }
    }
    
    /// Show editor for a new group (creating mode — writes to session only)
    func showCreatingEditor() {
        mode = .creating
        if isViewLoaded {
            switchDataSource()
            reloadData()
        }
    }
    
    /// Show reorder-only editor for the default group
    func showReorderEditor(for groupId: String) {
        mode = .reorderOnly(groupId: groupId)
        if isViewLoaded {
            switchDataSource()
            reloadData()
        }
    }
}

// MARK: - UICollectionViewDelegate

extension GroupDictionaryEditorViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        // In reorderOnly mode, tapping does nothing (only drag-to-reorder)
        guard case .reorderOnly = mode else {
            // Full mode: toggle add/remove
            guard let item = fullDataSource.itemIdentifier(for: indexPath) else { return }
            switch item {
            case .dict(let dictId, let inGroup):
                if inGroup {
                    removeDictionary(dictId)
                } else {
                    addDictionary(dictId)
                }
            case .emptyInGroup, .emptyAvailable:
                break
            }
            return
        }
        // reorderOnly: no-op on tap
    }
}
