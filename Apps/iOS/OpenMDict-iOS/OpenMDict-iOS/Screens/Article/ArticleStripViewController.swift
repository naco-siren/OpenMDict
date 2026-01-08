//
//  ArticleStripViewController.swift
//  OpenMDict-iOS
//
//  Secondary column: Safari-style tab bar + content view
//
//  Architecture:
//  ┌─────────────────────────────────────┐
//  │  Tab Bar (UICollectionView)         │  ← horizontal scrolling tabs
//  ├─────────────────────────────────────┤
//  │                                     │
//  │  Content View                       │  ← current article only
//  │  (ArticleContentView)               │
//  │                                     │
//  └─────────────────────────────────────┘
//  (Toolbar provided by UINavigationController)
//

import UIKit

class ArticleStripViewController: UIViewController {
    
    // MARK: - State
    
    private(set) var articles: [ArticleItem] = []
    private var selectedIndex: Int = 0
    
    var currentArticle: ArticleItem? {
        guard selectedIndex >= 0, selectedIndex < articles.count else { return nil }
        return articles[selectedIndex]
    }
    
    // MARK: - UI Components
    
    private lazy var tabBarCollectionView: UICollectionView = {
        // Use simple flow layout for horizontal scrolling
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 1
        layout.minimumLineSpacing = 1
        layout.estimatedItemSize = CGSize(width: 160, height: 52)
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .secondarySystemBackground
        cv.showsHorizontalScrollIndicator = false
        cv.showsVerticalScrollIndicator = false
        cv.alwaysBounceHorizontal = true
        cv.alwaysBounceVertical = false
        cv.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        cv.delegate = self
        cv.dataSource = self
        cv.dragDelegate = self
        cv.dropDelegate = self
        cv.dragInteractionEnabled = true
        cv.register(TabCell.self, forCellWithReuseIdentifier: TabCell.reuseId)
        return cv
    }()
    
    private lazy var contentContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()
    
    private var currentContentView: ArticleContentView?
    
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
        
        // Tab bar at top
        view.addSubview(tabBarCollectionView)
        NSLayoutConstraint.activate([
            tabBarCollectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabBarCollectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarCollectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarCollectionView.heightAnchor.constraint(equalToConstant: 52),
        ])
        
        // Content below tab bar
        view.addSubview(contentContainerView)
        NSLayoutConstraint.activate([
            contentContainerView.topAnchor.constraint(equalTo: tabBarCollectionView.bottomAnchor),
            contentContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }
    
    // MARK: - Public API
    
    func preloadArticle(_ article: ArticleItem) {
        articles.insert(article, at: 0)
        selectedIndex = 0
    }
    
    func pushArticle(_ article: ArticleItem, animated: Bool) {
        // Check if already exists
        if let existingIndex = articles.firstIndex(where: { $0.id == article.id }) {
            selectTab(at: existingIndex, animated: animated)
            return
        }
        
        // Insert at front
        articles.insert(article, at: 0)
        selectedIndex = 0
        
        tabBarCollectionView.reloadData()
        
        // Scroll tab bar to show new tab
        if animated && !articles.isEmpty {
            tabBarCollectionView.scrollToItem(
                at: IndexPath(item: 0, section: 0),
                at: .left,
                animated: true
            )
        }
        
        updateContentView(animated: animated)
        updateEmptyState()
        updateToolbar()
    }
    
    func closeArticle(at index: Int, animated: Bool = true) {
        guard index >= 0, index < articles.count else { return }
        
        articles.remove(at: index)
        
        // Adjust selected index
        if articles.isEmpty {
            selectedIndex = 0
        } else if selectedIndex >= articles.count {
            selectedIndex = articles.count - 1
        } else if index < selectedIndex {
            selectedIndex -= 1
        } else if index == selectedIndex {
            selectedIndex = min(selectedIndex, articles.count - 1)
        }
        
        tabBarCollectionView.reloadData()
        updateContentView(animated: animated)
        updateEmptyState()
        updateToolbar()
    }
    
    func moveTab(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex != destIndex,
              sourceIndex >= 0, sourceIndex < articles.count,
              destIndex >= 0, destIndex < articles.count else {
            return
        }
        
        let article = articles.remove(at: sourceIndex)
        articles.insert(article, at: destIndex)
        
        // Update selected index
        if selectedIndex == sourceIndex {
            selectedIndex = destIndex
        } else if sourceIndex < selectedIndex && destIndex >= selectedIndex {
            selectedIndex -= 1
        } else if sourceIndex > selectedIndex && destIndex <= selectedIndex {
            selectedIndex += 1
        }
        
        tabBarCollectionView.reloadData()
    }
    
    // MARK: - Private
    
    private func selectTab(at index: Int, animated: Bool) {
        guard index >= 0, index < articles.count else { return }
        
        let oldIndex = selectedIndex
        selectedIndex = index
        
        // Update tab bar selection
        var indexPathsToReload = [IndexPath(item: index, section: 0)]
        if oldIndex != index && oldIndex < articles.count {
            indexPathsToReload.append(IndexPath(item: oldIndex, section: 0))
        }
        tabBarCollectionView.reloadItems(at: indexPathsToReload)
        
        // Scroll to visible
        tabBarCollectionView.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: .centeredHorizontally,
            animated: animated
        )
        
        updateContentView(animated: animated)
        updateToolbar()
    }
    
