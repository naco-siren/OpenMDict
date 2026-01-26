//
//  ArticleViewController.swift
//  OpenMDict-iOS
//
//  Single article view for compact mode (iPhone / iPad narrow)
//  Passive View - no state, just renders what Container gives it
//

import UIKit
import WebKit

// MARK: - Delegate

protocol ArticleViewControllerDelegate: AnyObject {
    func articleViewController(_ vc: ArticleViewController, didTapEntryLink word: String, inDict dictId: String)
}

class ArticleViewController: UIViewController {
    
    // MARK: - Delegate
    
    weak var delegate: ArticleViewControllerDelegate?
    
    // MARK: - State
    
    private var currentArticle: ArticleDisplayItem?
    private var currentZoomLevel: Int = ZoomLevel.defaultLevel
    
    // MARK: - UI
    
    private lazy var headerView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .secondarySystemGroupedBackground
        return v
    }()
    
    private lazy var titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 24, weight: .bold)
        l.numberOfLines = 0
        return l
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        return l
    }()
    
    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MDictSchemeHandler.shared, forURLScheme: "mdict")
        
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = self
        if #available(iOS 16.0, *) {
            wv.isFindInteractionEnabled = true
        }
        return wv
    }()
    
    private lazy var emptyView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .systemBackground
        
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        
        let img = UIImageView(image: UIImage(systemName: "book.closed"))
        img.tintColor = .tertiaryLabel
        img.preferredSymbolConfiguration = .init(pointSize: 64)
        
        let lbl = UILabel()
        lbl.text = "Select a word to view"
        lbl.textColor = .secondaryLabel
        
        stack.addArrangedSubview(img)
        stack.addArrangedSubview(lbl)
        v.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        setupUI()
        showEmpty()
    }
    
    private func setupUI() {
        view.addSubview(headerView)
        view.addSubview(webView)
        view.addSubview(emptyView)
        
        headerView.addSubview(titleLabel)
        headerView.addSubview(subtitleLabel)
        
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -16),
            
            webView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    // MARK: - Trait Changes
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            reloadWebView()
        }
    }
    
    // MARK: - Public API (called by Container)
    
    func configure(article: ArticleDisplayItem?) {
        let articleChanged = (currentArticle?.id != article?.id)
        let contentStateChanged = (currentArticle?.contentState != article?.contentState)
        currentArticle = article
        
        if let article = article {
            showArticle(article, reload: articleChanged || contentStateChanged)
        } else {
            showEmpty()
        }
    }
    
    private func showArticle(_ article: ArticleDisplayItem, reload: Bool) {
        emptyView.isHidden = true
        headerView.isHidden = false
        webView.isHidden = false
        
        titleLabel.text = article.word
        subtitleLabel.text = article.dictName
        
        if reload {
            loadContent(for: article)
        }
    }
    
    private func showEmpty() {
        emptyView.isHidden = false
        headerView.isHidden = true
        webView.isHidden = true
        currentArticle = nil
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
    
    private func reloadWebView() {
        guard let article = currentArticle else { return }
        loadContent(for: article)
    }
    
    // MARK: - Zoom
    
    func setZoomLevel(_ level: Int) {
        currentZoomLevel = level
        let js = "document.body.style.fontSize = '\(level)%';"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("⚠️ Zoom JS error: \(error)")
            }
        }
    }

    // MARK: - Find

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

extension ArticleViewController: WKNavigationDelegate {
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
                delegate?.articleViewController(self, didTapEntryLink: targetWord, inDict: dictId)
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
}
