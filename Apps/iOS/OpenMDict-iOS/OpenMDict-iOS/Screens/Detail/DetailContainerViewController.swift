//
//  DetailContainerViewController.swift
//  OpenMDict-iOS
//
//  Container managing detail view for different size classes
//  SOURCE OF TRUTH for articles state and navigation bar
//

import UIKit
import Combine
import OpenMDictKit

class DetailContainerViewController: UIViewController {
    
    // MARK: - Source of Truth
    
    private var articles: [ArticleDisplayItem] = []
    private var layoutMode: ArticleLayoutMode = .columns
    private var appearanceMode: AppearanceMode = UserDefaults.standard.appearanceMode
    
    /// Called when articles become empty (for compact mode navigation)
    var onArticlesEmptied: (() -> Void)?
    
    /// Subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    /// All articles (for state restoration)
    var allArticles: [ArticleDisplayItem] { articles }
    
    /// Current layout mode (for state restoration)
    var currentLayoutMode: ArticleLayoutMode { layoutMode }
    
    // MARK: - Child View Controllers
    
    private lazy var articlesVC: ArticlesViewController = {
        let vc = ArticlesViewController()
        vc.delegate = self
        vc.cellDelegate = self
        return vc
    }()
    
    private lazy var articleVC: ArticleViewController = {
        let vc = ArticleViewController()
        vc.delegate = self
        return vc
    }()
    
    private var activeChild: UIViewController?
    
    // MARK: - Navigation Bar Items (Regular mode - Segments)
    
    private var layoutSegment: UISegmentedControl {
        let seg = UISegmentedControl(items: ArticleLayoutMode.allCases.map { $0.icon })
        seg.selectedSegmentIndex = layoutMode.rawValue
        seg.addTarget(self, action: #selector(layoutChanged), for: .valueChanged)
        return seg
    }
    
    private var appearanceSegment: UISegmentedControl {
        let seg = UISegmentedControl(items: [
            UIImage(systemName: "sun.max")!,
            UIImage(systemName: "circle.lefthalf.filled")!,
            UIImage(systemName: "moon")!,
        ])
        seg.selectedSegmentIndex = appearanceMode.rawValue
        seg.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)
        return seg
    }
    
    private var appearanceIcon: UIImage {
        switch appearanceMode {
        case .light: UIImage(systemName: "sun.max")!
        case .system: UIImage(systemName: "circle.lefthalf.filled")!
        case .dark: UIImage(systemName: "moon")!
        }
    }
  
    private let searchController = UISearchController()
    
    // MARK: - Navigation Bar Items (Compact mode - Menus)
    
    private lazy var layoutMenu: UIMenu = {
        UIMenu(title: "Layout", children:
           ArticleLayoutMode.allCases.map { mode in
                UIAction(title: mode.title, image: mode.icon) { _ in }
           }
        )
    }()
    
    private var appearanceMenu: UIMenu {
        UIMenu(title: "Appearance", children: [
            UIAction(title: "Light", image: .init(systemName: "sun.max"),
                     state: appearanceMode == .light ? .on : .off) { [weak self] _ in
                self?.setAppearanceMode(.light)
            },
            UIAction(title: "Auto", image: .init(systemName: "circle.lefthalf.filled"),
                     state: appearanceMode == .system ? .on : .off) { [weak self] _ in
                self?.setAppearanceMode(.system)
            },
            UIAction(title: "Dark", image: .init(systemName: "moon"),
                     state: appearanceMode == .dark ? .on : .off) { [weak self] _ in
                self?.setAppearanceMode(.dark)
            },
        ])
    }
    
