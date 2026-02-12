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
    
    private let instanceID = UUID().uuidString.prefix(8)
    
    // MARK: - Source of Truth
    
    private var articles: [ArticleDisplayItem] = []
    private var layoutMode: ArticleLayoutMode = .columns
    private var appearanceMode: AppearanceMode = UserDefaults.standard.appearanceMode
    private var zoom = ZoomLevel()
     
    /// Called when articles become empty (for compact mode navigation)
    var onArticlesEmptied: (() -> Void)?
    
    /// Subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    /// Per-dictionary subscriptions for pending articles (dictId → subscription)
    private var pendingDictSubscriptions: [String: AnyCancellable] = [:]
    
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
        UIMenu(title: L10n.Detail.layout, children:
           ArticleLayoutMode.allCases.map { mode in
                UIAction(title: mode.title, image: mode.icon) { _ in }
           }
        )
    }()
    
    private var appearanceMenu: UIMenu {
        UIMenu(title: L10n.Detail.appearance, children: [
            UIAction(title: L10n.Detail.light, image: .init(systemName: "sun.max"),
                     state: appearanceMode == .light ? .on : .off) { [weak self] _ in
                self?.setAppearanceMode(.light)
            },
            UIAction(title: L10n.Detail.auto, image: .init(systemName: "circle.lefthalf.filled"),
                     state: appearanceMode == .system ? .on : .off) { [weak self] _ in
                self?.setAppearanceMode(.system)
            },
            UIAction(title: L10n.Detail.dark, image: .init(systemName: "moon"),
                     state: appearanceMode == .dark ? .on : .off) { [weak self] _ in
                self?.setAppearanceMode(.dark)
            },
        ])
    }
    
    private var zoomMenu: UIMenu {
        let title = L10n.Detail.currentZoomLevel(zoom.displayString)
        
        let zoomInAction = UIAction(
            title: L10n.Detail.zoomIn,
            image: UIImage(systemName: "plus.magnifyingglass"),
            attributes: zoom.canZoomIn ? [] : .disabled
        ) { [weak self] _ in
            self?.zoomIn()
        }
        
        let resetAction = UIAction(
            title: L10n.Detail.reset,
            image: UIImage(systemName: "1.magnifyingglass"),
            attributes: zoom.isDefault ? .disabled : []
        ) { [weak self] _ in
            self?.resetZoom()
        }
        
        let zoomOutAction = UIAction(
            title: L10n.Detail.zoomOut,
            image: UIImage(systemName: "minus.magnifyingglass"),
            attributes: zoom.canZoomOut ? [] : .disabled
        ) { [weak self] _ in
            self?.zoomOut()
        }
        
        if #available(iOS 16.0, *) {
            return UIMenu(title: title, preferredElementSize: .small, children: [
                zoomOutAction, resetAction, zoomInAction
            ])
        } else {
            return UIMenu(title: title, children: [
                zoomInAction, resetAction, zoomOutAction
            ])
        }
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        debugLog("📐 [\(instanceID)] DetailContainer.viewDidLoad - safeArea: \(view.safeAreaInsets), frame: \(view.frame)")
        
        view.backgroundColor = .systemGroupedBackground
        
        // Install appropriate child for current traits
        updateChildForTraits(traitCollection)
        updateNavigationBar(for: traitCollection)
        
        subscribeToAppearanceChanges()
        subscribeToArticleMoved()
        
        loadPendingArticlesIfReady()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        debugLog("📐 [\(instanceID)] DetailContainer.viewWillAppear - safeArea: \(view.safeAreaInsets), frame: \(view.frame)")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        debugLog("📐 [\(instanceID)] DetailContainer.viewDidAppear - safeArea: \(view.safeAreaInsets), frame: \(view.frame)")
        
        // Apply appearance after window is available
        applyAppearance()
    }
    
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        debugLog("📐 [\(instanceID)] DetailContainer.viewSafeAreaInsetsDidChange - safeArea: \(view.safeAreaInsets)")

        // Child VC's safe area updates after parent's
        // Delay to ensure safe area has propagated to child
        if activeChild === articlesVC {
            DispatchQueue.main.async { [weak self] in
                self?.articlesVC.invalidateLayoutForSafeAreaChange()
            }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        debugLog("📐 [\(instanceID)] DetailContainer.viewDidLayoutSubviews - safeArea: \(view.safeAreaInsets), frame: \(view.frame)")
        if let child = activeChild {
            debugLog("📐 [\(instanceID)] DetailContainer.viewDidLayoutSubviews - child.view.frame: \(child.view.frame)")
        }
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
        debugLog("📐 [\(instanceID)] DetailContainer.willTransition - from \(traitCollection.horizontalSizeClass.rawValue) to \(newCollection.horizontalSizeClass.rawValue)")

        coordinator.animate { _ in
            self.updateChildForTraits(newCollection)
            self.updateNavigationBar(for: newCollection)
        } completion: { _ in
            // Safe area propagation only completes after the transition animation finishes.
            // Force layout rebuild here to ensure correct cell positioning.
            if newCollection.horizontalSizeClass == .regular {
                debugLog("📐 [\(self.instanceID)] DetailContainer.willTransition completion - triggering layout rebuild")
                self.articlesVC.invalidateLayoutForSafeAreaChange()
            }
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
            debugLog("📤 [\(instanceID)] Removed dragged article: \(articleId)")
            syncStateToActiveChild()

            // If articles empty and compact mode, notify to show supplementary
            if articles.isEmpty {
                onArticlesEmptied?()
            }
        }
    }
    

    // MARK: - Pending Article Subscriptions

    /// Subscribe to a specific dictionary's load state for pending articles
    /// Uses flatMap to handle race condition: dict may not exist yet in allDictionaries
    private func subscribeToDict(id: String) {
        // Already subscribed
        guard pendingDictSubscriptions[id] == nil else { return }

        // Chain: wait for dict to appear in allDictionaries → wait for it to load
        pendingDictSubscriptions[id] = DictionaryService.shared.$allDictionaries
            .compactMap { dicts in dicts.first { $0.id == id } }  // Wait for dict to appear
            .first()  // Only take first appearance
            .flatMap { dict in
                dict.$state
                    .filter { $0 == .loaded }
                    .map { _ in dict }  // Preserve dict reference
                    .first()  // Only take first loaded event
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dict in
                self?.handleDictLoaded(dict)
            }
    }

    /// When a subscribed dictionary loads, update its pending articles
    private func handleDictLoaded(_ dict: MDict) {
        var didUpdate = false

        for (index, article) in articles.enumerated() {
            guard case .pending = article.contentState,
                  article.dictId == dict.id else { continue }

            // Try to look up the word now that dictionary is loaded
            if let entry = dict.lookup(article.word) {
                articles[index].contentState = .loaded(html: entry.article.html, css: nil)
                debugLog("📖 Loaded pending article: \(article.word) from \(dict.id)")
            } else {
                articles[index].contentState = .notFound
                debugLog("⚠️ Word not found: \(article.word) in \(dict.id)")
            }
            didUpdate = true
        }

        if didUpdate {
            syncStateToActiveChild()
        }
        
        // Cleanup subscription
        pendingDictSubscriptions.removeValue(forKey: dict.id)
    }
    
    /// Load pending articles if their dictionaries are already loaded
    /// Called on viewDidLoad to handle cases where dict loaded before this VC
    private func loadPendingArticlesIfReady() {
        var didUpdate = false
        for (index, article) in articles.enumerated() {
            guard case .pending = article.contentState else { continue }

            // Check if dictionary exists and is already loaded
            guard let dict = DictionaryService.shared.dict(id: article.dictId),
                  dict.state == .loaded else { continue }

            if let entry = dict.lookup(article.word) {
                articles[index].contentState = .loaded(html: entry.article.html, css: nil)
                debugLog("📖 Loaded pending article (on init): \(article.word) from \(dict.id)")
            } else {
                articles[index].contentState = .notFound
                debugLog("⚠️ Word not found (on init): \(article.word) in \(dict.id)")
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

        debugLog("📐 [\(instanceID)] DetailContainer.updateChildForTraits - shouldUseArticlesVC: \(shouldUseArticlesVC), current activeChild: \(activeChild == nil ? "nil" : (activeChild === articlesVC ? "articlesVC" : "articleVC"))")
        debugLog("📐 [\(instanceID)] DetailContainer.updateChildForTraits - my safeArea: \(view.safeAreaInsets), my frame: \(view.frame)")

        guard targetChild !== activeChild else {
            print("[\(instanceID)] 🔄 → Already correct child, skipping")
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
            // ORIGINAL: view.topAnchor
            targetChild.view.topAnchor.constraint(equalTo: view.topAnchor),
            targetChild.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            targetChild.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            targetChild.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        targetChild.didMove(toParent: self)
        activeChild = targetChild
        debugLog("📐 [\(instanceID)] DetailContainer.updateChildForTraits - after install, child.view.frame: \(targetChild.view.frame)")

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
            if #available(iOS 16, *) {
                setupSearchBar(placeholder: L10n.Detail.keywordsPlaceholder)
            }
        } else {
            setupCompactNavigationBar()
            navigationItem.searchController = nil
        }
    }
    
    private func setupRegularNavigationBar() {
        if #available(iOS 16, *) {
            navigationItem.style = .browser
            
            navigationItem.leadingItemGroups = [
                .fixedGroup(
                    representativeItem: .init(
                        title: L10n.Detail.layout,
                        image: .init(systemName: "rectangle.and.text.magnifyingglass"),
                        menu: layoutMenu
                    ),
                    items: [.init(customView: layoutSegment)]
                ),
                .optionalGroup(
                    customizationIdentifier: "appearance",
                    representativeItem: .init(
                        title: L10n.Detail.appearance,
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
                        title: L10n.Detail.zoom,
                        image: .init(systemName: "textformat.size"),
                        menu: zoomMenu
                    ),
                    items: [
                        .init(title: L10n.Detail.zoomOut, image: .init(systemName: "minus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.zoomOut()
                        }),
                        .init(title: zoom.displayString, image: .init(systemName: "1.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.resetZoom()
                        }),
                        .init(title: L10n.Detail.zoomIn, image: .init(systemName: "plus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.zoomIn()
                        }),
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
                .init(title: L10n.Detail.zoomIn, image: .init(systemName: "plus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                    self?.zoomIn()
                }),
                .init(title: L10n.Detail.reset, image: .init(systemName: "1.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                    self?.resetZoom()
                }),
                .init(title: L10n.Detail.zoomOut, image: .init(systemName: "minus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                    self?.zoomOut()
                }),
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
                        title: L10n.Detail.appearance,
                        image: appearanceIcon,
                        menu: appearanceMenu
                    ),
                    items: [.init(customView: appearanceSegment)]
                ),
                .optionalGroup(
                    customizationIdentifier: "zoom",
                    representativeItem: .init(
                        title: L10n.Detail.currentLevel(zoom.displayString),
                        image: .init(systemName: "textformat.size"),
                        menu: zoomMenu
                    ),
                    items: [
                        .init(title: L10n.Detail.zoomOut, image: .init(systemName: "minus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.zoomOut()
                        }),
                        .init(title: L10n.Detail.reset, image: .init(systemName: "1.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.resetZoom()
                        }),
                        .init(title: L10n.Detail.zoomIn, image: .init(systemName: "plus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.zoomIn()
                        }),
                    ]
                ),
                .fixedGroup(
                    items: [
                        .init(title: L10n.Detail.find, image: .init(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.presentFind()
                        }),
                    ]
                ),
            ]
        } else {
            navigationItem.leftBarButtonItems = []
            navigationItem.rightBarButtonItems = [
                .init(title: L10n.Detail.appearance, image: .init(systemName: "circle.lefthalf.filled"), menu: appearanceMenu),
                .init(title: L10n.Detail.zoom, image: .init(systemName: "textformat.size"), menu: zoomMenu),
            ]
        }
    }
    
    private func setupSearchBar(placeholder: String) {
        searchController.delegate = self
        searchController.searchResultsUpdater = self
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.placeholder = placeholder

        navigationItem.searchController = searchController
        if #available(iOS 26, *) {
            navigationItem.preferredSearchBarPlacement = .integratedButton
        } else if #available(iOS 16, *) {
            navigationItem.preferredSearchBarPlacement = .inline
        }
    }

    // MARK: - Public API (called by MainSplitVC)
    
    func pushArticle(_ article: ArticleDisplayItem, animated: Bool) {
        // Check if already exists (by id, not full Equatable which includes contentState)
        if let existingIndex = articles.firstIndex(where: { $0.id == article.id }) {
            // Update content state if the existing one is pending and the new one is loaded
            var updated = article
            if case .pending = articles[existingIndex].contentState,
               case .pending = article.contentState {
                // Both pending — just move to front
                updated = articles[existingIndex]
            }
            articles.remove(at: existingIndex)
            articles.insert(updated, at: 0)
        } else {
            articles.insert(article, at: 0)
            // If pending, subscribe to the dictionary's load state
            if case .pending = article.contentState {
                subscribeToDict(id: article.dictId)
            }
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
        
        // If pending, subscribe to the dictionary's load state
        if case .pending = article.contentState {
            subscribeToDict(id: article.dictId)
        }
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
    
    // MARK: - Zoom

    private func zoomIn() {
        zoom.zoomIn()
        applyZoom()
    }

    private func zoomOut() {
        zoom.zoomOut()
        applyZoom()
    }

    private func resetZoom() {
        zoom.reset()
        applyZoom()
    }

    private func applyZoom() {
        print("🔍 Zoom level: \(zoom.displayString)")

        // Apply to child VCs
        articlesVC.setZoomLevel(zoom.current)
        articleVC.setZoomLevel(zoom.current)

        // Update nav bar to refresh zoom menu
        updateNavigationBar(for: traitCollection)
    }

    // MARK: - Find in Page

    private func presentFind() {
        guard #available(iOS 16.0, *) else { return }
        
        if activeChild === articleVC {
            articleVC.toggleFind()
        }
    }
    
    // MARK: - Keyboard Shortcuts

    override var keyCommands: [UIKeyCommand]? {
        guard #available(iOS 16.0, *) else { return nil }
        
        // Only intercept ⌘F in Regular mode (ArticlesVC)
        // In Compact mode (ArticleVC), let WebView handle it natively
        if traitCollection.horizontalSizeClass == .regular {
            return [UIKeyCommand(title: L10n.Detail.find, action: #selector(handleFindShortcut), input: "f", modifierFlags: .command)]
        }
        return nil
    }

    @objc private func handleFindShortcut() {
        // Toggle search bar focus in Regular mode
        if searchController.isActive {
            searchController.isActive = false
        } else {
            searchController.isActive = true
            searchController.searchBar.becomeFirstResponder()
        }
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
            } else {
                // Dictionary not loaded yet, subscribe to its load state
                subscribeToDict(id: dictId)
            }
            articles.insert(article, at: 0)
        }

        syncStateToActiveChild()
        articlesVC.scrollToArticle(articles.first!, animated: true)

        // Record lookup history
        let historyDictName = DictionaryService.shared.dict(id: dictId)?.metadata?.title ?? dictId
        LookupHistoryService.shared.recordLookup(
            word: word, dictId: dictId, dictName: historyDictName
        )
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

// MARK: - UISearchResultsUpdating (Regular mode - JS highlight)

extension DetailContainerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        if #available(iOS 16, *) {
            let keyword = searchController.searchBar.text
            articlesVC.highlightKeywordInAllCells(keyword)
        }
    }
}
