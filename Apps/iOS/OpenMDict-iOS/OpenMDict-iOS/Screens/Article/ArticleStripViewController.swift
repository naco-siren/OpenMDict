//
//  ArticleStripViewController.swift
//  OpenMDict-iOS
//
//  Secondary column: horizontal article cards (IDE-style)
//
//  Features:
//  - Multiple article cards side by side
//  - New articles push from left
//  - Drag to reorder
//  - Navigation bar for actions (not bottom toolbar)
//

import UIKit

class ArticleStripViewController: UIViewController {
    
    // MARK: - Configuration
    
    private let cardWidthRatio: CGFloat = 0.4
    private let minCardWidth: CGFloat = 320
    private let cardSpacing: CGFloat = 1
    private let maxCards: Int = 10
    
    // MARK: - State
    
    private(set) var articles: [ArticleItem] = []
    private var cardViews: [String: ArticleCardView] = [:]
    
    var currentArticle: ArticleItem? {
        articles.first
    }
    
    // MARK: - UI
    
    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = true
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceHorizontal = true
        sv.alwaysBounceVertical = false
        return sv
    }()
    
    private lazy var stackView: UIStackView = {
        let sv = UIStackView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.axis = .horizontal
        sv.alignment = .fill
        sv.distribution = .fill
        sv.spacing = cardSpacing
        return sv
    }()
    
    private lazy var emptyView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        
        let imageView = UIImageView(image: UIImage(systemName: "book.closed"))
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = .init(pointSize: 64)
        
        let label = UILabel()
        label.text = "Select a word to view"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .headline)
        
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(label)
        view.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        
        return view
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNavigationBar()
        updateEmptyState()
    }
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        // Empty state
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        // Scroll view
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        
        // Stack view
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }
    
    private func setupNavigationBar() {
        // Navigation bar items (right side)
        let zoomMenu = UIMenu(title: "Zoom", children: [
            UIAction(title: "Zoom In", image: UIImage(systemName: "plus.magnifyingglass")) { _ in
                print("Zoom in - TODO")
            },
            UIAction(title: "Zoom Out", image: UIImage(systemName: "minus.magnifyingglass")) { _ in
                print("Zoom out - TODO")
            },
            UIAction(title: "Reset", image: UIImage(systemName: "1.magnifyingglass")) { _ in
                print("Reset zoom - TODO")
            },
        ])
        let zoomItem = UIBarButtonItem(image: UIImage(systemName: "textformat.size"), menu: zoomMenu)
        
        navigationItem.rightBarButtonItems = [zoomItem]
    }
    
    // MARK: - Card Width
    
    private var cardWidth: CGFloat {
        max(minCardWidth, view.bounds.width * cardWidthRatio)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        let width = cardWidth
        for card in cardViews.values {
            card.updateWidth(width)
        }
    }
    
    // MARK: - Public API
    
    func preloadArticle(_ article: ArticleItem) {
        articles.insert(article, at: 0)
    }
    
    func pushArticle(_ article: ArticleItem, animated: Bool) {
        // Check if already exists → scroll to it
        if let existingIndex = articles.firstIndex(where: { $0.id == article.id }) {
            scrollToCard(at: existingIndex, animated: animated)
            return
        }
        
        // Create new card
        let card = createCard(for: article)
        articles.insert(article, at: 0)
        
        if animated {
            // Push from left animation
            card.alpha = 0
            card.transform = CGAffineTransform(translationX: -cardWidth, y: 0)
            stackView.insertArrangedSubview(card, at: 0)
            
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
                card.alpha = 1
                card.transform = .identity
                self.scrollView.contentOffset = .zero
            } completion: { _ in
                self.trimExcessCards()
            }
        } else {
            stackView.insertArrangedSubview(card, at: 0)
            trimExcessCards()
        }
        
        updateEmptyState()
    }
    
    func closeArticle(_ article: ArticleItem, animated: Bool = true) {
        guard let index = articles.firstIndex(of: article),
              let card = cardViews[article.id] else {
            return
        }
        
        articles.remove(at: index)
        cardViews.removeValue(forKey: article.id)
        
        if animated {
            UIView.animate(withDuration: 0.25) {
                card.alpha = 0
                card.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            } completion: { _ in
                card.removeFromSuperview()
                self.updateEmptyState()
            }
        } else {
            card.removeFromSuperview()
            updateEmptyState()
        }
    }
    
    func moveCard(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex != destIndex,
              sourceIndex >= 0, sourceIndex < articles.count,
              destIndex >= 0, destIndex < articles.count else {
            return
        }
        
        let article = articles.remove(at: sourceIndex)
        articles.insert(article, at: destIndex)
        
        if let card = cardViews[article.id] {
            stackView.removeArrangedSubview(card)
            stackView.insertArrangedSubview(card, at: destIndex)
        }
    }
    
    // MARK: - Private
    
    private func createCard(for article: ArticleItem) -> ArticleCardView {
        let card = ArticleCardView(article: article)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        
        card.onClose = { [weak self] in
            self?.closeArticle(article, animated: true)
        }
        
        card.onOpenInNewWindow = {
            SceneDelegate.openNewWindow(for: article)
        }
        
        card.onFavorite = {
            print("⭐ Favorite: \(article.title) - TODO")
        }
        
        card.onSpeak = {
            print("🔊 Speak: \(article.title) - TODO")
        }
        
        // Drag interaction
        let dragInteraction = UIDragInteraction(delegate: self)
        dragInteraction.isEnabled = true
        card.addInteraction(dragInteraction)
        
        // Drop interaction
        let dropInteraction = UIDropInteraction(delegate: self)
        card.addInteraction(dropInteraction)
        
        cardViews[article.id] = card
        return card
    }
    
    private func scrollToCard(at index: Int, animated: Bool) {
        let x = CGFloat(index) * (cardWidth + cardSpacing)
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }
    
    private func trimExcessCards() {
        while articles.count > maxCards {
            if let last = articles.last {
                closeArticle(last, animated: false)
            }
        }
    }
    
    private func updateEmptyState() {
        let isEmpty = articles.isEmpty
        emptyView.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }
}

