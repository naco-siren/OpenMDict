//
//  BookmarkListViewController.swift
//  OpenMDict-iOS
//
//  Displays user's bookmarks with 3 sort modes:
//  1. Date Added — grouped by bookmark creation date
//  2. Last Lookup — grouped by last lookup date
//  3. Frequency — flat list sorted by lookup count
//
//  Sort mode and order are controlled via navigation bar menu buttons.
//  Used as the supplementary column when "Bookmarks" is selected in sidebar.
//

import UIKit

// MARK: - Section Type

/// Section identifier for the DiffableDataSource.
/// At file scope so Hashable conformance is nonisolated
/// (required by DiffableDataSource under `-default-isolation=MainActor`).
nonisolated enum BookmarkSection: Hashable, Sendable {
    case dateGroup(String)  // modes 1 & 2: date-based section header
    case all                // mode 3: single flat section
}

// MARK: - Sort Mode

private enum SortMode: Int, CaseIterable {
    case byBookmarkDate = 0
    case byLastLookup   = 1
    case byLookupCount  = 2

    var title: String {
        switch self {
        case .byBookmarkDate: return L10n.BookmarkSort.byBookmarkDate
        case .byLastLookup:   return L10n.BookmarkSort.byLastLookup
        case .byLookupCount:  return L10n.BookmarkSort.byLookupCount
        }
    }

    var iconName: String {
        switch self {
        case .byBookmarkDate: return "calendar"
        case .byLastLookup:   return "clock"
        case .byLookupCount:  return "sum"
        }
    }
}

// MARK: - Controller

class BookmarkListViewController: UIViewController {

    // MARK: - Callbacks

    var onBookmarkSelected: ((BookmarkItem) -> Void)?

    // MARK: - State

    private var currentMode: SortMode = .byBookmarkDate
    private var isAscending: Bool = false  // default: newest/highest first

    /// Cached lookup metadata for modes 2 & 3.
    /// Key: "word\0dictId" → (lastDate, count)
    private var lookupMeta: [String: (lastDate: Date?, count: Int)] = [:]

