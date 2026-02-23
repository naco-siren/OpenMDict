//
//  ArticleViewController.swift
//  OpenMDict-iOS
//
//  Single article view for compact mode (iPhone / iPad narrow)
//  Passive View - no state, just renders what Container gives it
//

import Combine
import UIKit
import WebKit

// MARK: - Delegate

protocol ArticleViewControllerDelegate: AnyObject {
    func articleViewController(_ vc: ArticleViewController, didTapEntryLink word: String, inDict dictId: String)
    func articleViewController(_ vc: ArticleViewController, didRequestJumpSearch word: String, inDict dictId: String)
}

class ArticleViewController: UIViewController {
    
    // MARK: - Delegate
    
    weak var delegate: ArticleViewControllerDelegate?
    
    // MARK: - State

    private var currentArticle: ArticleDisplayItem?
    private var currentZoomLevel: Int = ZoomLevel.defaultLevel
    private var isBookmarked: Bool = false
    private var lookupCountCancellable: AnyCancellable?
    private var bookmarkCancellable: AnyCancellable?
    
    // MARK: - UI

    private static let headerHeight: CGFloat = 64

    private lazy var headerView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .secondarySystemGroupedBackground
        return v
    }()

    private lazy var bookmarkButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "bookmark")
        config.baseForegroundColor = .secondaryLabel
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            var config = button.configuration
            let imageName = self.isBookmarked ? "bookmark.fill" : "bookmark"
            config?.image = UIImage(systemName: imageName)
            config?.baseForegroundColor = self.isBookmarked ? nil : .secondaryLabel
            button.configuration = config
        }
        btn.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    private lazy var subtitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabel
        return l
    }()

    private lazy var lookupCountLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .italicSystemFont(ofSize: 11)
        return l
    }()

    // Drag preview (styled like ArticlePreviewViewController)
    private var dragPreviewTitleLabel: UILabel!
    private var dragPreviewSubtitleLabel: UILabel!
    private var dragPreviewWidthConstraint: NSLayoutConstraint!

    private lazy var dragPreviewView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .systemFill
        v.layer.cornerRadius = 12
        v.layer.masksToBounds = true

        let iconName: String = if #available(iOS 17.0, *) { "book.pages" } else { "menucard" }
        let iconView = UIImageView(image: UIImage(systemName: iconName))
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = .init(pointSize: 16, weight: .regular)

        let titleLbl = UILabel()
        titleLbl.font = .systemFont(ofSize: 17, weight: .semibold)
        dragPreviewTitleLabel = titleLbl

        let subtitleLbl = UILabel()
        subtitleLbl.font = .systemFont(ofSize: 13)
        subtitleLbl.textColor = .secondaryLabel
        dragPreviewSubtitleLabel = subtitleLbl

        let titleStack = UIStackView(arrangedSubviews: [titleLbl, subtitleLbl])
        titleStack.axis = .vertical
        titleStack.spacing = 2

        let mainStack = UIStackView(arrangedSubviews: [iconView, titleStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 10
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(mainStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            mainStack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            mainStack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])

        return v
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
        lbl.text = L10n.Articles.selectWord
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

        bookmarkCancellable = BookmarkService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.bookmarksDidChange()
            }
    }
    
    private func setupUI() {
        view.addSubview(headerView)
        view.addSubview(webView)
        view.addSubview(emptyView)

        // Leading: bookmark button
        headerView.addSubview(bookmarkButton)

        // Column: title, subtitle, lookup count
        let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, lookupCountLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleStack)

        // Drag interaction on header (drag to open in new window)
        let drag = UIDragInteraction(delegate: self)
        headerView.addInteraction(drag)

        // Drag preview (hidden behind headerView, snapshotted on drag)
        view.addSubview(dragPreviewView)
        view.sendSubviewToBack(dragPreviewView)
        dragPreviewWidthConstraint = dragPreviewView.widthAnchor.constraint(equalToConstant: 200)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            // Bookmark at leading, vertically centered
            bookmarkButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 4),
            bookmarkButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            bookmarkButton.widthAnchor.constraint(equalToConstant: 40),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 40),

            // Title stack after bookmark, vertically centered
            titleStack.leadingAnchor.constraint(equalTo: bookmarkButton.trailingAnchor, constant: 4),
            titleStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -12),

            webView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Drag preview (behind headerView, same vertical center)
            dragPreviewView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            dragPreviewView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            dragPreviewView.heightAnchor.constraint(equalToConstant: 72),
            dragPreviewWidthConstraint,
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

        // Update drag preview content
        dragPreviewTitleLabel.text = article.word
        dragPreviewSubtitleLabel.text = article.dictName
        let previewTitleWidth = max(dragPreviewTitleLabel.intrinsicContentSize.width,
                                    dragPreviewSubtitleLabel.intrinsicContentSize.width)
        dragPreviewWidthConstraint.constant = min(400, 24 + 10 + previewTitleWidth + 32)

        isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        bookmarkButton.setNeedsUpdateConfiguration()

        // Subscribe to this article's lookup count (re-binds on each article change)
        lookupCountCancellable = LookupHistoryService.shared
            .lookupCountPublisher(word: article.word, dictId: article.dictId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                guard let self else { return }
                if count > 0 {
                    self.lookupCountLabel.text = L10n.Articles.lookupCount(count)
                    self.lookupCountLabel.textColor = self.lookupCountColor(for: count)
                    self.lookupCountLabel.isHidden = false
                } else {
                    self.lookupCountLabel.isHidden = true
                }
            }

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
        guard let article = currentArticle else { return }
        if isBookmarked {
            // Removing → show confirmation
            let alert = UIAlertController(
                title: L10n.Bookmarks.removeBookmark,
                message: L10n.Bookmarks.removeBookmarkMessage(word: article.word, dictName: article.dictName),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
                BookmarkService.shared.toggleBookmark(
                    word: article.word, dictId: article.dictId
                )
                self?.isBookmarked = false
                self?.bookmarkButton.setNeedsUpdateConfiguration()
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
            bookmarkButton.setNeedsUpdateConfiguration()
        }
    }

    private func bookmarksDidChange() {
        guard let article = currentArticle else { return }
        isBookmarked = BookmarkService.shared.isBookmarked(word: article.word, dictId: article.dictId)
        bookmarkButton.setNeedsUpdateConfiguration()
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

    /// Present or hide system Find UI (iOS 16+)
    @available(iOS 16.0, *)
    func toggleFind() {
        if let findInteraction = webView.findInteraction {
            if (findInteraction.isFindNavigatorVisible) {
                findInteraction.dismissFindNavigator()
            } else {
                findInteraction.presentFindNavigator(showingReplace: false)
            }
        }
    }
}

// MARK: - UIDragInteractionDelegate

extension ArticleViewController: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let article = currentArticle else { return [] }
        let activity = article.userActivity
        if let sessionId = view.window?.windowScene?.session.persistentIdentifier {
            activity.userInfo?["sourceSessionId"] = sessionId
        }
        let itemProvider = NSItemProvider(object: activity)
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = article
        return [dragItem]
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
        view.layoutIfNeeded()
        let params = UIDragPreviewParameters()
        params.visiblePath = UIBezierPath(roundedRect: dragPreviewView.bounds, cornerRadius: 12)
        return UITargetedDragPreview(view: dragPreviewView, parameters: params)
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

// MARK: - Jump Search (via UIMenuController responder chain)

extension ArticleViewController {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(jumpSearchAction(_:)) {
            return currentArticle != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func jumpSearchAction(_ sender: Any?) {
        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self, let text = result as? String, !text.isEmpty,
                  let dictId = self.currentArticle?.dictId else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.delegate?.articleViewController(self, didRequestJumpSearch: trimmed, inDict: dictId)
        }
    }
}
