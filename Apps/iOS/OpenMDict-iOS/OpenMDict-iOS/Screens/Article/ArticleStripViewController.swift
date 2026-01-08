//
//  ArticleStripViewController.swift
//  OpenMDict-iOS
//

import UIKit

class ArticleStripViewController: UIViewController {
    
    private let cardWidthRatio: CGFloat = 0.5
    private let minCardWidth: CGFloat = 400
    private let cardSpacing: CGFloat = 1
    private let maxCards: Int = 10
    
    private(set) var articles: [ArticleItem] = []
    private var cardViews: [String: ArticleCardView] = [:]
    
    var currentArticle: ArticleItem? { articles.first }
    
    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = true
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceHorizontal = true
        return sv
    }()
    
    private lazy var stackView: UIStackView = {
        let sv = UIStackView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.axis = .horizontal
        sv.spacing = cardSpacing
        return sv
    }()
    
    private lazy var emptyView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(emptyView)
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        updateEmptyState()
    }
    
    private var cardWidth: CGFloat { max(minCardWidth, view.bounds.width * cardWidthRatio) }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for card in cardViews.values { card.updateWidth(cardWidth) }
    }
    
    func preloadArticle(_ article: ArticleItem) {
        articles.insert(article, at: 0)
    }
    
    func pushArticle(_ article: ArticleItem, animated: Bool) {
        if let idx = articles.firstIndex(where: { $0.id == article.id }) {
            scrollView.setContentOffset(CGPoint(x: CGFloat(idx) * (cardWidth + cardSpacing), y: 0), animated: animated)
            return
        }
        let card = createCard(for: article)
        articles.insert(article, at: 0)
        if animated {
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
        guard let idx = articles.firstIndex(of: article), let card = cardViews[article.id] else { return }
        articles.remove(at: idx)
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
    
    func moveCard(from src: Int, to dst: Int) {
        guard src != dst, src >= 0, src < articles.count, dst >= 0, dst < articles.count else { return }
        let a = articles.remove(at: src)
        articles.insert(a, at: dst)
        if let card = cardViews[a.id] {
            stackView.removeArrangedSubview(card)
            stackView.insertArrangedSubview(card, at: dst)
        }
    }
    
    private func createCard(for article: ArticleItem) -> ArticleCardView {
        let card = ArticleCardView(article: article)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        card.onClose = { [weak self] in self?.closeArticle(article) }
        card.onOpenInNewWindow = { SceneDelegate.openNewWindow(for: article) }
        card.onFavorite = { print("⭐ Favorite: \(article.title)") }
        card.onSpeak = { print("🔊 Speak: \(article.title)") }
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        card.addInteraction(drag)
        card.addInteraction(UIDropInteraction(delegate: self))
        cardViews[article.id] = card
        return card
    }
    
    private func trimExcessCards() {
        while articles.count > maxCards, let last = articles.last {
            closeArticle(last, animated: false)
        }
    }
    
    private func updateEmptyState() {
        emptyView.isHidden = !articles.isEmpty
        scrollView.isHidden = articles.isEmpty
    }
}

extension ArticleStripViewController: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let card = interaction.view as? ArticleCardView else { return [] }
        let provider = NSItemProvider(object: card.article.title as NSString)
        provider.registerObject(card.article.userActivity, visibility: .all)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = card.article
        return [item]
    }
}

extension ArticleStripViewController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }
    
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: session.localDragSession != nil ? .move : .forbidden)
    }
    
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let dragged = session.localDragSession?.items.first?.localObject as? ArticleItem,
              let target = (interaction.view as? ArticleCardView)?.article,
              let src = articles.firstIndex(of: dragged),
              let dst = articles.firstIndex(of: target) else { return }
        moveCard(from: src, to: dst)
    }
}

class ArticleCardView: UIView {
    let article: ArticleItem
    var onClose: (() -> Void)?
    var onOpenInNewWindow: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onSpeak: (() -> Void)?
    private var widthConstraint: NSLayoutConstraint?
    
    init(article: ArticleItem) {
        self.article = article
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = article.color
        container.layer.cornerRadius = 12
        container.layer.masksToBounds = true
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = UIColor.black.withAlphaComponent(0.1)
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 50),
        ])
        
        let titleLbl = UILabel()
        titleLbl.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLbl.text = article.title
        
        let subtitleLbl = UILabel()
        subtitleLbl.font = .systemFont(ofSize: 12)
        subtitleLbl.textColor = .secondaryLabel
        subtitleLbl.text = article.dictName
        
        let labels = UIStackView(arrangedSubviews: [titleLbl, subtitleLbl])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        
        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeBtn.tintColor = .secondaryLabel
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addTarget(self, action: #selector(closeTap), for: .touchUpInside)
        
        header.addSubview(labels)
        header.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 30),
            closeBtn.heightAnchor.constraint(equalToConstant: 30),
        ])
        
        let actions = UIStackView()
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.spacing = 16
        actions.addArrangedSubview(makeBtn("star", #selector(favTap)))
        actions.addArrangedSubview(makeBtn("speaker.wave.2", #selector(speakTap)))
        actions.addArrangedSubview(makeBtn("doc.on.doc", #selector(copyTap)))
        actions.addArrangedSubview(makeBtn("square.split.2x1", #selector(newWinTap)))
        container.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            actions.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        
        let content = UILabel()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.numberOfLines = 0
        content.textAlignment = .center
        content.text = "📖\n\n\(article.title)\n\n(WKWebView)"
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        
        container.addInteraction(UIContextMenuInteraction(delegate: self))
    }
    
    private func makeBtn(_ icon: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: icon), for: .normal)
        b.tintColor = .label
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }
    
    @objc private func closeTap() { onClose?() }
    @objc private func favTap() { onFavorite?() }
    @objc private func speakTap() { onSpeak?() }
    @objc private func copyTap() { UIPasteboard.general.string = article.title }
    @objc private func newWinTap() { onOpenInNewWindow?() }
    
    func updateWidth(_ w: CGFloat) {
        if let c = widthConstraint {
            c.constant = w
        } else {
            widthConstraint = widthAnchor.constraint(equalToConstant: w)
            widthConstraint?.isActive = true
        }
    }
}

extension ArticleCardView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Open in New Window", image: UIImage(systemName: "square.split.2x1")) { _ in self.onOpenInNewWindow?() },
                UIAction(title: "Favorite", image: UIImage(systemName: "star")) { _ in self.onFavorite?() },
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = self.article.title },
                UIAction(title: "Close", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in self.onClose?() },
            ])
        }
    }
}
