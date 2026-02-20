//
//  SidebarCells.swift
//  OpenMDict-iOS
//
//  Custom UICollectionViewListCell subclasses using updateConfiguration(using:)
//  This is the Apple-recommended approach from WWDC 2020 "Modern cell configuration"
//
//  Key principle: Cells query state from a provider and update themselves.
//  The VC just calls setNeedsUpdateConfiguration() when state changes.
//

import UIKit
import OpenMDictKit

// MARK: - iCloud Section Status

/// iCloud sync health for section headers and group cells.
enum ICloudSectionStatus {
    /// All healthy — `checkmark.icloud` (secondaryLabel)
    case healthy
    /// One or more dicts are still syncing — `arrow.trianglehead.clockwise.icloud` (secondaryLabel)
    case syncing
    /// Temporary issue (network, account temporarily unavailable) — `bolt.horizontal.icloud` (orange)
    case temporaryIssue
    /// Serious issue (no account, restricted) or child dicts have errors — `exclamationmark.icloud` (red)
    case error
}

// MARK: - State Provider Protocol

/// Protocol for cells to query the current selection state from the view controller.
/// This decouples cells from the specific VC implementation.
protocol SidebarStateProvider: AnyObject {
    var appMode: AppMode { get }
    var isEditingMode: Bool { get }

    var activeGroupId: String? { get }
    var activeDict: (id: String, mirrored: Bool)? { get }

    /// Called when info button is tapped on a dictionary cell
    func didTapInfoButton(forDictId dictId: String)

    /// Called when info button is tapped on a group cell
    func didTapInfoButton(forGroupId groupId: String)

    // MARK: - iCloud Sync Status

    /// Returns the CloudKit sync status for a dictionary, or nil if cloud sync is disabled.
    func cloudSyncStatus(forDictId dictId: String) -> CloudSyncStatus?

    /// Returns the section-level iCloud status, or nil if cloud sync is disabled.
    /// Considers both CKAccountStatus and child dict statuses.
    func iCloudSectionStatus() -> ICloudSectionStatus?

    /// Returns the group-level iCloud status, or nil if cloud sync is disabled.
    /// Shows warning if any dict in the group has error/tooLarge.
    func iCloudGroupStatus(forGroupId groupId: String) -> ICloudSectionStatus?

    /// Returns the aggregated iCloud status across all user groups, or nil if disabled.
    /// Used by the "My Groups" section header.
    func iCloudMyGroupsSectionStatus() -> ICloudSectionStatus?

    /// Called when sync status button is tapped on a dictionary cell
    func didTapSyncStatus(forDictId dictId: String)

    /// Called when iCloud status icon is tapped on a section header / group cell
    func didTapSectionSyncStatus()

    /// Called when iCloud status icon is tapped on a user group cell
    func didTapGroupSyncStatus(forGroupId groupId: String)
}

// MARK: - Default Group Cell (All Dictionaries)

/// Cell for the "All Dictionaries" group.
/// - Always shows filled icon (books.vertical.fill)
/// - Blue background + white text when selected (only in lookup mode, not editing)
/// - Edit mode: info button for viewing group info
final class DefaultGroupCell: UICollectionViewListCell {
    
    var group: MDicts?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let group = group else { return }

        let isLookupMode = stateProvider?.appMode == .lookup
        let isEditing = stateProvider?.isEditingMode ?? false

        var content = UIListContentConfiguration.sidebarCell()
        content.text = group.name
        content.image = UIImage(systemName: "books.vertical.fill")

        var bg = UIBackgroundConfiguration.listSidebarCell()

        // Only show selection highlight when NOT in edit mode
        let isActive = isLookupMode && !isEditing && (state.isSelected || state.isHighlighted)

