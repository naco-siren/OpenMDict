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
    
    /// Tracks which group is "active" for icon updates (separate from system selection)
    private var activeGroupId: String? = "all"
    
    private var dataSource: UICollectionViewDiffableDataSource<Section, SidebarItem>!
    
    private enum Section: Int, CaseIterable {
        case query
        case management
    }
    
    // MARK: - UI
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
        config.headerMode = .firstItemInSection
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
            if let firstGroupIndexPath = self.dataSource.indexPath(for: .group(self.groups[0])) {
                self.collectionView.selectItem(at: firstGroupIndexPath, animated: false, scrollPosition: [])
                self.onGroupSelected?(self.groups[0])
            }
        }
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        // Section header
        let headerReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, indexPath, title in
            var content = cell.defaultContentConfiguration()
            content.text = title
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure()]
        }
        
        // Group cell
        let groupReg = UICollectionView.CellRegistration<UICollectionViewListCell, DictionaryGroup> {
            [weak self] cell, indexPath, group in
            guard let self = self else { return }
            
            let isActive = self.activeGroupId == group.id
            
            var content = cell.defaultContentConfiguration()
            content.text = group.name
            content.image = UIImage(systemName: isActive ? "books.vertical.fill" : "books.vertical")
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure()]
            
            // Custom selection styling: blue background + white text
            cell.configurationUpdateHandler = { cell, state in
                debugPrint("groupReg: \(cell)")
                var content = UIListContentConfiguration.sidebarCell()
                content.text = group.name
                content.image = UIImage(
                    systemName: isActive
                        ? "books.vertical.fill" : "books.vertical"
                )
                if state.isSelected || state.isHighlighted {
                    content.textProperties.color = .white
                    content.imageProperties.tintColor = .white
                    var bg = UIBackgroundConfiguration.listSidebarCell()
                    bg.backgroundColor = .systemBlue
                    cell.backgroundConfiguration = bg
                } else {
                    cell.backgroundConfiguration =
                        UIBackgroundConfiguration.listSidebarCell()
                }
                cell.contentConfiguration = content
            }
        }
        
        // Dictionary cell
        let dictReg = UICollectionView.CellRegistration<UICollectionViewListCell, (DictionaryItem, String)> {
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
            
            // Custom selection styling: blue background + white text + open book
            cell.configurationUpdateHandler = { cell, state in
                debugPrint("dictReg: \(cell)")
                var content = UIListContentConfiguration.sidebarCell()
                content.text = dict.name
                if state.isSelected || state.isHighlighted {
                    content.image = UIImage(systemName: "book.fill")
                    content.textProperties.color = .white
                    content.imageProperties.tintColor = .white
                    var bg = UIBackgroundConfiguration.listSidebarCell()
                    bg.backgroundColor = .systemBlue
                    cell.backgroundConfiguration = bg
                } else {
                    content.image = UIImage(systemName: isParentActive ? "book.fill" : "book.closed")
                    if isParentActive {
                        content.imageProperties.tintColor = .systemBlue
                    }
                    cell.backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
                }
                cell.contentConfiguration = content
            }
        }
        
        // Action cell
        let actionReg = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarItem> { cell, indexPath, item in
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
            case .header(let title):
                return collectionView.dequeueConfiguredReusableCell(using: headerReg, for: indexPath, item: title)
            case .group(let g):
                return collectionView.dequeueConfiguredReusableCell(using: groupReg, for: indexPath, item: g)
            case .dictionary(let d, let gid):
                return collectionView.dequeueConfiguredReusableCell(using: dictReg, for: indexPath, item: (d, gid))
            case .importDict, .deleteDict, .settings:
                return collectionView.dequeueConfiguredReusableCell(using: actionReg, for: indexPath, item: item)
            }
        }
    }
    
    private func applySnapshot() {
        // Query section
        var querySnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let queryHeader = SidebarItem.header("Query")
        querySnapshot.append([queryHeader])
        
        for group in groups {
            let groupItem = SidebarItem.group(group)
            querySnapshot.append([groupItem], to: queryHeader)
            
            let children = group.dictionaries.map { SidebarItem.dictionary($0, groupId: group.id) }
            querySnapshot.append(children, to: groupItem)
            querySnapshot.expand([groupItem])
        }
        querySnapshot.expand([queryHeader])
        dataSource.apply(querySnapshot, to: .query, animatingDifferences: false)
        
        // Management section
        var mgmtSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let mgmtHeader = SidebarItem.header("Management")
        mgmtSnapshot.append([mgmtHeader])
        mgmtSnapshot.append([.importDict, .deleteDict, .settings], to: mgmtHeader)
        mgmtSnapshot.expand([mgmtHeader])
        dataSource.apply(mgmtSnapshot, to: .management, animatingDifferences: false)
    }
    
    private func reconfigureItems() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - UICollectionViewDelegate

extension DictionaryListViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .header:
            // Deselect headers - they shouldn't be selectable
            collectionView.deselectItem(at: indexPath, animated: false)
            
        case .group(let group):
            activeGroupId = group.id
            reconfigureItems()
            onGroupSelected?(group)
            
        case .dictionary(let dict, let groupId):
            if groupId == "all" {
                // Direct selection in All Dictionaries
                activeGroupId = nil  // No group active, just this dict
                reconfigureItems()
                onDictionarySelected?(dict)
            } else {
                // Clicked in a user group - jump to All Dictionaries
                collectionView.deselectItem(at: indexPath, animated: false)
                
                let targetItem = SidebarItem.dictionary(dict, groupId: "all")
                if let targetIndexPath = dataSource.indexPath(for: targetItem) {
                    activeGroupId = nil
                    reconfigureItems()
                    collectionView.selectItem(at: targetIndexPath, animated: true, scrollPosition: .centeredVertically)
                    onDictionarySelected?(dict)
                }
            }
            
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
