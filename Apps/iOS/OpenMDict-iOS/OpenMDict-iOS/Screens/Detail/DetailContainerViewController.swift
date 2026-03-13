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
    private var currentCompactIndex: Int = 0
    private var layoutMode: ArticleLayoutMode = .columns
    private var appearanceMode: AppearanceMode = UserDefaults.standard.appearanceMode
    private var zoom = ZoomLevel()
    /// Stored references for in-place zoom/slider updates (avoids rebuilding entire nav bar)
    private weak var zoomSlider: UISlider?
    private weak var zoomRepresentativeItem: UIBarButtonItem?
    /// iOS 15 fallback: stored references for 3 dedicated zoom buttons
    private weak var zoomOutItem: UIBarButtonItem?
    private weak var zoomResetItem: UIBarButtonItem?
    private weak var zoomInItem: UIBarButtonItem?

    /// Current articles capacity limit from Settings.bundle, scaled by device RAM.
    private var articlesCapacityLimit: Int = UserDefaults.standard.articlesCapacity.limit
     
    /// Current lookup context for recording entry-link lookups.
    /// Set by MainSplitViewController whenever the search context changes.
    var lookupContext: (dictId: String?, groupId: String?)?

    /// Called when articles become empty (for compact mode navigation)
    var onArticlesEmptied: (() -> Void)?

    /// Called when Jump Search fails to find the word in the same dictionary.
    /// Fallback: put the word in the search bar (wired by MainSplitVC).
    var onJumpSearchFallback: ((String) -> Void)?

    /// Called when find-in-page search bar becomes active / is dismissed.
    var onSearchActivated: (() -> Void)?
    var onSearchDeactivated: (() -> Void)?

    /// True while a `willTransition(to:with:)` animation is in-flight.
    /// Prevents `ensureCorrectChild()` in `viewDidLayoutSubviews` from
    /// fighting with the transition (self.traitCollection is still the OLD
    /// value during the animation block, so ensureCorrectChild would bounce
    /// the child VCs back and forth).
    private var isTransitioning = false

    /// Subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    /// Per-dictionary subscriptions for pending articles (dictId → subscription)
    private var pendingDictSubscriptions: [String: AnyCancellable] = [:]
    
    /// All articles (for state restoration)
    var allArticles: [ArticleDisplayItem] { articles }

    /// Index of the article currently visible to the user.
    /// Regular mode: visible cell in articlesVC. Compact: current pager page.
    var currentVisibleArticleIndex: Int {
        if activeChild === articlesVC {
            return articlesVC.visibleArticleIndex ?? 0
        } else if activeChild === articleVC {
            return articleVC.currentPageIndex
        }
        return currentCompactIndex
    }

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
    
    private let searchController = UISearchController()

    // MARK: - Navigation Bar Items (Compact mode - Menus)

    private lazy var layoutMenu: UIMenu = {
        UIMenu(title: L10n.Detail.layout, children:
           ArticleLayoutMode.allCases.map { mode in
                UIAction(title: mode.title, image: mode.icon) { _ in }
           }
        )
    }()

    /// Thin adapter: bridges shared ZoomLevel.menu factory to this VC's zoom methods.
    private var currentZoomMenu: UIMenu {
        zoom.menu(
            onZoomIn:  { [weak self] in self?.zoomIn() },
            onReset:   { [weak self] in self?.resetZoom() },
            onZoomOut: { [weak self] in self?.zoomOut() }
        )
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        debugLog("📐 [\(instanceID)] DetailContainer.viewDidLoad - safeArea: \(view.safeAreaInsets), frame: \(view.frame)")
        
        view.backgroundColor = .systemGroupedBackground
        
        // Register "Jump Search" menu item for WKWebView text selection
        ArticlePageView.registerJumpSearchMenuItem()

        // Install appropriate child for current traits
        updateChildForTraits(traitCollection)
        updateNavigationBar(for: traitCollection)

        subscribeToAppearanceChanges()
        subscribeToArticlesCapacityChanges()
        subscribeToArticleMoved()
        subscribeToDictMetadataChanges()

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
        // Skip during willTransition animation — self.traitCollection is still
        // the OLD value, so ensureCorrectChild would incorrectly switch back.
        if !isTransitioning {
            ensureCorrectChild()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.horizontalSizeClass != previousTraitCollection?.horizontalSizeClass {
            ensureCorrectChild()
        }
    }

    private func subscribeToAppearanceChanges() {
        // Cross-window sync via NotificationCenter (when user changes appearance in-app)
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

        // Settings.bundle sync: detect UserDefaults changes when returning from system Settings.
        // Settings.bundle writes to standard, so bridge the value to shared for Extension visibility.
        // Observe only `.standard` to avoid infinite loops from our own `.shared` writes.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let stored = UserDefaults.standard.appearanceMode
                guard stored != self.appearanceMode else { return }
                self.appearanceMode = stored
                UserDefaults.shared.setAppearanceModeStamped(stored)
                UserDefaults.standard.appearanceModeTimestamp = UserDefaults.shared.appearanceModeTimestamp
                self.applyAppearance()
                self.updateNavigationBar(for: self.traitCollection)
            }
        }
    }

    /// Detect changes to `articlesCapacity` from Settings.bundle and enforce immediately.
    /// Also bridges the value from `.standard` to `.shared` for Action Extension.
    private func subscribeToArticlesCapacityChanges() {
        // Observe only `.standard` — Settings.bundle writes there.
        // Using `object: nil` would also catch writes to `.shared`,
        // and the bridge line below writes to `.shared`, creating an
        // infinite notification loop that pins the CPU at 100%.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Bridge to shared (Action Extension reads shared)
                UserDefaults.shared.articlesCapacity = UserDefaults.standard.articlesCapacity
                UserDefaults.shared.showLookupCount = UserDefaults.standard.showLookupCount
                UserDefaults.shared.showEnhanceDarkMode = UserDefaults.standard.showEnhanceDarkMode

                self.articlesVC.refreshEnhanceDarkModeVisibility()
                self.articleVC.refreshEnhanceDarkModeVisibility()

                let newLimit = UserDefaults.standard.articlesCapacity.limit
                guard newLimit != self.articlesCapacityLimit else { return }
                self.articlesCapacityLimit = newLimit
                self.enforceCapacity()
            }
        }
    }

    override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)
        debugLog("📐 [\(instanceID)] DetailContainer.willTransition - from \(traitCollection.horizontalSizeClass.rawValue) to \(newCollection.horizontalSizeClass.rawValue)")

        isTransitioning = true

        coordinator.animate { _ in
            self.updateChildForTraits(newCollection)
            self.updateNavigationBar(for: newCollection)
        } completion: { _ in
            self.isTransitioning = false
            // Use self.traitCollection (the ACTUAL current traits, whether
            // the transition completed or was cancelled).
            self.ensureCorrectChild()
            // Safe area propagation only completes after the transition animation finishes.
            // Force layout rebuild here to ensure correct cell positioning.
            if self.traitCollection.horizontalSizeClass == .regular {
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

    /// React to DictMetadataService changes (e.g. user toggled enhanceDarkMode).
    /// Re-applies per-dict dark mode enhancement on all visible articles.
    private func subscribeToDictMetadataChanges() {
        DictMetadataService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.articlesVC.refreshDarkModeEnhance()
                self.articleVC.refreshDarkModeEnhance()
            }
            .store(in: &cancellables)
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

            // Adjust compact index
            if index < currentCompactIndex {
                currentCompactIndex -= 1
            } else if index == currentCompactIndex {
                currentCompactIndex = min(currentCompactIndex, articles.count - 1)
            }
            currentCompactIndex = max(0, currentCompactIndex)

            syncStateToActiveChild()

            if articles.isEmpty {
                onArticlesEmptied?()
            }
        }
    }
    

    // MARK: - Pending Article Subscriptions

    /// Subscribe to a specific dictionary's load state for pending articles.
    /// Waits for allDictionaries to populate, then either subscribes to the dict's
    /// load state or removes orphaned articles if the dict no longer exists.
    private func subscribeToDict(id: String) {
        // Already subscribed
        guard pendingDictSubscriptions[id] == nil else { return }

        // Wait for metadata to load (first non-empty emission), then branch
        pendingDictSubscriptions[id] = DictionaryService.shared.$allDictionaries
            .first { !$0.isEmpty }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dicts in
                guard let self else { return }
                self.pendingDictSubscriptions.removeValue(forKey: id)

                guard let dict = dicts.first(where: { $0.id == id }) else {
                    // Dictionary no longer exists — remove orphaned pending articles
                    self.removeOrphanedArticles(dictId: id)
                    return
                }

                // Dictionary exists — wait for it to finish loading
                if dict.state == .loaded {
                    self.handleDictLoaded(dict)
                } else {
                    self.pendingDictSubscriptions[id] = dict.$state
                        .filter { $0 == .loaded }
                        .first()
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] _ in
                            self?.handleDictLoaded(dict)
                        }
                }
            }
    }

    /// Remove pending articles whose dictionary no longer exists (e.g. deleted after session save).
    private func removeOrphanedArticles(dictId: String) {
        var indicesToRemove: [Int] = []
        for (index, article) in articles.enumerated() {
            if article.dictId == dictId, case .pending = article.contentState {
                indicesToRemove.append(index)
            }
        }
        guard !indicesToRemove.isEmpty else { return }

        for index in indicesToRemove.reversed() {
            debugLog("🗑️ Removing orphaned article: \(articles[index].word) (dict \(dictId) not imported)")
            articles.remove(at: index)
        }

        // Adjust compact index
        currentCompactIndex = articles.isEmpty ? 0 : min(currentCompactIndex, articles.count - 1)

        syncStateToActiveChild()

        if articles.isEmpty {
            onArticlesEmptied?()
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

        // Capture state from outgoing child before removing
        if activeChild === articleVC {
            // Switching from compact → regular: capture current page index
            currentCompactIndex = articleVC.currentPageIndex
        } else if activeChild === articlesVC {
            // Switching from regular → compact: capture visible article index
            currentCompactIndex = articlesVC.visibleArticleIndex ?? 0
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
        let childName = activeChild === articlesVC ? "articlesVC" : activeChild === articleVC ? "articleVC" : "nil"
        debugLog("🔄 [\(instanceID)] syncStateToActiveChild: \(articles.count) articles, activeChild=\(childName), compactIdx=\(currentCompactIndex)")
        if activeChild === articlesVC {
            articlesVC.configure(articles: articles, animated: false)
            articlesVC.applyLayout(layoutMode, animated: false)
        } else {
            articleVC.configure(articles: articles, currentIndex: currentCompactIndex)
        }
    }
    
    /// Defensive check: correct child VC if trait change animation was skipped or interrupted.
    /// O(1) pointer comparison in the normal case.
    private func ensureCorrectChild() {
        let shouldUseArticlesVC = traitCollection.horizontalSizeClass == .regular
        let targetChild: UIViewController = shouldUseArticlesVC ? articlesVC : articleVC
        guard targetChild !== activeChild else { return }

        debugLog("⚠️ [\(instanceID)] ensureCorrectChild: MISMATCH — expected \(shouldUseArticlesVC ? "articlesVC" : "articleVC"), correcting")
        updateChildForTraits(traitCollection)
        updateNavigationBar(for: traitCollection)
    }

    // MARK: - Navigation Bar

    private func updateNavigationBar(for traits: UITraitCollection) {
        let isRegular = traits.horizontalSizeClass == .regular
        
        navigationItem.title = nil
        navigationItem.titleView = nil
        navigationItem.largeTitleDisplayMode = .never
        
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
                        image: appearanceMode.icon,
                        menu: appearanceMode.menu { [weak self] m in self?.setAppearanceMode(m) }
                    ),
                    items: [.init(customView: appearanceMode.segmentedControl(target: self, action: #selector(appearanceChanged)))]
                ),
            ]

            let sliderContainer = makeZoomSliderContainer()
            let sliderItem = UIBarButtonItem(customView: sliderContainer)

            let zRep = UIBarButtonItem(title: L10n.Detail.zoom, image: .init(systemName: "textformat.size"), menu: currentZoomMenu)
            zoomRepresentativeItem = zRep

            navigationItem.centerItemGroups = [
                .fixedGroup(
                    representativeItem: zRep,
                    items: [sliderItem]
                ),
            ]
            
            navigationItem.trailingItemGroups = []

        } else {
            // iOS 15: Best effort with standard items
            navigationItem.leftBarButtonItems = [
                .init(customView: layoutSegment),
                .init(customView: appearanceMode.segmentedControl(target: self, action: #selector(appearanceChanged))),
            ]

            let zIn15 = UIBarButtonItem(title: L10n.Detail.zoomIn, image: .init(systemName: "plus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.zoomIn() })
            zIn15.isEnabled = zoom.canZoomIn
            let zReset15 = UIBarButtonItem(title: L10n.Detail.reset, image: .init(systemName: "1.magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.resetZoom() })
            zReset15.isEnabled = !zoom.isDefault
            let zOut15 = UIBarButtonItem(title: L10n.Detail.zoomOut, image: .init(systemName: "minus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.zoomOut() })
            zOut15.isEnabled = zoom.canZoomOut
            zoomInItem = zIn15; zoomResetItem = zReset15; zoomOutItem = zOut15
            navigationItem.rightBarButtonItems = [zIn15, zReset15, zOut15]
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
                        image: appearanceMode.icon,
                        menu: appearanceMode.menu { [weak self] m in self?.setAppearanceMode(m) }
                    ),
                    items: [.init(customView: appearanceMode.segmentedControl(target: self, action: #selector(appearanceChanged)))]
                ),
                {
                    let sliderContainer = self.makeZoomSliderContainer()
                    let sliderItem = UIBarButtonItem(customView: sliderContainer)
                    let zRep = UIBarButtonItem(title: L10n.Detail.currentLevel(self.zoom.displayString), image: .init(systemName: "textformat.size"), menu: self.currentZoomMenu)
                    self.zoomRepresentativeItem = zRep
                    return .optionalGroup(customizationIdentifier: "zoom", representativeItem: zRep, items: [sliderItem])
                }(),
            ]
        } else {
            navigationItem.leftBarButtonItems = []
            let zMenu = UIBarButtonItem(title: L10n.Detail.zoom, image: .init(systemName: "textformat.size"), menu: currentZoomMenu)
            zoomRepresentativeItem = zMenu
            navigationItem.rightBarButtonItems = [
                zMenu,
                .init(title: L10n.Detail.appearance, image: .init(systemName: "circle.lefthalf.filled"),
                      menu: appearanceMode.menu { [weak self] m in self?.setAppearanceMode(m) }),
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

    // MARK: - Articles Capacity

    /// Remove oldest articles (from the tail) until count is within capacity limit.
    private func trimToCapacity() {
        guard articles.count > articlesCapacityLimit else { return }
        let excess = articles.count - articlesCapacityLimit
        articles.removeLast(excess)
        debugLog("📦 [\(instanceID)] Evicted \(excess) oldest articles (capacity: \(articlesCapacityLimit))")
    }

    /// Called when the capacity setting changes to a lower value.
    /// Trims excess articles, adjusts compact index, and syncs to active child.
    private func enforceCapacity() {
        guard articles.count > articlesCapacityLimit else { return }
        trimToCapacity()
        currentCompactIndex = min(currentCompactIndex, max(0, articles.count - 1))
        syncStateToActiveChild()
        if articles.isEmpty {
            onArticlesEmptied?()
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

        // Enforce capacity: evict oldest articles from the tail
        trimToCapacity()

        // Update child
        if activeChild === articlesVC {
            articlesVC.configure(articles: articles, animated: animated)
            articlesVC.scrollToArticle(article, animated: animated)
        } else {
            currentCompactIndex = 0
            articleVC.configure(articles: articles, currentIndex: 0)
        }

        // Donate the activity for Siri Suggestions, Spotlight search, and Handoff.
        self.userActivity = article.userActivity
    }
    
    func preloadArticle(_ article: ArticleDisplayItem) {
        guard !articles.contains(article),
              articles.count < articlesCapacityLimit else { return }
        articles.append(article)
        
        // If pending, subscribe to the dictionary's load state
        if case .pending = article.contentState {
            subscribeToDict(id: article.dictId)
        }
    }
    
    /// Clear all articles and cancel pending subscriptions.
    /// Called after a layout transfer so only the receiving side owns the data.
    func clearArticles() {
        articles = []
        currentCompactIndex = 0
        pendingDictSubscriptions.removeAll()
        if isViewLoaded {
            syncStateToActiveChild()
        }
        // Note: do NOT fire onArticlesEmptied — this is a transfer cleanup,
        // not a user-initiated close.  The nav stack should stay as-is.
    }

    /// Restore articles from state transfer (compact ↔ regular).
    /// Replaces all current articles and syncs to active child.
    func restoreArticles(_ newArticles: [ArticleDisplayItem], currentIndex: Int) {
        debugLog("🔄 [\(instanceID)] restoreArticles: \(newArticles.count) articles, currentIndex=\(currentIndex), isViewLoaded=\(isViewLoaded), activeChild=\(activeChild === articlesVC ? "articlesVC" : activeChild === articleVC ? "articleVC" : "nil")")

        // Cancel stale subscriptions from previous transfer
        pendingDictSubscriptions.removeAll()

        articles = newArticles
        currentCompactIndex = newArticles.isEmpty ? 0 : min(currentIndex, newArticles.count - 1)

        // Subscribe to pending dict loads — articles transferred from another
        // DetailContainer lose their Combine subscriptions, so we must re-subscribe.
        for article in articles {
            if case .pending = article.contentState {
                subscribeToDict(id: article.dictId)
            }
        }

        if isViewLoaded {
            loadPendingArticlesIfReady()
            syncStateToActiveChild()
        }
    }

    func closeArticle(_ article: ArticleDisplayItem) {
        guard let index = articles.firstIndex(of: article) else { return }
        articles.remove(at: index)

        if activeChild === articlesVC {
            articlesVC.configure(articles: articles, animated: true)
        } else {
            // Smart index adjustment for compact pager
            if index < currentCompactIndex {
                currentCompactIndex -= 1
            } else if index == currentCompactIndex {
                currentCompactIndex = min(currentCompactIndex, articles.count - 1)
            }
            currentCompactIndex = max(0, currentCompactIndex)
            articleVC.configure(articles: articles, currentIndex: currentCompactIndex)
        }

        if articles.isEmpty {
            onArticlesEmptied?()
        }
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

    /// Set appearance mode and broadcast to all windows.
    /// Dual-write: standard (Settings.bundle consistency) + shared (Extension visibility).
    /// Both sides are stamped so the merge logic in AppDelegate knows which is newer.
    private func setAppearanceMode(_ mode: AppearanceMode) {
        UserDefaults.shared.setAppearanceModeStamped(mode)
        UserDefaults.standard.appearanceMode = mode
        UserDefaults.standard.appearanceModeTimestamp = UserDefaults.shared.appearanceModeTimestamp
        NotificationCenter.default.post(name: .appearanceModeDidChange, object: mode)
    }
    
    private func applyAppearance() {
        view.window?.overrideUserInterfaceStyle = appearanceMode.userInterfaceStyle

        // Refresh nav bar to update representativeItem icon
        updateNavigationBar(for: traitCollection)
    }

    // MARK: - Zoom

    func zoomIn() {
        guard !articles.isEmpty else { return }
        zoom.zoomIn()
        applyZoom()
    }

    func zoomOut() {
        guard !articles.isEmpty else { return }
        zoom.zoomOut()
        applyZoom()
    }

    func resetZoom() {
        guard !articles.isEmpty else { return }
        zoom.reset()
        applyZoom()
    }

    private func applyZoom() {
        debugLog("🔍 Zoom level: \(zoom.displayString)")

        // Apply to child VCs
        articlesVC.setZoomLevel(zoom.current)
        articleVC.setZoomLevel(zoom.current)

        // Update zoom controls in-place (avoids rebuilding entire nav bar)
        if let idx = ZoomLevel.levels.firstIndex(of: zoom.current) {
            zoomSlider?.value = Float(idx)  // iOS 16+ slider
        }
        // iOS 15 fallback: dedicated buttons
        zoomOutItem?.isEnabled = zoom.canZoomOut
        zoomResetItem?.isEnabled = !zoom.isDefault
        zoomResetItem?.title = zoom.displayString
        zoomInItem?.isEnabled = zoom.canZoomIn
        zoomRepresentativeItem?.menu = currentZoomMenu
        // Compact representative shows current level in title
        if traitCollection.horizontalSizeClass != .regular {
            zoomRepresentativeItem?.title = L10n.Detail.currentLevel(zoom.displayString)
        }
    }

    // MARK: - Zoom Slider

    private func makeZoomSliderContainer() -> UIView {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = Float(ZoomLevel.levels.count - 1)
        slider.value = Float(ZoomLevel.levels.firstIndex(of: zoom.current) ?? 2)
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(zoomSliderChanged(_:)), for: .valueChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        self.zoomSlider = slider

        let smallerIcon = UIImageView(image: UIImage(systemName: "textformat.size.smaller"))
        smallerIcon.tintColor = .secondaryLabel
        smallerIcon.contentMode = .scaleAspectFit
        smallerIcon.translatesAutoresizingMaskIntoConstraints = false
        smallerIcon.setContentHuggingPriority(.required, for: .horizontal)

        let largerIcon = UIImageView(image: UIImage(systemName: "textformat.size.larger"))
        largerIcon.tintColor = .secondaryLabel
        largerIcon.contentMode = .scaleAspectFit
        largerIcon.translatesAutoresizingMaskIntoConstraints = false
        largerIcon.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [smallerIcon, slider, largerIcon])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            slider.widthAnchor.constraint(equalToConstant: 140),
            smallerIcon.widthAnchor.constraint(equalToConstant: 16),
            smallerIcon.heightAnchor.constraint(equalToConstant: 16),
            largerIcon.widthAnchor.constraint(equalToConstant: 16),
            largerIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        return stack
    }

    @objc private func zoomSliderChanged(_ sender: UISlider) {
        let index = Int(sender.value.rounded())
        sender.value = Float(index)
        let newLevel = ZoomLevel.levels[index]
        guard newLevel != zoom.current else { return }
        zoom = ZoomLevel(newLevel)
        applyZoom()
    }

    // MARK: - Find in Page

    /// Whether the search bar (find/highlight) is currently active
    var isSearchActive: Bool { searchController.isActive }

    /// Dismiss the search bar (called by Esc smart dismiss)
    func dismissSearch() { searchController.isActive = false }

    // MARK: - Jump Search

    /// Look up selected text in the same dictionary. If found, push as new article.
    /// If not found, fall back to the search bar via onJumpSearchFallback.
    private func performJumpSearch(word: String, dictId: String) {
        guard let dict = DictionaryService.shared.dict(id: dictId),
              let article = DictionaryService.shared.lookup(word, in: dict) else {
            // Not found in same dictionary → fall back to search bar
            onJumpSearchFallback?(word)
            return
        }
        // Found → push as new article
        pushArticle(article, animated: true)

        // Record lookup history
        let ctx = lookupContext ?? (nil, "all")
        LookupHistoryService.shared.recordLookup(
            word: word, dictId: dictId,
            lookupContextDictId: ctx.dictId, lookupContextGroupId: ctx.groupId
        )
    }

    // MARK: - Keyboard Shortcut Handlers (called via responder chain from buildMenu)

    @objc func handleFindShortcut() {
        if activeChild === articlesVC {
            // Regular mode: toggle search bar
            if searchController.isActive {
                searchController.isActive = false
            } else {
                searchController.isActive = true
                searchController.searchBar.becomeFirstResponder()
            }
        } else if activeChild === articleVC {
            // Compact mode: toggle WKWebView find
            if #available(iOS 16.0, *) {
                articleVC.toggleFind()
            }
        }
    }

    @objc func previousPageShortcut() { navigatePage(direction: -1) }
    @objc func nextPageShortcut() { navigatePage(direction: 1) }

    private func navigatePage(direction: Int) {
        // Compact mode: page through ArticleVC's pager
        if activeChild === articleVC {
            let newIndex = articleVC.currentPageIndex + direction
            guard newIndex >= 0, newIndex < articles.count else { return }
            articleVC.navigateToPage(newIndex, animated: true)
            return
        }
        // Regular mode: scroll ArticlesVC in list layout
        guard layoutMode == .list, !articles.isEmpty else { return }
        let pageHeight = articlesVC.view.bounds.height
        guard pageHeight > 0 else { return }
        let currentPage = Int(round(articlesVC.currentScrollOffset.y / pageHeight))
        let targetPage = currentPage + direction
        guard targetPage >= 0, targetPage < articles.count else { return }
        articlesVC.scrollToItem(at: IndexPath(item: targetPage, section: 0), animated: true)
    }

    // MARK: - Appearance Toggle (⇧⌘A)

    /// Cycle appearance: light → system → dark → light
    func toggleAppearance() {
        let next: AppearanceMode
        switch appearanceMode {
        case .light: next = .system
        case .system: next = .dark
        case .dark: next = .light
        }
        setAppearanceMode(next)
    }

    // MARK: - Layout Switching (⌘1/2/3)

    /// Switch to a specific layout mode (called by keyboard shortcut)
    func switchLayout(to mode: ArticleLayoutMode) {
        guard mode != layoutMode else { return }
        layoutMode = mode
        articlesVC.applyLayout(mode, animated: true)
        updateNavigationBar(for: traitCollection)
    }

    // MARK: - canPerformAction

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // ⌘F: Find — iOS 16+, both regular and compact
        if action == #selector(handleFindShortcut) {
            if #available(iOS 16.0, *) {
                return true
            }
            return false
        }
        // ⌘[/]: Page nav — compact with multiple articles, or regular + list layout
        if action == #selector(previousPageShortcut) || action == #selector(nextPageShortcut) {
            if activeChild === articleVC && articles.count > 1 { return true }
            return traitCollection.horizontalSizeClass == .regular && layoutMode == .list
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

// MARK: - ArticlesViewControllerDelegate

extension DetailContainerViewController: ArticlesViewControllerDelegate {
    func articlesViewController(_ vc: ArticlesViewController, didCloseArticle article: ArticleDisplayItem) {
        closeArticle(article)
    }
    
    func articlesViewController(_ vc: ArticlesViewController, didSelectArticle article: ArticleDisplayItem) {
        print("📖 Selected: \(article.word)")

        // Donate the activity for Siri Suggestions, Spotlight search, and Handoff.
        // Setting userActivity on the VC lets UIKit manage becomeCurrent/resignCurrent.
        self.userActivity = article.userActivity
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

    func articlesViewController(_ vc: ArticlesViewController, didRequestJumpSearch word: String, inDict dictId: String) {
        performJumpSearch(word: word, dictId: dictId)
    }

    func articlesViewController(_ vc: ArticlesViewController, didRequestNewWindow article: ArticleDisplayItem) {
        let session = view.window?.windowScene?.session
        SceneDelegate.openNewWindow(for: article, sourceSession: session)
        closeArticle(article)
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

        // Enforce capacity: evict oldest articles from the tail
        trimToCapacity()

        if activeChild === articleVC {
            currentCompactIndex = 0
            articleVC.configure(articles: articles, currentIndex: 0)
        } else {
            articlesVC.configure(articles: articles, animated: true)
            articlesVC.scrollToArticle(articles.first!, animated: true)
        }

        // Record lookup history using the current lookup context
        let ctx = lookupContext ?? (nil, "all")
        LookupHistoryService.shared.recordLookup(
            word: word, dictId: dictId,
            lookupContextDictId: ctx.dictId, lookupContextGroupId: ctx.groupId
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

    func articleViewController(_ vc: ArticleViewController, didRequestJumpSearch word: String, inDict dictId: String) {
        performJumpSearch(word: word, dictId: dictId)
    }

    func articleViewController(_ vc: ArticleViewController, didChangePage index: Int) {
        currentCompactIndex = index
        if index < articles.count {
            self.userActivity = articles[index].userActivity
        }
    }

    func articleViewController(_ vc: ArticleViewController, didCloseArticle article: ArticleDisplayItem) {
        closeArticle(article)
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
        onSearchActivated?()
    }

    func willDismissSearchController(_ searchController: UISearchController) {
        //Swift.debugPrint("UISearchControllerDelegate invoked method: \(#function).")
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        onSearchDeactivated?()
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
