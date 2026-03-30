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
    static let jmdictId = "__tutorial_jmdict__"
    static let kanjidicId = "__tutorial_kanjidic__"
    static let unihanId = "__tutorial_unihan__"
    private static let defaultGroupId = "__tutorial_default_group__"
    private static let userGroupId = "__tutorial_user_group__"

    /// When true, includes a "Japanese" user group containing JMDict, KANJIDIC2, Unihan.
    let includeUserGroups: Bool

    init(includeUserGroups: Bool = false) {
        self.includeUserGroups = includeUserGroups
    }

    private let mockWordNet: MDict = {
        let metadata = MDictMetadata(
            title: "WordNet",
            description: "WordNet® is a large lexical database of English.",
            entryCount: 147_306,
            format: "MDict (MDX)",
            encoding: "UTF-8",
            engineVersion: "2.0",
            creationDate: "2026-03-01",
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
            creationDate: "2026-03-01",
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

    private let mockJMDict: MDict = {
        let metadata = MDictMetadata(
            title: "JMDict Japanese-English",
            description: "Japanese-Multilingual Dictionary Project.",
            entryCount: 214_883,
            format: "MDict (MDX)", encoding: "UTF-8", engineVersion: "2.0",
            creationDate: "2026-03-01", isEncrypted: false, isCaseSensitive: false,
            path: "", fileSize: 35_200_000, headerSHA256: jmdictId
        )
        return MDict(id: jmdictId, displayName: "JMDict Japanese-English", metadata: metadata)
    }()

    private let mockKANJIDIC: MDict = {
        let metadata = MDictMetadata(
            title: "KANJIDIC2",
            description: "Kanji dictionary with readings, meanings, and stroke data.",
            entryCount: 13_108,
            format: "MDict (MDX)", encoding: "UTF-8", engineVersion: "2.0",
            creationDate: "2026-03-01", isEncrypted: false, isCaseSensitive: false,
            path: "", fileSize: 8_900_000, headerSHA256: kanjidicId
        )
        return MDict(id: kanjidicId, displayName: "KANJIDIC2", metadata: metadata)
    }()

    private let mockUnihan: MDict = {
        let metadata = MDictMetadata(
            title: "Unihan CJK Characters",
            description: "Unicode Han Database — CJK unified ideographs.",
            entryCount: 98_562,
            format: "MDict (MDX)", encoding: "UTF-8", engineVersion: "2.0",
            creationDate: "2026-03-01", isEncrypted: false, isCaseSensitive: false,
            path: "", fileSize: 22_400_000, headerSHA256: unihanId
        )
        return MDict(id: unihanId, displayName: "Unihan CJK Characters", metadata: metadata)
    }()

    private lazy var userGroup: MDicts = {
        let group = MDicts(
            id: Self.userGroupId,
            name: "Japanese",
            isDefault: false,
            dictionaryIds: [Self.jmdictId, Self.kanjidicId, Self.unihanId]
        )
        group.populate(from: [mockJMDict, mockKANJIDIC, mockUnihan])
        return group
    }()

    // MARK: - DictionaryDataProvider

    var groups: [MDicts] {
        includeUserGroups ? [defaultGroup, userGroup] : [defaultGroup]
    }
    var allDictionaries: [MDict] {
        var dicts = [mockWordNet, mockGCIDE]
        if includeUserGroups { dicts += [mockJMDict, mockKANJIDIC, mockUnihan] }
        return dicts
    }

    func group(id: String) -> MDicts? {
        switch id {
        case Self.defaultGroupId: return defaultGroup
        case Self.userGroupId where includeUserGroups: return userGroup
        default: return nil
        }
    }

    func dict(id: String) -> MDict? {
        switch id {
        case Self.wordNetId: return mockWordNet
        case Self.gcideId: return mockGCIDE
        case Self.jmdictId where includeUserGroups: return mockJMDict
        case Self.kanjidicId where includeUserGroups: return mockKANJIDIC
        case Self.unihanId where includeUserGroups: return mockUnihan
        default: return nil
        }
    }

    // Static data — publishers emit once and never change
    var groupsPublisher: AnyPublisher<[MDicts], Never> {
        Just(groups).eraseToAnyPublisher()
    }
    var allDictionariesPublisher: AnyPublisher<[MDict], Never> {
        Just(allDictionaries).eraseToAnyPublisher()
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
        MockDictionaryDataProvider.jmdictId: DictMetadata(
            dictId: MockDictionaryDataProvider.jmdictId,
            displayName: "JMDict Japanese-English",
            originalFileName: "jmdict.mdx",
            importedAt: Date(), updatedAt: Date(),
            totalSizeKB: 34_375, mddCount: 0, cssCount: 0, jsCount: 0, fontsCount: 0,
            cloudSyncStatus: 0, enhanceDarkMode: false, enhanceDarkModeStrength: 0
        ),
        MockDictionaryDataProvider.kanjidicId: DictMetadata(
            dictId: MockDictionaryDataProvider.kanjidicId,
            displayName: "KANJIDIC2",
            originalFileName: "kanjidic2.mdx",
            importedAt: Date(), updatedAt: Date(),
            totalSizeKB: 8_691, mddCount: 0, cssCount: 0, jsCount: 0, fontsCount: 0,
            cloudSyncStatus: 0, enhanceDarkMode: false, enhanceDarkModeStrength: 0
        ),
        MockDictionaryDataProvider.unihanId: DictMetadata(
            dictId: MockDictionaryDataProvider.unihanId,
            displayName: "Unihan CJK Characters",
            originalFileName: "unihan.mdx",
            importedAt: Date(), updatedAt: Date(),
            totalSizeKB: 21_875, mddCount: 0, cssCount: 0, jsCount: 0, fontsCount: 0,
            cloudSyncStatus: 0, enhanceDarkMode: false, enhanceDarkModeStrength: 0
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
