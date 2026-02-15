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
    var onGroupInfoSelected: ((String) -> Void)?       // groupId
    var onAddGroupSelected: (() -> Void)?
    var onBookmarksSelected: (() -> Void)?
    var onLookupHistorySelected: (() -> Void)?
    var onManagePresetsSelected: (() -> Void)?
    
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
    
    /// Handle info button tap from group cell
    func didTapInfoButton(forGroupId groupId: String) {
        // Exit edit mode first
        setEditing(false, animated: true)
        // Then notify to show group info
        onGroupInfoSelected?(groupId)
    }
    
    // MARK: - Data
    
    private var groups: [MDicts] { DictionaryService.shared.groups }
    private var dataSource: UICollectionViewDiffableDataSource<Section, SidebarItem>!
    
    // MARK: - Subscriptions
    
    private var listChangeCancellable: AnyCancellable?
    private var groupsChangeCancellable: AnyCancellable?
    /// Subscriptions to individual MDict.$state (re-created when list changes)
    private var dictStateCancellables = Set<AnyCancellable>()
    /// Subscriptions to each MDicts.$items (re-created when groups change)
    private var groupItemsCancellables = Set<AnyCancellable>()
    
    private enum Section: Int, CaseIterable {
        case defaultGroup
        case userGroups
        case management
    }
    
    // MARK: - UI
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
        config.headerMode = .none
        
        // Trailing swipe: delete user groups
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self,
                  let item = self.dataSource?.itemIdentifier(for: indexPath),
                  case .group(let id, let isDefault) = item,
                  !isDefault else {
                return nil
            }
            
            let deleteAction = UIContextualAction(style: .destructive, title: L10n.delete) { [weak self] _, _, completion in
                self?.confirmDeleteGroup(id: id)
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
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.backButtonTitle = L10n.Sidebar.dictionaries
        
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

        // 2. Subscribe to group changes (groups added/removed/reordered)
        groupsChangeCancellable = DictionaryService.shared.$groups
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.subscribeToAllGroupItems()
                self?.applySnapshot(animated: true)
            }

        // 3. Subscribe to each dictionary's load state
        subscribeToAllDictionaryStates()
        
        // 4. Subscribe to each group's items (dictionaries added/removed within a group)
        subscribeToAllGroupItems()
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
    
    /// Subscribe to each group's $items changes (dictionaries added/removed within a group)
    /// Re-created when the groups array itself changes
    private func subscribeToAllGroupItems() {
        groupItemsCancellables.removeAll()
        
        for group in DictionaryService.shared.groups {
            group.$items
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.applySnapshot(animated: true)
                }
                .store(in: &groupItemsCancellables)
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
                
            case .importDictionary, .addGroup, .bookmarks, .lookupHistory,
                 .mgmtAddGroup, .mgmtImportDictionary, .managePresets, .settings:
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
        let userHeader = SidebarItem.header(L10n.Sidebar.myGroups, isBold: false)
        userSnapshot.append([userHeader])
        for group in userGroups {
            let groupItem = SidebarItem.group(id: group.id, isDefault: false)
            userSnapshot.append([groupItem], to: userHeader)
            let children = group.items.map { SidebarItem.dictionary(id: $0.id, groupId: group.id) }
            userSnapshot.append(children, to: groupItem)
            userSnapshot.expand([groupItem])
        }
        // "Add new group" - visible in edit mode or when no user groups exist
        if isEditing || userGroups.isEmpty {
            userSnapshot.append([.addGroup], to: userHeader)
        }
        userSnapshot.expand([userHeader])
        dataSource.apply(userSnapshot, to: .userGroups, animatingDifferences: animated)
        
        // Section 2: Management - with header
        var mgmtSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let mgmtHeader = SidebarItem.header(L10n.Sidebar.management, isBold: false)
        mgmtSnapshot.append([mgmtHeader])
        mgmtSnapshot.append([.bookmarks, .lookupHistory, .mgmtAddGroup, .mgmtImportDictionary, .managePresets, .settings], to: mgmtHeader)
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
    
    /// Programmatically select the Bookmarks sidebar item (called by keyboard shortcut)
    func selectBookmarksItem() {
        guard isViewLoaded,
              let indexPath = dataSource.indexPath(for: .bookmarks) else { return }
        // Deselect all other items
        for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
            if selectedIndexPath != indexPath {
                collectionView.deselectItem(at: selectedIndexPath, animated: false)
            }
        }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        activeGroupId = nil
        activeDict = nil
        invalidateVisibleCellConfigurations()
    }

    /// Programmatically select the Lookup History sidebar item (called by keyboard shortcut)
    func selectLookupHistoryItem() {
        guard isViewLoaded,
              let indexPath = dataSource.indexPath(for: .lookupHistory) else { return }
        // Deselect all other items
        for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
            if selectedIndexPath != indexPath {
                collectionView.deselectItem(at: selectedIndexPath, animated: false)
            }
        }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        activeGroupId = nil
        activeDict = nil
        invalidateVisibleCellConfigurations()
    }

    /// Programmatically select the management "Add New Group" sidebar item
    func selectMgmtAddGroupItem() {
        guard isViewLoaded,
              let indexPath = dataSource.indexPath(for: .mgmtAddGroup) else { return }
        for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
            if selectedIndexPath != indexPath {
                collectionView.deselectItem(at: selectedIndexPath, animated: false)
            }
        }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        activeGroupId = nil
        activeDict = nil
        invalidateVisibleCellConfigurations()
    }

    /// Programmatically select the management "Import Dictionary" sidebar item
    func selectMgmtImportItem() {
        guard isViewLoaded,
              let indexPath = dataSource.indexPath(for: .mgmtImportDictionary) else { return }
        for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
            if selectedIndexPath != indexPath {
                collectionView.deselectItem(at: selectedIndexPath, animated: false)
            }
        }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        activeGroupId = nil
        activeDict = nil
        invalidateVisibleCellConfigurations()
    }

    /// Deselect management-related items (called when switching back to lookup mode)
    func deselectManagementItems() {
        let items: [SidebarItem] = [.importDictionary, .mgmtImportDictionary, .mgmtAddGroup]
        for item in items {
            if let indexPath = dataSource.indexPath(for: item) {
                collectionView.deselectItem(at: indexPath, animated: true)
            }
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
                let message = dict.state == .loading ? L10n.loading : L10n.Sidebar.dictionaryNotLoaded
                print("⚠️ \(message): \(dict.metadata?.title ?? dict.id)")
                return false
            }
            return true
            
        case .importDictionary:
            // Import Dictionary is only visible in edit mode and should be selectable
            return true
            
        case .addGroup:
            // Add new group is visible in edit mode or when no user groups, always selectable
            return true
            
        case .bookmarks:
            // Bookmarks disabled in edit mode
            return !isEditing

        case .lookupHistory:
            // Lookup history disabled in edit mode
            return !isEditing

        case .mgmtAddGroup:
            // Management section redundant "Add New Group" — disabled in edit mode
            return !isEditing

        case .mgmtImportDictionary:
            // Management section redundant "Import Dictionary" — disabled in edit mode
            return !isEditing

        case .managePresets:
            // Management actions are disabled in edit mode
            return !isEditing

        case .settings:
            // Management actions are disabled in edit mode
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

            // Deselect self (action cell, not a navigation destination)
            collectionView.deselectItem(at: indexPath, animated: true)

            // Notify delegate to switch to management mode
            onImportDictionarySelected?()

        case .addGroup:
            // Exit edit mode first
            setEditing(false, animated: true)

            // Clear active state
            activeGroupId = nil
            activeDict = nil

            // Deselect all other items except this one
            for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
                if selectedIndexPath != indexPath {
                    collectionView.deselectItem(at: selectedIndexPath, animated: true)
                }
            }

            invalidateVisibleCellConfigurations()

            // Deselect self (action cell, not a navigation destination)
            collectionView.deselectItem(at: indexPath, animated: true)

            // Notify delegate to create and manage new group
            onAddGroupSelected?()
            
        case .bookmarks:
            // Navigation destination — keep selected, deselect others
            activeGroupId = nil
            activeDict = nil
            for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
                if selectedIndexPath != indexPath {
                    collectionView.deselectItem(at: selectedIndexPath, animated: true)
                }
            }
            invalidateVisibleCellConfigurations()
            onBookmarksSelected?()

        case .lookupHistory:
            // Navigation destination — keep selected, deselect others
            activeGroupId = nil
            activeDict = nil
            for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
                if selectedIndexPath != indexPath {
                    collectionView.deselectItem(at: selectedIndexPath, animated: true)
                }
            }
            invalidateVisibleCellConfigurations()
            onLookupHistorySelected?()

        case .mgmtAddGroup:
            // Management "Add New Group" — keep selected, deselect others
            activeGroupId = nil
            activeDict = nil
            for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
                if selectedIndexPath != indexPath {
                    collectionView.deselectItem(at: selectedIndexPath, animated: true)
                }
            }
            invalidateVisibleCellConfigurations()
            onAddGroupSelected?()

        case .mgmtImportDictionary:
            // Management "Import Dictionary" — keep selected, deselect others
            activeGroupId = nil
            activeDict = nil
            for selectedIndexPath in collectionView.indexPathsForSelectedItems ?? [] {
                if selectedIndexPath != indexPath {
                    collectionView.deselectItem(at: selectedIndexPath, animated: true)
                }
            }
            invalidateVisibleCellConfigurations()
            onImportDictionarySelected?()

        case .managePresets:
            collectionView.deselectItem(at: indexPath, animated: true)
            onManagePresetsSelected?()

        case .settings:
            collectionView.deselectItem(at: indexPath, animated: true)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
    
    // MARK: - Context Menu
    
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        
        switch item {
        case .group(let id, let isDefault) where !isDefault:
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                guard let self else { return UIMenu(children: []) }
                
                let editAction = UIAction(
                    title: L10n.Sidebar.editInfo,
                    image: UIImage(systemName: "info.circle")
                ) { _ in
                    self.onGroupInfoSelected?(id)
                }
                
                // Move Up / Move Down
                let userGroups = self.groups.filter { !$0.isDefault }
                let currentIndex = userGroups.firstIndex(where: { $0.id == id })
                
                let moveUpAction = UIAction(
                    title: L10n.Sidebar.moveUp,
                    image: UIImage(systemName: "arrow.up"),
                    attributes: currentIndex == 0 || currentIndex == nil ? .disabled : []
                ) { _ in
                    self.moveGroup(id: id, direction: .up)
                }
                
                let moveDownAction = UIAction(
                    title: L10n.Sidebar.moveDown,
                    image: UIImage(systemName: "arrow.down"),
                    attributes: currentIndex == (userGroups.count - 1) || currentIndex == nil ? .disabled : []
                ) { _ in
                    self.moveGroup(id: id, direction: .down)
                }
                
                let deleteAction = UIAction(
                    title: L10n.Sidebar.deleteGroup,
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    self.confirmDeleteGroup(id: id)
                }
                
                let moveMenu = UIMenu(title: "", options: .displayInline, children: [moveUpAction, moveDownAction])
                return UIMenu(children: [editAction, moveMenu, deleteAction])
            })
            
        case .group(let id, let isDefault) where isDefault:
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                let viewAction = UIAction(
                    title: L10n.Sidebar.viewInfo,
                    image: UIImage(systemName: "info.circle")
                ) { _ in
                    self?.onGroupInfoSelected?(id)
                }
                return UIMenu(children: [viewAction])
            })
            
        case .dictionary(let dictId, let groupId):
            // Context menu on dictionaries in default group: Edit Info
            let group = DictionaryService.shared.group(id: groupId)
            guard group?.isDefault == true else { return nil }
            
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                let editAction = UIAction(
                    title: L10n.Sidebar.editInfo,
                    image: UIImage(systemName: "info.circle")
                ) { _ in
                    self?.onDictionaryInfoSelected?(dictId)
                }
                return UIMenu(children: [editAction])
            })
            
        default:
            return nil
        }
    }
    
    // MARK: - Group Reorder
    
    private enum MoveDirection { case up, down }
    
    private func moveGroup(id: String, direction: MoveDirection) {
        var userGroupIds = groups.filter { !$0.isDefault }.map { $0.id }
        guard let index = userGroupIds.firstIndex(of: id) else { return }
        
        let targetIndex: Int
        switch direction {
        case .up:   targetIndex = index - 1
        case .down: targetIndex = index + 1
        }
        guard userGroupIds.indices.contains(targetIndex) else { return }
        
        userGroupIds.swapAt(index, targetIndex)
        
        DictionaryService.shared.reorderUserGroups(newOrder: userGroupIds)
        applySnapshot(animated: true)
    }
    
    // MARK: - Group Deletion
    
    private func confirmDeleteGroup(id: String) {
        let group = DictionaryService.shared.group(id: id)
        let groupName = group?.name ?? "this group"
        
        let alert = UIAlertController(
            title: L10n.Sidebar.deleteGroup,
            message: L10n.GroupInfo.deleteGroupMessage(name: groupName),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
            self?.performDeleteGroup(id: id)
        })
        present(alert, animated: true)
    }
    
    private func performDeleteGroup(id: String) {
        DictionaryService.shared.deleteGroup(id: id)
        applySnapshot(animated: true)
    }
}
