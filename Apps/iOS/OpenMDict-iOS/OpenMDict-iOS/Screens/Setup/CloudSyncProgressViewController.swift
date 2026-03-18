//
//  CloudSyncProgressViewController.swift
//  OpenMDict-iOS
//
//  Live sync dashboard shown during first-launch iCloud restore.
//
//  Layout (matches ImportProgressViewController):
//    - Title label (centred, top)
//    - Icon + message header (collection view section header)
//    - UICollectionView (fills available space, insetGrouped)
//    - Separator + status label + footer button (pinned to bottom)
//
//  Sync phases:
//    1. Wait for CoreData metadata to sync from CloudKit (via CloudKitSyncMonitor).
//       During this phase, group and bookmark counts update in real-time.
//    2. Download dictionary files via DictionaryFileSyncService.
//    3. Enable "Done" button when all categories reach target counts.
//
//  Each category cell shows:  title + "X of Y synced" + CircularProgressView or ✓
//

import Combine
import CoreData
import UIKit

final class CloudSyncProgressViewController: UIViewController {

    // MARK: - Input

    /// Target counts from CloudKit (set by SetupViewController before display).
    var targetSummary = CloudDataSummary(dictionaryCount: 0, groupCount: 0, bookmarkCount: 0, lookupHistoryCount: 0)

    // MARK: - Callbacks

    /// Fired when the user taps "Done" (all categories synced).
    var onComplete: (() -> Void)?

    // MARK: - Sync Category Model

    private enum Category: String, CaseIterable {
        case dictionaries
        case groups
        case bookmarks
        case lookupHistory

        var title: String {
            switch self {
            case .dictionaries:   return L10n.SyncProgress.categoryDictionaries
            case .groups:         return L10n.SyncProgress.categoryGroups
            case .bookmarks:      return L10n.SyncProgress.categoryBookmarks
            case .lookupHistory:  return L10n.SyncProgress.categoryLookupHistory
            }
        }
    }

    private struct CategoryState {
        var current: Int = 0
        var target: Int = 0
        var isComplete: Bool { current >= target }
        var fraction: CGFloat {
            guard target > 0 else { return 1 }
            return CGFloat(min(current, target)) / CGFloat(target)
        }
    }

    private var categoryStates: [Category: CategoryState] = [:]

    /// Which categories to show (target > 0).
    private var visibleCategories: [Category] = []

    // MARK: - Sync State

    private enum SyncPhase {
        case syncingMetadata   // Phase 1: waiting for CoreData/CloudKit import
        case downloadingFiles  // Phase 2: downloading dictionary archives
        case complete          // All done
    }

    private var syncPhase: SyncPhase = .syncingMetadata
    private let syncMonitor = CloudKitSyncMonitor()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - UI: Header

