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
    
    private var currentDictId: String?
    
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
        preferredPrimaryColumnWidthFraction = 0.2
        preferredSupplementaryColumnWidthFraction = 0.25
        minimumPrimaryColumnWidth = 200
        minimumSupplementaryColumnWidth = 250
        
        preferredDisplayMode = .twoBesideSecondary
        presentsWithGesture = true
        
        view.backgroundColor = .systemGroupedBackground
    }
    
    private func setupChildControllers() {
        // Primary: Dictionary list
        let primaryNav = UINavigationController(rootViewController: dictionaryListVC)
        primaryNav.navigationBar.prefersLargeTitles = true
        
        // Supplementary: Word list
        let supplementaryNav = UINavigationController(rootViewController: wordListVC)
        
        // Secondary: Article strip (no nav bar, actions are on cards)
        let secondaryNav = UINavigationController(rootViewController: articleStripVC)
        secondaryNav.setNavigationBarHidden(true, animated: false)
        
        setViewController(primaryNav, for: .primary)
        setViewController(supplementaryNav, for: .supplementary)
        setViewController(secondaryNav, for: .secondary)
        
        // Compact mode fallback
        setViewController(UINavigationController(rootViewController: WordListViewController()), for: .compact)
    }
    
    private func setupDelegates() {
        dictionaryListVC.onDictionarySelected = { [weak self] dictItem in
            self?.selectDictionary(dictItem)
        }
        
        wordListVC.onWordSelected = { [weak self] wordItem in
            self?.selectWord(wordItem)
        }
    }
    
    // MARK: - Navigation
    
    private func selectDictionary(_ dict: DictionaryItem) {
        currentDictId = dict.id
        wordListVC.loadWords(for: dict)
        
        if traitCollection.horizontalSizeClass == .regular {
            show(.supplementary)
        }
    }
    
    private func selectWord(_ word: WordItem) {
        let article = ArticleItem(
            title: word.word,
            dictName: DictionaryItem.mockData.first { $0.id == word.dictId }?.name ?? "Unknown"
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
