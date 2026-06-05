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

    private static let articleSearchEnabledKey = "articleSearchEnabled"

    /// M15: master switch for article-content ("full-text") search. When
    /// off, no indexing is scheduled and the 全文 scope stays hidden in
    /// search. Opt-in — defaults to false (absent key → false), since
    /// indexing is heavy and the feature is iOS 26+ only.
    var articleSearchEnabled: Bool {
        get { bool(forKey: Self.articleSearchEnabledKey) }
        set { set(newValue, forKey: Self.articleSearchEnabledKey) }
    }

}

// MARK: - Article Search Master Toggle Notification

extension Notification.Name {
    /// Posted by `ArticleIndexOverviewViewController.setMasterEnabled`
    /// (the *only* writer of `UserDefaults.articleSearchEnabled`)
    /// immediately after flipping the master toggle.
    ///
    /// Consumers — currently `WordListViewController` — listen for this
    /// instead of `UserDefaults.didChangeNotification` so they react ONLY
    /// to the article-search toggle, not to the constant churn of
    /// unrelated defaults writes (keyboard/dictation/etc.) that floods the
    /// global notification, especially while a search field is active.
    static let articleSearchMasterToggleDidChange =
        Notification.Name("io.github.naco-siren.openmdict.articleSearchMasterToggleDidChange")
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

    /// Short tag for use in SVG filter IDs and CSS data attributes.
    /// e.g. "n3" for −3, "0" for 0, "p2" for +2.
    var filterTag: String {
        let r = rawValue
        if r < 0 { return "n\(-r)" }
        if r > 0 { return "p\(r)" }
        return "0"
    }

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

    /// Per-tier floor for the gamma-invert output range.
    ///
    /// Baseline is 28/255 (≈ Apple's `secondarySystemGroupedBackground` dark,
    /// #1C1C1C).  Each tier adds a small **absolute** offset (±2/255 per step)
    /// so dim tiers go slightly darker and bright tiers slightly lighter.
    ///
    /// | Tier      | Floor | ≈ Hex  |
    /// |-----------|-------|--------|
    /// | dimmest   |  22   | #161616 |
    /// | dimmer    |  24   | #181818 |
    /// | dim       |  26   | #1A1A1A |
    /// | standard  |  28   | #1C1C1C |
    /// | bright    |  30   | #1E1E1E |
    /// | brighter  |  32   | #202020 |
    /// | brightest |  34   | #222222 |
    private var floor: Double {
        let base = 28.0
        let step = 2.0
        return (base + step * Double(rawValue)) / 255.0
    }

    /// Precomputed `tableValues` for the **forward** (invert) SVG filter.
    ///
    /// Formula: `output(x) = floor + (1 - floor) × pow(1 - pow(x, γ), 1/γ)`
    ///
    /// Output range is `[floor, 1]` — white (1) maps to dark gray, black (0)
    /// maps to full white.  This keeps background hierarchy readable just
    /// like Apple's native dark appearance.
    var svgTableValues: String {
        let steps = 32
        let g = gamma
        let invG = 1.0 / g
        let f = floor
        return (0...steps).map { i in
            let x = Double(i) / Double(steps)
            let raw = pow(max(0, 1.0 - pow(x, g)), invG)
            let output = f + (1.0 - f) * raw
            return String(format: "%.4f", output)
        }.joined(separator: " ")
    }

    /// Precomputed `tableValues` for the **reverse** (undo) SVG filter,
    /// applied to `img`/`video`/`svg` to restore their original colors
    /// after the content wrapper's forward gamma-invert.
    ///
    /// This is the exact inverse of `svgTableValues`:
    /// `output(y) = pow(1 - pow(clamp((y - floor)/(1 - floor)), γ), 1/γ)`
    var svgReverseTableValues: String {
        let steps = 32
        let g = gamma
        let invG = 1.0 / g
        let f = floor
        return (0...steps).map { i in
            let y = Double(i) / Double(steps)
            let normalized = max(0, min(1, (y - f) / (1.0 - f)))
            let output = pow(max(0, 1.0 - pow(normalized, g)), invG)
            return String(format: "%.4f", output)
        }.joined(separator: " ")
    }
}
