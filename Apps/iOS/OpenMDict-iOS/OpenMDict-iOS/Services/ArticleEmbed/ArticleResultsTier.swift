//
//  ArticleResultsTier.swift
//  OpenMDict-iOS
//
//  M15 — user-facing tier knob for ARTICLE-CONTENT ("词条内容") search
//  result count, the article-search counterpart to RelatedWordsTier.
//
//  Unlike RelatedWordsTier (which lives in Settings.bundle alongside the
//  other lookup knobs), this one is surfaced INSIDE the app — in the
//  Article-Search Indexing overview, next to the master toggle. Article
//  search is iOS 26+ and feature-gated, and Settings.bundle can't hide a
//  specifier conditionally, so an in-app control is the only way to keep
//  it from showing as a dead setting on older systems.
//
//  Stored in UserDefaults as the K value itself (15 / 30 / 60), mirroring
//  RelatedWordsTier's "store K directly, no rawValue gymnastics" choice.
//

import Foundation

/// "Article search results" setting. K = top-K cap on the merged,
/// cross-dictionary article-content hit list returned by
/// ArticleSearchService. Consumed by ArticleLookupSession.
nonisolated enum ArticleResultsTier: Int, CaseIterable {
    case few     = 15   // concise — just the closest article matches
    case `default` = 30 // balanced — what most users see
    case more    = 60   // generous — a wide net for exploration

    /// Top-K cap. Equal to the raw value so the stored Int is the K itself.
    var k: Int { rawValue }

    /// UserDefaults key. The stored value is the Int K (15/30/60).
    static let userDefaultsKey = "articleResultsCount"

    /// Resolve the current setting from UserDefaults. Falls back to
    /// `.default` for any unknown value (including the "not set" zero case
    /// iOS returns for missing Int keys).
    static var current: ArticleResultsTier {
        let raw = UserDefaults.standard.integer(forKey: userDefaultsKey)
        return ArticleResultsTier(rawValue: raw) ?? .default
    }
}
