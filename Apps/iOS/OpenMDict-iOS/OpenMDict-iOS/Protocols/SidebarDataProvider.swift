//
//  SidebarDataProvider.swift
//  OpenMDict-iOS
//
//  Abstracts the data sources used by DictionaryListViewController.
//  Production: DictionaryService + DictMetadataService singletons.
//  Tutorial: Mock implementations with static data.
//

import Combine
import OpenMDictKit

// MARK: - Dictionary Data Provider

/// Provides dictionary and group data to DictionaryListViewController.
protocol DictionaryDataProvider: AnyObject {
    // Synchronous accessors
    var groups: [MDicts] { get }
    var allDictionaries: [MDict] { get }
    func group(id: String) -> MDicts?
    func dict(id: String) -> MDict?

    // Reactive publishers
    var groupsPublisher: AnyPublisher<[MDicts], Never> { get }
    var allDictionariesPublisher: AnyPublisher<[MDict], Never> { get }
    var displayNameRevisionPublisher: AnyPublisher<UInt, Never> { get }

    // Mutations (group management)
    func reorderUserGroups(newOrder: [String])
    func deleteGroup(id: String)
}

// MARK: - Metadata Data Provider

/// Provides dictionary metadata (display names, sync status, download state)
/// to DictionaryListViewController.
protocol DictMetadataProvider: AnyObject {
    func find(dictId: String) -> DictMetadata?
    func loadAll() -> [DictMetadata]
    var downloadingDictIds: Set<String> { get }
    var revisionPublisher: AnyPublisher<UInt, Never> { get }
}

// MARK: - DictionaryService Conformance

extension DictionaryService: DictionaryDataProvider {
    var groupsPublisher: AnyPublisher<[MDicts], Never> {
        $groups.eraseToAnyPublisher()
    }
    var allDictionariesPublisher: AnyPublisher<[MDict], Never> {
        $allDictionaries.eraseToAnyPublisher()
    }
    var displayNameRevisionPublisher: AnyPublisher<UInt, Never> {
        $displayNameRevision.eraseToAnyPublisher()
    }
}

// MARK: - DictMetadataService Conformance

extension DictMetadataService: DictMetadataProvider {
    var revisionPublisher: AnyPublisher<UInt, Never> {
        $revision.eraseToAnyPublisher()
    }
}
