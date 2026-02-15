//
//  GroupInfoViewController.swift
//  OpenMDict-iOS
//
//  Group configuration view controller (second column in Management mode).
//  Symmetric to DictInfoViewController but much simpler — no file I/O.
//
//  Modes:
//  - Creating: New group with editable name, no delete
//  - Managing (viewing): Read-only name, stats, "Manage Dictionaries" (compact)
//  - Managing (editing): Editable name, delete button
//  - ViewingDefault: Read-only view for "All Dictionaries" — no edit, no delete
//
//  Navigation:
//  - Regular mode: Cancel/Done/Edit buttons
//  - Compact mode: System back + "Manage Dictionaries" row to push third column
//

import UIKit
import Combine
import OpenMDictKit

// MARK: - Mode

enum GroupConfigMode: Equatable {
    case creating(groupId: String)        // New group, always actively editing
    case managing(groupId: String)        // Existing group, view/edit toggle
    case viewingDefault(groupId: String)  // Default group, read-only
}

// MARK: - View Controller

class GroupInfoViewController: UIViewController {
    
    // MARK: - Callbacks
    
    var onDismiss: (() -> Void)?
    
    /// Callback to push dictionary editor in compact mode
    var onManageDictionaries: ((String) -> Void)?
    
    /// Callback when a new group is created and saved
    var onCreateComplete: ((String) -> Void)?
    
    /// Callback when group metadata changed (e.g. rename) — refreshes sidebar without exiting management
    var onGroupChanged: ((String) -> Void)?
    
    /// Callback when group is deleted
    var onDeleteComplete: ((String) -> Void)?
    
    // MARK: - State
    
    private(set) var currentMode: GroupConfigMode? {
        didSet {
            if isViewLoaded {
                updateUI()
            }
        }
    }
    
