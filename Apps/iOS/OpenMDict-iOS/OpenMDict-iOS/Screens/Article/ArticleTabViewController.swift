//
//  ArticleTabViewController.swift
//  OpenMDict-iOS
//
//  Single article tab within the strip
//
//  Features:
//  - Colored background (prototype visualization)
//  - Header with title and close button
//  - Drag interaction for reorder & new window
//  - Context menu
//

import UIKit

class ArticleTabViewController: UIViewController {
    
    // MARK: - Data
    
    let article: ArticleItem
    
    // MARK: - Callbacks
    
    var onClose: (() -> Void)?
    var onOpenInNewWindow: (() -> Void)?
    
    // MARK: - UI
    
    private var widthConstraint: NSLayoutConstraint?
    
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
    
    private lazy var dictLabel: UILabel = {
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
    
    private lazy var contentLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.text = """
        📖 Article Preview
        
        Word: \(article.title)
        Dictionary: \(article.dictName)
        
        (In real app, this would be
        a WKWebView with HTML content)
        """
        return label
    }()
    
    // MARK: - Initialization
    
    init(article: ArticleItem) {
        self.article = article
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupInteractions()
    }
    
    private func setupUI() {
        view.backgroundColor = .clear
        
        view.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        
        containerView.addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 50),
        ])
        
        headerView.addSubview(titleLabel)
        headerView.addSubview(dictLabel)
        headerView.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            
            dictLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dictLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            dictLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        
        containerView.addSubview(contentLabel)
        NSLayoutConstraint.activate([
            contentLabel.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 20),
            contentLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            contentLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
        ])
    }
    
    private func setupInteractions() {
        let contextMenu = UIContextMenuInteraction(delegate: self)
        containerView.addInteraction(contextMenu)
        
        let dragInteraction = UIDragInteraction(delegate: self)
        dragInteraction.isEnabled = true
        containerView.addInteraction(dragInteraction)
        
        let dropInteraction = UIDropInteraction(delegate: self)
        containerView.addInteraction(dropInteraction)
    }
    
    // MARK: - Actions
    
    @objc private func closeTapped() {
        onClose?()
    }
    
    // MARK: - Width Update
    
    func updateWidth(_ width: CGFloat) {
        if let constraint = widthConstraint {
            constraint.constant = width
        } else {
            widthConstraint = view.widthAnchor.constraint(equalToConstant: width)
            widthConstraint?.isActive = true
        }
    }
}

// MARK: - UIContextMenuInteractionDelegate

extension ArticleTabViewController: UIContextMenuInteractionDelegate {
    
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            
            let openNewWindow = UIAction(
                title: "Open in New Window",
                image: UIImage(systemName: "square.split.2x1")
            ) { _ in
                self?.onOpenInNewWindow?()
            }
            
            let copyTitle = UIAction(
                title: "Copy Word",
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                UIPasteboard.general.string = self?.article.title
            }
            
            let close = UIAction(
                title: "Close",
                image: UIImage(systemName: "xmark"),
                attributes: .destructive
            ) { _ in
                self?.onClose?()
            }
            
            return UIMenu(children: [openNewWindow, copyTitle, close])
        }
    }
}

// MARK: - UIDragInteractionDelegate

extension ArticleTabViewController: UIDragInteractionDelegate {
    
    func dragInteraction(
        _ interaction: UIDragInteraction,
        itemsForBeginning session: UIDragSession
    ) -> [UIDragItem] {
        
        let itemProvider = NSItemProvider(object: article.title as NSString)
        
        let activity = article.userActivity
        itemProvider.registerObject(activity, visibility: .all)
        
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = article
        
        return [dragItem]
    }
    
    func dragInteraction(
        _ interaction: UIDragInteraction,
        previewForLifting item: UIDragItem,
        session: UIDragSession
    ) -> UITargetedDragPreview? {
        
        let params = UIDragPreviewParameters()
        params.backgroundColor = .clear
        return UITargetedDragPreview(view: containerView, parameters: params)
    }
    
    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionAllowsMoveOperation session: UIDragSession
    ) -> Bool {
        true
    }
}

// MARK: - UIDropInteractionDelegate

extension ArticleTabViewController: UIDropInteractionDelegate {
    
    func dropInteraction(
        _ interaction: UIDropInteraction,
        canHandle session: UIDropSession
    ) -> Bool {
        session.localDragSession != nil && session.canLoadObjects(ofClass: NSString.self)
    }
    
    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: session.localDragSession != nil ? .move : .copy)
    }
    
    func dropInteraction(
        _ interaction: UIDropInteraction,
        performDrop session: UIDropSession
    ) {
        guard let draggedArticle = session.localDragSession?.items.first?.localObject as? ArticleItem,
              let stripVC = parent as? ArticleStripViewController else {
            return
        }
        
        let sourceIndex = stripVC.articles.firstIndex(of: draggedArticle)
        let destIndex = stripVC.articles.firstIndex(of: article)
        
        if let source = sourceIndex, let dest = destIndex {
            stripVC.moveTab(from: source, to: dest)
        }
    }
}
