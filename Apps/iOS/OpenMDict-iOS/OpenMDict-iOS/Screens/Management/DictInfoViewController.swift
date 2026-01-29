//
//  DictInfoViewController.swift
//  OpenMDict-iOS
//
//  Dictionary configuration view controller.
//  Shows dictionary info form for Import or Edit mode.
//
//  Navigation:
//  - Regular mode: Manual close button (split view columns side-by-side, no system back)
//  - Compact mode: System back button (split view collapsed, use backAction to intercept)
//  - Done: System .done button, enabled only when hasUnsavedChanges
//
//  Behavior:
//  - No changes: Back/Close navigates away directly
//  - Has changes: Back/Close shows discard alert, Done shows save/import alert
//
//  Compact mode only: "Manage Resources" row to push DictResourceEditorVC
//

import UIKit
import UniformTypeIdentifiers
import OpenMDictKit

// MARK: - State

enum DictConfigMode: Equatable {
    case empty              // No dictionary - prompt to select file
    case importing          // File selected, showing preview
    case editing(dictId: String)  // Editing existing dictionary
}

// MARK: - View Controller

class DictInfoViewController: UIViewController {
    
    // MARK: - Callbacks
    
    var onDismiss: (() -> Void)?
    var onImportComplete: ((String) -> Void)?
    var onDeleteComplete: ((String) -> Void)?
    
    /// Callback to push resource editor in compact mode
    var onManageResources: ((String) -> Void)?
    
    // MARK: - State
    
    private(set) var currentMode: DictConfigMode = .empty {
        didSet {
            if isViewLoaded {
                updateUI()
            }
        }
    }
    
    /// Tracks if user has made changes that need saving
    private var hasUnsavedChanges: Bool = false {
        didSet {
            updateDoneButtonState()
        }
    }
    
    /// Selected MDX file URL (for import mode)
    private var selectedMDXURL: URL?
    
    /// Current dictionary ID (for edit mode)
    private var currentDictId: String?
    
    /// Edited display name (tracks changes)
    private var editedDisplayName: String?
    
    // MARK: - UI
    
    private enum Section: Int, CaseIterable {
        case fileSelection   // Import mode: "Select MDX File" button
        case metadata        // Title, description (from MDX header)
        case displayName     // Editable display name
        case resources       // "Manage Resources" (compact mode only)
        case actions         // Delete button (edit mode only)
    }
    