        if isActive {
            content.textProperties.font = .systemFont(ofSize: 20, weight: .bold)
            content.textProperties.color = .white
            content.imageProperties.tintColor = .white

            bg.backgroundColor = .systemBlue

            accessories = [.outlineDisclosure(options: .init(style: .cell, tintColor: .white))]
        } else {
            content.textProperties.font = .systemFont(ofSize: 20, weight: .medium)
            content.textProperties.color = .label
            content.imageProperties.tintColor = isEditing ? .label : .systemBlue

            bg.backgroundColor = .clear

            var cellAccessories: [UICellAccessory] = [.outlineDisclosure(options: .init(style: .cell))]

            // iCloud status + info button in edit mode
            if isEditing {
                // iCloud section status (before info button)
                if let status = stateProvider?.iCloudSectionStatus() {
                    let syncButton = Self.createSectionSyncButton(status: status, target: self, action: #selector(sectionSyncTapped))
                    let syncConfig = UICellAccessory.CustomViewConfiguration(
                        customView: syncButton,
                        placement: .trailing(displayed: .always)
                    )
                    cellAccessories.append(.customView(configuration: syncConfig))
                }

                let infoButton = createInfoButton(for: group.id)
                let infoConfig = UICellAccessory.CustomViewConfiguration(
                    customView: infoButton,
                    placement: .trailing(displayed: .always)
                )
                cellAccessories.append(.customView(configuration: infoConfig))
            }

            accessories = cellAccessories
        }

        contentConfiguration = content
        backgroundConfiguration = bg
    }

    static func createSectionSyncButton(status: ICloudSectionStatus, target: Any, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        let iconName: String
        let tintColor: UIColor
        switch status {
        case .healthy:
            iconName = "checkmark.icloud"
            tintColor = .secondaryLabel
        case .syncing:
            iconName = "arrow.trianglehead.clockwise.icloud"
            tintColor = .secondaryLabel
        case .temporaryIssue:
            iconName = "bolt.horizontal.icloud"
            tintColor = .systemOrange
        case .error:
            iconName = "exclamationmark.icloud"
            tintColor = .systemRed
        }
        button.setImage(UIImage(systemName: iconName), for: .normal)
        button.tintColor = tintColor
        button.addTarget(target, action: action, for: .touchUpInside)
        return button
    }

    @objc private func sectionSyncTapped() {
        stateProvider?.didTapSectionSyncStatus()
    }

    private func createInfoButton(for groupId: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "info.circle"), for: .normal)
        button.tintColor = .systemBlue
        button.accessibilityIdentifier = groupId
        button.addTarget(self, action: #selector(infoButtonTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func infoButtonTapped(_ sender: UIButton) {
        guard let groupId = sender.accessibilityIdentifier else { return }
        stateProvider?.didTapInfoButton(forGroupId: groupId)
    }
}

// MARK: - User Group Cell

/// Cell for user-created dictionary groups.
/// - Shows outlined icon normally, filled when this group is active
/// - Blue background + white text when selected (only in lookup mode, not editing)
final class UserGroupCell: UICollectionViewListCell {
    
    var group: MDicts?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let group = group else { return }
        
        // Check if this group is the active one (for icon state)
        let isLookupMode = stateProvider?.appMode == .lookup
        let isEditing = stateProvider?.isEditingMode ?? false
        // let isGroupActive = stateProvider?.activeGroupId == group.id
        
        // Only show selection highlight when NOT in edit mode
        let isSelected = isLookupMode && !isEditing && (state.isSelected || state.isHighlighted)
        
        var content = UIListContentConfiguration.sidebarCell()
        content.text = group.name
        content.image = UIImage(systemName: isSelected ? "folder.fill" : "folder")
        
        var bg = UIBackgroundConfiguration.listSidebarCell()
        
