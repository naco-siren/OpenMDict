//
//  ArticleViewController.swift
//  OpenMDict-iOS
//
//  Paged article view for compact mode (iPhone / iPad narrow).
//  Displays all open articles in a horizontally-paged UICollectionView with a
//  floating page control at the bottom.  Each page is a CompactArticleCell
//  (shared ArticlePageView: header + WKWebView).
//
//  ── Why a recycling collection view (not a manual UIScrollView pager) ──
//  The old implementation kept one live WKWebView per open article (up to the
//  per-device capacity, 30–60) and tore them ALL down + rebuilt them on every
//  push.  Discarded webviews were mid-navigation and got pinned by WebKit's
//  NavigationState, so they accumulated unboundedly → memory climbed → the app
//  OOM-crashed inside Auto Layout (`+[NSISVariable …] couldNotInstantiate`).
//  A UICollectionView recycles cells, so the live WKWebView working set is
//  bounded to the visible window (~1–3), and a diffable data source keyed by
//  the stable article id means a new lookup only builds ONE cell instead of
//  rebuilding every page.  This mirrors the regular-mode ArticlesViewController.
//

import Combine
import UIKit
import WebKit

// MARK: - Delegate

protocol ArticleViewControllerDelegate: AnyObject {
    /// `fragment` is the `#anchor` part of an `entry://word#anchor` cross-reference
    /// (nil when the URL had no fragment).  The handler is expected to scroll the
    /// target article to that DOM id after it loads.
    func articleViewController(_ vc: ArticleViewController, didTapEntryLink word: String, fragment: String?, inDict dictId: String)
    func articleViewController(_ vc: ArticleViewController, didRequestJumpSearch word: String, inDict dictId: String)
    func articleViewController(_ vc: ArticleViewController, didChangePage index: Int)
    func articleViewController(_ vc: ArticleViewController, didCloseArticle article: ArticleDisplayItem)
}

class ArticleViewController: UIViewController {

    // MARK: - Delegate

    weak var delegate: ArticleViewControllerDelegate?

    // MARK: - Pager State

    private var articles: [ArticleDisplayItem] = []
    /// id → article, for O(1) lookup from the diffable data source (which is
    /// keyed by the stable article id, not the full `ArticleDisplayItem`).
    private var articlesById: [String: ArticleDisplayItem] = [:]
    private(set) var currentPageIndex: Int = 0
    /// Lazy-init from the persisted compact-trait zoom so a freshly-built
    /// pager (cold start, or after navigating away + back) starts at the
    /// user's last-used level instead of always 100%.  Subsequent updates
    /// arrive via `setZoomLevel(_:)` from DetailContainerVC.applyZoom().
    private lazy var currentZoomLevel: Int = UserDefaults.shared.initialZoomLevel(compact: true)
    private var bookmarkCancellable: AnyCancellable?
    private var lookupHistoryCancellable: AnyCancellable?

    // MARK: - Safe Area (manual, same pattern as ArticlesVC)

    /// Constraint from collectionView.top → view.top, constant = effective safe area.
    /// We manage this manually instead of using `safeAreaLayoutGuide.topAnchor`
    /// because safeAreaLayoutGuide doesn't propagate from UINavigationController
    /// during a `UIViewControllerTransitionCoordinator.animate` block.
    private var collectionViewTopConstraint: NSLayoutConstraint!

    /// Effective safe area top: own value, falling back to parent's.
    private var effectiveSafeAreaTop: CGFloat {
        let myTop = view.safeAreaInsets.top
        if myTop > 0 { return myTop }
        return parent?.view.safeAreaInsets.top ?? 0
    }

    // MARK: - Pager UI

