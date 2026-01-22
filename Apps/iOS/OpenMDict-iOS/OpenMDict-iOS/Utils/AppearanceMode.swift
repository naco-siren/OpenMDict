//
//  AppearanceMode.swift
//  OpenMDict-iOS
//
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

// MARK: - UserDefaults Extension

extension UserDefaults {
    private static let appearanceModeKey = "appearanceMode"

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: integer(forKey: Self.appearanceModeKey)) ?? .system }
        set { set(newValue.rawValue, forKey: Self.appearanceModeKey) }
    }
}
