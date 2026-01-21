//
//  MainSplitViewController.swift
//  OpenMDict-iOS
//
//  Triple column split view controller
//

import UIKit
import OpenMDictKit

class MainSplitViewController: UISplitViewController {
    
    // MARK: - Child Controllers
    
    private let dictionaryListVC = DictionaryListViewController()
    private let wordListVC = WordListViewController()
    private let detailContainer = DetailContainerViewController()
    
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
    
    // MARK: - Setup
    
    private func setupSplitView() {
        preferredDisplayMode = .twoDisplaceSecondary
        preferredSplitBehavior = .displace
        
        primaryBackgroundStyle = .none
        preferredPrimaryColumnWidthFraction = 0.25
        minimumPrimaryColumnWidth = 250
        
        preferredSupplementaryColumnWidthFraction = 0.25
        minimumSupplementaryColumnWidth = 250
        
        navigationItem.backButtonDisplayMode = .minimal
        
        presentsWithGesture = true

        view.backgroundColor = .systemGroupedBackground
    }
    
    private func setupChildControllers() {
        // Inject search session into word list
        wordListVC.searchSession = searchSession
        
        // Primary: Sidebar (dictionary list)
        setViewController(dictionaryListVC, for: .primary)
         
        // Supplementary: Word list
        setViewController(wordListVC, for: .supplementary)

        // Secondary: Detail container (manages iPad/iPhone views)
        setViewController(detailContainer, for: .secondary)
    }
    
    private func setupDelegates() {
        dictionaryListVC.onGroupSelected = { [weak self] group in
            self?.selectGroup(group)
        }
        
        dictionaryListVC.onDictionarySelected = { [weak self] dict in
            self?.selectDictionary(dict)
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
        return .supplementary
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
