//
//  ArticleViewController.swift
//  OpenMDict-iOS
//
//  Paged article view for compact mode (iPhone / iPad narrow).
//  Displays all open articles in a horizontally-scrollable pager
//  with a floating page control at the bottom.
//  Each page contains its own header row + WKWebView, so headers
//  swipe together with content.
//

import Combine
import UIKit
import WebKit

// MARK: - Delegate

protocol ArticleViewControllerDelegate: AnyObject {
    func articleViewController(_ vc: ArticleViewController, didTapEntryLink word: String, inDict dictId: String)
    func articleViewController(_ vc: ArticleViewController, didRequestJumpSearch word: String, inDict dictId: String)
    func articleViewController(_ vc: ArticleViewController, didChangePage index: Int)
}

class ArticleViewController: UIViewController {

    // MARK: - Delegate

    weak var delegate: ArticleViewControllerDelegate?

    // MARK: - Pager State

    private var articles: [ArticleDisplayItem] = []
    private(set) var currentPageIndex: Int = 0
    private var currentZoomLevel: Int = ZoomLevel.defaultLevel
    private var isBookmarked: Bool = false
    private var lookupCountCancellable: AnyCancellable?
    private var bookmarkCancellable: AnyCancellable?

    // MARK: - Per-Page Layout

    /// Each page is a vertical stack: header (64pt) + WKWebView (fill).
    private struct PageSlot {
        let container: UIView
        let headerView: UIView
        let bookmarkButton: UIButton
        let titleLabel: UILabel
        let subtitleLabel: UILabel
        let lookupCountLabel: UILabel
        let webView: WKWebView
    }

    private var pages: [PageSlot] = []
    private var pageLeadingConstraints: [NSLayoutConstraint] = []

    private static let headerHeight: CGFloat = 64

