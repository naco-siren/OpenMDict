//
//  GroupManagementSession.swift
//  OpenMDict-iOS
//
//  Tracks group create/manage workflow state.
//
//  Key invariant: this session never mutates DictionaryService.groups.
//  It holds temporary state (pending name, pending dictionary selections)
//  until the caller explicitly persists.
//
//  Creating: pendingDictionaryIds starts empty, user adds dicts in EditorVC,
//            GroupInfoVC Done → createGroup + setGroupDictionaries
//  Managing: pendingDictionaryIds snapshots from group.dictionaryIds on begin,
//            EditorVC modifications go directly to DictionaryService (immediate persist)
//

import Foundation
import Combine
import OpenMDictKit

@MainActor
final class GroupManagementSession: ObservableObject {
    
    enum Mode: Equatable {
        /// Creating a new group. Not yet in DictionaryService.
        case creating(pendingName: String)
        /// Managing an existing (persisted) group.
        case managing(groupId: String)
    }
    
    // MARK: - State
    
    @Published private(set) var mode: Mode?
    
    /// Dictionary IDs selected for this group.
    /// - Creating: in-memory only, persisted on group creation
    /// - Managing: snapshotted on begin, but EditorVC writes directly to service
    @Published var pendingDictionaryIds: [String] = []
    
    // MARK: - Computed
    
    var isActive: Bool { mode != nil }
    
    var isCreating: Bool {
        if case .creating = mode { return true }
        return false
    }
    
    var isManaging: Bool {
        if case .managing = mode { return true }
        return false
    }
    
    var groupId: String? {
        switch mode {
        case .managing(let id): return id
        default: return nil
        }
    }
    
    var pendingName: String? {
        switch mode {
        case .creating(let name): return name
        default: return nil
        }
    }
    
    // MARK: - Begin
    
    /// Begin creating a new group.
    /// Generates a unique default name. pendingDictionaryIds starts empty.
    func beginCreate() {
        let name = DictionaryService.shared.uniqueGroupName(from: "New Group")
        pendingDictionaryIds = []
        mode = .creating(pendingName: name)
        print("📂 GroupSession: beginCreate → pending name \"\(name)\"")
    }
    
    /// Begin managing an existing (persisted) group.
    /// Snapshots the group's current dictionaryIds into pendingDictionaryIds.
    func beginManaging(groupId: String) {
        let group = DictionaryService.shared.group(id: groupId)
        pendingDictionaryIds = group?.dictionaryIds ?? []
        mode = .managing(groupId: groupId)
        print("📂 GroupSession: beginManaging → \(groupId.prefix(8))... (\(pendingDictionaryIds.count) dicts)")
    }
    
    // MARK: - Reset
    
    /// Discard the session. No data layer cleanup needed.
    /// Safe to call multiple times (idempotent).
    func reset() {
        if mode != nil {
            print("📂 GroupSession: reset")
        }
        pendingDictionaryIds = []
        mode = nil
    }
}
