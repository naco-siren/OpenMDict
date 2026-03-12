//
//  SidebarItem.swift
//  OpenMDict-iOS
//
//  Sidebar cell identifier for DiffableDataSource.
//  Stores only IDs (not actual objects) to satisfy Sendable requirement.
//

import Foundation

/// Sidebar item identifier
/// Only stores IDs - actual objects retrieved from DictionaryService when needed
nonisolated enum SidebarItem: Hashable, Sendable {
    case header(String, isBold: Bool)
    case group(id: String, isDefault: Bool)
    case dictionary(id: String, groupId: String)
    case importDictionary      // Child of All Dictionaries, visible only in Edit mode
    case addGroup              // Child of My Groups, visible in Edit mode or when no user groups
    case bookmarks             // Management section: bookmarks list
    case lookupHistory         // Management section: lookup history list
    case mgmtAddGroup          // Management section: redundant "Add New Group" (always visible)
    case mgmtImportDictionary  // Management section: redundant "Import Dictionary" (always visible)
    case managePresets         // Management section: add/remove preset dictionaries
    case changeAppIcon         // Management section: change app icon
    case iCloudTroubleshoot    // Management section: iCloud troubleshooting (visible only when sync enabled)
    case settings

    var itemId: String {
        switch self {
        case .header(let t, _): return "header:\(t)"
        case .group(let id, _): return "group:\(id)"
        case .dictionary(let id, let gid): return "dict:\(gid):\(id)"
        case .importDictionary: return "action:import"
        case .addGroup: return "action:addGroup"
        case .bookmarks: return "action:bookmarks"
        case .lookupHistory: return "action:lookupHistory"
        case .mgmtAddGroup: return "action:mgmtAddGroup"
        case .mgmtImportDictionary: return "action:mgmtImport"
        case .managePresets: return "action:managePresets"
        case .changeAppIcon: return "action:changeAppIcon"
        case .iCloudTroubleshoot: return "action:iCloudTroubleshoot"
        case .settings: return "action:settings"
        }
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(itemId) }
    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool { lhs.itemId == rhs.itemId }
}
