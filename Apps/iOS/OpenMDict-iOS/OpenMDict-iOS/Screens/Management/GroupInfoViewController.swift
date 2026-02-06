//
//  GroupInfoViewController.swift
//  OpenMDict-iOS
//
//  Group configuration view controller (second column in Management mode).
//  Symmetric to DictInfoViewController but much simpler — no file I/O.
//
//  Modes:
//  - Creating: New group with editable name, no delete
//  - Editing (viewing): Read-only name, stats, "Manage Dictionaries" (compact)
//  - Editing (editing): Editable name, delete button
//
//  Navigation:
//  - Regular mode: Cancel/Done/Edit buttons
//  - Compact mode: System back + "Manage Dictionaries" row to push third column
//

import UIKit
import OpenMDictKit

// MARK: - Mode

enum GroupConfigMode: Equatable {
    case creating(groupId: String)        // New group, always actively editing
    case managing(groupId: String)        // Existing group, view/edit toggle
}

// MARK: - View Controller

class GroupInfoViewController: UIViewController {
    
    // MARK: - Callbacks
    
    var onDismiss: (() -> Void)?
    
    /// Callback to push dictionary editor in compact mode
    var onManageDictionaries: ((String) -> Void)?
    
    /// Callback when a new group is created and saved
    var onCreateComplete: ((String) -> Void)?
    
    /// Callback when edit is saved
    var onEditComplete: ((String) -> Void)?
    
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
    /// - Editing mode: toggleable via Edit/Done buttons
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
    
    /// Edited display name (tracks changes)
    private var editedName: String?
    
    /// Computed header style for the displayName section.
    /// Encodes current mode + editing state + conflict into the Section enum
    /// so diffable data source naturally diffs and reconfigures the header.
    private var displayNameHeaderStyle: Section.HeaderStyle {
        guard let mode = currentMode else { return .plain }
        let isActivelyEditing: Bool = switch mode {
        case .creating: true
        case .managing: isEditingMode
        }
        guard isActivelyEditing else { return .plain }
        return hasNameConflict ? .conflict : .active
    }
    
    // MARK: - UI
    
    private nonisolated enum Section: Hashable {
        case manageDictionaries  // Button (compact mode only)
        case displayName(HeaderStyle)  // Group name with contextual header
        case stats               // Dictionary count, created/modified dates
        case dangerZone          // Delete button (editing mode only)
        
        /// Header style for displayName section, encoded so diffable data source
        /// naturally detects changes and reconfigures the supplementary view.
        enum HeaderStyle: Hashable {
            case plain      // viewing mode: default gray header
            case active     // editing: pencil icon + tintColor
            case conflict   // editing + name conflict: warning icon + red
        }
        
        var title: String? {
            switch self {
            case .manageDictionaries: return nil
            case .displayName: return "Group Name"
            case .stats: return "Info"
            case .dangerZone: return nil
            }
        }
    }
    
