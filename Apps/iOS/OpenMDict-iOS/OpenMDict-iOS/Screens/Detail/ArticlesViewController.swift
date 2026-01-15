//
//  ArticlesViewController.swift
//  OpenMDict-iOS
//
//  Multi-article browser for regular mode (iPad)
//  Passive View - receives data from Container, sends callbacks up
//

import UIKit
import WebKit

// MARK: - Layout Mode

enum ArticleLayoutMode: Int, CaseIterable {
    case columns = 0
    case grid = 1
    case list = 2
    
    var title: String {
        switch self {
        case .columns: return "Columns"
        case .grid: return "Grid"
        case .list: return "List"
        }
    }
    
    var icon: UIImage {
        switch self {
        case .columns: return UIImage(systemName: "rectangle.split.3x1")!
        case .grid: return UIImage(systemName: "square.grid.2x2")!
        case .list: return UIImage(systemName: "list.bullet")!
        }
    }
}

// MARK: - Delegate

protocol ArticlesViewControllerDelegate: AnyObject {
    func articlesViewController(_ vc: ArticlesViewController, didCloseArticle article: ArticleItem)
    func articlesViewController(_ vc: ArticlesViewController, didSelectArticle article: ArticleItem)
    func articlesViewController(_ vc: ArticlesViewController, didRequestFocusOn article: ArticleItem)
}

// MARK: - Articles View Controller

class ArticlesViewController: UIViewController {
    
    weak var delegate: ArticlesViewControllerDelegate?
    
    // MARK: - Internal State (view-rendering only, not source of truth)
    
    private var articles: [ArticleItem] = []
    private var layoutMode: ArticleLayoutMode = .columns
    
    // MARK: - Collection View
    
    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: createLayout(for: layoutMode))
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .systemGroupedBackground
        cv.delegate = self
        return cv
    }()
    
    private var pageControl: UIPageControl?
     
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
        
        // Initialize paging for default mode
        collectionView.isPagingEnabled = (layoutMode == .list)
        
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
        collectionView.dragDelegate = self
        collectionView.dragInteractionEnabled = true
        
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
            cell.onBookmarkToggle = { isBookmarked in
                print("🔖 Bookmark: \(article.title): \(isBookmarked)")
                // TODO: Implement bookmark persistence
            }
        }
        
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, article in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: article)
        }
        
        // Page control on the left side for list mode on iOS/iPadOS 16+
        if #available(iOS 16.0, *) {
            let pc = UIPageControl()
            pc.translatesAutoresizingMaskIntoConstraints = false
            pc.currentPageIndicatorTintColor = .label
            pc.pageIndicatorTintColor = .tertiaryLabel
            pc.isUserInteractionEnabled = true
            pc.addTarget(self, action: #selector(pageControlTapped(_:)), for: .valueChanged)
            pc.direction = .topToBottom
            pc.backgroundStyle = .minimal
            view.addSubview(pc)
            NSLayoutConstraint.activate([
                pc.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
                pc.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                pc.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                pc.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 8),
            ])
            pc.isHidden = true
            pageControl = pc
        }
    }
    
    // MARK: - Public API (called by Container)
    
    func configure(articles: [ArticleItem], animated: Bool) {
        self.articles = articles
        applySnapshot(animated: animated)
        updateEmptyState()
        
        // Update page control
        pageControl?.numberOfPages = articles.count
    }
    
    func applyLayout(_ mode: ArticleLayoutMode, animated: Bool) {
        let oldMode = self.layoutMode
        self.layoutMode = mode
        
        // List mode uses paging behavior
        collectionView.isPagingEnabled = (mode == .list)
        
        // Check if scroll direction changed (columns ↔ grid/list)
        let oldIsHorizontal = (oldMode == .columns)
        let newIsHorizontal = (mode == .columns)
        let scrollDirectionChanged = (oldIsHorizontal != newIsHorizontal)
        
        if scrollDirectionChanged {
            // Must recreate layout when scrollDirection changes
            let newLayout = createLayout(for: mode)
            collectionView.setCollectionViewLayout(newLayout, animated: animated)
        } else {
            // Same scroll direction - just invalidate
            collectionView.collectionViewLayout.invalidateLayout()
            
            if animated {
                if #available(iOS 17, *) {
                    // iOS 17+: native animation via reconfigureItems
                } else {
                    // iOS 15-16: manual animation wrapper
                    UIView.animate(withDuration: 0.3) {
                        self.collectionView.layoutIfNeeded()
                    }
                }
            }
        }
        
        // Reconfigure cells for new layout mode
        if !articles.isEmpty {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(articles)
            dataSource.apply(snapshot, animatingDifferences: animated && !scrollDirectionChanged)
        }
        
        // Show page control under List layout
        if let pc = pageControl {
            pc.isHidden = (mode != .list)
            if mode == .list {
                pc.numberOfPages = articles.count
                pc.currentPage = 0
            }
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
    
    private func createLayout(for mode: ArticleLayoutMode) -> UICollectionViewLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        
        // Columns mode: entire collectionView scrolls horizontally
        // Grid/List modes: collectionView scrolls vertically
        configuration.scrollDirection = (mode == .columns) ? .horizontal : .vertical
        
        return UICollectionViewCompositionalLayout(
            sectionProvider: { [weak self] sectionIndex, environment in
                guard let self = self else { return nil }
                
                switch self.layoutMode {
                case .grid: return self.createGridSection(environment: environment)
                case .list: return self.createListSection(environment: environment)
                case .columns: return self.createColumnsSection(environment: environment)
                }
            },
            configuration: configuration
        )
    }

    private func createGridSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        // Calculate columns based on container width
        let containerWidth = environment.container.effectiveContentSize.width
        let columnCount = max(2, Int(floor(containerWidth / 320)))
        let itemFraction = 1.0 / CGFloat(columnCount)
        
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(itemFraction),
            heightDimension: .fractionalWidth(itemFraction)  // Square cells
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalWidth(itemFraction)
        )
        
        // Use subitems array with explicit count - NOT subitem:count:
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            subitems: Array(repeating: item, count: columnCount)
        )
        
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        
        return section
    }

    private func createListSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        // Each item takes fills all space after a top margin to avoiding conflicting with navigation bar
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 72, leading: 0, bottom: 16, trailing: 0)
        
        // Group height equals container to ensure full-height paging
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        let leadingMargin: CGFloat = if #available(iOS 16, *) { 12 } else { 0 }
        group.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: leadingMargin, bottom: 0, trailing: 0)
        
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        
        return section
    }

    private func createColumnsSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        // With horizontal scrollDirection, cells fill the full height
        // and scroll horizontally across the screen
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let bottomMargin: CGFloat =
            if #available(iOS 26, *) {
                0
            } else if #available(iOS 16, *) {
                16
            } else {
                0
            }
    
        item.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 0, bottom: bottomMargin, trailing: 0)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute(400),
            heightDimension: .fractionalHeight(1.0)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        section.interGroupSpacing = 16

        return section
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
    
    @objc private func pageControlTapped(_ sender: UIPageControl) {
        guard layoutMode == .list else { return }
        let indexPath = IndexPath(item: sender.currentPage, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
    }
}

