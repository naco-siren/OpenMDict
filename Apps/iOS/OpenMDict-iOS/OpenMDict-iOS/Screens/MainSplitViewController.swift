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

class MainSplitViewController: UISplitViewController {
    
    // MARK: - Sidebar Controller (Main Navigation)
    private let dictionaryListVC = DictionaryListViewController()
    
    // MARK: - Child Controllers (Lookup Mode)
    
    private let wordListVC = WordListViewController()
    private let detailContainer = DetailContainerViewController()
    
    // MARK: - Child Controllers (Management Mode)
    
    private lazy var dictInfoVC = DictInfoViewController()
    private lazy var dictResourceEditorVC = DictResourceEditorViewController()
    
    // MARK: - Mode State
    
    private(set) var currentMode: AppMode = .lookup
    
    // MARK: - Column Width Constants
    
    private enum ColumnWidth {
        // Lookup mode: narrower supplementary for word list
        static let lookupSupplementaryFraction: CGFloat = 0.25
        static let lookupSupplementaryMin: CGFloat = 250
        
        // Management mode: wider supplementary for form UI
        static let managementSupplementaryFraction: CGFloat = 0.35
        static let managementSupplementaryMin: CGFloat = 320
    }
    
    // MARK: - State

    /// Per-scene search session
    private let searchSession = DictionaryService.shared.createSearchSession()

    private var initialGroupId: String = ""
    private var currentGroup: MDicts?
    private var currentDict: MDict?
    
    // MARK: - Initialization
    
    init(
        initialArticles: [ArticleDisplayItem] = [],
        initialGroupId: String = "",
        initialLayoutMode: Int = 0
    ) {
        super.init(style: .tripleColumn)
        
        self.initialGroupId = initialGroupId
        
        // Preload articles
        for article in initialArticles {
            detailContainer.preloadArticle(article)
        }

        // Set layout mode
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
        setupDelegates()
        setupInitialState()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Show initial articles (from state restoration or drag) if exist
        if !detailContainer.allArticles.isEmpty {
            print("📱 viewDidAppear: showing secondary with \(detailContainer.allArticles.count) articles")
            show(.secondary)
        }
    }
    
