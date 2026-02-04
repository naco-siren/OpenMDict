//
//  DictResourceEditorViewController.swift
//  OpenMDict-iOS
//
//  Third column in Management mode - manage dictionary resources (MDD, CSS, JS).
//  MDX is read-only, MDD/CSS/JS can be added/removed.
//

import UIKit
import UniformTypeIdentifiers

class DictResourceEditorViewController: UIViewController {
    
    // MARK: - Types
    
    nonisolated enum Section: Int, CaseIterable {
        case mdx, mdd, css, js
        
        var title: String {
            switch self {
            case .mdx: return "DICTIONARY FILE (MDX)"
            case .mdd: return "RESOURCE FILES (MDD)"
            case .css: return "CUSTOM STYLES (CSS)"
            case .js: return "CUSTOM SCRIPTS (JS)"
            }
        }
        
        var resourceType: ResourceFile.ResourceType {
            switch self {
            case .mdx: return .mdx
            case .mdd: return .mdd
            case .css: return .css
            case .js: return .js
            }
        }
        
        var allowedUTTypes: [UTType] {
            switch self {
            case .mdx: return []  // Not editable
            case .mdd: return [AppIdentifiers.ResourceType.mdd, .data]
            case .css: return [AppIdentifiers.ResourceType.css]
            case .js: return [AppIdentifiers.ResourceType.js]
            }
        }
    }
    
    nonisolated enum Item: Hashable {
        case resourceFile(ResourceFile)
        case addButton(Section)
        case emptyPlaceholder(Section)
    }
    
    enum Mode: Equatable {
        case empty
        case editing(dictId: String)
    }
    
    // MARK: - State
    
    private var mode: Mode = .empty {
        didSet {
            if oldValue != mode && isViewLoaded {
                reloadData()
            }
        }
    }
    
    private var resources: [ResourceFile] = []
    
