//
//  MainSplitViewController.swift
//  OpenMDict-iOS
//
//  Triple column split view controller with dual-mode support:
//  - Lookup Mode: WordList + DetailContainer (default)
//  - Management Mode: DictInfo (import/edit dictionary)
//

import UIKit
import OpenMDictKit

// MARK: - App Mode

enum AppMode {
    case lookup      // Default: word search and article display
    case management  // Dictionary management and import
}

// MARK: - MainSplitViewController

class MainSplitViewController: UISplitViewController {

    /// Simplified column target for compact ↔ regular state transfer.
    enum ColumnTargetSnapshot {
        case lookup
        case bookmarks
        case lookupHistory
        case management
    }

    // MARK: - Child Controllers

    private let dictionaryListVC = DictionaryListViewController()
    private let wordListVC = WordListViewController()
    private let detailContainer = DetailContainerViewController()
    private lazy var dictInfoVC = DictInfoViewController()
    private lazy var dictResourceEditorVC = DictResourceEditorViewController()
    private lazy var groupInfoVC = GroupInfoViewController()
    private lazy var groupDictEditorVC = GroupDictionaryEditorViewController()
    private lazy var bookmarkListVC = BookmarkListViewController()
    private lazy var lookupHistoryListVC = LookupHistoryListViewController()

    /// Compact layout: UITabBarController shown when the split view collapses.
    private(set) lazy var compactTabBarController = CompactTabBarController()
    
    // MARK: - State
    
    private(set) var currentMode: AppMode = .lookup
    private let searchSession = DictionaryService.shared.createSearchSession()
    private var initialGroupId: String = ""
    private var currentGroup: MDicts?
    private var currentDict: MDict?

    /// Loading modal for long-running operations
    private weak var loadingVC: LoadingViewController?

    /// Prevents presenting setup multiple times (e.g., on multi-window restore)
    private var hasAttemptedSetup = false
    
    // MARK: - Constants
    
    private enum ColumnWidth {
        static let lookupFraction: CGFloat = 0.25
        static let lookupMin: CGFloat = 250
        static let managementFraction: CGFloat = 0.40
        static let managementMin: CGFloat = 400
    }
    
    // MARK: - Initialization
    
