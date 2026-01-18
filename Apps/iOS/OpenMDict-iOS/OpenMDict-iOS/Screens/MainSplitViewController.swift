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
    
    private var currentGroup: MDicts?
    
    // MARK: - Initialization
    
    init(initialArticle: ArticleDisplayItem? = nil) {
        super.init(style: .tripleColumn)
        
        if let article = initialArticle {
            detailContainer.preloadArticle(article)
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
    }
    
    private func setupInitialState() {
        let defaultGroup = DictionaryService.shared.groups.first { $0.isDefault }!
        currentGroup = defaultGroup
        wordListVC.loadWords(for: defaultGroup)
        dictionaryListVC.setActiveGroup(defaultGroup)
    }
    
    // MARK: - Navigation
    
    private func selectGroup(_ group: MDicts) {
        currentGroup = group
        wordListVC.loadWords(for: group)
        
        show(.supplementary)
    }
    
    private func selectDictionary(_ dict: MDict) {
        currentGroup = nil
        wordListVC.loadWords(for: dict)
        
        show(.supplementary)
    }
    
    private func selectWord(_ word: WordDisplayItem) {
        // Use stub HTML if available, otherwise placeholder
        let html = StubHTML.html(for: word.word, dictName: word.dictName)
        
        let article = ArticleDisplayItem(
            word: word.word,
            dictId: word.dictId,
            dictName: word.dictName,
            html: html
        )
        showArticle(article, animated: true)
    }
    
    func showArticle(_ article: ArticleDisplayItem, animated: Bool) {
        detailContainer.pushArticle(article, animated: animated)
        
        show(.secondary)
    }
    
    // MARK: - State Restoration
    
    func currentStateActivity() -> NSUserActivity? {
        guard let currentArticle = detailContainer.currentArticle else {
            return nil
        }
        return currentArticle.userActivity
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
        SceneDelegate.openNewWindow(for: article)
    }
}
