//
//  DictManageListViewController.swift
//  OpenMDict-iOS
//
//  Supplementary column for Management Mode.
//  Displays list of all dictionaries (bundled + imported) with add/delete actions.
//
//  States:
//  - idle: Normal browsing, Import enabled, Delete shows "Delete Dictionaries"
//  - selecting: Multi-select mode, Import disabled, Delete shows "Confirm Deletion"
//  - deleting: Deletion in progress, all interactions disabled, shows spinner
//

import UIKit
import OpenMDictKit

class DictManageListViewController: UIViewController {
    
    // MARK: - State
    
    private enum State {
        case idle
        case selecting
        case deleting
    }
    
    private var currentState: State = .idle {
        didSet { updateUIForState() }
    }
    
    // MARK: - Callbacks
    
    /// Called when user selects a dictionary to edit
    var onDictionarySelected: ((DictionaryManifest.DictionaryEntry?) -> Void)?
    
    /// Called when user taps Import button
    var onAddDictionaryTapped: (() -> Void)?
    
    /// Called when deletion starts/ends - parent can disable sidebar navigation
    var onDeleteStateChanged: ((Bool) -> Void)?
    
    // MARK: - UI Components
    
    private lazy var importButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Import Dictionary"
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 8
        config.cornerStyle = .large
        
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(importButtonTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var deleteButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "Delete Dictionaries"
        config.baseForegroundColor = .systemRed
        config.image = UIImage(systemName: "trash")
        config.imagePadding = 8
        
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(deleteButtonTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
        cv.allowsMultipleSelection = false
        return cv
    }()
    
    private enum Section: Int, CaseIterable {
        case imported
        case bundled
    }
    
    private nonisolated struct DictItem: Hashable {
        let id: String
        let name: String
        let subtitle: String
        let isBundled: Bool
    }
    
    private var dataSource: UICollectionViewDiffableDataSource<Section, DictItem>!
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupNavigationBar()
        setupUI()
        configureDataSource()
        applySnapshot()
        updateUIForState()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
    }
    
    // MARK: - Setup
    
    private func setupNavigationBar() {
        let imageView = UIImageView(image: UIImage(systemName: "square.grid.3x1.folder.fill.badge.plus"))
        imageView.tintColor = .label
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = "Manage Dictionaries"
        label.font = .systemFont(ofSize: 17, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center

        navigationItem.title = nil
        navigationItem.titleView = stack
        navigationItem.largeTitleDisplayMode = .never
    }
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        view.addSubview(importButton)
        view.addSubview(collectionView)
        view.addSubview(deleteButton)
        
        NSLayoutConstraint.activate([
            // Import button at top
            importButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            importButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            importButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            importButton.heightAnchor.constraint(equalToConstant: 50),
            
            // CollectionView in middle
            collectionView.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: deleteButton.topAnchor, constant: -8),
            
            // Delete button at bottom
            deleteButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            deleteButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            deleteButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            deleteButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }
    
    // MARK: - State Management
    
    private func updateUIForState() {
        switch currentState {
        case .idle:
            // Import enabled
            importButton.isEnabled = true
            
            // Delete button: "Delete Dictionaries"
            var config = UIButton.Configuration.plain()
            config.title = "Delete Dictionaries"
            config.baseForegroundColor = .systemRed
            config.image = UIImage(systemName: "trash")
            config.imagePadding = 8
            deleteButton.configuration = config
            deleteButton.isEnabled = hasImportedDictionaries
            
            // Exit multi-selection
            collectionView.allowsMultipleSelection = false
            deselectAllItems()
            
            // Remove cancel button
            navigationItem.leftBarButtonItem = nil
            
            // Re-enable interactions
            view.isUserInteractionEnabled = true
            onDeleteStateChanged?(false)
            
            // Refresh cells (show chevrons)
            reloadVisibleCells()
            
        case .selecting:
            // Import disabled
            importButton.isEnabled = false
            
            // Delete button: "Confirm Deletion"
            var config = UIButton.Configuration.plain()
            config.title = "Confirm Deletion"
            config.baseForegroundColor = .systemRed
            config.image = UIImage(systemName: "trash.fill")
            config.imagePadding = 8
            deleteButton.configuration = config
            deleteButton.isEnabled = true
            
            // Enter multi-selection
            collectionView.allowsMultipleSelection = true
            
            // Add cancel button
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(cancelSelecting)
            )
            
            // Refresh cells (show checkboxes)
            reloadVisibleCells()
            
        case .deleting:
            // Disable everything
            importButton.isEnabled = false
            deleteButton.isEnabled = false
            view.isUserInteractionEnabled = false
            onDeleteStateChanged?(true)
            
            // Show progress indicator
            var config = UIButton.Configuration.plain()
            config.title = "Deleting..."
            config.baseForegroundColor = .secondaryLabel
            config.showsActivityIndicator = true
            deleteButton.configuration = config
        }
    }
    
