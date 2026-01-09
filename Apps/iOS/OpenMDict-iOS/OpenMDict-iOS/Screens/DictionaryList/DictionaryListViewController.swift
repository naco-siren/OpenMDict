//
//  DictionaryListViewController.swift
//  OpenMDict-iOS
//
//  Standard iOS 14+ sidebar with outline groups
//

import UIKit

class DictionaryListViewController: UIViewController {
    
    // MARK: - Callbacks
    
    var onGroupSelected: ((DictionaryGroup) -> Void)?
    var onDictionarySelected: ((DictionaryItem) -> Void)?
    
    // MARK: - Data
    
    private var groups: [DictionaryGroup] = DictionaryGroup.mockData
    
    /// Tracks which group is "active"
    private var activeGroupId: String? = nil

    /// Tracks with dictionary is "active", and whether it is mirrored
    private var activeDict: (id: String, mirrored: Bool)? = nil
    
    private var dataSource: UICollectionViewDiffableDataSource<Section, SidebarItem>!
    
    private enum Section: Int, CaseIterable {
        case defaultGroup
        case userGroups
        case management
    }
    
    // MARK: - UI
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
        config.headerMode = .none
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
        return cv
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "OpenMDict"
        navigationController?.navigationBar.prefersLargeTitles = true
        
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        configureDataSource()
        applySnapshot()
        
