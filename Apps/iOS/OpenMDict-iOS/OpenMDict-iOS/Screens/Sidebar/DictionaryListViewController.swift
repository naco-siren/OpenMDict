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
import Combine
import OpenMDictKit

class DictionaryListViewController: UIViewController, SidebarStateProvider {
    
    // MARK: - Callbacks
    
    var onGroupSelected: ((MDicts) -> Void)?
    var onDictionarySelected: ((MDict) -> Void)?
    var onImportDictionarySelected: (() -> Void)?
    var onDictionaryInfoSelected: ((String) -> Void)?  // dictId
    
    // MARK: - SidebarStateProvider
    
    /// Whether the sidebar is in edit mode
    var isEditingMode: Bool { isEditing }
    
    /// Current app mode (updated by MainSplitViewController)
    var appMode: AppMode = .lookup
    
    /// Currently active group (when a group is selected)
    private(set) var activeGroupId: String? = nil
    
    /// Currently active dictionary and whether it was selected via a mirror
    private(set) var activeDict: (id: String, mirrored: Bool)? = nil

    /// Handle info button tap from cell
    func didTapInfoButton(forDictId dictId: String) {
        // Guard: only allow info action for fully loaded dictionaries
        guard let dict = DictionaryService.shared.dict(id: dictId),
              dict.state == .loaded else {
            print("⚠️ Info action ignored: dictionary \(dictId.prefix(8))... not fully loaded")
            return
        }
        
        // Exit edit mode first
        setEditing(false, animated: true)
        // Then notify to show dictionary info
        onDictionaryInfoSelected?(dictId)
    }
    
    // MARK: - Data
    
    private var groups: [MDicts] { DictionaryService.shared.groups }
    private var dataSource: UICollectionViewDiffableDataSource<Section, SidebarItem>!
    
    // MARK: - Subscriptions
    
    private var listChangeCancellable: AnyCancellable?
    private var groupsChangeCancellable: AnyCancellable?
    /// Subscriptions to individual MDict.$state (re-created when list changes)
    private var dictStateCancellables = Set<AnyCancellable>()
    
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
        
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.backButtonTitle = "Dictionaries"
        
        title = "OpenMDict"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        
        // Edit button (system editButtonItem handles Edit/Done toggle)
        navigationItem.rightBarButtonItem = editButtonItem
        
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        configureDataSource()
        applySnapshot(animated: false)
        setupSubscriptions()
        