    private var hasImportedDictionaries: Bool {
        DictionaryService.shared.allDictionaries.contains {
            !DictionaryService.shared.isBundled($0.id)
        }
    }
    
    private func deselectAllItems() {
        collectionView.indexPathsForSelectedItems?.forEach {
            collectionView.deselectItem(at: $0, animated: false)
        }
    }
    
    private func reloadVisibleCells() {
        // Reconfigure all visible cells to update accessories
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    private func updateDeleteButtonTitle() {
        guard currentState == .selecting else { return }
        
        let selectedCount = collectionView.indexPathsForSelectedItems?.count ?? 0
        var config = deleteButton.configuration ?? UIButton.Configuration.plain()
        
        if selectedCount == 0 {
            config.title = "Confirm Deletion"
        } else if selectedCount == 1 {
            config.title = "Delete 1 Dictionary"
        } else {
            config.title = "Delete \(selectedCount) Dictionaries"
        }
        
        deleteButton.configuration = config
    }
    
    // MARK: - Actions
    
    @objc private func importButtonTapped() {
        guard currentState == .idle else { return }
        
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "Quick Import", style: .default) { [weak self] _ in
            self?.onAddDictionaryTapped?()
        })
        
        alert.addAction(UIAlertAction(title: "Manual Import", style: .default) { [weak self] _ in
            self?.onAddDictionaryTapped?()
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = importButton
            popover.sourceRect = importButton.bounds
        }
        
        present(alert, animated: true)
    }
    
    @objc private func deleteButtonTapped() {
        switch currentState {
        case .idle:
            // Enter selecting mode
            currentState = .selecting
            
        case .selecting:
            // Get selected items
            let selectedIndexPaths = collectionView.indexPathsForSelectedItems ?? []
            let selectedItems = selectedIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
                .filter { !$0.isBundled }
            
            if selectedItems.isEmpty {
                // Nothing selected, exit selecting mode
                currentState = .idle
            } else {
                confirmDelete(items: selectedItems)
            }
            
        case .deleting:
            break
        }
    }
    
    @objc private func cancelSelecting() {
        currentState = .idle
    }
    
    // MARK: - Deletion
    