    override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)

        let wasRegular = traitCollection.horizontalSizeClass == .regular
        let willBeCompact = newCollection.horizontalSizeClass == .compact

        // Only handle regular → compact transition
        // Compact → regular is handled automatically by split view
        guard wasRegular && willBeCompact else { return }
        
        coordinator.animate { _ in
            switch self.currentMode {
            case .lookup:
                if self.detailContainer.allArticles.isEmpty {
                    debugLog("📱 Transitioning to compact (lookup): no articles, showing word list")
                    self.show(.supplementary)
                } else {
                    debugLog("📱 Transitioning to compact (lookup): has \(self.detailContainer.allArticles.count) articles, showing detail")
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
        
        // IMPORTANT: Set initial supplementary width for lookup mode
        preferredSupplementaryColumnWidthFraction = ColumnWidth.lookupSupplementaryFraction
        minimumSupplementaryColumnWidth = ColumnWidth.lookupSupplementaryMin
        
        navigationItem.backButtonDisplayMode = .minimal
        
        presentsWithGesture = true

        view.backgroundColor = .systemGroupedBackground
    }
    
    private func setupChildControllers() {
        // Inject search session into word list
        wordListVC.searchSession = searchSession
        
        // Primary: Sidebar (dictionary list) - no nav controller needed, split view handles it
        setViewController(dictionaryListVC, for: .primary)
         
        // Supplementary & Secondary: Set up for lookup mode (default)
        // Don't wrap in nav controllers here - split view manages navigation
        setViewController(wordListVC, for: .supplementary)
        setViewController(detailContainer, for: .secondary)
    }
    
    private func setupDelegates() {
        dictionaryListVC.onGroupSelected = { [weak self] group in
            self?.switchToLookupModeIfNeeded()
            self?.selectGroup(group)
        }
        
        dictionaryListVC.onDictionarySelected = { [weak self] dict in
            self?.switchToLookupModeIfNeeded()
            self?.selectDictionary(dict)
        }
        
        dictionaryListVC.onImportDictionarySelected = { [weak self] in
            self?.switchToManagementMode(showImport: true)
        }
        
        dictionaryListVC.onDictionaryInfoSelected = { [weak self] dictId in
            self?.switchToManagementMode(showImport: false, editDictId: dictId)
        }
        
        wordListVC.onWordSelected = { [weak self] wordItem in
            self?.selectWord(wordItem)
        }
        
        // Handle articles emptied (e.g., after drag to new window)
        detailContainer.onArticlesEmptied = { [weak self] in
            // In compact mode, show supplementary column when articles become empty
            if self?.traitCollection.horizontalSizeClass == .compact {
                self?.show(.supplementary)
            }
        }
        
        // Management mode callbacks
        dictInfoVC.onDismiss = { [weak self] in
            self?.switchToLookupMode()
        }
        
        dictInfoVC.onImportComplete = { [weak self] dictionaryId in
            guard let self = self else { return }

            // Refresh sidebar to show new dictionary
            self.dictionaryListVC.reloadData()

            // Select default group and load its words
            if let defaultGroup = DictionaryService.shared.defaultGroup {
                self.currentGroup = defaultGroup
                self.currentDict = nil
                self.wordListVC.loadWords(for: defaultGroup)
                self.dictionaryListVC.setActiveGroup(defaultGroup)
            }

            // Switch to lookup mode
            self.switchToLookupMode()

            // In compact mode, navigate back to sidebar to show new dictionary
            if self.traitCollection.horizontalSizeClass == .compact {
                self.show(.primary)
            }
        }
        
        dictInfoVC.onDeleteComplete = { [weak self] dictionaryId in
            DictionaryService.shared.refreshAfterDelete(dictionaryId)
            self?.dictionaryListVC.reloadData()
            self?.switchToLookupMode()
        }
        
        // Compact mode only: show resource editor
        dictInfoVC.onManageResources = { [weak self] dictId in
            guard let self = self else { return }
            // In compact mode, show secondary column (resource editor)
            if self.traitCollection.horizontalSizeClass == .compact {
                self.dictResourceEditorVC.showEditor(for: dictId)
                self.show(.secondary)
            }
        }
    }
    
    private func setupInitialState() {
        // Use restored group or default
        let group: MDicts?
        if initialGroupId.isEmpty {
            group = DictionaryService.shared.defaultGroup
        } else {
            group = DictionaryService.shared.group(id: initialGroupId)
                ?? DictionaryService.shared.defaultGroup
        }

        guard let group = group else {
            print("⚠️ No default group found")
            return
        }
        currentGroup = group
        currentDict = nil
        wordListVC.loadWords(for: group)
        dictionaryListVC.setActiveGroup(group)
    }
    
    // MARK: - Navigation
    
    private func selectGroup(_ group: MDicts) {
        currentGroup = group
        currentDict = nil
        wordListVC.loadWords(for: group)
        
        show(.supplementary)
    }
    
    private func selectDictionary(_ dict: MDict) {
        currentGroup = nil
        currentDict = dict
        wordListVC.loadWords(for: dict)
        
        show(.supplementary)
    }
    
    private func selectWord(_ word: WordDisplayItem) {
        // Try real lookup first
        let dict = DictionaryService.shared.dict(id: word.dictId)

        var article = ArticleDisplayItem(
            word: word.word,
            dictId: word.dictId,
            dictName: word.dictName,
            contentState: .pending
        )

        // If dictionary is loaded, get the content
        if let dict = dict, let entry = dict.lookup(word.word) {
            article.contentState = .loaded(html: entry.article.html, css: nil)
        }
        
        showArticle(article, animated: true)
    }
    
    func showArticle(_ article: ArticleDisplayItem, animated: Bool) {
        detailContainer.pushArticle(article, animated: animated)
        
        show(.secondary)
    }
    
    // MARK: - Mode Switching
    
    /// Switch to management mode
    /// - Parameters:
    ///   - showImport: If true, show import mode; if false, show edit mode
    ///   - editDictId: Dictionary ID to edit (only used when showImport is false)
    private func switchToManagementMode(showImport: Bool, editDictId: String? = nil) {
        // ALWAYS set wider supplementary for management UI (even if already in management mode)
        preferredSupplementaryColumnWidthFraction = ColumnWidth.managementSupplementaryFraction
        minimumSupplementaryColumnWidth = ColumnWidth.managementSupplementaryMin
        
        if currentMode != .management {
            currentMode = .management
            
            dictionaryListVC.appMode = .management
            dictionaryListVC.setNeedsUpdateAllCells()
            
            // Clear columns first to ensure proper replacement
            setViewController(nil, for: .supplementary)
            setViewController(nil, for: .secondary)
            
            // Set supplementary (second column): DictInfo directly (no nav controller needed)
            setViewController(dictInfoVC, for: .supplementary)
            
            // Set secondary (third column): DictResourceEditor
            setViewController(dictResourceEditorVC, for: .secondary)

            print("📚 Switched to Management mode")
        }
        
        // Show appropriate mode
        if showImport {
            dictInfoVC.showImportMode()
            dictResourceEditorVC.showEmptyState()
        } else if let dictId = editDictId {
            dictInfoVC.showEditMode(for: dictId)
            dictResourceEditorVC.showEditor(for: dictId)
        }
        
        // Always show supplementary
        show(.supplementary)
    }
    
    /// Switch to lookup mode (word list + detail)
    func switchToLookupMode() {
        guard currentMode != .lookup else { return }
        currentMode = .lookup
        
        dictionaryListVC.appMode = .lookup
        dictionaryListVC.setNeedsUpdateAllCells()
        
        // Narrower supplementary for word list
        preferredSupplementaryColumnWidthFraction = ColumnWidth.lookupSupplementaryFraction
        minimumSupplementaryColumnWidth = ColumnWidth.lookupSupplementaryMin
        
        // Clear columns first to ensure proper replacement
        setViewController(nil, for: .supplementary)
        setViewController(nil, for: .secondary)
        
        // Set view controllers for lookup mode
        setViewController(wordListVC, for: .supplementary)
        setViewController(detailContainer, for: .secondary)
        
        show(.supplementary)
        
        // Deselect import item in sidebar
        dictionaryListVC.deselectImportItem()
        
        print("🔍 Switched to Lookup mode")
    }
    
    /// Switch to lookup mode only if currently in management mode
    private func switchToLookupModeIfNeeded() {
        if currentMode == .management {
            switchToLookupMode()
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
        return switch currentMode {
        case .lookup:
            // Show detail if there are articles, otherwise show word list
            if !detailContainer.allArticles.isEmpty { .secondary } else { .supplementary }

        case .management:
            // Always show supplementary (config VC)
            .supplementary
        }
    }
}

// MARK: - Multi-Window Support

extension MainSplitViewController {
    
    func openInNewWindow(_ article: ArticleDisplayItem) {
        // Get current scene session
        let session = view.window?.windowScene?.session
        SceneDelegate.openNewWindow(for: article, sourceSession: session)
    }
}
