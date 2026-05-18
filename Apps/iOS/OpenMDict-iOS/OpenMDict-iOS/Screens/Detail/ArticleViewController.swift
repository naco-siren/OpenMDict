//
//  ArticleViewController.swift
//  OpenMDict-iOS
//
//  Paged article view for compact mode (iPhone / iPad narrow).
//  Displays all open articles in a horizontally-scrollable pager
//  with a floating page control at the bottom.
//  Each page is an ArticlePageView (shared component: header + WKWebView).
//

import Combine
import UIKit
import WebKit

// MARK: - Delegate

protocol ArticleViewControllerDelegate: AnyObject {
    /// `fragment` is the `#anchor` part of an `entry://word#anchor` cross-reference
    /// (nil when the URL had no fragment).  The handler is expected to scroll the
    /// target article to that DOM id after it loads.
    func articleViewController(_ vc: ArticleViewController, didTapEntryLink word: String, fragment: String?, inDict dictId: String)
    func articleViewController(_ vc: ArticleViewController, didRequestJumpSearch word: String, inDict dictId: String)
    func articleViewController(_ vc: ArticleViewController, didChangePage index: Int)
    func articleViewController(_ vc: ArticleViewController, didCloseArticle article: ArticleDisplayItem)
}

class ArticleViewController: UIViewController {

    // MARK: - Delegate

    weak var delegate: ArticleViewControllerDelegate?

    // MARK: - Pager State

    private var articles: [ArticleDisplayItem] = []
    private(set) var currentPageIndex: Int = 0
    private var currentZoomLevel: Int = ZoomLevel.defaultLevel
    private var lookupCountCancellable: AnyCancellable?
    private var bookmarkCancellable: AnyCancellable?

    // MARK: - Pages

    private var pages: [ArticlePageView] = []
    private var pageLeadingConstraints: [NSLayoutConstraint] = []

    // MARK: - Safe Area (manual, same pattern as ArticlesVC)

    /// Constraint from scrollView.top → view.top, constant = effective safe area.
    /// We manage this manually instead of using `safeAreaLayoutGuide.topAnchor`
    /// because safeAreaLayoutGuide doesn't propagate from UINavigationController
    /// during a `UIViewControllerTransitionCoordinator.animate` block.
    private var scrollViewTopConstraint: NSLayoutConstraint!

    /// Effective safe area top: own value, falling back to parent's.
    /// Mirrors the `effectiveSafeAreaTop` pattern in ArticlesVC.
    private var effectiveSafeAreaTop: CGFloat {
        let myTop = view.safeAreaInsets.top
        if myTop > 0 { return myTop }
        return parent?.view.safeAreaInsets.top ?? 0
    }

