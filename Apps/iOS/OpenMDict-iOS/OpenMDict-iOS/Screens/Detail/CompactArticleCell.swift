//
//  CompactArticleCell.swift
//  OpenMDict-iOS
//
//  Collection view cell for the compact-mode horizontal article pager
//  (ArticleViewController).  Thin shell wrapping a shared ArticlePageView
//  configured with the `.compactPager` feature set (64pt header, full-bleed,
//  close button, no drag / new-window).
//
//  Deliberately mirrors ArticleCell (regular mode) so the compact pager gets
//  the same cell recycling + WKWebView reuse.  The old manual pager
//  (UIScrollView + rebuildPages) instead built one live WKWebView per article
//  and tore them all down + recreated them on every push; discarded webviews
//  were mid-navigation and got pinned by WebKit::NavigationState, leaking
//  unboundedly until the app OOM-crashed (`NSISVariable couldNotInstantiate`).
//  Recycling caps the live cell/WKWebView working set to the visible window.
//

import UIKit
import WebKit

final class CompactArticleCell: UICollectionViewCell {

    // MARK: - Page View

    private(set) var pageView: ArticlePageView!

    // MARK: - State

    private(set) var currentArticle: ArticleDisplayItem?

    // MARK: - Shared WKWebViewConfiguration

    private static let sharedWebViewConfiguration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        config.setURLSchemeHandler(MDictSchemeHandler.shared, forURLScheme: MDictSchemeHandler.scheme)
        return config
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        let config = ArticlePageView.Configuration.compactPager(
            webViewConfig: Self.sharedWebViewConfiguration
        )
        pageView = ArticlePageView(configuration: config)
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pageView)

        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configuration

    /// Configure the cell's display state for `article`, (re)loading its HTML
    /// only when the article identity or content state changed.  Callbacks
    /// (entry-link, close, bookmark, …) are wired by the owning VC's cell
    /// registration closure, which has the article + VC in scope.
    func configure(with article: ArticleDisplayItem) {
        let articleChanged = (currentArticle?.id != article.id)
        let contentStateChanged = (currentArticle?.contentState != article.contentState)
        currentArticle = article

        let isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        pageView.configure(word: article.word, dictName: article.dictName,
                           dictId: article.dictId, isBookmarked: isBookmarked)

        // Compute the lookup count only when the setting is on; off → 0 (hidden),
        // skipping the lookup entirely.
        let count = UserDefaults.shared.showLookupCount
            ? LookupHistoryService.shared.totalLookupCount(word: article.word, dictId: article.dictId)
            : 0
        pageView.setLookupCount(count)

        pageView.setDarkModeEnhance(strength: ArticlesViewController.enhanceStrength(for: article.dictId))

        if articleChanged || contentStateChanged {
            loadContent(for: article)
        }
    }

    private func loadContent(for article: ArticleDisplayItem) {
        switch article.contentState {
        case .pending:
            let html = ArticleHTMLRenderer.renderPending(word: article.word, traitCollection: traitCollection)
            pageView.loadHTMLContent(html)
            pageView.showPendingOverlay(word: article.word, dictName: article.dictName)

        case .loaded(let html, _):
            pageView.removePendingOverlay()
            let styledHTML = ArticleHTMLRenderer.renderArticle(html: html, dictId: article.dictId, traitCollection: traitCollection)
            // Same-origin base URL so `@font-face` fonts (a CORS-enabled fetch)
            // load from mdict://<dictId> without being blocked as cross-origin.
            // See ArticleCell.loadContent for the full rationale.
            let baseURL = URL(string: "\(MDictSchemeHandler.scheme)://\(article.dictId)/")
            pageView.loadHTMLContent(styledHTML, baseURL: baseURL)

        case .notFound:
            pageView.removePendingOverlay()
            let html = ArticleHTMLRenderer.renderNotFound(word: article.word, dictName: article.dictName, traitCollection: traitCollection)
            pageView.loadHTMLContent(html)
        }
    }

    // MARK: - Lifecycle

    override func prepareForReuse() {
        super.prepareForReuse()
        pageView.prepareForReuse()
        currentArticle = nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            forceReloadWebView()
        }
    }

    // MARK: - Public Methods (proxies to pageView)

    func setZoomLevel(_ level: Int) {
        pageView.setZoomLevel(level)
    }

    func setDarkModeEnhance(strength: EnhanceDarkModeStrength?) {
        pageView.setDarkModeEnhance(strength: strength)
    }

    /// Scroll the inner WebView to an in-page anchor (cross-reference target).
    func scrollToAnchor(_ anchor: String?) {
        pageView.scrollToAnchor(anchor)
    }

    /// Refresh only the bookmark icon state from persistence.
    func refreshBookmarkState() {
        guard let article = currentArticle else { return }
        pageView.setBookmarked(BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId))
    }

    /// Refresh only the lookup count label from persistence.
    func refreshLookupCount() {
        guard let article = currentArticle else { return }
        let count = UserDefaults.shared.showLookupCount
            ? LookupHistoryService.shared.totalLookupCount(word: article.word, dictId: article.dictId)
            : 0
        pageView.setLookupCount(count)
    }

    /// Re-render the current article's HTML (e.g. on light/dark appearance change).
    func forceReloadWebView() {
        guard let article = currentArticle else { return }
        loadContent(for: article)
    }

    @available(iOS 16.0, *)
    func presentFind() { pageView.presentFind() }

    @available(iOS 16.0, *)
    func dismissFind() { pageView.dismissFind() }

    var isFindNavigatorVisible: Bool { pageView.isFindNavigatorVisible }
}