        if isSelected {
            content.textProperties.font = .systemFont(ofSize: 18, weight: .semibold)
            content.textProperties.color = .white
            content.imageProperties.tintColor = .white
            
            bg.backgroundColor = .systemBlue
            
            accessories = [.outlineDisclosure(options: .init(style: .cell, tintColor: .white))]
        } else {
            content.textProperties.font = .systemFont(ofSize: 18, weight: .regular)
            content.textProperties.color = .label
            content.imageProperties.tintColor = isEditing ? .label : .systemBlue
            
            bg.backgroundColor = .clear
            
            var cellAccessories: [UICellAccessory] = [.outlineDisclosure(options: .init(style: .cell))]

            // Sync status + info button in edit mode
            if isEditing {
                // Group-level sync status (considers child dict issues)
                if let status = stateProvider?.iCloudGroupStatus(forGroupId: group.id) {
                    let syncButton = DefaultGroupCell.createSectionSyncButton(
                        status: status, target: self, action: #selector(groupSyncTapped)
                    )
                    syncButton.accessibilityIdentifier = group.id
                    let syncConfig = UICellAccessory.CustomViewConfiguration(
                        customView: syncButton,
                        placement: .trailing(displayed: .always)
                    )
                    cellAccessories.append(.customView(configuration: syncConfig))
                }

                let infoButton = createInfoButton(for: group.id)
                let infoConfig = UICellAccessory.CustomViewConfiguration(
                    customView: infoButton,
                    placement: .trailing(displayed: .always)
                )
                cellAccessories.append(.customView(configuration: infoConfig))
            }

            accessories = cellAccessories
        }

        contentConfiguration = content
        backgroundConfiguration = bg
    }

    @objc private func groupSyncTapped(_ sender: UIButton) {
        guard let groupId = sender.accessibilityIdentifier else { return }
        stateProvider?.didTapGroupSyncStatus(forGroupId: groupId)
    }

    private func createInfoButton(for groupId: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "info.circle"), for: .normal)
        button.tintColor = .systemBlue
        button.accessibilityIdentifier = groupId
        button.addTarget(self, action: #selector(infoButtonTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func infoButtonTapped(_ sender: UIButton) {
        guard let groupId = sender.accessibilityIdentifier else { return }
        stateProvider?.didTapInfoButton(forGroupId: groupId)
    }
}

// MARK: - Default Group Dictionary Cell

/// Cell for dictionaries inside "All Dictionaries".
/// - Always shows filled icon (book.closed.fill or book.fill)
/// - When parent group is active: open book with blue tint
/// - When directly selected: blue background + white (only in lookup mode)
/// - When highlighted by mirror selection: blue background + white (only in lookup mode)
/// - Loading state: spinner accessory, gray text
/// - Error state: exclamationmark.triangle icon
/// - Edit mode: info button accessory, NO selection highlight
final class DefaultGroupDictCell: UICollectionViewListCell {
    
    var dict: MDict?
    var groupId: String?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let dict = dict, let groupId = groupId else { return }
        
        let isLookupMode = stateProvider?.appMode == .lookup
        let isEditing = stateProvider?.isEditingMode ?? false
        
        let isParentActive = stateProvider?.activeGroupId == groupId
        let isHighlightedBySelection = stateProvider?.activeDict?.id == dict.id
        
        let loadState = dict.state
        
        // In edit mode: NEVER show selection highlight (blue background)
        // In lookup mode: show highlight if selected or if this dict is the active one
        let shouldHighlight =
            if !isLookupMode || isEditing {
                false
            } else {
                state.isSelected || state.isHighlighted || isHighlightedBySelection
            }
        
        var content = UIListContentConfiguration.sidebarCell()
        content.text = dict.preferredTitle
        
        var bg = UIBackgroundConfiguration.listSidebarCell()
        bg.backgroundColorTransformer = nil
        
        // Build accessories based on state
        var cellAccessories: [UICellAccessory] = []
        
