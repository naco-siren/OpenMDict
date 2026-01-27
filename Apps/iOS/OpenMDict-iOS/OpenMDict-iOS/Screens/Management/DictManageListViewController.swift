//
//  DictManageListViewController.swift
//  OpenMDict-iOS
//
//  Supplementary column for Management Mode.
//  Displays list of all dictionaries (bundled + imported) with add/delete actions.
//

import UIKit
import OpenMDictKit

class DictManageListViewController: UIViewController {
    
    // MARK: - Callbacks (matching MainSplitViewController expectations)
    
    /// Called when user selects a dictionary to edit
    var onDictionarySelected: ((DictionaryManifest.DictionaryEntry?) -> Void)?
    
    /// Called when user taps + button to add new dictionary
    var onAddDictionaryTapped: (() -> Void)?
    
    // MARK: - UI
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipeActions(for: indexPath)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
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
        
        // Add button in nav bar
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addButtonTapped)
        )
        
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        configureDataSource()
        applySnapshot()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh list when appearing (e.g., after import)
        applySnapshot()
    }
    
    // MARK: - Actions
    
    @objc private func addButtonTapped() {
        showImportOptions()
    }
    
    private func showImportOptions() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "Quick Import", style: .default) { [weak self] _ in
            self?.onAddDictionaryTapped?()
        })
        
        alert.addAction(UIAlertAction(title: "Manual Import", style: .default) { [weak self] _ in
            self?.onAddDictionaryTapped?()
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        // For iPad
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        
        present(alert, animated: true)
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, DictItem> {
            cell, indexPath, item in
            
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.name
            content.secondaryText = item.subtitle
            content.image = UIImage(systemName: item.isBundled ? "book.closed" : "book")
            content.imageProperties.tintColor = item.isBundled ? .secondaryLabel : .systemBlue
            
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
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
        
        // Build items
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
        
        // Only add sections if they have items
        if !importedItems.isEmpty {
            snapshot.appendSections([.imported])
            snapshot.appendItems(importedItems, toSection: .imported)
        }
        
        if !bundledItems.isEmpty {
            snapshot.appendSections([.bundled])
            snapshot.appendItems(bundledItems, toSection: .bundled)
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    // MARK: - Swipe Actions
    
    private func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              !item.isBundled else {
            // Bundled dictionaries cannot be deleted
            return nil
        }
        
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") {
            [weak self] _, _, completion in
            self?.confirmDelete(item: item)
            completion(true)
        }
        deleteAction.image = UIImage(systemName: "trash")
        
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
    
    private func confirmDelete(item: DictItem) {
        let alert = UIAlertController(
            title: "Delete Dictionary",
            message: "Are you sure you want to delete \"\(item.name)\"? This action cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteDictionary(id: item.id)
        })
        
        present(alert, animated: true)
    }
    
    private func deleteDictionary(id: String) {
        Task {
            do {
                try DictionaryStorageService.shared.deleteDictionary(id: id)
                DictionaryService.shared.refreshAfterDelete(id)
                applySnapshot()
            } catch {
                print("❌ Failed to delete dictionary: \(error)")
            }
        }
    }
    
    // MARK: - Public API
    
    /// Refresh the list (called after import/delete)
    func reloadData() {
        applySnapshot()
    }
    
    /// Get manifest entry for a dictionary ID
    private func manifestEntry(for dictId: String) -> DictionaryManifest.DictionaryEntry? {
        DictionaryStorageService.shared.manifest.dictionary(id: dictId)
    }
}

// MARK: - UICollectionViewDelegate

extension DictManageListViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        // For bundled dictionaries, pass nil (they have limited editing)
        // For imported dictionaries, pass the manifest entry
        let entry = item.isBundled ? nil : manifestEntry(for: item.id)
        onDictionarySelected?(entry)
    }
}