    private lazy var pagerLayout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        return layout
    }()

    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: pagerLayout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        // Full-width cells + native paging give the same snapping as the old
        // UIScrollView pager, with no visible scroll indicator.
        cv.isPagingEnabled = true
        cv.showsHorizontalScrollIndicator = false
        cv.showsVerticalScrollIndicator = false
        cv.alwaysBounceVertical = false
        // Safe area is handled manually via collectionViewTopConstraint.
        cv.contentInsetAdjustmentBehavior = .never
        cv.backgroundColor = .clear
        cv.delegate = self
        return cv
    }()

    /// Lazy so `configure(...)` works even when DetailContainerVC calls it
    /// before this VC's view loads (compact first-lookup pushes an article
    /// *before* the container is on the nav stack).  Accessing it self-builds
    /// the data source + (lazy) collection view, mirroring how the old pager
    /// tolerated early configuration via its lazy `scrollView`.
    private lazy var dataSource: UICollectionViewDiffableDataSource<Int, String> = makeDataSource()

    private lazy var pageControlBackdrop: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26, *) {
            effect = UIGlassEffect(style: .clear)
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        let v = UIVisualEffectView(effect: effect)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private lazy var pageControl: UIPageControl = {
        let pc = UIPageControl()
        pc.translatesAutoresizingMaskIntoConstraints = false
        pc.hidesForSinglePage = true
        pc.currentPageIndicatorTintColor = .label
        pc.pageIndicatorTintColor = .tertiaryLabel
        pc.addTarget(self, action: #selector(pageControlValueChanged), for: .valueChanged)
        pc.isHidden = true
        return pc
    }()

    private lazy var emptyView: ArticlePlaceholderView = {
        let v = ArticlePlaceholderView.empty()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .systemBackground
        return v
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        navigationItem.largeTitleDisplayMode = .never
        setupUI()
        showEmpty()

        // Refresh bookmark icon / lookup count on visible cells when the
        // underlying services change (same pattern as ArticlesViewController).
        bookmarkCancellable = BookmarkService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.bookmarksDidChange()
            }

        lookupHistoryCancellable = LookupHistoryService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lookupCountsDidChange()
            }
    }

    private func setupUI() {
        view.addSubview(collectionView)
        view.addSubview(emptyView)

        pageControlBackdrop.contentView.addSubview(pageControl)
        view.addSubview(pageControlBackdrop)

        // Manual safe area: topAnchor + constant (not safeAreaLayoutGuide — see comment above)
        collectionViewTopConstraint = collectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: effectiveSafeAreaTop)

        NSLayoutConstraint.activate([
            collectionViewTopConstraint,
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Page control backdrop — centered at bottom
            pageControlBackdrop.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControlBackdrop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            // Page control inside backdrop
            pageControl.topAnchor.constraint(equalTo: pageControlBackdrop.contentView.topAnchor, constant: 4),
            pageControl.bottomAnchor.constraint(equalTo: pageControlBackdrop.contentView.bottomAnchor, constant: -4),
            pageControl.leadingAnchor.constraint(equalTo: pageControlBackdrop.contentView.leadingAnchor, constant: 4),
            pageControl.trailingAnchor.constraint(equalTo: pageControlBackdrop.contentView.trailingAnchor, constant: -4),

            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        collectionViewTopConstraint.constant = effectiveSafeAreaTop
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Keep collectionView below nav bar (parent fallback for first transition)
        collectionViewTopConstraint.constant = effectiveSafeAreaTop

        // Capsule shape for page control backdrop
        if pageControlBackdrop.bounds.height > 0 {
            pageControlBackdrop.layer.cornerRadius = pageControlBackdrop.bounds.height / 2
            pageControlBackdrop.layer.masksToBounds = true
        }

        // Each page fills the collection view; native paging snaps per page.
        let size = collectionView.bounds.size
        if size.width > 0, size.height > 0, pagerLayout.itemSize != size {
            pagerLayout.itemSize = size
            pagerLayout.invalidateLayout()
            // Restore the current page after a bounds / orientation change once
            // the new contentSize has settled (defer to next runloop tick).
            let targetPage = currentPageIndex
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pagerLayout.itemSize.width > 0 else { return }
                self.scrollToPage(targetPage, animated: false)
            }
        }
    }

    // MARK: - Data Source

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Int, String> {
        let cellReg = UICollectionView.CellRegistration<CompactArticleCell, String> { [weak self] cell, _, articleId in
            guard let self, let article = self.articlesById[articleId] else { return }

            cell.configure(with: article)
            cell.setZoomLevel(self.currentZoomLevel)

            // ── Wire pageView callbacks ──
            // The registration handler re-runs on reconfigure, so captured
            // immutable fields (dictId/word) stay fresh; the close handler
            // resolves the *current* article by the cell's live index so it
            // matches even after a pending → loaded contentState change.
            cell.pageView.onEntryLinkTapped = { [weak self] word, fragment in
                guard let self else { return }
                self.delegate?.articleViewController(self, didTapEntryLink: word, fragment: fragment, inDict: article.dictId)
            }
            cell.pageView.onSoundLinkTapped = { url in
                AudioService.shared.play(url: url, dictId: article.dictId)
            }
            cell.pageView.onJumpSearch = { [weak self] text in
                guard let self else { return }
                self.delegate?.articleViewController(self, didRequestJumpSearch: text, inDict: article.dictId)
            }
            cell.pageView.onEnhanceDarkModeStrengthChanged = { newStrength in
                DictMetadataService.shared.updateEnhanceDarkModeStrength(dictId: article.dictId, strength: newStrength)
            }
            cell.pageView.onBookmarkTapped = { [weak self, weak cell] isCurrentlyBookmarked in
                guard let self else { return }
                if isCurrentlyBookmarked {
                    self.confirmRemoveBookmark(word: article.word, dictId: article.dictId, dictName: article.dictName)
                } else {
                    cell?.pageView.setBookmarked(true)
                    let created = BookmarkService.shared.toggleBookmark(word: article.word, dictId: article.dictId)
                    if created {
                        BookmarkCountService.shared.incrementAll(dictId: article.dictId)
                    }
                }
            }
            cell.pageView.onFindTapped = { [weak self, weak cell] in
                self?.dismissAllFindsExcept(cell)
            }
            cell.pageView.onCloseTapped = { [weak self, weak cell] in
                guard let self, let cell,
                      let idx = self.collectionView.indexPath(for: cell)?.item,
                      idx < self.articles.count else { return }
                self.delegate?.articleViewController(self, didCloseArticle: self.articles[idx])
            }
        }

        return UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, articleId in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: articleId)
        }
    }

    // MARK: - Public API (called by Container)

    func configure(articles: [ArticleDisplayItem], currentIndex: Int) {
        let oldById = articlesById
        self.articles = articles
        self.articlesById = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })

        guard !articles.isEmpty else {
            showEmpty()
            return
        }

        showContent()

        // Build a snapshot of stable ids.  Items present in both old and new
        // keep their cell (and WKWebView); only genuinely-new ids build a cell.
        // Ids whose contentState changed (pending → loaded) are reconfigured
        // in place so the same WKWebView reloads, without a teardown/rebuild.
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(articles.map(\.id))
        let changedIds = articles.compactMap { article -> String? in
            guard let old = oldById[article.id], old.contentState != article.contentState else { return nil }
            return article.id
        }
        if !changedIds.isEmpty {
            snapshot.reconfigureItems(changedIds)
        }

        let safeIndex = max(0, min(currentIndex, articles.count - 1))
        currentPageIndex = safeIndex

        // Update page control
        pageControl.numberOfPages = articles.count
        pageControl.currentPage = safeIndex
        let showPager = articles.count > 1
        pageControl.isHidden = !showPager
        pageControlBackdrop.isHidden = !showPager

        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            // After the snapshot lands (and contentSize updates) jump to the
            // requested page.  viewDidLayoutSubviews also restores this on a
            // later bounds change, so a too-early call here is harmless.
            self?.scrollToPage(safeIndex, animated: false)
        }
    }

    /// Navigate to a specific page. Called by Container for keyboard shortcuts / external navigation.
    func navigateToPage(_ page: Int, animated: Bool = false) {
        guard page >= 0, page < articles.count else { return }
        currentPageIndex = page
        pageControl.currentPage = page
        scrollToPage(page, animated: animated)
        delegate?.articleViewController(self, didChangePage: page)
    }

    /// Scroll the page at index 0 (the most recently navigated-to article) to
    /// an in-page anchor.  Used by cross-reference click handling so the user
    /// lands at the matching `id` inside the target article.  Retries on the
    /// next runloop tick if the cell isn't dequeued yet.
    func scrollFirstPage(toAnchor anchor: String?) {
        guard let anchor, !anchor.isEmpty else { return }
        let indexPath = IndexPath(item: 0, section: 0)
        if let cell = collectionView.cellForItem(at: indexPath) as? CompactArticleCell {
            cell.scrollToAnchor(anchor)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let cell = self?.collectionView.cellForItem(at: indexPath) as? CompactArticleCell else { return }
                cell.scrollToAnchor(anchor)
            }
        }
    }

    // MARK: - Page Navigation

    /// Scroll to a page by setting the content offset directly.  Full-width
    /// cells mean `page * width` is exactly the snapped paging position.
    private func scrollToPage(_ page: Int, animated: Bool) {
        guard page >= 0, page < articles.count else { return }
        let pageWidth = collectionView.bounds.width
        guard pageWidth > 0 else { return }  // not laid out yet; viewDidLayoutSubviews restores
        collectionView.setContentOffset(CGPoint(x: CGFloat(page) * pageWidth, y: 0), animated: animated)
    }

    @objc private func pageControlValueChanged(_ sender: UIPageControl) {
        navigateToPage(sender.currentPage, animated: true)
    }

    /// Sync `currentPageIndex` + page control from the scroll position after a
    /// user-driven swipe, and notify the delegate of the page change.
    private func syncCurrentPageFromScroll() {
        let pageWidth = collectionView.bounds.width
        guard pageWidth > 0, !articles.isEmpty else { return }
        let page = Int(round(collectionView.contentOffset.x / pageWidth))
        let clamped = min(max(0, page), articles.count - 1)
        guard clamped != currentPageIndex else { return }
        currentPageIndex = clamped
        pageControl.currentPage = clamped
        delegate?.articleViewController(self, didChangePage: clamped)
    }

    // MARK: - Show / Hide States

    private func showContent() {
        emptyView.isHidden = true
        collectionView.isHidden = false
    }

    private func showEmpty() {
        emptyView.isHidden = false
        collectionView.isHidden = true
        pageControl.isHidden = true
        pageControlBackdrop.isHidden = true
        articles = []
        articlesById = [:]
        currentPageIndex = 0
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Bookmark Actions

    private func confirmRemoveBookmark(word: String, dictId: String, dictName: String) {
        let alert = UIAlertController(
            title: L10n.Bookmarks.removeBookmark,
            message: L10n.Bookmarks.removeBookmarkMessage(word: word, dictName: dictName),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { _ in
            BookmarkService.shared.toggleBookmark(word: word, dictId: dictId)
        })
        present(alert, animated: true)
    }

    private func bookmarksDidChange() {
        for cell in collectionView.visibleCells {
            (cell as? CompactArticleCell)?.refreshBookmarkState()
        }
    }

    private func lookupCountsDidChange() {
        for cell in collectionView.visibleCells {
            (cell as? CompactArticleCell)?.refreshLookupCount()
        }
    }

    // MARK: - Zoom

    func setZoomLevel(_ level: Int) {
        currentZoomLevel = level
        for cell in collectionView.visibleCells {
            (cell as? CompactArticleCell)?.setZoomLevel(level)
        }
    }

    /// Re-apply per-dict dark mode enhancement to all visible pages.
    /// Called when DictMetadataService revision changes (e.g. user toggled enhanceDarkMode).
    func refreshDarkModeEnhance() {
        for cell in collectionView.visibleCells {
            guard let articleCell = cell as? CompactArticleCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  let article = articlesById[id] else { continue }
            articleCell.setDarkModeEnhance(strength: ArticlesViewController.enhanceStrength(for: article.dictId))
        }
    }

    /// Re-evaluate visibility of the enhance dark mode button on all visible pages.
    /// Called when the Settings toggle changes.
    func refreshEnhanceDarkModeVisibility() {
        for cell in collectionView.visibleCells {
            (cell as? CompactArticleCell)?.pageView.updateEnhanceDarkModeButtonVisibility()
        }
    }

    // MARK: - Find

    private func dismissAllFindsExcept(_ excludeCell: CompactArticleCell?) {
        guard #available(iOS 16.0, *) else { return }
        for cell in collectionView.visibleCells {
            if let articleCell = cell as? CompactArticleCell, articleCell !== excludeCell {
                articleCell.dismissFind()
            }
        }
    }

    /// Present or hide system Find UI (iOS 16+) on the current page.
    @available(iOS 16.0, *)
    func toggleFind() {
        let indexPath = IndexPath(item: currentPageIndex, section: 0)
        guard let cell = collectionView.cellForItem(at: indexPath) as? CompactArticleCell else { return }
        if cell.isFindNavigatorVisible {
            cell.dismissFind()
        } else {
            cell.presentFind()
        }
    }
}

// MARK: - UICollectionViewDelegate

extension ArticleViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Re-apply per-dict dark mode to cells scrolling into view (the dict's
        // setting may have changed while this cell was off-screen / pooled).
        guard let articleCell = cell as? CompactArticleCell,
              let id = dataSource.itemIdentifier(for: indexPath),
              let article = articlesById[id] else { return }
        articleCell.setDarkModeEnhance(strength: ArticlesViewController.enhanceStrength(for: article.dictId))
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        syncCurrentPageFromScroll()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === collectionView else { return }
        if !decelerate {
            syncCurrentPageFromScroll()
        }
    }
}
