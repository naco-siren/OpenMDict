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
    
    /// Callback when import starts (for showing loading UI)
    var onImportStarted: (() -> Void)?
    
    /// Callback when user selected dictionary is imported (dictId passed back)
    var onImportComplete: ((String) -> Void)?
    
    /// Callback when import fails (for hiding loading UI)
    var onImportFailed: ((Error) -> Void)?
    
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
    
    /// Cached attributed description (parsed asynchronously)
    private var cachedAttributedDescription: NSAttributedString?
    /// HTML that was used to generate the cached attributed description
    private var cachedDescriptionHTML: String?
    
    /// Existing dictionary ID if duplicate detected (nil = no duplicate)
    /// When non-nil, import is blocked and user should view the existing dictionary
    private var duplicatedDictId: String?
    
    // MARK: - UI
    
    private nonisolated enum Section: Int, CaseIterable {
        case status           // Warnings (duplicate, mddMissing) - conditional
        case manageResources  // Button to manage MDD/CSS/JS (compact mode only)
        case displayName      // Editable display name with header
        case selectFile       // "Select MDX File" button (import empty state)
        case basicMetadata    // Title, Date Created, Date Imported, Entries
        case advancedMetadata // Engine, Format, Encoding, flags
        case description      // Description (standalone, bottom of page)
        case dangerZone       // Delete button (edit mode only)

        var title: String? {
            switch self {
            case .status: return nil
            case .manageResources: return nil
            case .displayName: return L10n.DictInfo.customName
            case .selectFile: return nil
            case .basicMetadata: return L10n.DictInfo.basicInfo
            case .advancedMetadata: return L10n.DictInfo.technicalDetails
            case .description: return L10n.DictInfo.descriptionHeader
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
        /// Entry count: -1 = unknown/missing, 0 = parse error, >0 = actual count
        case date(title: String, icon: String, date: Date)
        case entryCount(Int)
        case lookupCount(Int)
        case bookmarkCount(Int)
        case description(String)
        
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
        label.text = L10n.DictInfo.emptyState
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        
        let button = UIButton(type: .system)
        button.setTitle(L10n.DictInfo.selectMdxFile, for: .normal)
        button.setImage(UIImage(systemName: "folder.circle"), for: .normal)
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

    /// Explicit close button for iOS 26 compact mode where the system back button
    /// may not appear due to UISplitViewController column-swap behavior.
    private lazy var closeButton: UIBarButtonItem = {
        UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
    }()
    
    /// Reference to the display name text view (for reading edited value)
    private weak var displayNameTextView: UITextView?
    
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
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Re-apply navigation bar configuration.
        // On iOS 26 compact mode, UISplitViewController column swaps may cause
        // the wrapper UINavigationController to lose bar button item state.
        updateNavigationBar()
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
            content.text = L10n.DictInfo.alreadyImportedTitle
            content.textProperties.color = .systemOrange
            content.secondaryText = L10n.DictInfo.alreadyImportedSubtitle
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
            content.text = L10n.DictInfo.selectMdxFile
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
            content.text = L10n.DictInfo.manageResources
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
            content.text = value.isEmpty ? L10n.DictInfo.noCustomName : value
            content.textProperties.color = value.isEmpty ? .tertiaryLabel : .label
            content.textProperties.numberOfLines = 0  // Allow multi-line display
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Display Name Field (editing mode - UITextView for multi-line)
        let displayNameFieldReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, indexPath, value in
            // Remove any existing subviews
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            cell.contentConfiguration = nil
            
            // Create text view (supports multi-line)
            let textView = UITextView()
            textView.text = value
            textView.font = .preferredFont(forTextStyle: .body)
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.isScrollEnabled = false  // Let cell size to content
            textView.backgroundColor = .clear
            textView.delegate = self
            textView.translatesAutoresizingMaskIntoConstraints = false
            
            // Store reference
            self?.displayNameTextView = textView
            
            cell.contentView.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                textView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                textView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
                textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),  // Minimum height
            ])
            
            cell.accessories = []
        }
        
        // MARK: Info Cell (horizontal key-value: icon + title on left, value on right)
        let infoReg = UICollectionView.CellRegistration<UICollectionViewListCell, (icon: String, title: String, value: String)> {
            cell, indexPath, data in
            var content = UIListContentConfiguration.valueCell()
            content.text = data.title
            content.secondaryText = data.value.isEmpty ? "—" : data.value
            content.secondaryTextProperties.color = data.value.isEmpty ? .tertiaryLabel : .secondaryLabel
            content.image = UIImage(systemName: data.icon)
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Entry Count Cell (formatted number, horizontal)
        /// Only shown when count > 0 (snapshots skip this cell otherwise)
        let entryCountReg = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, indexPath, count in
            var content = UIListContentConfiguration.valueCell()
            content.text = L10n.DictInfo.metaEntries
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            content.secondaryText = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "list.number")
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Date Cell (formatted date, horizontal)
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }()
        let dateReg = UICollectionView.CellRegistration<UICollectionViewListCell, (title: String, icon: String, date: Date)> {
            cell, indexPath, data in
            var content = UIListContentConfiguration.valueCell()
            content.text = data.title
            content.secondaryText = dateFormatter.string(from: data.date)
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: data.icon)
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Description Cell (multi-line, HTML rendered asynchronously, no icon)
        let descriptionReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, indexPath, htmlValue in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = nil  // No title - standalone section header serves as label
            
            if htmlValue.isEmpty {
                content.secondaryText = L10n.DictInfo.noDescription
                content.secondaryTextProperties.color = .tertiaryLabel
            } else if let cached = self?.cachedAttributedDescription,
                      self?.cachedDescriptionHTML == htmlValue {
                // Use cached attributed string
                content.secondaryAttributedText = cached
            } else {
                // Show placeholder while parsing
                content.secondaryText = L10n.loading
                content.secondaryTextProperties.color = .tertiaryLabel
                
                // Parse HTML asynchronously and reconfigure cell
                // Note: NSAttributedString HTML parsing MUST be on main thread (WebKit requirement)
                // We use async to defer execution after current layout pass
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    // Double-check we still need to parse this HTML
                    guard self.cachedDescriptionHTML != htmlValue else { return }

                    if let attributed = Self.attributedString(fromHTML: htmlValue) {
                        self.cachedAttributedDescription = attributed
                        self.cachedDescriptionHTML = htmlValue

                        // Reconfigure just this cell (if still in snapshot — user
                        // may have switched to editing mode while HTML was parsing)
                        var snapshot = self.dataSource.snapshot()
                        let descItem = Item.description(htmlValue)
                        guard snapshot.itemIdentifiers.contains(descItem) else { return }
                        snapshot.reconfigureItems([descItem])
                        self.dataSource.apply(snapshot, animatingDifferences: false)
                    }
                }
            }
            
            content.secondaryTextProperties.numberOfLines = 0  // Allow multi-line
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
            content.text = L10n.DictInfo.deleteDictionary
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
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("book", L10n.DictInfo.metaTitle, value))
            case .date(let title, let icon, let date):
                return collectionView.dequeueConfiguredReusableCell(using: dateReg, for: indexPath, item: (title, icon, date))
            case .entryCount(let count):
                return collectionView.dequeueConfiguredReusableCell(using: entryCountReg, for: indexPath, item: count)
            case .lookupCount(let count):
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("number.circle", L10n.DictInfo.lookupCount, formatted))
            case .bookmarkCount(let count):
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("bookmark", L10n.DictInfo.bookmarkCount, formatted))
            case .description(let value):
                return collectionView.dequeueConfiguredReusableCell(using: descriptionReg, for: indexPath, item: value)
                
            // Advanced Metadata
            case .engineVersion(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("gearshape", L10n.DictInfo.metaEngineVersion, value))
            case .format(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("doc.text", L10n.DictInfo.metaFormat, value))
            case .encoding(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("textformat", L10n.DictInfo.metaEncoding, value))
            case .isEncrypted(let value):
                return collectionView.dequeueConfiguredReusableCell(using: booleanReg, for: indexPath, item: ("lock.shield", L10n.DictInfo.metaEncrypted, value))
            case .isCaseSensitive(let value):
                return collectionView.dequeueConfiguredReusableCell(using: booleanReg, for: indexPath, item: ("textformat.abc", L10n.DictInfo.metaCaseSensitive, value))

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
    
    // MARK: - HTML Rendering
    
    /// Parse MDX header creation date string (e.g. "2018-1-1", "2015-03-20") into Date
    private static func parseCreationDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Try common formats from MDX headers
        for format in ["yyyy-MM-dd", "yyyy-M-d", "yyyy/MM/dd", "yyyy/M/d"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
    
    /// Convert HTML string to NSAttributedString for display
    /// Returns nil if conversion fails
    private static func attributedString(fromHTML html: String) -> NSAttributedString? {
        // Wrap in basic HTML structure with styling
        let styledHTML = """
        <html>
        <head>
        <style>
        body {
            font-family: -apple-system;
            font-size: \(UIFont.preferredFont(forTextStyle: .subheadline).pointSize)px;
            color: #8E8E93;
        }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
        
        guard let data = styledHTML.data(using: .utf8) else { return nil }
        
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        
        // HTML parsing must be done on main thread
        if Thread.isMainThread {
            return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        } else {
            var result: NSAttributedString?
            DispatchQueue.main.sync {
                result = try? NSAttributedString(data: data, options: options, documentAttributes: nil)
            }
            return result
        }
    }
    
    // MARK: - UI Updates
    
    private func updateUI() {
        navigationItem.rightBarButtonItem = doneButton
        
        switch currentMode {
        case .empty:
            title = L10n.DictInfo.importDictionary
            emptyStateView.isHidden = false
            collectionView.isHidden = true
            hasUnsavedChanges = false
            isEditingMode = false
            
        case .importing:
            title = L10n.DictInfo.importDictionary
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
                // On iOS 26 compact, the system back button may not appear after
                // UISplitViewController column swaps. Provide an explicit close button.
                if #available(iOS 26, *), isSplitViewCollapsed {
                    navigationItem.leftBarButtonItem = closeButton
                } else {
                    navigationItem.leftBarButtonItem = nil
                }
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
            let descHTML = MDictDescriptionParser.cleanHTMLForDisplay(metadata.description)
            
            var basicItems: [Item] = [.title(titleDisplay)]
            
            if let date = Self.parseCreationDate(metadata.creationDate) {
                basicItems.append(.date(title: L10n.DictInfo.metaDateCreated, icon: "calendar", date: date))
            }
            
            if let count = metadata.entryCount, count > 0 {
                basicItems.append(.entryCount(count))
            }
            
            snapshot.appendItems(basicItems, toSection: .basicMetadata)

            // SECTION: Advanced Metadata
            snapshot.appendSections([.advancedMetadata])
            snapshot.appendItems([
                .engineVersion(metadata.engineVersion),
                .format(metadata.format),
                .encoding(metadata.encoding),
                .isEncrypted(metadata.isEncrypted),
                .isCaseSensitive(metadata.isCaseSensitive)
            ], toSection: .advancedMetadata)

            // SECTION: Description (standalone, bottom)
            if !descHTML.isEmpty {
                snapshot.appendSections([.description])
                snapshot.appendItems([.description(descHTML)], toSection: .description)
            }

        } else {
            // No file selected - show file selection button
            snapshot.appendSections([.selectFile])
            snapshot.appendItems([.selectFileButton], toSection: .selectFile)
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    private func applyEditSnapshot(dictId: String) {
        guard let dict = DictionaryService.shared.dict(id: dictId) else {
            // Dictionary not found or not loaded yet - show loading state
            debugLog("⚠️ applyEditSnapshot: dict not found for \(dictId.prefix(8))...")
            return
        }
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let displayName = editedDisplayName ?? dict.preferredTitle
        
        if isEditingMode {
            // EDITING MODE: Only show editable field and delete button
            // Hide metadata sections to avoid "everything is editable" impression
            
            // SECTION: Display Name (editable)
            snapshot.appendSections([.displayName])
            snapshot.appendItems([.displayNameField(current: displayName)], toSection: .displayName)
            
            // SECTION: Danger Zone (all dictionaries are deletable)
            snapshot.appendSections([.dangerZone])
            snapshot.appendItems([.deleteButton], toSection: .dangerZone)
            
        } else {
            // VIEWING MODE: Show read-only label, manage resources, and all metadata

            // SECTION: Manage Resources (compact mode only)
            if isSplitViewCollapsed {
                snapshot.appendSections([.manageResources])
                snapshot.appendItems([.manageResourcesButton], toSection: .manageResources)
            }

            // SECTION: Display Name (read-only)
            snapshot.appendSections([.displayName])
            snapshot.appendItems([.displayNameLabel(current: displayName)], toSection: .displayName)

            // SECTION: Basic Metadata (only show if metadata loaded)
            if let metadata = dict.metadata {
                snapshot.appendSections([.basicMetadata])
                let descHTML = MDictDescriptionParser.cleanHTMLForDisplay(metadata.description)

                var basicItems: [Item] = [.title(dict.displayTitle)]

                if let date = Self.parseCreationDate(metadata.creationDate) {
                    basicItems.append(.date(title: L10n.DictInfo.metaDateCreated, icon: "calendar", date: date))
                }

                // Date Imported (from manifest, only for existing dictionaries)
                if let importedDate = DictionaryService.shared.importedDate(dictId) {
                    basicItems.append(.date(title: L10n.DictInfo.metaDateImported, icon: "square.and.arrow.down", date: importedDate))
                }

                if let count = metadata.entryCount, count > 0 {
                    basicItems.append(.entryCount(count))
                }

                // Lookup count (per-dict-context trophy counter)
                let lookups = LookupCountService.shared.lookupCount(contextDictId: dictId, contextGroupId: nil)
                basicItems.append(.lookupCount(lookups))

                // Bookmark times (monotonic trophy counter for this dictionary)
                let bookmarks = BookmarkCountService.shared.bookmarkCount(contextDictId: dictId, contextGroupId: nil)
                basicItems.append(.bookmarkCount(bookmarks))

                snapshot.appendItems(basicItems, toSection: .basicMetadata)

                // SECTION: Advanced Metadata
                snapshot.appendSections([.advancedMetadata])
                snapshot.appendItems([
                    .engineVersion(metadata.engineVersion),
                    .format(metadata.format),
                    .encoding(metadata.encoding),
                    .isEncrypted(metadata.isEncrypted),
                    .isCaseSensitive(metadata.isCaseSensitive)
                ], toSection: .advancedMetadata)

                // SECTION: Description (standalone, bottom)
                if !descHTML.isEmpty {
                    snapshot.appendSections([.description])
                    snapshot.appendItems([.description(descHTML)], toSection: .description)
                }
            }
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
    
    /// Close button action (iOS 26 compact fallback for missing system back button).
    /// Exits management mode and navigates back to the sidebar.
    @objc private func closeTapped() {
        performDismiss()
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
        // Sync text view value before saving
        if let text = displayNameTextView?.text {
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
        displayNameTextView = nil
    }
    
    /// Show alert to confirm discarding edits (not the whole import)
    private func showAbandonEditingAlert() {
        let alert = UIAlertController(
            title: L10n.discardChangesTitle,
            message: L10n.discardChangesMessage,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: L10n.keepEditing, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.discard, style: .destructive) { [weak self] _ in
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
            title: L10n.discardChangesTitle,
            message: L10n.discardChangesMessage,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.discard, style: .destructive) { [weak self] _ in
            self?.performDismiss()
        })
        
        present(alert, animated: true)
    }
    
    private func showConfirmImportAlert() {
        guard let url = selectedMDXURL else { return }
        
        let alert = UIAlertController(
            title: L10n.DictInfo.importQuestion,
            message: L10n.DictInfo.importMessage(filename: url.lastPathComponent),
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.importAction, style: .default) { [weak self] _ in
            self?.performImport()
        })
        
        present(alert, animated: true)
    }
    
    private func showConfirmSaveAlert() {
        let alert = UIAlertController(
            title: L10n.DictInfo.saveChangesTitle,
            message: L10n.DictInfo.saveChangesMessage,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.save, style: .default) { [weak self] _ in
            self?.performSave()
        })
        
        present(alert, animated: true)
    }
    
    private func showDeleteConfirmation() {
        guard case .editing(let dictId) = currentMode else { return }
        
        let dict = DictionaryService.shared.dict(id: dictId)
        let dictTitle = dict?.metadata?.title ?? "this dictionary"
        
        let alert = UIAlertController(
            title: L10n.DictInfo.deleteDictionary,
            message: L10n.DictInfo.deleteMessage(name: dictTitle),
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
            self?.performDelete(dictId: dictId)
        })
        
        present(alert, animated: true)
    }
    
    // MARK: - Perform Actions
    
    @objc private func selectFileTapped() {
        showDocumentPicker()
    }
    
    private func performImport() {
        let session = DictionaryService.shared.importSession
        
        guard let metadata = session.mdxMetadata,
              let headerSHA256 = metadata.headerSHA256 else {
            print("❌ Import failed: no MDX in ImportSession")
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
        
        print("📦 Importing: MDX=\(session.mdxPendingFile?.fileName ?? "?"), MDD=\(session.pendingMDDFiles.count), CSS=\(session.pendingCSSFiles.count), JS=\(session.pendingJSFiles.count)")
        
        // Notify start (for loading UI)
        onImportStarted?()
        
        Task {
            do {
                let dictId = try await DictionaryService.shared.importDictionary(
                    displayName: displayName
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
                    onImportFailed?(error)
                    showImportError(error)
                }
            }
        }
    }
    
    private func performSave() {
        guard case .editing(let dictId) = currentMode else { return }
        
        // Save display name if changed
        if let newName = editedDisplayName {
            DictionaryService.shared.updateDisplayName(dictId: dictId, newName: newName)
            print("💾 Saved display name: \(newName)")
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
            title: L10n.DictInfo.importFailed,
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }

    private func showDeleteError(_ error: Error) {
        let alert = UIAlertController(
            title: L10n.DictInfo.deleteFailed,
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
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
        displayNameTextView = nil
        cachedAttributedDescription = nil  // Clear cache
        cachedDescriptionHTML = nil
        currentMode = .empty  // Start with empty, showing file picker prompt
    }
    
    func showEditMode(for dictId: String) {
        selectedMDXURL = nil
        currentDictId = dictId
        editedDisplayName = nil
        hasUnsavedChanges = false
        duplicatedDictId = nil
        isEditingMode = false  // Start in viewing mode
        displayNameTextView = nil
        cachedAttributedDescription = nil  // Clear cache for new dictionary
        cachedDescriptionHTML = nil
        
        // Check if dictionary is loaded
        if let dict = DictionaryService.shared.dict(id: dictId) {
            debugLog("📋 showEditMode: dict loaded, title=\(dict.displayTitle)")
            currentMode = .editing(dictId: dictId)
        } else {
            debugLog("⚠️ showEditMode: dict not loaded yet for \(dictId.prefix(8))...")
            // Show empty state while waiting for dictionary to load
            currentMode = .empty
            // TODO: Could add observer to reload when dictionary becomes available
        }
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
            // Editing mode: text view handles input, tap to focus
            displayNameTextView?.becomeFirstResponder()
            
        // Danger Zone
        case .deleteButton:
            showDeleteConfirmation()
            
        // Metadata items - not tappable
        case .title, .date, .entryCount, .lookupCount, .bookmarkCount, .description,
             .engineVersion, .format, .encoding,
             .isEncrypted, .isCaseSensitive:
            break
        }
    }

}

// MARK: - UITextViewDelegate

private let maxDisplayNameLength = 50

extension DictInfoViewController: UITextViewDelegate {
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Block newlines (including pasted text with newlines)
        if text.rangeOfCharacter(from: .newlines) != nil { return false }
        // Enforce character limit
        let current = textView.text ?? ""
        let updated = (current as NSString).replacingCharacters(in: range, with: text)
        return updated.count <= maxDisplayNameLength
    }
    
    func textViewDidChange(_ textView: UITextView) {
        editedDisplayName = textView.text
        hasUnsavedChanges = true
        
        // Trigger cell resize for dynamic height
        collectionView.collectionViewLayout.invalidateLayout()
    }
}

// MARK: - UIDocumentPickerDelegate

extension DictInfoViewController: UIDocumentPickerDelegate {
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        handleMDXFile(at: url)
    }

    /// Process an MDX file URL (from document picker or external file open).
    /// Loads metadata, checks for duplicates, and enters import mode.
    func handleMDXFile(at url: URL) {
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
