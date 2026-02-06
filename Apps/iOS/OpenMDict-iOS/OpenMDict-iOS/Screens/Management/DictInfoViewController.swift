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
    
    /// Callback to push resource editor in compact mode
    var onManageResources: ((String) -> Void)?
    
    // MARK: - Callbacks for importing
    
    /// Callback when MDX file is selected (dictId = headerSHA256, for updating resource editor)
    var onMDXSelected: ((String) -> Void)?
    
    /// Callback for "View Existing Dictionary" navigation (when duplicate detected)
    var onViewExistingDictionary: ((String) -> Void)?
    
    /// Callback when user selected dictionary is imported (dictId passed back)
    var onImportComplete: ((String) -> Void)?
    
    // MARK: - Callbacks for editing
    
    /// Callback when edit is saved (dictId passed back)
    var onEditComplete: ((String) -> Void)?
    
    /// Callback when a selected dictionary is removed (dictId passed back)
    var onDeleteComplete: ((String) -> Void)?
    
    // MARK: - State
    
    private(set) var currentMode: DictConfigMode = .empty {
        didSet {
            if isViewLoaded {
                updateUI()
            }
        }
    }
    
    /// Whether the user is in editing mode (vs viewing mode)
    /// - Import mode: always true (user is setting up new dictionary)
    /// - Edit mode: toggleable via Edit/Done buttons
    private var isEditingMode: Bool = false {
        didSet {
            if isViewLoaded {
                updateNavigationBar()
                applyCurrentSnapshot()
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
    
    /// Previewed metadata (for import mode, loaded from selected MDX)
    private var previewMetadata: MDictMetadata?
    
    /// Current dictionary ID (for edit mode)
    private var currentDictId: String?
    
    /// Edited display name (tracks changes)
    private var editedDisplayName: String?
    
    /// Existing dictionary ID if duplicate detected (nil = no duplicate)
    /// When non-nil, import is blocked and user should view the existing dictionary
    private var duplicatedDictId: String?
    
    // MARK: - UI
    
    private nonisolated enum Section: Int, CaseIterable {
        case status           // Warnings (duplicate, mddMissing) - conditional
        case manageResources  // Button to manage MDD/CSS/JS (compact mode only)
        case displayName      // Editable display name with header
        case selectFile       // "Select MDX File" button (import empty state)
        case basicMetadata    // Title, Entries, Description
        case advancedMetadata // Engine, Format, Encoding, flags
        case dangerZone       // Delete button (edit mode only)
        
        var title: String? {
            switch self {
            case .status: return nil
            case .manageResources: return nil
            case .displayName: return "Custom Name"
            case .selectFile: return nil
            case .basicMetadata: return "Dictionary Info"
            case .advancedMetadata: return "Technical Details"
            case .dangerZone: return nil
            }
        }
    }
    
    private nonisolated enum Item: Hashable {
        // Status
        case duplicateWarning(existingId: String)
        // case mddMissingWarning  // TBD
        
        // Actions
        case selectFileButton
        case manageResourcesButton
        
        // Display Name
        case displayNameLabel(current: String)  // Viewing mode: read-only label
        case displayNameField(current: String)  // Editing mode: UITextField
        
        // Basic Metadata
        case title(String)
        case entryCount(Int?)
        case description(String)
        // case creationDate(String)  // TBD
        // case importedDate(Date)    // TBD, editing only
        
        // Advanced Metadata
        case engineVersion(String)
        case format(String)
        case encoding(String)
        case isEncrypted(Bool)
        case isCaseSensitive(Bool)
        
        // Danger Zone
        case deleteButton
    }
    
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
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
    
    /// Edit button (viewing mode → editing mode)
    private lazy var editButton: UIBarButtonItem = {
        UIBarButtonItem(
            barButtonSystemItem: .edit,
            target: self,
            action: #selector(editTapped)
        )
    }()
    
    /// Done button (save changes)
    private lazy var doneButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
        button.isEnabled = false
        return button
    }()
    
    /// Cancel button (discard changes, exit editing mode)
    private lazy var cancelButton: UIBarButtonItem = {
        UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
    }()
    
    /// Reference to the display name text field (for reading edited value)
    private weak var displayNameTextField: UITextField?
    
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
        
        configureDataSource()
        updateUI()
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
            
            // Show/hide "Manage Resources"
            applyCurrentSnapshot()
        }
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        // MARK: Warning Cell (orange background)
        let warningReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, indexPath, existingId in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Dictionary Already Imported"
            content.textProperties.color = .systemOrange
            content.secondaryText = "Tap to view the existing dictionary"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            
            var bgConfig = UIBackgroundConfiguration.listGroupedCell()
            bgConfig.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.1)
            cell.backgroundConfiguration = bgConfig
        }
        
        // MARK: Select File Button (blue background)
        let selectFileReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Select MDX File"
            content.textProperties.color = .white
            content.textProperties.alignment = .center
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            cell.contentConfiguration = content
            cell.accessories = []
            
            var bgConfig = UIBackgroundConfiguration.listGroupedCell()
            bgConfig.backgroundColor = .systemBlue
            bgConfig.cornerRadius = 10
            cell.backgroundConfiguration = bgConfig
        }
        
        // MARK: Manage Resources Button (blue background)
        let manageResourcesReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "folder.badge.gearshape")
            content.imageProperties.tintColor = .white
            content.text = "Manage Resources"
            content.textProperties.color = .white
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator(options: .init(tintColor: .white.withAlphaComponent(0.7)))]
            
            var bgConfig = UIBackgroundConfiguration.listGroupedCell()
            bgConfig.backgroundColor = .systemBlue
            bgConfig.cornerRadius = 10
            cell.backgroundConfiguration = bgConfig
        }
        
        // MARK: Display Name Label (viewing mode - read-only)
        let displayNameLabelReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, indexPath, value in
            var content = UIListContentConfiguration.cell()
            content.text = value.isEmpty ? "No custom name" : value
            content.textProperties.color = value.isEmpty ? .tertiaryLabel : .label
            content.textProperties.numberOfLines = 0  // Allow multi-line display
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Display Name Field (editing mode - UITextField)
        let displayNameFieldReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, indexPath, value in
            // Remove any existing subviews
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            cell.contentConfiguration = nil
            
            // Create text field
            let textField = UITextField()
            textField.text = value
            textField.placeholder = "Enter a custom name..."
            textField.font = .preferredFont(forTextStyle: .body)
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
            textField.delegate = self
            textField.addTarget(self, action: #selector(self?.displayNameTextFieldDidChange(_:)), for: .editingChanged)
            textField.translatesAutoresizingMaskIntoConstraints = false
            
            // Store reference
            self?.displayNameTextField = textField
            
            cell.contentView.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                textField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                textField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                textField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            ])
            
            cell.accessories = []
        }
        
        // MARK: Info Cell (icon + title + value)
        let infoReg = UICollectionView.CellRegistration<UICollectionViewListCell, (icon: String, title: String, value: String)> {
            cell, indexPath, data in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = data.title
            content.secondaryText = data.value.isEmpty ? "—" : data.value
            content.secondaryTextProperties.color = data.value.isEmpty ? .tertiaryLabel : .secondaryLabel
            content.image = UIImage(systemName: data.icon)
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Entry Count Cell (formatted number)
        let entryCountReg = UICollectionView.CellRegistration<UICollectionViewListCell, Int?> { cell, indexPath, count in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Entries"
            if let count = count {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                content.secondaryText = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
                content.secondaryTextProperties.color = .secondaryLabel
            } else {
                content.secondaryText = "Unknown"
                content.secondaryTextProperties.color = .tertiaryLabel
            }
            content.image = UIImage(systemName: "list.number")
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Description Cell (multi-line)
        let descriptionReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, indexPath, value in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Description"
            content.secondaryText = value.isEmpty ? "No description" : value
            content.secondaryTextProperties.color = value.isEmpty ? .tertiaryLabel : .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0  // Allow multi-line
            content.image = UIImage(systemName: "text.alignleft")
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Boolean Switch Cell (non-interactive display)
        let booleanReg = UICollectionView.CellRegistration<UICollectionViewListCell, (icon: String, title: String, value: Bool)> {
            cell, indexPath, data in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = data.title
            content.image = UIImage(systemName: data.icon)
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            
            // Non-interactive switch to display boolean value
            let toggle = UISwitch()
            toggle.isOn = data.value
            toggle.isUserInteractionEnabled = false
            toggle.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
        }
        
        // MARK: Delete Button Cell
        let deleteReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Delete Dictionary"
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Header Registration
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, elementKind, indexPath in
            guard let section = self?.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = headerView.defaultContentConfiguration()
            content.text = section.title
            headerView.contentConfiguration = content
        }
        
        // MARK: Data Source Provider
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            // Status
            case .duplicateWarning(let existingId):
                return collectionView.dequeueConfiguredReusableCell(using: warningReg, for: indexPath, item: existingId)
                
            // Actions
            case .selectFileButton:
                return collectionView.dequeueConfiguredReusableCell(using: selectFileReg, for: indexPath, item: ())
            case .manageResourcesButton:
                return collectionView.dequeueConfiguredReusableCell(using: manageResourcesReg, for: indexPath, item: ())
                
            // Display Name
            case .displayNameLabel(let value):
                return collectionView.dequeueConfiguredReusableCell(using: displayNameLabelReg, for: indexPath, item: value)
            case .displayNameField(let value):
                return collectionView.dequeueConfiguredReusableCell(using: displayNameFieldReg, for: indexPath, item: value)
                
            // Basic Metadata
            case .title(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("book", "Title", value))
            case .entryCount(let count):
                return collectionView.dequeueConfiguredReusableCell(using: entryCountReg, for: indexPath, item: count)
            case .description(let value):
                return collectionView.dequeueConfiguredReusableCell(using: descriptionReg, for: indexPath, item: value)
                
            // Advanced Metadata
            case .engineVersion(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("gearshape", "Engine Version", value))
            case .format(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("doc.text", "Format", value))
            case .encoding(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("textformat", "Encoding", value))
            case .isEncrypted(let value):
                return collectionView.dequeueConfiguredReusableCell(using: booleanReg, for: indexPath, item: ("lock.shield", "Encrypted", value))
            case .isCaseSensitive(let value):
                return collectionView.dequeueConfiguredReusableCell(using: booleanReg, for: indexPath, item: ("textformat.abc", "Case Sensitive", value))
                
            // Danger Zone
            case .deleteButton:
                return collectionView.dequeueConfiguredReusableCell(using: deleteReg, for: indexPath, item: ())
            }
        }
        
        // Register supplementary view provider
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
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
            isEditingMode = false
            
        case .importing:
            title = "Import Dictionary"
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            hasUnsavedChanges = true  // File selected = has changes to import
            isEditingMode = true  // Import mode is always editing
            applyImportSnapshot()
            
        case .editing(let dictId):
            let dict = DictionaryService.shared.dict(id: dictId)
            title = dict?.displayTitle
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            // Start in viewing mode for existing dictionaries
            if !isEditingMode {
                hasUnsavedChanges = false
            }
            applyEditSnapshot(dictId: dictId)
        }
        
        updateNavigationBar()
    }
    
    private func updateNavigationBar() {
        switch currentMode {
        case .empty:
            // Empty state: Cancel on left (via onDismiss)
            navigationItem.leftBarButtonItem = cancelButton
            navigationItem.rightBarButtonItem = nil
            
        case .importing:
            // Import mode: always editing, Cancel/Done
            navigationItem.leftBarButtonItem = cancelButton
            navigationItem.rightBarButtonItem = doneButton
            
        case .editing:
            if isEditingMode {
                // Editing mode: Cancel/Done
                navigationItem.leftBarButtonItem = cancelButton
                navigationItem.rightBarButtonItem = doneButton
            } else {
                // Viewing mode: (system back) / Edit
                navigationItem.leftBarButtonItem = nil
                navigationItem.rightBarButtonItem = editButton
            }
        }
    }
    
    private func updateDoneButtonState() {
        // Disable Done button if no changes OR if duplicate detected in import mode
        doneButton.isEnabled = hasUnsavedChanges && duplicatedDictId == nil
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
        
        if let metadata = previewMetadata,
           let sourceFileName = selectedMDXURL?.deletingPathExtension().lastPathComponent {
            
            // SECTION: Status (warnings)
            if let existingId = duplicatedDictId {
                snapshot.appendSections([.status])
                snapshot.appendItems([.duplicateWarning(existingId: existingId)], toSection: .status)
            }
            
            // Only show interaction sections when NOT duplicate
            if duplicatedDictId == nil {
                // SECTION: Manage Resources (compact mode only)
                if isSplitViewCollapsed {
                    snapshot.appendSections([.manageResources])
                    snapshot.appendItems([.manageResourcesButton], toSection: .manageResources)
                }
                
                // SECTION: Display Name
                snapshot.appendSections([.displayName])
                let extractedTitle = MDictDescriptionParser.tryExtractTitle(from: metadata.description)
                let displayName = editedDisplayName ?? extractedTitle ?? metadata.title ?? sourceFileName
                snapshot.appendItems([.displayNameField(current: displayName)], toSection: .displayName)
            }
            
            // SECTION: Basic Metadata
            snapshot.appendSections([.basicMetadata])
            let titleDisplay = metadata.title ?? sourceFileName
            let cleanedDesc = MDictDescriptionParser.cleanDescription(metadata.description)
            
            snapshot.appendItems([
                .title(titleDisplay),
                .entryCount(metadata.entryCount),
                .description(cleanedDesc)
            ], toSection: .basicMetadata)
            
            // SECTION: Advanced Metadata
            snapshot.appendSections([.advancedMetadata])
            snapshot.appendItems([
                .engineVersion(metadata.engineVersion),
                .format(metadata.format),
                .encoding(metadata.encoding),
                .isEncrypted(metadata.isEncrypted),
                .isCaseSensitive(metadata.isCaseSensitive)
            ], toSection: .advancedMetadata)
            
        } else {
            // No file selected - show file selection button
            snapshot.appendSections([.selectFile])
            snapshot.appendItems([.selectFileButton], toSection: .selectFile)
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    private func applyEditSnapshot(dictId: String) {
        guard let dict = DictionaryService.shared.dict(id: dictId),
              let metadata = dict.metadata else { return }
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let displayName = editedDisplayName ?? dict.preferredTitle
        
        if isEditingMode {
            // EDITING MODE: Show editable field and delete button
            
            // SECTION: Display Name (editable)
            snapshot.appendSections([.displayName])
            snapshot.appendItems([.displayNameField(current: displayName)], toSection: .displayName)
            
            // SECTION: Basic Metadata
            snapshot.appendSections([.basicMetadata])
            let cleanedDesc = dict.cleanedDescription ?? metadata.description
            snapshot.appendItems([
                .title(dict.displayTitle),
                .entryCount(metadata.entryCount),
                .description(cleanedDesc)
            ], toSection: .basicMetadata)
            
            // SECTION: Advanced Metadata
            snapshot.appendSections([.advancedMetadata])
            snapshot.appendItems([
                .engineVersion(metadata.engineVersion),
                .format(metadata.format),
                .encoding(metadata.encoding),
                .isEncrypted(metadata.isEncrypted),
                .isCaseSensitive(metadata.isCaseSensitive)
            ], toSection: .advancedMetadata)
            
            // SECTION: Danger Zone (only for user-imported, not bundled)
            let source = DictionaryService.shared.dictionarySources[dictId]
            if source == .imported {
                snapshot.appendSections([.dangerZone])
                snapshot.appendItems([.deleteButton], toSection: .dangerZone)
            }
            
        } else {
            // VIEWING MODE: Show read-only label and manage resources
            
            // SECTION: Manage Resources (compact mode only, viewing mode only)
            if isSplitViewCollapsed {
                snapshot.appendSections([.manageResources])
                snapshot.appendItems([.manageResourcesButton], toSection: .manageResources)
            }
            
            // SECTION: Display Name (read-only)
            snapshot.appendSections([.displayName])
            snapshot.appendItems([.displayNameLabel(current: displayName)], toSection: .displayName)
            
            // SECTION: Basic Metadata
            snapshot.appendSections([.basicMetadata])
            let cleanedDesc = dict.cleanedDescription ?? metadata.description
            snapshot.appendItems([
                .title(dict.displayTitle),
                .entryCount(metadata.entryCount),
                .description(cleanedDesc)
            ], toSection: .basicMetadata)
            
            // SECTION: Advanced Metadata
            snapshot.appendSections([.advancedMetadata])
            snapshot.appendItems([
                .engineVersion(metadata.engineVersion),
                .format(metadata.format),
                .encoding(metadata.encoding),
                .isEncrypted(metadata.isEncrypted),
                .isCaseSensitive(metadata.isCaseSensitive)
            ], toSection: .advancedMetadata)
        }
        
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
    
    @objc private func editTapped() {
        // Enter editing mode
        isEditingMode = true
    }
    
    @objc private func cancelTapped() {
        switch currentMode {
        case .empty:
            // Cancel from empty state - just dismiss
            performDismiss()
            
        case .importing:
            // Cancel import - discard and dismiss
            if hasUnsavedChanges {
                showAbandonChangesAlert()
            } else {
                performDismiss()
            }
            
        case .editing:
            // Cancel editing - discard changes and return to viewing mode
            if hasUnsavedChanges {
                showAbandonEditingAlert()
            } else {
                exitEditingMode()
            }
        }
    }
    
    @objc private func doneTapped() {
        // Sync text field value before saving
        if let text = displayNameTextField?.text {
            editedDisplayName = text
        }
        
        switch currentMode {
        case .empty:
            break  // Should not happen - Done is disabled
            
        case .importing:
            showConfirmImportAlert()
            
        case .editing:
            showConfirmSaveAlert()
        }
    }
    
    /// Exit editing mode without saving (discard changes)
    private func exitEditingMode() {
        editedDisplayName = nil
        hasUnsavedChanges = false
        isEditingMode = false
        displayNameTextField = nil
    }
    
    /// Show alert to confirm discarding edits (not the whole import)
    private func showAbandonEditingAlert() {
        let alert = UIAlertController(
            title: "Discard Changes?",
            message: "You have unsaved changes. Are you sure you want to discard them?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.exitEditingMode()
        })
        
        present(alert, animated: true)
    }
    
    /// Actually perform the dismiss action
    private func performDismiss() {
        // Reset internal state (but NOT currentMode - let MainSplitVC handle the mode switch first)
        // This prevents the empty state from flashing before switchToLookupMode() takes effect
        selectedMDXURL = nil
        previewMetadata = nil
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
        guard let url = selectedMDXURL,
              let metadata = previewMetadata,
              let headerSHA256 = metadata.headerSHA256 else {
            print("❌ Import failed: missing URL or metadata")
            return
        }
        
        // Double-check for duplicate (should already be caught by UI)
        if DictionaryService.shared.isDuplicateImport(headerSHA256: headerSHA256) {
            print("❌ Import blocked: duplicate detected")
            return
        }
        
        // Determine display name
        let displayName = editedDisplayName
            ?? MDictDescriptionParser.tryExtractTitle(from: metadata.description)
            ?? metadata.title
            ?? "???" // TODO: Fall back to source filename
        
        // Create SelectedFile for the MDX
        let mdxFile = SelectedFile(url: url)
        
        // Get pending resources from ImportSession
        let session = DictionaryService.shared.importSession
        let mddFiles = session.pendingMDDFiles.map { SelectedFile(url: $0.url) }
        let cssFiles = session.pendingCSSFiles.map { SelectedFile(url: $0.url) }
        let jsFiles = session.pendingJSFiles.map { SelectedFile(url: $0.url) }
        
        print("📦 Importing: MDX=\(mdxFile.fileName), MDD=\(mddFiles.count), CSS=\(cssFiles.count), JS=\(jsFiles.count)")
        
        Task {
            do {
                let dictId = try await DictionaryService.shared.importDictionary(
                    mdxFile: mdxFile,
                    mddFiles: mddFiles,
                    cssFiles: cssFiles,
                    jsFiles: jsFiles,
                    displayName: displayName,
                    headerSHA256: headerSHA256
                )
                print("✅ Import completed: \(dictId)")

                // Reset state on main thread
                await MainActor.run {
                    selectedMDXURL = nil
                    previewMetadata = nil
                    editedDisplayName = nil
                    duplicatedDictId = nil
                    hasUnsavedChanges = false
                    currentMode = .empty

                    onImportComplete?(dictId)
                }
            } catch {
                print("❌ Import failed: \(error)")
                await MainActor.run {
                    showImportError(error)
                }
            }
        }
    }
    
    private func performSave() {
        guard case .editing(let dictId) = currentMode else { return }
        
        // Save display name if changed
        if let newName = editedDisplayName {
            do {
                try DictionaryService.shared.updateDisplayName(dictId: dictId, newName: newName)
                print("💾 Saved display name: \(newName)")
            } catch {
                print("❌ Failed to save display name: \(error)")
            }
        }
        
        // Reset state
        editedDisplayName = nil
        hasUnsavedChanges = false
        
        onEditComplete?(dictId)
    }
    
    private func performDelete(dictId: String) {
        do {
            try DictionaryService.shared.deleteDictionary(dictId: dictId)
            print("🗑️ Deleted dictionary: \(dictId)")

            // Reset state
            editedDisplayName = nil
            hasUnsavedChanges = false
            currentMode = .empty

            onDeleteComplete?(dictId)
        } catch {
            print("❌ Failed to delete dictionary: \(error)")
            showDeleteError(error)
        }
    }
    
    private func showImportError(_ error: Error) {
        let alert = UIAlertController(
            title: "Import Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showDeleteError(_ error: Error) {
        let alert = UIAlertController(
            title: "Delete Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    private func showDocumentPicker() {
        let mdxType = UTType(filenameExtension: "mdx") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [mdxType])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
    
    // MARK: - Public API
    
    func showEmptyState() {
        selectedMDXURL = nil
        currentDictId = nil
        editedDisplayName = nil
        hasUnsavedChanges = false
        duplicatedDictId = nil
        currentMode = .empty
    }
    
    func showImportMode() {
        selectedMDXURL = nil
        currentDictId = nil
        editedDisplayName = nil
        hasUnsavedChanges = false
        duplicatedDictId = nil
        isEditingMode = true  // Import is always in editing mode
        displayNameTextField = nil
        currentMode = .empty  // Start with empty, showing file picker prompt
    }
    
    func showEditMode(for dictId: String) {
        selectedMDXURL = nil
        currentDictId = dictId
        editedDisplayName = nil
        hasUnsavedChanges = false
        duplicatedDictId = nil
        isEditingMode = false  // Start in viewing mode
        displayNameTextField = nil
        currentMode = .editing(dictId: dictId)
    }
}

// MARK: - UICollectionViewDelegate

extension DictInfoViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        // Actions - tappable
        case .selectFileButton:
            showDocumentPicker()
            
        case .manageResourcesButton:
            if case .editing(let dictId) = currentMode {
                onManageResources?(dictId)
            } else if case .importing = currentMode, let sha256 = previewMetadata?.headerSHA256 {
                onManageResources?(sha256)
            }
            
        // Status - tappable
        case .duplicateWarning(let existingId):
            onViewExistingDictionary?(existingId)
            
        // Display Name
        case .displayNameLabel:
            // Viewing mode: tap does nothing (use Edit button)
            break
        case .displayNameField:
            // Editing mode: text field handles input, tap to focus
            displayNameTextField?.becomeFirstResponder()
            
        // Danger Zone
        case .deleteButton:
            showDeleteConfirmation()
            
        // Metadata items - not tappable
        case .title, .entryCount, .description,
             .engineVersion, .format, .encoding,
             .isEncrypted, .isCaseSensitive:
            break
        }
    }
}

