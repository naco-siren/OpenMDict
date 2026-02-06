//
//  GroupManagementSession.swift
//  OpenMDict-iOS
//
//  Tracks whether a group create/edit workflow is in progress.
//  Symmetric to ImportSession — holds temporary state that has NOT
//  been persisted yet.
//
//  Key invariant: this session never mutates DictionaryService.groups.
//  On Done → caller uses DictionaryService.createGroup() / renameGroup() to persist.
//  On Cancel/abandon → caller invokes reset() which is a no-op on data layer.
//

import Foundation
import Combine

@MainActor
final class GroupManagementSession: ObservableObject {
    
    enum Mode: Equatable {
        /// Creating a new group. The group does NOT exist in DictionaryService yet.
        case creating(pendingName: String)
        /// Editing an existing (already persisted) group.
        case editing(groupId: String)
    }
    
    // MARK: - State
    
    @Published private(set) var mode: Mode?
    
    // MARK: - Computed
    
    var isActive: Bool { mode != nil }
    
    var isCreating: Bool {
        if case .creating = mode { return true }
        return false
    }
    
    var groupId: String? {
        switch mode {
        case .editing(let id): return id
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
    
    /// Begin a group creation workflow.
    /// Generates a unique default name but does NOT create the group in data layer.
    func beginCreate() {
        let name = DictionaryService.shared.uniqueGroupName(from: "New Group")
        mode = .creating(pendingName: name)
        print("📂 GroupSession: beginCreate → pending name \"\(name)\"")
    }
    
    /// Begin editing an existing (already persisted) group.
    func beginEdit(groupId: String) {
        mode = .editing(groupId: groupId)
        print("📂 GroupSession: beginEdit → \(groupId.prefix(8))...")
    }
    
    // MARK: - Reset
    
    /// Discard the session. No data layer cleanup needed since nothing was persisted.
    /// Safe to call multiple times (idempotent).
    func reset() {
        if mode != nil {
            print("📂 GroupSession: reset")
        }
        mode = nil
    }
}