    private func confirmDelete(items: [DictItem]) {
        let names = items.map { $0.name }
        let message: String
        
        if items.count == 1 {
            message = "Are you sure you want to delete \"\(names[0])\"? This action cannot be undone."
        } else {
            let nameList = names.joined(separator: "\n• ")
            message = "Are you sure you want to delete these \(items.count) dictionaries?\n\n• \(nameList)\n\nThis action cannot be undone."
        }
        
        let alert = UIAlertController(
            title: "Delete Dictionaries",
            message: message,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.currentState = .idle
        })
        
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.performDelete(items: items)
        })
        
        present(alert, animated: true)
    }
    
    private func performDelete(items: [DictItem]) {
        currentState = .deleting
        
        Task {
            var failedCount = 0
            
            for item in items {
                do {
                    try DictionaryStorageService.shared.deleteDictionary(id: item.id)
                    DictionaryService.shared.refreshAfterDelete(item.id)
                } catch {
                    print("❌ Failed to delete \(item.name): \(error)")
                    failedCount += 1
                }
            }
            
            // Small delay to show the deleting state
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            
            await MainActor.run {
                applySnapshot()
                currentState = .idle
                
                if failedCount > 0 {
                    showErrorAlert(failedCount: failedCount, totalCount: items.count)
                }
            }
        }
    }
    
    private func showErrorAlert(failedCount: Int, totalCount: Int) {
        let message = failedCount == totalCount
            ? "Failed to delete dictionaries."
            : "Some dictionaries could not be deleted (\(failedCount) of \(totalCount) failed)."
        
        let alert = UIAlertController(
            title: "Error",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, DictItem> {
            [weak self] cell, indexPath, item in
            guard let self = self else { return }
            
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.name
            content.secondaryText = item.subtitle
            content.image = UIImage(systemName: item.isBundled ? "book.closed" : "book")
            content.imageProperties.tintColor = item.isBundled ? .secondaryLabel : .systemBlue
            
            cell.contentConfiguration = content
            
            // Configure accessories based on state
            switch self.currentState {
            case .idle:
                cell.accessories = [.disclosureIndicator()]
                cell.contentView.alpha = 1.0
                
            case .selecting, .deleting:
                if item.isBundled {
                    // Bundled dictionaries can't be deleted
                    cell.accessories = []
                    cell.contentView.alpha = 0.4
                } else {
                    // Show checkbox for imported dictionaries
                    cell.accessories = [.multiselect(displayed: .always)]
                    cell.contentView.alpha = 1.0
                }
            }
        }
        
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { supplementaryView, elementKind, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = indexPath.section == Section.imported.rawValue
                ? "Imported Dictionaries"
                : "Bundled Dictionaries"
            supplementaryView.contentConfiguration = content
        }
        
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
        
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }
    
    private func applySnapshot() {
        let service = DictionaryService.shared
        
        var importedItems: [DictItem] = []
        var bundledItems: [DictItem] = []
        
        for dict in service.allDictionaries {
            let name = dict.metadata?.title ?? dict.id
            let entryCount = dict.metadata?.entryCount
            let subtitle = entryCount.map { "\($0) entries" } ?? ""
            
            let item = DictItem(
                id: dict.id,
                name: name,
                subtitle: subtitle,
                isBundled: service.isBundled(dict.id)
            )
            
            if service.isBundled(dict.id) {
                bundledItems.append(item)
            } else {
                importedItems.append(item)
            }
        }
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, DictItem>()
        
        if !importedItems.isEmpty {
            snapshot.appendSections([.imported])
            snapshot.appendItems(importedItems, toSection: .imported)
        }
        
        if !bundledItems.isEmpty {
            snapshot.appendSections([.bundled])
            snapshot.appendItems(bundledItems, toSection: .bundled)
        }
        
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    // MARK: - Public API
    
    func reloadData() {
        applySnapshot()
    }
    
    private func manifestEntry(for dictId: String) -> DictionaryManifest.DictionaryEntry? {
        DictionaryStorageService.shared.manifest.dictionary(id: dictId)
    }
}

// MARK: - UICollectionViewDelegate

extension DictManageListViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        
        switch currentState {
        case .idle:
            return true
        case .selecting:
            // Only allow selecting imported dictionaries for deletion
            return !item.isBundled
        case .deleting:
            return false
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch currentState {
        case .idle:
            // Navigate to edit/view dictionary
            collectionView.deselectItem(at: indexPath, animated: true)
            let entry = item.isBundled ? nil : manifestEntry(for: item.id)
            onDictionarySelected?(entry)
            
        case .selecting:
            // Multi-select mode - update button title
            updateDeleteButtonTitle()
            
        case .deleting:
            break
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if currentState == .selecting {
            updateDeleteButtonTitle()
        }
    }
}