    init(
        initialArticles: [ArticleDisplayItem] = [],
        initialGroupId: String = "",
        initialLayoutMode: Int = 0
    ) {
        super.init(style: .tripleColumn)
        
        self.initialGroupId = initialGroupId
        
        for article in initialArticles {
            detailContainer.preloadArticle(article)
        }
        
        if let mode = ArticleLayoutMode(rawValue: initialLayoutMode) {
            detailContainer.setLayoutMode(mode)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        delegate = self
        
        setupSplitView()
        setupChildControllers()
        setupSidebarCallbacks()
        setupManagementCallbacks()
        setupBookmarkCallbacks()
        setupLookupHistoryCallbacks()
        applyInitialSelection()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Check for first-install setup (before article restoration)
        presentSetupIfNeeded()

        if !detailContainer.allArticles.isEmpty {
            debugLog("📱 viewDidAppear: showing secondary with \(detailContainer.allArticles.count) articles")
            show(.secondary)
        }
    }
    
    override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)
        // Compact layout is handled by CompactTabBarController via .compact column.
        // No manual show(.supplementary)/show(.secondary) needed on collapse.
    }
    
    // MARK: - Setup
    
    private func setupSplitView() {
        preferredDisplayMode = .twoDisplaceSecondary
        preferredSplitBehavior = .displace
        primaryBackgroundStyle = .none
        preferredPrimaryColumnWidthFraction = 0.35
        minimumPrimaryColumnWidth = 300
        preferredSupplementaryColumnWidthFraction = ColumnWidth.lookupFraction
        minimumSupplementaryColumnWidth = ColumnWidth.lookupMin
        navigationItem.backButtonDisplayMode = .minimal
        presentsWithGesture = true
        view.backgroundColor = .systemGroupedBackground
    }
    
    private func setupChildControllers() {
        wordListVC.searchSession = searchSession
        setViewController(dictionaryListVC, for: .primary)
        setViewController(wordListVC, for: .supplementary)
        setViewController(detailContainer, for: .secondary)
        setViewController(compactTabBarController, for: .compact)
    }
    
    private func setupSidebarCallbacks() {
        dictionaryListVC.onGroupSelected = { [weak self] group in
            guard let self else { return }
            exitToLookupModeIfNeeded()
            select(group: group)
        }
        
        dictionaryListVC.onDictionarySelected = { [weak self] dict in
            guard let self else { return }
            exitToLookupModeIfNeeded()
            select(dictionary: dict)
        }
        
        dictionaryListVC.onImportDictionarySelected = { [weak self] in
            self?.enterManagementMode(for: .importNew)
        }
        
        dictionaryListVC.onDictionaryInfoSelected = { [weak self] dictId in
            self?.enterManagementMode(for: .editDict(dictId: dictId))
        }
        
        dictionaryListVC.onGroupInfoSelected = { [weak self] groupId in
            let group = DictionaryService.shared.group(id: groupId)
            if group?.isDefault == true {
                self?.enterManagementMode(for: .viewDefaultGroup(groupId: groupId))
            } else {
                self?.enterManagementMode(for: .editGroup(groupId: groupId))
            }
        }
        
        dictionaryListVC.onAddGroupSelected = { [weak self] in
            self?.enterManagementMode(for: .createGroup)
        }

        dictionaryListVC.onBookmarksSelected = { [weak self] in
            self?.showBookmarksList()
        }

        dictionaryListVC.onLookupHistorySelected = { [weak self] in
            self?.showLookupHistoryList()
        }

        dictionaryListVC.onManagePresetsSelected = { [weak self] in
            self?.presentPresetManager()
        }
        
        wordListVC.onWordSelected = { [weak self] word in
            self?.select(word: word)
        }

        wordListVC.onViewAllHistory = { [weak self] in
            self?.showLookupHistoryList()
        }
        
        detailContainer.onArticlesEmptied = { [weak self] in
            guard let self, isCollapsed else { return }
            show(.supplementary)
        }

        detailContainer.onJumpSearchFallback = { [weak self] word in
            self?.focusSearchAndLookup(word: word)
        }
    }
    
    private func setupManagementCallbacks() {
        dictInfoVC.onDismiss = { [weak self] in
            self?.exitToLookupMode()
        }
        
        dictInfoVC.onManageResources = { [weak self] dictId in
            guard let self, isCollapsed else { return }
            dictResourceEditorVC.showEditor(for: dictId)
            show(.secondary)
        }
        
        dictInfoVC.onMDXSelected = { [weak self] dictId in
            guard let self else { return }
            // Update third column to show resource editor for pending import
            // This works in both regular (columns visible) and compact (user taps Manage Resources) modes
            dictResourceEditorVC.showEditor(for: dictId)
            debugLog("📄 MDX selected: resource editor ready for \(dictId.prefix(8))...")
        }
        
        dictInfoVC.onImportStarted = { [weak self] in
            guard let self else { return }
            loadingVC = showLoadingModal(message: L10n.Detail.importingDictionary)
            debugLog("📦 Import started: showing loading modal")
        }
        
        dictInfoVC.onImportFailed = { [weak self] error in
            guard let self else { return }
            hideLoadingModal(loadingVC)
            loadingVC = nil
            debugLog("❌ Import failed: hiding loading modal")
        }
        
        dictInfoVC.onImportComplete = { [weak self] dictId in
            guard let self else { return }
            
            // Hide loading modal first
            hideLoadingModal(loadingVC) { [weak self] in
                guard let self else { return }
                
                dictionaryListVC.reloadData()
                
                if isCollapsed {
                    // Compact mode: update state
                    currentMode = .lookup
                    dictionaryListVC.appMode = .lookup
                    dictionaryListVC.setNeedsUpdateAllCells()
                    dictionaryListVC.deselectManagementItems()

                    // Select the new dictionary in sidebar
                    if let dict = DictionaryService.shared.dict(id: dictId) {
                        currentDict = dict
                        currentGroup = nil
                        dictionaryListVC.setActiveDictionary(dict)
                        wordListVC.loadWords(for: dict)
                    }

                    // Navigate back to sidebar, then swap columns back to lookup mode
                    show(.primary)
                    configureColumns(for: .lookup)
                    debugLog("🔍 Import complete (compact): navigated to sidebar")
                } else {
                    // Regular mode: normal flow
                    select(dictionaryId: dictId)
                    debugLog("🔍 Import complete (regular): select new dictionary")
                }
            }
            loadingVC = nil
        }
        
        dictInfoVC.onEditComplete = { [weak self] dictId in
            guard let self else { return }

            if isCollapsed {
                // Compact mode: update state
                currentMode = .lookup
                dictionaryListVC.appMode = .lookup
                dictionaryListVC.setNeedsUpdateAllCells()
                dictionaryListVC.deselectManagementItems()

                // Select the edited dictionary in sidebar
                if let dict = DictionaryService.shared.dict(id: dictId) {
                    currentDict = dict
                    currentGroup = nil
                    dictionaryListVC.setActiveDictionary(dict)
                    wordListVC.loadWords(for: dict)
                }

                // Navigate back to sidebar, then swap columns back to lookup mode
                show(.primary)
                configureColumns(for: .lookup)
                debugLog("📝 Edit complete (compact): navigated to sidebar")
            } else {
                // Regular mode: exit to lookup and select
                select(dictionaryId: dictId)
                debugLog("📝 Edit complete (regular): selected dictionary")
            }
        }
        
        dictInfoVC.onDeleteComplete = { [weak self] dictId in
            guard let self else { return }
            dictionaryListVC.reloadData()
            exitToLookupMode()
        }
        
        // MARK: Group Management Callbacks
        
        groupInfoVC.onDismiss = { [weak self] in
            guard let self else { return }
            dictionaryListVC.reloadData()
            exitToLookupMode()
        }
        
        groupInfoVC.onManageDictionaries = { [weak self] groupId in
            guard let self, isCollapsed else { return }
            // EditorVC was already configured by enterManagementMode
            // (showCreatingEditor for .createGroup, showEditor for .editGroup).
            // Don't call showEditor here — it would overwrite creating mode
            // with .managing(groupId: "pending").
            show(.secondary)
        }
        
        groupInfoVC.onCreateComplete = { [weak self] groupId in
            guard let self else { return }
            dictionaryListVC.reloadData()
            
            if isCollapsed {
                currentMode = .lookup
                dictionaryListVC.appMode = .lookup
                dictionaryListVC.setNeedsUpdateAllCells()
                
                // Select the new group
                if let group = DictionaryService.shared.group(id: groupId) {
                    select(group: group)
                }
                
                show(.primary)
                configureColumns(for: .lookup)
                debugLog("📂 Create group complete (compact)")
            } else {
                // Regular: select the new group
                if let group = DictionaryService.shared.group(id: groupId) {
                    exitToLookupModeIfNeeded()
                    select(group: group)
                }
                debugLog("📂 Create group complete (regular)")
            }
        }
        
        groupInfoVC.onGroupChanged = { [weak self] groupId in
            guard let self else { return }
            dictionaryListVC.reloadData()
            debugLog("📝 Group changed: sidebar refreshed")
        }
        
        groupInfoVC.onDeleteComplete = { [weak self] groupId in
            guard let self else { return }
            dictionaryListVC.reloadData()
            exitToLookupMode()
        }
    }
    
    private func applyInitialSelection() {
        let group: MDicts?
        if initialGroupId.isEmpty {
            group = DictionaryService.shared.defaultGroup
        } else {
            group = DictionaryService.shared.group(id: initialGroupId)
                ?? DictionaryService.shared.defaultGroup
        }
        
        guard let group else {
            debugLog("⚠️ No default group found")
            return
        }
        
        currentGroup = group
        currentDict = nil
        wordListVC.loadWords(for: group)
        dictionaryListVC.setActiveGroup(group)
    }
    
    // MARK: - Setup Flow

    /// Present the setup/onboarding flow when needed.
    ///
    /// Two modes:
    ///   1. **First install** (`syncMode == .notDecided`):
    ///      Full flow — welcome → sync chooser → picker/cloudProgress.
    ///   2. **Picker only** (`syncMode` already decided, but no dictionaries):
    ///      Sync mode is locked in; just show the preset picker so the user
    ///      can download dictionaries.  Reuses `.management` mode but kept
    ///      non-dismissible (`isModalInPresentation = true`).
    private func presentSetupIfNeeded() {
        guard !hasAttemptedSetup else { return }
        hasAttemptedSetup = true

        let syncMode = SyncModeService.shared.currentMode
        let hasDicts = DictMetadataService.shared.hasAnyDictionaries

        let needsSetup = syncMode == .notDecided || !hasDicts

        guard needsSetup else {
            debugLog("📱 Setup not needed: syncMode=\(syncMode.rawValue), hasDicts=true")
            return
        }

        // Sync mode already persisted → only the preset picker is needed.
        let isPickerOnly = syncMode != .notDecided && !hasDicts

        debugLog("📱 Setup needed: syncMode=\(syncMode.rawValue), hasDicts=\(hasDicts), pickerOnly=\(isPickerOnly)")

        let setupVC = SetupViewController(mode: isPickerOnly ? .management : .firstInstall)
        setupVC.isCancellable = false
        // iPad (regular): formSheet card; iPhone (compact): pageSheet for picker-only, fullScreen for first install
        if traitCollection.horizontalSizeClass == .regular {
            setupVC.modalPresentationStyle = .formSheet
            setupVC.preferredContentSize = CGSize(width: 540, height: 620)
        } else {
            setupVC.modalPresentationStyle = isPickerOnly ? .pageSheet : .fullScreen
        }
        // Non-dismissible in both modes — user must pick at least one dictionary.
        setupVC.isModalInPresentation = true

        setupVC.onComplete = { [weak self] in
            guard let self else { return }
            // Reset search context first so the Combine pipeline's
            // removeDuplicates() sees a change when we set the new group
            // (old group and new group share the same id "all").
            searchSession.setContext(.none)
            applyInitialSelection()
            debugLog("📱 Setup complete: dictionaries loaded")
        }

        present(setupVC, animated: true)
    }

    // MARK: - Preset Dictionary Management

    /// Present the preset dictionary management flow as a modal.
    /// Reuses SetupViewController in .management mode (picker → progress).
    private func presentPresetManager() {
        let setupVC = SetupViewController(mode: .management)

        if traitCollection.horizontalSizeClass == .regular {
            setupVC.modalPresentationStyle = .formSheet
            setupVC.preferredContentSize = CGSize(width: 540, height: 620)
        } else {
            setupVC.modalPresentationStyle = .pageSheet
        }

        setupVC.onComplete = { [weak self] in
            guard let self else { return }
            // Refresh sidebar to show newly imported dictionaries
            dictionaryListVC.reloadData()
            // Reload search context so newly imported dicts appear in word list
            searchSession.setContext(.none)
            applyInitialSelection()
            debugLog("📚 Preset management complete: dictionaries refreshed")
        }

        present(setupVC, animated: true)
    }

    // MARK: - Selection

    func select(group: MDicts) {
        currentGroup = group
        currentDict = nil

        if isCollapsed {
            // Compact mode: route to compact tab bar's lookup tab
            compactTabBarController.currentGroup = group
            compactTabBarController.currentDict = nil
            compactTabBarController.selectedIndex = 0
            compactTabBarController.lookupNav.popToRootViewController(animated: false)
            compactTabBarController.lookupWordListVC.loadWords(for: group)
            return
        }

        // Exit bookmarks/history column if needed
        if currentColumnTarget == .bookmarks || currentColumnTarget == .lookupHistory {
            configureColumns(for: .lookup)
        }
        wordListVC.loadWords(for: group)
        dictionaryListVC.setActiveGroup(group)
        show(.supplementary)
    }

    func select(dictionary dict: MDict) {
        currentGroup = nil
        currentDict = dict

        if isCollapsed {
            // Compact mode: route to compact tab bar's lookup tab
            compactTabBarController.currentGroup = nil
            compactTabBarController.currentDict = dict
            compactTabBarController.selectedIndex = 0
            compactTabBarController.lookupNav.popToRootViewController(animated: false)
            compactTabBarController.lookupWordListVC.loadWords(for: dict)
            return
        }

        // Exit bookmarks/history column if needed
        if currentColumnTarget == .bookmarks || currentColumnTarget == .lookupHistory {
            configureColumns(for: .lookup)
        }
        wordListVC.loadWords(for: dict)
        dictionaryListVC.setActiveDictionary(dict)
        show(.supplementary)
    }
    
    func select(dictionaryId dictId: String) {
        guard let dict = DictionaryService.shared.dict(id: dictId) else {
            debugLog("⚠️ Dictionary not found: \(dictId), falling back to default group")
            if let defaultGroup = DictionaryService.shared.defaultGroup {
                exitToLookupModeIfNeeded()
                select(group: defaultGroup)
            }
            return
        }
        exitToLookupModeIfNeeded()
        select(dictionary: dict)
    }

    func select(groupId: String) {
        guard let group = DictionaryService.shared.group(id: groupId) else {
            debugLog("⚠️ Group not found: \(groupId), falling back to default group")
            if let defaultGroup = DictionaryService.shared.defaultGroup {
                exitToLookupModeIfNeeded()
                select(group: defaultGroup)
            }
            return
        }
        exitToLookupModeIfNeeded()
        select(group: group)
    }

    /// Focus search bar and type the given word to trigger lookup.
    /// Used by URL Scheme, Siri Suggestions (lookupWord), Share Extension, etc.
    func focusSearchAndLookup(word: String) {
        if isCollapsed {
            // Compact mode: route to compact tab bar's lookup tab
            compactTabBarController.selectedIndex = 0
            compactTabBarController.lookupNav.popToRootViewController(animated: false)
            compactTabBarController.lookupWordListVC.focusSearchBar(withInitialText: word)
            return
        }
        exitToLookupModeIfNeeded()
        show(.supplementary)
        wordListVC.focusSearchBar(withInitialText: word)
    }

    /// Open an external .mdx file for import.
    /// Enters management/import mode and pre-fills the selected file.
    func importMDXFile(url: URL) {
        if isCollapsed {
            // Compact mode: switch to Management tab and start import
            compactTabBarController.selectedIndex = 3
            compactTabBarController.managementVC.onImportSelected?()
            // DictInfoVC is now on the management nav stack; hand it the file
            DispatchQueue.main.async { [weak self] in
                self?.compactTabBarController.dictInfoVC.handleMDXFile(at: url)
            }
            return
        }
        enterManagementMode(for: .importNew)
        dictInfoVC.handleMDXFile(at: url)
    }

    func select(word: WordDisplayItem) {
        if isCollapsed {
            // Compact mode: route to compact tab bar's lookup tab
            compactTabBarController.selectedIndex = 0
            compactTabBarController.handleWordSelected(word)
            return
        }

        let dict = DictionaryService.shared.dict(id: word.dictId)

        var article = ArticleDisplayItem(
            word: word.word,
            dictId: word.dictId,
            dictName: word.dictName,
            contentState: .pending
        )

        if let dict, let entry = dict.lookup(word.word) {
            article.contentState = .loaded(html: entry.article.html, css: nil)
        }

        showArticle(article, animated: true)

        // Record lookup history with current search context
        let (ctxDictId, ctxGroupId): (String?, String?) = switch wordListVC.searchSession?.currentContext {
        case .dictionary(let d): (d.id, nil)
        case .group(let g):      (nil, g.id)
        case .none?, nil:        (nil, "all")   // SearchContext.none or no session
        }
        detailContainer.lookupContext = (dictId: ctxDictId, groupId: ctxGroupId)
        LookupHistoryService.shared.recordLookup(
            word: word.word, dictId: word.dictId,
            lookupContextDictId: ctxDictId, lookupContextGroupId: ctxGroupId
        )
    }

    func showArticle(_ article: ArticleDisplayItem, animated: Bool) {
        if isCollapsed {
            // Compact mode: show article in lookup tab's detail container
            compactTabBarController.selectedIndex = 0
            let lookupDetail = compactTabBarController.lookupDetailContainer
            let lookupNav = compactTabBarController.lookupNav
            if lookupDetail.parent == nil || lookupNav.viewControllers.last !== lookupDetail {
                lookupDetail.pushArticle(article, animated: false)
                lookupNav.pushViewController(lookupDetail, animated: animated)
            } else {
                lookupDetail.pushArticle(article, animated: animated)
            }
            return
        }
        detailContainer.pushArticle(article, animated: animated)
        show(.secondary)
    }

    // MARK: - Bookmarks

    private func showBookmarksList() {
        // Exit management mode if needed, but stay in lookup mode
        exitToLookupModeIfNeeded()

        configureColumns(for: .bookmarks)
        bookmarkListVC.reload()
        dictionaryListVC.selectBookmarksItem()
        show(.supplementary)
        debugLog("🔖 Showing bookmarks list")
    }

    private func setupBookmarkCallbacks() {
        bookmarkListVC.onBookmarkSelected = { [weak self] bookmark in
            guard let self else { return }
            guard bookmark.isDictAvailable else { return }  // Dict not on this device
            let dict = DictionaryService.shared.dict(id: bookmark.dictId)
            var article = ArticleDisplayItem(
                word: bookmark.word,
                dictId: bookmark.dictId,
                dictName: bookmark.dictName,
                contentState: .pending
            )
            if let dict, let entry = dict.lookup(bookmark.word) {
                article.contentState = .loaded(html: entry.article.html, css: nil)
            }
            showArticle(article, animated: true)

            // Record lookup so count stays accurate
            // (bookmarkListVC auto-reloads via $revision subscription)
            LookupHistoryService.shared.recordLookup(
                word: bookmark.word, dictId: bookmark.dictId,
                lookupContextDictId: nil, lookupContextGroupId: nil
            )
        }
    }

    // MARK: - Lookup History

    private func showLookupHistoryList() {
        // Exit management mode if needed, but stay in lookup mode
        exitToLookupModeIfNeeded()

        configureColumns(for: .lookupHistory)
        lookupHistoryListVC.reload()
        dictionaryListVC.selectLookupHistoryItem()
        show(.supplementary)
        debugLog("🕐 Showing lookup history list")
    }

    private func setupLookupHistoryCallbacks() {
        lookupHistoryListVC.onHistorySelected = { [weak self] historyItem in
            guard let self else { return }
            guard historyItem.isDictAvailable else { return }  // Dict not on this device
            let dict = DictionaryService.shared.dict(id: historyItem.dictId)
            var article = ArticleDisplayItem(
                word: historyItem.word,
                dictId: historyItem.dictId,
                dictName: historyItem.dictName,
                contentState: .pending
            )
            if let dict, let entry = dict.lookup(historyItem.word) {
                article.contentState = .loaded(html: entry.article.html, css: nil)
            }
            showArticle(article, animated: true)

            // Record lookup so history stays accurate
            // (lookupHistoryListVC auto-reloads via $revision subscription)
            LookupHistoryService.shared.recordLookup(
                word: historyItem.word, dictId: historyItem.dictId,
                lookupContextDictId: nil, lookupContextGroupId: nil
            )
        }
    }

    // MARK: - Mode Management
    
    private enum ManagementAction {
        case importNew
        case editDict(dictId: String)
        case editGroup(groupId: String)
        case createGroup
        case viewDefaultGroup(groupId: String)
    }
    
    private func enterManagementMode(for action: ManagementAction) {
        if currentMode != .management {
            currentMode = .management
            dictionaryListVC.appMode = .management
            dictionaryListVC.setNeedsUpdateAllCells()
            debugLog("📚 Entered Management mode")
        }
        
        switch action {
        case .importNew:
            configureColumns(for: .managementDict)
            dictInfoVC.showImportMode()
            dictResourceEditorVC.showEmptyState()
            dictionaryListVC.selectMgmtImportItem()
        case .editDict(let dictId):
            configureColumns(for: .managementDict)
            dictInfoVC.showEditMode(for: dictId)
            dictResourceEditorVC.showEditor(for: dictId)
            // editDict is triggered via info button — no persistent sidebar selection
        case .editGroup(let groupId):
            let session = DictionaryService.shared.groupSession
            session.beginManaging(groupId: groupId)
            configureColumns(for: .managementGroup)
            groupInfoVC.showManagingMode(for: groupId)
            groupDictEditorVC.showEditor(for: groupId)
            // editGroup is triggered via info button — no persistent sidebar selection
        case .createGroup:
            let session = DictionaryService.shared.groupSession
            session.beginCreate()
            configureColumns(for: .managementGroup)
            groupInfoVC.showCreatingMode(pendingName: session.pendingName ?? L10n.GroupInfo.newGroup)
            groupDictEditorVC.showCreatingEditor()
            dictionaryListVC.selectMgmtAddGroupItem()
        case .viewDefaultGroup(let groupId):
            configureColumns(for: .managementGroup)
            groupInfoVC.showViewingDefaultMode(for: groupId)
            groupDictEditorVC.showReorderEditor(for: groupId)
            // viewDefaultGroup is triggered via info button — no persistent sidebar selection
        }
        
        show(.supplementary)
    }
    
    private func exitToLookupModeIfNeeded() {
        guard currentMode == .management else { return }
        exitToLookupMode()
    }
    
    private func exitToLookupMode() {
        guard currentMode != .lookup else { return }
        currentMode = .lookup
        
        // Reset any active sessions (discard unpersisted state)
        DictionaryService.shared.importSession.reset()
        DictionaryService.shared.groupSession.reset()
        
        // Reset management VCs to empty state
        groupInfoVC.resetToEmptyState()
        groupDictEditorVC.showEmptyState()
        
        dictionaryListVC.appMode = .lookup
        dictionaryListVC.setNeedsUpdateAllCells()
        
        if isCollapsed {
            // Compact mode: pop to sidebar FIRST, then reconfigure columns.
            // Doing it the other way (configureColumns first) corrupts the internal
            // navigation stack because setViewController(nil) detaches the currently-
            // visible VC without popping it.
            show(.primary)
            configureColumns(for: .lookup)
        } else {
            // Regular mode: reconfigure columns (side-by-side), show word list
            configureColumns(for: .lookup)
            show(.supplementary)
        }
        
        dictionaryListVC.deselectManagementItems()
        
        debugLog("🔍 Exited to Lookup mode")
    }
    
    private enum ColumnTarget {
        case lookup
        case bookmarks
        case lookupHistory
        case managementDict
        case managementGroup
    }
    
    private var currentColumnTarget: ColumnTarget = .lookup
    
    private func configureColumns(for target: ColumnTarget) {
        guard target != currentColumnTarget else { return }

        let previousTarget = currentColumnTarget
        currentColumnTarget = target

        // Determine new VCs
        let newSupplementary: UIViewController
        let newSecondary: UIViewController

        switch target {
        case .lookup:
            preferredSupplementaryColumnWidthFraction = ColumnWidth.lookupFraction
            minimumSupplementaryColumnWidth = ColumnWidth.lookupMin
            newSupplementary = wordListVC
            newSecondary = detailContainer
        case .bookmarks:
            preferredSupplementaryColumnWidthFraction = ColumnWidth.lookupFraction
            minimumSupplementaryColumnWidth = ColumnWidth.lookupMin
            newSupplementary = bookmarkListVC
            newSecondary = detailContainer
        case .lookupHistory:
            preferredSupplementaryColumnWidthFraction = ColumnWidth.lookupFraction
            minimumSupplementaryColumnWidth = ColumnWidth.lookupMin
            newSupplementary = lookupHistoryListVC
            newSecondary = detailContainer
        case .managementDict:
            preferredSupplementaryColumnWidthFraction = ColumnWidth.managementFraction
            minimumSupplementaryColumnWidth = ColumnWidth.managementMin
            newSupplementary = dictInfoVC
            newSecondary = dictResourceEditorVC
        case .managementGroup:
            preferredSupplementaryColumnWidthFraction = ColumnWidth.managementFraction
            minimumSupplementaryColumnWidth = ColumnWidth.managementMin
            newSupplementary = groupInfoVC
            newSecondary = groupDictEditorVC
        }

        // Swap supplementary — always changes between column targets.
        setViewController(nil, for: .supplementary)
        setViewController(newSupplementary, for: .supplementary)

        // Swap secondary — only if the VC actually changes.
        // On iPadOS 18, nil-then-re-set of a VC whose navigationItem has a
        // searchController (detailContainer on iOS 16+) crashes: the auto-
        // wrapped UINavigationController is destroyed and recreated, but the
        // searchController still references the old nav bar, triggering
        // "top item belongs to a different navigation bar" in layoutSubviews.
        // Skipping the redundant swap keeps the wrapper nav controller alive.
        let previousSecondary: UIViewController? = {
            switch previousTarget {
            case .lookup, .bookmarks, .lookupHistory: return detailContainer
            case .managementDict: return dictResourceEditorVC
            case .managementGroup: return groupDictEditorVC
            }
        }()

        if newSecondary !== previousSecondary {
            setViewController(nil, for: .secondary)
            setViewController(newSecondary, for: .secondary)
        }
    }
    
    // MARK: - Keyboard Shortcut Handlers (registered via AppDelegate.buildMenu)

    // MARK: Query Category

    @objc func focusLookupShortcut() {
        exitToLookupModeIfNeeded()
        if currentColumnTarget != .lookup {
            configureColumns(for: .lookup)
        }
        show(.supplementary)
        wordListVC.focusSearchBar()
    }

    @objc func selectAllDictionaries() { selectNthGroup(0) }
    @objc func selectGroup1() { selectNthGroup(1) }
    @objc func selectGroup2() { selectNthGroup(2) }
    @objc func selectGroup3() { selectNthGroup(3) }
    @objc func selectGroup4() { selectNthGroup(4) }
    @objc func selectGroup5() { selectNthGroup(5) }
    @objc func selectGroup6() { selectNthGroup(6) }
    @objc func selectGroup7() { selectNthGroup(7) }
    @objc func selectGroup8() { selectNthGroup(8) }
    @objc func selectGroup9() { selectNthGroup(9) }

    private func selectNthGroup(_ index: Int) {
        let groups = DictionaryService.shared.groups
        guard index < groups.count else { return }
        exitToLookupModeIfNeeded()
        select(group: groups[index])
    }

    @objc func selectDictionary1() { selectNthDictionaryInDefaultGroup(0) }
    @objc func selectDictionary2() { selectNthDictionaryInDefaultGroup(1) }
    @objc func selectDictionary3() { selectNthDictionaryInDefaultGroup(2) }
    @objc func selectDictionary4() { selectNthDictionaryInDefaultGroup(3) }
    @objc func selectDictionary5() { selectNthDictionaryInDefaultGroup(4) }
    @objc func selectDictionary6() { selectNthDictionaryInDefaultGroup(5) }
    @objc func selectDictionary7() { selectNthDictionaryInDefaultGroup(6) }
    @objc func selectDictionary8() { selectNthDictionaryInDefaultGroup(7) }
    @objc func selectDictionary9() { selectNthDictionaryInDefaultGroup(8) }

    private func selectNthDictionaryInDefaultGroup(_ index: Int) {
        guard let defaultGroup = DictionaryService.shared.defaultGroup,
              index < defaultGroup.items.count else { return }
        exitToLookupModeIfNeeded()
        select(dictionary: defaultGroup.items[index])
    }

    // MARK: View Category

    @objc func switchToColumnsLayout() { detailContainer.switchLayout(to: .columns) }
    @objc func switchToGridLayout() { detailContainer.switchLayout(to: .grid) }
    @objc func switchToListLayout() { detailContainer.switchLayout(to: .list) }

    @objc func zoomInShortcut() { detailContainer.zoomIn() }
    @objc func zoomOutShortcut() { detailContainer.zoomOut() }
    @objc func actualSizeShortcut() { detailContainer.resetZoom() }

    @objc func toggleAppearanceShortcut() { detailContainer.toggleAppearance() }

    // MARK: Bookmarks & History Category

    @objc func showBookmarksShortcut() {
        showBookmarksList()
    }

    @objc func showHistoryShortcut() {
        showLookupHistoryList()
    }

    // MARK: Window Category

    @objc func closeArticleShortcut() {
        let articles = detailContainer.allArticles
        guard !articles.isEmpty else {
            // No articles — in multi-window scenario, close the window
            if UIApplication.shared.openSessions.count > 1,
               let session = view.window?.windowScene?.session {
                UIApplication.shared.requestSceneSessionDestruction(
                    session, options: nil, errorHandler: nil
                )
            }
            return
        }
        detailContainer.closeArticle(articles[0])  // Close most recent (index 0)
    }

    @objc func newWindowShortcut() {
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: nil, options: nil, errorHandler: nil
        )
    }

    @objc func dismissShortcut() {
        // 1. Search bar active → dismiss search bar
        if wordListVC.isSearchBarFirstResponder {
            wordListVC.dismissSearchBar()
            return
        }
        // 2. Find in page active → dismiss find
        if detailContainer.isSearchActive {
            detailContainer.dismissSearch()
            return
        }
        // 3. Modal presented → dismiss modal
        if let presented = presentedViewController {
            presented.dismiss(animated: true)
            return
        }
    }

    // MARK: Context Cycling (⌥⌘[/])

    @objc func previousContextShortcut() { cycleContext(direction: -1) }
    @objc func nextContextShortcut() { cycleContext(direction: 1) }

    private func cycleContext(direction: Int) {
        exitToLookupModeIfNeeded()
        let groups = DictionaryService.shared.groups
        guard !groups.isEmpty else { return }

        if let currentGroup {
            // Group mode: cycle within the groups array
            guard let idx = groups.firstIndex(where: { $0.id == currentGroup.id }) else {
                if let dg = DictionaryService.shared.defaultGroup { select(group: dg) }
                return
            }
            select(group: groups[(idx + direction + groups.count) % groups.count])

        } else if let currentDict {
            // Dictionary mode: cycle within the containing group's dictionary list
            let containingGroup = groups.first { $0.items.contains { $0.id == currentDict.id } }
            guard let containingGroup,
                  let idx = containingGroup.items.firstIndex(where: { $0.id == currentDict.id }) else {
                if let dg = DictionaryService.shared.defaultGroup { select(group: dg) }
                return
            }
            let items = containingGroup.items
            select(dictionary: items[(idx + direction + items.count) % items.count])

        } else {
            // No context — select default group
            if let dg = DictionaryService.shared.defaultGroup { select(group: dg) }
        }
    }

    // MARK: Utilities Category

    @objc func openSettingsShortcut() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    @objc func importPresetsShortcut() {
        presentPresetManager()
    }

    // MARK: canPerformAction

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // ⌥⌘`: Select "All Dictionaries" — always available
        if action == #selector(selectAllDictionaries) {
            return true
        }

        // ⌥⌘1~9: User group selection — index 1…9 (groups[1]…groups[9])
        let groupSelectors: [Selector] = [
            #selector(selectGroup1), #selector(selectGroup2), #selector(selectGroup3),
            #selector(selectGroup4), #selector(selectGroup5), #selector(selectGroup6),
            #selector(selectGroup7), #selector(selectGroup8), #selector(selectGroup9),
        ]
        if let idx = groupSelectors.firstIndex(of: action) {
            return (idx + 1) < DictionaryService.shared.groups.count
        }

        // ⌃⌥⌘N: Dictionary selection — only enable if dict exists at that index in default group
        let dictSelectors: [Selector] = [
            #selector(selectDictionary1), #selector(selectDictionary2), #selector(selectDictionary3),
            #selector(selectDictionary4), #selector(selectDictionary5), #selector(selectDictionary6),
            #selector(selectDictionary7), #selector(selectDictionary8), #selector(selectDictionary9),
        ]
        if let idx = dictSelectors.firstIndex(of: action) {
            return idx < (DictionaryService.shared.defaultGroup?.items.count ?? 0)
        }

        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: Auto-focus Search on Typing

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard currentMode == .lookup,
              currentColumnTarget == .lookup,
              !wordListVC.isSearchBarFirstResponder,
              let key = presses.first?.key else {
            super.pressesBegan(presses, with: event)
            return
        }
        // Only intercept letter keys without command/control/option modifiers
        let forbidden: UIKeyModifierFlags = [.command, .control, .alternate]
        guard key.modifierFlags.intersection(forbidden).isEmpty,
              let char = key.charactersIgnoringModifiers.first,
              char.isLetter else {
            super.pressesBegan(presses, with: event)
            return
        }
        // Focus search bar and forward the first typed character
        exitToLookupModeIfNeeded()
        if currentColumnTarget != .lookup {
            configureColumns(for: .lookup)
        }
        show(.supplementary)
        wordListVC.focusSearchBar(withInitialText: String(char))
    }

    // MARK: - State Restoration

    func currentStateActivity() -> NSUserActivity? {
        // When collapsed, read articles from the compact tab bar's detail container
        let articles: [ArticleDisplayItem]
        let groupId: String

        if isCollapsed {
            let state = compactTabBarController.transferStateOut()
            articles = state.articles
            groupId = state.group?.id ?? ""
        } else {
            articles = detailContainer.allArticles
            groupId = currentGroup?.id ?? ""
        }

        let layoutMode = detailContainer.currentLayoutMode.rawValue

        return ArticleDisplayItem.sceneStateActivity(
            articles: articles,
            groupId: groupId,
            layoutMode: layoutMode
        )
    }
}