    private let iconImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        let name: String
        if #available(iOS 18, *) {
            name = "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        } else {
            name = "icloud.and.arrow.down"
        }
        let image = UIImage(systemName: name, withConfiguration: config)
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 80),
            iv.heightAnchor.constraint(equalToConstant: 80),
        ])
        return iv
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.SyncProgress.syncingMessage
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    /// Stack containing icon + message, placed as collection view header
    private lazy var headerStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [iconImageView, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 32, left: 32, bottom: 16, right: 32)
        return stack
    }()

    // MARK: - UI: Collection View

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Category>!

    // MARK: - UI: Bottom Area

    private let bottomSeparator: UIView = {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let footerButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        config.showsActivityIndicator = true
        config.imagePadding = 8
        config.title = L10n.SyncProgress.syncing
        let button = UIButton(configuration: config)
        button.isEnabled = false
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        buildCategoryStates()
        setupCollectionView()
        setupLayout()
        configureDataSource()
        applyInitialSnapshot()

        footerButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSync()
    }

    // MARK: - Category Setup

    private func buildCategoryStates() {
        let s = targetSummary
        if s.dictionaryCount > 0 {
            categoryStates[.dictionaries] = CategoryState(current: 0, target: s.dictionaryCount)
            visibleCategories.append(.dictionaries)
        }
        if s.groupCount > 0 {
            categoryStates[.groups] = CategoryState(current: 0, target: s.groupCount)
            visibleCategories.append(.groups)
        }
        if s.bookmarkCount > 0 {
            categoryStates[.bookmarks] = CategoryState(current: 0, target: s.bookmarkCount)
            visibleCategories.append(.bookmarks)
        }
        if s.lookupHistoryCount > 0 {
            categoryStates[.lookupHistory] = CategoryState(current: 0, target: s.lookupHistoryCount)
            visibleCategories.append(.lookupHistory)
        }
    }

    /// Called by SetupVC when target counts arrive after the view has loaded
    /// (recovery path: app killed during cloud sync → re-query CloudKit).
    func reloadTargets() {
        guard isViewLoaded else { return }

        // Rebuild state from updated targetSummary
        categoryStates.removeAll()
        visibleCategories.removeAll()
        buildCategoryStates()

        // Re-apply snapshot with new categories
        var snapshot = NSDiffableDataSourceSnapshot<Int, Category>()
        snapshot.appendSections([0])
        snapshot.appendItems(visibleCategories, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)

        // Refresh counts immediately
        refreshCounts()
    }

    // MARK: - Collection View Setup

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfig.headerMode = .none

        let layout = UICollectionViewCompositionalLayout { _, layoutEnvironment in
            let section = NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: layoutEnvironment)
            section.contentInsetsReference = .readableContent
            section.contentInsets.leading = 12
            section.contentInsets.trailing = 12
            return section
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemGroupedBackground

        view.addSubview(collectionView)
    }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(headerStack)
        view.addSubview(bottomSeparator)
        view.addSubview(footerButton)

        NSLayoutConstraint.activate([
            // Header stack (centred, top)
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.readableContentGuide.leadingAnchor),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.readableContentGuide.trailingAnchor),
            headerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Collection view (below header, above separator)
            collectionView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            // Separator
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            // Footer button (pinned to bottom, readableContentGuide width)
            footerButton.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor, constant: 20),
            footerButton.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            footerButton.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            footerButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            footerButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    // MARK: - Data Source

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Category> {
            [weak self] cell, _, category in
            guard let self, let state = self.categoryStates[category] else { return }
            self.configureCell(cell, category: category, state: state)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
    }

    private func applyInitialSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Category>()
        snapshot.appendSections([0])
        snapshot.appendItems(visibleCategories, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Cell Configuration

    private func configureCell(_ cell: UICollectionViewListCell, category: Category, state: CategoryState) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = category.title
        content.secondaryText = state.isComplete
            ? L10n.SyncProgress.progressComplete
            : L10n.SyncProgress.progressFormat(current: state.current, total: state.target)
        if state.isComplete {
            content.secondaryTextProperties.color = .systemGreen
        }
        cell.contentConfiguration = content

        // Trailing accessory: checkmark or progress ring
        if state.isComplete {
            let checkImage = UIImageView(image: UIImage(systemName: "checkmark.diamond.fill"))
            checkImage.tintColor = .systemGreen
            cell.accessories = [.customView(configuration: .init(
                customView: checkImage, placement: .trailing(displayed: .always)
            ))]
        } else {
            let progress = CircularProgressView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            progress.progress = state.fraction
            cell.accessories = [.customView(configuration: .init(
                customView: progress, placement: .trailing(displayed: .always),
                reservedLayoutWidth: .custom(24)
            ))]
        }
    }

    // MARK: - Sync Flow

    private func startSync() {
        syncPhase = .syncingMetadata

        // Subscribe to remote changes for live count updates
        CoreDataStack.shared.remoteChangePublisher
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.refreshCounts()
            }
            .store(in: &cancellables)

        // Phase 1: wait for metadata to arrive via CloudKit
        syncMonitor.onInitialImportComplete = { [weak self] in
            self?.handleMetadataSynced()
        }
        syncMonitor.start()
    }

    /// Called when CloudKitSyncMonitor determines metadata import is done.
    private func handleMetadataSynced() {
        debugLog("☁️ CloudSyncProgress: metadata import complete → starting file downloads")
        syncPhase = .downloadingFiles
        refreshCounts()

        // Phase 2: download dictionary files
        let allMetadata = DictMetadataService.shared.loadAll()

        Task {
            for metadata in allMetadata {
                // Only attempt download for dicts whose archive is already in CloudKit.
                // If the originating device hasn't finished uploading (status == .pending)
                // or the dict is too large / errored, skip — the CKRecord doesn't exist.
                let syncStatus = CloudSyncStatus(rawValue: metadata.cloudSyncStatus) ?? .pending
                guard syncStatus == .synced else {
                    debugLog("☁️ CloudSyncProgress: skip \(metadata.dictId.prefix(16)) — cloudSyncStatus=\(syncStatus)")
                    continue
                }

                let dictDir = DictionaryStorageService.shared.dictionaryDirectoryURL(id: metadata.dictId)
                if FileManager.default.fileExists(atPath: dictDir.path) {
                    continue // Already present
                }

                let success = await DictionaryFileSyncService.shared.downloadDictionary(
                    dictId: metadata.dictId
                )
                if success {
                    debugLog("☁️ CloudSyncProgress: downloaded \(metadata.dictId.prefix(16))")
                } else {
                    debugLog("☁️ CloudSyncProgress: failed to download \(metadata.dictId.prefix(16)) — skipping")
                }

                // Refresh counts after each download
                refreshCounts()
            }

            // All downloads attempted — final refresh
            refreshCounts()
            checkCompletion()
        }
    }

    // MARK: - Live Count Updates

    private func refreshCounts() {
        let stack = CoreDataStack.shared

        // Dictionaries: count metadata records with local files.
        // Adjust the effective target to only count dicts whose archive
        // is actually in CloudKit (.synced).  Dicts that are still .pending
        // on the originating device, .tooLarge, or .error cannot be downloaded.
        let allMetadata = DictMetadataService.shared.loadAll()
        let dictsWithFiles = allMetadata.filter { metadata in
            let dictDir = DictionaryStorageService.shared.dictionaryDirectoryURL(id: metadata.dictId)
            return FileManager.default.fileExists(atPath: dictDir.path)
        }
        categoryStates[.dictionaries]?.current = dictsWithFiles.count

        // Adjust target to only downloadable dicts (avoid stalling on un-uploaded dicts)
        if syncPhase == .downloadingFiles || syncPhase == .complete {
            let downloadableDicts = allMetadata.filter {
                CloudSyncStatus(rawValue: $0.cloudSyncStatus) == .synced
            }
            categoryStates[.dictionaries]?.target = max(
                downloadableDicts.count,
                dictsWithFiles.count
            )
        }

        // Groups: CoreData count
        let groupRequest = NSFetchRequest<NSNumber>(entityName: "DictionaryGroupRecord")
        if let groupCount = try? stack.viewContext.count(for: groupRequest as! NSFetchRequest<NSFetchRequestResult>) {
            categoryStates[.groups]?.current = groupCount
        }

        // Bookmarks: CoreData count
        let bookmarkRequest = NSFetchRequest<NSNumber>(entityName: "BookmarkRecord")
        if let bookmarkCount = try? stack.viewContext.count(for: bookmarkRequest as! NSFetchRequest<NSFetchRequestResult>) {
            categoryStates[.bookmarks]?.current = bookmarkCount
        }

        // Lookup history: CoreData count
        let historyRequest = NSFetchRequest<NSNumber>(entityName: "LookupRecord")
        if let historyCount = try? stack.viewContext.count(for: historyRequest as! NSFetchRequest<NSFetchRequestResult>) {
            categoryStates[.lookupHistory]?.current = historyCount
        }

        debugLog("☁️ CloudSyncProgress: counts — "
                 + "dicts=\(categoryStates[.dictionaries]?.current ?? 0)/\(categoryStates[.dictionaries]?.target ?? 0), "
                 + "groups=\(categoryStates[.groups]?.current ?? 0)/\(categoryStates[.groups]?.target ?? 0), "
                 + "bookmarks=\(categoryStates[.bookmarks]?.current ?? 0)/\(categoryStates[.bookmarks]?.target ?? 0), "
                 + "history=\(categoryStates[.lookupHistory]?.current ?? 0)/\(categoryStates[.lookupHistory]?.target ?? 0)")

        // Reconfigure all visible cells
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(visibleCategories)
        dataSource.apply(snapshot, animatingDifferences: false)

        checkCompletion()
    }

    private func checkCompletion() {
        let allComplete = visibleCategories.allSatisfy { categoryStates[$0]?.isComplete ?? true }
        if allComplete && syncPhase != .complete {
            syncPhase = .complete
            syncMonitor.stop()

            // Update icon to checkmark.icloud
            let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.systemGreen]))
            let image = UIImage(systemName: "checkmark.icloud.fill", withConfiguration: config)
            iconImageView.image = image

            // Update message
            messageLabel.text = L10n.SyncProgress.completeMessage

            // Enable done button
            footerButton.isEnabled = true
            footerButton.configuration?.showsActivityIndicator = false
            footerButton.configuration?.title = L10n.SyncProgress.done
        }
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        onComplete?()
    }
}