    private lazy var zoomMenu: UIMenu = {
        if #available(iOS 16.0, *) {
            UIMenu(title: "Zoom", preferredElementSize: .small, children: [
                UIAction(title: "Zoom out", image: UIImage(systemName: "minus.magnifyingglass"), attributes: .keepsMenuPresented) { _ in },
                UIAction(title: "Reset", image: UIImage(systemName: "1.magnifyingglass"), attributes: .keepsMenuPresented) { _ in },
                UIAction(title: "Zoom in", image: UIImage(systemName: "plus.magnifyingglass"), attributes: .keepsMenuPresented) { _ in },
            ])
        } else {
            UIMenu(title: "Zoom", children: [
                UIAction(title: "Zoom out", image: UIImage(systemName: "minus.magnifyingglass")) { _ in },
                UIAction(title: "Reset", image: UIImage(systemName: "1.magnifyingglass")) { _ in },
                UIAction(title: "Zoom in", image: UIImage(systemName: "plus.magnifyingglass")) { _ in },
            ])
        }
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        
        // Install appropriate child for current traits
        updateChildForTraits(traitCollection)
        updateNavigationBar(for: traitCollection)
        subscribeToDictionaryLoads()
        subscribeToAppearanceChanges()
        subscribeToArticleMoved()
        loadPendingArticlesIfReady()
        applyAppearance()
    }
    
    private func subscribeToAppearanceChanges() {
        NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self else { return }
            let mode = notif.object as? AppearanceMode
            
            Task { @MainActor in
                guard let mode else { return }
                self.appearanceMode = mode
                self.applyAppearance()
                self.updateNavigationBar(for: self.traitCollection)
            }
        }
    }

    
    override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)
        
        // Pass in newCollection instead of self.traitCollection
        coordinator.animate { _ in
            self.updateChildForTraits(newCollection)
            self.updateNavigationBar(for: newCollection)
        }
    }
    
    private func subscribeToArticleMoved() {
        NotificationCenter.default.addObserver(
            forName: .articleMovedToNewScene,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self else { return }
            // Extract Sendable values immediately
            let articleId = notif.userInfo?["articleId"] as? String
            let sourceSessionId = notif.userInfo?["sourceSessionId"] as? String
            
            Task { @MainActor in
                self.handleArticleMovedToNewScene(articleId: articleId, sourceSessionId: sourceSessionId)
            }
        }
    }

    /// Handle notification when an article was dragged to a new window
    private func handleArticleMovedToNewScene(articleId: String?, sourceSessionId: String?) {
        guard let articleId, let sourceSessionId else {
            return
        }

        // Check if this is the source window
        guard let mySessionId = view.window?.windowScene?.session.persistentIdentifier,
              mySessionId == sourceSessionId else {
            return  // Not from this window, ignore
        }

        // Remove the article from this window
        if let index = articles.firstIndex(where: { $0.id == articleId }) {
            articles.remove(at: index)
            print("📤 Removed dragged article: \(articleId)")
            syncStateToActiveChild()

            // If articles empty and compact mode, notify to show supplementary
            if articles.isEmpty {
                onArticlesEmptied?()
            }
        }
    }
    

    // MARK: - Dictionary Load Subscription

    private func subscribeToDictionaryLoads() {
        DictionaryService.shared.onDictionaryLoaded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dict in
                self?.handleDictionaryLoaded(dict)
            }
            .store(in: &cancellables)
    }

    /// When a dictionary loads, update any pending articles from that dictionary
    private func handleDictionaryLoaded(_ dict: MDict) {
        var didUpdate = false

        for (index, article) in articles.enumerated() {
            guard case .pending = article.contentState,
                  article.dictId == dict.id else { continue }

            // Try to look up the word now that dictionary is loaded
            if let entry = dict.lookup(article.word) {
                articles[index].contentState = .loaded(html: entry.article.html, css: nil)
                print("📖 Loaded pending article: \(article.word) from \(dict.id)")
            } else {
                articles[index].contentState = .notFound
                print("⚠️ Word not found: \(article.word) in \(dict.id)")
            }
            didUpdate = true
        }

        if didUpdate {
            syncStateToActiveChild()
        }
    }
    
    /// Load pending articles if their dictionaries are already loaded
    /// Called on viewDidLoad to handle cases where dict loaded before this VC
    private func loadPendingArticlesIfReady() {
        var didUpdate = false
        for (index, article) in articles.enumerated() {
            guard case .pending = article.contentState else { continue }

            // Check if dictionary is already loaded
            guard let dict = DictionaryService.shared.dict(id: article.dictId),
                  dict.state == .loaded else { continue }

            if let entry = dict.lookup(article.word) {
                articles[index].contentState = .loaded(html: entry.article.html, css: nil)
                print("📖 Loaded pending article (on init): \(article.word) from \(dict.id)")
            } else {
                articles[index].contentState = .notFound
                print("⚠️ Word not found (on init): \(article.word) in \(dict.id)")
            }
            didUpdate = true
        }

        if didUpdate {
            syncStateToActiveChild()
        }
    }
    
    // MARK: - Child Management
    
    private func updateChildForTraits(_ traits: UITraitCollection) {
        let shouldUseArticlesVC = traits.horizontalSizeClass == .regular
        let targetChild = shouldUseArticlesVC ? articlesVC : articleVC
        
        guard targetChild !== activeChild else {
            print("🔄 → Already correct child, skipping")
            return
        }
        
        // Remove old child
        if let old = activeChild {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        
        // Add new child
        addChild(targetChild)
        targetChild.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(targetChild.view)
        NSLayoutConstraint.activate([
            targetChild.view.topAnchor.constraint(equalTo: view.topAnchor),
            targetChild.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            targetChild.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            targetChild.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        targetChild.didMove(toParent: self)
        activeChild = targetChild
        
        // Sync state to new child
        syncStateToActiveChild()
    }
    
    private func syncStateToActiveChild() {
        if activeChild === articlesVC {
            articlesVC.configure(articles: articles, animated: false)
            articlesVC.applyLayout(layoutMode, animated: false)
        } else {
            articleVC.configure(article: articles.first)
        }
    }
    
    // MARK: - Navigation Bar
    
    private func updateNavigationBar(for traits: UITraitCollection) {
        let isRegular = traits.horizontalSizeClass == .regular
        
        navigationItem.title = nil
        navigationItem.titleView = nil
        
        if isRegular {
            setupRegularNavigationBar()
            setupSearchBar(placeholder: "Search opened articles for keywords...")
        } else {
            setupCompactNavigationBar()
            setupSearchBar(placeholder: "keywords...")
        }
    }
    
    private func setupRegularNavigationBar() {
        if #available(iOS 16, *) {
            navigationItem.style = .browser
            
            // TODO: research whether & should this API can be used
            // navigationItem.titleMenuProvider =
            
            navigationItem.leadingItemGroups = [
                .fixedGroup(
                    representativeItem: .init(
                        title: "Layout",
                        image: .init(systemName: "rectangle.and.text.magnifyingglass"),
                        menu: layoutMenu
                    ),
                    items: [.init(customView: layoutSegment)]
                ),
                .optionalGroup(
                    customizationIdentifier: "appearance",
                    representativeItem: .init(
                        title: "Appearance",
                        image: appearanceIcon,
                        menu: appearanceMenu
                    ),
                    items: [.init(customView: appearanceSegment)]
                ),
            ]
            
            navigationItem.centerItemGroups = [
                .optionalGroup(
                    customizationIdentifier: "zoom",
                    representativeItem: .init(
                        title: "Zoom",
                        image: .init(systemName: "textformat.size"),
                        menu: zoomMenu
                    ),
                    items: [
                        .init(title: "Zoom out", image: .init(systemName: "minus.magnifyingglass")),
                        .init(title: "Reset", image: .init(systemName: "1.magnifyingglass")),
                        .init(title: "Zoom in", image: .init(systemName: "plus.magnifyingglass")),
                    ]
                ),
            ]
            
            navigationItem.trailingItemGroups = []
            
        } else {
            // iOS 15: Best effort with standard items
            navigationItem.leftBarButtonItems = [
                .init(customView: layoutSegment),
                .init(customView: appearanceSegment)
            ]
            navigationItem.rightBarButtonItems = [
                .init(title: "Zoom out", image: .init(systemName: "minus.magnifyingglass"), primaryAction: nil),
                .init(title: "Reset", image: .init(systemName: "1.magnifyingglass"), primaryAction: nil),
                .init(title: "Zoom in", image: .init(systemName: "plus.magnifyingglass"), primaryAction: nil),
            ]
        }
        
        
    }
    
    private func setupCompactNavigationBar() {
        if #available(iOS 16, *) {
            navigationItem.style = .browser
            navigationItem.leadingItemGroups = []
            navigationItem.centerItemGroups = []
            navigationItem.trailingItemGroups = [
                .optionalGroup(
                    customizationIdentifier: "appearance",
                    representativeItem: .init(
                        title: "Appearance",
                        image: appearanceIcon,
                        menu: appearanceMenu
                    ),
                    items: [.init(customView: appearanceSegment)]
                ),
                .optionalGroup(
                    customizationIdentifier: "zoom",
                    representativeItem: .init(
                        title: "Zoom",
                        image: .init(systemName: "textformat.size"),
                        menu: zoomMenu
                    ),
                    items: [
                        .init(title: "Zoom out", image: .init(systemName: "minus.magnifyingglass")),
                        .init(title: "Reset", image: .init(systemName: "1.magnifyingglass")),
                        .init(title: "Zoom in", image: .init(systemName: "plus.magnifyingglass")),
                    ]
                ),
            ]
        } else {
            navigationItem.leftBarButtonItems = []
            navigationItem.rightBarButtonItems = [
                .init(title: "Appearance", image: .init(systemName: "circle.lefthalf.filled"), menu: appearanceMenu),
                .init(title: "Zoom", image: .init(systemName: "textformat.size"), menu: zoomMenu),
            ]
        }
    }
    
    private func setupSearchBar(placeholder: String) {
        searchController.delegate = self
        // TODO: TO BE IMPLEMENTED
        // searchController.searchResultsUpdater = self
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.placeholder = placeholder
        // TODO: only highlight the keywords after WKWebView is implmented, but maybe also provide `next`/`previous` navigation?
        // searchController.searchBar.delegate = self

        navigationItem.searchController = searchController
        if #available(iOS 26, *) {
            navigationItem.preferredSearchBarPlacement = .integratedButton
        } else if #available(iOS 16, *) {
            navigationItem.preferredSearchBarPlacement = .inline
        }
    }

    // MARK: - Public API (called by MainSplitVC)
    
    func pushArticle(_ article: ArticleDisplayItem, animated: Bool) {
        // Check if already exists
        if let existingIndex = articles.firstIndex(of: article) {
            // Move to front
            articles.remove(at: existingIndex)
            articles.insert(article, at: 0)
        } else {
            articles.insert(article, at: 0)
        }
        
        // Update child
        if activeChild === articlesVC {
            articlesVC.configure(articles: articles, animated: animated)
            articlesVC.scrollToArticle(article, animated: animated)
        } else {
            articleVC.configure(article: article)
        }
    }
    
    func preloadArticle(_ article: ArticleDisplayItem) {
        guard !articles.contains(article) else { return }
        articles.append(article)
    }
    
    func closeArticle(_ article: ArticleDisplayItem) {
        guard let index = articles.firstIndex(of: article) else { return }
        articles.remove(at: index)
        
        if activeChild === articlesVC {
            articlesVC.configure(articles: articles, animated: true)
        } else {
            articleVC.configure(article: articles.first)
        }
        
        // TODO: Show some placeholder articles become empty
    }
    
    /// Set layout mode (for state restoration)
    func setLayoutMode(_ mode: ArticleLayoutMode) {
        layoutMode = mode
        // Will be applied when view loads
    }
    
    // MARK: - Actions
    
    @objc private func layoutChanged(_ sender: UISegmentedControl) {
        guard let mode = ArticleLayoutMode(rawValue: sender.selectedSegmentIndex) else { return }
        layoutMode = mode
        articlesVC.applyLayout(mode, animated: true)
    }
    
    @objc private func appearanceChanged(_ sender: UISegmentedControl) {
        appearanceMode = AppearanceMode(rawValue: sender.selectedSegmentIndex) ?? .system
        setAppearanceMode(appearanceMode)
    }

    /// Set appearance mode and broadcast to all windows
    private func setAppearanceMode(_ mode: AppearanceMode) {
        UserDefaults.standard.appearanceMode = mode
        NotificationCenter.default.post(name: .appearanceModeDidChange, object: mode)
    }
    
    private func applyAppearance() {
        view.window?.overrideUserInterfaceStyle = appearanceMode.userInterfaceStyle
   
        // Refresh nav bar to update representativeItem icon
        updateNavigationBar(for: traitCollection)
    }
    
    @objc private func zoomChanged(_ sender: UISegmentedControl) {
        print("🔍 Zoom: \(sender.selectedSegmentIndex)")
    }
}

