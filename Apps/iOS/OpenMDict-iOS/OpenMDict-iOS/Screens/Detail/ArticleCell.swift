//
//  ArticleCell.swift
//  OpenMDict-iOS
//
//  Collection view cell for displaying dictionary articles in regular mode.
//  Thin shell wrapping a shared ArticlePageView — all header + webView layout,
//  WKNavigationDelegate, drag, and jump search are handled by ArticlePageView.
//

import UIKit
import WebKit

// MARK: - Delegate

protocol ArticleCellDelegate: AnyObject {
    func articleCell(_ cell: ArticleCell, didTapEntryLink word: String, inDict dictId: String)
}

class ArticleCell: UICollectionViewCell {

    // MARK: - Page View

    private(set) var pageView: ArticlePageView!

    // MARK: - Delegate (for entry links)

    weak var delegate: ArticleCellDelegate?

    // MARK: - State

    private var currentLayoutMode: ArticleLayoutMode = .columns
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

        let config = ArticlePageView.Configuration.regularCell(
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

    func configure(with article: ArticleDisplayItem, layoutMode: ArticleLayoutMode) {
        let articleChanged = (currentArticle?.id != article.id)
        let contentStateChanged = (currentArticle?.contentState != article.contentState)

        currentLayoutMode = layoutMode
        currentArticle = article

        let isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        pageView.configure(word: article.word, dictName: article.dictName,
                          dictId: article.dictId, isBookmarked: isBookmarked)

        // Lookup count
        let count = LookupHistoryService.shared.totalLookupCount(word: article.word, dictId: article.dictId)
        pageView.setLookupCount(count)

        // Grid mode: disable webView scroll & interaction, hide per-cell find
        pageView.webView.scrollView.isScrollEnabled = (layoutMode != .grid)
        if #available(iOS 16, *) {
            pageView.setFindInPageHidden(layoutMode == .grid)
        }
        if layoutMode == .grid {
            pageView.setWebViewInteractive(false)
        }

        // Wire internal callbacks that depend on the current article
        pageView.onEntryLinkTapped = { [weak self] word in
            guard let self else { return }
            self.delegate?.articleCell(self, didTapEntryLink: word, inDict: article.dictId)
        }
        pageView.onSoundLinkTapped = { url in
            AudioService.shared.play(url: url, dictId: article.dictId)
        }

        // Load content when article or content state changes
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
            pageView.loadHTMLContent(styledHTML)

        case .notFound:
            pageView.removePendingOverlay()
            let html = ArticleHTMLRenderer.renderNotFound(word: article.word, dictName: article.dictName, traitCollection: traitCollection)
            pageView.loadHTMLContent(html)
        }
    }

    // MARK: - Lifecycle

    override func prepareForReuse() {
        super.prepareForReuse()
        delegate = nil
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

    /// Refresh only the bookmark icon state from persistence.
    func refreshBookmarkState() {
        guard let article = currentArticle else { return }
        let newState = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        pageView.setBookmarked(newState)
    }

    /// Refresh only the lookup count label from persistence.
    func refreshLookupCount() {
        guard let article = currentArticle else { return }
        let count = LookupHistoryService.shared.totalLookupCount(word: article.word, dictId: article.dictId)
        pageView.setLookupCount(count)
    }

    /// Check if a point (in this cell's coordinate space) falls within the header area.
    func isPointInHeader(_ pointInCell: CGPoint) -> Bool {
        pageView.isPointInHeader(pointInCell)
    }

    func setWebViewInteractive(_ interactive: Bool) {
        pageView.setWebViewInteractive(interactive)
    }

    func forceReloadWebView() {
        guard let article = currentArticle else { return }
        loadContent(for: article)
    }

    func setZoomLevel(_ level: Int) {
        pageView.setZoomLevel(level)
    }

    func setDarkModeEnhance(_ enhance: Bool) {
        pageView.setDarkModeEnhance(enhance)
    }

    /// Present system Find UI (iOS 16+)
    @available(iOS 16.0, *)
    func presentFind() {
        pageView.presentFind()
    }

    /// Dismiss system Find UI (iOS 16+)
    @available(iOS 16.0, *)
    func dismissFind() {
        pageView.dismissFind()
    }

    /// Check if find navigator is currently visible (iOS 16+)
    var isFindNavigatorVisible: Bool {
        pageView.isFindNavigatorVisible
    }

    // MARK: - JavaScript Highlight (for multi-article search)

    func highlightKeyword(_ keyword: String?) {
        pageView.highlightKeyword(keyword)
    }
}