    private nonisolated enum Item: Hashable {
        // Actions
        case manageDictionariesButton
        
        // Display Name
        case nameLabel(current: String)    // Viewing mode: read-only
        case nameField(current: String)    // Editing mode: text view
        
        // Stats
        case dictionaryCount(Int)
        case createdDate(String)
        case modifiedDate(String)
        
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
        doneButton.isEnabled = hasUnsavedChanges && !hasNameConflict
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
        // MARK: Manage Dictionaries Button
        let manageDictsReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "books.vertical")
            content.imageProperties.tintColor = .white
            content.text = "Manage Dictionaries"
            content.textProperties.color = .white
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator(options: .init(tintColor: .white.withAlphaComponent(0.7)))]
            
            var bgConfig = UIBackgroundConfiguration.listGroupedCell()
            bgConfig.backgroundColor = .systemBlue
            bgConfig.cornerRadius = 10
            cell.backgroundConfiguration = bgConfig
        }
        
        // MARK: Name Label (viewing mode)
        let nameLabelReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, indexPath, value in
            var content = UIListContentConfiguration.cell()
            content.text = value.isEmpty ? "Untitled Group" : value
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
            content.text = "Delete Group"
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
            case .displayName(let style):
                content.text = section.title
                switch style {
                case .plain:
                    break  // default gray header
                case .active:
                    content.image = .init(systemName: "pencil")
                    content.imageProperties.tintColor = .tintColor
                    content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
                    content.textProperties.color = .tintColor
                case .conflict:
                    content.image = .init(systemName: "exclamationmark.triangle")
                    content.imageProperties.tintColor = .systemRed
                    content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
                    content.text = "This name is already taken"
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
            case .manageDictionariesButton:
                return collectionView.dequeueConfiguredReusableCell(using: manageDictsReg, for: indexPath, item: ())
                
            case .nameLabel(let value):
                return collectionView.dequeueConfiguredReusableCell(using: nameLabelReg, for: indexPath, item: value)
            case .nameField(let value):
                return collectionView.dequeueConfiguredReusableCell(using: nameFieldReg, for: indexPath, item: value)
                
            case .dictionaryCount(let count):
                let countStr = count == 1 ? "1 dictionary" : "\(count) dictionaries"
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("books.vertical", "Dictionaries", countStr))
            case .createdDate(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("calendar", "Created", value))
            case .modifiedDate(let value):
                return collectionView.dequeueConfiguredReusableCell(using: infoReg, for: indexPath, item: ("clock", "Modified", value))
                
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
            title = "Group"
            return
        }
        
        switch mode {
        case .creating:
            title = "New Group"
            isEditingMode = true
            hasUnsavedChanges = true  // New group always has "changes" to save
            
        case .managing(let groupId):
            let group = DictionaryService.shared.group(id: groupId)
            title = group?.name ?? "Group"
            if !isEditingMode {
                hasUnsavedChanges = false
            }
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
        }
    }
    
    private func applyCurrentSnapshot() {
        guard let mode = currentMode else { return }
        
        switch mode {
        case .creating(let groupId):
            applyCreatingSnapshot(groupId: groupId)
        case .managing(let groupId):
            applyManagingSnapshot(groupId: groupId)
        }
    }
    
    private func applyCreatingSnapshot(groupId: String) {
        let group = DictionaryService.shared.group(id: groupId)
        let name = editedName ?? group?.name ?? "New Group"
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        // SECTION: Manage Dictionaries (compact only)
        if isSplitViewCollapsed {
            snapshot.appendSections([.manageDictionaries])
            snapshot.appendItems([.manageDictionariesButton], toSection: .manageDictionaries)
        }
        
        // SECTION: Name (always editable in creating mode)
        let nameSection = Section.displayName(displayNameHeaderStyle)
        snapshot.appendSections([nameSection])
        snapshot.appendItems([.nameField(current: name)], toSection: nameSection)
        
        // SECTION: Stats
        snapshot.appendSections([.stats])
        let count = group?.dictionaryIds.count ?? 0
        snapshot.appendItems([.dictionaryCount(count)], toSection: .stats)
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    private func applyManagingSnapshot(groupId: String) {
        guard let group = DictionaryService.shared.group(id: groupId) else {
            debugLog("⚠️ applyManagingSnapshot: group not found for \(groupId.prefix(8))...")
            return
        }
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let name = editedName ?? group.name
        let nameSection = Section.displayName(displayNameHeaderStyle)
        
        if isEditingMode {
            // EDITING MODE: editable name + delete
            snapshot.appendSections([nameSection])
            snapshot.appendItems([.nameField(current: name)], toSection: nameSection)
            
            snapshot.appendSections([.dangerZone])
            snapshot.appendItems([.deleteButton], toSection: .dangerZone)
            
        } else {
            // VIEWING MODE: read-only name, manage dicts button, stats
            
            // Manage Dictionaries (compact only)
            if isSplitViewCollapsed {
                snapshot.appendSections([.manageDictionaries])
                snapshot.appendItems([.manageDictionariesButton], toSection: .manageDictionaries)
            }
            
            snapshot.appendSections([nameSection])
            snapshot.appendItems([.nameLabel(current: name)], toSection: nameSection)
            
            snapshot.appendSections([.stats])
            let count = group.dictionaryIds.count
            snapshot.appendItems([
                .dictionaryCount(count),
            ], toSection: .stats)
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    // MARK: - Navigation Actions
    
    @objc private func editTapped() {
        isEditingMode = true
    }
    
    @objc private func cancelTapped() {
        guard let mode = currentMode else { return }
        
        switch mode {
        case .creating:
            // Cancel creating - delete the group and dismiss
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
        }
    }
    
    private func exitEditingMode() {
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        isEditingMode = false
        nameTextView = nil
    }
    
    // MARK: - Alerts
    
    private func showAbandonCreateAlert() {
        let alert = UIAlertController(
            title: "Discard New Group?",
            message: "The new group will not be saved.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.performCancelCreate()
        })
        present(alert, animated: true)
    }
    
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
    
    private func showDeleteConfirmation() {
        guard case .managing(let groupId) = currentMode else { return }
        let group = DictionaryService.shared.group(id: groupId)
        let groupName = group?.name ?? "this group"
        
        let alert = UIAlertController(
            title: "Delete Group",
            message: "Delete \"\(groupName)\"? Dictionaries in this group will not be removed.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.performDelete(groupId: groupId)
        })
        present(alert, animated: true)
    }
    
    // MARK: - Perform Actions
    
    /// Cancel creating - just discard session state (groups was never modified)
    private func performCancelCreate() {
        DictionaryService.shared.groupSession.reset()
        
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        nameTextView = nil
        currentMode = nil
        
        onDismiss?()
        
        if isSplitViewCollapsed, let splitVC = findSplitViewController() {
            splitVC.show(.primary)
        }
    }
    
    private func performSaveCreate(groupId: String) {
        let name = (editedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "New Group" : name
        
        // Actually create the group in data layer (append to groups + persist)
        do {
            let group = try DictionaryService.shared.createGroup(name: finalName)
            
            DictionaryService.shared.groupSession.reset()
            
            editedName = nil
            hasUnsavedChanges = false
            hasNameConflict = false
            nameTextView = nil
            
            onCreateComplete?(group.id)
        } catch {
            debugLog("❌ Failed to create group: \(error)")
        }
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
        isEditingMode = false
        nameTextView = nil
        
        onEditComplete?(groupId)
    }
    
    private func performDelete(groupId: String) {
        do {
            try DictionaryService.shared.deleteGroup(id: groupId)
            
            editedName = nil
            hasUnsavedChanges = false
            currentMode = nil
            
            onDeleteComplete?(groupId)
        } catch {
            let alert = UIAlertController(
                title: "Delete Failed",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
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
        isEditingMode = true
        nameTextView = nil
        currentMode = .creating(groupId: "pending")  // placeholder, real ID assigned on save
    }
    
    /// Show in editing mode (existing group)
    func showManagingMode(for groupId: String) {
        editedName = nil
        hasUnsavedChanges = false
        hasNameConflict = false
        isEditingMode = false
        nameTextView = nil
        currentMode = .managing(groupId: groupId)
    }
}

// MARK: - UICollectionViewDelegate

extension GroupInfoViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .manageDictionariesButton:
            guard let mode = currentMode else { return }
            switch mode {
            case .creating(let groupId), .managing(let groupId):
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

extension GroupInfoViewController: UITextViewDelegate {
    
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
        case .none: nil
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
        content.text = Section.displayName(style).title
        switch style {
        case .plain:
            break
        case .active:
            content.image = .init(systemName: "pencil")
            content.imageProperties.tintColor = .tintColor
            content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
            content.textProperties.color = .tintColor
        case .conflict:
            content.image = .init(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemRed
            content.imageProperties.preferredSymbolConfiguration = .init(scale: .medium)
            content.text = "This name is already taken"
            content.textProperties.color = .systemRed
        }
        headerView.contentConfiguration = content
    }
}
