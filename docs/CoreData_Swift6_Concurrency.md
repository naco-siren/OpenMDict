# Core Data under Swift 6 strict concurrency

How OpenMDict-iOS reconciles Core Data's threading model with Swift 6 strict
concurrency and a `MainActor` default isolation. The problem first surfaced
when the lookup-history feature moved its persistence to Core Data; the
pattern below is what the app has used since.

## Background

Project configuration:

- Swift 6 language mode (`SWIFT_VERSION = 6.0`)
- `-default-isolation=MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
- iOS deployment target 15.6

With this configuration every `@NSManaged` property of an Xcode-generated
`NSManagedObject` subclass (`codeGenerationType="class"`) is **implicitly
`@MainActor`**. Touching such a property inside a background
`ctx.perform { }` closure (which is `@Sendable`) produces:

```
Main actor-isolated property 'word' can not be mutated from a Sendable closure
```

## Approaches that did not work

| Approach | Result |
|---|---|
| `@preconcurrency import CoreData` | Downgrades the diagnostic to a note; nothing is actually fixed |
| `nonisolated(unsafe) let record = ...` | `unsafe` on a local binding does not propagate to the property-level actor isolation |
| `@unchecked Sendable` on `NSManagedObject` | Dangerous — `NSManagedObject` is genuinely not `Sendable` |

## The fix: manual codegen + `nonisolated class`

### Step 1 — turn off Xcode code generation for the entity

In the `.xcdatamodel/contents` XML, **remove** the `codeGenerationType`
attribute (do not set it to another value):

```xml
<!-- before: generated class, properties inherit MainActor -->
<entity name="LookupRecord" representedClassName="LookupRecord" syncable="YES" codeGenerationType="class">

<!-- after: Manual/None (no code generated) -->
<entity name="LookupRecord" representedClassName="LookupRecord" syncable="YES">
```

> Manual/None is represented by the **absence** of the attribute, not by
> `"manual/none"` or `"none"`. An unknown value triggers an Xcode assertion
> failure.

### Step 2 — write the class by hand as `nonisolated`

```swift
// LookupRecord+CoreDataClass.swift
import CoreData

@objc(LookupRecord)
nonisolated public class LookupRecord: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<LookupRecord> {
        return NSFetchRequest<LookupRecord>(entityName: "LookupRecord")
    }

    @NSManaged public var word: String?
    @NSManaged public var dictId: String?
    @NSManaged public var dictName: String?
    @NSManaged public var firstLookedUpAt: Date?
    @NSManaged public var lastLookedUpAt: Date?
    @NSManaged public var lookupCount: Int32
}
```

### Detail that matters: `@NSManaged` must live in the class body

`nonisolated` on a class only applies to members declared **inside the
class body**. `@NSManaged` properties placed in an extension pick up the
default isolation (`MainActor`) again and the warning returns.

```swift
// wrong: @NSManaged in an extension is still MainActor-isolated
nonisolated public class LookupRecord: NSManagedObject { }
extension LookupRecord {
    @NSManaged public var word: String?  // MainActor-isolated!
}

// right: @NSManaged in the class body inherits nonisolated
nonisolated public class LookupRecord: NSManagedObject {
    @NSManaged public var word: String?  // nonisolated
}
```

## Why `nonisolated` is correct for `NSManagedObject`

Core Data has its own thread-safety model — **context-queue confinement**:
an `NSManagedObject` may only be touched on the queue of the
`NSManagedObjectContext` that owns it, which `ctx.perform { }` guarantees.

That model is fundamentally incompatible with Swift actors:

- Actor model: an object is bound to one fixed actor (e.g. `MainActor`).
- Core Data model: the same entity class is instantiated by different
  contexts (`viewContext` on the main thread, background contexts elsewhere).

Marking the class `@MainActor` would make objects created by a background
context impossible to access legally. `nonisolated` does not abandon thread
safety; it **delegates it to Core Data's runtime rules**.

## Companion pattern: `Sendable` value types

`NSManagedObject` instances must not cross actor boundaries (they are not
`Sendable`). The UI layer receives data as `Sendable` value types instead:

```swift
// inside the service
struct HistoryRecord: Sendable {
    let objectID: NSManagedObjectID
    let word: String
    let dictId: String
    let dictName: String
    let lastLookedUpAt: Date?
}

// converted on viewContext (MainActor)
for managedRecord in fetchResults {
    let record = HistoryRecord(
        objectID: managedRecord.objectID,
        word: managedRecord.word ?? "",
        ...
    )
}
```

## Background-write pattern

The current architecture keeps an in-memory cache as the single source of
truth (the `DataRepository` pattern) and persists to Core Data in deferred
batches. Background contexts are used only for batch operations such as
`BookmarkService.clearAll()`:

```swift
// BookmarkService.clearAll() — batch delete still needs a background context
let ctx = self.stack.newBackgroundContext()
Task.detached {
    try? await ctx.perform(schedule: .immediate as NSManagedObjectContext.ScheduledTaskType) {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "BookmarkRecord")
        let batchDelete = NSBatchDeleteRequest(fetchRequest: request)
        batchDelete.resultType = .resultTypeObjectIDs
        let result = try ctx.execute(batchDelete) as? NSBatchDeleteResult
        if let objectIDs = result?.result as? [NSManagedObjectID] {
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                into: [viewContext]
            )
        }
    }
    // Notify downstream on the main actor through @Published (never NotificationCenter)
    await MainActor.run {
        BookmarkService.shared.revision += 1
    }
}
```

**No `NotificationCenter`**: every service publishes changes through a
Combine `@Published revision` counter; subscribers use
`$revision.dropFirst().receive(on: DispatchQueue.main).sink { }`.

## Requirements

- Swift 6.1+ compiler (SE-0449, `nonisolated` on class declarations)
- The project builds with Swift 6.2+ in the `SWIFT_VERSION = 6.0` language mode

## References

- [Swift Forums: defaultIsolation MainActor and Core Data background tasks](https://forums.swift.org/t/defaultisolation-mainactor-and-core-data-background-tasks/80569)
- [Apple Developer Forums: Using Core Data with the Swift 6 language mode](https://developer.apple.com/forums/thread/756807)
- [SE-0449: nonisolated for global actor cutoff](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md)
- [fatbobman: Default Actor Isolation](https://fatbobman.com/en/posts/default-actor-isolation/)