// MARK: - UIDragInteractionDelegate

extension ArticleStripViewController: UIDragInteractionDelegate {
    
    func dragInteraction(_ interaction: UIDragInteraction,
                         itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let card = interaction.view as? ArticleCardView else { return [] }
        
        let itemProvider = NSItemProvider(object: card.article.title as NSString)
        itemProvider.registerObject(card.article.userActivity, visibility: .all)
        
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = card.article
        return [dragItem]
    }
    
    func dragInteraction(_ interaction: UIDragInteraction,
                         previewForLifting item: UIDragItem,
                         session: UIDragSession) -> UITargetedDragPreview? {
        guard let card = interaction.view as? ArticleCardView else { return nil }
        
        let params = UIDragPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 12)
        return UITargetedDragPreview(view: card, parameters: params)
    }
}

// MARK: - UIDropInteractionDelegate

extension ArticleStripViewController: UIDropInteractionDelegate {
    
    func dropInteraction(_ interaction: UIDropInteraction,
                         canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }
    
    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: session.localDragSession != nil ? .move : .forbidden)
    }
    
    func dropInteraction(_ interaction: UIDropInteraction,
                         performDrop session: UIDropSession) {
        guard let draggedArticle = session.localDragSession?.items.first?.localObject as? ArticleItem,
              let targetCard = interaction.view as? ArticleCardView else {
            return
        }
        
        let sourceIndex = articles.firstIndex(of: draggedArticle)
        let destIndex = articles.firstIndex(of: targetCard.article)
        
        if let source = sourceIndex, let dest = destIndex {
            moveCard(from: source, to: dest)
        }
    }
}

