//
//  DictManagementDataSource.swift
//  OpenMDict-iOS
//
//  Protocol abstracting service dependencies for DictInfoVC and
//  DictResourceEditorVC. Enables tutorial mock data injection
//  without coupling to DictionaryService, LookupCountService, etc.
//
//  Default implementation (`DefaultDictManagementDataSource`) delegates
//  to the real singleton services — no behavior change for production code.
//

import Foundation
import Combine
import OpenMDictKit

// MARK: - Protocol

protocol DictManagementDataSource: AnyObject {

    // MARK: Dictionary Lookup

    /// Fetch an imported dictionary by ID.
    func dict(id: String) -> MDict?

    /// Date the dictionary was imported (from manifest).
    func importedDate(dictId: String) -> Date?

    // MARK: Statistics

    /// Lookup count for a dictionary (trophy counter).
    func lookupCount(dictId: String) -> Int

    /// Bookmark count for a dictionary (trophy counter).
    func bookmarkCount(dictId: String) -> Int

    // MARK: Mutations (DictInfoVC editing mode)

    /// Update the user-customized display name.
    func updateDisplayName(dictId: String, newName: String)

    /// Delete a dictionary. Throws on failure.
    func deleteDictionary(dictId: String) throws

    // MARK: Resources (DictResourceEditorVC editing mode)

    /// List all resource files for a dictionary.
    func resources(for dictId: String) -> [ResourceFile]

    /// Publisher that fires when resource files change (e.g. CloudKit sync).
    var resourceRevisionPublisher: AnyPublisher<UInt, Never> { get }

    /// Add a resource file. Returns the new file name.
    func addMDD(to dictId: String, from url: URL) async throws -> String
    func addCSS(to dictId: String, from url: URL) async throws -> String
    func addJS(to dictId: String, from url: URL) async throws -> String

    /// Remove a resource file.
    func removeMDD(from dictId: String, fileName: String) throws
    func removeCSS(from dictId: String, fileName: String) throws
    func removeJS(from dictId: String, fileName: String) throws
}

// MARK: - Default Implementation

/// Production implementation that delegates to the real services.
final class DefaultDictManagementDataSource: DictManagementDataSource {

    static let shared = DefaultDictManagementDataSource()
    private init() {}

    func dict(id: String) -> MDict? {
        DictionaryService.shared.dict(id: id)
    }

    func importedDate(dictId: String) -> Date? {
        DictionaryService.shared.importedDate(dictId)
    }

    func lookupCount(dictId: String) -> Int {
        LookupCountService.shared.lookupCount(contextDictId: dictId, contextGroupId: nil)
    }

    func bookmarkCount(dictId: String) -> Int {
        BookmarkCountService.shared.bookmarkCount(contextDictId: dictId, contextGroupId: nil)
    }

    func updateDisplayName(dictId: String, newName: String) {
        DictionaryService.shared.updateDisplayName(dictId: dictId, newName: newName)
    }

    func deleteDictionary(dictId: String) throws {
        try DictionaryService.shared.deleteDictionary(dictId: dictId)
    }

    func resources(for dictId: String) -> [ResourceFile] {
        DictionaryService.shared.resources(for: dictId)
    }

    var resourceRevisionPublisher: AnyPublisher<UInt, Never> {
        DictionaryService.shared.$resourceRevision.eraseToAnyPublisher()
    }

    func addMDD(to dictId: String, from url: URL) async throws -> String {
        try await DictionaryService.shared.addMDD(to: dictId, from: url)
    }

    func addCSS(to dictId: String, from url: URL) async throws -> String {
        try await DictionaryService.shared.addCSS(to: dictId, from: url)
    }

    func addJS(to dictId: String, from url: URL) async throws -> String {
        try await DictionaryService.shared.addJS(to: dictId, from: url)
    }

    func removeMDD(from dictId: String, fileName: String) throws {
        try DictionaryService.shared.removeMDD(from: dictId, fileName: fileName)
    }

    func removeCSS(from dictId: String, fileName: String) throws {
        try DictionaryService.shared.removeCSS(from: dictId, fileName: fileName)
    }

    func removeJS(from dictId: String, fileName: String) throws {
        try DictionaryService.shared.removeJS(from: dictId, fileName: fileName)
    }
}