    // MARK: - Pager UI

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.isPagingEnabled = true
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.bounces = true
        sv.delegate = self
        // Safe area is handled manually via scrollViewTopConstraint.
        // Prevent UIKit from adding automatic content insets that would
        // double-offset the pages and cause the header to scroll with
        // the WKWebView content when inside a UINavigationController.
        sv.contentInsetAdjustmentBehavior = .never
        return sv
    }()

    private lazy var pageControlBackdrop: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26, *) {
            effect = UIGlassEffect(style: .clear)
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        let v = UIVisualEffectView(effect: effect)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private lazy var pageControl: UIPageControl = {
        let pc = UIPageControl()
        pc.translatesAutoresizingMaskIntoConstraints = false
        pc.hidesForSinglePage = true
        pc.currentPageIndicatorTintColor = .label
        pc.pageIndicatorTintColor = .tertiaryLabel
        pc.addTarget(self, action: #selector(pageControlValueChanged), for: .valueChanged)
        pc.isHidden = true
        return pc
    }()

    private lazy var webViewConfiguration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MDictSchemeHandler.shared, forURLScheme: "mdict")
        return config
    }()

    private lazy var emptyView: ArticlePlaceholderView = {
        let v = ArticlePlaceholderView.empty()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .systemBackground
        return v
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        
        navigationItem.largeTitleDisplayMode = .never
        setupUI()
        showEmpty()

        bookmarkCancellable = BookmarkService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.bookmarksDidChange()
            }
    }

    private func setupUI() {
        view.addSubview(scrollView)
        view.addSubview(emptyView)

        // Floating page control with capsule backdrop
        if #available(iOS 26, *) {
            pageControlBackdrop.contentView.addSubview(pageControl)
        } else {
            pageControlBackdrop.contentView.addSubview(pageControl)
        }
        view.addSubview(pageControlBackdrop)

        // Manual safe area: topAnchor + constant (not safeAreaLayoutGuide — see comment above)
        scrollViewTopConstraint = scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: effectiveSafeAreaTop)

        NSLayoutConstraint.activate([
            scrollViewTopConstraint,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Page control backdrop — centered at bottom
            pageControlBackdrop.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControlBackdrop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            // Page control inside backdrop
            pageControl.topAnchor.constraint(equalTo: pageControlBackdrop.contentView.topAnchor, constant: 4),
            pageControl.bottomAnchor.constraint(equalTo: pageControlBackdrop.contentView.bottomAnchor, constant: -4),
            pageControl.leadingAnchor.constraint(equalTo: pageControlBackdrop.contentView.leadingAnchor, constant: 4),
            pageControl.trailingAnchor.constraint(equalTo: pageControlBackdrop.contentView.trailingAnchor, constant: -4),

            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        scrollViewTopConstraint.constant = effectiveSafeAreaTop
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Keep scrollView below nav bar (parent fallback for first transition)
        scrollViewTopConstraint.constant = effectiveSafeAreaTop

        // Capsule shape for page control backdrop
        if pageControlBackdrop.bounds.height > 0 {
            pageControlBackdrop.layer.cornerRadius = pageControlBackdrop.bounds.height / 2
            pageControlBackdrop.layer.masksToBounds = true
        }

        guard !pages.isEmpty else { return }
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        // Update content size
        scrollView.contentSize = CGSize(
            width: pageWidth * CGFloat(pages.count),
            height: scrollView.bounds.height
        )

        // Update each page's leading constraint
        for (index, constraint) in pageLeadingConstraints.enumerated() {
            constraint.constant = CGFloat(index) * pageWidth
        }

        // Restore current page offset (without animation to avoid flicker)
        scrollView.contentOffset = CGPoint(
            x: CGFloat(currentPageIndex) * pageWidth,
            y: 0
        )
    }

    // MARK: - Trait Changes

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            reloadAllPages()
        }
    }

    // MARK: - Public API (called by Container)

    func configure(articles: [ArticleDisplayItem], currentIndex: Int) {
        guard !articles.isEmpty else {
            showEmpty()
            return
        }

        let oldIds = self.articles.map(\.id)
        let newIds = articles.map(\.id)

        if oldIds == newIds {
            // Same articles in same order — update contentState changes in-place
            for (index, newArticle) in articles.enumerated() {
                if self.articles[index].contentState != newArticle.contentState {
                    self.articles[index] = newArticle
                    if index < pages.count {
                        loadContent(for: newArticle, in: pages[index])
                        // Remove native pending overlay once content arrives
                        if case .pending = newArticle.contentState {} else {
                            pages[index].removePendingOverlay()
                        }
                    }
                }
            }
        } else {
            // Article set changed — full rebuild
            self.articles = articles
            rebuildPages()
        }

        // Navigate to requested page
        let safeIndex = max(0, min(currentIndex, articles.count - 1))
        currentPageIndex = safeIndex

        // Update page control
        pageControl.numberOfPages = articles.count
        pageControl.currentPage = safeIndex
        let showPager = articles.count > 1
        pageControl.isHidden = !showPager
        pageControlBackdrop.isHidden = !showPager

        // Show content and navigate
        showContent()
        scrollToPageInternal(safeIndex, animated: false)
        updateCurrentPageState()
    }

    /// Navigate to a specific page. Called by Container for keyboard shortcuts / external navigation.
    func navigateToPage(_ page: Int, animated: Bool = false) {
        scrollToPageInternal(page, animated: animated)
        updateCurrentPageState()
        delegate?.articleViewController(self, didChangePage: page)
    }

    /// Scroll the page at index 0 (the most recently navigated-to article) to
    /// an in-page anchor.  Used by cross-reference click handling so the user
    /// lands at the matching `id` inside the target article.  No-op when
    /// `anchor` is nil or the page isn't built yet.
    func scrollFirstPage(toAnchor anchor: String?) {
        guard let anchor, !anchor.isEmpty, let first = pages.first else { return }
        first.scrollToAnchor(anchor)
    }

    // MARK: - Page Management

    private func rebuildPages() {
        // Remove old pages
        for page in pages {
            page.removeFromSuperview()
        }
        pages.removeAll()
        pageLeadingConstraints.removeAll()

        // Add new pages
        for (index, article) in articles.enumerated() {
            addPage(for: article, at: index)
        }

        // Update content size
        let pageWidth = scrollView.bounds.width
        scrollView.contentSize = CGSize(
            width: pageWidth * CGFloat(articles.count),
            height: scrollView.bounds.height
        )
    }

    private func addPage(for article: ArticleDisplayItem, at index: Int) {
        let pageView = makeArticlePageView(for: article)
        scrollView.addSubview(pageView)

        let leadingConstraint = pageView.leadingAnchor.constraint(
            equalTo: scrollView.leadingAnchor,
            constant: CGFloat(index) * scrollView.bounds.width
        )

        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            pageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            pageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            leadingConstraint,
        ])

        pages.append(pageView)
        pageLeadingConstraints.append(leadingConstraint)

        // Apply per-dict dark mode enhancement strength.
        pageView.setDarkModeEnhance(strength: ArticlesViewController.enhanceStrength(for: article.dictId))

        loadContent(for: article, in: pageView)

        // Native pending overlay while dictionary loads
        if case .pending = article.contentState {
            pageView.showPendingOverlay(word: article.word, dictName: article.dictName)
        }
    }

    /// Create a page view for the given article.
    private func makeArticlePageView(for article: ArticleDisplayItem) -> ArticlePageView {
        let config = ArticlePageView.Configuration.compactPager(
            webViewConfig: webViewConfiguration
        )
        let pageView = ArticlePageView(configuration: config)
        pageView.translatesAutoresizingMaskIntoConstraints = false

        let isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        pageView.configure(word: article.word, dictName: article.dictName,
                          dictId: article.dictId, isBookmarked: isBookmarked)

        // Wire callbacks
        pageView.onBookmarkTapped = { [weak self] isCurrentlyBookmarked in
            self?.handleBookmarkTapped(isCurrentlyBookmarked: isCurrentlyBookmarked)
        }
        pageView.onEntryLinkTapped = { [weak self] word, fragment in
            guard let self else { return }
            // Determine which page this belongs to
            if let pageIndex = self.pages.firstIndex(where: { $0 === pageView }),
               pageIndex < self.articles.count {
                let dictId = self.articles[pageIndex].dictId
                self.delegate?.articleViewController(self, didTapEntryLink: word, fragment: fragment, inDict: dictId)
            }
        }
        pageView.onSoundLinkTapped = { [weak self] url in
            guard let self else { return }
            if let pageIndex = self.pages.firstIndex(where: { $0 === pageView }),
               pageIndex < self.articles.count {
                let dictId = self.articles[pageIndex].dictId
                AudioService.shared.play(url: url, dictId: dictId)
            }
        }
        pageView.onJumpSearch = { [weak self] text in
            guard let self else { return }
            if let pageIndex = self.pages.firstIndex(where: { $0 === pageView }),
               pageIndex < self.articles.count {
                let dictId = self.articles[pageIndex].dictId
                self.delegate?.articleViewController(self, didRequestJumpSearch: text, inDict: dictId)
            }
        }
        pageView.onEnhanceDarkModeStrengthChanged = { [weak self] newStrength in
            guard let self else { return }
            if let pageIndex = self.pages.firstIndex(where: { $0 === pageView }),
               pageIndex < self.articles.count {
                let dictId = self.articles[pageIndex].dictId
                DictMetadataService.shared.updateEnhanceDarkModeStrength(dictId: dictId, strength: newStrength)
            }
        }
        pageView.onCloseTapped = { [weak self] in
            guard let self else { return }
            if let pageIndex = self.pages.firstIndex(where: { $0 === pageView }),
               pageIndex < self.articles.count {
                let article = self.articles[pageIndex]
                self.delegate?.articleViewController(self, didCloseArticle: article)
            }
        }
        pageView.onFindTapped = { [weak self] in
            // Dismiss find on all other pages when one page opens find
            guard let self else { return }
            if #available(iOS 16.0, *) {
                for (idx, p) in self.pages.enumerated() {
                    if p !== pageView && p.isFindNavigatorVisible {
                        p.dismissFind()
                    }
                }
            }
        }

        return pageView
    }

    private func scrollToPageInternal(_ page: Int, animated: Bool) {
        guard page >= 0, page < articles.count else { return }
        currentPageIndex = page
        pageControl.currentPage = page

        let pageWidth = scrollView.bounds.width
        if pageWidth > 0 {
            scrollView.setContentOffset(
                CGPoint(x: CGFloat(page) * pageWidth, y: 0),
                animated: animated
            )
        }
    }

    /// Update bookmark state and lookup count subscription for the current page.
    private func updateCurrentPageState() {
        guard currentPageIndex < articles.count,
              currentPageIndex < pages.count else { return }
        let article = articles[currentPageIndex]
        let page = pages[currentPageIndex]

        // Bookmark state
        let isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        page.setBookmarked(isBookmarked)

        // Lookup count subscription (re-binds on each page change)
        lookupCountCancellable = LookupHistoryService.shared
            .lookupCountPublisher(word: article.word, dictId: article.dictId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                guard let self,
                      self.currentPageIndex < self.pages.count else { return }
                self.pages[self.currentPageIndex].setLookupCount(count)
            }
    }

    @objc private func pageControlValueChanged(_ sender: UIPageControl) {
        navigateToPage(sender.currentPage, animated: true)
    }

    // MARK: - Content Loading

    private func loadContent(for article: ArticleDisplayItem, in pageView: ArticlePageView) {
        switch article.contentState {
        case .pending:
            let html = ArticleHTMLRenderer.renderPending(word: article.word, traitCollection: traitCollection)
            pageView.loadHTMLContent(html)

        case .loaded(let html, _):
            let styledHTML = ArticleHTMLRenderer.renderArticle(html: html, dictId: article.dictId, traitCollection: traitCollection)
            pageView.loadHTMLContent(styledHTML)

        case .notFound:
            let html = ArticleHTMLRenderer.renderNotFound(word: article.word, dictName: article.dictName, traitCollection: traitCollection)
            pageView.loadHTMLContent(html)
        }
    }

    private func reloadAllPages() {
        for (index, page) in pages.enumerated() where index < articles.count {
            loadContent(for: articles[index], in: page)
        }
    }

    // MARK: - Show / Hide States

    private func showContent() {
        emptyView.isHidden = true
        scrollView.isHidden = false
    }

    private func showEmpty() {
        emptyView.isHidden = false
        scrollView.isHidden = true
        pageControl.isHidden = true
        pageControlBackdrop.isHidden = true
        articles = []
        for page in pages { page.removeFromSuperview() }
        pages.removeAll()
        pageLeadingConstraints.removeAll()
        currentPageIndex = 0
    }

    // MARK: - Bookmark Actions

    private func handleBookmarkTapped(isCurrentlyBookmarked: Bool) {
        guard currentPageIndex < articles.count,
              currentPageIndex < pages.count else { return }
        let article = articles[currentPageIndex]
        let page = pages[currentPageIndex]

        if isCurrentlyBookmarked {
            // Removing → show confirmation
            let alert = UIAlertController(
                title: L10n.Bookmarks.removeBookmark,
                message: L10n.Bookmarks.removeBookmarkMessage(word: article.word, dictName: article.dictName),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
                guard let self else { return }
                BookmarkService.shared.toggleBookmark(
                    word: article.word, dictId: article.dictId
                )
                page.setBookmarked(false)
            })
            present(alert, animated: true)
        } else {
            // Adding → immediate
            let created = BookmarkService.shared.toggleBookmark(
                word: article.word, dictId: article.dictId
            )
            if created {
                BookmarkCountService.shared.incrementAll(dictId: article.dictId)
            }
            page.setBookmarked(created)
        }
    }

    private func bookmarksDidChange() {
        guard currentPageIndex < articles.count,
              currentPageIndex < pages.count else { return }
        let article = articles[currentPageIndex]
        let isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        pages[currentPageIndex].setBookmarked(isBookmarked)
    }

    // MARK: - Zoom

    func setZoomLevel(_ level: Int) {
        currentZoomLevel = level
        for page in pages {
            page.setZoomLevel(level)
        }
    }

    /// Re-apply per-dict dark mode enhancement to all pages.
    /// Called when DictMetadataService revision changes (e.g. user toggled enhanceDarkMode).
    func refreshDarkModeEnhance() {
        for (index, page) in pages.enumerated() where index < articles.count {
            page.setDarkModeEnhance(strength: ArticlesViewController.enhanceStrength(for: articles[index].dictId))
        }
    }

    /// Re-evaluate visibility of the enhance dark mode button on all pages.
    /// Called when the Settings toggle changes.
    func refreshEnhanceDarkModeVisibility() {
        for page in pages {
            page.updateEnhanceDarkModeButtonVisibility()
        }
    }

    // MARK: - Find

    /// Present or hide system Find UI (iOS 16+)
    @available(iOS 16.0, *)
    func toggleFind() {
        guard currentPageIndex < pages.count else { return }
        let page = pages[currentPageIndex]
        if page.isFindNavigatorVisible {
            page.dismissFind()
        } else {
            page.presentFind()
        }
    }
}

// MARK: - UIScrollViewDelegate

extension ArticleViewController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }
        let page = Int(round(scrollView.contentOffset.x / pageWidth))
        guard page != currentPageIndex, page >= 0, page < articles.count else { return }
        currentPageIndex = page
        pageControl.currentPage = page
        updateCurrentPageState()
        delegate?.articleViewController(self, didChangePage: page)
    }
}
