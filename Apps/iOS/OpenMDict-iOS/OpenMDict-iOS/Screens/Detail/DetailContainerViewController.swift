//
//  DetailContainerViewController.swift
//  OpenMDict-iOS
//
//  Container managing detail view for different size classes
//  SOURCE OF TRUTH for articles state and navigation bar
//

import UIKit

// MARK: - Appearance Mode

enum AppearanceMode: Int {
    case light = 0
    case system = 1
    case dark = 2
}


class DetailContainerViewController: UIViewController {
    
    // MARK: - Source of Truth
    
    private var articles: [ArticleDisplayItem] = []
    private var layoutMode: ArticleLayoutMode = .columns
    private var appearanceMode: AppearanceMode = .system
    
    var currentArticle: ArticleDisplayItem? { articles.first }
    
    // MARK: - Child View Controllers
    
    private lazy var articlesVC: ArticlesViewController = {
        let vc = ArticlesViewController()
        vc.delegate = self
        return vc
    }()
    
    private lazy var articleVC: ArticleViewController = {
        ArticleViewController()
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
                self?.appearanceMode = .light
                self?.applyAppearance()
            },
            UIAction(title: "Auto", image: .init(systemName: "circle.lefthalf.filled"),
                     state: appearanceMode == .system ? .on : .off) { [weak self] _ in
                self?.appearanceMode = .system
                self?.applyAppearance()
            },
            UIAction(title: "Dark", image: .init(systemName: "moon"),
                     state: appearanceMode == .dark ? .on : .off) { [weak self] _ in
                self?.appearanceMode = .dark
                self?.applyAppearance()
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
        applyAppearance()
    }
    
    override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)
        
        // Pass in newCollection instead of self.traitCollection
        coordinator.animate { _ in
            self.updateChildForTraits(newCollection)
            self.updateNavigationBar(for: newCollection)
        }
    }
    
    // MARK: - Child Management
    
    private func updateChildForTraits(_ traits: UITraitCollection) {
        let shouldUseArticlesVC = traits.horizontalSizeClass == .regular
        let targetChild = shouldUseArticlesVC ? articlesVC : articleVC
        
        guard targetChild !== activeChild else { return }
        
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
    
    // MARK: - Actions
    
    @objc private func layoutChanged(_ sender: UISegmentedControl) {
        guard let mode = ArticleLayoutMode(rawValue: sender.selectedSegmentIndex) else { return }
        layoutMode = mode
        articlesVC.applyLayout(mode, animated: true)
    }
    
    @objc private func appearanceChanged(_ sender: UISegmentedControl) {
        appearanceMode = AppearanceMode(rawValue: sender.selectedSegmentIndex) ?? .system
        applyAppearance()
    }

    private func applyAppearance() {
        let style: UIUserInterfaceStyle = switch appearanceMode {
        case .light: .light
        case .system: .unspecified
        case .dark: .dark
        }

        view.window?.overrideUserInterfaceStyle = style
        
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
