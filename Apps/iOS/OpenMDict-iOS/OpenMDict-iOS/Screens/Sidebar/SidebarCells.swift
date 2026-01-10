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

// MARK: - State Provider Protocol

/// Protocol for cells to query the current selection state from the view controller.
/// This decouples cells from the specific VC implementation.
protocol SidebarStateProvider: AnyObject {
    var activeGroupId: String? { get }
    var activeDict: (id: String, mirrored: Bool)? { get }
}

// MARK: - Default Group Cell (All Dictionaries)

/// Cell for the "All Dictionaries" group.
/// - Always shows filled icon (books.vertical.fill)
/// - Blue background + white text when selected
final class DefaultGroupCell: UICollectionViewListCell {
    
    var group: DictionaryGroup?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let group = group else { return }
        
        var content = UIListContentConfiguration.sidebarCell()
        content.text = group.name
        content.image = UIImage(systemName: "books.vertical.fill")
        
        let isActive = state.isSelected || state.isHighlighted
        
        if isActive {
            content.textProperties.font = .systemFont(ofSize: 20, weight: .bold)
            content.textProperties.color = .white
            content.imageProperties.tintColor = .white
            
            var bg = UIBackgroundConfiguration.listSidebarCell()
            bg.backgroundColor = .systemBlue
            backgroundConfiguration = bg
            
            accessories = [.outlineDisclosure(options: .init(style: .cell, tintColor: .white))]
        } else {
            content.textProperties.font = .systemFont(ofSize: 20, weight: .medium)
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            accessories = [.outlineDisclosure(options: .init(style: .cell))]
        }
        
        contentConfiguration = content
    }
}

// MARK: - User Group Cell

/// Cell for user-created dictionary groups.
/// - Shows outlined icon normally, filled when this group is active
/// - Blue background + white text when selected
final class UserGroupCell: UICollectionViewListCell {
    
    var group: DictionaryGroup?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let group = group else { return }
        
        // Check if this group is the active one (for icon state)
        let isGroupActive = stateProvider?.activeGroupId == group.id
        let isSelected = state.isSelected || state.isHighlighted
        
        var content = UIListContentConfiguration.sidebarCell()
        content.text = group.name
        content.image = UIImage(systemName: isGroupActive ? "books.vertical.fill" : "books.vertical")
        
        if isSelected {
            content.textProperties.font = .systemFont(ofSize: 18, weight: .semibold)
            content.textProperties.color = .white
            content.imageProperties.tintColor = .white
            
            var bg = UIBackgroundConfiguration.listSidebarCell()
            bg.backgroundColor = .systemBlue
            backgroundConfiguration = bg
            
            accessories = [.outlineDisclosure(options: .init(style: .cell, tintColor: .white))]
        } else {
            content.textProperties.font = .systemFont(ofSize: 18, weight: .regular)
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            accessories = [.outlineDisclosure(options: .init(style: .cell))]
        }
        
        contentConfiguration = content
    }
}

// MARK: - Default Group Dictionary Cell

/// Cell for dictionaries inside "All Dictionaries".
/// - Always shows filled icon (book.closed.fill or book.fill)
/// - When parent group is active: open book with blue tint
/// - When directly selected: blue background + white
/// - When highlighted by mirror selection: blue background + white
final class DefaultGroupDictCell: UICollectionViewListCell {
    
    var dict: DictionaryItem?
    var groupId: String?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let dict = dict, let groupId = groupId else { return }
        
        let isParentActive = stateProvider?.activeGroupId == groupId
        let isHighlightedBySelection = stateProvider?.activeDict?.id == dict.id
        let isDirectlySelected = state.isSelected || state.isHighlighted
        
        var content = UIListContentConfiguration.sidebarCell()
        content.text = dict.name
        
        if isParentActive {
            // Parent group is selected - show open book with blue tint, no special background
            content.image = UIImage(systemName: "book.fill")
            content.imageProperties.tintColor = .systemBlue
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
        } else if isDirectlySelected || isHighlightedBySelection {
            // This dict is selected (directly or via mirror) - blue background
            content.image = UIImage(systemName: "book.fill")
            content.textProperties.color = .white
            content.imageProperties.tintColor = .white
            
            var bg = UIBackgroundConfiguration.listSidebarCell()
            bg.backgroundColor = .systemBlue
            backgroundConfiguration = bg
        } else {
            // Default state - closed filled book
            content.image = UIImage(systemName: "book.closed.fill")
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
        }
        
        contentConfiguration = content
        accessories = []
    }
}

// MARK: - User Group Dictionary Cell (Mirror)

/// Cell for dictionaries inside user groups (mirrors/symbolic links).
/// - Shows outlined icon (book.closed or book)
/// - Light selection style (system default, not deep blue)
final class UserGroupDictCell: UICollectionViewListCell {
    
    var dict: DictionaryItem?
    var groupId: String?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let dict = dict else { return }
        
        let isParentActive = stateProvider?.activeGroupId == groupId
        let isSelected = state.isSelected || state.isHighlighted
        let isRelatedDictSelected = stateProvider?.activeDict?.id == dict.id

        var content = UIListContentConfiguration.sidebarCell()
        content.text = dict.name
        
        if isParentActive {
            // Parent group is selected - open book with blue tint
            content.image = UIImage(systemName: "book")
            content.imageProperties.tintColor = .systemBlue
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
        } else if isSelected || isRelatedDictSelected {
            // This mirror is selected - light blue style (use blue tint, no custom background)
            content.image = UIImage(systemName: "book")
            content.imageProperties.tintColor = .systemBlue
            content.textProperties.color = .systemBlue
            
            var bg = UIBackgroundConfiguration.listSidebarCell()
            bg.backgroundColor = .tertiarySystemFill
            backgroundConfiguration = bg
        } else {
            // Default state - closed outlined book
            content.image = UIImage(systemName: "book.closed")
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
        }
        
        // Let system handle background (light blue for selection)
        contentConfiguration = content
        accessories = []
    }
}

// MARK: - Section Header Cell

/// Cell for section headers (User Groups, Management).
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

/// Cell for management actions (Import, Delete, Settings).
final class ManagementActionCell: UICollectionViewListCell {
    
    var item: SidebarItem?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let item = item else { return }
        
        var content = UIListContentConfiguration.sidebarCell()
        
        switch item {
        case .importDict:
            content.text = "Import Dictionary"
            content.image = UIImage(systemName: "square.and.arrow.down")
        case .deleteDict:
            content.text = "Delete Dictionaries"
            content.image = UIImage(systemName: "trash")
        case .settings:
            content.text = "App Settings"
            content.image = UIImage(systemName: "gearshape")
        default:
            break
        }
        
        contentConfiguration = content
        accessories = []
    }
}