    // MARK: - Pager UI

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.isPagingEnabled = true
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.bounces = true
        sv.delegate = self
        return sv
    }()

    private lazy var pageControlBackdrop: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26, *) {
            effect = UIGlassEffect(style: .regular)
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

        NSLayoutConstraint.activate([
            // ScrollView from safe area top to bottom (headers are per-page now)
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

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

        // Update each page container's leading constraint
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
                        loadContent(for: newArticle, in: pages[index].webView)
                        // Remove native pending overlay once content arrives
                        if case .pending = newArticle.contentState {} else {
                            removePendingOverlay(from: pages[index])
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

    // MARK: - Page Management

    private func rebuildPages() {
        // Remove old pages
        for page in pages {
            page.container.removeFromSuperview()
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
        let slot = makePageSlot(for: article)
        scrollView.addSubview(slot.container)

        let leadingConstraint = slot.container.leadingAnchor.constraint(
            equalTo: scrollView.leadingAnchor,
            constant: CGFloat(index) * scrollView.bounds.width
        )

        NSLayoutConstraint.activate([
            slot.container.topAnchor.constraint(equalTo: scrollView.topAnchor),
            slot.container.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            slot.container.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            leadingConstraint,
        ])

        pages.append(slot)
        pageLeadingConstraints.append(leadingConstraint)

        loadContent(for: article, in: slot.webView)

        // Native pending overlay while dictionary loads
        if case .pending = article.contentState {
            addPendingOverlay(to: slot, word: article.word, dictName: article.dictName)
        }
    }

    /// Create a page container with header row + WKWebView.
    private func makePageSlot(for article: ArticleDisplayItem) -> PageSlot {
        // Container
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = .secondarySystemGroupedBackground

        // Bookmark button
        var btnConfig = UIButton.Configuration.plain()
        btnConfig.image = UIImage(systemName: "bookmark")
        btnConfig.baseForegroundColor = .secondaryLabel
        let bookmarkBtn = UIButton(configuration: btnConfig)
        bookmarkBtn.translatesAutoresizingMaskIntoConstraints = false
        bookmarkBtn.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)

        // Labels
        let titleLbl = UILabel()
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.text = article.word

        let subtitleLbl = UILabel()
        subtitleLbl.translatesAutoresizingMaskIntoConstraints = false
        subtitleLbl.font = .systemFont(ofSize: 11)
        subtitleLbl.textColor = .secondaryLabel
        subtitleLbl.text = article.dictName

        let lookupCountLbl = UILabel()
        lookupCountLbl.translatesAutoresizingMaskIntoConstraints = false
        lookupCountLbl.font = .italicSystemFont(ofSize: 11)
        lookupCountLbl.isHidden = true

        let titleStack = UIStackView(arrangedSubviews: [titleLbl, subtitleLbl, lookupCountLbl])
        titleStack.axis = .vertical
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(bookmarkBtn)
        header.addSubview(titleStack)

        // Note: UIDragInteraction is NOT added here. Plain UIScrollView (unlike UICollectionView)
        // has no built-in drag coordination, making drag-to-new-scene unreliable from paged content.
        // Drag-to-new-window remains available in regular mode via ArticleCell.

        // WebView
        let webView = makeWebView()

        // Layout
        container.addSubview(header)
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            bookmarkBtn.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            bookmarkBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            bookmarkBtn.widthAnchor.constraint(equalToConstant: 40),
            bookmarkBtn.heightAnchor.constraint(equalToConstant: 40),

            titleStack.leadingAnchor.constraint(equalTo: bookmarkBtn.trailingAnchor, constant: 4),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -12),

            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return PageSlot(
            container: container,
            headerView: header,
            bookmarkButton: bookmarkBtn,
            titleLabel: titleLbl,
            subtitleLabel: subtitleLbl,
            lookupCountLabel: lookupCountLbl,
            webView: webView
        )
    }

    private func makeWebView() -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: webViewConfiguration)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = self
        if #available(iOS 16.0, *) {
            wv.isFindInteractionEnabled = true
        }
        return wv
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
        isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        updateBookmarkButton(page.bookmarkButton, isBookmarked: isBookmarked)

        // Lookup count subscription (re-binds on each page change)
        lookupCountCancellable = LookupHistoryService.shared
            .lookupCountPublisher(word: article.word, dictId: article.dictId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                guard let self,
                      self.currentPageIndex < self.pages.count else { return }
                let lookupLabel = self.pages[self.currentPageIndex].lookupCountLabel
                if count > 0 {
                    lookupLabel.text = L10n.Articles.lookupCount(count)
                    lookupLabel.textColor = self.lookupCountColor(for: count)
                    lookupLabel.isHidden = false
                } else {
                    lookupLabel.isHidden = true
                }
            }
    }

    private func updateBookmarkButton(_ button: UIButton, isBookmarked: Bool) {
        var config = button.configuration
        let imageName = isBookmarked ? "bookmark.fill" : "bookmark"
        config?.image = UIImage(systemName: imageName)
        config?.baseForegroundColor = isBookmarked ? nil : .secondaryLabel
        button.configuration = config
    }

    @objc private func pageControlValueChanged(_ sender: UIPageControl) {
        navigateToPage(sender.currentPage, animated: true)
    }

    // MARK: - Pending Overlay

    private static let pendingOverlayTag = 9876

    private func addPendingOverlay(to page: PageSlot, word: String, dictName: String) {
        let overlay = ArticlePlaceholderView.loading(word: word, dictName: dictName)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.tag = Self.pendingOverlayTag
        overlay.backgroundColor = .systemBackground
        page.container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: page.webView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: page.webView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: page.webView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: page.webView.bottomAnchor),
        ])
    }

    private func removePendingOverlay(from page: PageSlot) {
        page.container.viewWithTag(Self.pendingOverlayTag)?.removeFromSuperview()
    }

    // MARK: - Content Loading

    private func loadContent(for article: ArticleDisplayItem, in webView: WKWebView) {
        switch article.contentState {
        case .pending:
            let html = ArticleHTMLRenderer.renderPending(word: article.word, traitCollection: traitCollection)
            webView.loadHTMLString(html, baseURL: nil)

        case .loaded(let html, _):
            let styledHTML = ArticleHTMLRenderer.renderArticle(html: html, dictId: article.dictId, traitCollection: traitCollection)
            webView.loadHTMLString(styledHTML, baseURL: nil)

        case .notFound:
            let html = ArticleHTMLRenderer.renderNotFound(word: article.word, dictName: article.dictName, traitCollection: traitCollection)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func reloadAllPages() {
        for (index, page) in pages.enumerated() where index < articles.count {
            loadContent(for: articles[index], in: page.webView)
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
        for page in pages { page.container.removeFromSuperview() }
        pages.removeAll()
        pageLeadingConstraints.removeAll()
        currentPageIndex = 0
    }

    // MARK: - Lookup Count

    private func lookupCountColor(for count: Int) -> UIColor {
        switch count {
        case 15...:   return .systemRed
        case 10..<15: return .systemOrange
        case 6..<10:  return .systemBrown
        case 3..<6:   return .secondaryLabel
        default:      return .tertiaryLabel
        }
    }

    // MARK: - Bookmark Actions

    @objc private func bookmarkTapped() {
        guard currentPageIndex < articles.count,
              currentPageIndex < pages.count else { return }
        let article = articles[currentPageIndex]
        let page = pages[currentPageIndex]

        if isBookmarked {
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
                self.isBookmarked = false
                self.updateBookmarkButton(page.bookmarkButton, isBookmarked: false)
            })
            present(alert, animated: true)
        } else {
            // Adding → immediate
            isBookmarked = BookmarkService.shared.toggleBookmark(
                word: article.word, dictId: article.dictId
            )
            if isBookmarked {
                BookmarkCountService.shared.incrementAll(dictId: article.dictId)
            }
            updateBookmarkButton(page.bookmarkButton, isBookmarked: isBookmarked)
        }
    }

    private func bookmarksDidChange() {
        guard currentPageIndex < articles.count,
              currentPageIndex < pages.count else { return }
        let article = articles[currentPageIndex]
        isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        updateBookmarkButton(pages[currentPageIndex].bookmarkButton, isBookmarked: isBookmarked)
    }

    // MARK: - Zoom

    func setZoomLevel(_ level: Int) {
        currentZoomLevel = level
        let js = "document.body.style.fontSize = '\(level)%';"
        for page in pages {
            page.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Find

    /// Present or hide system Find UI (iOS 16+)
    @available(iOS 16.0, *)
    func toggleFind() {
        guard currentPageIndex < pages.count else { return }
        let wv = pages[currentPageIndex].webView
        if let findInteraction = wv.findInteraction {
            if findInteraction.isFindNavigatorVisible {
                findInteraction.dismissFindNavigator()
            } else {
                findInteraction.presentFindNavigator(showingReplace: false)
            }
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

// MARK: - WKNavigationDelegate

extension ArticleViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Determine which article this webView belongs to
        let pageIndex = pages.firstIndex(where: { $0.webView === webView }) ?? currentPageIndex
        let article = pageIndex < articles.count ? articles[pageIndex] : nil

        let scheme = url.scheme ?? ""

        switch scheme {
        case "entry":
            // Entry link: navigate to word in same dictionary
            let targetWord = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let dictId = article?.dictId, !targetWord.isEmpty {
                delegate?.articleViewController(self, didTapEntryLink: targetWord, inDict: dictId)
            }
            decisionHandler(.cancel)

        case "sound":
            // Play audio from MDD
            if let dictId = article?.dictId {
                AudioService.shared.play(url: url, dictId: dictId)
            }
            decisionHandler(.cancel)

        case "about":
            decisionHandler(.allow)

        default:
            print("🔗 Unknown link: \(url)")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Apply zoom to this page if non-default
        guard currentZoomLevel != ZoomLevel.defaultLevel else { return }
        let js = "document.body.style.fontSize = '\(currentZoomLevel)%';"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - Jump Search (via UIMenuController responder chain)

extension ArticleViewController {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(jumpSearchAction(_:)) {
            return !articles.isEmpty && currentPageIndex < articles.count
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func jumpSearchAction(_ sender: Any?) {
        guard currentPageIndex < pages.count,
              currentPageIndex < articles.count else { return }
        let wv = pages[currentPageIndex].webView
        let dictId = articles[currentPageIndex].dictId
        wv.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self, let text = result as? String, !text.isEmpty else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.delegate?.articleViewController(self, didRequestJumpSearch: trimmed, inDict: dictId)
        }
    }
}
