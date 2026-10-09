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

import CloudKit
import Combine
import OpenMDictKit
import UIKit

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
    var onNewUserGuideSelected: (() -> Void)?
    var onChangeAppIconSelected: (() -> Void)?
    /// M15: "Article Search Indexing" tapped (row only shown on iOS 26+).
    var onArticleIndexSelected: (() -> Void)?
    var onTroubleshootSelected: (() -> Void)?
    var onAICoachSelected: (() -> Void)?
    /// DEBUG-only: M15 Phase 3.0.5 article-embedding POC entry. Wired by
    /// MainSplitViewController only under `#if DEBUG`; in release builds
    /// the management section never includes the `.articleEmbedPOC` row,
    /// so this callback is unreachable.
    var onArticleEmbedPOCSelected: (() -> Void)?

    // MARK: - Data Providers

    /// Dictionary/group data source. Defaults to production singleton.
    var dictionaryProvider: DictionaryDataProvider = DictionaryService.shared

    /// Dictionary metadata source. Defaults to production singleton.
    var metadataProvider: DictMetadataProvider = DictMetadataService.shared

    // MARK: - Compact Sidebar Mode

    /// When `true`, the sidebar is configured for compact tab bar mode:
    /// - Collection view top is pinned to safe area (fixes nav bar overlap in child VC context)
    /// - Management section is hidden (covered by the Management tab)
    /// Must be set **before** the view loads.
    var isCompactSidebarMode = false

    // MARK: - SidebarStateProvider

    /// Whether the sidebar is in edit mode
    var isEditingMode: Bool { isEditing }

    /// Current app mode (updated by MainSplitViewController)
    var appMode: AppMode = .lookup
    
    /// Currently active group (when a group is selected)
    private(set) var activeGroupId: String? = nil
    
    /// Currently active dictionary and whether it was selected via a mirror
    private(set) var activeDict: (id: String, mirrored: Bool)? = nil

    /// When true, relaxes guards that require `.loaded` state, hides iCloud status,
    /// and respects tutorial-specific collapse/expand state.
    var isTutorialMode = false

    /// When true, the "All Dictionaries" section is collapsed. Tutorial only.
    var tutorialDefaultGroupCollapsed = false

    /// When true, the "My Groups" section is collapsed. Tutorial only.
    /// Import tutorial: true (no user groups to show).
    /// Groups tutorial: false (show "Favorites" group).
    var tutorialMyGroupsCollapsed = true

    /// Expand the "All Dictionaries" section with animation. Tutorial only.
    func expandDefaultGroup(animated: Bool = true) {
        tutorialDefaultGroupCollapsed = false
        guard let defaultGroup = dictionaryProvider.groups.first(where: { $0.isDefault }) else { return }
        let item = SidebarItem.group(id: defaultGroup.id, isDefault: true)
        var snapshot = dataSource.snapshot(for: .defaultGroup)
        snapshot.expand([item])
        dataSource.apply(snapshot, to: .defaultGroup, animatingDifferences: animated)
    }

    /// Handle info button tap from cell
    func didTapInfoButton(forDictId dictId: String) {
        // Guard: only allow info action for fully loaded dictionaries
        guard let dict = dictionaryProvider.dict(id: dictId),
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

    // MARK: - iCloud Sync Status (SidebarStateProvider)

    func cloudSyncStatus(forDictId dictId: String) -> CloudSyncStatus? {
        guard !isTutorialMode else { return nil }
        guard SyncModeService.shared.isCloudSyncEnabled else { return nil }
        guard let metadata = metadataProvider.find(dictId: dictId) else { return nil }
        // If the dict is currently downloading files from CloudKit, show as pending
        // (in-memory flag — not written to CoreData to avoid CloudKit export ping-pong).
        if metadataProvider.downloadingDictIds.contains(dictId) {
            return .pending
        }
        let status = CloudSyncStatus(rawValue: metadata.cloudSyncStatus) ?? .pending
        // Synced in iCloud but not loaded on this device yet (queued for
        // download after a fresh install or a mirroring reset): the files are
        // on their way, so show it as syncing rather than "ready".
        if status == .synced && dictionaryProvider.dict(id: dictId) == nil {
            return .pending
        }
        return status
    }

    func iCloudSectionStatus() -> ICloudSectionStatus? {
        guard !isTutorialMode else { return nil }
        guard SyncModeService.shared.isCloudSyncEnabled else { return nil }
        guard let accountStatus = cachedAccountStatus else { return nil }

        // Start with account-level baseline.
        // Priority: error > temporaryIssue > syncing > healthy
        // More severe dict-level issues can escalate the baseline.
        var worst: ICloudSectionStatus
        switch accountStatus {
        case .noAccount, .restricted:
            return .error
        case .temporarilyUnavailable, .couldNotDetermine:
            worst = .temporaryIssue
        case .available:
            worst = .healthy
        @unknown default:
            worst = .temporaryIssue
        }

        // Check child dict statuses — may escalate to .error
        let allMetadata = metadataProvider.loadAll()
        let downloading = metadataProvider.downloadingDictIds
        for metadata in allMetadata {
            let s = CloudSyncStatus(rawValue: metadata.cloudSyncStatus)
            if s == .error || s == .tooLarge { return .error }
            if (s == .pending || downloading.contains(metadata.dictId)) && worst == .healthy {
                worst = .syncing
            }
        }
        return worst
    }

    func iCloudGroupStatus(forGroupId groupId: String) -> ICloudSectionStatus? {
        guard !isTutorialMode else { return nil }
        guard SyncModeService.shared.isCloudSyncEnabled else { return nil }

        // Check child dicts in this group.
        // Priority: error/tooLarge > pending/downloading (syncing) > healthy
        guard let group = dictionaryProvider.group(id: groupId) else { return .healthy }
        let downloading = metadataProvider.downloadingDictIds
        var hasPending = false
        for dict in group.items {
            guard let metadata = metadataProvider.find(dictId: dict.id) else { continue }
            let s = CloudSyncStatus(rawValue: metadata.cloudSyncStatus)
            if s == .error || s == .tooLarge { return .error }
            if s == .pending || downloading.contains(dict.id) { hasPending = true }
        }
        return hasPending ? .syncing : .healthy
    }

    func iCloudMyGroupsSectionStatus() -> ICloudSectionStatus? {
        guard !isTutorialMode else { return nil }
        guard SyncModeService.shared.isCloudSyncEnabled else { return nil }

        // Start with account-level baseline.
        // Priority: error > temporaryIssue > syncing > healthy
        var worst: ICloudSectionStatus = .healthy
        if let accountStatus = cachedAccountStatus {
            switch accountStatus {
            case .noAccount, .restricted:
                return .error
            case .temporarilyUnavailable, .couldNotDetermine:
                worst = .temporaryIssue
            case .available:
                break
            @unknown default:
                worst = .temporaryIssue
            }
        }

        // Aggregate per-group statuses — may escalate the baseline.
        let userGroups = dictionaryProvider.groups.dropFirst() // skip default group
        for group in userGroups {
            guard let groupStatus = iCloudGroupStatus(forGroupId: group.id) else { continue }
            switch groupStatus {
            case .error:       return .error
            case .syncing:
                if worst == .healthy { worst = .syncing }
            case .temporaryIssue, .healthy:
                break
            }
        }
        return worst
    }

    func didTapSyncStatus(forDictId dictId: String) {
        guard let status = cloudSyncStatus(forDictId: dictId) else { return }
        let dict = dictionaryProvider.dict(id: dictId)
        let dictName = dict?.preferredTitle ?? dictId.prefix(16).description
        let metadata = metadataProvider.find(dictId: dictId)

        let title: String
        let message: String
        switch status {
        case .synced:
            title = L10n.SyncStatus.syncedTitle
            message = L10n.SyncStatus.syncedDictMessage(name: dictName)
        case .pending:
            title = L10n.SyncStatus.syncingTitle
            message = L10n.SyncStatus.syncingMessage(name: dictName)
        case .tooLarge:
            title = L10n.SyncStatus.cannotSyncTitle
            let sizeString = Self.formattedSize(kb: metadata?.totalSizeKB ?? 0)
            message = L10n.SyncStatus.cannotSyncTooLargeMessage(name: dictName, size: sizeString)
        case .error:
            title = L10n.SyncStatus.syncErrorTitle
            message = L10n.SyncStatus.syncErrorMessage(name: dictName)
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }

    func didTapSectionSyncStatus() {
        guard let status = iCloudSectionStatus() else { return }
        let title: String
        let message: String
        switch status {
        case .healthy:
            title = L10n.SyncStatus.iCloudHealthyTitle
            message = L10n.SyncStatus.iCloudHealthyMessage
        case .syncing:
            title = L10n.SyncStatus.iCloudSyncingTitle
            message = L10n.SyncStatus.iCloudSyncingMessage
        case .temporaryIssue, .error:
            title = L10n.SyncStatus.iCloudIssueTitle
            message = L10n.SyncStatus.iCloudIssueMessage
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }

    func didTapMyGroupsSyncStatus() {
        guard let status = iCloudMyGroupsSectionStatus() else { return }
        let title: String
        let message: String
        switch status {
        case .healthy:
            title = L10n.SyncStatus.iCloudHealthyTitle
            let userGroups = dictionaryProvider.groups.filter { !$0.isDefault }
            message = userGroups.isEmpty
                ? L10n.SyncStatus.iCloudNoGroupsMessage
                : L10n.SyncStatus.iCloudGroupsHealthyMessage
        case .syncing:
            title = L10n.SyncStatus.iCloudSyncingTitle
            message = L10n.SyncStatus.iCloudSyncingMessage
        case .temporaryIssue, .error:
            title = L10n.SyncStatus.iCloudIssueTitle
            message = L10n.SyncStatus.iCloudIssueMessage
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }

    func didTapGroupSyncStatus(forGroupId groupId: String) {
        let group = dictionaryProvider.group(id: groupId)
        let groupName = group?.name ?? groupId.prefix(16).description
        let status = iCloudGroupStatus(forGroupId: groupId) ?? .healthy

        let title: String
        let message: String
        switch status {
        case .healthy:
            title = L10n.SyncStatus.syncedTitle
            message = L10n.SyncStatus.syncedGroupMessage(name: groupName)
        case .syncing:
            title = L10n.SyncStatus.iCloudSyncingTitle
            message = L10n.SyncStatus.iCloudSyncingMessage
        case .temporaryIssue, .error:
            title = L10n.SyncStatus.iCloudIssueTitle
            message = L10n.SyncStatus.iCloudIssueMessage
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }

    /// Format KB size into a human-readable string (e.g. "323.76 MB")
    private static func formattedSize(kb: Int64) -> String {
        let bytes = Double(kb) * 1024
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Data
    
    private var groups: [MDicts] { dictionaryProvider.groups }
    private var dataSource: UICollectionViewDiffableDataSource<Section, SidebarItem>!
    
    // MARK: - Subscriptions
    
    private var listChangeCancellable: AnyCancellable?
    private var groupsChangeCancellable: AnyCancellable?
    /// Subscriptions to individual MDict.$state (re-created when list changes)
    private var dictStateCancellables = Set<AnyCancellable>()
    /// Subscriptions to each MDicts.$items (re-created when groups change)
    private var groupItemsCancellables = Set<AnyCancellable>()
    /// Subscription to dictionary display name changes (remote renames)
    private var displayNameCancellable: AnyCancellable?
    /// Subscription to DictMetadataService revision (cloudSyncStatus changes)
    private var metadataRevisionCancellable: AnyCancellable?

    /// Cached CKAccountStatus for iCloud health indicator on section headers.
    /// Defaults to `.available` (optimistic) so the first cell render already
    /// shows an iCloud icon; `refreshCKAccountStatus()` corrects it async.
    private var cachedAccountStatus: CKAccountStatus? = {
        SyncModeService.shared.isCloudSyncEnabled ? .available : nil
    }()

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
        
        // In compact sidebar mode the nav controller is a manually-added child VC
        // of the tab bar controller (via addChild), NOT one of its managed tabs.
        // UITabBarController only propagates safe area to its own viewControllers,
        // so the nav bar height never reaches this VC's safeAreaInsets.
        // Setting edgesForExtendedLayout = [] tells the UINavigationController to
        // place this VC's view BELOW the nav bar instead of behind it — this changes
        // the view frame directly and doesn't rely on safe area propagation.
        if isCompactSidebarMode {
            edgesForExtendedLayout = []
        }

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
    
    /// Called when editing mode changes (tutorial uses this to detect Edit button tap).
    var onEditingChanged: ((Bool) -> Void)?

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        onEditingChanged?(editing)
        applySnapshot(animated: animated)
        invalidateVisibleCellConfigurations()
    }
    
    // MARK: - State Subscriptions

    private func setupSubscriptions() {
        // 1. Subscribe to dictionary list changes (import/delete)
        listChangeCancellable = dictionaryProvider.allDictionariesPublisher
            .dropFirst()  // Skip initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDictionaryListChanged()
            }

        // 2. Subscribe to group changes (groups added/removed/reordered/renamed via iCloud)
        //    reloadGroupsFromCoreData() replaces the groups array with new MDicts
        //    instances.  applySubscriptionSnapshot() handles structural changes
        //    (add/remove), but when only a name changed the snapshot signature is
        //    identical → refreshGroupAndDictCells() re-binds the live references.
        groupsChangeCancellable = dictionaryProvider.groupsPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.subscribeToAllGroupItems()
                self?.applySubscriptionSnapshot()
                self?.refreshGroupAndDictCells()
            }

        // 3. Subscribe to each dictionary's load state
        subscribeToAllDictionaryStates()
        
        // 4. Subscribe to each group's items (dictionaries added/removed within a group)
        subscribeToAllGroupItems()

        // 5. Subscribe to display name changes (group renames, remote dict renames)
        displayNameCancellable = dictionaryProvider.displayNameRevisionPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshGroupAndDictCells()
            }

        // 6. Subscribe to metadata revision (cloudSyncStatus changes after upload/download)
        metadataRevisionCancellable = metadataProvider.revisionPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateVisibleCellConfigurations()
            }

        // 7. Refresh CKAccountStatus — always register the observer so
        //    it fires even when cloud sync is enabled *after* initial setup
        //    (e.g. user picks iCloud during the setup flow, CoreData reloads
        //    with CloudKit=true, but this VC was created when it was false).
        refreshCKAccountStatus()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDidBecomeActive),
            name: UIScene.didActivateNotification, object: nil
        )
    }

    @objc private func handleDidBecomeActive() {
        refreshCKAccountStatus()
        // M14 POC: the AI Coach sidebar row is gated by a Settings.bundle
        // toggle the user flips outside the app. When they come back,
        // rebuild the snapshot so the row appears/disappears immediately
        // — `applySubscriptionSnapshot()` is cheap when the signature is
        // unchanged (cached `lastSnapshotSignature` short-circuits the
        // outline apply), so this is safe to call unconditionally.
        debugLog("🪄 sidebar didBecomeActive → \(AICoach.diagnosticSummary)")
        applySubscriptionSnapshot()
    }

    /// Async-check CKAccountStatus and cache the result.
    /// Safe to call even when cloud sync is disabled — bails out early.
    private func refreshCKAccountStatus() {
        guard SyncModeService.shared.isCloudSyncEnabled else {
            // Cloud sync was turned off (or never on).  Nil out cached status
            // so iCloud icons disappear.
            if cachedAccountStatus != nil {
                cachedAccountStatus = nil
                invalidateVisibleCellConfigurations()
            }
            return
        }
        Task {
            let container = CKContainer(identifier: AppIdentifiers.cloudKitContainerID)
            let status = try? await container.accountStatus()
            self.cachedAccountStatus = status ?? .couldNotDetermine
            self.invalidateVisibleCellConfigurations()
        }
    }

    /// Handle dictionary list changes (import/delete)
    private func handleDictionaryListChanged() {
        // Re-subscribe to new list of dictionaries
        subscribeToAllDictionaryStates()
        // Refresh CK account status — covers the case where cloud sync was
        // enabled mid-session (setup flow: CoreData reloads with CloudKit=true)
        refreshCKAccountStatus()
        // Schedule coalesced snapshot (may overlap with $groups / $items fires)
        applySubscriptionSnapshot()
    }

    /// Subscribe to all dictionaries' load state changes to update cell UI
    private func subscribeToAllDictionaryStates() {
        // Clear old subscriptions
        dictStateCancellables.removeAll()

        // Subscribe to each dictionary's $state
    
        for dict in dictionaryProvider.allDictionaries {
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

        for group in dictionaryProvider.groups {
            group.$items
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.applySubscriptionSnapshot()
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
            guard let dict = self?.dictionaryProvider.dict(id: dictId) else { return }
            cell.dict = dict
            cell.groupId = groupId
            cell.stateProvider = self
        }

        // User Group Dictionary Cell (Mirror)
        let userDictReg = UICollectionView.CellRegistration<UserGroupDictCell, (String, String)> {
            [weak self] cell, indexPath, tuple in
            let (dictId, groupId) = tuple
            guard let dict = self?.dictionaryProvider.dict(id: dictId) else { return }
            cell.dict = dict
            cell.groupId = groupId
            cell.stateProvider = self
        }
        
        // Section Header Cell
        let headerReg = UICollectionView.CellRegistration<SidebarHeaderCell, (String, Bool, Bool)> {
            [weak self] cell, indexPath, tuple in
            let (title, isBold, showsSyncStatus) = tuple
            cell.title = title
            cell.isBold = isBold
            cell.showsSyncStatus = showsSyncStatus
            cell.stateProvider = self
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
                // "My Groups" header shows iCloud sync status; "Management" does not.
                let showsSyncStatus = (title == L10n.Sidebar.myGroups)
                return collectionView.dequeueConfiguredReusableCell(
                    using: headerReg, for: indexPath, item: (title, isBold, showsSyncStatus)
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
                let group = self.dictionaryProvider.group(id: groupId)
                let isDefault = group?.isDefault ?? false
                return isDefault
                    ? collectionView.dequeueConfiguredReusableCell(
                        using: defaultDictReg, for: indexPath, item: (dictId, groupId)
                    )
                    : collectionView.dequeueConfiguredReusableCell(
                        using: userDictReg, for: indexPath, item: (dictId, groupId)
                    )
                
            case .importDictionary, .addGroup, .bookmarks, .lookupHistory,
                 .mgmtAddGroup, .mgmtImportDictionary, .managePresets,
                 .newUserGuide, .changeAppIcon, .iCloudTroubleshoot, .aiCoach,
                 .articleEmbedPOC, .articleIndex, .settings:
                return collectionView.dequeueConfiguredReusableCell(
                    using: actionReg, for: indexPath, item: item
                )
            }
        }
    }
    
    // MARK: - Snapshot

    /// Cached item identifiers from the last snapshot apply.
    /// Used to skip redundant `dataSource.apply` calls — applying an identical
    /// section snapshot to an outline parent (DefaultGroupCell) causes UIKit to
    /// reset its accessories, which makes the iCloud button disappear.
    private var lastSnapshotSignature: [Section: [SidebarItem]] = [:]

    /// Handle subscription-driven updates.
    /// If the structural items haven't changed, just invalidate visible cell
    /// configurations (cheap, preserves accessories). Only rebuild the full
    /// snapshot when items actually differ (import/delete/reorder).
    private func applySubscriptionSnapshot() {
        let signature = buildSnapshotSignature()
        if signature == lastSnapshotSignature {
            // Items unchanged — only cell content (sync status, display name) changed.
            invalidateVisibleCellConfigurations()
            return
        }
        applySnapshot(animated: false)
    }

    /// Build a lightweight signature of what the next snapshot would contain.
    private func buildSnapshotSignature() -> [Section: [SidebarItem]] {
        guard let defaultGroup = groups.first(where: { $0.isDefault }) else { return [:] }
        let userGroups = groups.filter { !$0.isDefault }

        var defaultItems: [SidebarItem] = [.group(id: defaultGroup.id, isDefault: true)]
        defaultItems += defaultGroup.items.map { .dictionary(id: $0.id, groupId: defaultGroup.id) }
        if isEditing || defaultGroup.items.isEmpty { defaultItems.append(.importDictionary) }

        var userItems: [SidebarItem] = [.header(L10n.Sidebar.myGroups, isBold: false)]
        for group in userGroups {
            userItems.append(.group(id: group.id, isDefault: false))
            userItems += group.items.map { .dictionary(id: $0.id, groupId: group.id) }
        }
        if isEditing || userGroups.isEmpty { userItems.append(.addGroup) }

        let mgmtItems: [SidebarItem]
        if isCompactSidebarMode {
            mgmtItems = []
        } else {
            var actions: [SidebarItem] = [
                .header(L10n.Sidebar.management, isBold: false),
            ]
            // M14 POC: AI Coach sits at the top of the Management section
            // when enabled — it's the most prominent new capability and we
            // want users to find it first.
            if AICoach.isVisible {
                actions.append(.aiCoach)
            }
            actions.append(contentsOf: [
                .bookmarks, .lookupHistory, .mgmtAddGroup, .mgmtImportDictionary, .managePresets,
                .newUserGuide, .iCloudTroubleshoot, .changeAppIcon,
            ])
            // M15: article-content search indexing (iOS 26+ + feature available).
            // MUST match applySnapshot()'s condition exactly, or the
            // signature-diff skip-logic falsely no-ops and resets accessories.
            if ArticleIndexCoordinator.shared.isAvailable {
                actions.append(.articleIndex)
            }
            actions.append(.settings)
            mgmtItems = actions
        }

        return [.defaultGroup: defaultItems, .userGroups: userItems, .management: mgmtItems]
    }

    func applySnapshot(animated: Bool) {
        guard let defaultGroup = groups.first(where: { $0.isDefault }) else {
            return
        }
        
        let userGroups = groups.filter { !$0.isDefault }
        
        // Section 0: Default Group (All Dictionaries) - no header wrapper
        var defaultSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
        let defaultGroupItem = SidebarItem.group(id: defaultGroup.id, isDefault: true)
        defaultSnapshot.append([defaultGroupItem])
        
        // Dictionary children
        var defaultChildren = defaultGroup.items.map { SidebarItem.dictionary(id: $0.id, groupId: defaultGroup.id) }
        
        // Add "Import Dictionary" at the end (visible in Edit mode or when no dicts exist)
        if isEditing || defaultGroup.items.isEmpty {
            defaultChildren.append(.importDictionary)
        }
        
        defaultSnapshot.append(defaultChildren, to: defaultGroupItem)
        if !(isTutorialMode && tutorialDefaultGroupCollapsed) {
            defaultSnapshot.expand([defaultGroupItem])
        }
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
        if !(isTutorialMode && tutorialMyGroupsCollapsed) {
            userSnapshot.expand([userHeader])
        }
        dataSource.apply(userSnapshot, to: .userGroups, animatingDifferences: animated)
        
        // Section 2: Management - with header (hidden in compact sidebar mode
        // because all management actions live in the dedicated Management tab).
        if isCompactSidebarMode {
            // Apply an empty section snapshot to clear any existing management items
            let emptyMgmt = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
            dataSource.apply(emptyMgmt, to: .management, animatingDifferences: animated)
        } else {
            var mgmtSnapshot = NSDiffableDataSourceSectionSnapshot<SidebarItem>()
            let mgmtHeader = SidebarItem.header(L10n.Sidebar.management, isBold: false)
            mgmtSnapshot.append([mgmtHeader])
            var mgmtChildren: [SidebarItem] = []
            // M14 POC: AI Coach at the top of the section when enabled.
            if AICoach.isVisible {
                mgmtChildren.append(.aiCoach)
            }
            mgmtChildren.append(contentsOf: [
                .bookmarks, .lookupHistory, .mgmtAddGroup, .mgmtImportDictionary, .managePresets,
                .newUserGuide, .iCloudTroubleshoot, .changeAppIcon,
            ])
            // M15: article-content search indexing (iOS 26+ + feature available).
            // MUST match buildSnapshotSignature()'s condition exactly.
            if ArticleIndexCoordinator.shared.isAvailable {
                mgmtChildren.append(.articleIndex)
            }
            mgmtChildren.append(.settings)
            // M15 Phase 3.0.5 article-embedding POC entry. DEBUG-only; never
            // appears in Release builds. Tap routes to ArticleEmbedPOCViewController.
            #if DEBUG
            mgmtChildren.append(.articleEmbedPOC)
            #endif
            mgmtSnapshot.append(mgmtChildren, to: mgmtHeader)
            mgmtSnapshot.expand([mgmtHeader])
            dataSource.apply(mgmtSnapshot, to: .management, animatingDifferences: animated)
        }

        // Cache the signature so applySubscriptionSnapshot() can skip
        // redundant applies that would cause UIKit to reset accessories
        // on outline parent items (DefaultGroupCell iCloud button bug).
        lastSnapshotSignature = buildSnapshotSignature()
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

    /// Refresh group and dictionary cells by re-binding their data references.
    ///
    /// `setNeedsUpdateConfiguration()` alone is not reliable for outline-
    /// disclosure parent cells (UIKit may skip `updateConfiguration` when
    /// the cell configuration state hasn't changed).  Work around this by
    /// re-assigning the live `MDicts`/`MDict` reference on each visible cell,
    /// then calling `updateConfiguration(using:)` directly.
    private func refreshGroupAndDictCells() {
        for cell in collectionView.visibleCells {
            if let groupCell = cell as? UserGroupCell,
               let group = groupCell.group,
               let fresh = dictionaryProvider.group(id: group.id) {
                groupCell.group = fresh
                groupCell.updateConfiguration(using: groupCell.configurationState)
            } else if let groupCell = cell as? DefaultGroupCell,
                      let group = groupCell.group,
                      let fresh = dictionaryProvider.group(id: group.id) {
                groupCell.group = fresh
                groupCell.updateConfiguration(using: groupCell.configurationState)
            } else if let dictCell = cell as? DefaultGroupDictCell,
                      let dict = dictCell.dict,
                      let fresh = dictionaryProvider.dict(id: dict.id) {
                dictCell.dict = fresh
                dictCell.updateConfiguration(using: dictCell.configurationState)
            } else if let dictCell = cell as? UserGroupDictCell,
                      let dict = dictCell.dict,
                      let fresh = dictionaryProvider.dict(id: dict.id) {
                dictCell.dict = fresh
                dictCell.updateConfiguration(using: dictCell.configurationState)
            } else {
                cell.setNeedsUpdateConfiguration()
            }
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

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Ensure cells pick up current state (editing, selection, sync status)
        // when scrolling into view — invalidateVisibleCellConfigurations()
        // only updates cells already on screen.
        cell.setNeedsUpdateConfiguration()
    }

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
            guard let dict = dictionaryProvider.dict(id: dictId) else { return false }
            if dict.state != .loaded {
                let message = dict.state == .loading ? L10n.loading : L10n.Sidebar.dictionaryNotLoaded
                print("⚠️ \(message): \(dict.metadata?.title ?? dict.id)")
                return false
            }
            return true
            
        case .importDictionary:
            // Import Dictionary: visible in edit mode or when no dicts exist
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

        case .newUserGuide:
            return !isEditing

        case .changeAppIcon:
            return !isEditing

        case .iCloudTroubleshoot:
            return !isEditing

        case .aiCoach:
            return !isEditing

        case .articleEmbedPOC:
            return !isEditing

        case .articleIndex:
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
            guard let group = dictionaryProvider.group(id: id) else { return }
            // Update state
            activeGroupId = group.id
            activeDict = nil
            // Trigger cell updates
            invalidateVisibleCellConfigurations()
            // Notify delegate
            onGroupSelected?(group)
            
        case .dictionary(let dictId, let groupId):
            guard let dict = dictionaryProvider.dict(id: dictId) else { return }
            // Note: unloaded dicts are already blocked by shouldSelectItemAt
            
            // Update state - track if selection was via mirror
            let group = dictionaryProvider.group(id: groupId)
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

        case .newUserGuide:
            collectionView.deselectItem(at: indexPath, animated: true)
            onNewUserGuideSelected?()

        case .changeAppIcon:
            collectionView.deselectItem(at: indexPath, animated: true)
            onChangeAppIconSelected?()

        case .articleIndex:
            collectionView.deselectItem(at: indexPath, animated: true)
            onArticleIndexSelected?()

        case .iCloudTroubleshoot:
            collectionView.deselectItem(at: indexPath, animated: true)
            onTroubleshootSelected?()

        case .aiCoach:
            collectionView.deselectItem(at: indexPath, animated: true)
            onAICoachSelected?()

        case .articleEmbedPOC:
            collectionView.deselectItem(at: indexPath, animated: true)
            onArticleEmbedPOCSelected?()

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
            let group = dictionaryProvider.group(id: groupId)
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
        
        dictionaryProvider.reorderUserGroups(newOrder: userGroupIds)
        applySnapshot(animated: true)
    }
    
    // MARK: - Group Deletion
    
    private func confirmDeleteGroup(id: String) {
        let group = dictionaryProvider.group(id: id)
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
        dictionaryProvider.deleteGroup(id: id)
        applySnapshot(animated: true)
    }
}
