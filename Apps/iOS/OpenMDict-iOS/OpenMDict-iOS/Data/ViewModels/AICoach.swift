//
//  AICoach.swift
//  OpenMDict-iOS
//
//  M14: Availability gate for the AI Coach feature.
//
//  Single OS gate (was two-tier with a Settings.bundle opt-in toggle).
//  The toggle was removed: it was meaningless on iOS 15–18 (no Foundation
//  Models there at all) yet Settings.app shows every Settings.bundle row
//  unconditionally, so those users stared at a dead switch; and on iOS 26
//  it was redundant — the in-app facade (AICoachViewController) already
//  triages every not-ready reason (device-not-eligible, with the actual
//  chip name via DeviceChipInfo; Apple Intelligence off; model
//  downloading; locale mismatch). So the entry is gated purely on the OS:
//
//    isVisible          — UI gate. iOS 26+ runtime. Controls whether the
//                         Management entry (sidebar + compact) appears.
//                         Shown on EVERY iOS 26 device, even ineligible
//                         hardware, because the facade explains why.
//
//    isGenerationReady  — Runtime gate. isVisible AND
//                         SystemLanguageModel.default.availability == .available.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - AICoach gate

/// Availability helpers for the AI Coach feature. Plain runtime/OS checks;
/// all call sites (sidebar snapshot build, management tab rebuild, facade
/// VC) are already on MainActor.
enum AICoach {

    /// True iff the runtime is iOS 26+ (Foundation Models SDK present).
    static var isOSSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }

    /// **UI gate.** True iff the runtime is iOS 26+. The Management entry
    /// uses this. We deliberately show it on every iOS 26 device — even
    /// ones whose chip can't run Apple Intelligence — because the facade
    /// VC explains exactly why it's unavailable (DeviceChipInfo-aware
    /// "device not eligible", "Apple Intelligence not enabled", "model
    /// downloading", or a locale mismatch). Hiding the row would leave the
    /// user with no signal at all.
    static var isVisible: Bool { isOSSupported }

    /// **Runtime gate.** True iff `isVisible` AND the on-device model is
    /// reported `.available`. The facade checks this before trying to
    /// generate; if false it triages the specific reason.
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

    /// Human-readable reason the model isn't ready, for the Flashcard POC
    /// alert. Returns nil when `isGenerationReady` is true. (The main facade
    /// VC uses richer per-state triage screens, not this one-liner.)
    static var unavailableDescription: String? {
        guard isOSSupported else {
            return "AI Coach requires iOS 26 or later. This device is on an older OS."
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
    /// the feature passes through.
    static var diagnosticSummary: String {
        let osTag      = isOSSupported     ? "OS✓"      : "OS✗"
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

        return "[AICoach] \(osTag) \(visibleTag) \(readyTag) availability=\(availabilityTag)"
    }
}
