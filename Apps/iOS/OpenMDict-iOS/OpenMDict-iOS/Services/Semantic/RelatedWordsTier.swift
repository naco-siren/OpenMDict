//
//  RelatedWordsTier.swift
//  OpenMDict-iOS
//
//  M15 Phase 1 — user-facing tier knob for semantic search result count.
//
//  Plan B (locked after a multi-source, CEFR-stratified real-data bench;
//  see docs/article-embeddings.md, "Phase 1", for the methodology):
//
//      Single uniform cosine floor (0.45) for all tiers. The tier knob is
//      purely K — how many top-K results to display. Quality over quantity:
//      if fewer than K candidates clear the floor, we return fewer (no padding).
//
//  Stored in UserDefaults as the K value itself (5 / 10 / 20). This lets
//  PSMultiValueSpecifier in Settings.bundle write the value directly without
//  any rawValue translation gymnastics on read.
//

import Foundation

/// "Semantic Search Results" setting. K = top-K cap on the returned
/// related-words list. Floor is constant (0.45) across tiers.
nonisolated enum RelatedWordsTier: Int, CaseIterable {
    case few     = 12   // strict — modest list of high-confidence neighbors
    case `default` = 24 // balanced — what most users see
    case more    = 48   // generous — exhaustive set for power users

    /// Top-K cap. Equal to the raw value so Settings.bundle can store it directly.
    var k: Int { rawValue }

    /// Cosine similarity floor. Uniform across tiers in Plan B.
    /// Words scoring below this are gated as noise even if they'd fit in K.
    var floor: Double { 0.45 }

    /// UserDefaults key. The stored value is the Int K itself (5/10/20).
    static let userDefaultsKey = "semanticResultsCount"

    /// Resolve the current setting from UserDefaults. Falls back to `.default`
    /// for any unknown value (including the "not set" zero case, which iOS
    /// returns for missing Int keys).
    static var current: RelatedWordsTier {
        let raw = UserDefaults.standard.integer(forKey: userDefaultsKey)
        return RelatedWordsTier(rawValue: raw) ?? .default
    }
}
