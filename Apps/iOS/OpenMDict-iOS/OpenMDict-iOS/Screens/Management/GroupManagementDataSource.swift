//
//  GroupManagementDataSource.swift
//  OpenMDict-iOS
//
//  Protocol abstracting service dependencies for GroupInfoVC and
//  GroupDictionaryEditorVC. Enables tutorial mock data injection
//  without coupling to DictionaryService, LookupCountService, etc.
//
//  Default implementation (`DefaultGroupManagementDataSource`) delegates
//  to the real singleton services — no behavior change for production code.
//

import Foundation
import Combine
import OpenMDictKit

// MARK: - Protocol

protocol GroupManagementDataSource: AnyObject {

    // MARK: Group/Dictionary Lookup

    /// Fetch a group by ID.
    func group(id: String) -> MDicts?

    /// Fetch a dictionary by ID.
    func dict(id: String) -> MDict?

    /// All imported dictionaries (for "available to add" list in editor).
    var allDictionaries: [MDict] { get }

    /// All groups (for name-conflict validation when renaming).
    var groups: [MDicts] { get }

    // MARK: Group Session (creating mode)

    /// The in-memory session for creating/editing groups.
    /// Tutorial mock returns a fake session; production returns real.
    var groupSession: GroupManagementSession { get }

    // MARK: Statistics

    /// Lookup count for a group (trophy counter).
    func lookupCount(contextGroupId: String) -> Int

    /// Bookmark count for a group (trophy counter).
    func bookmarkCount(contextGroupId: String) -> Int

    // MARK: Mutations

    /// Rename an existing group. Throws on failure.
    func renameGroup(id: String, newName: String) throws

    /// Delete an existing group.
    func deleteGroup(id: String)

    /// Create a new group. Returns the new group object.
    func createGroup(name: String) -> MDicts

    /// Reorder dictionaries within a group.
    func reorderDictionariesInGroup(groupId: String, newOrder: [String])

    /// Add a dictionary to a group.
    func addDictionaryToGroup(groupId: String, dictId: String)

    /// Remove a dictionary from a group.
    func removeDictionaryFromGroup(groupId: String, dictId: String)
}

// MARK: - Default Implementation

/// Production implementation that delegates to the real services.
final class DefaultGroupManagementDataSource: GroupManagementDataSource {

    static let shared = DefaultGroupManagementDataSource()
    private init() {}

    func group(id: String) -> MDicts? {
        DictionaryService.shared.group(id: id)
    }

    func dict(id: String) -> MDict? {
        DictionaryService.shared.dict(id: id)
    }

    var allDictionaries: [MDict] {
        DictionaryService.shared.allDictionaries
    }

    var groups: [MDicts] {
        DictionaryService.shared.groups
    }

    var groupSession: GroupManagementSession {
        DictionaryService.shared.groupSession
    }

    func lookupCount(contextGroupId: String) -> Int {
        LookupCountService.shared.lookupCount(contextDictId: nil, contextGroupId: contextGroupId)
    }

    func bookmarkCount(contextGroupId: String) -> Int {
        BookmarkCountService.shared.bookmarkCount(contextDictId: nil, contextGroupId: contextGroupId)
    }

    func renameGroup(id: String, newName: String) throws {
        try DictionaryService.shared.renameGroup(id: id, newName: newName)
    }

    func deleteGroup(id: String) {
        DictionaryService.shared.deleteGroup(id: id)
    }

    func createGroup(name: String) -> MDicts {
        DictionaryService.shared.createGroup(name: name)
    }

    func reorderDictionariesInGroup(groupId: String, newOrder: [String]) {
        DictionaryService.shared.reorderDictionariesInGroup(groupId: groupId, newOrder: newOrder)
    }

    func addDictionaryToGroup(groupId: String, dictId: String) {
        DictionaryService.shared.addDictionaryToGroup(groupId: groupId, dictId: dictId)
    }

    func removeDictionaryFromGroup(groupId: String, dictId: String) {
        DictionaryService.shared.removeDictionaryFromGroup(groupId: groupId, dictId: dictId)
    }
}
