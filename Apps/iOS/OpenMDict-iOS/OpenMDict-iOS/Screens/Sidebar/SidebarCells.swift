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
    var activeGroupId: String? { get }
    var activeDict: (id: String, mirrored: Bool)? { get }
}

// MARK: - Default Group Cell (All Dictionaries)

/// Cell for the "All Dictionaries" group.
/// - Always shows filled icon (books.vertical.fill)
/// - Blue background + white text when selected
final class DefaultGroupCell: UICollectionViewListCell {
    
    var group: MDicts?
    
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
    
    var group: MDicts?
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
/// - Loading state: spinner accessory, gray text
/// - Error state: exclamationmark.triangle icon
final class DefaultGroupDictCell: UICollectionViewListCell {
    
    var dict: MDict?
    var groupId: String?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let dict = dict, let groupId = groupId else { return }
        
        let isParentActive = stateProvider?.activeGroupId == groupId
        let isHighlightedBySelection = stateProvider?.activeDict?.id == dict.id
        let isDirectlySelected = state.isSelected || state.isHighlighted
        let loadState = dict.state
        
        var content = UIListContentConfiguration.sidebarCell()
        content.text = dict.metadata?.title ?? dict.id
        
        // Handle loading states first
        switch loadState {
        case .unloaded, .loading:
            // Gray text, spinner accessory
            content.image = UIImage(systemName: "book.closed.fill")
            content.textProperties.color = .secondaryLabel
            content.imageProperties.tintColor = .secondaryLabel
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            
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
                accessories = [.customView(configuration: spinnerConfig)]
            } else {
                accessories = []
            }
            
        case .error:
            // Error state - show warning icon
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.textProperties.color = .systemRed
            content.imageProperties.tintColor = .systemRed
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            accessories = []
            
        case .metadataLoaded, .loaded:
            // Normal loaded state - original logic
            if isParentActive {
                content.image = UIImage(systemName: "book.fill")
                content.imageProperties.tintColor = .systemBlue
                backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            } else if isDirectlySelected || isHighlightedBySelection {
                content.image = UIImage(systemName: "book.fill")
                content.textProperties.color = .white
                content.imageProperties.tintColor = .white
                
                var bg = UIBackgroundConfiguration.listSidebarCell()
                bg.backgroundColor = .systemBlue
                backgroundConfiguration = bg
            } else {
                content.image = UIImage(systemName: "book.closed.fill")
                backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            }
            accessories = []
        }
        
        contentConfiguration = content
    }
}

// MARK: - User Group Dictionary Cell (Mirror)

/// Cell for dictionaries inside user groups (mirrors/symbolic links).
/// - Shows outlined icon (book.closed or book)
/// - Light selection style (system default, not deep blue)
/// - Loading state: spinner accessory, gray text
/// - Error state: exclamationmark.triangle icon
final class UserGroupDictCell: UICollectionViewListCell {
    
    var dict: MDict?
    var groupId: String?
    weak var stateProvider: SidebarStateProvider?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let dict = dict else { return }
        
        let isParentActive = stateProvider?.activeGroupId == groupId
        let isSelected = state.isSelected || state.isHighlighted
        let isRelatedDictSelected = stateProvider?.activeDict?.id == dict.id
        let loadState = dict.state

        var content = UIListContentConfiguration.sidebarCell()
        content.text = dict.metadata?.title ?? dict.id
        
        // Handle loading states first
        switch loadState {
        case .unloaded, .loading:
            // Gray text, spinner accessory
            content.image = UIImage(systemName: "book.closed")
            content.textProperties.color = .secondaryLabel
            content.imageProperties.tintColor = .secondaryLabel
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            
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
            backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            accessories = []
            
        case .metadataLoaded, .loaded:
            // Normal loaded state - original logic
            if isParentActive {
                content.image = UIImage(systemName: "book")
                content.imageProperties.tintColor = .systemBlue
                backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            } else if isSelected || isRelatedDictSelected {
                content.image = UIImage(systemName: "book")
                content.imageProperties.tintColor = .systemBlue
                content.textProperties.color = .systemBlue
                
                var bg = UIBackgroundConfiguration.listSidebarCell()
                bg.backgroundColor = .tertiarySystemFill
                backgroundConfiguration = bg
            } else {
                content.image = UIImage(systemName: "book.closed")
                backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()
            }
            accessories = []
        }
        
        contentConfiguration = content
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

/// Cell for management actions (Import, Delete, Settings).
final class ManagementActionCell: UICollectionViewListCell {
    
    var item: SidebarItem?
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let item = item else { return }
        
        let isActive = state.isSelected || state.isHighlighted
        
        // Check if all dictionaries are loaded (for manageDicts item)
        let allDictsLoaded: Bool = {
            guard case .manageDicts = item else { return true }
            
            return DictionaryService.shared.allDictionaries.allSatisfy {
                switch $0.state {
                case .loaded, .error(_):
                    true
                default:
                    false
                }
            }
        }()
        
        var content = UIListContentConfiguration.sidebarCell()
        
        switch item {
        case .manageDicts:
            content.text = "My Library"
            content.image = UIImage(systemName: "square.grid.3x1.folder.badge.plus")
        case .settings:
            content.text = "App Settings"
            content.image = UIImage(systemName: "gearshape")
        default:
            break
        }
        
        // Apply styling based on state
        if !allDictsLoaded {
            // Disabled state - gray out
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