    private func updateContentView(animated: Bool) {
        let oldView = currentContentView
        
        guard let article = currentArticle else {
            oldView?.removeFromSuperview()
            currentContentView = nil
            return
        }
        
        let newView = ArticleContentView(article: article)
        newView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(newView)
        
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            newView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            newView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
        ])
        
        if animated, let old = oldView {
            newView.alpha = 0
            UIView.animate(withDuration: 0.2) {
                newView.alpha = 1
                old.alpha = 0
            } completion: { _ in
                old.removeFromSuperview()
            }
        } else {
            oldView?.removeFromSuperview()
        }
        
        currentContentView = newView
    }
    
    private func updateToolbar() {
        guard let article = currentArticle else {
            toolbarItems = []
            return
        }
        
        // Article-specific actions (left side)
        let favoriteItem = UIBarButtonItem(
            image: UIImage(systemName: "star"),
            style: .plain,
            target: self,
            action: #selector(favoriteTapped)
        )
        favoriteItem.accessibilityLabel = "Add to Favorites"
        
        let speakItem = UIBarButtonItem(
            image: UIImage(systemName: "speaker.wave.2"),
            style: .plain,
            target: self,
            action: #selector(speakTapped)
        )
        speakItem.accessibilityLabel = "Speak"
        
        let copyItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copyTapped)
        )
        copyItem.accessibilityLabel = "Copy"
        
        let flex = UIBarButtonItem(systemItem: .flexibleSpace)
        
        // Global actions (right side)
        let zoomMenu = UIMenu(title: "Zoom", children: [
            UIAction(title: "Zoom In", image: UIImage(systemName: "plus.magnifyingglass")) { [weak self] _ in
                self?.zoomIn()
            },
            UIAction(title: "Zoom Out", image: UIImage(systemName: "minus.magnifyingglass")) { [weak self] _ in
                self?.zoomOut()
            },
            UIAction(title: "Reset", image: UIImage(systemName: "1.magnifyingglass")) { [weak self] _ in
                self?.zoomReset()
            },
        ])
        let zoomItem = UIBarButtonItem(image: UIImage(systemName: "textformat.size"), menu: zoomMenu)
        
        let newWindowItem = UIBarButtonItem(
            image: UIImage(systemName: "square.split.2x1"),
            style: .plain,
            target: self,
            action: #selector(openInNewWindowTapped)
        )
        newWindowItem.accessibilityLabel = "Open in New Window"
        
        toolbarItems = [favoriteItem, speakItem, copyItem, flex, zoomItem, newWindowItem]
    }
    
    // MARK: - Toolbar Actions
    
    @objc private func favoriteTapped() {
        guard let article = currentArticle else { return }
        print("Favorite: \(article.title)")
        // TODO: Add to favorites
    }
    
    @objc private func speakTapped() {
        guard let article = currentArticle else { return }
        print("Speak: \(article.title)")
        // TODO: Text-to-speech
    }
    
    @objc private func copyTapped() {
        guard let article = currentArticle else { return }
        UIPasteboard.general.string = article.title
    }
    
    @objc private func openInNewWindowTapped() {
        guard let article = currentArticle else { return }
        SceneDelegate.openNewWindow(for: article)
    }
    
    private func zoomIn() { print("Zoom in") }
    private func zoomOut() { print("Zoom out") }
    private func zoomReset() { print("Zoom reset") }
    
    private func updateEmptyState() {
        let isEmpty = articles.isEmpty
        emptyView.isHidden = !isEmpty
        tabBarCollectionView.isHidden = isEmpty
        contentContainerView.isHidden = isEmpty
        navigationController?.setToolbarHidden(isEmpty, animated: true)
    }
}

// MARK: - UICollectionViewDataSource

extension ArticleStripViewController: UICollectionViewDataSource {
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        articles.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabCell.reuseId, for: indexPath) as! TabCell
        let article = articles[indexPath.item]
        let isSelected = indexPath.item == selectedIndex
        cell.configure(with: article, isSelected: isSelected)
        cell.onClose = { [weak self] in
            self?.closeArticle(at: indexPath.item, animated: true)
        }
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension ArticleStripViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectTab(at: indexPath.item, animated: true)
    }
    
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        let article = articles[indexPath.item]
        
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let newWindow = UIAction(title: "Open in New Window", image: UIImage(systemName: "square.split.2x1")) { _ in
                SceneDelegate.openNewWindow(for: article)
            }
            
            let close = UIAction(title: "Close", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
                self?.closeArticle(at: indexPath.item, animated: true)
            }
            
            let closeOthers = UIAction(title: "Close Others", image: UIImage(systemName: "xmark.square")) { _ in
                self?.closeAllExcept(indexPath.item)
            }
            
            return UIMenu(children: [newWindow, close, closeOthers])
        }
    }
    
    private func closeAllExcept(_ keepIndex: Int) {
        guard keepIndex >= 0, keepIndex < articles.count else { return }
        let keeper = articles[keepIndex]
        articles = [keeper]
        selectedIndex = 0
        tabBarCollectionView.reloadData()
        updateContentView(animated: true)
    }
}

