//
//  DeviceCapability.swift
//  OpenMDict-iOS
//
//  Device RAM tier for scaling resource limits.
//

import Foundation

/// Device capability classification based on physical RAM.
///
/// `nonisolated` because the project uses `-default-isolation=MainActor` with Swift 6,
/// and this type is thread-safe (read-only system value, `static let` with dispatch_once).
nonisolated enum DeviceCapability {

    enum RAMTier {
        case low      // <= 2 GB
        case medium   // 3–4 GB
        case high     // >= 6 GB
    }

    /// Determined once at first access, cached for process lifetime.
    static let ramTier: RAMTier = {
        let gb = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        if gb <= 2 { return .low }
        if gb <= 4 { return .medium }
        return .high
    }()
}