// MARK: - UICollectionViewDelegate

extension ArticlesViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let article = dataSource.itemIdentifier(for: indexPath) else { return }
        if layoutMode == .grid {
            delegate?.articlesViewController(self, didRequestFocusOn: article)
        } else {
            delegate?.articlesViewController(self, didSelectArticle: article)
        }
    }
    
    // MARK: - Scroll handling for List pager mode

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateWebViewInteractivity()
        updatePageControlIndex()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateWebViewInteractivity()
            updatePageControlIndex()
        }
    }

    private func updateWebViewInteractivity() {
        guard layoutMode == .list else { return }

        // Find the "current" cell (most visible)
        let visibleCells = collectionView.visibleCells.compactMap { $0 as? ArticleCell }
        let centerY = collectionView.bounds.midY + collectionView.contentOffset.y

        for cell in visibleCells {
            let cellCenterY = cell.frame.midY
            let isCurrent = abs(cellCenterY - centerY) < cell.frame.height / 2
            cell.setWebViewInteractive(isCurrent)
        }
    }
    
    private func updatePageControlIndex() {
        guard let pc = pageControl else { return }
        guard layoutMode == .list, !articles.isEmpty else { return }
        
        let pageHeight = collectionView.bounds.height
        let currentPage = Int(round(collectionView.contentOffset.y / pageHeight))
        pc.currentPage = min(max(0, currentPage), articles.count - 1)
    }
    
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let article = dataSource.itemIdentifier(for: indexPath) else { return nil }

        return UIContextMenuConfiguration(
            identifier: indexPath as NSCopying,
            previewProvider: {
                return ArticlePreviewViewController(article: article)     
            },
            actionProvider: { [weak self] _ in
                guard let self = self else { return nil }
                return UIMenu(children: [
                    UIAction(title: "Open in New Window", image: UIImage(systemName: "rectangle.badge.plus")) { _ in
                        SceneDelegate.openNewWindow(for: article)
                    },
                    UIAction(title: "Bookmark", image: UIImage(systemName: "bookmark")) { _ in
                        print("🔖 Bookmark: \(article.title)")
                        // TODO: Implement bookmark persistence
                    },
                    UIAction(title: "Close", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
                        self.delegate?.articlesViewController(self, didCloseArticle: article)
                    },
                ])
            }
        )
    }
    
    func collectionView(_ collectionView: UICollectionView,
                        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionAnimating?) {
        animator?.addCompletion { [weak self] in
            guard let self = self else { return }
            for cell in self.collectionView.visibleCells {
                if let articleCell = cell as? ArticleCell {
                    articleCell.forceReloadWebView()
                }
            }
        }
    }
}

// MARK: - UICollectionViewDragDelegate

extension ArticlesViewController: UICollectionViewDragDelegate {
    func collectionView(_ collectionView: UICollectionView,
                        itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard let article = dataSource.itemIdentifier(for: indexPath) else { return [] }
        
        let itemProvider = NSItemProvider(object: article.userActivity)
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = article
        return [dragItem]
    }
}