        // Handle loading states first
        switch loadState {
        case .unloaded, .loading:
            // Gray text, spinner accessory
            content.image = UIImage(systemName: "book.closed.fill")
            content.textProperties.color = .secondaryLabel
            content.imageProperties.tintColor = .secondaryLabel
            
            bg.backgroundColor = .clear
            
            if loadState == .loading {
                // Show spinner
                let spinnerConfig = UICellAccessory.CustomViewConfiguration(
                    customView: {
                        let spinner = UIActivityIndicatorView(style: .medium)
                        spinner.startAnimating()
                        return spinner
                    }(),
                    placement: .trailing()
                )
                cellAccessories.append(.customView(configuration: spinnerConfig))
            }
            
        case .error:
            // Error state - show warning icon
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemRed
            content.textProperties.color = .systemRed
            
            bg.backgroundColor = .clear
            
        case .metadataLoaded:
            // Metadata loaded state - not yet available for lookup or management
            
            if shouldHighlight {
                // Selected state - blue background + white
                content.image = UIImage(systemName: "book.fill")
                content.imageProperties.tintColor = .white
                content.textProperties.color = .white
                
                bg.backgroundColor = .systemBlue
            } else if isLookupMode && !isEditing && isParentActive {
                // Parent group is active (but this dict not directly selected) - show open book with gray tint
                content.image = UIImage(systemName: "book.fill")
                content.imageProperties.tintColor = .secondaryLabel
                content.textProperties.color = .secondaryLabel
                
                bg.backgroundColor = .clear
            } else {
                // Normal unselected state (including edit mode)
                content.image = UIImage(systemName: "book.closed.fill")
                content.imageProperties.tintColor = .secondaryLabel
                content.textProperties.color = .secondaryLabel
                
                bg.backgroundColor = .clear
            }
            
        case .loaded:
            // Normal loaded state
            
            if shouldHighlight {
                // Selected state - blue background + white
                content.image = UIImage(systemName: "book.fill")
                content.imageProperties.tintColor = .white
                content.textProperties.color = .white
                
                bg.backgroundColor = .systemBlue
            } else if isLookupMode && !isEditing && isParentActive {
                // Parent group is active (but this dict not directly selected) - show open book with blue tint
                content.image = UIImage(systemName: "book.fill")
                content.imageProperties.tintColor = isEditing ? .label : .systemBlue
                content.textProperties.color = .label
                
                bg.backgroundColor = .clear
            } else {
                // Normal unselected state (including edit mode)
                content.image = UIImage(systemName: "book.closed.fill")
                content.imageProperties.tintColor = isEditing ? .label : .systemBlue
                content.textProperties.color = .label
                
                bg.backgroundColor = .clear
            }
        }
        
        backgroundConfiguration = bg
        
        // Add sync status + info button in edit mode (for loaded dictionaries)
        if isEditing && (loadState == .metadataLoaded || loadState == .loaded) {
            // Per-dict cloud sync status button
            if let syncStatus = stateProvider?.cloudSyncStatus(forDictId: dict.id) {
                let syncButton = createSyncStatusButton(for: dict.id, status: syncStatus)
                let syncConfig = UICellAccessory.CustomViewConfiguration(
                    customView: syncButton,
                    placement: .trailing(displayed: .always)
                )
                cellAccessories.append(.customView(configuration: syncConfig))
            }

            let infoButton = createInfoButton(for: dict.id)
            let infoConfig = UICellAccessory.CustomViewConfiguration(
                customView: infoButton,
                placement: .trailing(displayed: .always)
            )
            cellAccessories.append(.customView(configuration: infoConfig))
        }

        accessories = cellAccessories
        contentConfiguration = content
    }

    private func createSyncStatusButton(for dictId: String, status: CloudSyncStatus) -> UIButton {
        let button = UIButton(type: .system)
        let iconName: String
        let tintColor: UIColor
        switch status {
        case .synced:
            iconName = "checkmark.icloud"
            tintColor = .secondaryLabel
        case .pending:
            iconName = "arrow.clockwise.icloud"
            tintColor = .secondaryLabel
        case .tooLarge:
            iconName = "xmark.icloud"
            tintColor = .systemOrange
        case .error:
            iconName = "exclamationmark.icloud"
            tintColor = .systemRed
        }
        button.setImage(UIImage(systemName: iconName), for: .normal)
        button.tintColor = tintColor
        button.accessibilityIdentifier = dictId
        button.addTarget(self, action: #selector(syncStatusTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func syncStatusTapped(_ sender: UIButton) {
        guard let dictId = sender.accessibilityIdentifier else { return }
        stateProvider?.didTapSyncStatus(forDictId: dictId)
    }

    private func createInfoButton(for dictId: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "info.circle"), for: .normal)
        button.tintColor = .systemBlue
        button.accessibilityIdentifier = dictId
        button.addTarget(self, action: #selector(infoButtonTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func infoButtonTapped(_ sender: UIButton) {
        guard let dictId = sender.accessibilityIdentifier else { return }
        stateProvider?.didTapInfoButton(forDictId: dictId)
    }
}