// MARK: - UICollectionViewDragDelegate

extension ArticleStripViewController: UICollectionViewDragDelegate {
    
    func collectionView(_ collectionView: UICollectionView,
                        itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        let article = articles[indexPath.item]
        let itemProvider = NSItemProvider(object: article.title as NSString)
        
        // Register NSUserActivity for cross-window drag
        itemProvider.registerObject(article.userActivity, visibility: .all)
        
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = indexPath.item
        return [dragItem]
    }
    
    func collectionView(_ collectionView: UICollectionView,
                        dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? TabCell else { return nil }
        
        let params = UIDragPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 8)
        return params
    }
}

// MARK: - UICollectionViewDropDelegate

extension ArticleStripViewController: UICollectionViewDropDelegate {
    
    func collectionView(_ collectionView: UICollectionView,
                        dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        if session.localDragSession != nil {
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        return UICollectionViewDropProposal(operation: .forbidden)
    }
    
    func collectionView(_ collectionView: UICollectionView,
                        performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let item = coordinator.items.first,
              let sourceIndex = item.dragItem.localObject as? Int,
              let destIndexPath = coordinator.destinationIndexPath else {
            return
        }
        
        let destIndex = destIndexPath.item
        
        collectionView.performBatchUpdates {
            moveTab(from: sourceIndex, to: destIndex)
            collectionView.moveItem(
                at: IndexPath(item: sourceIndex, section: 0),
                to: destIndexPath
            )
        }
        
        coordinator.drop(item.dragItem, toItemAt: destIndexPath)
    }
}

// MARK: - Tab Cell

private class TabCell: UICollectionViewCell {
    
    static let reuseId = "TabCell"
    
    var onClose: (() -> Void)?
    private var isSelectedTab: Bool = false
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        return label
    }()
    
    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        return label
    }()
    
    private let closeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        btn.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        btn.tintColor = .secondaryLabel
        return btn
    }()
    
    private let labelStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }()
    
    private var closeButtonWidthConstraint: NSLayoutConstraint?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        contentView.layer.cornerRadius = 8
        contentView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        
        labelStack.addArrangedSubview(titleLabel)
        labelStack.addArrangedSubview(subtitleLabel)
        
        contentView.addSubview(closeButton)
        contentView.addSubview(labelStack)
        
        closeButtonWidthConstraint = closeButton.widthAnchor.constraint(equalToConstant: 24)
        
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            closeButtonWidthConstraint!,
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            
            labelStack.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            labelStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            labelStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    }
    
    @objc private func closeTapped() {
        onClose?()
    }
    
    func configure(with article: ArticleItem, isSelected: Bool) {
        self.isSelectedTab = isSelected
        
        titleLabel.text = article.title
        subtitleLabel.text = article.dictName
        
        // Only show close button when selected
        closeButton.isHidden = !isSelected
        closeButtonWidthConstraint?.constant = isSelected ? 24 : 0
        
        if isSelected {
            contentView.backgroundColor = .systemBackground
            titleLabel.textColor = .label
            subtitleLabel.textColor = .secondaryLabel
        } else {
            contentView.backgroundColor = .tertiarySystemBackground
            titleLabel.textColor = .secondaryLabel
            subtitleLabel.textColor = .tertiaryLabel
        }
    }
    
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attrs = super.preferredLayoutAttributesFitting(layoutAttributes)
        
        // Calculate width based on content
        let labelWidth = max(titleLabel.intrinsicContentSize.width, subtitleLabel.intrinsicContentSize.width)
        let closeWidth: CGFloat = isSelectedTab ? 28 : 0
        let padding: CGFloat = 20  // leading + trailing
        
        attrs.size.width = min(200, max(100, labelWidth + closeWidth + padding))
        attrs.size.height = 52
        
        return attrs
    }
}

// MARK: - Article Content View

private class ArticleContentView: UIView {
    
    let article: ArticleItem
    
    init(article: ArticleItem) {
        self.article = article
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        backgroundColor = article.color
        
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)
        
        let emojiLabel = UILabel()
        emojiLabel.text = "📖"
        emojiLabel.font = .systemFont(ofSize: 48)
        
        let titleLabel = UILabel()
        titleLabel.text = article.title
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textColor = .label
        
        let dictLabel = UILabel()
        dictLabel.text = article.dictName
        dictLabel.font = .preferredFont(forTextStyle: .subheadline)
        dictLabel.textColor = .secondaryLabel
        
        let placeholderLabel = UILabel()
        placeholderLabel.text = "(WKWebView with HTML content)"
        placeholderLabel.font = .preferredFont(forTextStyle: .caption1)
        placeholderLabel.textColor = .tertiaryLabel
        
        stack.addArrangedSubview(emojiLabel)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(dictLabel)
        stack.addArrangedSubview(placeholderLabel)
        
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
