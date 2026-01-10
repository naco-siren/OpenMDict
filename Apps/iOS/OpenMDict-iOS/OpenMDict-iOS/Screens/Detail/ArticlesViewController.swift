//
//  ArticlesViewController.swift
//  OpenMDict-iOS
//
//  Multi-article browser for regular mode (iPad)
//  Passive View - receives data from Container, sends callbacks up
//

import UIKit

// MARK: - Layout Mode

enum ArticleLayoutMode: Int, CaseIterable {
    case grid = 0
    case list = 1
    case columns = 2
    
    var title: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        case .columns: return "Columns"
        }
    }
    
    var icon: UIImage {
        switch self {
        case .grid: return UIImage(systemName: "square.grid.2x2")!
        case .list: return UIImage(systemName: "list.bullet")!
        case .columns: return UIImage(systemName: "rectangle.split.3x1")!
        }
    }
}

// MARK: - Delegate

protocol ArticlesViewControllerDelegate: AnyObject {
    func articlesViewController(_ vc: ArticlesViewController, didCloseArticle article: ArticleItem)
    func articlesViewController(_ vc: ArticlesViewController, didSelectArticle article: ArticleItem)
}

// MARK: - Articles View Controller

class ArticlesViewController: UIViewController {
    
    weak var delegate: ArticlesViewControllerDelegate?
    
    // MARK: - Internal State (view-rendering only, not source of truth)
    
    private var articles: [ArticleItem] = []
    private var layoutMode: ArticleLayoutMode = .columns
    
    // MARK: - Collection View
    
    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: makeLayout(for: layoutMode))
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .systemGroupedBackground
        cv.delegate = self
        return cv
    }()
     
    private var dataSource: UICollectionViewDiffableDataSource<Int, ArticleItem>!
    
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
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        // Cell registration
        let cellReg = UICollectionView.CellRegistration<ArticleCell, ArticleItem> { [weak self] cell, indexPath, article in
            cell.configure(with: article, layoutMode: self?.layoutMode ?? .columns)
            cell.onClose = { [weak self] in
                guard let self = self else { return }
                self.delegate?.articlesViewController(self, didCloseArticle: article)
            }
            cell.onOpenInNewWindow = { SceneDelegate.openNewWindow(for: article) }
        }
        
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, article in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: article)
        }
    }
    
    // MARK: - Public API (called by Container)
    
    func configure(articles: [ArticleItem], animated: Bool) {
        self.articles = articles
        applySnapshot(animated: animated)
        updateEmptyState()
    }
    
    func applyLayout(_ mode: ArticleLayoutMode, animated: Bool) {
        self.layoutMode = mode
        let newLayout = makeLayout(for: mode)
        collectionView.setCollectionViewLayout(newLayout, animated: animated)
        
        // Reconfigure visible cells for new layout
        if animated {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(articles)
            dataSource.apply(snapshot, animatingDifferences: true)
        }
    }
    
    func scrollToArticle(_ article: ArticleItem, animated: Bool) {
        guard let index = articles.firstIndex(of: article),
              dataSource.snapshot().numberOfItems > 0 else { return }
        
        let indexPath = IndexPath(item: index, section: 0)
        let scrollPosition: UICollectionView.ScrollPosition = switch layoutMode {
        case .columns: .centeredHorizontally
        case .grid, .list: .centeredVertically
        }
        collectionView.scrollToItem(at: indexPath, at: scrollPosition, animated: animated)
    }
    
    // MARK: - Layouts
    
    private func makeLayout(for mode: ArticleLayoutMode) -> UICollectionViewLayout {
        switch mode {
        case .grid: return makeGridLayout()
        case .list: return makeListLayout()
        case .columns: return makeColumnsLayout()
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
            guard let self = self,
                  let article = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
            let closeAction = UIContextualAction(style: .destructive, title: "Close") { _, _, completion in
                self.delegate?.articlesViewController(self, didCloseArticle: article)
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
    
    // MARK: - Private
    
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
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let article = dataSource.itemIdentifier(for: indexPath) else { return }
        delegate?.articlesViewController(self, didSelectArticle: article)
    }
    
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let article = dataSource.itemIdentifier(for: indexPath) else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            return UIMenu(children: [
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
                    self.delegate?.articlesViewController(self, didCloseArticle: article)
                },
            ])
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