    // MARK: - UI

    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self,
                  let bookmark = self.dataSource.itemIdentifier(for: indexPath) else {
                return nil
            }
            let deleteAction = UIContextualAction(style: .destructive, title: L10n.Bookmarks.removeBookmark) { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                let alert = UIAlertController(
                    title: L10n.Bookmarks.removeBookmark,
                    message: L10n.Bookmarks.removeBookmarkMessage(word: bookmark.word, dictName: bookmark.dictName),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel) { _ in
                    completion(false)
                })
                alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
                    BookmarkService.shared.deleteBookmark(objectID: bookmark.objectID)
                    self?.reload()
                    completion(true)
                })
                self.present(alert, animated: true)
            }
            deleteAction.image = UIImage(systemName: "bookmark.slash")
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }

        let layout = UICollectionViewCompositionalLayout.list(using: config)

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
        return cv
    }()

    private lazy var emptyView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        let img = UIImageView(image: UIImage(systemName: "bookmark.slash"))
        img.tintColor = .tertiaryLabel
        img.preferredSymbolConfiguration = .init(pointSize: 48)

        let titleLabel = UILabel()
        titleLabel.text = L10n.Bookmarks.empty
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .secondaryLabel

        let subtitleLabel = UILabel()
        subtitleLabel.text = L10n.Bookmarks.emptySubtitle
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .tertiaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        stack.addArrangedSubview(img)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -32),
        ])
        return v
    }()

    // MARK: Navigation Bar Buttons

    /// Sort-by menu: line.3.horizontal.decrease
    private lazy var sortByButton: UIBarButtonItem = {
        UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), menu: buildSortByMenu())
    }()

    /// Sort-order menu: arrow.up.arrow.down
    private lazy var sortOrderButton: UIBarButtonItem = {
        UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: buildSortOrderMenu())
    }()

    /// Overflow menu: ellipsis.circle (contains "Clear All")
    private lazy var overflowButton: UIBarButtonItem = {
        UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: buildOverflowMenu())
    }()

    private var dataSource: UICollectionViewDiffableDataSource<BookmarkSection, BookmarkItem>!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.Bookmarks.title
        navigationItem.rightBarButtonItems = [overflowButton, sortOrderButton, sortByButton]

        view.backgroundColor = .systemGroupedBackground
        view.addSubview(collectionView)
        view.addSubview(emptyView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureDataSource()
        reload()
    }

    // MARK: - Public Reload

    /// Reload bookmarks from the data layer and refresh the snapshot.
    /// Called externally by MainSplitVC after bookmark mutations (e.g., article-side toggle).
    func reload() {
        // dataSource is configured in viewDidLoad; if called before that
        // (e.g. from MainSplitVC.showBookmarksList before the view
        // hierarchy triggers loadView), force-load the view first.
        loadViewIfNeeded()

        let bookmarks = BookmarkService.shared.allBookmarks()

        // Fetch lookup metadata for modes 2 & 3
        let pairs = bookmarks.map { (word: $0.word, dictId: $0.dictId) }
        lookupMeta = LookupHistoryService.shared.lookupMetadata(for: pairs)

        applySnapshot(bookmarks: bookmarks, animated: true)
        updateEmptyState(bookmarks: bookmarks)
    }

    // MARK: - Data Source Configuration

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, BookmarkItem> {
            [weak self] cell, indexPath, bookmark in
            guard let self else { return }

            var content = cell.defaultContentConfiguration()
            content.text = bookmark.word
            content.secondaryText = bookmark.dictName
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "bookmark")
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content

            // Mode 3: show lookup count as trailing label
            if self.currentMode == .byLookupCount {
                let key = "\(bookmark.word)\0\(bookmark.dictId)"
                let count = self.lookupMeta[key]?.count ?? 0
                let countLabel = UILabel()
                countLabel.text = "\(count)"
                countLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
                countLabel.textColor = .secondaryLabel
                cell.accessories = [
                    .customView(configuration: .init(
                        customView: countLabel,
                        placement: .trailing(displayed: .always)
                    ))
                ]
            } else {
                cell.accessories = []
            }
        }

        // Section header registration
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, _, indexPath in
            guard let self,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }

            switch section {
            case .dateGroup(let title):
                var config = UIListContentConfiguration.groupedHeader()
                config.text = title
                headerView.contentConfiguration = config
                headerView.isHidden = false
            case .all:
                // No header for flat list (Lookup Times mode)
                headerView.contentConfiguration = nil
                headerView.isHidden = true
            }
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, bookmark in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: bookmark)
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    // MARK: - Snapshot Building

    private func applySnapshot(bookmarks: [BookmarkItem], animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<BookmarkSection, BookmarkItem>()

        switch currentMode {
        case .byBookmarkDate:
            applyDateAddedSnapshot(&snapshot, bookmarks: bookmarks)
        case .byLastLookup:
            applyLastLookupSnapshot(&snapshot, bookmarks: bookmarks)
        case .byLookupCount:
            applyLookupCountSnapshot(&snapshot, bookmarks: bookmarks)
        }

        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    /// Mode 1: group by bookmark creation date
    private func applyDateAddedSnapshot(
        _ snapshot: inout NSDiffableDataSourceSnapshot<BookmarkSection, BookmarkItem>,
        bookmarks: [BookmarkItem]
    ) {
        var sections = groupItemsByDate(bookmarks)
        if isAscending {
            sections.reverse()
            sections = sections.map { DateSection(title: $0.title, items: $0.items.reversed()) }
        }
        for section in sections {
            let sectionId = BookmarkSection.dateGroup(section.title)
            snapshot.appendSections([sectionId])
            snapshot.appendItems(section.items, toSection: sectionId)
        }
    }

    /// Mode 2: group by last lookup date
    private func applyLastLookupSnapshot(
        _ snapshot: inout NSDiffableDataSourceSnapshot<BookmarkSection, BookmarkItem>,
        bookmarks: [BookmarkItem]
    ) {
        struct LookupDateWrapper: DateGroupable {
            let bookmark: BookmarkItem
            let lookupDate: Date?
            var groupingDate: Date? { lookupDate }
        }

        let wrappers = bookmarks.map { bm -> LookupDateWrapper in
            let key = "\(bm.word)\0\(bm.dictId)"
            let lastDate = lookupMeta[key]?.lastDate
            return LookupDateWrapper(bookmark: bm, lookupDate: lastDate)
        }

        let sorted = wrappers.sorted { a, b in
            let dateA = a.lookupDate ?? .distantPast
            let dateB = b.lookupDate ?? .distantPast
            return isAscending ? dateA < dateB : dateA > dateB
        }

        var sections = groupItemsByDate(
            sorted,
            unknownSectionTitle: L10n.HistorySection.unknown
        )

        if isAscending {
            sections.reverse()
            sections = sections.map { DateSection(title: $0.title, items: $0.items.reversed()) }
        }

        for section in sections {
            let sectionId = BookmarkSection.dateGroup(section.title)
            snapshot.appendSections([sectionId])
            let items = section.items.map { $0.bookmark }
            snapshot.appendItems(items, toSection: sectionId)
        }
    }

    /// Mode 3: flat list sorted by lookup count
    private func applyLookupCountSnapshot(
        _ snapshot: inout NSDiffableDataSourceSnapshot<BookmarkSection, BookmarkItem>,
        bookmarks: [BookmarkItem]
    ) {
        let sorted = bookmarks.sorted { a, b in
            let keyA = "\(a.word)\0\(a.dictId)"
            let keyB = "\(b.word)\0\(b.dictId)"
            let countA = lookupMeta[keyA]?.count ?? 0
            let countB = lookupMeta[keyB]?.count ?? 0
            return isAscending ? countA < countB : countA > countB
        }

        snapshot.appendSections([.all])
        snapshot.appendItems(sorted, toSection: .all)
    }

    // MARK: - Navigation Bar Menus

    private func buildSortByMenu() -> UIMenu {
        let actions = SortMode.allCases.map { mode in
            UIAction(
                title: mode.title,
                image: UIImage(systemName: mode.iconName),
                state: mode == currentMode ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.currentMode = mode
                self.isAscending = false
                self.rebuildMenus()
                self.reload()
            }
        }
        return UIMenu(children: actions)
    }

    private func buildSortOrderMenu() -> UIMenu {
        let ascAction = UIAction(
            title: "Ascending",
            image: UIImage(systemName: "arrow.up"),
            state: isAscending ? .on : .off
        ) { [weak self] _ in
            guard let self else { return }
            self.isAscending = true
            self.rebuildMenus()
            self.reload()
        }

        let descAction = UIAction(
            title: "Descending",
            image: UIImage(systemName: "arrow.down"),
            state: !isAscending ? .on : .off
        ) { [weak self] _ in
            guard let self else { return }
            self.isAscending = false
            self.rebuildMenus()
            self.reload()
        }

        return UIMenu(children: [ascAction, descAction])
    }

    private func buildOverflowMenu() -> UIMenu {
        let clearAction = UIAction(
            title: L10n.Bookmarks.clearAll,
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmClearAll()
        }
        return UIMenu(children: [clearAction])
    }

    /// Rebuild all menus to reflect current sort state (checkmarks).
    private func rebuildMenus() {
        sortByButton.menu = buildSortByMenu()
        sortOrderButton.menu = buildSortOrderMenu()
    }

    // MARK: - Empty State

    private func updateEmptyState(bookmarks: [BookmarkItem]) {
        let isEmpty = bookmarks.isEmpty
        emptyView.isHidden = !isEmpty
        collectionView.isHidden = isEmpty
        overflowButton.isEnabled = !isEmpty
    }

    // MARK: - Actions

    private func confirmClearAll() {
        let alert = UIAlertController(
            title: L10n.Bookmarks.clearAll,
            message: L10n.Bookmarks.clearAllConfirm,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
            BookmarkService.shared.clearAll()
            self?.reload()
        })
        present(alert, animated: true)
    }
}

// MARK: - UICollectionViewDelegate

extension BookmarkListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let bookmark = dataSource.itemIdentifier(for: indexPath) else { return }
        onBookmarkSelected?(bookmark)
    }
}
