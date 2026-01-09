//
//  MainSplitViewController.swift
//  OpenMDict-iOS
//
//  Triple column split view controller
//

import UIKit

class MainSplitViewController: UISplitViewController {
    
    // MARK: - Child Controllers
    
    private let dictionaryListVC = DictionaryListViewController()
    private let wordListVC = WordListViewController()
    private let articleStripVC = ArticleStripViewController()
    
    // MARK: - State
    
    private var currentGroup: DictionaryGroup?
    
    // MARK: - Initialization
    
    init(initialArticle: ArticleItem? = nil) {
        super.init(style: .tripleColumn)
        
        if let article = initialArticle {
            articleStripVC.preloadArticle(article)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupSplitView()
        setupChildControllers()
        setupDelegates()
    }
    
    // MARK: - Setup
    
    private func setupSplitView() {
        preferredDisplayMode = .twoBesideSecondary
        primaryBackgroundStyle = .none
        
        preferredPrimaryColumnWidthFraction = 0.25
        preferredSupplementaryColumnWidthFraction = 0.25
        minimumPrimaryColumnWidth = 250
        minimumSupplementaryColumnWidth = 250
        
        presentsWithGesture = true
        
        view.backgroundColor = .systemGroupedBackground
    }
    
    private func setupChildControllers() {
        // Primary: Dictionary list (sidebar)
        let primaryNav = UINavigationController(rootViewController: dictionaryListVC)
        primaryNav.navigationBar.prefersLargeTitles = true
        
        // Supplementary: Word list
        let supplementaryNav = UINavigationController(rootViewController: wordListVC)
        
        // Secondary: Article strip (with nav bar for global actions)
        let secondaryNav = UINavigationController(rootViewController: articleStripVC)
        secondaryNav.setNavigationBarHidden(true, animated: false) // Will show when articles exist
        
        setViewController(primaryNav, for: .primary)
        setViewController(supplementaryNav, for: .supplementary)
        setViewController(secondaryNav, for: .secondary)
        
        // Compact mode fallback
        setViewController(UINavigationController(rootViewController: WordListViewController()), for: .compact)
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
    
    // MARK: - Navigation
    
    private func selectGroup(_ group: DictionaryGroup) {
        currentGroup = group
        wordListVC.loadWords(for: group)
        
        if traitCollection.horizontalSizeClass == .regular {
            show(.supplementary)
        }
    }
    
    private func selectDictionary(_ dict: DictionaryItem) {
       currentGroup = nil
       wordListVC.loadWords(for: dict)

       if traitCollection.horizontalSizeClass == .regular {
           show(.supplementary)
       }
    }
    
    private func selectWord(_ word: WordItem) {
        // Find dictionary name from the word's dictId
        let dictName = DictionaryItem.mockData.first { $0.id == word.dictId }?.name ?? "Unknown"
        
        let article = ArticleItem(
            title: word.word,
            dictName: dictName
        )
        showArticle(article, animated: true)
    }
    
    func showArticle(_ article: ArticleItem, animated: Bool) {
        articleStripVC.pushArticle(article, animated: animated)
        
        if traitCollection.horizontalSizeClass == .regular {
            show(.secondary)
        }
    }
    
    // MARK: - State Restoration
    
    func currentStateActivity() -> NSUserActivity? {
        guard let currentArticle = articleStripVC.currentArticle else {
            return nil
        }
        return currentArticle.userActivity
    }
}

// MARK: - Multi-Window Support

extension MainSplitViewController {
    
    func openInNewWindow(_ article: ArticleItem) {
        SceneDelegate.openNewWindow(for: article)
    }
}
