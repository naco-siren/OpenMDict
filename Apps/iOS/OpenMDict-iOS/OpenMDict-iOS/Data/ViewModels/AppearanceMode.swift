//
//  AppearanceMode.swift
//  OpenMDict-iOS
//

import UIKit

// MARK: - Appearance Mode

enum AppearanceMode: Int {
    case light = 0
    case system = 1
    case dark = 2

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .system: return .unspecified
        case .dark: return .dark
        }
    }
}

// MARK: - UI Factories

extension AppearanceMode {

    /// SF Symbol icon for the current mode.
    var icon: UIImage {
        switch self {
        case .light: UIImage(systemName: "sun.max")!
        case .system: UIImage(systemName: "circle.lefthalf.filled")!
        case .dark:   UIImage(systemName: "moon")!
        }
    }

    /// Pull-down menu showing all three modes with a checkmark on the current one.
    /// - Parameter handler: Called with the selected mode.
    func menu(handler: @escaping (AppearanceMode) -> Void) -> UIMenu {
        UIMenu(title: L10n.Detail.appearance, children: [
            UIAction(title: L10n.Detail.light, image: .init(systemName: "sun.max"),
                     state: self == .light ? .on : .off) { _ in handler(.light) },
            UIAction(title: L10n.Detail.auto, image: .init(systemName: "circle.lefthalf.filled"),
                     state: self == .system ? .on : .off) { _ in handler(.system) },
            UIAction(title: L10n.Detail.dark, image: .init(systemName: "moon"),
                     state: self == .dark ? .on : .off) { _ in handler(.dark) },
        ])
    }

    /// Three-segment control (sun / half-circle / moon) with the current mode selected.
    func segmentedControl(target: AnyObject, action: Selector) -> UISegmentedControl {
        let seg = UISegmentedControl(items: [
            UIImage(systemName: "sun.max")!,
            UIImage(systemName: "circle.lefthalf.filled")!,
            UIImage(systemName: "moon")!,
        ])
        seg.selectedSegmentIndex = rawValue
        seg.addTarget(target, action: action, for: .valueChanged)
        return seg
    }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
    /// App Group shared defaults visible to both main app and extensions.
    static let shared = UserDefaults(suiteName: AppIdentifiers.appGroupIdentifier)!

    private static let appearanceModeKey = "appearanceMode"
    private static let appearanceModeTimestampKey = "appearanceModeTimestamp"

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: integer(forKey: Self.appearanceModeKey)) ?? .system }
        set { set(newValue.rawValue, forKey: Self.appearanceModeKey) }
    }

    /// Timestamp of the last appearance mode write (only meaningful on shared suite).
    var appearanceModeTimestamp: Double {
        get { double(forKey: Self.appearanceModeTimestampKey) }
        set { set(newValue, forKey: Self.appearanceModeTimestampKey) }
    }

    /// Write appearance mode to this suite and stamp the current time.
    /// Use this instead of the raw setter when the write should be
    /// visible to the merge logic in AppDelegate.
    func setAppearanceModeStamped(_ mode: AppearanceMode) {
        appearanceMode = mode
        appearanceModeTimestamp = Date().timeIntervalSince1970
    }
}
