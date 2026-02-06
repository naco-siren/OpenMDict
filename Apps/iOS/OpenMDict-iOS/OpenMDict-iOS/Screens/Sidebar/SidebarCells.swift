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
}

// MARK: - Default Group Cell (All Dictionaries)

/// Cell for the "All Dictionaries" group.
/// - Always shows filled icon (books.vertical.fill)
/// - Blue background + white text when selected (only in lookup mode, not editing)
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
            content.imageProperties.tintColor = .systemBlue
            
            bg.backgroundColor = .clear
            
            accessories = [.outlineDisclosure(options: .init(style: .cell))]
        }
        
        contentConfiguration = content
        backgroundConfiguration = bg
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
        let isGroupActive = stateProvider?.activeGroupId == group.id
        
        // Only show selection highlight when NOT in edit mode
        let isSelected = isLookupMode && !isEditing && (state.isSelected || state.isHighlighted)
        
        var content = UIListContentConfiguration.sidebarCell()
        content.text = group.name
        content.image = UIImage(systemName: isGroupActive ? "books.vertical.fill" : "books.vertical")
        
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
            content.imageProperties.tintColor = .systemBlue
            
            bg.backgroundColor = .clear
            
            accessories = [.outlineDisclosure(options: .init(style: .cell))]
        }
        
        contentConfiguration = content
        backgroundConfiguration = bg
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
            
        case .metadataLoaded, .loaded:
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
                content.imageProperties.tintColor = .systemBlue
                content.textProperties.color = .label
                
                bg.backgroundColor = .clear
            } else {
                // Normal unselected state (including edit mode)
                content.image = UIImage(systemName: "book.closed.fill")
                content.imageProperties.tintColor = .systemBlue
                content.textProperties.color = .label
                
                bg.backgroundColor = .clear
            }
        }
        
        backgroundConfiguration = bg
        
        // Add info button in edit mode (for loaded dictionaries)
        if isEditing && (loadState == .metadataLoaded || loadState == .loaded) {
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
    
    private func createInfoButton(for dictId: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "info.circle"), for: .normal)
        button.tintColor = .systemBlue
        
        // Store dictId for action handler
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
                accessories = [.customView(configuration: spinnerConfig)]
            } else {
                accessories = []
            }
            
        case .error:
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.textProperties.color = .systemRed
            content.imageProperties.tintColor = .systemRed

            accessories = []
            
        case .metadataLoaded, .loaded:
            // Normal loaded state
            if isLookupMode && !isEditing && isParentActive {
                content.image = UIImage(systemName: "book")
                content.imageProperties.tintColor = .systemBlue

            } else if isSelected || isRelatedDictSelected {
                content.image = UIImage(systemName: "book")
                content.imageProperties.tintColor = .systemBlue
                content.textProperties.color = .systemBlue
                
                bg.backgroundColor = .tertiarySystemFill
                
            } else {
                content.image = UIImage(systemName: "book.closed")
            }
            accessories = []
        }
        
        contentConfiguration = content
        backgroundConfiguration = bg
    }
}

// MARK: - Section Header Cell

/// Cell for section headers ("My Groups", "Management").
final class SidebarHeaderCell: UICollectionViewListCell {
    
    var title: String?
    var isBold: Bool = false
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let title = title else { return }
        
        var content = UIListContentConfiguration.sidebarHeader()
        content.text = title
        if isBold {
            content.textProperties.font = .systemFont(ofSize: 13, weight: .bold)
        }
        
        contentConfiguration = content
        accessories = [.outlineDisclosure(options: .init(style: .header))]
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
        
        // Import Dictionary is only visible in edit mode, but other management
        // actions (Settings, etc.) should be disabled during edit mode
        let isDisabled = isEditing && item != .importDictionary
        
        var content = UIListContentConfiguration.sidebarCell()
        
        switch item {
        case .importDictionary:
            content.text = "Import Dictionary"
            content.image = UIImage(systemName: "plus.rectangle.on.folder")
        case .settings:
            content.text = "App Settings"
            content.image = UIImage(systemName: "gearshape")
        default:
            break
        }
        
        // Apply styling based on state
        if isDisabled {
            // Disabled state - gray text/icon
            content.textProperties.color = .tertiaryLabel
            content.imageProperties.tintColor = .tertiaryLabel
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
        } else if isActive {
            // Selected state - blue background + white text/icon
            content.textProperties.color = .white
            content.imageProperties.tintColor = .white

            var bg = UIBackgroundConfiguration.listSidebarCell()
            bg.backgroundColor = .systemBlue
            backgroundConfiguration = bg
        } else {
            // Normal state
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
        }
        
        contentConfiguration = content
        accessories = []
    }
}