// MARK: - User Group Dictionary Cell (Mirror)

/// Cell for dictionaries inside user groups (mirrors/symbolic links).
/// - Shows outlined icon (book.closed or book)
/// - Light selection style (system default, not deep blue) - only in lookup mode
/// - Loading state: spinner accessory, gray text
/// - Error state: exclamationmark.triangle icon
final class UserGroupDictCell: UICollectionViewListCell {
    
    var dict: MDict?
    var groupId: String?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let dict = dict else { return }
        
        let isLookupMode = stateProvider?.appMode == .lookup
        let isEditing = stateProvider?.isEditingMode ?? false
        
        let isParentActive = stateProvider?.activeGroupId == groupId
        let loadState = dict.state
        
        // Only show selection highlight when NOT in edit mode
        let isSelected = isLookupMode && !isEditing && (state.isSelected || state.isHighlighted)
        let isRelatedDictSelected = isLookupMode && !isEditing && (stateProvider?.activeDict?.id == dict.id)

        var content = UIListContentConfiguration.sidebarCell()
        content.text = dict.preferredTitle
        
        var bg = UIBackgroundConfiguration.listSidebarCell()
        bg.backgroundColorTransformer = nil
        
        var cellAccessories: [UICellAccessory] = []
        
        // Handle loading states first
        switch loadState {
        case .unloaded, .loading:
            // Gray text, spinner accessory
            content.image = UIImage(systemName: "book.closed")
            content.textProperties.color = .secondaryLabel
            content.imageProperties.tintColor = .secondaryLabel
            
            if loadState == .loading {
                let spinnerConfig = UICellAccessory.CustomViewConfiguration(
                    customView: {
                        let spinner = UIActivityIndicatorView(style: .medium)
                        spinner.startAnimating()
                        return spinner
                    }(),
                    placement: .trailing()
                )
                cellAccessories.append(.customView(configuration: spinnerConfig))
            }
            
        case .error:
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.textProperties.color = .systemRed
            content.imageProperties.tintColor = .systemRed
            
        case .metadataLoaded:
            // Metadata loaded state - not yet available for lookup or management
            if isSelected || isRelatedDictSelected {
                content.image = UIImage(systemName: "book")
                content.imageProperties.tintColor = .secondaryLabel
                content.textProperties.color = .secondaryLabel
                
                bg.backgroundColor = .tertiarySystemFill
                
            } else if isLookupMode && !isEditing && isParentActive {
                content.image = UIImage(systemName: "book")
                content.imageProperties.tintColor = .secondaryLabel
                content.textProperties.color = .secondaryLabel

            } else {
                content.image = UIImage(systemName: "book.closed")
                content.imageProperties.tintColor = .secondaryLabel
                content.textProperties.color = .secondaryLabel
            }
            
        case .loaded:
            // Normal loaded state
            if isSelected || isRelatedDictSelected {
                content.image = UIImage(systemName: "book")
                content.imageProperties.tintColor = .systemBlue
                content.textProperties.color = .systemBlue
                
                bg.backgroundColor = .tertiarySystemFill
                
            } else if isLookupMode && !isEditing && isParentActive {
                content.image = UIImage(systemName: "book")
                content.imageProperties.tintColor = .systemBlue

            } else {
                content.image = UIImage(systemName: "book.closed")
                content.imageProperties.tintColor = isEditing ? .label : .systemBlue
            }
        }
        