    private nonisolated enum Item: Hashable {
        case selectFile
        case metadataTitle(String)
        case metadataDescription(String)
        case displayNameField(String)
        case manageResources
        case deleteButton
    }
    
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
        cv.backgroundColor = .systemGroupedBackground
        return cv
    }()
    
    private lazy var emptyStateView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        
        let imageView = UIImageView(image: UIImage(systemName: "doc.badge.plus"))
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = .init(pointSize: 60)
        
        let label = UILabel()
        label.text = "Select an MDX file to import\na new dictionary"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        
        let button = UIButton(type: .system)
        button.setTitle("Select MDX File", for: .normal)
        button.setImage(UIImage(systemName: "folder"), for: .normal)
        button.addTarget(self, action: #selector(selectFileTapped), for: .touchUpInside)
        
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        
        return view
    }()
    
    // MARK: - Navigation Items
    
    /// System Done button (enabled only when hasUnsavedChanges)
    private lazy var doneButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
        button.isEnabled = false
        return button
    }()
    
    /// Check if split view is collapsed (compact mode)
    /// More reliable than checking own traitCollection, which may be incorrect
    /// when embedded in a navigation controller inside split view column
    private var isSplitViewCollapsed: Bool {
        // Walk up the parent chain to find the split view
        var vc: UIViewController? = self
        while let current = vc {
            if let splitVC = current as? UISplitViewController {
                return splitVC.isCollapsed
            }
            vc = current.parent
        }
        // Fallback: assume collapsed if trait collection is compact
        return traitCollection.horizontalSizeClass == .compact
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemGroupedBackground
        
        view.addSubview(collectionView)
        view.addSubview(emptyStateView)
        
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        // Setup backAction for iOS 16+ (intercepts system back button in compact mode)
        if #available(iOS 16.0, *) {
            navigationItem.backAction = UIAction { [weak self] _ in
                self?.handleBackNavigation()
            }
        }
        
        configureDataSource()
        updateUI()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        updateLeftBarButton()
    }
    
    @objc private func closeButtonTapped() {
        handleBackNavigation()
    }
    
    /// Update left bar button based on size class
    /// - Regular mode: Show close button (no system back in side-by-side columns)
    /// - Compact mode: No custom button (system provides back button, intercepted by backAction on iOS 16+)
    private func updateLeftBarButton() {
        let isCollapsed = isSplitViewCollapsed
        debugLog("📋 updateLeftBarButton: isSplitViewCollapsed=\(isCollapsed)")
        
        if !isCollapsed {
            // Regular mode: columns side by side, need manual close button
            let closeButton = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(closeButtonTapped)
            )
            navigationItem.leftBarButtonItem = closeButton
        } else {
            // Compact mode: split view collapsed, system provides back button
            navigationItem.leftBarButtonItem = nil
        }
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        // Note: In split view supplementary column, horizontalSizeClass is always .compact
        // So we can't rely on it to detect split view collapse. Instead use viewWillLayoutSubviews.
    }
    
    /// Track previous collapsed state to detect changes
    private var previousIsCollapsed: Bool?
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        // Detect split view collapsed state changes
        let isCollapsed = isSplitViewCollapsed
        if previousIsCollapsed != isCollapsed {
            debugLog("📋 viewWillLayoutSubviews: isCollapsed changed from \(previousIsCollapsed?.description ?? "nil") to \(isCollapsed)")
            previousIsCollapsed = isCollapsed
            
            updateLeftBarButton()
            applyCurrentSnapshot()  // Show/hide "Manage Resources"
        }
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        // Select File Cell
        let selectFileReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Select MDX File"
            content.image = UIImage(systemName: "doc.badge.plus")
            content.imageProperties.tintColor = .systemBlue
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        
        // Metadata Cell (read-only)
        let metadataReg = UICollectionView.CellRegistration<UICollectionViewListCell, (String, String)> { cell, indexPath, tuple in
            let (label, value) = tuple
            var content = UIListContentConfiguration.valueCell()
            content.text = label
            content.secondaryText = value.isEmpty ? "—" : value
            content.secondaryTextProperties.color = value.isEmpty ? .tertiaryLabel : .label
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // Display Name Cell (editable)
        let displayNameReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, indexPath, value in
            var content = UIListContentConfiguration.valueCell()
            content.text = "Display Name"
            content.secondaryText = value.isEmpty ? "Enter name..." : value
            content.secondaryTextProperties.color = value.isEmpty ? .placeholderText : .label
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        
        // Manage Resources Cell (compact mode only)
        let manageResourcesReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Manage Resources"
            content.image = UIImage(systemName: "doc.badge.gearshape")
            content.imageProperties.tintColor = .systemBlue
            content.secondaryText = "CSS, fonts, and more"
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        
        // Delete Button Cell
        let deleteReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Delete Dictionary"
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .selectFile:
                return collectionView.dequeueConfiguredReusableCell(using: selectFileReg, for: indexPath, item: ())
                
            case .metadataTitle(let value):
                return collectionView.dequeueConfiguredReusableCell(using: metadataReg, for: indexPath, item: ("Title", value))
                
            case .metadataDescription(let value):
                return collectionView.dequeueConfiguredReusableCell(using: metadataReg, for: indexPath, item: ("Description", value))
                
            case .displayNameField(let value):
                return collectionView.dequeueConfiguredReusableCell(using: displayNameReg, for: indexPath, item: value)
                
            case .manageResources:
                return collectionView.dequeueConfiguredReusableCell(using: manageResourcesReg, for: indexPath, item: ())
                
            case .deleteButton:
                return collectionView.dequeueConfiguredReusableCell(using: deleteReg, for: indexPath, item: ())
            }
        }
    }
    
    // MARK: - UI Updates
    
    private func updateUI() {
        navigationItem.rightBarButtonItem = doneButton
        
        switch currentMode {
        case .empty:
            title = "Import Dictionary"
            emptyStateView.isHidden = false
            collectionView.isHidden = true
            hasUnsavedChanges = false
            
        case .importing:
            title = "Import Dictionary"
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            hasUnsavedChanges = true  // File selected = has changes to import
            applyImportSnapshot()
            
        case .editing(let dictId):
            let dict = DictionaryService.shared.dict(id: dictId)
            title = dict?.metadata?.title ?? "Dictionary"
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            applyEditSnapshot(dictId: dictId)
        }
    }
    
    private func updateDoneButtonState() {
        doneButton.isEnabled = hasUnsavedChanges
    }
    
    private func applyCurrentSnapshot() {
        switch currentMode {
        case .empty:
            break  // No snapshot needed for empty state
        case .importing:
            applyImportSnapshot()
        case .editing(let dictId):
            applyEditSnapshot(dictId: dictId)
        }
    }
    
    private func applyImportSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        // File selection section
        snapshot.appendSections([.fileSelection])
        snapshot.appendItems([.selectFile], toSection: .fileSelection)
        
        // If file selected, show metadata preview
        if selectedMDXURL != nil {
            snapshot.appendSections([.metadata, .displayName])
            // TODO: Read actual metadata from MDX file
            snapshot.appendItems([
                .metadataTitle("Preview Title"),
                .metadataDescription("Preview Description")
            ], toSection: .metadata)
            snapshot.appendItems([.displayNameField(editedDisplayName ?? "")], toSection: .displayName)
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    private func applyEditSnapshot(dictId: String) {
        guard let dict = DictionaryService.shared.dict(id: dictId) else { return }
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        // Metadata section
        snapshot.appendSections([.metadata])
        snapshot.appendItems([
            .metadataTitle(dict.metadata?.title ?? ""),
            .metadataDescription(dict.metadata?.description ?? "")
        ], toSection: .metadata)
        
        // Display name section
        snapshot.appendSections([.displayName])
        let displayName = editedDisplayName ?? dict.metadata?.title ?? ""
        snapshot.appendItems([.displayNameField(displayName)], toSection: .displayName)
        
        // Manage Resources section (ONLY in compact mode - when split view is collapsed)
        // In regular mode (columns side-by-side), the third column shows the resource editor
        let isCollapsed = isSplitViewCollapsed
        debugLog("📋 applyEditSnapshot: isSplitViewCollapsed=\(isCollapsed), showManageResources=\(isCollapsed)")
        if isCollapsed {
            snapshot.appendSections([.resources])
            snapshot.appendItems([.manageResources], toSection: .resources)
        }
        
        // Delete section
        // TODO: Only show for user-imported dictionaries, not bundled ones
        snapshot.appendSections([.actions])
        snapshot.appendItems([.deleteButton], toSection: .actions)
        
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    // MARK: - Navigation Actions
    
    /// Handle back navigation (called by system back button via backAction)
    private func handleBackNavigation() {
        if hasUnsavedChanges {
            showAbandonChangesAlert()
        } else {
            performDismiss()
        }
    }
    
    @objc private func doneTapped() {
        switch currentMode {
        case .empty:
            break  // Should not happen - Done is disabled
            
        case .importing:
            showConfirmImportAlert()
            
        case .editing:
            showConfirmSaveAlert()
        }
    }
    
    /// Actually perform the dismiss action
    private func performDismiss() {
        // Reset internal state (but NOT currentMode - let MainSplitVC handle the mode switch first)
        // This prevents the empty state from flashing before switchToLookupMode() takes effect
        selectedMDXURL = nil
        currentDictId = nil
        editedDisplayName = nil
        hasUnsavedChanges = false
        
        // Call onDismiss which triggers switchToLookupMode() in MainSplitVC
        // The mode will be reset when showImportMode() or showEditMode() is called next time
        onDismiss?()
        
        // In compact mode, we need to navigate back to sidebar (primary column)
        // because switchToLookupMode() only replaces view controllers but doesn't navigate
        if isSplitViewCollapsed, let splitVC = findSplitViewController() {
            debugLog("📋 performDismiss: compact mode, showing primary")
            splitVC.show(.primary)
        }
    }
    
    /// Find the parent split view controller
    private func findSplitViewController() -> UISplitViewController? {
        var vc: UIViewController? = self
        while let current = vc {
            if let splitVC = current as? UISplitViewController {
                return splitVC
            }
            vc = current.parent
        }
        return nil
    }
    
    // MARK: - Alerts
    
    private func showAbandonChangesAlert() {
        let alert = UIAlertController(
            title: "Discard Changes?",
            message: "You have unsaved changes. Are you sure you want to discard them?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.performDismiss()
        })
        
        present(alert, animated: true)
    }
    
    private func showConfirmImportAlert() {
        guard let url = selectedMDXURL else { return }
        
        let alert = UIAlertController(
            title: "Import Dictionary?",
            message: "Import \"\(url.lastPathComponent)\" to your library?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Import", style: .default) { [weak self] _ in
            self?.performImport()
        })
        
        present(alert, animated: true)
    }
    
    private func showConfirmSaveAlert() {
        let alert = UIAlertController(
            title: "Save Changes?",
            message: "Save your changes to this dictionary?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            self?.performSave()
        })
        
        present(alert, animated: true)
    }
    
    private func showDeleteConfirmation() {
        guard case .editing(let dictId) = currentMode else { return }
        
        let dict = DictionaryService.shared.dict(id: dictId)
        let dictTitle = dict?.metadata?.title ?? "this dictionary"
        
        let alert = UIAlertController(
            title: "Delete Dictionary",
            message: "Are you sure you want to delete \"\(dictTitle)\"? This action cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.performDelete(dictId: dictId)
        })
        
        present(alert, animated: true)
    }
    
    // MARK: - Perform Actions
    
    @objc private func selectFileTapped() {
        showDocumentPicker()
    }
    
    private func performImport() {
        guard let url = selectedMDXURL else { return }
        
        // TODO: Perform actual import
        print("📥 Importing from: \(url.lastPathComponent)")
        
        // Simulate import completion
        let fakeDictId = UUID().uuidString
        
        // Reset state
        selectedMDXURL = nil
        editedDisplayName = nil
        hasUnsavedChanges = false
        currentMode = .empty
        
        onImportComplete?(fakeDictId)
    }
    
    private func performSave() {
        guard case .editing(let dictId) = currentMode else { return }
        
        // TODO: Save changes (display name, etc.)
        print("💾 Saving changes for: \(dictId)")
        if let newName = editedDisplayName {
            print("   New display name: \(newName)")
        }
        
        // Reset state
        currentDictId = nil
        editedDisplayName = nil
        hasUnsavedChanges = false
        currentMode = .empty
        
        onDismiss?()
    }
    
    private func performDelete(dictId: String) {
        // TODO: Perform actual delete
        print("🗑️ Deleting dictionary: \(dictId)")
        
        // Reset state
        currentDictId = nil
        editedDisplayName = nil
        hasUnsavedChanges = false
        currentMode = .empty
        
        onDeleteComplete?(dictId)
    }
    
    private func showDocumentPicker() {
        let mdxType = UTType(filenameExtension: "mdx") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [mdxType])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
    
    private func showDisplayNameEditor() {
        guard case .editing(let dictId) = currentMode else { return }
        let dict = DictionaryService.shared.dict(id: dictId)
        let currentName = editedDisplayName ?? dict?.metadata?.title ?? ""
        
        let alert = UIAlertController(
            title: "Display Name",
            message: "Enter a custom display name for this dictionary",
            preferredStyle: .alert
        )
        
        alert.addTextField { textField in
            textField.text = currentName
            textField.placeholder = "Display name"
            textField.clearButtonMode = .whileEditing
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let newName = alert.textFields?.first?.text else { return }
            self?.editedDisplayName = newName
            self?.hasUnsavedChanges = true
            self?.applyCurrentSnapshot()
        })
        
        present(alert, animated: true)
    }
    
    // MARK: - Public API
    
    func showEmptyState() {
        selectedMDXURL = nil
        currentDictId = nil
        editedDisplayName = nil
        hasUnsavedChanges = false
        currentMode = .empty
    }
    
    func showImportMode() {
        selectedMDXURL = nil
        currentDictId = nil
        editedDisplayName = nil
        hasUnsavedChanges = false
        currentMode = .empty  // Start with empty, showing file picker prompt
    }
    
    func showEditMode(for dictId: String) {
        selectedMDXURL = nil
        currentDictId = dictId
        editedDisplayName = nil
        hasUnsavedChanges = false
        currentMode = .editing(dictId: dictId)
    }
}

// MARK: - UICollectionViewDelegate

extension DictInfoViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .selectFile:
            showDocumentPicker()
            
        case .displayNameField:
            showDisplayNameEditor()
            
        case .manageResources:
            if case .editing(let dictId) = currentMode {
                onManageResources?(dictId)
            }
            
        case .deleteButton:
            showDeleteConfirmation()
            
        default:
            break
        }
    }
}

// MARK: - UIDocumentPickerDelegate

extension DictInfoViewController: UIDocumentPickerDelegate {
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        selectedMDXURL = url
        currentMode = .importing
        
        print("📄 Selected: \(url.lastPathComponent)")
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Stay in current state
    }
}
