//
//  AppIcon.swift
//  OpenMDict-iOS
//
//  Alternate app icon variants for the icon chooser.
//  rawValue matches the name passed to setAlternateIconName(_:)
//  and the ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES build setting.
//
//  iOS 18+: .icon bundles provide light/dark/tinted automatically.
//           → 9 cells in the chooser (one per variant).
//  iOS 15–17: CFBundleAlternateIcons Info.plist fallback with PNGs.
//           → light + dark cells for each variant (inverse variants
//             get a single cell since they have no dark counterpart).
//

import UIKit

// MARK: - AppIcon (the 9 icon variants)

/// All available app icon variants.
///
/// `nonisolated` because the project uses `-default-isolation=MainActor`
/// and this enum is used in NSDiffableDataSourceSnapshot which requires Sendable.
/// All properties access only thread-safe APIs (NSLocalizedString, Bundle).
nonisolated enum AppIcon: String, CaseIterable, Sendable {

    case `default`  = "OpenMDict"           // Aあ
    case inverse    = "OpenMDict-Inverse"   // Aあ (inverted colors)
    case west       = "OpenMDict-West"      // Aa
    case east1      = "OpenMDict-East1"     // 辞
    case east2      = "OpenMDict-East2"     // 詞
    case east3      = "OpenMDict-East3"     // 词
    case east4      = "OpenMDict-East4"     // ひ
    case east5      = "OpenMDict-East5"     // 한
    case east114514 = "OpenMDict-East114514"

    // MARK: - Icon Names for setAlternateIconName(_:)

    /// Light variant: `nil` = primary icon, otherwise rawValue.
    var alternateIconName: String? {
        self == .default ? nil : rawValue
    }

    /// Dark variant for iOS 15–17: rawValue + "-Dark".
    /// e.g. "OpenMDict-Dark", "OpenMDict-West-Dark".
    /// Inverse has no dark variant (falls back to default dark).
    var darkAlternateIconName: String? {
        hasDarkVariant ? rawValue + "-Dark" : nil
    }

    /// Whether this icon has its own dark variant.
    /// Inverse variants reuse the parent icon's dark mode, so they have no separate dark entry.
    var hasDarkVariant: Bool {
        self != .inverse
    }

    // MARK: - Display

    /// Localized display name for the chooser UI.
    var displayName: String {
        switch self {
        case .default:            return L10n.AppIcon.defaultIcon
        case .inverse:            return L10n.AppIcon.defaultInverse
        case .west:               return L10n.AppIcon.west
        case .east1:              return L10n.AppIcon.east1
        case .east2:              return L10n.AppIcon.east2
        case .east3:              return L10n.AppIcon.east3
        case .east4:              return L10n.AppIcon.east4
        case .east5:              return L10n.AppIcon.east5
        case .east114514:         return L10n.AppIcon.east114514
        }
    }

    // MARK: - Preview Image

    /// Light-mode preview image for the chooser UI.
    ///
    /// Reuses the @3x icon PNG already bundled for `setAlternateIconName(_:)` —
    /// 180×180 px, displayed at 60×60 pt, downsampling is imperceptible.
    /// Default icon's light variant uses a dedicated 180×180 PNG because Icon Composer
    /// assets (.icon) can't be loaded as UIImage via the asset catalog.
    var previewImage: UIImage? {
        if self == .default {
            return Self.loadIconPNG("OpenMDict-Preview")
        }
        return Self.loadIconPNG("\(rawValue)-iPhone@3x")
    }

    /// Dark-mode preview image for the chooser UI.
    /// Returns nil for icons without a dark variant (Inverse).
    var darkPreviewImage: UIImage? {
        guard hasDarkVariant else { return nil }
        return Self.loadIconPNG("\(rawValue)-Dark-iPhone@3x")
    }

    private static func loadIconPNG(_ name: String) -> UIImage? {
        guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }
        return UIImage(contentsOfFile: path)
    }

    // MARK: - Parsing

    /// Parse `UIApplication.shared.alternateIconName` back to (AppIcon, isDark).
    static func from(alternateIconName: String?) -> (icon: AppIcon, isDark: Bool) {
        guard let name = alternateIconName else { return (.default, false) }
        // Check for "-Dark" suffix first
        if name.hasSuffix("-Dark"),
           let icon = AppIcon(rawValue: String(name.dropLast(5))) {
            return (icon, true)
        }
        return (AppIcon(rawValue: name) ?? .default, false)
    }
}

// MARK: - AppIconItem (DiffableDataSource item)

/// Wrapper for the icon chooser's diffable data source.
///
/// On iOS 18+: one item per variant (isDark = false), .icon handles appearance.
/// On iOS 15–17: two items per variant (light + dark), user picks manually.
nonisolated struct AppIconItem: Hashable, Sendable {
    let icon: AppIcon
    let isDark: Bool

    /// Name passed to `setAlternateIconName(_:)`.
    var alternateIconName: String? {
        isDark ? icon.darkAlternateIconName : icon.alternateIconName
    }

    /// Whether this item represents a dark variant that actually exists.
    /// Inverse has no dark variant, so isDark should never be true for it.
    var isValid: Bool {
        !isDark || icon.hasDarkVariant
    }

    /// Localized display name.  Dark variants append "(Dark)".
    var displayName: String {
        isDark
            ? String(format: L10n.AppIcon.darkFormat, icon.displayName)
            : icon.displayName
    }

    /// Preview image matching the appearance.
    var previewImage: UIImage? {
        isDark ? icon.darkPreviewImage : icon.previewImage
    }
}