    // MARK: - UI
    
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    
    private lazy var emptyStateView: UIView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .thin)
        let image = UIImage(systemName: "doc.badge.gearshape", withConfiguration: config)
        let iv = UIImageView(image: image)
        iv.tintColor = .tertiaryLabel
        iv.contentMode = .scaleAspectFit
        stack.addArrangedSubview(iv)
        
        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.text = "No Dictionary Selected"
        stack.addArrangedSubview(titleLabel)
        
        let subtitleLabel = UILabel()
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .tertiaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = "Select a dictionary to manage its resources"
        stack.addArrangedSubview(subtitleLabel)
        
        stack.setCustomSpacing(24, after: iv)
        
        return stack
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupUI()
        setupCollectionView()
        setupDataSource()
        reloadData()
    }
    
    // MARK: - Setup
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = "Resources"
        
        // Empty state
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
    
    private func setupCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipeActions(for: indexPath)
        }
        
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.delegate = self
        
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    private func setupDataSource() {
        // Cell registration
        let resourceCellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ResourceFile> {
            cell, indexPath, resource in
            
            var content = cell.defaultContentConfiguration()
            content.text = resource.fileName
            content.secondaryText = resource.fileSizeFormatted
            content.secondaryTextProperties.color = .secondaryLabel
            
            // Icon based on type
            let iconName: String
            switch resource.type {
            case .mdx: iconName = "doc.text.fill"
            case .mdd: iconName = "archivebox.fill"
            case .css: iconName = "paintbrush.fill"
            case .js: iconName = "chevron.left.forwardslash.chevron.right"
            }
            content.image = UIImage(systemName: iconName)
            content.imageProperties.tintColor = .systemBlue
            
            cell.contentConfiguration = content
            
            // Lock indicator for MDX (non-removable)
            if !resource.isRemovable {
                let lockImage = UIImageView(image: UIImage(systemName: "lock.fill"))
                lockImage.tintColor = .tertiaryLabel
                let customAccessory = UICellAccessory.customView(
                    configuration: .init(customView: lockImage, placement: .trailing())
                )
                cell.accessories = [customAccessory]
            } else {
                cell.accessories = []
            }
        }
        
        let addButtonRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Section> {
            cell, indexPath, section in
            
            var content = cell.defaultContentConfiguration()
            content.text = "Add \(section.resourceType.fileExtension.uppercased()) File"
            content.textProperties.color = .systemBlue
            content.image = UIImage(systemName: "plus.circle.fill")
            content.imageProperties.tintColor = .systemBlue
            
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        let emptyRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Section> {
            cell, indexPath, section in
            
            var content = cell.defaultContentConfiguration()
            content.text = "No \(section.resourceType.displayName.lowercased())"
            content.textProperties.color = .tertiaryLabel
            content.textProperties.alignment = .center
            
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // Header registration
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { headerView, elementKind, indexPath in
            guard let section = Section(rawValue: indexPath.section) else { return }
            
            var content = headerView.defaultContentConfiguration()
            content.text = section.title
            headerView.contentConfiguration = content
        }
        
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .resourceFile(let resource):
                return collectionView.dequeueConfiguredReusableCell(
                    using: resourceCellRegistration, for: indexPath, item: resource
                )
            case .addButton(let section):
                return collectionView.dequeueConfiguredReusableCell(
                    using: addButtonRegistration, for: indexPath, item: section
                )
            case .emptyPlaceholder(let section):
                return collectionView.dequeueConfiguredReusableCell(
                    using: emptyRegistration, for: indexPath, item: section
                )
            }
        }
        
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }
    
    // MARK: - Data
    
    private func reloadData() {
        switch mode {
        case .empty:
            emptyStateView.isHidden = false
            collectionView.isHidden = true
            resources = []
            
        case .editing(let dictId):
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            resources = DictionaryService.shared.resources(for: dictId)
            applySnapshot()
        }
    }
    
    private func applySnapshot(animated: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        
        for section in Section.allCases {
            let sectionResources = resources.filter { $0.type == section.resourceType }
            
            if sectionResources.isEmpty && section != .mdx {
                // Show empty placeholder + add button (except for MDX)
                snapshot.appendItems([.emptyPlaceholder(section)], toSection: section)
                snapshot.appendItems([.addButton(section)], toSection: section)
            } else {
                // Show resources
                snapshot.appendItems(sectionResources.map { .resourceFile($0) }, toSection: section)
                
                // Add button (except for MDX)
                if section != .mdx {
                    snapshot.appendItems([.addButton(section)], toSection: section)
                }
            }
        }
        
        dataSource.apply(snapshot, animatingDifferences: animated)
    }
    
    // MARK: - Swipe Actions
    
    private func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .resourceFile(let resource) = item,
              resource.isRemovable else {
            return nil
        }
        
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDeleteResource(resource, completion: completion)
        }
        deleteAction.image = UIImage(systemName: "trash")
        
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
    
    // MARK: - Actions
    
    private func handleAddButton(for section: Section) {
        guard case .editing = mode else { return }
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: section.allowedUTTypes)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        
        // Store which section we're adding to
        picker.view.tag = section.rawValue
        
        present(picker, animated: true)
    }
    
    private func confirmDeleteResource(_ resource: ResourceFile, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "Delete Resource?",
            message: "Are you sure you want to delete \(resource.fileName)? This action cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })
        
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteResource(resource)
            completion(true)
        })
        
        present(alert, animated: true)
    }
    
    private func deleteResource(_ resource: ResourceFile) {
        guard case .editing(let dictId) = mode else { return }
        
        do {
            switch resource.type {
            case .mdx:
                break  // Not deletable
            case .mdd:
                try DictionaryService.shared.removeMDD(from: dictId, fileName: resource.fileName)
            case .css:
                try DictionaryService.shared.removeCSS(from: dictId, fileName: resource.fileName)
            case .js:
                try DictionaryService.shared.removeJS(from: dictId, fileName: resource.fileName)
            }
            
            // Reload
            reloadData()
            
        } catch {
            showError(error)
        }
    }
    
    private func addResource(from url: URL, to section: Section) {
        guard case .editing(let dictId) = mode else { return }
        
        Task {
            do {
                switch section {
                case .mdx:
                    break  // Not addable
                case .mdd:
                    _ = try await DictionaryService.shared.addMDD(to: dictId, from: url)
                case .css:
                    _ = try await DictionaryService.shared.addCSS(to: dictId, from: url)
                case .js:
                    _ = try await DictionaryService.shared.addJS(to: dictId, from: url)
                }
                
                // Reload on main thread
                await MainActor.run {
                    reloadData()
                }
                
            } catch {
                await MainActor.run {
                    showError(error)
                }
            }
        }
    }
    
    private func showError(_ error: Error) {
        let alert = UIAlertController(
            title: "Error",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    // MARK: - Public API
    
    /// Show empty state
    func showEmptyState() {
        mode = .empty
    }
    
    /// Show editor for a specific dictionary
    func showEditor(for dictId: String) {
        mode = .editing(dictId: dictId)
    }
}

// MARK: - UICollectionViewDelegate

extension DictResourceEditorViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .addButton(let section):
            handleAddButton(for: section)
        case .resourceFile, .emptyPlaceholder:
            break
        }
    }
}

// MARK: - UIDocumentPickerDelegate

extension DictResourceEditorViewController: UIDocumentPickerDelegate {
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first,
              let section = Section(rawValue: controller.view.tag) else {
            return
        }
        
        addResource(from: url, to: section)
    }
}
