//
//  BookmarkListViewController.swift
//  OpenMDict-iOS
//
//  Displays user's bookmarks as a flat list (most recent first).
//  Used as the supplementary column when "Bookmarks" is selected in sidebar.
//

import UIKit

class BookmarkListViewController: UIViewController {

    // MARK: - Callbacks

    var onBookmarkSelected: ((BookmarkItem) -> Void)?

    // MARK: - Data

    private var bookmarks: [BookmarkItem] = []
    private var dataSource: UICollectionViewDiffableDataSource<Int, BookmarkItem>!

    // MARK: - UI

    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebarPlain)
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
                alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { _ in
                    BookmarkService.shared.deleteBookmark(objectID: bookmark.objectID)
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

    private lazy var clearAllButton: UIBarButtonItem = {
        let btn = UIBarButtonItem(
            title: L10n.Bookmarks.clearAll,
            style: .plain,
            target: self,
            action: #selector(clearAllTapped)
        )
        btn.tintColor = .systemRed
        return btn
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.Bookmarks.title
        navigationItem.rightBarButtonItem = clearAllButton

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
        loadBookmarks()

        NotificationCenter.default.addObserver(
            self, selector: #selector(bookmarksDidChange),
            name: BookmarkService.didChangeNotification, object: nil
        )
    }

    // MARK: - Data Source

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, BookmarkItem> {
            cell, indexPath, bookmark in

            var content = UIListContentConfiguration.sidebarSubtitleCell()
            content.text = bookmark.word
            content.secondaryText = bookmark.dictName
            content.image = UIImage(systemName: "bookmark.fill")
            content.imageProperties.tintColor = .systemBlue
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, bookmark in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: bookmark)
        }
    }

    // MARK: - Load & Refresh

    private func loadBookmarks() {
        bookmarks = BookmarkService.shared.allBookmarks()
        applySnapshot(animated: false)
        updateEmptyState()
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, BookmarkItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(bookmarks)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func updateEmptyState() {
        emptyView.isHidden = !bookmarks.isEmpty
        collectionView.isHidden = bookmarks.isEmpty
        clearAllButton.isEnabled = !bookmarks.isEmpty
    }

    @objc private func bookmarksDidChange() {
        loadBookmarks()
    }

    // MARK: - Actions

    @objc private func clearAllTapped() {
        let alert = UIAlertController(
            title: L10n.Bookmarks.clearAll,
            message: L10n.Bookmarks.clearAllConfirm,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { _ in
            BookmarkService.shared.clearAll()
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
