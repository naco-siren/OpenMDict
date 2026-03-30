//
//  MockSidebarDataProvider.swift
//  OpenMDict-iOS
//
//  Mock DictionaryDataProvider and DictMetadataProvider for the
//  Import & Resources and Dictionary Groups tutorials.
//  Provides static data (WordNet + GCIDE) without real MDX files.
//

import Combine
import Foundation
import OpenMDictKit

// MARK: - Mock Dictionary Data Provider

final class MockDictionaryDataProvider: DictionaryDataProvider {

    static let wordNetId = "__tutorial_wordnet__"
    static let gcideId = "__tutorial_gcide__"
    private static let defaultGroupId = "__tutorial_default_group__"

    private let mockWordNet: MDict = {
        let metadata = MDictMetadata(
            title: "WordNet",
            description: "WordNet® is a large lexical database of English.",
            entryCount: 147_306,
            format: "MDict (MDX)",
            encoding: "UTF-8",
            engineVersion: "2.0",
            creationDate: "2023-06-15",
            isEncrypted: false,
            isCaseSensitive: false,
            path: "",
            fileSize: 28_540_928,
            headerSHA256: wordNetId
        )
        return MDict(id: wordNetId, displayName: "Open English WordNet", metadata: metadata)
    }()

    private let mockGCIDE: MDict = {
        let metadata = MDictMetadata(
            title: "GCIDE - English Dictionary",
            description: "GNU Collaborative International Dictionary of English.",
            entryCount: 128_985,
            format: "MDict (MDX)",
            encoding: "UTF-8",
            engineVersion: "2.0",
            creationDate: "2022-11-20",
            isEncrypted: false,
            isCaseSensitive: false,
            path: "",
            fileSize: 42_987_520,
            headerSHA256: gcideId
        )
        return MDict(id: gcideId, displayName: "GCIDE - English Dictionary", metadata: metadata)
    }()

    private lazy var defaultGroup: MDicts = {
        let group = MDicts(
            id: Self.defaultGroupId,
            name: "All Dictionaries",
            isDefault: true,
            dictionaryIds: [Self.wordNetId, Self.gcideId]
        )
        group.populate(from: [mockWordNet, mockGCIDE])
        return group
    }()

    // MARK: - DictionaryDataProvider

    var groups: [MDicts] { [defaultGroup] }
    var allDictionaries: [MDict] { [mockWordNet, mockGCIDE] }

    func group(id: String) -> MDicts? {
        id == Self.defaultGroupId ? defaultGroup : nil
    }

    func dict(id: String) -> MDict? {
        switch id {
        case Self.wordNetId: return mockWordNet
        case Self.gcideId: return mockGCIDE
        default: return nil
        }
    }

    // Static data — publishers emit once and never change
    var groupsPublisher: AnyPublisher<[MDicts], Never> {
        Just([defaultGroup]).eraseToAnyPublisher()
    }
    var allDictionariesPublisher: AnyPublisher<[MDict], Never> {
        Just([mockWordNet, mockGCIDE]).eraseToAnyPublisher()
    }
    var displayNameRevisionPublisher: AnyPublisher<UInt, Never> {
        Just(0).eraseToAnyPublisher()
    }

    // No-ops for mutations
    func reorderUserGroups(newOrder: [String]) {}
    func deleteGroup(id: String) {}
}

// MARK: - Mock Metadata Provider

final class MockDictMetadataProvider: DictMetadataProvider {

    private let metadataMap: [String: DictMetadata] = [
        MockDictionaryDataProvider.wordNetId: DictMetadata(
            dictId: MockDictionaryDataProvider.wordNetId,
            displayName: "WordNet",
            originalFileName: "wordnet.mdx",
            importedAt: Date(),
            updatedAt: Date(),
            totalSizeKB: 27_872,
            mddCount: 0,
            cssCount: 0,
            jsCount: 0,
            fontsCount: 0,
            cloudSyncStatus: 0,
            enhanceDarkMode: false,
            enhanceDarkModeStrength: 0
        ),
        MockDictionaryDataProvider.gcideId: DictMetadata(
            dictId: MockDictionaryDataProvider.gcideId,
            displayName: "GCIDE",
            originalFileName: "gcide.mdx",
            importedAt: Date(),
            updatedAt: Date(),
            totalSizeKB: 41_980,
            mddCount: 1,
            cssCount: 1,
            jsCount: 0,
            fontsCount: 0,
            cloudSyncStatus: 0,
            enhanceDarkMode: false,
            enhanceDarkModeStrength: 0
        ),
    ]

    func find(dictId: String) -> DictMetadata? {
        metadataMap[dictId]
    }

    func loadAll() -> [DictMetadata] {
        Array(metadataMap.values)
    }

    var downloadingDictIds: Set<String> { [] }

    var revisionPublisher: AnyPublisher<UInt, Never> {
        Just(0).eraseToAnyPublisher()
    }
}
