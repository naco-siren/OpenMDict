//
//  DictionaryListViewController.swift
//  OpenMDict-iOS
//
//  Sidebar with outline groups using custom cell subclasses.
//  Uses updateConfiguration(using:) pattern from WWDC 2020 "Modern cell configuration".
//
//  Key patterns:
//  1. Custom UICollectionViewListCell subclasses override updateConfiguration(using:)
//  2. Cells query state via SidebarStateProvider protocol (weak reference to VC)
//  3. State changes trigger setNeedsUpdateConfiguration() on visible cells
//  4. No reloadItems/reconfigureItems needed - cells update themselves
//

import UIKit

class DictionaryListViewController: UIViewController, SidebarStateProvider {
    
    // MARK: - Callbacks
    
    var onGroupSelected: ((DictionaryGroup) -> Void)?
    var onDictionarySelected: ((DictionaryItem) -> Void)?
    
    // MARK: - State (SidebarStateProvider)
    
    /// Currently active group (when a group is selected)
    private(set) var activeGroupId: String? = nil
    
    /// Currently active dictionary and whether it was selected via a mirror
    private(set) var activeDict: (id: String, mirrored: Bool)? = nil
    
    // MARK: - Data
    
    private var groups: [DictionaryGroup] = DictionaryGroup.mockData
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
        
        // Select default group on launch
        selectDefaultGroup()
    }
    
    private func selectDefaultGroup() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let defaultGroup = self.groups.first { $0.isDefault }!
            if let indexPath = self.dataSource.indexPath(for: .dictGroup(defaultGroup, isDefault: true)) {
                self.activeGroupId = defaultGroup.id
                self.collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                self.invalidateVisibleCellConfigurations()
                self.onGroupSelected?(defaultGroup)
            }
        }
    }
    
    // MARK: - Data Source Configuration
    
    private func configureDataSource() {
        
        // Default Group Cell (All Dictionaries)
        let defaultGroupReg = UICollectionView.CellRegistration<DefaultGroupCell, DictionaryGroup> {
            cell, indexPath, group in
            cell.group = group
            // No stateProvider needed - DefaultGroupCell doesn't query external state for icons
        }
        
        // User Group Cell
        let userGroupReg = UICollectionView.CellRegistration<UserGroupCell, DictionaryGroup> {
            [weak self] cell, indexPath, group in
            cell.group = group
            cell.stateProvider = self
        }
        
        // Default Group Dictionary Cell
        let defaultDictReg = UICollectionView.CellRegistration<DefaultGroupDictCell, (DictionaryItem, String)> {
            [weak self] cell, indexPath, tuple in
            let (dict, groupId) = tuple
            cell.dict = dict
            cell.groupId = groupId
            cell.stateProvider = self
        }
        
        // User Group Dictionary Cell (Mirror)
        let userDictReg = UICollectionView.CellRegistration<UserGroupDictCell, (DictionaryItem, String)> {
            [weak self] cell, indexPath, tuple in
            let (dict, groupId) = tuple
            cell.dict = dict
            cell.groupId = groupId
            cell.stateProvider = self
        }
        
        // Section Header Cell
        let headerReg = UICollectionView.CellRegistration<SidebarHeaderCell, (String, Bool)> {
            cell, indexPath, tuple in
            let (title, isBold) = tuple
            cell.title = title
            cell.isBold = isBold
        }
        
        // Management Action Cell
        let actionReg = UICollectionView.CellRegistration<ManagementActionCell, SidebarItem> {
            cell, indexPath, item in
            cell.item = item
        }
        
        // Create data source with cell provider
        dataSource = UICollectionViewDiffableDataSource<Section, SidebarItem>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .header(let title, let isBold):
                return collectionView.dequeueConfiguredReusableCell(
                    using: headerReg, for: indexPath, item: (title, isBold)
                )
                
            case .dictGroup(let group, let isDefault):
                return isDefault
                    ? collectionView.dequeueConfiguredReusableCell(
                        using: defaultGroupReg,
                        for: indexPath,
                        item: group
                    )
                    : collectionView.dequeueConfiguredReusableCell(
                        using: userGroupReg,
                        for: indexPath,
                        item: group
                    )
                
            case .dict(let dict, let group):
                return group.isDefault
                    ? collectionView.dequeueConfiguredReusableCell(
                        using: defaultDictReg, for: indexPath, item: (dict, group.id)
                    )
                    : collectionView.dequeueConfiguredReusableCell(
                        using: userDictReg, for: indexPath, item: (dict, group.id)
                    )
                
            case .importDict, .deleteDict, .settings:
                return collectionView.dequeueConfiguredReusableCell(
                    using: actionReg, for: indexPath, item: item
                )
            }
        }
    }
    
    // MARK: - Snapshot
    
    private func applySnapshot() {
        let defaultGroup = groups.first { $0.isDefault }!
        let userGroups = groups.filter { !$0.isDefault }
        
        // Section 0: Default Group (All Dictionaries) - no header wrapper
        var defaultSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let defaultGroupItem = SidebarItem.dictGroup(defaultGroup, isDefault: true)
        defaultSnapshot.append([defaultGroupItem])
        let defaultChildren = defaultGroup.dictionaries.map { SidebarItem.dict($0, group: defaultGroup) }
        defaultSnapshot.append(defaultChildren, to: defaultGroupItem)
        defaultSnapshot.expand([defaultGroupItem])
        dataSource.apply(defaultSnapshot, to: .defaultGroup, animatingDifferences: false)
        
        // Section 1: User Groups - with header
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
        
        // Section 2: Management - with header
        var mgmtSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let mgmtHeader = SidebarItem.header("Management", isBold: false)
        mgmtSnapshot.append([mgmtHeader])
        mgmtSnapshot.append([.importDict, .deleteDict, .settings], to: mgmtHeader)
        mgmtSnapshot.expand([mgmtHeader])
        dataSource.apply(mgmtSnapshot, to: .management, animatingDifferences: false)
    }
    
    // MARK: - State Update
    
    /// Invalidate all visible cells to trigger updateConfiguration(using:).
    /// This is the Apple-recommended approach instead of reloadItems/reconfigureItems.
    /// Each cell will re-query state from the provider and update itself.
    private func invalidateVisibleCellConfigurations() {
        for cell in collectionView.visibleCells {
            cell.setNeedsUpdateConfiguration()
        }
    }
}

// MARK: - UICollectionViewDelegate

extension DictionaryListViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        
        debugPrint("item: \(item)")
        
        return switch item {
        case .header:
            // Headers should not be selectable
            false
        case .dictGroup(let group, _):
            // Prevent re-selecting the same group
            activeGroupId != group.id
        case .dict(let dict, _):
            // Prevent re-selecting the same dictionary
            activeDict?.id != dict.id
        default:
            true
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .header:
            // Should not reach here due to shouldSelectItemAt
            break
            
        case .dictGroup(let group, _):
            // Update state
            activeGroupId = group.id
            activeDict = nil
            // Trigger cell updates
            invalidateVisibleCellConfigurations()
            // Notify delegate
            onGroupSelected?(group)
            
        case .dict(let dict, let group):
            // Update state - track if selection was via mirror
            activeGroupId = nil
            activeDict = (dict.id, !group.isDefault)
            // Trigger cell updates
            invalidateVisibleCellConfigurations()
            // Notify delegate
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