        // Select first group by default
        DispatchQueue.main.async {
            if let firstGroupIndexPath = self.dataSource.indexPath(for: .dictGroup(self.groups[0], isDefault: true)) {
                self.activeGroupId = self.groups[0].id
                self.collectionView.selectItem(at: firstGroupIndexPath, animated: false, scrollPosition: [])
                self.reconfigureItems()
                self.onGroupSelected?(self.groups[0])
            }
        }
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        // Section header
        let headerReg = UICollectionView.CellRegistration<UICollectionViewListCell, (String, Bool)> { cell, indexPath, tuple in
            let (title, isBold) = tuple
            var content = UIListContentConfiguration.sidebarHeader()
            content.text = title
            if isBold {
                content.textProperties.font = .systemFont(ofSize: 13, weight: .bold)
            }
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure()]
        }
        
        // Default group cell containing all the dictionaries
        let defaultGroupReg = UICollectionView.CellRegistration<UICollectionViewListCell, DictionaryGroup> { cell, indexPath, group in
            var content = UIListContentConfiguration.cell()
            content.text = group.name
            content.textProperties.font = .systemFont(ofSize: 17, weight: .semibold)
            content.image = UIImage(systemName: "books.vertical.fill")
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure()]

            // Custom selection styling
            cell.configurationUpdateHandler = { cell, state in
                var content = UIListContentConfiguration.cell()
                content.text = group.name
                content.textProperties.font = .systemFont(ofSize: 17, weight: .semibold)
                content.image = UIImage(systemName: "books.vertical.fill")
                if state.isSelected || state.isHighlighted {
                    content.textProperties.color = .white
                    content.imageProperties.tintColor = .white
                    var bg = UIBackgroundConfiguration.listSidebarCell()
                    bg.backgroundColor = .systemBlue
                    cell.backgroundConfiguration = bg
                } else {
                    cell.backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
                }
                cell.contentConfiguration = content
            }
        }

        // Default group's dictionary item cell
        let defaultGroupItemReg = UICollectionView.CellRegistration<UICollectionViewListCell, (DictionaryItem, String)> {
            [weak self] cell, indexPath, tuple in
            guard let self = self else { return }
            
            let (dict, groupId) = tuple
            let isParentActive = self.activeGroupId == groupId
            
            let (activeDictId, _) = self.activeDict ?? (nil, false)
            let isHighlighted = activeDictId == dict.id

            var content = cell.defaultContentConfiguration()
            content.text = dict.name
            content.image = UIImage(systemName: isParentActive ? "book.fill" : "book.closed.fill")
            cell.contentConfiguration = content
            cell.accessories = []

            // Custom selection styling + mirror highlight
            cell.configurationUpdateHandler = { cell, state in
                var content = UIListContentConfiguration.cell()
                content.text = dict.name
                if isParentActive {
                    content.image = UIImage(systemName: "book.fill")
                    content.imageProperties.tintColor = .systemBlue
                    cell.backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
                } else if state.isSelected || state.isHighlighted || isHighlighted {
                    content.image = UIImage(systemName: "book.fill")
                    content.imageProperties.tintColor = .white
                    content.textProperties.color = .white
                    var bg = UIBackgroundConfiguration.listSidebarCell()
                    bg.backgroundColor = .systemBlue
                    cell.backgroundConfiguration = bg
                } else {
                    content.image = UIImage(systemName: "book.closed.fill")
                    cell.backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
                }
                cell.contentConfiguration = content
            }
        }
        
        // User group cell
        let userGroupReg = UICollectionView.CellRegistration<UICollectionViewListCell, DictionaryGroup> { cell, indexPath, group in
            var content = UIListContentConfiguration.cell()
            content.text = group.name
            content.image = UIImage(systemName: "books.vertical")
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure()]
            
            // Custom selection styling
            cell.configurationUpdateHandler = { cell, state in
                var content = UIListContentConfiguration.cell()
                content.text = group.name
                content.image = UIImage(systemName: "books.vertical")
                if state.isSelected || state.isHighlighted {
                    content.textProperties.color = .white
                    content.imageProperties.tintColor = .white
                    var bg = UIBackgroundConfiguration.listSidebarCell()
                    bg.backgroundColor = .systemBlue
                    cell.backgroundConfiguration = bg
                } else {
                    cell.backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
                }
                cell.contentConfiguration = content
            }
        }
        
        // User groups' dictionary item cell
        let userGroupItemReg = UICollectionView.CellRegistration<UICollectionViewListCell, (DictionaryItem, String)> {
            [weak self] cell, indexPath, tuple in
            guard let self = self else { return }
            
            let (dict, groupId) = tuple
            let isParentActive = self.activeGroupId == groupId
            
            var content = cell.defaultContentConfiguration()
            content.text = dict.name
            content.image = UIImage(systemName: isParentActive ? "book.fill" : "book.closed")
            if isParentActive {
                content.imageProperties.tintColor = .systemBlue
            }
            cell.contentConfiguration = content
            cell.accessories = []
            
            // Custom selection styling + mirror highlight
            cell.configurationUpdateHandler = { cell, state in
                var content = UIListContentConfiguration.cell()
                content.text = dict.name
                if isParentActive {
                    content.image = UIImage(systemName: "book")
                    content.imageProperties.tintColor = .systemBlue
                } else if state.isSelected || state.isHighlighted {
                    content.image = UIImage(systemName: "book")
                    content.imageProperties.tintColor = .systemBlue
                    content.textProperties.color = .systemBlue
                } else {
                    content.image = UIImage(systemName: "book.closed")
                }
                cell.contentConfiguration = content
            }
        }
        
        // Mangament section's action cells
        let managementItemReg = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarItem> { cell, indexPath, item in
            var content = cell.defaultContentConfiguration()
            switch item {
            case .importDict:
                content.text = "Import Dictionary"
                content.image = UIImage(systemName: "square.and.arrow.down")
            case .deleteDict:
                content.text = "Delete Dictionaries"
                content.image = UIImage(systemName: "trash")
            case .settings:
                content.text = "App Settings"
                content.image = UIImage(systemName: "gearshape")
            default: break
            }
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        dataSource = UICollectionViewDiffableDataSource<Section, SidebarItem>(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .header(let title, let isBold):
            return collectionView.dequeueConfiguredReusableCell(using: headerReg, for: indexPath, item: (title, isBold))
            case .dictGroup(let g, let isAllDicts):
                if isAllDicts {
                    return collectionView.dequeueConfiguredReusableCell(using: defaultGroupReg, for: indexPath, item: g)
                } else {
                    return collectionView.dequeueConfiguredReusableCell(using: userGroupReg, for: indexPath, item: g)
                }
            case .dict(let d, let g):
                return collectionView.dequeueConfiguredReusableCell(using: g.isDefault ? defaultGroupItemReg : userGroupItemReg, for: indexPath, item: (d, g.id))
            case .importDict, .deleteDict, .settings:
                return collectionView.dequeueConfiguredReusableCell(using: managementItemReg, for: indexPath, item: item)
            }
        }
    }
    
    private func applySnapshot() {
        let allDictsGroup = groups.first { $0.id == "all" }!
        let userGroups = groups.filter { $0.id != "all" }

        // Section 0: All Dictionaries
        var allDictsSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let allDictsGroupItem = SidebarItem.dictGroup(allDictsGroup, isDefault: true)
        allDictsSnapshot.append([allDictsGroupItem])
        let allDictsChildren = allDictsGroup.dictionaries.map { SidebarItem.dict($0, group: allDictsGroup) }
        allDictsSnapshot.append(allDictsChildren, to: allDictsGroupItem)
        allDictsSnapshot.expand([allDictsGroupItem])
        dataSource.apply(allDictsSnapshot, to: .defaultGroup, animatingDifferences: false)

        // Section 1: User Groups
        var userSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let userHeader = SidebarItem.header("User Groups", isBold: false)
        userSnapshot.append([userHeader])
        for group in userGroups {
            let groupItem = SidebarItem.dictGroup(group, isDefault: false)
            userSnapshot.append([groupItem], to: userHeader)
            let children = group.dictionaries.map { SidebarItem.dict($0, group: group) }
            userSnapshot.append(children, to: groupItem)
            userSnapshot.expand([groupItem])
        }
        userSnapshot.expand([userHeader])
        dataSource.apply(userSnapshot, to: .userGroups, animatingDifferences: false)

        // Management section
        var mgmtSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let mgmtHeader = SidebarItem.header("Management", isBold: false)
        mgmtSnapshot.append([mgmtHeader])
        mgmtSnapshot.append([.importDict, .deleteDict, .settings], to: mgmtHeader)
        mgmtSnapshot.expand([mgmtHeader])
        dataSource.apply(mgmtSnapshot, to: .management, animatingDifferences: false)
    }
    
    private func reconfigureItems() {
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - UICollectionViewDelegate

extension DictionaryListViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        
        return switch item {
        case .header:
            false
        case .dict(let dict, _):
            self.activeDict?.id != dict.id
        default:
            true
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .header:
            // Unexpected branch: header shouldn't be selectable
            // collectionView.deselectItem(at: indexPath, animated: false)
            break
            
        case .dictGroup(let group, _):
            activeGroupId = group.id
            activeDict = nil
            reconfigureItems()
            onGroupSelected?(group)
            
        case .dict(let dict, let group):
            activeGroupId = nil
            activeDict = (dict.id, !group.isDefault)
            reconfigureItems()
            onDictionarySelected?(dict)
    
        case .importDict:
            collectionView.deselectItem(at: indexPath, animated: true)
            print("📥 Import dictionary - TODO")
            
        case .deleteDict:
            collectionView.deselectItem(at: indexPath, animated: true)
            print("🗑️ Delete dictionaries - TODO")
            
        case .settings:
            collectionView.deselectItem(at: indexPath, animated: true)
            print("⚙️ App Settings - TODO")
        }
    }
}
