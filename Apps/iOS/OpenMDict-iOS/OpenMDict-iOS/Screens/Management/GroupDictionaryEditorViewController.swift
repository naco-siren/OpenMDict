//
//  GroupDictionaryEditorViewController.swift
//  OpenMDict-iOS
//
//  Third column in Group Management mode - add/remove dictionaries from a group.
//  Symmetric to DictResourceEditorViewController but for dictionary references.
//
//  Layout:
//  - Section "In This Group": dictionaries currently in the group (swipe to remove)
//  - Section "Available": dictionaries not in the group (tap to add)
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
    
    private enum Mode: Equatable {
        case empty
        case editing(groupId: String)
    }
    
    // MARK: - State
    
    private var mode: Mode = .empty {
        didSet {
            if oldValue != mode && isViewLoaded {
                reloadData()
            }
        }
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
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipeActions(for: indexPath)
        }
        
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.delegate = self
        
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
                // In group: filled book icon, checkmark
                content.image = UIImage(systemName: "book.closed.fill")
                content.imageProperties.tintColor = .systemBlue
                cell.accessories = [.checkmark()]
            } else {
                // Available: outlined book icon, plus indicator
                content.image = UIImage(systemName: "book.closed")
                content.imageProperties.tintColor = .secondaryLabel
                
                let plusImage = UIImageView(image: UIImage(systemName: "plus.circle.fill"))
                plusImage.tintColor = .systemGreen
                let accessory = UICellAccessory.customView(
                    configuration: .init(customView: plusImage, placement: .trailing())
                )
                cell.accessories = [accessory]
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
    }
    
    // MARK: - Data
    
    private func reloadData() {
        switch mode {
        case .empty:
            emptyStateView.isHidden = false
            collectionView.isHidden = true
            
        case .editing:
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            applySnapshot()
        }
    }
    
    private func applySnapshot(animated: Bool = true) {
        guard case .editing(let groupId) = mode,
              let group = DictionaryService.shared.group(id: groupId) else { return }
        
        let allDicts = DictionaryService.shared.allDictionaries
        let inGroupIds = Set(group.dictionaryIds)
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        
        // In group section
        let inGroupItems = group.dictionaryIds.map { Item.dict(id: $0, inGroup: true) }
        if inGroupItems.isEmpty {
            snapshot.appendItems([.emptyInGroup], toSection: .inGroup)
        } else {
            snapshot.appendItems(inGroupItems, toSection: .inGroup)
        }
        
        // Available section - all dicts NOT in this group
        let availableItems = allDicts
            .filter { !inGroupIds.contains($0.id) }
            .map { Item.dict(id: $0.id, inGroup: false) }
        if availableItems.isEmpty {
            snapshot.appendItems([.emptyAvailable], toSection: .available)
        } else {
            snapshot.appendItems(availableItems, toSection: .available)
        }
        
        dataSource.apply(snapshot, animatingDifferences: animated)
    }
    
    // MARK: - Swipe Actions
    
    private func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .dict(let dictId, let inGroup) = item,
              inGroup else {
            return nil
        }
        
        let removeAction = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
            self?.removeDictionary(dictId)
            completion(true)
        }
        removeAction.image = UIImage(systemName: "minus.circle.fill")
        
        return UISwipeActionsConfiguration(actions: [removeAction])
    }
    
    // MARK: - Actions
    
    private func addDictionary(_ dictId: String) {
        guard case .editing(let groupId) = mode else { return }
        
        do {
            try DictionaryService.shared.addDictionaryToGroup(groupId: groupId, dictId: dictId)
            applySnapshot()
        } catch {
            debugLog("❌ Failed to add dict to group: \(error)")
        }
    }
    
    private func removeDictionary(_ dictId: String) {
        guard case .editing(let groupId) = mode else { return }
        
        do {
            try DictionaryService.shared.removeDictionaryFromGroup(groupId: groupId, dictId: dictId)
            applySnapshot()
        } catch {
            debugLog("❌ Failed to remove dict from group: \(error)")
        }
    }
    
    // MARK: - Public API
    
    func showEmptyState() {
        mode = .empty
    }
    
    func showEditor(for groupId: String) {
        mode = .editing(groupId: groupId)
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
                // Tap on in-group dict → remove
                removeDictionary(dictId)
            } else {
                // Tap on available dict → add
                addDictionary(dictId)
            }
        case .emptyInGroup, .emptyAvailable:
            break
        }
    }
}
