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
    
    // MARK: - Child Controllers
    
    private let dictionaryListVC = DictionaryListViewController()
    private let wordListVC = WordListViewController()
    private let detailContainer = DetailContainerViewController()
    private lazy var dictInfoVC = DictInfoViewController()
    private lazy var dictResourceEditorVC = DictResourceEditorViewController()
    private lazy var groupInfoVC = GroupInfoViewController()
    private lazy var groupDictEditorVC = GroupDictionaryEditorViewController()
    
    // MARK: - State
    
    private(set) var currentMode: AppMode = .lookup
    private let searchSession = DictionaryService.shared.createSearchSession()
    private var initialGroupId: String = ""
    private var currentGroup: MDicts?
    private var currentDict: MDict?
    
    /// Loading modal for long-running operations
    private weak var loadingVC: LoadingViewController?
    
    // MARK: - Constants
    
    private enum ColumnWidth {
        static let lookupFraction: CGFloat = 0.25
        static let lookupMin: CGFloat = 250
        static let managementFraction: CGFloat = 0.35
        static let managementMin: CGFloat = 320
    }
    
    private var isCompact: Bool {
        traitCollection.horizontalSizeClass == .compact
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
        applyInitialSelection()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if !detailContainer.allArticles.isEmpty {
            debugLog("📱 viewDidAppear: showing secondary with \(detailContainer.allArticles.count) articles")
            show(.secondary)
        }
    }
    
    override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)
        
        let wasRegular = traitCollection.horizontalSizeClass == .regular
        let willBeCompact = newCollection.horizontalSizeClass == .compact
        
        guard wasRegular && willBeCompact else { return }
        
        coordinator.animate { _ in
            switch self.currentMode {
            case .lookup:
                if self.detailContainer.allArticles.isEmpty {
                    debugLog("📱 Transitioning to compact (lookup): showing word list")
                    self.show(.supplementary)
                } else {
                    debugLog("📱 Transitioning to compact (lookup): showing detail")
                    self.show(.secondary)
                }
            case .management:
                debugLog("📱 Transitioning to compact (management): showing config")
                self.show(.supplementary)
            }
        }
    }
    
    // MARK: - Setup
    
    private func setupSplitView() {
        preferredDisplayMode = .twoDisplaceSecondary
        preferredSplitBehavior = .displace
        primaryBackgroundStyle = .none
        preferredPrimaryColumnWidthFraction = 0.25
        minimumPrimaryColumnWidth = 250
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
            self?.enterManagementMode(for: .editGroup(groupId: groupId))
        }
        
        dictionaryListVC.onAddGroupSelected = { [weak self] in
            self?.enterManagementMode(for: .createGroup)
        }
        
        wordListVC.onWordSelected = { [weak self] word in
            self?.select(word: word)
        }
        
        detailContainer.onArticlesEmptied = { [weak self] in
            guard let self, isCompact else { return }
            show(.supplementary)
        }
    }
    
    private func setupManagementCallbacks() {
        dictInfoVC.onDismiss = { [weak self] in
            self?.exitToLookupMode()
        }
        
        dictInfoVC.onManageResources = { [weak self] dictId in
            guard let self, isCompact else { return }
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
            loadingVC = showLoadingModal(message: "Importing dictionary...")
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
                    dictionaryListVC.deselectImportItem()

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
                dictionaryListVC.deselectImportItem()

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
            guard let self, isCompact else { return }
            groupDictEditorVC.showEditor(for: groupId)
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
        
        groupInfoVC.onEditComplete = { [weak self] groupId in
            guard let self else { return }
            dictionaryListVC.reloadData()
            
            if isCollapsed {
                currentMode = .lookup
                dictionaryListVC.appMode = .lookup
                dictionaryListVC.setNeedsUpdateAllCells()
                
                if let group = DictionaryService.shared.group(id: groupId) {
                    select(group: group)
                }
                
                show(.primary)
                configureColumns(for: .lookup)
                debugLog("📝 Edit group complete (compact)")
            } else {
                if let group = DictionaryService.shared.group(id: groupId) {
                    exitToLookupModeIfNeeded()
                    select(group: group)
                }
                debugLog("📝 Edit group complete (regular)")
            }
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
    
    // MARK: - Selection
    
    func select(group: MDicts) {
        currentGroup = group
        currentDict = nil
        wordListVC.loadWords(for: group)
        dictionaryListVC.setActiveGroup(group)
        show(.supplementary)
    }
    
    func select(dictionary dict: MDict) {
        currentGroup = nil
        currentDict = dict
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
    
    func select(word: WordDisplayItem) {
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
    }
    
    func showArticle(_ article: ArticleDisplayItem, animated: Bool) {
        detailContainer.pushArticle(article, animated: animated)
        show(.secondary)
    }
    
    // MARK: - Mode Management
    
    private enum ManagementAction {
        case importNew
        case editDict(dictId: String)
        case editGroup(groupId: String)
        case createGroup
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
        case .editDict(let dictId):
            configureColumns(for: .managementDict)
            dictInfoVC.showEditMode(for: dictId)
            dictResourceEditorVC.showEditor(for: dictId)
        case .editGroup(let groupId):
            configureColumns(for: .managementGroup)
            groupInfoVC.showEditMode(for: groupId)
            groupDictEditorVC.showEditor(for: groupId)
        case .createGroup:
            // Pre-create the group in data layer, then show creating mode
            guard let newGroup = try? DictionaryService.shared.createGroup() else {
                debugLog("❌ Failed to create group")
                return
            }
            dictionaryListVC.reloadData()
            configureColumns(for: .managementGroup)
            groupInfoVC.showCreatingMode(groupId: newGroup.id)
            groupDictEditorVC.showEditor(for: newGroup.id)
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
        
        dictionaryListVC.appMode = .lookup
        dictionaryListVC.setNeedsUpdateAllCells()
        configureColumns(for: .lookup)
        
        show(.supplementary)
        dictionaryListVC.deselectImportItem()
        
        debugLog("🔍 Exited to Lookup mode")
    }
    
    private enum ColumnTarget {
        case lookup
        case managementDict
        case managementGroup
    }
    
    private func configureColumns(for target: ColumnTarget) {
        setViewController(nil, for: .supplementary)
        setViewController(nil, for: .secondary)
        
        switch target {
        case .lookup:
            preferredSupplementaryColumnWidthFraction = ColumnWidth.lookupFraction
            minimumSupplementaryColumnWidth = ColumnWidth.lookupMin
            setViewController(wordListVC, for: .supplementary)
            setViewController(detailContainer, for: .secondary)
            
        case .managementDict:
            preferredSupplementaryColumnWidthFraction = ColumnWidth.managementFraction
            minimumSupplementaryColumnWidth = ColumnWidth.managementMin
            setViewController(dictInfoVC, for: .supplementary)
            setViewController(dictResourceEditorVC, for: .secondary)
            
        case .managementGroup:
            preferredSupplementaryColumnWidthFraction = ColumnWidth.managementFraction
            minimumSupplementaryColumnWidth = ColumnWidth.managementMin
            setViewController(groupInfoVC, for: .supplementary)
            setViewController(groupDictEditorVC, for: .secondary)
        }
    }
    
    // MARK: - State Restoration
    
    func currentStateActivity() -> NSUserActivity? {
        let articles = detailContainer.allArticles
        let groupId = currentGroup?.id ?? ""
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
    
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        switch currentMode {
        case .lookup:
            return detailContainer.allArticles.isEmpty ? .supplementary : .secondary
        case .management:
            return .supplementary
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
