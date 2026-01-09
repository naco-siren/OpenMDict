//
//  ArticlesViewController.swift
//  OpenMDict-iOS
//
//  Desktop-class article browser with switchable layouts (Grid/List/Columns)
//  Uses UICollectionView with animated layout transitions
//

import UIKit

// MARK: - Layout Mode

enum ArticleLayoutMode: Int, CaseIterable {
    case grid = 0
    case list = 1
    case columns = 2
    
    var icon: UIImage? {
        switch self {
        case .grid: return UIImage(systemName: "square.grid.2x2")
        case .list: return UIImage(systemName: "list.bullet")
        case .columns: return UIImage(systemName: "rectangle.split.3x1")
        }
    }
}

// MARK: - Article View Controller

class ArticlesViewController: UIViewController {
    
    private let maxArticles: Int = 10
    private(set) var articles: [ArticleItem] = []
    
    var currentArticle: ArticleItem? { articles.first }
    
    // MARK: - Layout State
    private var layoutMode: ArticleLayoutMode = .columns {
        didSet { applyLayout(animated: true) }
    }

    // MARK: - Collection View
    
    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: makeLayout(for: layoutMode))
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .systemGroupedBackground
        cv.delegate = self
        return cv
    }()
     
    private var dataSource: UICollectionViewDiffableDataSource<Int, ArticleItem>!

    // MARK: - Navigation Bar Controls

    private lazy var layoutSegment: UISegmentedControl = {
        let sc = UISegmentedControl(items: ArticleLayoutMode.allCases.map { $0.icon! })
        sc.selectedSegmentIndex = layoutMode.rawValue
        sc.addTarget(self, action: #selector(layoutChanged), for: .valueChanged)
        return sc
    }()
    
    private lazy var appearanceSegment: UISegmentedControl = {
        let sc = UISegmentedControl(items: [
            UIImage(systemName: "moon.fill")!,
            UIImage(systemName: "circle.lefthalf.filled")!,
            UIImage(systemName: "sun.max.fill")!
        ])
        sc.selectedSegmentIndex = 1  // Auto by default
        sc.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)
        return sc
    }()

    private lazy var fontSegment: UISegmentedControl = {
        let sc = UISegmentedControl(items: [
            UIImage(systemName: "textformat.size.smaller")!,
            UIImage(systemName: "textformat.size.larger")!
        ])
        sc.isMomentary = true  // Buttons, not toggle
        sc.addTarget(self, action: #selector(fontSegmentTapped), for: .valueChanged)
        return sc
    }()

    private lazy var searchController: UISearchController = {
        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
        sc.obscuresBackgroundDuringPresentation = false
        sc.searchBar.placeholder = "Search in articles..."
        sc.hidesNavigationBarDuringPresentation = false
        return sc
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
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemGroupedBackground
        setupCollectionView()
        setupNavigationBar()
        view.addSubview(emptyView)
        
        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateEmptyState()
    }
    
    // MARK: - Collection View Setup
    
    private func setupCollectionView() {
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        // Cell registration
        let cellReg = UICollectionView.CellRegistration<ArticleCell, ArticleItem> { [weak self] cell, indexPath, article in
            cell.configure(with: article, layoutMode: self?.layoutMode ?? .columns)
            cell.onClose = { [weak self] in self?.closeArticle(article) }
            cell.onOpenInNewWindow = { SceneDelegate.openNewWindow(for: article) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, article in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: article)
        }
    }

    // MARK: - Navigation Bar Setup

    private func setupNavigationBar() {
        navigationController?.setNavigationBarHidden(false, animated: false)
        
        let layoutItem = UIBarButtonItem(customView: layoutSegment)
        let appearanceItem = UIBarButtonItem(customView: appearanceSegment)
        let fontItem = UIBarButtonItem(customView: fontSegment)

        if #available(iOS 16.0, *) {
            // Desktop-class iPad: layout on left, reading controls in center
            navigationItem.style = .browser
            navigationItem.leftBarButtonItems = [layoutItem]
            navigationItem.centerItemGroups = [
                UIBarButtonItemGroup(barButtonItems: [appearanceItem, fontItem], representativeItem: nil)
            ]
        } else {
            // iOS 15 fallback: all on left
            navigationItem.leftBarButtonItems = [layoutItem, appearanceItem, fontItem]
        }
    
        // Right side: Search
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }
    
    // MARK: - Layouts
    private func makeLayout(for mode: ArticleLayoutMode) -> UICollectionViewLayout {
        switch mode {
        case .grid:
            return makeGridLayout()
        case .list:
            return makeListLayout()
        case .columns:
            return makeColumnsLayout()
        }
    }

    private func makeGridLayout() -> UICollectionViewCompositionalLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(0.5),
            heightDimension: .fractionalWidth(0.5)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalWidth(0.5)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        return UICollectionViewCompositionalLayout(section: section)
    }

    private func makeListLayout() -> UICollectionViewCompositionalLayout {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = true
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let article = self?.dataSource.itemIdentifier(for: indexPath) else { return nil }
            let closeAction = UIContextualAction(style: .destructive, title: "Close") { _, _, completion in
                self?.closeArticle(article)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [closeAction])
        }
        return UICollectionViewCompositionalLayout.list(using: config)
    }

    private func makeColumnsLayout() -> UICollectionViewCompositionalLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(400),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute(400),
            heightDimension: .fractionalHeight(1.0)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)

        return UICollectionViewCompositionalLayout(section: section)
    }

    private func applyLayout(animated: Bool) {
        let newLayout = makeLayout(for: layoutMode)
        collectionView.setCollectionViewLayout(newLayout, animated: animated)
    }
    
    // MARK: - Navigation Bar Actions

    @objc private func layoutChanged(_ sender: UISegmentedControl) {
        guard let mode = ArticleLayoutMode(rawValue: sender.selectedSegmentIndex) else { return }
        layoutMode = mode
    }
    
    @objc private func appearanceChanged(_ sender: UISegmentedControl) {
        let style: UIUserInterfaceStyle = switch sender.selectedSegmentIndex {
            case 0: .dark
            case 2: .light
            default: .unspecified
        }
        view.window?.overrideUserInterfaceStyle = style
    }

    @objc private func fontSegmentTapped(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 0:
            print("📉 Decrease font size - TODO")
        case 1:
            print("📈 Increase font size - TODO")
        default:
            break
        }
    }
    
    func preloadArticle(_ article: ArticleItem) {
        articles.insert(article, at: 0)
    }
    
    func pushArticle(_ article: ArticleItem, animated: Bool) {
        if let index = articles.firstIndex(of: article) {
            // Scroll to existing article
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: animated)
            return
        }
        
        // Insert new article at front
        articles.insert(article, at: 0)
        trimExcessArticles()
        applySnapshot(animated: animated)
        updateEmptyState()
    }
    
    func closeArticle(_ article: ArticleItem, animated: Bool = true) {
        guard let index = articles.firstIndex(of: article) else { return }
        articles.remove(at: index)
        applySnapshot(animated: animated)
        updateEmptyState()
    }
    
    private func trimExcessArticles() {
        while articles.count > maxArticles {
            articles.removeLast()
        }
    }
    
    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ArticleItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(articles)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }
    
    private func updateEmptyState() {
        emptyView.isHidden = !articles.isEmpty
        collectionView.isHidden = articles.isEmpty
    }
}

