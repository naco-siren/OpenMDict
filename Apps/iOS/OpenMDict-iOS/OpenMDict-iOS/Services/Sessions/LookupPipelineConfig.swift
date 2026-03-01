//
//  LookupPipelineConfig.swift
//  OpenMDict-iOS
//
//  Device-tier-aware configuration for the lookup pipeline.
//  Higher-end devices get shorter debounce and larger result budgets.
//
//  All values are `static let` — computed once at first access (dispatch_once),
//  since `DeviceCapability.ramTier` never changes after process launch.
//

import Foundation

/// Pipeline configuration for LookupSession, scaled by device RAM tier.
nonisolated enum LookupPipelineConfig {

    // MARK: - Debounce

    /// Debounce interval for raw query input (ms).
    static let queryDebounceMs: Int = {
        switch DeviceCapability.ramTier {
        case .high:   return 200
        case .medium: return 300
        case .low:    return 400
        }
    }()

    /// Debounce interval before evaluating lemma resolution (ms).
    static let lemmaDebounceMs: Int = {
        switch DeviceCapability.ramTier {
        case .high:   return 200
        case .medium: return 300
        case .low:    return 400
        }
    }()

    // MARK: - Thresholds

    /// Minimum direct-result count before skipping lemma / suggestions.
    /// Higher-end devices tolerate more lemma/suggestion work → higher threshold.
    static let resultThreshold: Int = {
        switch DeviceCapability.ramTier {
        case .high:   return 5
        case .medium: return 3
        case .low:    return 2
        }
    }()

    /// Per-reader suggestion limit passed to `MDictReader.suggestions(for:limit:)`.
    static let suggestionsPerReader: Int = {
        switch DeviceCapability.ramTier {
        case .high:   return 12
        case .medium: return 8
        case .low:    return 5
        }
    }()

    /// Maximum suggestions surfaced to the UI after global distance-ranked merge.
    /// Generous budget — the expensive computation already happened per-reader;
    /// extra cells are near-zero UI cost.
    static let maxSuggestions: Int = {
        switch DeviceCapability.ramTier {
        case .high:   return 36
        case .medium: return 24
        case .low:    return 15
        }
    }()
}
