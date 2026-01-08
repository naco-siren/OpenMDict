//
//  DictionaryListViewController.swift
//  OpenMDict-iOS
//
//  Primary column: sidebar with dictionaries + fixed footer
//
//  Layout:
//  ┌─────────────────────────┐
//  │  Dictionaries (header)  │
//  │  ┌───────────────────┐  │
//  │  │ 📖 Dict A      📌 │  │  ← scrollable
//  │  │ 📕 Dict B         │  │
//  │  │ 📖 Dict C      📌 │  │
//  │  └───────────────────┘  │
//  ├─────────────────────────┤
//  │  📚 Dictionary Mgmt     │  ← fixed
//  │  ⚙️ App Settings        │  ← fixed
//  └─────────────────────────┘
//

import UIKit

class DictionaryListViewController: UIViewController {
    
    // MARK: - Callback
    
    var onDictionarySelected: ((DictionaryItem) -> Void)?
    
    // MARK: - Data
    
    private var dictionaries: [DictionaryItem] = DictionaryItem.mockData
    private var selectedId: String?
    
    private var dataSource: UICollectionViewDiffableDataSource<Int, DictionaryItem>!
    
    // MARK: - UI
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActionsForItem(at: indexPath)
        }
        
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
        cv.dragDelegate = self
        cv.dropDelegate = self
        cv.dragInteractionEnabled = true
        return cv
    }()
    
    private lazy var footerStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        return stack
    }()
    
    private lazy var managementButton: UIButton = {
        createFooterButton(
            title: "Dictionary Management",
            icon: "books.vertical",
            action: #selector(managementTapped)
        )
    }()
    
    private lazy var settingsButton: UIButton = {
        createFooterButton(
            title: "App Settings",
            icon: "gearshape",
            action: #selector(settingsTapped)
        )
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "OpenMDict"
        navigationController?.navigationBar.prefersLargeTitles = true
        
        setupUI()
        configureDataSource()
        applySnapshot(animated: false)
        
        // Auto-select first dictionary
        if let first = dictionaries.first {
            selectedId = first.id
            onDictionarySelected?(first)
        }
    }
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        // Footer
        footerStack.addArrangedSubview(createSeparator())
        footerStack.addArrangedSubview(managementButton)
        footerStack.addArrangedSubview(settingsButton)
        view.addSubview(footerStack)
        
        // Collection view
        view.addSubview(collectionView)
        
        NSLayoutConstraint.activate([
            footerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: footerStack.topAnchor),
        ])
    }
    
    private func createFooterButton(title: String, icon: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: icon)
        config.imagePadding = 12
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        config.baseForegroundColor = .label
        
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
    
    private func createSeparator() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return view
    }
    
    // MARK: - Footer Actions (Stubs)
    
    @objc private func managementTapped() {
        print("📚 Dictionary Management tapped - TODO: implement")
    }
    
    @objc private func settingsTapped() {
        print("⚙️ App Settings tapped - TODO: implement")
    }
    
    // MARK: - Swipe Actions
    
    private func swipeActionsForItem(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        
        let pinAction = UIContextualAction(
            style: .normal,
            title: item.isPinned ? "Unpin" : "Pin"
        ) { [weak self] _, _, completion in
            self?.togglePin(item)
            completion(true)
        }
        pinAction.image = UIImage(systemName: item.isPinned ? "pin.slash" : "pin")
        pinAction.backgroundColor = .systemOrange
        
        return UISwipeActionsConfiguration(actions: [pinAction])
    }
    
    private func togglePin(_ item: DictionaryItem) {
        guard let index = dictionaries.firstIndex(where: { $0.id == item.id }) else { return }
        dictionaries[index].isPinned.toggle()
        print("📌 \(item.name) is now \(dictionaries[index].isPinned ? "pinned" : "unpinned") - TODO: persist")
        applySnapshot(animated: true)
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        // Cell registration
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, DictionaryItem> {
            [weak self] (cell: UICollectionViewListCell, indexPath: IndexPath, item: DictionaryItem) in
            
            var content = cell.defaultContentConfiguration()
            content.text = item.name
            content.secondaryText = "\(item.entryCount.formatted()) entries"
            
            // Leading icon: loaded state
            content.image = UIImage(systemName: item.isLoaded ? "book.fill" : "book.closed")
            content.imageProperties.tintColor = item.isLoaded ? .systemBlue : .secondaryLabel
            
            cell.contentConfiguration = content
            
            // Trailing accessories
            var accessories: [UICellAccessory] = []
            
            // Pin indicator
            if item.isPinned {
                let pinConfig = UICellAccessory.CustomViewConfiguration(
                    customView: UIImageView(image: UIImage(systemName: "pin.fill")),
                    placement: .trailing(displayed: .always)
                )
                accessories.append(.customView(configuration: pinConfig))
            }
            
            // Selection indicator
            if item.id == self?.selectedId {
                accessories.append(.checkmark())
            }
            
            cell.accessories = accessories
        }
        
        // Header registration
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { (headerView: UICollectionViewListCell, elementKind: String, indexPath: IndexPath) in
            var content = headerView.defaultContentConfiguration()
            content.text = "Dictionaries"
            headerView.contentConfiguration = content
        }
        
        // Create data source
        dataSource = UICollectionViewDiffableDataSource<Int, DictionaryItem>(
            collectionView: collectionView
        ) { (collectionView: UICollectionView, indexPath: IndexPath, item: DictionaryItem) -> UICollectionViewCell? in
            return collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: item
            )
        }
        
        dataSource.supplementaryViewProvider = {
            (collectionView: UICollectionView, kind: String, indexPath: IndexPath) -> UICollectionReusableView? in
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        
        // Enable reordering
        dataSource.reorderingHandlers.canReorderItem = { _ in true }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            // Update our backing store
            if let updatedItems = self?.dictionaries.applying(transaction.difference) {
                self?.dictionaries = updatedItems
                print("📋 Dictionaries reordered - TODO: persist order")
            }
        }
    }
    
    // MARK: - Snapshot
    
    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, DictionaryItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(dictionaries, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }
}