// MARK: - UITextFieldDelegate

extension DictInfoViewController: UITextFieldDelegate {
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
    
    @objc func displayNameTextFieldDidChange(_ textField: UITextField) {
        editedDisplayName = textField.text
        hasUnsavedChanges = true
    }
}

// MARK: - UIDocumentPickerDelegate

extension DictInfoViewController: UIDocumentPickerDelegate {
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        selectedMDXURL = url
        
        // Load metadata preview from selected MDX (need security scope)
        var metadata: MDictMetadata?
        var fileSize: Int64 = 0
        
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        metadata = MDictReader.loadMetadata(from: url.path)
        
        // Get file size while we have security access
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }
        
        previewMetadata = metadata
        
        // Log metadata details (describe style)
        if let m = metadata {
            // TODO: Fall back to source filename
            let title = if let title = m.title, !title.isEmpty { title } else { "(empty)" }
            print("📋 Metadata loaded:")
            print("   Title: \(title)")
            print("   Entries: \(m.entryCount?.description ?? "-")")
            print("   Format: \(m.format), Encoding: \(m.encoding)")
            print("   Engine: \(m.engineVersion)")
            print("   SHA256: \(m.headerSHA256?.prefix(16) ?? "nil")...")
            print("   File size: \(fileSize) bytes")
            let extracted = MDictDescriptionParser.tryExtractTitle(from: m.description)
            print("   Extracted title: \(extracted ?? "(none)")")
        }
        
        // Check for duplicate using SHA256 (SHA256 is used as directory id)
        if let sha256 = metadata?.headerSHA256 {
            if DictionaryService.shared.isDuplicateImport(headerSHA256: sha256) {
                duplicatedDictId = sha256  // SHA256 is the existing dict's id
                print("⚠️ Duplicate detected: existing dictionary \(sha256)")
            } else {
                duplicatedDictId = nil
            }
        } else {
            duplicatedDictId = nil
        }
        
        currentMode = .importing
        print("📄 Selected: \(url.lastPathComponent)")
        
        // Update ImportSession with selected MDX
        if let m = metadata {
            DictionaryService.shared.importSession.setMDX(url: url, metadata: m, fileSize: fileSize)
        }
        
        // Notify MainSplitVC to update third column (resource editor)
        // dictId = headerSHA256 (available before import)
        if let sha256 = metadata?.headerSHA256 {
            onMDXSelected?(sha256)
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Stay in current state
    }
}
