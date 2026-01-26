//
//  ArticlesViewController.swift
//  OpenMDict-iOS
//
//  Multi-article browser for regular mode (iPad)
//  Passive View - receives data from Container, sends callbacks up
//

import UIKit
import WebKit

// MARK: - Delegate

protocol ArticlesViewControllerDelegate: AnyObject {
    func articlesViewController(_ vc: ArticlesViewController, didCloseArticle article: ArticleDisplayItem)
    func articlesViewController(_ vc: ArticlesViewController, didSelectArticle article: ArticleDisplayItem)
    func articlesViewController(_ vc: ArticlesViewController, didRequestFocusOn article: ArticleDisplayItem)
}

// MARK: - Articles View Controller

class ArticlesViewController: UIViewController {
    
    private let instanceID = UUID().uuidString.prefix(8)
    
    private var lastKnownSafeAreaTop: CGFloat = -1

    weak var delegate: ArticlesViewControllerDelegate?
    
    /// Delegate for handling entry:// links from cells
    weak var cellDelegate: ArticleCellDelegate?
    
    // MARK: - Internal State (view-rendering only, not source of truth)
    
    private var articles: [ArticleDisplayItem] = []
    private var layoutMode: ArticleLayoutMode = .columns
    private var zoomLevel: Int = ZoomLevel.defaultLevel
    
    // Track cell that needs to present find after context menu dismisses
    private var pendingFindIndexPath: IndexPath?
    