    /// Whether the user is in editing mode (vs viewing mode)
    /// - Creating mode: always true
    /// - Managing mode: toggleable via Edit/Done buttons
    /// - ViewingDefault: always false
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
        didSet { updateDoneButtonState() }
    }
    
    /// Whether the current name conflicts with an existing group
    private var hasNameConflict: Bool = false {
        didSet { updateDoneButtonState() }
    }
    
    private var hasEmptyName: Bool = false {
        didSet { updateDoneButtonState() }
    }
    
    /// True when creating a group with zero dictionaries selected.
    /// Only gates the Done button in creating mode.
    private var hasNoDictionaries: Bool = true {
        didSet { updateDoneButtonState() }
    }
    
    /// Edited display name (tracks changes)
    private var editedName: String?
    
    /// Subscription for dictionary count changes (from session or group.$items)
    private var dictCountCancellable: AnyCancellable?
    
    /// Date formatter for created/modified dates
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    
    /// Computed header style for the displayName section.
    /// Encodes current mode + editing state + conflict into the Section enum
    /// so diffable data source naturally diffs and reconfigures the header.
    private var displayNameHeaderStyle: Section.HeaderStyle {
        guard let mode = currentMode else { return .plain }
        let isActivelyEditing: Bool = switch mode {
        case .creating: true
        case .managing: isEditingMode
        case .viewingDefault: false
        }
        guard isActivelyEditing else { return .plain }
        if hasEmptyName { return .empty }
        return hasNameConflict ? .conflict : .active
    }
    
    /// Whether current mode is viewingDefault
    private var isViewingDefaultMode: Bool {
        if case .viewingDefault = currentMode { return true }
        return false
    }
    
    // MARK: - UI
    
    private nonisolated enum Section: Hashable {
        case displayName(HeaderStyle, isDefault: Bool)  // Group name with contextual header
        case containedItems(compact: Bool)  // Dict count cell (encodes collapsed state for reconfiguration)
        case stats                          // Created/modified dates
        case dangerZone                     // Delete button (editing mode only)
        
        /// Header style for displayName section, encoded so diffable data source
        /// naturally detects changes and reconfigures the supplementary view.
        enum HeaderStyle: Hashable {
            case plain      // viewing mode: default gray header
            case active     // editing: pencil icon + tintColor
            case empty      // editing + name empty: warning icon + red
            case conflict   // editing + name conflict: warning icon + red
        }
        
        var title: String? {
            switch self {
            case .displayName(_, let isDefault): return isDefault ? L10n.GroupInfo.groupName : L10n.GroupInfo.customName
            case .containedItems: return L10n.GroupInfo.containedItems
            case .stats: return L10n.GroupInfo.groupInfoHeader
            case .dangerZone: return nil
            }
        }
    }
    
    private nonisolated enum Item: Hashable {
        // Display Name
        case nameLabel(current: String)    // Viewing mode: read-only
        case nameField(current: String)    // Editing mode: text view
        
        // Contained Items
        case containedItems(Int)           // Dict count (tappable in compact)
        
        // Stats
        case createdDate(String)
        case modifiedDate(String)
        case lookupCount(Int)

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
    
    // MARK: - Navigation Items
    
    private lazy var editButton: UIBarButtonItem = {
        UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(editTapped))
    }()
    
    private lazy var doneButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        button.isEnabled = false
        return button
    }()
    
    private lazy var cancelButton: UIBarButtonItem = {
        UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
    }()
    
    /// Reference to the name text view (for reading edited value)
    private weak var nameTextView: UITextView?
    
    private func updateDoneButtonState() {
        var canSave = hasUnsavedChanges && !hasNameConflict && !hasEmptyName
        if case .creating = currentMode {
            canSave = canSave && !hasNoDictionaries
        }
        doneButton.isEnabled = canSave
    }
    
    /// Check if split view is collapsed (compact mode)
    private var isSplitViewCollapsed: Bool {
        var vc: UIViewController? = self
        while let current = vc {
            if let splitVC = current as? UISplitViewController {
                return splitVC.isCollapsed
            }
            vc = current.parent
        }
        return traitCollection.horizontalSizeClass == .compact
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemGroupedBackground
        
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        configureDataSource()
        updateUI()
    }
    
    /// Track previous collapsed state to detect changes
    private var previousIsCollapsed: Bool?
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        let isCollapsed = isSplitViewCollapsed
        if previousIsCollapsed != isCollapsed {
            previousIsCollapsed = isCollapsed
            applyCurrentSnapshot()
        }
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        // MARK: Contained Items Cell (dual mode: info in regular, button in compact)
        let containedItemsReg = UICollectionView.CellRegistration<UICollectionViewListCell, Int> {
            [weak self] cell, indexPath, count in
            guard let self else { return }
            
            let isCollapsed = self.isSplitViewCollapsed
            let isDefault = self.isViewingDefaultMode
            let isEmpty = count == 0
            let countStr = L10n.dictionaryCount(count)
            
            if isCollapsed && !isDefault {
                // COMPACT (user groups): button-like cell with disclosure chevron
                var content = UIListContentConfiguration.cell()
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
                content.textProperties.color = .white
                
                if isEmpty {
                    content.image = UIImage(systemName: "exclamationmark.triangle")
                    content.text = L10n.GroupInfo.tapToAddDictionaries
                } else {
                    content.image = UIImage(systemName: "books.vertical")
                    content.text = countStr
                }
                content.imageProperties.tintColor = .white
                cell.contentConfiguration = content
                
                cell.accessories = [.disclosureIndicator(options: .init(tintColor: .white.withAlphaComponent(0.7)))]
                
                var bg = UIBackgroundConfiguration.listGroupedCell()
                bg.backgroundColor = isEmpty ? .systemOrange : .systemBlue
                bg.cornerRadius = 10
                cell.backgroundConfiguration = bg
            } else if isCollapsed && isDefault {
                // COMPACT (default group): button-like cell to navigate to reorder editor
                var content = UIListContentConfiguration.cell()
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
                content.textProperties.color = .white
                content.image = UIImage(systemName: "arrow.up.arrow.down")
                content.text = L10n.GroupInfo.reorderDictionaries
                content.imageProperties.tintColor = .white
                cell.contentConfiguration = content
                
                cell.accessories = [.disclosureIndicator(options: .init(tintColor: .white.withAlphaComponent(0.7)))]
                
                var bg = UIBackgroundConfiguration.listGroupedCell()
                bg.backgroundColor = .systemBlue
                bg.cornerRadius = 10
                cell.backgroundConfiguration = bg
            } else {
                // REGULAR: info-style cell (not tappable)
                var content = UIListContentConfiguration.cell()
                
                if isEmpty && !isDefault {
                    content.image = UIImage(systemName: "exclamationmark.triangle")
                    content.imageProperties.tintColor = .systemOrange
                    content.text = L10n.GroupInfo.addAtLeastOne
                    content.textProperties.color = .systemOrange
                } else {
                    content.image = UIImage(systemName: "books.vertical")
                    content.imageProperties.tintColor = .secondaryLabel
                    content.text = countStr
                    content.textProperties.color = .secondaryLabel
                }
                cell.contentConfiguration = content
                cell.accessories = []
                cell.backgroundConfiguration = .listGroupedCell()
            }
        }
        
        // MARK: Name Label (viewing mode)
        let nameLabelReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, indexPath, value in
            var content = UIListContentConfiguration.cell()
            content.text = value.isEmpty ? L10n.GroupInfo.untitledGroup : value
            content.textProperties.color = value.isEmpty ? .tertiaryLabel : .label
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Name Field (editing mode - UITextView)
        let nameFieldReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, indexPath, value in
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            cell.contentConfiguration = nil
            
            let textView = UITextView()
            textView.text = value
            textView.font = .preferredFont(forTextStyle: .body)
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.delegate = self
            textView.translatesAutoresizingMaskIntoConstraints = false
            
            self?.nameTextView = textView
            
            cell.contentView.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                textView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                textView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
                textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
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
        
        // MARK: Delete Button
        let deleteReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.text = L10n.GroupInfo.deleteGroup
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // MARK: Header (style driven by Section.displayName associated value)
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, elementKind, indexPath in
            guard let self,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = headerView.defaultContentConfiguration()
            
            switch section {
            case .displayName(let style, _):
                content.text = section.title
                switch style {
                case .plain:
                    break  // default gray header
                case .active:
                    content.image = .init(systemName: "pencil")
                    content.imageProperties.tintColor = .tintColor
                    content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
                    content.textProperties.color = .tintColor
                case .empty:
                    content.image = .init(systemName: "exclamationmark.triangle")
                    content.imageProperties.tintColor = .systemRed
                    content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
                    content.text = L10n.GroupInfo.nameCannotBeEmpty
                    content.textProperties.color = .systemRed
                case .conflict:
                    content.image = .init(systemName: "exclamationmark.triangle")
                    content.imageProperties.tintColor = .systemRed
                    content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
                    content.text = L10n.GroupInfo.nameAlreadyTaken
                    content.textProperties.color = .systemRed
                }
            default:
                content.text = section.title
            }
            
            headerView.contentConfiguration = content
        }
        
        // MARK: Data Source Provider
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .nameLabel(let value):
                return collectionView.dequeueConfiguredReusableCell(using: nameLabelReg, for: indexPath, item: value)
            case .nameField(let value):
                return collectionView.dequeueConfiguredReusableCell(using: nameFieldReg, for: indexPath, item: value)
                
            case .containedItems(let count):
                return collectionView.dequeueConfiguredReusableCell(using: containedItemsReg, for: indexPath, item: count)
            case .createdDate(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("calendar", L10n.GroupInfo.created, value))
            case .modifiedDate(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("clock", L10n.GroupInfo.modified, value))
            case .lookupCount(let count):
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("number.circle", L10n.GroupInfo.lookupCount, formatted))

            case .deleteButton:
                return collectionView.dequeueConfiguredReusableCell(using: deleteReg, for: indexPath, item: ())
            }
        }
        
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }
    
    // MARK: - UI Updates
    
    private func updateUI() {
        guard let mode = currentMode else {
            title = L10n.GroupInfo.group
            return
        }
        
        switch mode {
        case .creating:
            title = L10n.GroupInfo.newGroup
            isEditingMode = true
            hasUnsavedChanges = true  // New group always has "changes" to save
            
        case .managing(let groupId):
            let group = DictionaryService.shared.group(id: groupId)
            title = group?.name ?? L10n.GroupInfo.group
            if !isEditingMode {
                hasUnsavedChanges = false
            }
            
        case .viewingDefault(let groupId):
            let group = DictionaryService.shared.group(id: groupId)
            title = group?.name ?? L10n.GroupInfo.allDictionaries
            isEditingMode = false
            hasUnsavedChanges = false
        }
        
        updateNavigationBar()
        applyCurrentSnapshot()
    }
    
    private func updateNavigationBar() {
        guard let mode = currentMode else { return }
        
        switch mode {
        case .creating:
            // Creating: Cancel / Done
            navigationItem.leftBarButtonItem = cancelButton
            navigationItem.rightBarButtonItem = doneButton
            
        case .managing:
            if isEditingMode {
                // Editing mode: Cancel / Done
                navigationItem.leftBarButtonItem = cancelButton
                navigationItem.rightBarButtonItem = doneButton
            } else {
                // Viewing mode: (back) / Edit
                navigationItem.leftBarButtonItem = nil
                navigationItem.rightBarButtonItem = editButton
            }
            
        case .viewingDefault:
            // Read-only: no edit buttons
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItem = nil
        }
    }
    
    private func applyCurrentSnapshot() {
        guard let mode = currentMode else { return }
        
        switch mode {
        case .creating(let groupId):
            applyCreatingSnapshot(groupId: groupId)
        case .managing(let groupId):
            applyManagingSnapshot(groupId: groupId)
        case .viewingDefault(let groupId):
            applyViewingDefaultSnapshot(groupId: groupId)
        }
    }
    
    private func applyCreatingSnapshot(groupId: String) {
        let group = DictionaryService.shared.group(id: groupId)
        let name = editedName ?? group?.name ?? L10n.GroupInfo.newGroup
        let isCollapsed = isSplitViewCollapsed
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        // SECTION: Name (always editable in creating mode)
        let nameSection = Section.displayName(displayNameHeaderStyle, isDefault: false)
        snapshot.appendSections([nameSection])
        snapshot.appendItems([.nameField(current: name)], toSection: nameSection)
        
        // SECTION: Contained Items (compact state encoded → section rebuilds on layout change)
        let itemsSection = Section.containedItems(compact: isCollapsed)
        snapshot.appendSections([itemsSection])
        let count = DictionaryService.shared.groupSession.pendingDictionaryIds.count
        snapshot.appendItems([.containedItems(count)], toSection: itemsSection)
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    private func applyManagingSnapshot(groupId: String) {
        guard let group = DictionaryService.shared.group(id: groupId) else {
            debugLog("⚠️ applyManagingSnapshot: group not found for \(groupId.prefix(8))...")
            return
        }
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let name = editedName ?? group.name
        let nameSection = Section.displayName(displayNameHeaderStyle, isDefault: false)
        
        if isEditingMode {
            // EDITING MODE: editable name + delete
            snapshot.appendSections([nameSection])
            snapshot.appendItems([.nameField(current: name)], toSection: nameSection)
            
            snapshot.appendSections([.dangerZone])
            snapshot.appendItems([.deleteButton], toSection: .dangerZone)
            
        } else {
            // VIEWING MODE: read-only name + contained items + stats
            let isCollapsed = isSplitViewCollapsed
            
            snapshot.appendSections([nameSection])
            snapshot.appendItems([.nameLabel(current: name)], toSection: nameSection)
            
            // Contained Items (own section, tappable in compact)
            let itemsSection = Section.containedItems(compact: isCollapsed)
            snapshot.appendSections([itemsSection])
            let count = group.dictionaryIds.count
            snapshot.appendItems([.containedItems(count)], toSection: itemsSection)
            
            // Stats (dates only)
            let fmt = Self.dateFormatter
            var statsItems: [Item] = []
            if let created = group.createdAt {
                statsItems.append(.createdDate(fmt.string(from: created)))
            }
            if let modified = group.modifiedAt {
                statsItems.append(.modifiedDate(fmt.string(from: modified)))
            }

            // Lookup count (per-group-context trophy counter)
            let lookups = LookupCountService.shared.lookupCount(contextDictId: nil, contextGroupId: group.id)
            statsItems.append(.lookupCount(lookups))

            if !statsItems.isEmpty {
                snapshot.appendSections([.stats])
                snapshot.appendItems(statsItems, toSection: .stats)
            }
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    private func applyViewingDefaultSnapshot(groupId: String) {
        guard let group = DictionaryService.shared.group(id: groupId) else {
            debugLog("⚠️ applyViewingDefaultSnapshot: group not found for \(groupId.prefix(8))...")
            return
        }
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let nameSection = Section.displayName(.plain, isDefault: true)
        let isCollapsed = isSplitViewCollapsed
        
        // SECTION: Name (read-only)
        snapshot.appendSections([nameSection])
        snapshot.appendItems([.nameLabel(current: group.name)], toSection: nameSection)
        
        // SECTION: Contained Items (tappable in compact for reorder navigation)
        let itemsSection = Section.containedItems(compact: isCollapsed)
        snapshot.appendSections([itemsSection])
        let count = group.dictionaryIds.count
        snapshot.appendItems([.containedItems(count)], toSection: itemsSection)
        
        // Stats: created date (from initial setup) + lookup count; no modifiedDate
        let fmt = Self.dateFormatter
        var statsItems: [Item] = []
        if let created = group.createdAt {
            statsItems.append(.createdDate(fmt.string(from: created)))
        }
        let lookups = LookupCountService.shared.lookupCount(contextDictId: nil, contextGroupId: groupId)
        statsItems.append(.lookupCount(lookups))
        snapshot.appendSections([.stats])
        snapshot.appendItems(statsItems, toSection: .stats)

        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    // MARK: - Navigation Actions
    
    @objc private func editTapped() {
        guard case .managing = currentMode else { return }
        isEditingMode = true
    }
    
    @objc private func cancelTapped() {
        guard let mode = currentMode else { return }
        
        switch mode {
        case .creating:
            if hasUnsavedChanges {
                showAbandonCreateAlert()
            } else {
                performCancelCreate()
            }
            
        case .managing:
            if hasUnsavedChanges {
                showAbandonEditingAlert()
            } else {
                exitEditingMode()
            }
            
        case .viewingDefault:
            break  // No cancel in read-only mode
        }
    }
    
    @objc private func doneTapped() {
        // Sync text view value before saving
        if let text = nameTextView?.text {
            editedName = text
        }
        
        guard let mode = currentMode else { return }
        
        switch mode {
        case .creating(let groupId):
            performSaveCreate(groupId: groupId)
        case .managing(let groupId):
            performSaveEdit(groupId: groupId)
        case .viewingDefault:
            break  // No done in read-only mode
        }
    }
    
    private func exitEditingMode() {
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        hasEmptyName = false
        hasNoDictionaries = true
        isEditingMode = false
        nameTextView = nil
    }
    
    // MARK: - Alerts
    
    private func showAbandonCreateAlert() {
        let alert = UIAlertController(
            title: L10n.GroupInfo.discardNewGroupTitle,
            message: L10n.GroupInfo.discardNewGroupMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.keepEditing, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.discard, style: .destructive) { [weak self] _ in
            self?.performCancelCreate()
        })
        present(alert, animated: true)
    }
    
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
    
    private func showDeleteConfirmation() {
        guard case .managing(let groupId) = currentMode else { return }
        let group = DictionaryService.shared.group(id: groupId)
        let groupName = group?.name ?? "this group"
        
        let alert = UIAlertController(
            title: L10n.GroupInfo.deleteGroup,
            message: L10n.GroupInfo.deleteGroupMessage(name: groupName),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
            self?.performDelete(groupId: groupId)
        })
        present(alert, animated: true)
    }
    
    // MARK: - Perform Actions
    
    /// Cancel creating - just discard session state (groups was never modified)
    private func performCancelCreate() {
        DictionaryService.shared.groupSession.reset()
        
        dictCountCancellable = nil
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        hasEmptyName = false
        hasNoDictionaries = true
        nameTextView = nil
        currentMode = nil
        
        onDismiss?()
        
        if isSplitViewCollapsed, let splitVC = findSplitViewController() {
            splitVC.show(.primary)
        }
    }
    
    private func performSaveCreate(groupId: String) {
        let name = (editedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? L10n.GroupInfo.newGroup : name
        let session = DictionaryService.shared.groupSession
        let pendingDicts = session.pendingDictionaryIds
        
        // Create the group and set its dictionaries in one go
        let group = DictionaryService.shared.createGroup(name: finalName)

        if !pendingDicts.isEmpty {
            DictionaryService.shared.reorderDictionariesInGroup(
                groupId: group.id,
                newOrder: pendingDicts
            )
        }

        session.reset()

        dictCountCancellable = nil
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        hasEmptyName = false
        hasNoDictionaries = true
        nameTextView = nil

        onCreateComplete?(group.id)
    }
    
    private func performSaveEdit(groupId: String) {
        let name = (editedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !name.isEmpty {
            do {
                try DictionaryService.shared.renameGroup(id: groupId, newName: name)
                title = name
            } catch {
                debugLog("⚠️ Failed to rename group: \(error)")
            }
        }
        
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        hasEmptyName = false
        hasNoDictionaries = true
        isEditingMode = false
        nameTextView = nil
        
        onGroupChanged?(groupId)
    }
    
    private func performDelete(groupId: String) {
        DictionaryService.shared.deleteGroup(id: groupId)

        editedName = nil
        hasUnsavedChanges = false
        currentMode = nil

        onDeleteComplete?(groupId)
    }
    
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
    
    // MARK: - Public API
    
    /// Show in creating mode (new group)
    func showCreatingMode(pendingName: String) {
        editedName = pendingName
        hasUnsavedChanges = true
        hasNameConflict = false
        hasEmptyName = false
        hasNoDictionaries = DictionaryService.shared.groupSession.pendingDictionaryIds.isEmpty
        isEditingMode = true
        nameTextView = nil
        
        // Subscribe to session's pending dict changes for stats + Done button
        dictCountCancellable = DictionaryService.shared.groupSession.$pendingDictionaryIds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                guard let self else { return }
                self.hasNoDictionaries = ids.isEmpty
                self.applyCurrentSnapshot()
            }
        
        currentMode = .creating(groupId: "pending")  // placeholder, real ID assigned on save
    }
    
    /// Show in managing mode (existing group)
    func showManagingMode(for groupId: String) {
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        hasEmptyName = false
        hasNoDictionaries = true
        isEditingMode = false
        nameTextView = nil
        
        // Subscribe to group's $items for stats update
        if let group = DictionaryService.shared.group(id: groupId) {
            dictCountCancellable = group.$items
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.applyCurrentSnapshot()
                }
        }
        
        currentMode = .managing(groupId: groupId)
    }
    
    /// Show in read-only mode for the default group
    func showViewingDefaultMode(for groupId: String) {
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        hasEmptyName = false
        hasNoDictionaries = false
        isEditingMode = false
        nameTextView = nil
        dictCountCancellable = nil
        
        currentMode = .viewingDefault(groupId: groupId)
    }
    
    /// Reset to idle state (no group selected). Called when exiting management mode.
    func resetToEmptyState() {
        dictCountCancellable = nil
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        hasEmptyName = false
        hasNoDictionaries = true
        isEditingMode = false
        nameTextView = nil
        currentMode = nil
    }
}

// MARK: - UICollectionViewDelegate

extension GroupInfoViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .containedItems:
            // In compact mode, this cell acts as navigation to the dictionary editor
            guard isSplitViewCollapsed else { return }
            guard let mode = currentMode else { return }
            switch mode {
            case .creating(let groupId), .managing(let groupId), .viewingDefault(let groupId):
                onManageDictionaries?(groupId)
            }
            
        case .deleteButton:
            showDeleteConfirmation()
            
        default:
            break
        }
    }
}

