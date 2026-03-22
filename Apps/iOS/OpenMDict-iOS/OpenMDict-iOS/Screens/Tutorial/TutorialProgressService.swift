//
//  TutorialProgressService.swift
//  OpenMDict-iOS
//
//  Lightweight UserDefaults persistence for tutorial completion state.
//  Device-local only — not synced via iCloud.
//

import Foundation

nonisolated enum TutorialProgressService {

    private static let key = "tutorialCompletedLevels"

    static func isCompleted(_ level: TutorialLevel) -> Bool {
        completedSet().contains(level.rawValue)
    }

    static func markCompleted(_ level: TutorialLevel) {
        var set = completedSet()
        set.insert(level.rawValue)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Private

    private static func completedSet() -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
    }
}