// MARK: - Article Card View

class ArticleCardView: UIView {
    
    let article: ArticleItem
    
    var onClose: (() -> Void)?
    var onOpenInNewWindow: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onSpeak: (() -> Void)?
    
    private var widthConstraint: NSLayoutConstraint?
    
    // MARK: - UI
    
    private lazy var containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = article.color
        view.layer.cornerRadius = 12
        view.layer.masksToBounds = true
        return view
    }()
    
    private lazy var headerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.1)
        return view
    }()
    
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        label.text = article.title
        return label
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.text = article.dictName
        return label
    }()
    
    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        button.tintColor = .secondaryLabel
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var actionStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 16
        return stack
    }()
    
    private lazy var favoriteButton: UIButton = {
        createActionButton(icon: "star", action: #selector(favoriteTapped))
    }()
    
    private lazy var speakButton: UIButton = {
        createActionButton(icon: "speaker.wave.2", action: #selector(speakTapped))
    }()
    
    private lazy var copyButton: UIButton = {
        createActionButton(icon: "doc.on.doc", action: #selector(copyTapped))
    }()
    
    private lazy var newWindowButton: UIButton = {
        createActionButton(icon: "square.split.2x1", action: #selector(newWindowTapped))
    }()
    
    private lazy var contentLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.text = "📖\n\n\(article.title)\n\n(WKWebView with HTML content)"
        return label
    }()
    
    // MARK: - Init
    
    init(article: ArticleItem) {
        self.article = article
        super.init(frame: .zero)
        setupUI()
        setupContextMenu()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        
        // Header
        containerView.addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 50),
        ])
        
        // Title & subtitle
        let labelStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.axis = .vertical
        labelStack.spacing = 2
        
        headerView.addSubview(labelStack)
        headerView.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            labelStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        
        // Action buttons
        actionStack.addArrangedSubview(favoriteButton)
        actionStack.addArrangedSubview(speakButton)
        actionStack.addArrangedSubview(copyButton)
        actionStack.addArrangedSubview(newWindowButton)
        
        containerView.addSubview(actionStack)
        NSLayoutConstraint.activate([
            actionStack.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
            actionStack.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        ])
        
        // Content
        containerView.addSubview(contentLabel)
        NSLayoutConstraint.activate([
            contentLabel.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 20),
            contentLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            contentLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
        ])
    }
    
    private func createActionButton(icon: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: icon), for: .normal)
        button.tintColor = .label
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
    
    private func setupContextMenu() {
        let interaction = UIContextMenuInteraction(delegate: self)
        containerView.addInteraction(interaction)
    }
    
    // MARK: - Actions
    
    @objc private func closeTapped() { onClose?() }
    @objc private func favoriteTapped() { onFavorite?() }
    @objc private func speakTapped() { onSpeak?() }
    @objc private func copyTapped() { UIPasteboard.general.string = article.title }
    @objc private func newWindowTapped() { onOpenInNewWindow?() }
    
    // MARK: - Width
    
    func updateWidth(_ width: CGFloat) {
        if let constraint = widthConstraint {
            constraint.constant = width
        } else {
            widthConstraint = widthAnchor.constraint(equalToConstant: width)
            widthConstraint?.isActive = true
        }
    }
}

// MARK: - UIContextMenuInteractionDelegate

extension ArticleCardView: UIContextMenuInteractionDelegate {
    
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            
            let newWindow = UIAction(title: "Open in New Window", image: UIImage(systemName: "square.split.2x1")) { _ in
                self.onOpenInNewWindow?()
            }
            let favorite = UIAction(title: "Favorite", image: UIImage(systemName: "star")) { _ in
                self.onFavorite?()
            }
            let copy = UIAction(title: "Copy Word", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = self.article.title
            }
            let close = UIAction(title: "Close", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
                self.onClose?()
            }
            
            return UIMenu(children: [newWindow, favorite, copy, close])
        }
    }
}