// MARK: - UICollectionViewDelegate

extension ArticlesViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let article = dataSource.itemIdentifier(for: indexPath) else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Open in New Window", image: UIImage(systemName: "square.split.2x1")) { _ in
                    SceneDelegate.openNewWindow(for: article)
                },
                UIAction(title: "Favorite", image: UIImage(systemName: "star")) { _ in
                    print("⭐ Favorite: \(article.title)")
                },
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = article.title
                },
                UIAction(title: "Close", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
                    self?.closeArticle(article)
                },
            ])
        }
    }
}

// MARK: - UISearchResultsUpdating

extension ArticlesViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        if !query.isEmpty {
            print("🔍 Search: \(query) - TODO")
        }
    }
}

// MARK: - Article Cell

class ArticleCell: UICollectionViewCell {
    var onClose: (() -> Void)?
    var onOpenInNewWindow: (() -> Void)?

    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let contentLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 12
        containerView.layer.masksToBounds = true
        contentView.addSubview(containerView)
        
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        
        contentLabel.numberOfLines = 0
        contentLabel.textAlignment = .center
        contentLabel.textColor = .secondaryLabel
        
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        
        [titleLabel, subtitleLabel, contentLabel, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            
            closeButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),
            
            contentLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            contentLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            contentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor, constant: 16),
        ])
    }

    func configure(with article: ArticleItem, layoutMode: ArticleLayoutMode) {
            containerView.backgroundColor = article.color
            titleLabel.text = article.title
            subtitleLabel.text = article.dictName
            contentLabel.text = "📖\n\n\(article.title)\n\n(WKWebView)"
    
            // Adjust visibility based on layout
            let isCompact = layoutMode == .list
            contentLabel.isHidden = isCompact
            closeButton.isHidden = isCompact
    }
    
    @objc private func closeTapped() { onClose?() }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        onClose = nil
        onOpenInNewWindow = nil
    }
}
