//
//  PersistentHistoryExpiryTests.swift
//  OpenMDictKitTests
//
//  Pins the Core Data persistent-history mechanics that the iOS app's
//  CloudKit code depends on. `NSPersistentCloudKitContainer` anchors its
//  exporter on a persistent-history token; if the app deletes the
//  transaction that token points at, the next export fails with
//  NSPersistentHistoryTokenExpiredError (134301) and the mirroring delegate
//  resets ("HistoryExpired"), purging every mirrored row locally.
//
//  These tests run on macOS with a programmatic model and two SQLite stores
//  that mirror the app's "Default" (CloudKit) and "Local" configurations.
//

import Testing
import Foundation
@preconcurrency import CoreData

@Suite(.serialized)
struct PersistentHistoryExpiryTests {

    static let tokenExpiredCode = 134301   // NSPersistentHistoryTokenExpiredError

    /// Two-configuration model: `CloudItem` lives in "Default", `LocalItem` in "Local".
    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        func entity(_ name: String) -> NSEntityDescription {
            let e = NSEntityDescription()
            e.name = name
            e.managedObjectClassName = "NSManagedObject"
            let attr = NSAttributeDescription()
            attr.name = "title"
            attr.attributeType = .stringAttributeType
            attr.isOptional = true
            e.properties = [attr]
            return e
        }

        let cloud = entity("CloudItem")
        let local = entity("LocalItem")
        model.entities = [cloud, local]
        model.setEntities([cloud], forConfigurationName: "Default")
        model.setEntities([local], forConfigurationName: "Local")
        return model
    }

    struct Stack {
        let container: NSPersistentContainer
        let cloudStore: NSPersistentStore
        let localStore: NSPersistentStore
        let directory: URL

        func save(_ entityName: String) throws {
            let ctx = container.newBackgroundContext()
            try ctx.performAndWait {
                let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: ctx)
                object.setValue(UUID().uuidString, forKey: "title")
                try ctx.save()
            }
        }

        func token(for store: NSPersistentStore) -> NSPersistentHistoryToken? {
            container.persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: [store])
        }

        /// Returns the NSError thrown by `fetchHistory(after:)`, or nil on success.
        func fetchError(after token: NSPersistentHistoryToken?, store: NSPersistentStore) -> NSError? {
            let ctx = container.newBackgroundContext()
            var result: NSError?
            ctx.performAndWait {
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                request.affectedStores = [store]
                do {
                    _ = try ctx.execute(request)
                } catch {
                    result = error as NSError
                }
            }
            return result
        }

        func deleteHistory(before date: Date, stores: [NSPersistentStore]?) throws {
            let ctx = container.newBackgroundContext()
            try ctx.performAndWait {
                let request = NSPersistentHistoryChangeRequest.deleteHistory(before: date)
                if let stores { request.affectedStores = stores }
                try ctx.execute(request)
            }
        }

        func tearDown() {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func makeStack() throws -> Stack {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenMDictKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let container = NSPersistentContainer(name: "HistoryTest", managedObjectModel: makeModel())

        let cloudDesc = NSPersistentStoreDescription(url: dir.appendingPathComponent("cloud.sqlite"))
        cloudDesc.configuration = "Default"
        cloudDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        cloudDesc.shouldAddStoreAsynchronously = false

        let localDesc = NSPersistentStoreDescription(url: dir.appendingPathComponent("local.sqlite"))
        localDesc.configuration = "Local"
        localDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        localDesc.shouldAddStoreAsynchronously = false

        container.persistentStoreDescriptions = [cloudDesc, localDesc]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            if let error { loadError = error }
        }
        if let loadError { throw loadError }

        let coordinator = container.persistentStoreCoordinator
        let cloudStore = try #require(coordinator.persistentStore(for: cloudDesc.url!))
        let localStore = try #require(coordinator.persistentStore(for: localDesc.url!))
        return Stack(container: container, cloudStore: cloudStore, localStore: localStore, directory: dir)
    }

    // MARK: - Tests

    @Test("Deleting the transaction a token points at expires that token (134301), even with newer transactions")
    func deletedTokenRowExpires() throws {
        let stack = try Self.makeStack()
        defer { stack.tearDown() }

        try stack.save("CloudItem")
        try stack.save("CloudItem")
        let token = try #require(stack.token(for: stack.cloudStore))
        #expect(stack.fetchError(after: token, store: stack.cloudStore) == nil, "token is valid before the purge")

        // The old app purged with a date cutoff and no affectedStores.
        try stack.deleteHistory(before: .distantFuture, stores: [stack.cloudStore])

        let afterPurge = try #require(stack.fetchError(after: token, store: stack.cloudStore))
        #expect(afterPurge.domain == NSCocoaErrorDomain)
        #expect(afterPurge.code == Self.tokenExpiredCode)

        // New transactions do not "un-expire" the old token.
        try stack.save("CloudItem")
        let afterNewSave = try #require(stack.fetchError(after: token, store: stack.cloudStore))
        #expect(afterNewSave.code == Self.tokenExpiredCode)

        // A fresh token taken now works again.
        let fresh = try #require(stack.token(for: stack.cloudStore))
        #expect(stack.fetchError(after: fresh, store: stack.cloudStore) == nil)
    }

    @Test("A date cutoff older than every transaction leaves the token valid")
    func oldCutoffIsHarmless() throws {
        let stack = try Self.makeStack()
        defer { stack.tearDown() }

        try stack.save("CloudItem")
        let token = try #require(stack.token(for: stack.cloudStore))
        try stack.deleteHistory(before: Date().addingTimeInterval(-7 * 24 * 3600), stores: [stack.cloudStore])
        #expect(stack.fetchError(after: token, store: stack.cloudStore) == nil)
    }

    @Test("affectedStores confines the purge: the other store's token stays valid")
    func affectedStoresScopesThePurge() throws {
        let stack = try Self.makeStack()
        defer { stack.tearDown() }

        try stack.save("CloudItem")
        try stack.save("LocalItem")
        let cloudToken = try #require(stack.token(for: stack.cloudStore))
        let localToken = try #require(stack.token(for: stack.localStore))

        // What the fixed app does: purge the Local store only.
        try stack.deleteHistory(before: .distantFuture, stores: [stack.localStore])

        #expect(stack.fetchError(after: cloudToken, store: stack.cloudStore) == nil,
                "cloud token survives a Local-only purge")
        let localError = try #require(stack.fetchError(after: localToken, store: stack.localStore))
        #expect(localError.code == Self.tokenExpiredCode)
    }

    @Test("Without affectedStores the purge hits every store (the old app's bug)")
    func unscopedPurgeHitsBothStores() throws {
        let stack = try Self.makeStack()
        defer { stack.tearDown() }

        try stack.save("CloudItem")
        try stack.save("LocalItem")
        let cloudToken = try #require(stack.token(for: stack.cloudStore))
        let localToken = try #require(stack.token(for: stack.localStore))

        try stack.deleteHistory(before: .distantFuture, stores: nil)

        #expect(stack.fetchError(after: cloudToken, store: stack.cloudStore)?.code == Self.tokenExpiredCode)
        #expect(stack.fetchError(after: localToken, store: stack.localStore)?.code == Self.tokenExpiredCode)
    }
}
