//
//  DictResourceEditorViewController.swift
//  OpenMDict-iOS
//
//  Third column in Management mode - manage dictionary resources (MDD, CSS, JS).
//  MDX is read-only, MDD/CSS/JS can be added/removed.
//

import UIKit
import UniformTypeIdentifiers
import Combine

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
            case .mdd: return [AppIdentifiers.ResourceType.mdd]
            case .css: return [AppIdentifiers.ResourceType.css]
            case .js: return [AppIdentifiers.ResourceType.js]
            }
        }
    }
    
    nonisolated enum Item: Hashable {
        case resourceFile(ResourceFile)
        case addButton(Section)
        case emptyPlaceholder(Section)
        case pendingFile(PendingFile)  // For importing mode
    }
    
    enum Mode: Equatable {
        case empty
        case editing(dictId: String)    // Editing an imported dictionary
        case importing(dictId: String)  // Importing a new dictionary (dictId = headerSHA256)
    }
    
    // MARK: - State
    
    private var mode: Mode = .empty {
        didSet {
            debugLog("📋 ResourceEditor: mode changed from \(oldValue) to \(mode), isViewLoaded=\(isViewLoaded)")
            if oldValue != mode && isViewLoaded {
                reloadData()
            }
        }
    }
    
    private var resources: [ResourceFile] = []
    
    // MARK: - Combine
    
    private var cancellables = Set<AnyCancellable>()
    
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
        
        debugLog("📋 ResourceEditor: viewDidLoad, current mode=\(mode)")
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
        
        // Pending file cell (for importing mode) - uses outlined icons to indicate "not yet imported"
        let pendingFileRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, PendingFile> {
            cell, indexPath, file in
            
            var content = cell.defaultContentConfiguration()
            content.text = file.fileName
            content.secondaryText = ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
            
            // Icon based on section - use OUTLINED variants (not .fill) for pending files
            let section = Section(rawValue: indexPath.section) ?? .mdx
            let iconName: String
            switch section {
            case .mdx: iconName = "doc"              // outlined, vs "doc.fill" for stored
            case .mdd: iconName = "archivebox"       // outlined
            case .css: iconName = "paintbrush"       // outlined
            case .js: iconName = "chevron.left.forwardslash.chevron.right"  // no fill variant
            }
            content.image = UIImage(systemName: iconName)
            content.imageProperties.tintColor = .systemBlue  // Same blue as stored files
            
            cell.contentConfiguration = content
            
            // MDX is not removable, others are
            if section == .mdx {
                let lockImage = UIImageView(image: UIImage(systemName: "lock.fill"))
                lockImage.tintColor = .tertiaryLabel
                cell.accessories = [.customView(configuration: .init(customView: lockImage, placement: .trailing()))]
            } else {
                cell.accessories = []
            }
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
            case .pendingFile(let file):
                return collectionView.dequeueConfiguredReusableCell(
                    using: pendingFileRegistration, for: indexPath, item: file
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
            cancellables.removeAll()
            
        case .editing(let dictId):
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            resources = DictionaryService.shared.resources(for: dictId)
            cancellables.removeAll()
            applySnapshot()
            
        case .importing:
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            resources = []
            setupImportSessionSubscriptions()
            applyImportingSnapshot()
        }
    }
    
    private func setupImportSessionSubscriptions() {
        cancellables.removeAll()
        
        let session = DictionaryService.shared.importSession
        
        // Subscribe to all pending file changes
        Publishers.CombineLatest4(
            session.$mdxPendingFile,
            session.$pendingMDDFiles,
            session.$pendingCSSFiles,
            session.$pendingJSFiles
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in
            self?.applyImportingSnapshot()
        }
        .store(in: &cancellables)
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
    
    /// Apply snapshot for importing mode - shows pending files from ImportSession
    private func applyImportingSnapshot(animated: Bool = false) {
        let session = DictionaryService.shared.importSession
        
        print("📋 applyImportingSnapshot: mdxPendingFile=\(session.mdxPendingFile?.fileName ?? "nil"), MDD=\(session.pendingMDDFiles.count), CSS=\(session.pendingCSSFiles.count), JS=\(session.pendingJSFiles.count)")
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        
        // MDX section - show pending MDX if available
        if let mdxFile = session.mdxPendingFile {
            snapshot.appendItems([.pendingFile(mdxFile)], toSection: .mdx)
        } else {
            snapshot.appendItems([.emptyPlaceholder(.mdx)], toSection: .mdx)
        }
        
        // MDD section
        if session.pendingMDDFiles.isEmpty {
            snapshot.appendItems([.emptyPlaceholder(.mdd)], toSection: .mdd)
        } else {
            snapshot.appendItems(session.pendingMDDFiles.map { .pendingFile($0) }, toSection: .mdd)
        }
        snapshot.appendItems([.addButton(.mdd)], toSection: .mdd)
        
        // CSS section
        if session.pendingCSSFiles.isEmpty {
            snapshot.appendItems([.emptyPlaceholder(.css)], toSection: .css)
        } else {
            snapshot.appendItems(session.pendingCSSFiles.map { .pendingFile($0) }, toSection: .css)
        }
        snapshot.appendItems([.addButton(.css)], toSection: .css)
        
        // JS section
        if session.pendingJSFiles.isEmpty {
            snapshot.appendItems([.emptyPlaceholder(.js)], toSection: .js)
        } else {
            snapshot.appendItems(session.pendingJSFiles.map { .pendingFile($0) }, toSection: .js)
        }
        snapshot.appendItems([.addButton(.js)], toSection: .js)
        
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
        // Allow adding in both editing and importing modes
        switch mode {
        case .empty:
            return
        case .editing, .importing:
            break
        }
        
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
        switch mode {
        case .empty:
            return
            
        case .editing(let dictId):
            // Editing mode: copy file to storage immediately
            // Show loading modal on the presenting view controller
            let presentingVC = view.window?.rootViewController
            let loadingVC = presentingVC?.showLoadingModal(message: "Adding resource...")
            
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
                        presentingVC?.hideLoadingModal(loadingVC)
                        reloadData()
                    }
                    
                } catch {
                    await MainActor.run {
                        presentingVC?.hideLoadingModal(loadingVC)
                        showError(error)
                    }
                }
            }
            
        case .importing:
            // Importing mode: add to ImportSession (will be copied on import)
            // IMPORTANT: Create PendingFile while security scope is active to capture bookmark
            let hasAccess = url.startAccessingSecurityScopedResource()
            debugLog("📋 addResource: url=\(url.lastPathComponent), hasAccess=\(hasAccess)")
            
            // Get file size while we have access
            var fileSize: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                fileSize = size
                print("📋 addResource: fileSize=\(fileSize)")
            } else {
                print("⚠️ addResource: failed to get file size for \(url.path)")
            }
            
            // Add to session (PendingFile.init will capture bookmark while scope is active)
            let session = DictionaryService.shared.importSession
            switch section {
            case .mdx:
                break  // Not addable (MDX is set via DictInfoVC)
            case .mdd:
                session.addMDD(url, fileSize: fileSize)
            case .css:
                session.addCSS(url, fileSize: fileSize)
            case .js:
                session.addJS(url, fileSize: fileSize)
            }
            
            // Now safe to close security scope
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
            // Note: applyImportingSnapshot() will be called automatically via Combine subscription
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
    /// Automatically determines if we're editing (imported dict) or importing (pending dict)
    func showEditor(for dictId: String) {
        // Check if this dictId corresponds to an already-imported dictionary
        if DictionaryService.shared.dict(id: dictId) != nil {
            // Imported dictionary - use editing mode
            print("📋 ResourceEditor: showEditor(\(dictId.prefix(8))...) -> editing mode")
            mode = .editing(dictId: dictId)
        } else {
            // Not imported yet - use importing mode (dictId = headerSHA256 from ImportSession)
            print("📋 ResourceEditor: showEditor(\(dictId.prefix(8))...) -> importing mode")
            mode = .importing(dictId: dictId)
        }
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
        case .resourceFile, .emptyPlaceholder, .pendingFile:
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
