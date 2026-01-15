//
//  ArticleCell.swift
//  OpenMDict-iOS
//
//  Collection view cell for displaying dictionary article with WKWebView
//

import UIKit
import WebKit

class ArticleCell: UICollectionViewCell {
    
    // MARK: - Callbacks
    
    var onClose: (() -> Void)?
    var onOpenInNewWindow: (() -> Void)?
    var onBookmarkToggle: ((Bool) -> Void)?

    // MARK: - State
    
    private var currentLayoutMode: ArticleLayoutMode = .columns
    private var currentArticle: ArticleItem?
    private var isBookmarked: Bool = false
    
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
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = self
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
    
    func configure(with article: ArticleItem, layoutMode: ArticleLayoutMode) {
        let shouldReloadWeb = (currentArticle?.id != article.id)
        currentLayoutMode = layoutMode
        currentArticle = article
        
        titleLabel.text = article.title
        subtitleLabel.text = article.dictName
        
        // TODO: Combine ArticleItem with bookmark state (loaded from persistence)
        isBookmarked = false
        bookmarkButton.setNeedsUpdateConfiguration()

        // Disable scroll in Grid mode, due to viewport too small
        webView.scrollView.isScrollEnabled = (layoutMode != .grid)
        webView.isUserInteractionEnabled = (layoutMode != .grid)

        // Load content when Article changes
        if shouldReloadWeb {
            let styledHTML = wrapHTML(article.html)
            webView.loadHTMLString(styledHTML, baseURL: nil)
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
        let styledHTML = wrapHTML(article.html)
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
    
    // MARK: - HTML Rendering
    
    private func wrapHTML(_ html: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { -webkit-user-select: none; user-select: none; }
                body {
                    font-family: -apple-system, system-ui;
                    font-size: 15px;
                    line-height: 1.5;
                    margin: 12px;
                    padding: 0;
                    color: \(cssColor(.label));
                    background: transparent;
                }
                h2.h { font-size: 1.3em; margin: 0 0 8px 0; }
                .pos { color: \(cssColor(.secondaryLabel)); font-style: italic; }
                .def { display: block; margin: 8px 0; }
                .x { color: \(cssColor(.secondaryLabel)); display: block; margin: 4px 0 4px 16px; }
                .x::before { content: "• "; }
                .phon { color: \(cssColor(.systemBlue)); }
                .num { font-weight: bold; margin-right: 4px; }
                .collapse { display: block; margin-top: 12px; padding-top: 8px; border-top: 1px solid \(cssColor(.separator)); }
                .heading { font-weight: 600; display: block; margin-bottom: 4px; }
                a { color: \(cssColor(.link)); text-decoration: none; }
            </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }
    
    private func cssColor(_ uiColor: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int(r*255)), \(Int(g*255)), \(Int(b*255)), \(a))"
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
            print("📖 Entry link: \(url.host ?? url.absoluteString)")
            decisionHandler(.cancel)
        case "sound":
            print("🔊 Sound link: \(url.path)")
            decisionHandler(.cancel)
        case "about":
            decisionHandler(.allow)
        default:
            print("🔗 Unknown link: \(url)")
            decisionHandler(.cancel)
        }
    }
}