// MARK: - UITextViewDelegate

private let maxNameLength = 50

extension GroupInfoViewController: UITextViewDelegate {
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Block newlines (including pasted text with newlines)
        if text.rangeOfCharacter(from: .newlines) != nil { return false }
        // Enforce character limit
        let current = textView.text ?? ""
        let updated = (current as NSString).replacingCharacters(in: range, with: text)
        return updated.count <= maxNameLength
    }
    
    func textViewDidChange(_ textView: UITextView) {
        editedName = textView.text
        hasUnsavedChanges = true
        
        // Inline name conflict validation
        validateNameConflict()
        
        // Animate cell height change
        collectionView.collectionViewLayout.invalidateLayout()
    }
}

// MARK: - Name Validation

private extension GroupInfoViewController {
    
    func validateNameConflict() {
        let trimmed = (editedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let currentGroupId: String? = switch currentMode {
        case .creating(let id): id
        case .managing(let id): id
        case .viewingDefault: nil
        case .none: nil
        }
        
        // Check empty
        let empty = trimmed.isEmpty
        if empty != hasEmptyName {
            hasEmptyName = empty
            patchDisplayNameHeader()
        }
        
        // Check if any OTHER user group has this exact name
        let conflict = !trimmed.isEmpty && DictionaryService.shared.groups
            .filter { !$0.isDefault && $0.id != currentGroupId }
            .contains { $0.name == trimmed }
        
        if conflict != hasNameConflict {
            hasNameConflict = conflict
            // Patch header directly to avoid snapshot rebuild (which kills first responder)
            patchDisplayNameHeader()
        }
    }
    
    /// Directly update the visible displayName header without re-applying the snapshot.
    /// Used during text editing to preserve first responder.
    private func patchDisplayNameHeader() {
        let style = displayNameHeaderStyle
        let snapshot = dataSource.snapshot()
        // Find the displayName section regardless of its current HeaderStyle
        guard let sectionIndex = snapshot.sectionIdentifiers.firstIndex(where: {
            if case .displayName = $0 { return true }
            return false
        }) else { return }
        
        let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
        guard let headerView = collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader,
            at: headerIndexPath
        ) as? UICollectionViewListCell else { return }
        
        var content = headerView.defaultContentConfiguration()
        content.text = Section.displayName(style, isDefault: false).title
        switch style {
        case .plain:
            break
        case .active:
            content.image = .init(systemName: "pencil")
            content.imageProperties.tintColor = .tintColor
            content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
            content.textProperties.color = .tintColor
        case .empty:
            content.image = .init(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemRed
            content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
            content.text = L10n.GroupInfo.nameCannotBeEmpty
            content.textProperties.color = .systemRed
        case .conflict:
            content.image = .init(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemRed
            content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
            content.text = L10n.GroupInfo.nameAlreadyTaken
            content.textProperties.color = .systemRed
        }
        headerView.contentConfiguration = content
    }
}
