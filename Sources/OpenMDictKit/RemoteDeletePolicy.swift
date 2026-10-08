//
//  RemoteDeletePolicy.swift
//  OpenMDictKit
//
//  Decides what a dictionary whose CloudKit-mirrored metadata row has
//  disappeared means, WITHOUT ever treating the absence of a row as proof
//  that another device deleted the dictionary.
//
//  Why: `NSPersistentCloudKitContainer` can reset its mirror at any time
//  (expired persistent-history token, expired server change token, zone
//  deleted, account change). A reset purges every mirrored row locally and
//  re-imports the zone afterwards. On 2026-10-08 an iPad that had been idle
//  for three months went through exactly that, and the app — which equated
//  "row gone" with "remote delete" — removed all eleven dictionaries from
//  disk and then re-downloaded them.
//
//  The policy therefore only nominates *candidates* for deletion. The caller
//  must still confirm each candidate against CloudKit itself (the manifest
//  record is deleted by a real remote delete, but survives a mirror reset)
//  before touching any file. Dictionaries that were never uploaded are never
//  nominated: CloudKit has no copy to recover them from.
//

import Foundation

public struct RemoteDeleteEvaluation: Equatable, Sendable {
    /// Every loaded dictionary whose metadata row is currently missing,
    /// with the time the absence was first observed.
    public var pending: [String: Date]
    /// Missing dictionaries the caller should now verify against CloudKit.
    public var candidates: Set<String>
    /// Previously pending dictionaries whose row is back. Nothing to do:
    /// they were never unloaded.
    public var reappeared: Set<String>
    /// Missing dictionaries that CloudKit cannot restore (never uploaded).
    /// These are never auto-deleted.
    public var unrecoverable: Set<String>
    /// `true` when every missing dictionary was held back because a
    /// mirroring reset is in progress.
    public var heldForReset: Bool

    public init(
        pending: [String: Date] = [:],
        candidates: Set<String> = [],
        reappeared: Set<String> = [],
        unrecoverable: Set<String> = [],
        heldForReset: Bool = false
    ) {
        self.pending = pending
        self.candidates = candidates
        self.reappeared = reappeared
        self.unrecoverable = unrecoverable
        self.heldForReset = heldForReset
    }
}

public enum RemoteDeletePolicy {

    /// - Parameters:
    ///   - loadedIds: Dictionaries currently loaded in memory.
    ///   - metadataIds: Dictionaries that currently have a metadata row.
    ///   - previousPending: The `pending` map returned by the previous call.
    ///   - recoverableFromCloud: Dictionaries whose last known sync status
    ///     said their files are in CloudKit (`.synced`).
    ///   - lastSuccessfulImportEnd: End time of the most recent successful
    ///     CloudKit import, if any was observed in this process.
    ///   - resetSuspected: A mirroring reset has been detected and no
    ///     successful import has completed since.
    ///   - lastVerifiedAfter: Per dictionary, the import end time that was
    ///     current when the caller last verified it against CloudKit. A
    ///     dictionary is only re-verified once a newer import has completed.
    ///   - now: Current time (injected for tests).
    public static func evaluate(
        loadedIds: Set<String>,
        metadataIds: Set<String>,
        previousPending: [String: Date],
        recoverableFromCloud: Set<String>,
        lastSuccessfulImportEnd: Date?,
        resetSuspected: Bool,
        lastVerifiedAfter: [String: Date],
        now: Date
    ) -> RemoteDeleteEvaluation {
        let missing = loadedIds.subtracting(metadataIds)

        var evaluation = RemoteDeleteEvaluation()
        evaluation.reappeared = Set(previousPending.keys).subtracting(missing)

        for id in missing {
            evaluation.pending[id] = previousPending[id] ?? now
        }

        guard !missing.isEmpty else { return evaluation }

        if resetSuspected {
            evaluation.heldForReset = true
            return evaluation
        }

        for id in missing {
            guard recoverableFromCloud.contains(id) else {
                evaluation.unrecoverable.insert(id)
                continue
            }
            guard let importEnd = lastSuccessfulImportEnd else { continue }
            if let verifiedAfter = lastVerifiedAfter[id], importEnd <= verifiedAfter {
                // Already verified against CloudKit since the last import.
                continue
            }
            evaluation.candidates.insert(id)
        }
        return evaluation
    }
}