    // MARK: - Collection View
    
    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: createLayout(for: layoutMode))
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.contentInsetAdjustmentBehavior = .never
        cv.backgroundColor = .systemGroupedBackground
        cv.delegate = self
        return cv
    }()
    
    private var pageControl: UIPageControl?
     
    private var dataSource: UICollectionViewDiffableDataSource<Int, ArticleDisplayItem>!
    
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
    
    /// Get effective safe area, falling back to parent's safe area if ours is 0.
    /// This handles the edge case where child VC is created during trait transition
    /// and its safe area never propagates from parent.
    private var effectiveSafeAreaTop: CGFloat {
        let myTop = view.safeAreaInsets.top
        if myTop > 0 { return myTop }
        // Fallback to parent's safe area
        let parentTop = parent?.view.safeAreaInsets.top ?? 0
        return parentTop
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        debugLog("📐 [\(instanceID)] ArticlesVC.viewDidLoad - safeArea: \(view.safeAreaInsets), frame: \(view.frame)")
        
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
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        debugLog("📐 [\(instanceID)] ArticlesVC.viewWillAppear - safeArea: \(view.safeAreaInsets), view.frame: \(view.frame), cv.frame: \(collectionView.frame)")
        debugLog("📐 [\(instanceID)] ArticlesVC.viewWillAppear - contentInsetAdjustmentBehavior: \(collectionView.contentInsetAdjustmentBehavior.rawValue)")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        debugLog("📐 [\(instanceID)] ArticlesVC.viewDidAppear - safeArea: \(view.safeAreaInsets), view.frame: \(view.frame), cv.frame: \(collectionView.frame)")
        debugLog("📐 [\(instanceID)] ArticlesVC.viewDidAppear - cv.contentInset: \(collectionView.contentInset), cv.adjustedContentInset: \(collectionView.adjustedContentInset)")
        debugLog("📐 [\(instanceID)] ArticlesVC.viewDidAppear - cv.contentInsetAdjustmentBehavior: \(collectionView.contentInsetAdjustmentBehavior.rawValue)")
        // Log first visible cell position if any
        if let firstCell = collectionView.visibleCells.first {
            debugLog("📐 [\(instanceID)] ArticlesVC.viewDidAppear - firstCell.frame: \(firstCell.frame)")
        }
        
        // Final safety check: if safe area is still 0 but we're in a nav controller, force layout rebuild
        // This handles edge cases where safe area propagation is delayed during trait transitions
        if view.safeAreaInsets.top == 0 && parent?.navigationController != nil {
            DispatchQueue.main.async { [weak self] in
                self?.checkAndFixSafeAreaLayout()
            }
        }
    }
    
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        debugLog("📐 [\(instanceID)] ArticlesVC.viewSafeAreaInsetsDidChange - safeArea: \(view.safeAreaInsets)")
        
        // Force layout recalculation when safe area changes
        collectionView.collectionViewLayout.invalidateLayout()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        debugLog("📐 [\(instanceID)] ArticlesVC.viewDidLayoutSubviews - safeArea: \(view.safeAreaInsets), view.frame: \(view.frame), cv.frame: \(collectionView.frame)")
        debugLog("📐 [\(instanceID)] ArticlesVC.viewDidLayoutSubviews - contentInsetAdjustmentBehavior: \(collectionView.contentInsetAdjustmentBehavior.rawValue), adjustedContentInset: \(collectionView.adjustedContentInset)")
        
        // Detect safe area changes - viewSafeAreaInsetsDidChange may not be called
        // when ArticlesVC is added as child during trait transition
        let currentSafeAreaTop = view.safeAreaInsets.top
        if currentSafeAreaTop != lastKnownSafeAreaTop {
            debugLog("📐 [\(instanceID)] Safe area changed: \(lastKnownSafeAreaTop) → \(currentSafeAreaTop), invalidating layout")
            lastKnownSafeAreaTop = currentSafeAreaTop

            // Must recreate layout, not just invalidate - invalidateLayout doesn't always reposition cells
            let newLayout = createLayout(for: layoutMode)
            collectionView.setCollectionViewLayout(newLayout, animated: false)

        }
    }
    
    /// Check if safe area has updated and fix layout if needed
    private func checkAndFixSafeAreaLayout() {
        let currentSafeArea = view.safeAreaInsets.top
        if currentSafeArea != lastKnownSafeAreaTop && currentSafeArea > 0 {
            debugLog("📐 [\(instanceID)] checkAndFixSafeAreaLayout - safe area now \(currentSafeArea), was \(lastKnownSafeAreaTop)")
            lastKnownSafeAreaTop = currentSafeArea
            let newLayout = createLayout(for: layoutMode)
            collectionView.setCollectionViewLayout(newLayout, animated: false)
        }
    }
    
    // MARK: - Collection View Setup
    
    private func setupCollectionView() {
        collectionView.dragDelegate = self
        collectionView.dragInteractionEnabled = true
        
        // Only allow cell selection in Grid mode
        collectionView.allowsSelection = (layoutMode == .grid)
        
        view.addSubview(collectionView)
        // ORIGINAL: view.topAnchor (no safe area)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        debugLog("📐 [\(instanceID)] ArticlesVC.setupCollectionView - contentInsetAdjustmentBehavior: \(collectionView.contentInsetAdjustmentBehavior.rawValue)")
        
        // Cell registration
        let cellReg = UICollectionView.CellRegistration<ArticleCell, ArticleDisplayItem> { [weak self] cell, indexPath, article in
            cell.delegate = self?.cellDelegate
            cell.configure(with: article, layoutMode: self?.layoutMode ?? .columns)
            cell.setZoomLevel(self?.zoomLevel ?? 100)
            cell.onClose = { [weak self] in
                guard let self = self else { return }
                self.delegate?.articlesViewController(self, didCloseArticle: article)
            }
            cell.onOpenInNewWindow = { [weak self] in
                let session = self?.view.window?.windowScene?.session
                SceneDelegate.openNewWindow(for: article, sourceSession: session)
            }
            cell.onBookmarkToggle = { isBookmarked in
                print("🔖 Bookmark: \(article.word): \(isBookmarked)")
                // TODO: Implement bookmark persistence
            }
            cell.onWillPresentFind = { [weak self] in
                self?.dismissAllFindsExcept(cell)
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
                pc.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                pc.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            ])
            pc.isHidden = true
            pageControl = pc
        }
        
        debugLog("📐 [\(instanceID)] ArticlesVC.setupCollectionView - contentInsetAdjustmentBehavior: \(collectionView.contentInsetAdjustmentBehavior.rawValue)")
    }
    
    // MARK: - Public API (called by Container)
    
    /// Called by parent when safe area changes during trait transition
    func invalidateLayoutForSafeAreaChange() {
        debugLog("📐 [\(instanceID)] ArticlesVC.invalidateLayoutForSafeAreaChange called, current safeArea: \(view.safeAreaInsets)")

        // Just invalidating doesn't fully update cell positions
        // Force recreate the entire layout
        let newLayout = createLayout(for: layoutMode)
        collectionView.setCollectionViewLayout(newLayout, animated: false)
    }
    
    func configure(articles: [ArticleDisplayItem], animated: Bool) {
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
        
        // Only allow cell selection in Grid mode (to switch to Columns)
        // In List/Columns, clicks should go to WebView for link handling
        collectionView.allowsSelection = (mode == .grid)
        
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
    
    func scrollToArticle(_ article: ArticleDisplayItem, animated: Bool) {
        guard let index = articles.firstIndex(of: article),
              dataSource.snapshot().numberOfItems > 0 else { return }
        
        let indexPath = IndexPath(item: index, section: 0)
        let scrollPosition: UICollectionView.ScrollPosition = switch layoutMode {
        case .columns: .centeredHorizontally
        case .grid, .list: .centeredVertically
        }
        collectionView.scrollToItem(at: indexPath, at: scrollPosition, animated: animated)
    }
    
    func setZoomLevel(_ level: Int) {
        zoomLevel = level

        // Update all visible cells
        for cell in collectionView.visibleCells {
            if let articleCell = cell as? ArticleCell {
                articleCell.setZoomLevel(level)
            }
        }
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
    
    private func createColumnsSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let safeTop = effectiveSafeAreaTop
        let mySafeTop = view.safeAreaInsets.top
        debugLog("📐 [\(instanceID)] ArticlesVC.createColumnsSection - safeArea: \(view.safeAreaInsets), effectiveSafeTop: \(safeTop), containerSize: \(environment.container.effectiveContentSize)")
        
        // IMPORTANT: Horizontal scroll behavior in UICollectionViewCompositionalLayout
        // ============================================================================
        // For horizontal scroll, the system AUTOMATICALLY:
        // 1. Subtracts safe area from effectiveContentSize.height (768 → 698)
        // 2. Positions cells below the safe area
        //
        // However, when child VC's safe area is 0 (due to trait transition timing),
        // the system doesn't know about safe area, so we must manually correct.
        // This is why we need `needsCorrection` only for columns, not for grid/list.
        let containerHeight = environment.container.effectiveContentSize.height
        let needsCorrection = mySafeTop == 0 && safeTop > 0
        let correctedHeight = needsCorrection ? containerHeight - safeTop : containerHeight
                 
        // With horizontal scrollDirection, cells fill the full height
        // and scroll horizontally across the screen
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let bottomMargin: CGFloat = if #available(iOS 26, *) { 0 } else { 16 }
        item.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 0, bottom: bottomMargin, trailing: 0)

        // Use corrected height instead of fractionalHeight(1.0) to fix safe area issue
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute(400),
            heightDimension: .absolute(correctedHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        // Only add top inset when safe area correction is needed (see comment above)
        let topInset: CGFloat = needsCorrection ? safeTop : 0
        section.contentInsets = NSDirectionalEdgeInsets(top: topInset, leading: 16, bottom: 0, trailing: 16)
        section.interGroupSpacing = 16

        return section
    }

    private func createGridSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let safeTop = effectiveSafeAreaTop
        debugLog("📐 [\(instanceID)] ArticlesVC.createGridSection - safeArea: \(view.safeAreaInsets), effectiveSafeTop: \(safeTop), containerSize: \(environment.container.effectiveContentSize)")

        // IMPORTANT: Vertical scroll behavior in UICollectionViewCompositionalLayout
        // ==========================================================================
        // For vertical scroll, the system does NOT automatically handle safe area:
        // 1. effectiveContentSize.height remains full height (768, not 698)
        // 2. Cells start at Y=0, ignoring safe area
        //
        // Therefore, we ALWAYS need to manually add safeTop as top inset.

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
        // Always add safe area as top inset (vertical scroll doesn't auto-handle it)
        section.contentInsets = NSDirectionalEdgeInsets(top: safeTop + 8, leading: 8, bottom: 8, trailing: 8)

        return section
    }

    private func createListSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let safeTop = effectiveSafeAreaTop
        debugLog("📐 [\(instanceID)] ArticlesVC.createListSection - safeArea: \(view.safeAreaInsets), effectiveSafeTop: \(safeTop), containerSize: \(environment.container.effectiveContentSize)")
        
        // Vertical scroll: must calculate height manually (see createGridSection comment)
        let correctedHeight = view.bounds.height - safeTop
                 
        // Each item fills all space
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .absolute(correctedHeight),
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0)

        // Group height equals container to ensure full-height paging
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        let leadingMargin: CGFloat = if #available(iOS 16, *) { 12 } else { 0 }
        group.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: leadingMargin, bottom: 0, trailing: 0)
        
        let section = NSCollectionLayoutSection(group: group)
        // Always add safe area as top inset (vertical scroll doesn't auto-handle it)
        section.contentInsets = NSDirectionalEdgeInsets(top: safeTop, leading: 16, bottom: 0, trailing: 16)
        section.interGroupSpacing = 0
        
        return section
    }
    
    // MARK: - Private
    
    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ArticleDisplayItem>()
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
    
    private func dismissAllFindsExcept(_ excludeCell: ArticleCell?) {
        guard #available(iOS 16.0, *) else { return }
        
        for cell in collectionView.visibleCells {
            if let articleCell = cell as? ArticleCell, articleCell !== excludeCell {
                articleCell.dismissFind()
            }
        }
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
                    UIAction(title: "Bookmark", image: UIImage(systemName: "bookmark")) { _ in
                        print("🔖 Bookmark: \(article.word)")
                        // TODO: Implement bookmark persistence
                    },
                    UIAction(title: "Find in Page", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                        guard #available(iOS 16.0, *) else { return }
                        self?.pendingFindIndexPath = indexPath
                    },
                    UIAction(title: "Open in New Window", image: UIImage(systemName: "rectangle.badge.plus")) { _ in
                        let session = self.view.window?.windowScene?.session
                        SceneDelegate.openNewWindow(for: article, sourceSession: session)
                    },
                    UIAction(title: "Close", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                        if let self = self {
                            self.delegate?.articlesViewController(self, didCloseArticle: article)
                        }
                    },
                ])
            }
        )
    }
    
    func collectionView(_ collectionView: UICollectionView,
                        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionAnimating?) {
        let pendingFind = self.pendingFindIndexPath
        self.pendingFindIndexPath = nil
        
        animator?.addCompletion { [weak self] in
            guard let self = self else { return }
            
            // Handle pending find request first
            if #available(iOS 16.0, *), let indexPath = pendingFind,
               let cell = self.collectionView.cellForItem(at: indexPath) as? ArticleCell {
                self.dismissAllFindsExcept(cell)
                cell.presentFind()
                return  // Skip reload when presenting find
            }
            
            // Normal case: reload visible cells
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
        
        // Create user activity with source session ID for tracking
        let activity = article.userActivity
        if let sessionId = view.window?.windowScene?.session.persistentIdentifier {
            activity.userInfo?["sourceSessionId"] = sessionId
        }

        let itemProvider = NSItemProvider(object: activity)
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = article
        return [dragItem]
    }
}

// MARK: - Find in Page

@available(iOS 16.0, *)
extension ArticlesViewController {
    /// Highlight keyword in all visible cells using JavaScript
    func highlightKeywordInAllCells(_ keyword: String?) {
        for cell in collectionView.visibleCells {
            (cell as? ArticleCell)?.highlightKeyword(keyword)
        }
    }
}