        accessories = cellAccessories
        contentConfiguration = content
        backgroundConfiguration = bg
    }
}

// MARK: - Section Header Cell

/// Cell for section headers ("My Groups", "Management").
final class SidebarHeaderCell: UICollectionViewListCell {

    var title: String?
    var isBold: Bool = false
    /// When true, this header shows an iCloud status trailing icon in edit mode.
    var showsSyncStatus: Bool = false
    weak var stateProvider: SidebarStateProvider?

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let title = title else { return }

        var content = UIListContentConfiguration.sidebarHeader()
        content.text = title
        if isBold {
            content.textProperties.font = .systemFont(ofSize: 13, weight: .bold)
        }

        contentConfiguration = content

        var cellAccessories: [UICellAccessory] = [.outlineDisclosure(options: .init(style: .header))]

        // iCloud status icon in edit mode (only for "My Groups" header)
        let isEditing = stateProvider?.isEditingMode ?? false
        if isEditing && showsSyncStatus, let status = stateProvider?.iCloudMyGroupsSectionStatus() {
            let button = DefaultGroupCell.createSectionSyncButton(
                status: status, target: self, action: #selector(syncStatusTapped)
            )
            let config = UICellAccessory.CustomViewConfiguration(
                customView: button,
                placement: .trailing(displayed: .always)
            )
            cellAccessories.append(.customView(configuration: config))
        }

        accessories = cellAccessories
    }

    @objc private func syncStatusTapped() {
        stateProvider?.didTapSectionSyncStatus()
    }
}

// MARK: - Management Action Cell

/// Cell for management actions (Import Dictionary, Settings).
/// Disabled (grayed out) when sidebar is in edit mode.
final class ManagementActionCell: UICollectionViewListCell {
    
    var item: SidebarItem?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let item = item else { return }
        
        let isActive = state.isSelected || state.isHighlighted
        let isEditing = stateProvider?.isEditingMode ?? false
        
        // Import Dictionary and Add Group (edit-mode versions) are always enabled.
        // Management section items are disabled during edit mode.
        let isDisabled = isEditing && item != .importDictionary && item != .addGroup
        
        var content = UIListContentConfiguration.sidebarCell()
        var bg = UIBackgroundConfiguration.listSidebarCell()
        
        switch item {
        case .importDictionary:
            content.text = L10n.Sidebar.importDictionary
            content.image = UIImage(systemName: "plus.circle")
        case .addGroup:
            content.text = L10n.Sidebar.addNewGroup
            content.image = UIImage(systemName: "folder.badge.plus")
        case .bookmarks:
            content.text = L10n.Sidebar.bookmarks
            content.image = UIImage(systemName: "bookmark")
        case .lookupHistory:
            content.text = L10n.Sidebar.lookupHistory
            content.image = UIImage(systemName: "clock.arrow.circlepath")
        case .mgmtAddGroup:
            content.text = L10n.Sidebar.addNewGroup
            content.image = UIImage(systemName: "folder.badge.plus")
        case .mgmtImportDictionary:
            content.text = L10n.Sidebar.importDictionary
            content.image = UIImage(systemName: "plus.circle")
        case .managePresets:
            content.text = L10n.Sidebar.downloadPresets
            content.image = UIImage(systemName: "icloud.and.arrow.down")
        case .settings:
            content.text = L10n.Sidebar.appSettings
            content.image = UIImage(systemName: "gearshape")
        default:
            break
        }
        
        // Apply styling based on state
        if isDisabled {
            // Disabled state - gray text/icon
            content.textProperties.color = .tertiaryLabel
            content.imageProperties.tintColor = .tertiaryLabel

            bg.backgroundColor = .clear
        } else if isActive {
            // Selected state - blue background + white text/icon
            content.textProperties.color = .white
            content.imageProperties.tintColor = .white

            bg.backgroundColor = .systemBlue
        } else {
            // Normal state
        }
        
        contentConfiguration = content
        backgroundConfiguration = bg
        
        accessories = []
    }
}