// MARK: - UICollectionViewDelegate

extension DictionaryListViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        // Toggle loaded state if tapping already-selected item
        if item.id == selectedId {
            toggleLoaded(item)
            return
        }
        
        // Select new item
        selectedId = item.id
        
        // Auto-load if not loaded
        if !item.isLoaded {
            if let index = dictionaries.firstIndex(where: { $0.id == item.id }) {
                dictionaries[index].isLoaded = true
                print("📖 \(item.name) loaded - TODO: actually load")
            }
        }
        
        applySnapshot(animated: false)
        onDictionarySelected?(item)
    }
    
    private func toggleLoaded(_ item: DictionaryItem) {
        guard let index = dictionaries.firstIndex(where: { $0.id == item.id }) else { return }
        dictionaries[index].isLoaded.toggle()
        let loaded = dictionaries[index].isLoaded
        print("\(loaded ? "📖" : "📕") \(item.name) \(loaded ? "loaded" : "unloaded") - TODO: actually \(loaded ? "load" : "unload")")
        applySnapshot(animated: true)
    }
}

// MARK: - UICollectionViewDragDelegate

extension DictionaryListViewController: UICollectionViewDragDelegate {
    
    func collectionView(_ collectionView: UICollectionView,
                        itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let itemProvider = NSItemProvider(object: item.id as NSString)
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = item
        return [dragItem]
    }
}

// MARK: - UICollectionViewDropDelegate

extension DictionaryListViewController: UICollectionViewDropDelegate {
    
    func collectionView(_ collectionView: UICollectionView,
                        dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        if session.localDragSession != nil {
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        return UICollectionViewDropProposal(operation: .forbidden)
    }
    
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        // Handled by dataSource.reorderingHandlers
    }
}
