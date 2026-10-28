//
//  PresetVersioning.swift
//  OpenMDictKit
//
//  Pure rules for updating an installed preset dictionary to the build that
//  ships with a newer app.
//
//  A preset is installed under the SHA-256 of the MDX file it was first
//  installed from, and that dictionary ID never changes: bookmarks, history,
//  groups, settings, the user's own resources and the iCloud records all
//  refer to it. An update replaces the MDX file in place on one device, so
//  devices running different app versions each show the build their app
//  ships, and nothing has to be coordinated between them.
//
//  The catalog records the hash of the build it ships (`sha256`) and of every
//  build that shipped before it (`previousSha256`):
//    * a dictionary with a preset's file name is that preset when its ID is
//      one of those hashes (user imports are identified by the MDX header
//      hash, never by a whole-file hash);
//    * its MDX on this device is out of date when the file's own hash (which
//      differs from the ID after an update) is an earlier build. Nothing is
//      offered until the file has been hashed: a copy downloaded from iCloud
//      can hold a later build under an earlier build's ID.
//

import Foundation

/// One installed dictionary with a preset's file name.
public struct InstalledPresetCopy: Equatable, Sendable {
    /// The dictionary ID.
    public let dictId: String
    /// SHA-256 of the MDX file on this device, once it has been hashed.
    /// Unknown until then: the ID is not proof — a copy downloaded from
    /// iCloud can hold a later build under an earlier build's ID.
    public let fileSha256: String?

    public init(dictId: String, fileSha256: String?) {
        self.dictId = dictId
        self.fileSha256 = fileSha256
    }
}

public enum PresetInstallState: Equatable, Sendable {
    /// No dictionary with the preset's file name is installed.
    case notInstalled
    /// The preset is installed and this device has the build the catalog
    /// ships (or a newer one, from a newer app).
    case current(dictId: String)
    /// These copies of the preset have an earlier build on this device.
    case updateAvailable(dictIds: [String])
    /// A dictionary with the preset's file name is installed, but it is not
    /// this preset (e.g. the user's own import of the same file). Shown as
    /// installed; never updated.
    case unrecognized(dictId: String)
}

public enum PresetVersioning {

    /// - Parameters:
    ///   - installed: The installed dictionaries that have the preset's file
    ///     name, in a stable order (oldest import first).
    ///   - latestSha256: The catalog's hash for the preset. Catalogs before
    ///     2026-10 had none; without it no update can be detected.
    ///   - previousSha256: Hashes of every earlier build of the preset.
    public static func state(installed: [InstalledPresetCopy],
                             latestSha256: String?,
                             previousSha256: [String] = []) -> PresetInstallState {
        let copies = installed.filter { !$0.dictId.isEmpty }
        guard let first = copies.first else { return .notInstalled }
        guard let latest = latestSha256?.lowercased(), !latest.isEmpty else {
            return .current(dictId: first.dictId)
        }
        let previous = Set(previousSha256.map { $0.lowercased() })
        let presetCopies = copies.filter {
            let id = $0.dictId.lowercased()
            return id == latest || previous.contains(id)
        }
        guard let firstPreset = presetCopies.first else {
            return .unrecognized(dictId: first.dictId)
        }
        let outdated = presetCopies.filter {
            guard let build = $0.fileSha256?.lowercased() else { return false }
            return previous.contains(build) && build != latest
        }
        if !outdated.isEmpty {
            return .updateAvailable(dictIds: outdated.map(\.dictId))
        }
        return .current(dictId: firstPreset.dictId)
    }

    /// Whether `sha256` is a build of a preset that this catalog knows
    /// (the current one or an earlier one).
    public static func isKnownBuild(_ sha256: String, latestSha256: String?,
                                    previousSha256: [String]) -> Bool {
        let id = sha256.lowercased()
        if let latest = latestSha256?.lowercased(), latest == id { return true }
        return previousSha256.contains { $0.lowercased() == id }
    }

    /// The name an installed preset takes when it is updated: the catalog's
    /// name if the dictionary still has one of the preset's earlier catalog
    /// names (a build that is another text of the work is renamed with it);
    /// nil to keep the current name, e.g. one the user chose.
    public static func adoptedDisplayName(current: String?, catalogName: String?,
                                          previousNames: [String]) -> String? {
        guard let current, let catalogName, !catalogName.isEmpty,
              current != catalogName, previousNames.contains(current) else { return nil }
        return catalogName
    }
}

// MARK: - Group membership of dictionaries that are not loaded here

public enum GroupOrder {

    /// The entries to persist for one group.
    ///
    /// The in-memory groups only hold dictionaries that are loaded on this
    /// device. A dictionary that another device added (its metadata has
    /// synced, its files have not arrived yet) is missing from them, and
    /// writing them back as they are would delete its group entries on every
    /// device. `preserved` lists such IDs: an existing entry for one of them is
    /// kept, at the same place relative to its neighbours, unless `incoming`
    /// already contains it.
    ///
    /// - Parameters:
    ///   - incoming: The group as this device sees it (loaded dictionaries).
    ///   - existing: The stored entries, in their stored order.
    ///   - preserved: IDs that have metadata but are not loaded here.
    public static func merge(incoming: [String], existing: [String],
                             preserved: Set<String>) -> [String] {
        var result = incoming
        var present = Set(incoming)
        for (i, id) in existing.enumerated() where preserved.contains(id) && !present.contains(id) {
            // Insert after the closest earlier stored neighbour that is in the
            // result; at the front when there is none.
            var insertAt = 0
            for j in stride(from: i - 1, through: 0, by: -1) {
                if let pos = result.firstIndex(of: existing[j]) {
                    insertAt = pos + 1
                    break
                }
            }
            result.insert(id, at: insertAt)
            present.insert(id)
        }
        return result
    }
}

// MARK: - Merging the shared sync status of duplicate metadata rows

public enum CloudSyncStatusMerge {

    /// Raw values of the app's `CloudSyncStatus` (Int16, stored in CoreData).
    public static let pending: Int16 = 0
    public static let synced: Int16 = 1
    public static let tooLarge: Int16 = 2
    public static let error: Int16 = 3

    /// The status to keep when two devices wrote a metadata row for the same
    /// dictionary. A dictionary is in CloudKit as soon as one device uploaded
    /// it, so `.synced` always wins; otherwise the more definite state wins
    /// (too large > pending > error). Taking the newer row's status instead
    /// let a device that imported the same file offline reset `.synced` to
    /// `.pending`, which stops every other device from downloading it.
    public static func best(_ a: Int16, _ b: Int16) -> Int16 {
        func rank(_ s: Int16) -> Int {
            switch s {
            case synced: return 3
            case tooLarge: return 2
            case pending: return 1
            default: return 0
            }
        }
        return rank(a) >= rank(b) ? a : b
    }
}
