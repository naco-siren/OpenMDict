//
//  AICoach.swift
//  OpenMDict-iOS
//
//  M14 POC: Availability gate for the AI Coach feature.
//
//  Two-tier gate (split during POC debugging):
//
//    isVisible          — UI gate. Controls whether the sidebar / Management
//                         row is shown at all. Loose: iOS 26 SDK runtime +
//                         user opted in via Settings.bundle. Does NOT require
//                         the on-device model to be ready.
//
//    isGenerationReady  — Runtime gate. Controls whether we can actually
//                         create a session and generate text. Strict: above
//                         + `SystemLanguageModel.default.availability` is
//                         exactly `.available`.
//
//  The reason for two tiers: in earlier POC builds we required the strict
//  check for visibility, which meant the row would silently disappear if
//  Apple Intelligence wasn't enabled in Settings → Apple Intelligence & Siri
//  (or wasn't done downloading), with no way to tell whether the build
//  was broken, the toggle didn't take, or Apple Intelligence wasn't ready.
//  Now the row appears as soon as the user opts in, and tapping it
//  surfaces the actual `unavailableReason` if generation isn't ready.
//
//  The Settings.bundle toggle is visible unconditionally to all users
//  because Settings.app can't conditionally hide individual entries.
//

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - UserDefaults Extension

extension UserDefaults {
    /// Settings.bundle key for the AI Coach feature toggle.
    /// Default: false (registered in AppDelegate.didFinishLaunching).
    fileprivate static let aiCoachEnabledKey = "aiCoachEnabled"

    var aiCoachEnabled: Bool {
        get { bool(forKey: Self.aiCoachEnabledKey) }
        set { set(newValue, forKey: Self.aiCoachEnabledKey) }
    }
}

// MARK: - AICoach gate

/// Availability helpers for the AI Coach POC.
///
/// Not marked `nonisolated`: the user-toggle lookup goes through the
/// `UserDefaults.aiCoachEnabled` extension which, under the project's
/// `-default-isolation=MainActor` flag, is implicitly MainActor-isolated.
/// All call sites (sidebar snapshot build, AppDelegate launch, management
/// tab rebuild, POC VC) are already on MainActor so this is harmless.
enum AICoach {

    /// True iff the runtime is iOS 26+. Independent of hardware/model
    /// readiness — only used as a hard floor for the Settings.bundle
    /// toggle to mean anything at all.
    static var isOSSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }

    /// **UI gate.** True iff the OS supports Foundation Models AND the user
    /// has flipped the Settings.app toggle on. The sidebar row and tab entry
    /// use this — we want users to see the entry as soon as they opt in,
    /// even if Apple Intelligence isn't downloaded yet.
    static var isVisible: Bool {
        guard isOSSupported else { return false }
        return UserDefaults.standard.aiCoachEnabled
    }

    /// **Runtime gate.** True iff `isVisible` AND the on-device model is
    /// reported `.available`. The POC view controller checks this before
    /// trying to start generation; if false, it shows an alert with
    /// `unavailableDescription` so the user knows what to fix.
    static var isGenerationReady: Bool {
        guard isVisible else { return false }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return true
            default:         return false
            }
        }
        #endif
        return false
    }

    /// Human-readable reason the model isn't ready, suitable for showing
    /// in an alert. Returns nil when `isGenerationReady` is true.
    static var unavailableDescription: String? {
        guard isVisible else {
            if !isOSSupported {
                return "AI Coach requires iOS 26 or later. This device is on an older OS."
            }
            return "AI Coach is disabled. Enable it in Settings → OpenMDict → AI Coach (POC)."
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return L10n.AICoach.deviceNotEligible
                case .appleIntelligenceNotEnabled:
                    return L10n.AICoach.aiNotEnabled
                case .modelNotReady:
                    return L10n.AICoach.modelNotReady
                @unknown default:
                    return "The on-device language model is unavailable for an unknown reason."
                }
            @unknown default:
                return "The on-device language model is in an unknown state."
            }
        }
        #endif
        return "AI Coach requires iOS 26 or later."
    }

    /// Diagnostic snapshot for debug logs. One-line summary of every gate
    /// the feature passes through, intended for `debugLog` callsites that
    /// can't easily reach into FoundationModels themselves.
    static var diagnosticSummary: String {
        let osTag      = isOSSupported     ? "OS✓"      : "OS✗"
        let toggleTag  = UserDefaults.standard.aiCoachEnabled ? "toggle✓" : "toggle✗"
        let visibleTag = isVisible         ? "visible✓" : "visible✗"
        let readyTag   = isGenerationReady ? "ready✓"   : "ready✗"

        var availabilityTag = "n/a"
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                availabilityTag = "available"
            case .unavailable(.deviceNotEligible):
                availabilityTag = "unavailable.deviceNotEligible"
            case .unavailable(.appleIntelligenceNotEnabled):
                availabilityTag = "unavailable.appleIntelligenceNotEnabled"
            case .unavailable(.modelNotReady):
                availabilityTag = "unavailable.modelNotReady"
            case .unavailable:
                availabilityTag = "unavailable.<unknown>"
            @unknown default:
                availabilityTag = "<unknown>"
            }
        }
        #endif

        return "[AICoach] \(osTag) \(toggleTag) \(visibleTag) \(readyTag) availability=\(availabilityTag)"
    }
}
