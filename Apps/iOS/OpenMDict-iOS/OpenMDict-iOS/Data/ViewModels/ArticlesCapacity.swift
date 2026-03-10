//
//  ArticlesCapacity.swift
//  OpenMDict-iOS
//
//  Qualitative articles capacity setting, mapped to a quantitative limit
//  based on device RAM tier.
//

import Foundation

/// Articles capacity tier. Users see "Fewer / Default / More" in Settings.bundle;
/// the exact limit depends on device RAM (via `DeviceCapability.ramTier`).
///
/// Formula: Default = 10 / 20 / 30 per RAM tier.
///          Fewer  = Default ÷ 2.
///          More   = Default × 2.
nonisolated enum ArticlesCapacity: Int {
    case fewer   = 0
    case normal  = 1  // default
    case more    = 2

    /// Maximum number of articles a single scene (or Action Extension) may hold.
    var limit: Int {
        switch (self, DeviceCapability.ramTier) {
        // fewer (Default ÷ 2)
        case (.fewer, .low):    return 5
        case (.fewer, .medium): return 10
        case (.fewer, .high):   return 15
        // normal (Default)
        case (.normal, .low):    return 10
        case (.normal, .medium): return 20
        case (.normal, .high):   return 30
        // more (Default × 2)
        case (.more, .low):    return 20
        case (.more, .medium): return 40
        case (.more, .high):   return 60
        }
    }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
    private static let articlesCapacityKey = "articlesCapacity"

    var articlesCapacity: ArticlesCapacity {
        get { ArticlesCapacity(rawValue: integer(forKey: Self.articlesCapacityKey)) ?? .normal }
        set { set(newValue.rawValue, forKey: Self.articlesCapacityKey) }
    }

    private static let showEnhanceDarkModeKey = "showEnhanceDarkMode"

    /// Whether to show the per-dict dark mode enhance toggle in article headers.
    /// Defaults to `true` when the key is absent (fresh install before register).
    var showEnhanceDarkMode: Bool {
        get {
            if object(forKey: Self.showEnhanceDarkModeKey) == nil { return true }
            return bool(forKey: Self.showEnhanceDarkModeKey)
        }
        set { set(newValue, forKey: Self.showEnhanceDarkModeKey) }
    }
}
