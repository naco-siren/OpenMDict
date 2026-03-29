//
//  MockDictManagementDataSource.swift
//  OpenMDict-iOS
//
//  Mock data source for the Import & Resources tutorial.
//  Provides a fake WordNet dictionary with pre-populated metadata,
//  resources, and statistics — no real files or services involved.
//

import Foundation
import Combine
import OpenMDictKit

final class MockDictManagementDataSource: DictManagementDataSource {

    static let tutorialDictId = "__tutorial_wordnet__"
    static let tutorialDictName = "WordNet 3.0"

    // MARK: - Mock MDict

    private lazy var mockDict: MDict = {
        let metadata = MDictMetadata(
            title: "WordNet",
            description: "<p>WordNet® is a large lexical database of English.</p>",
            entryCount: 147_306,
            format: "MDict (MDX)",
            encoding: "UTF-8",
            engineVersion: "2.0",
            creationDate: "2023-06-15",
            isEncrypted: false,
            isCaseSensitive: false,
            path: "",
            fileSize: 28_540_928,  // ~28 MB
            headerSHA256: Self.tutorialDictId
        )
        return MDict(id: Self.tutorialDictId, displayName: Self.tutorialDictName, metadata: metadata)
    }()

    // MARK: - DictManagementDataSource

    func dict(id: String) -> MDict? {
        id == Self.tutorialDictId ? mockDict : nil
    }

    func importedDate(dictId: String) -> Date? {
        // Fake: imported 30 days ago
        Calendar.current.date(byAdding: .day, value: -30, to: Date())
    }

    func lookupCount(dictId: String) -> Int { 514 }
    func bookmarkCount(dictId: String) -> Int { 114 }

    func updateDisplayName(dictId: String, newName: String) {
        // No-op in tutorial
    }

    func deleteDictionary(dictId: String) throws {
        // No-op in tutorial
    }

    // MARK: - Resources

    func resources(for dictId: String) -> [ResourceFile] {
        [
            ResourceFile(
                id: "wordnet.mdx", type: .mdx,
                fileName: "wordnet.mdx", hash: "abc123", fileSize: 28_540_928
            ),
            ResourceFile(
                id: "wordnet.mdd", type: .mdd,
                fileName: "wordnet.mdd", hash: "def456", fileSize: 15_728_640
            ),
        ]
    }

    var resourceRevisionPublisher: AnyPublisher<UInt, Never> {
        Just(0).eraseToAnyPublisher()
    }

    func addMDD(to dictId: String, from url: URL) async throws -> String { "mock.mdd" }
    func addCSS(to dictId: String, from url: URL) async throws -> String { "mock.css" }
    func addJS(to dictId: String, from url: URL) async throws -> String { "mock.js" }

    func removeMDD(from dictId: String, fileName: String) throws {}
    func removeCSS(from dictId: String, fileName: String) throws {}
    func removeJS(from dictId: String, fileName: String) throws {}
}
