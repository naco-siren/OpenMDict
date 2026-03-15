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

    private static let showLookupCountKey = "showLookupCount"

    /// Whether to display the "looked up N time(s)" info row below article headers.
    /// Defaults to `true` when the key is absent (fresh install before register).
    var showLookupCount: Bool {
        get {
            if object(forKey: Self.showLookupCountKey) == nil { return true }
            return bool(forKey: Self.showLookupCountKey)
        }
        set { set(newValue, forKey: Self.showLookupCountKey) }
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

// MARK: - Enhance Dark Mode Strength

/// Per-dictionary dark mode enhancement strength.
///
/// Stored in CoreData as `enhanceDarkModeStrength` (Int16), alongside the
/// `enhanceDarkMode` Bool (kept for CloudKit production schema compatibility).
///
/// - `none` (0) = enhancement off
/// Signed tier for per-dictionary enhance-dark-mode strength.
///
/// Raw values are **signed tiers** (−3 … +3), NOT gamma values.  This keeps
/// the serialized value stable even if the exact gamma mapping changes later,
/// and the user's chosen "slot" in the UI stays consistent.
///
/// - `.none` (special, not stored as a tier) = enhancement off.
/// - Negative tiers (`dimmest`…`dim`) compress contrast → dimmer result.
///   Useful for dictionaries whose default style is already bright.
/// - Zero tier (`default`) is the baseline enhancement (γ = 1.0).
/// - Positive tiers (`bright`…`brightest`) boost separation → brighter result.
///   Higher gamma → more visual separation between background hierarchy levels
///   in the dark end (Weber-Fechner).
///
/// "Dim/bright" wording is intentional to avoid collision with "light/dark"
/// appearance terminology.
nonisolated enum EnhanceDarkModeStrength: Int16 {
    // Dimmer direction — compresses contrast (mirrors positive spacing)
    case dimmest  = -3  // γ = 0.4
    case dimmer   = -2  // γ = 0.6
    case dim      = -1  // γ = 0.8

    // Baseline
    case standard  = 0  // γ = 1.0 (starting point when first enabled)

    // Brighter direction — boosts separation
    case bright    = 1  // γ = 1.2
    case brighter  = 2  // γ = 1.4
    case brightest = 3  // γ = 1.6

    /// All tiers in ascending order, for building the picker menu.
    static let allTiers: [EnhanceDarkModeStrength] = [
        .dimmest, .dimmer, .dim, .standard, .bright, .brighter, .brightest
    ]

    var isEnhanced: Bool { true }

    var gamma: Double {
        switch self {
        case .dimmest:  return 0.4
        case .dimmer:   return 0.6
        case .dim:      return 0.8
        case .standard:  return 1.0
        case .bright:   return 1.2
        case .brighter: return 1.4
        case .brightest: return 1.6
        }
    }

    /// Precomputed `tableValues` string for SVG `feComponentTransfer type="table"`.
    /// Formula per sample: `output(x) = pow(1 - pow(x, γ), 1/γ)`.
    var svgTableValues: String {
        let steps = 32
        let g = gamma
        let invG = 1.0 / g
        return (0...steps).map { i in
            let x = Double(i) / Double(steps)
            let linear = pow(x, g)
            let output = pow(max(0, 1.0 - linear), invG)
            return String(format: "%.4f", output)
        }.joined(separator: " ")
    }
}
