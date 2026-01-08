//
//  DictionaryListViewController.swift
//  OpenMDict-iOS
//
//  Primary column: dictionary list with modern sidebar style
//
//  Uses:
//  - UICollectionViewCompositionalLayout.list(using: .sidebar)
//  - UICollectionViewDiffableDataSource
//  - UICollectionView.CellRegistration
//

import UIKit

class DictionaryListViewController: UIViewController {
    
    // MARK: - Types
    
    enum Section: Int, Hashable, CaseIterable, Sendable {
        case loaded
        case available
        
        var title: String {
            switch self {
            case .loaded: return "Loaded"
            case .available: return "Available"
            }
        }
    }
    
    // MARK: - Callback
    
    var onDictionarySelected: ((DictionaryItem) -> Void)?
    
    // MARK: - Data
    
    private var dictionaries: [DictionaryItem] = DictionaryItem.mockData
    private var selectedId: String?
    
    private var dataSource: UICollectionViewDiffableDataSource<Section, DictionaryItem>!
    
    // MARK: - UI
    
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout.list(using: createListConfiguration())
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
        return cv
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Dictionaries"
        navigationController?.navigationBar.prefersLargeTitles = true
        
        setupUI()
        configureDataSource()
        applySnapshot(animated: false)
        
        // Auto-select first loaded dictionary
        if let first = dictionaries.first(where: { $0.isLoaded }) {
            selectedId = first.id
            onDictionarySelected?(first)
        }
    }
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(collectionView)
        
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        setupToolbar()
    }
    
    private func setupToolbar() {
        let addButton = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addDictionaryTapped)
        )
        addButton.accessibilityLabel = "Import Dictionary"
        
        navigationItem.rightBarButtonItem = addButton
    }
    
    @objc private func addDictionaryTapped() {
        // TODO: Show document picker for .mdx files
        print("Import dictionary tapped")
    }
    
    // MARK: - List Configuration
    
    private func createListConfiguration() -> UICollectionLayoutListConfiguration {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
        
        config.headerMode = .supplementary
        
        // Swipe actions
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self = self,
                  let item = self.dataSource.itemIdentifier(for: indexPath) else {
                return nil
            }
            
            let deleteAction = UIContextualAction(style: .destructive, title: "Remove") { _, _, completion in
                self.removeDictionary(item)
                completion(true)
            }
            deleteAction.image = UIImage(systemName: "trash")
            
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }
        
        return config
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        // Cell registration
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, DictionaryItem> {
            [weak self] (cell: UICollectionViewListCell, indexPath: IndexPath, item: DictionaryItem) in
            
            var content = cell.defaultContentConfiguration()
            content.text = item.name
            content.secondaryText = "\(item.entryCount.formatted()) entries"
            content.image = UIImage(systemName: item.isLoaded ? "book.fill" : "book.closed")
            content.imageProperties.tintColor = item.isLoaded ? .systemBlue : .secondaryLabel
            
            cell.contentConfiguration = content
            
            // Selection indicator
            if item.id == self?.selectedId {
                cell.accessories = [.checkmark()]
            } else {
                cell.accessories = []
            }
        }
        
        // Header registration
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { (headerView: UICollectionViewListCell, elementKind: String, indexPath: IndexPath) in
            guard let section = Section(rawValue: indexPath.section) else { return }
            
            var content = headerView.defaultContentConfiguration()
            content.text = section.title
            headerView.contentConfiguration = content
        }
        
        // Create data source
        dataSource = UICollectionViewDiffableDataSource<Section, DictionaryItem>(
            collectionView: collectionView
        ) { (collectionView: UICollectionView, indexPath: IndexPath, item: DictionaryItem) -> UICollectionViewCell? in
            return collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: item
            )
        }
        
        // Supplementary view provider
        dataSource.supplementaryViewProvider = {
            (collectionView: UICollectionView, kind: String, indexPath: IndexPath) -> UICollectionReusableView? in
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
    }
    
    // MARK: - Snapshot
    
    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, DictionaryItem>()
        
        let loaded = dictionaries.filter { $0.isLoaded }
        let available = dictionaries.filter { !$0.isLoaded }
        
        if !loaded.isEmpty {
            snapshot.appendSections([.loaded])
            snapshot.appendItems(loaded, toSection: .loaded)
        }
        
        if !available.isEmpty {
            snapshot.appendSections([.available])
            snapshot.appendItems(available, toSection: .available)
        }
        
        dataSource.apply(snapshot, animatingDifferences: animated)
    }
    
    // MARK: - Actions
    
    private func removeDictionary(_ item: DictionaryItem) {
        dictionaries.removeAll { $0.id == item.id }
        applySnapshot(animated: true)
    }
}

// MARK: - UICollectionViewDelegate

extension DictionaryListViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        // If not loaded, load it first
        if !item.isLoaded {
            // Update the item to be loaded
            if let index = dictionaries.firstIndex(where: { $0.id == item.id }) {
                dictionaries[index].isLoaded = true
                applySnapshot(animated: true)
            }
        }
        
        selectedId = item.id
        applySnapshot(animated: false)  // Refresh to update checkmark
        onDictionarySelected?(item)
    }
    
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []
            
            if item.isLoaded {
                let unloadAction = UIAction(
                    title: "Unload",
                    image: UIImage(systemName: "arrow.down.circle")
                ) { _ in
                    self?.toggleLoaded(item)
                }
                actions.append(unloadAction)
            } else {
                let loadAction = UIAction(
                    title: "Load",
                    image: UIImage(systemName: "arrow.up.circle")
                ) { _ in
                    self?.toggleLoaded(item)
                }
                actions.append(loadAction)
            }
            
            let infoAction = UIAction(
                title: "Info",
                image: UIImage(systemName: "info.circle")
            ) { _ in
                self?.showInfo(for: item)
            }
            actions.append(infoAction)
            
            let removeAction = UIAction(
                title: "Remove",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self?.removeDictionary(item)
            }
            actions.append(removeAction)
            
            return UIMenu(children: actions)
        }
    }
    
    private func toggleLoaded(_ item: DictionaryItem) {
        if let index = dictionaries.firstIndex(where: { $0.id == item.id }) {
            dictionaries[index].isLoaded.toggle()
            applySnapshot(animated: true)
        }
    }
    
    private func showInfo(for item: DictionaryItem) {
        let alert = UIAlertController(
            title: item.name,
            message: "Entries: \(item.entryCount.formatted())\nStatus: \(item.isLoaded ? "Loaded" : "Not loaded")",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
