//
//  GroupDictionaryEditorViewController.swift
//  OpenMDict-iOS
//
//  Third column in Group Management mode - add/remove dictionaries from a group.
//
//  Dual behavior:
//  - Creating mode: reads/writes GroupManagementSession.pendingDictionaryIds (in-memory only)
//  - Managing mode: calls DictionaryService add/remove directly (immediate persist)
//
//  Layout:
//  - Section "In This Group": dictionaries currently in the group (tap ⊖ to remove)
//  - Section "Available": dictionaries not in the group (tap ⊕ to add)
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
            case .inGroup: return "IN THIS GROUP"
            case .available: return "AVAILABLE DICTIONARIES"
            }
        }
    }
    
    private nonisolated enum Item: Hashable {
        case dict(id: String, inGroup: Bool)
        case emptyInGroup        // "No dictionaries" placeholder
        case emptyAvailable      // "All dictionaries added" placeholder
    }
    
    enum Mode: Equatable {
        case empty
        case creating              // New group — reads/writes session.pendingDictionaryIds
        case managing(groupId: String)  // Existing group — immediate persist via service
    }
    
    // MARK: - State
    
    private(set) var mode: Mode = .empty {
        didSet {
            if oldValue != mode && isViewLoaded {
                reloadData()
            }
        }
    }
    
    private var session: GroupManagementSession {
        DictionaryService.shared.groupSession
    }
    
    // MARK: - UI
    
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    
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
        titleLabel.text = "No Group Selected"
        stack.addArrangedSubview(titleLabel)
        
        let subtitleLabel = UILabel()
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .tertiaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = "Select a group to manage its dictionaries"
        stack.addArrangedSubview(subtitleLabel)
        
        stack.setCustomSpacing(24, after: iv)
        
        return stack
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupUI()
        setupCollectionView()
        setupDataSource()
        reloadData()
    }
    
    // MARK: - Setup
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = "Dictionaries"
        
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
    
    private func setupDataSource() {
        // MARK: Dictionary Cell
        let dictReg = UICollectionView.CellRegistration<UICollectionViewListCell, (String, Bool)> {
            cell, indexPath, tuple in
            let (dictId, inGroup) = tuple
            let dict = DictionaryService.shared.dict(id: dictId)
            
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
            guard let section = self?.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = headerView.defaultContentConfiguration()
            content.text = section.title
            headerView.contentConfiguration = content
        }
        
        // MARK: Provider
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .dict(let id, let inGroup):
                return collectionView.dequeueConfiguredReusableCell(using: dictReg, for: indexPath, item: (id, inGroup))
            case .emptyInGroup:
                return collectionView.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: "No dictionaries in this group")
            case .emptyAvailable:
                return collectionView.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: "All dictionaries added")
            }
        }
        
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
        
        // MARK: Reordering (inGroup section only)
        dataSource.reorderingHandlers.canReorderItem = { item in
            if case .dict(_, inGroup: true) = item { return true }
            return false
        }
        
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.commitReorder(transaction)
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
            applySnapshot()
        }
    }
    
    private func applySnapshot(animated: Bool = true) {
        let inGroupIds: [String]
        
        switch mode {
        case .empty:
            return
        case .creating:
            inGroupIds = session.pendingDictionaryIds
        case .managing(let groupId):
            guard let group = DictionaryService.shared.group(id: groupId) else { return }
            inGroupIds = group.dictionaryIds
        }
        
        let inGroupSet = Set(inGroupIds)
        let allDicts = DictionaryService.shared.allDictionaries
        
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
        
        dataSource.apply(snapshot, animatingDifferences: animated)
    }
    
    // MARK: - Actions
    
    /// Persist the new order after a drag-and-drop reorder in the inGroup section.
    private func commitReorder(_ transaction: NSDiffableDataSourceTransaction<Section, Item>) {
        // Extract the new order of dict IDs from the post-reorder snapshot
        let newOrder = transaction.finalSnapshot.itemIdentifiers(inSection: .inGroup).compactMap { item -> String? in
            if case .dict(let id, inGroup: true) = item { return id }
            return nil
        }
        
        guard !newOrder.isEmpty else { return }
        
        switch mode {
        case .creating:
            session.pendingDictionaryIds = newOrder
        case .managing(let groupId):
            do {
                try DictionaryService.shared.reorderDictionariesInGroup(groupId: groupId, newOrder: newOrder)
            } catch {
                debugLog("❌ Failed to reorder dicts: \(error)")
            }
        case .empty:
            break
        }
    }
    
    private func addDictionary(_ dictId: String) {
        switch mode {
        case .creating:
            session.pendingDictionaryIds.append(dictId)
            applySnapshot()
        case .managing(let groupId):
            do {
                try DictionaryService.shared.addDictionaryToGroup(groupId: groupId, dictId: dictId)
                applySnapshot()
            } catch {
                debugLog("❌ Failed to add dict to group: \(error)")
            }
        case .empty:
            break
        }
    }
    
    private func removeDictionary(_ dictId: String) {
        switch mode {
        case .creating:
            session.pendingDictionaryIds.removeAll { $0 == dictId }
            applySnapshot()
        case .managing(let groupId):
            do {
                try DictionaryService.shared.removeDictionaryFromGroup(groupId: groupId, dictId: dictId)
                applySnapshot()
            } catch {
                debugLog("❌ Failed to remove dict from group: \(error)")
            }
        case .empty:
            break
        }
    }
    
    // MARK: - Public API
    
    func showEmptyState() {
        mode = .empty
    }
    
    /// Show editor for an existing group (managing mode — immediate persist)
    func showEditor(for groupId: String) {
        mode = .managing(groupId: groupId)
    }
    
    /// Show editor for a new group (creating mode — writes to session only)
    func showCreatingEditor() {
        mode = .creating
    }
}

// MARK: - UICollectionViewDelegate

extension GroupDictionaryEditorViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
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
    }
}