        // Apply any pending selection (set before view was loaded)
        applyPendingSelection()
    }
    
    /// Apply pending selection after snapshot is ready
    private func applyPendingSelection() {
        if let groupId = activeGroupId {
            // Find the group to determine if it's default
            let isDefault = groups.first(where: { $0.id == groupId })?.isDefault ?? false
            if let indexPath = dataSource.indexPath(for: .group(id: groupId, isDefault: isDefault)) {
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                invalidateVisibleCellConfigurations()
            }
        } else if let dictInfo = activeDict {
            // TODO: Handle pending dictionary selection if needed
            _ = dictInfo
        }
    }
    
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        applySnapshot(animated: animated)
        // Trigger cell updates so dict cells show/hide info button
        invalidateVisibleCellConfigurations()
    }
    
    // MARK: - State Subscriptions

    private func setupSubscriptions() {
        // 1. Subscribe to dictionary list changes (import/delete)
        listChangeCancellable = DictionaryService.shared.$allDictionaries
            .dropFirst()  // Skip initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDictionaryListChanged()
            }

        // 2. Subscribe to group changes
        groupsChangeCancellable = DictionaryService.shared.$groups
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshot(animated: true)
            }

        // 3. Subscribe to each dictionary's load state
        subscribeToAllDictionaryStates()
    }

    /// Handle dictionary list changes (import/delete)
    private func handleDictionaryListChanged() {
        // Re-subscribe to new list of dictionaries
        subscribeToAllDictionaryStates()
        // Refresh snapshot
        applySnapshot(animated: true)
    }

    /// Subscribe to all dictionaries' load state changes to update cell UI
    private func subscribeToAllDictionaryStates() {
        // Clear old subscriptions
        dictStateCancellables.removeAll()

        // Subscribe to each dictionary's $state
    
        for dict in DictionaryService.shared.allDictionaries {
            dict.$state
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.invalidateVisibleCellConfigurations()
                }
                .store(in: &dictStateCancellables)
        }
    }
    
    // MARK: - Data Source Configuration
    
    func setActiveGroup(_ group: MDicts) {
        activeGroupId = group.id
        activeDict = nil
        
        // Select corresponding cell if collectionView has already been loaded
        if isViewLoaded,
           let indexPath = dataSource.indexPath(for: .group(id: group.id, isDefault: group.isDefault)) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            invalidateVisibleCellConfigurations()
        }
    }
    
    func setActiveDictionary(_ dict: MDict) {
        activeGroupId = nil
        activeDict = (dict.id, false)

        guard isViewLoaded else { return }

        // Find the group containing this dictionary and select the cell
        for group in groups {
            if group.items.contains(where: { $0.id == dict.id }) {
                if let indexPath = dataSource.indexPath(for: .dictionary(id: dict.id, groupId: group.id)) {
                    collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                    invalidateVisibleCellConfigurations()
                    return
                }
            }
        }
    }
    
    private func configureDataSource() {
        
        // Default Group Cell (All Dictionaries)
        let defaultGroupReg = UICollectionView.CellRegistration<DefaultGroupCell, String> {
            [weak self] cell, indexPath, groupId in
            guard let group = self?.groups.first(where: { $0.id == groupId }) else { return }
            cell.group = group
            cell.stateProvider = self
        }
        
        // User Group Cell
        let userGroupReg = UICollectionView.CellRegistration<UserGroupCell, String> {
            [weak self] cell, indexPath, groupId in
            guard let group = self?.groups.first(where: { $0.id == groupId }) else { return }
            cell.group = group
            cell.stateProvider = self
        }
        
        // Default Group Dictionary Cell
        let defaultDictReg = UICollectionView.CellRegistration<DefaultGroupDictCell, (String, String)> {
            [weak self] cell, indexPath, tuple in
            let (dictId, groupId) = tuple
            guard let dict = DictionaryService.shared.dict(id: dictId) else { return }
            cell.dict = dict
            cell.groupId = groupId
            cell.stateProvider = self
        }
        
        // User Group Dictionary Cell (Mirror)
        let userDictReg = UICollectionView.CellRegistration<UserGroupDictCell, (String, String)> {
            [weak self] cell, indexPath, tuple in
            let (dictId, groupId) = tuple
            guard let dict = DictionaryService.shared.dict(id: dictId) else { return }
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
            [weak self] cell, indexPath, item in
            cell.item = item
            cell.stateProvider = self
        }
        
        // Create data source with cell provider
        dataSource = UICollectionViewDiffableDataSource<Section, SidebarItem>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .header(let title, let isBold):
                return collectionView.dequeueConfiguredReusableCell(
                    using: headerReg, for: indexPath, item: (title, isBold)
                )
                
            case .group(let id, let isDefault):
                return isDefault
                    ? collectionView.dequeueConfiguredReusableCell(
                        using: defaultGroupReg, for: indexPath, item: id
                    )
                    : collectionView.dequeueConfiguredReusableCell(
                        using: userGroupReg, for: indexPath, item: id
                    )
                
            case .dictionary(let dictId, let groupId):
                let group = DictionaryService.shared.group(id: groupId)
                let isDefault = group?.isDefault ?? false
                return isDefault
                    ? collectionView.dequeueConfiguredReusableCell(
                        using: defaultDictReg, for: indexPath, item: (dictId, groupId)
                    )
                    : collectionView.dequeueConfiguredReusableCell(
                        using: userDictReg, for: indexPath, item: (dictId, groupId)
                    )
                
            case .importDictionary, .settings:
                return collectionView.dequeueConfiguredReusableCell(
                    using: actionReg, for: indexPath, item: item
                )
            }
        }
    }
    
    // MARK: - Snapshot
    
    private func applySnapshot(animated: Bool) {
        guard let defaultGroup = groups.first(where: { $0.isDefault }) else {
            print("⚠️ No default group found")
            return
        }
        
        print("📋 applySnapshot - defaultGroup.items: \(defaultGroup.items.map { $0.id })")
        print("📋 applySnapshot - dictionaryIds: \(defaultGroup.dictionaryIds)")
        
        let userGroups = groups.filter { !$0.isDefault }
        
        // Section 0: Default Group (All Dictionaries) - no header wrapper
        var defaultSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let defaultGroupItem = SidebarItem.group(id: defaultGroup.id, isDefault: true)
        defaultSnapshot.append([defaultGroupItem])
        
        // Dictionary children
        var defaultChildren = defaultGroup.items.map { SidebarItem.dictionary(id: $0.id, groupId: defaultGroup.id) }
        
        // Add "Import Dictionary" at the end (only visible in Edit mode)
        if isEditing {
            defaultChildren.append(.importDictionary)
        }
        
        defaultSnapshot.append(defaultChildren, to: defaultGroupItem)
        defaultSnapshot.expand([defaultGroupItem])
        dataSource.apply(defaultSnapshot, to: .defaultGroup, animatingDifferences: animated)
        
        // Section 1: My Groups - with header
        var userSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let userHeader = SidebarItem.header("My Groups", isBold: false)
        userSnapshot.append([userHeader])
        for group in userGroups {
            let groupItem = SidebarItem.group(id: group.id, isDefault: false)
            userSnapshot.append([groupItem], to: userHeader)
            let children = group.items.map { SidebarItem.dictionary(id: $0.id, groupId: group.id) }
            userSnapshot.append(children, to: groupItem)
            userSnapshot.expand([groupItem])
        }
        userSnapshot.expand([userHeader])
        dataSource.apply(userSnapshot, to: .userGroups, animatingDifferences: animated)
        
        // Section 2: Management - with header
        var mgmtSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let mgmtHeader = SidebarItem.header("Management", isBold: false)
        mgmtSnapshot.append([mgmtHeader])
        mgmtSnapshot.append([.settings], to: mgmtHeader)
        mgmtSnapshot.expand([mgmtHeader])
        dataSource.apply(mgmtSnapshot, to: .management, animatingDifferences: animated)
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
    
    /// Deselect the import item (called when switching back to lookup mode)
    func deselectImportItem() {
        if let indexPath = dataSource.indexPath(for: .importDictionary) {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
    }
    
    /// Reload sidebar data (called after import/delete)
    func reloadData() {
        applySnapshot(animated: true)
    }
    
    /// Trigger all visible cells to update their configuration (e.g., when app mode changes)
    func setNeedsUpdateAllCells() {
        for cell in collectionView.visibleCells {
            cell.setNeedsUpdateConfiguration()
        }
    }
}

// MARK: - UICollectionViewDelegate

extension DictionaryListViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        
        switch item {
        case .header:
            // Headers should not be selectable
            return false
            
        case .group:
            // In edit mode, groups are not selectable (only drag reorder allowed)
            // Exit edit mode is only via Done button or navigating to a management action
            if isEditing {
                return false
            }
            return true
            
        case .dictionary(let dictId, _):
            // In edit mode, dictionaries are not selectable
            // (info button tap is handled separately, not via selection)
            if isEditing {
                return false
            }
            
            // Only allow selecting loaded dictionaries
            guard let dict = DictionaryService.shared.dict(id: dictId) else { return false }
            if dict.state != .loaded {
                let message = dict.state == .loading ? "Loading..." : "Dictionary not loaded"
                print("⚠️ \(message): \(dict.metadata?.title ?? dict.id)")
                return false
            }
            return true
            
        case .importDictionary:
            // Import Dictionary is only visible in edit mode and should be selectable
            return true
            
        case .settings:
            // Management actions (except importDictionary) are disabled in edit mode
            return !isEditing
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .header:
            // Should not reach here due to shouldSelectItemAt
            break
            
        case .group(let id, _):
            guard let group = DictionaryService.shared.group(id: id) else { return }
            // Update state
            activeGroupId = group.id
            activeDict = nil
            // Trigger cell updates
            invalidateVisibleCellConfigurations()
            // Notify delegate
            onGroupSelected?(group)
            
        case .dictionary(let dictId, let groupId):
            guard let dict = DictionaryService.shared.dict(id: dictId) else { return }
            // Note: unloaded dicts are already blocked by shouldSelectItemAt
            
            // Update state - track if selection was via mirror
            let group = DictionaryService.shared.group(id: groupId)
            let isMirror = !(group?.isDefault ?? true)
            activeGroupId = nil
            activeDict = (dict.id, isMirror)
            // Trigger cell updates
            invalidateVisibleCellConfigurations()
            // Notify delegate
            onDictionarySelected?(dict)
            
        case .importDictionary:
            // Exit edit mode first
            setEditing(false, animated: true)
            
            // Clear active state so other cells don't show as active
            activeGroupId = nil
            activeDict = nil

            // Deselect all other items except this one
            for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
                if selectedIndexPath != indexPath {
                    collectionView.deselectItem(at: selectedIndexPath, animated: true)
                }
            }

            // Trigger cell updates to remove active styling from other cells
            invalidateVisibleCellConfigurations()

            // Notify delegate to switch to management mode
            onImportDictionarySelected?()
            
        case .settings:
            collectionView.deselectItem(at: indexPath, animated: true)
            print("⚙️ App Settings - TODO")
        }
    }
}