// MARK: - ArticlesViewControllerDelegate

extension DetailContainerViewController: ArticlesViewControllerDelegate {
    func articlesViewController(_ vc: ArticlesViewController, didCloseArticle article: ArticleDisplayItem) {
        closeArticle(article)
    }
    
    func articlesViewController(_ vc: ArticlesViewController, didSelectArticle article: ArticleDisplayItem) {
        print("📖 Selected: \(article.word)")
    }
    
    func articlesViewController(_ vc: ArticlesViewController, didRequestFocusOn article: ArticleDisplayItem) {
        // Switch to columns
        layoutMode = .columns
        
        // Update child and nav bar
        articlesVC.configure(articles: articles, animated: false)
        articlesVC.applyLayout(.columns, animated: true)
        articlesVC.scrollToArticle(article, animated: true)
        updateNavigationBar(for: traitCollection)
    }
}

// MARK: - ArticleCellDelegate (Entry Links)

extension DetailContainerViewController: ArticleCellDelegate, ArticleViewControllerDelegate {

    private func handleEntryLink(word: String, dictId: String) {
        // Check if we already have this article
        let articleId = "\(dictId):\(word)"
        if let existingIndex = articles.firstIndex(where: { $0.id == articleId }) {
            // Move to front
            let article = articles.remove(at: existingIndex)
            articles.insert(article, at: 0)
        } else {
            // Create new article - try to load content if dictionary is ready
            let dict = DictionaryService.shared.dict(id: dictId)
            let dictName = dict?.metadata?.title ?? dictId

            var article = ArticleDisplayItem.pending(word: word, dictId: dictId, dictName: dictName)
            if let dict = dict, let entry = dict.lookup(word) {
                article.contentState = .loaded(html: entry.article.html, css: nil)
            }
            articles.insert(article, at: 0)
        }

        syncStateToActiveChild()
        articlesVC.scrollToArticle(articles.first!, animated: true)
    }

    func articleCell(_ cell: ArticleCell, didTapEntryLink word: String, inDict dictId: String) {
        print("📖 Entry link (cell): \(word) in \(dictId)")
        handleEntryLink(word: word, dictId: dictId)
    }
    
    func articleViewController(_ vc: ArticleViewController, didTapEntryLink word: String, inDict dictId: String) {
        print("📖 Entry link (vc): \(word) in \(dictId)")
        handleEntryLink(word: word, dictId: dictId)
    }
}

extension DetailContainerViewController: UISearchControllerDelegate {
    
    func presentSearchController(_ searchController: UISearchController) {
        //Swift.debugPrint("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func willPresentSearchController(_ searchController: UISearchController) {
        //Swift.debugPrint("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func didPresentSearchController(_ searchController: UISearchController) {
        //Swift.debugPrint("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func willDismissSearchController(_ searchController: UISearchController) {
        //Swift.debugPrint("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func didDismissSearchController(_ searchController: UISearchController) {
        //Swift.debugPrint("UISearchControllerDelegate invoked method: \(#function).")
    }
    
}
