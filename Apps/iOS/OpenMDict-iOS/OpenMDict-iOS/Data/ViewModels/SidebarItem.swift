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
    case importDictionary  // Child of All Dictionaries, visible only in Edit mode
    case addGroup          // Child of My Groups, visible in Edit mode or when no user groups
    case settings
    
    var itemId: String {
        switch self {
        case .header(let t, _): return "header:\(t)"
        case .group(let id, _): return "group:\(id)"
        case .dictionary(let id, let gid): return "dict:\(gid):\(id)"
        case .importDictionary: return "action:import"
        case .addGroup: return "action:addGroup"
        case .settings: return "action:settings"
        }
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(itemId) }
    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool { lhs.itemId == rhs.itemId }
}
