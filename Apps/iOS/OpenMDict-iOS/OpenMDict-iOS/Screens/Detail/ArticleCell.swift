//
//  ArticleCell.swift
//  OpenMDict-iOS
//
//  Collection view cell for displaying dictionary article with WKWebView
//

import UIKit
import WebKit

// MARK: - Delegate

protocol ArticleCellDelegate: AnyObject {
    func articleCell(_ cell: ArticleCell, didTapEntryLink word: String, inDict dictId: String)
}

class ArticleCell: UICollectionViewCell {
    
    // MARK: - Callbacks
    
    weak var delegate: ArticleCellDelegate?
    var onClose: (() -> Void)?
    var onOpenInNewWindow: (() -> Void)?
    var onBookmarkToggle: ((Bool) -> Void)?

    // MARK: - State
    
    private var currentLayoutMode: ArticleLayoutMode = .columns
    private var currentArticle: ArticleDisplayItem?
    private var isBookmarked: Bool = false
    private var currentZoomLevel: Int = ZoomLevel.defaultLevel
    
    // MARK: - Views
    
    private let containerView = UIView()
    private let headerView = UIView()
    
    private lazy var bookmarkButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "bookmark")
        config.baseForegroundColor = .secondaryLabel
        let btn = UIButton(configuration: config)
        btn.configurationUpdateHandler = { [weak self] button in
            guard let self = self else { return }
            var config = button.configuration
            let imageName = self.isBookmarked ? "bookmark.fill" : "bookmark"
            config?.image = UIImage(systemName: imageName)
            config?.baseForegroundColor = self.isBookmarked ? nil : .secondaryLabel
            button.configuration = config
        }
        btn.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        return btn
    }()
    
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    
    // Trailing toolbar buttons
    private lazy var newWindowButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "rectangle.badge.plus")
        config.baseForegroundColor = .secondaryLabel
        let btn = UIButton(configuration: config)
        btn.addTarget(self, action: #selector(newWindowTapped), for: .touchUpInside)
        return btn
    }()
    
    private lazy var closeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark.circle.fill")
        config.baseForegroundColor = .secondaryLabel
        let btn = UIButton(configuration: config)
        btn.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.baseForegroundColor = button.isHighlighted ? .systemRed : .secondaryLabel
            button.configuration = config
        }
        btn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return btn
    }()
    
    private var webView: WKWebView!

    // MARK: - Init
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    // MARK: - Setup
    
    private func setupUI() {
        // Container
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 12
        containerView.layer.masksToBounds = true
        containerView.backgroundColor = .secondarySystemGroupedBackground
        contentView.addSubview(containerView)
        
        // Header bar
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = .systemFill
        containerView.addSubview(headerView)
        
        // Leading icon
        bookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(bookmarkButton)
        
        // Title & subtitle stack
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        
        let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleStack)
        
        // Trailing toolbar
        let toolbarStack = UIStackView(arrangedSubviews: [newWindowButton, closeButton])
        toolbarStack.axis = .horizontal
        toolbarStack.spacing = 0
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(toolbarStack)
        
        // Content WebView
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        config.setURLSchemeHandler(MDictSchemeHandler.shared, forURLScheme: MDictSchemeHandler.scheme)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = self
        if #available(iOS 16.0, *) {
            wv.isFindInteractionEnabled = true
        }
        containerView.addSubview(wv)
        webView = wv
        
        NSLayoutConstraint.activate([
            // Container fills cell's contentView
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            
            // Header at top of container
            headerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),
            
            // Leading bookmark button
            bookmarkButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 4),
            bookmarkButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                        
            // Title stack after icon
            titleStack.leadingAnchor.constraint(equalTo: bookmarkButton.trailingAnchor, constant: 8),
            titleStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: toolbarStack.leadingAnchor, constant: -8),
            
            // Trailing toolbar
            toolbarStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -4),
            toolbarStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            
            // Article content below header
            webView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    // MARK: - Configuration
    
    func configure(with article: ArticleDisplayItem, layoutMode: ArticleLayoutMode) {
        let articleChanged = (currentArticle?.id != article.id)
        let contentStateChanged = (currentArticle?.contentState != article.contentState)
                 
        currentLayoutMode = layoutMode
        currentArticle = article
        
        titleLabel.text = article.word
        subtitleLabel.text = article.dictName
        
        // TODO: Combine ArticleDisplayItem with bookmark state (loaded from persistence)
        isBookmarked = false
        bookmarkButton.setNeedsUpdateConfiguration()

        // Disable scroll in Grid mode, due to viewport too small
        webView.scrollView.isScrollEnabled = (layoutMode != .grid)
        webView.isUserInteractionEnabled = (layoutMode != .grid)

        // Load content when article or content state changes
        if articleChanged || contentStateChanged {
            loadContent(for: article)
        }
    }
    
    private func loadContent(for article: ArticleDisplayItem) {
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
    
    // MARK: - Actions
    
    @objc private func closeTapped() { onClose?() }
    @objc private func newWindowTapped() { onOpenInNewWindow?() }
    @objc private func bookmarkTapped() {
        isBookmarked.toggle()
        bookmarkButton.setNeedsUpdateConfiguration()
        onBookmarkToggle?(isBookmarked)
    }
    
    // MARK: - Lifecycle
    
    override func prepareForReuse() {
        super.prepareForReuse()
        delegate = nil
        onClose = nil
        onOpenInNewWindow = nil
        onBookmarkToggle = nil
        currentArticle = nil
        isBookmarked = false
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            forceReloadWebView()
        }
    }
    
    // MARK: - Public Methods
    
    func setWebViewInteractive(_ interactive: Bool) {
        webView.isUserInteractionEnabled = interactive
        containerView.alpha = interactive ? 1.0 : 0.95
    }
    
    func forceReloadWebView() {
        guard let article = currentArticle else { return }
        loadContent(for: article)
    }
    
    func setZoomLevel(_ level: Int) {
        currentZoomLevel = level
        let js = "document.body.style.fontSize = '\(level)%';"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("⚠️ Zoom JS error: \(error)")
            }
        }
    }
    
    /// Present system Find UI (iOS 16+)
    @available(iOS 16.0, *)
    func presentFind() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }
    
    /// Dismiss system Find UI (iOS 16+)
    @available(iOS 16.0, *)
    func dismissFind() {
        webView.findInteraction?.dismissFindNavigator()
    }
}

// MARK: - WKNavigationDelegate

extension ArticleCell: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        
        let scheme = url.scheme ?? ""
        
        switch scheme {
        case "entry":
            // Entry link: navigate to word in same dictionary
            let targetWord = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let dictId = currentArticle?.dictId, !targetWord.isEmpty {
                delegate?.articleCell(self, didTapEntryLink: targetWord, inDict: dictId)
            }
            decisionHandler(.cancel)
        case "sound":
            // Play audio from MDD
            if let dictId = currentArticle?.dictId {
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
        // Apply zoom level after content loads
        if currentZoomLevel != ZoomLevel.defaultLevel {
            let js = "document.body.style.fontSize = '\(currentZoomLevel)%';"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
