//
//  MockGroupManagementDataSource.swift
//  OpenMDict-iOS
//
//  Mock GroupManagementDataSource for the Dictionary Groups tutorial.
//  Provides a "Japanese" group with JMDict, KANJIDIC2, Unihan members
//  and fake statistics (lookup=514, bookmarks=114).
//

import Foundation
import Combine
import OpenMDictKit

final class MockGroupManagementDataSource: GroupManagementDataSource {

    static let tutorialGroupId = "__tutorial_user_group__"

    // Reuse the shared mock dicts from MockDictionaryDataProvider
    private let dictProvider: MockDictionaryDataProvider

    init(dictProvider: MockDictionaryDataProvider) {
        self.dictProvider = dictProvider
    }

    func group(id: String) -> MDicts? {
        dictProvider.group(id: id)
    }

    func dict(id: String) -> MDict? {
        dictProvider.dict(id: id)
    }

    var allDictionaries: [MDict] {
        dictProvider.allDictionaries
    }

    var groups: [MDicts] {
        dictProvider.groups
    }

    var groupSession: GroupManagementSession {
        // Tutorial doesn't use creating mode — return the real session
        // (it won't be accessed since we only use managing mode)
        DictionaryService.shared.groupSession
    }

    func lookupCount(contextGroupId: String) -> Int { 514 }
    func bookmarkCount(contextGroupId: String) -> Int { 114 }

    // No-ops for mutations (tutorial is view-only)
    func renameGroup(id: String, newName: String) throws {}
    func deleteGroup(id: String) {}
    func createGroup(name: String) -> MDicts { MDicts() }
    func reorderDictionariesInGroup(groupId: String, newOrder: [String]) {}
    func addDictionaryToGroup(groupId: String, dictId: String) {}
    func removeDictionaryFromGroup(groupId: String, dictId: String) {}
}