// MARK: - UISplitViewControllerDelegate

extension MainSplitViewController: UISplitViewControllerDelegate {

    // topColumnForCollapsingToProposedTopColumn is NOT called when a .compact
    // column is registered.  State transfer uses willCollapse/willExpand instead.

    func splitViewControllerWillCollapse(_ svc: UISplitViewController) {
        transferStateToCompact()
        debugLog("📱 splitViewControllerWillCollapse: transferred state to compact tab bar")
    }

    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        transferStateFromCompact()
        debugLog("📱 splitViewControllerDidExpand: transferred state from compact tab bar")
    }
}

// MARK: - Compact State Transfer

extension MainSplitViewController {

    /// Map the private `ColumnTarget` to the public `ColumnTargetSnapshot`.
    private var columnTargetSnapshot: ColumnTargetSnapshot {
        switch currentColumnTarget {
        case .lookup:                        return .lookup
        case .bookmarks:                     return .bookmarks
        case .lookupHistory:                 return .lookupHistory
        case .managementDict, .managementGroup: return .management
        }
    }

    /// Push current regular-mode state into the compact tab bar controller.
    private func transferStateToCompact() {
        compactTabBarController.transferStateIn(
            group: currentGroup,
            dict: currentDict,
            searchSession: searchSession,
            articles: detailContainer.allArticles,
            currentArticleIndex: 0,
            columnTarget: columnTargetSnapshot
        )
    }

    /// Read state from the compact tab bar controller and apply to regular-mode VCs.
    private func transferStateFromCompact() {
        let state = compactTabBarController.transferStateOut()

        // Restore group / dictionary selection
        if let group = state.group {
            currentGroup = group
            currentDict = nil
            wordListVC.loadWords(for: group)
            dictionaryListVC.setActiveGroup(group)
        } else if let dict = state.dict {
            currentGroup = nil
            currentDict = dict
            wordListVC.loadWords(for: dict)
            dictionaryListVC.setActiveDictionary(dict)
        }

        // Restore articles into the regular detail container
        if !state.articles.isEmpty {
            detailContainer.restoreArticles(state.articles, currentIndex: state.currentArticleIndex)
        }

        // Restore column target based on selected tab
        switch state.selectedTab {
        case 1:
            if currentColumnTarget != .bookmarks {
                configureColumns(for: .bookmarks)
                bookmarkListVC.reload()
                dictionaryListVC.selectBookmarksItem()
            }
        case 2:
            if currentColumnTarget != .lookupHistory {
                configureColumns(for: .lookupHistory)
                lookupHistoryListVC.reload()
                dictionaryListVC.selectLookupHistoryItem()
            }
        case 3:
            // Management tab — if not already in management mode, just switch to lookup
            if currentMode != .management, currentColumnTarget != .lookup {
                configureColumns(for: .lookup)
            }
        default:
            // Tab 0 = Lookup
            if currentColumnTarget != .lookup {
                configureColumns(for: .lookup)
            }
        }
    }
}

// MARK: - Multi-Window Support

extension MainSplitViewController {
    
    func openInNewWindow(_ article: ArticleDisplayItem) {
        let session = view.window?.windowScene?.session
        SceneDelegate.openNewWindow(for: article, sourceSession: session)
    }
}
