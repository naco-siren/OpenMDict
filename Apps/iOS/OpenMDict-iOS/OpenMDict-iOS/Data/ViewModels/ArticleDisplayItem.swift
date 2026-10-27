//
//  ArticleDisplayItem.swift
//  OpenMDict-iOS
//
//  ViewModel for article cells with support for pending/loaded states
//

import CoreSpotlight
import Foundation
import OpenMDictKit
import UIKit

// MARK: - Content State

/// Content loading state for an article
nonisolated enum ArticleContentState: Equatable, Hashable {
    case pending                              // Dictionary not loaded yet
    case loaded(html: String, css: String?)   // Content available
    case notFound                             // Dictionary loaded but word not found

    var html: String? {
        if case .loaded(let html, _) = self { return html }
        return nil
    }

    var css: String? {
        if case .loaded(_, let css) = self { return css }
        return nil
    }
}

// MARK: - ArticleDisplayItem

/// Article cell ViewModel
/// Contains word reference and content state (pending/loaded/notFound)
nonisolated struct ArticleDisplayItem: Identifiable, Hashable {
    let id: String
    /// The key the article is of. Bookmarks, lookup counts and history are
    /// kept under it.
    let word: String
    let dictId: String
    let dictName: String
    var contentState: ArticleContentState
    /// What was looked up when a lookup fallback (`MDictWordEntry.fallback`)
    /// found this article under another key; nil for a direct hit. Shown
    /// as "query → key" in the header, as the Action Extension does.
    let resolvedFrom: String?

    init(word: String, dictId: String, dictName: String, contentState: ArticleContentState = .pending,
         resolvedFrom: String? = nil) {
        self.id = "\(dictId):\(word)"
        self.word = word
        self.dictId = dictId
        self.dictName = dictName
        self.contentState = contentState
        self.resolvedFrom = resolvedFrom
    }

    /// The header title: the key, or "query → key" for a fallback hit.
    var displayWord: String {
        resolvedFrom.map { "\($0) → \(word)" } ?? word
    }

    /// This article with `entry`'s content. An entry a fallback found is
    /// shown under the key it matched, labelled with the word looked up
    /// (which this article was pending for).
    func filled(with entry: MDictWordEntry) -> ArticleDisplayItem {
        let content = ArticleContentState.loaded(html: entry.article.html, css: nil)
        guard entry.fallback == nil else {
            return ArticleDisplayItem(word: entry.key, dictId: dictId, dictName: dictName,
                                      contentState: content, resolvedFrom: word)
        }
        var filled = self
        filled.contentState = content
        return filled
    }
}

// MARK: - Handoff Support

extension ArticleDisplayItem {
    
    var userActivity: NSUserActivity {
        let activity = NSUserActivity(activityType: AppIdentifiers.Activity.viewArticle)
        activity.title = word
        activity.userInfo = ["id": id, "word": word, "dictId": dictId, "dictName": dictName]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.isEligibleForPrediction = true
        activity.persistentIdentifier = id

        // Rich attributes for Spotlight search results and Siri suggestions
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = word
        attributes.contentDescription = dictName
        attributes.keywords = [word, dictName]
        activity.contentAttributeSet = attributes

        return activity
    }
    
    /// Create from NSUserActivity (state restoration / handoff)
    /// Content will be in pending state - needs to be loaded after dictionary is ready
    static func from(userActivity: NSUserActivity) -> ArticleDisplayItem? {
        guard userActivity.activityType == AppIdentifiers.Activity.viewArticle,
              let info = userActivity.userInfo,
              let word = info["word"] as? String,
              let dictId = info["dictId"] as? String,
              let dictName = info["dictName"] as? String else { return nil }
        return ArticleDisplayItem(
            word: word,
            dictId: dictId,
            dictName: dictName,
            contentState: .pending
        )
    }
}

// MARK: - Scene State Restoration

extension ArticleDisplayItem {

    /// Create scene state activity with multiple articles
    static func sceneStateActivity(
        articles: [ArticleDisplayItem],
        groupId: String,
        layoutMode: Int
    ) -> NSUserActivity {
        let activity = NSUserActivity(activityType: AppIdentifiers.Activity.sceneState)
        activity.title = articles.first?.word ?? "OpenMDict"

        // Encode articles as array of dictionaries (only essential fields)
        let articlesData = articles.map { article -> [String: String] in
            ["word": article.word, "dictId": article.dictId, "dictName": article.dictName]
        }

        activity.userInfo = [
            "articles": articlesData,
            "groupId": groupId,
            "layoutMode": layoutMode
        ]

        return activity
    }

    /// Parse scene state from activity
    static func parseSceneState(from activity: NSUserActivity) -> (articles: [ArticleDisplayItem], groupId: String, layoutMode: Int)? {
        guard activity.activityType == AppIdentifiers.Activity.sceneState,
              let info = activity.userInfo,
              let articlesData = info["articles"] as? [[String: String]] else {
            return nil
        }

        let articles = articlesData.compactMap { dict -> ArticleDisplayItem? in
            guard let word = dict["word"],
                  let dictId = dict["dictId"],
                  let dictName = dict["dictName"] else { return nil }
            return ArticleDisplayItem.pending(word: word, dictId: dictId, dictName: dictName)
        }

        let groupId = info["groupId"] as? String ?? ""
        let layoutMode = info["layoutMode"] as? Int ?? 0

        return (articles, groupId, layoutMode)
    }
}

// MARK: - Factory (MainActor required for MDict access)

extension ArticleDisplayItem {
    
    /// Create from MDictLookupResult.
    /// Uses `preferredTitle` (userDisplayName → extractedTitle → metadata.title
    /// → originalFileName → id) so dicts without an MDX header title still
    /// get a human-readable name in the article header.
    /// - Parameter query: The word looked up; kept as `resolvedFrom` when
    ///   a fallback found the entry.
    @MainActor
    init(from result: MDictLookupResult, query: String? = nil) {
        self.init(from: result.entry, dict: result.dict, query: query)
    }

    /// Create from MDict and entry.
    /// Uses `preferredTitle` for the same reason as `init(from: MDictLookupResult)`.
    /// - Parameter query: The word looked up; kept as `resolvedFrom` when
    ///   a fallback found the entry.
    @MainActor
    init(from entry: MDictWordEntry, dict: MDict, css: String? = nil, query: String? = nil) {
        self.init(
            word: entry.key,
            dictId: dict.id,
            dictName: dict.preferredTitle,
            contentState: .loaded(html: entry.article.html, css: css),
            resolvedFrom: entry.fallback == nil ? nil : query
        )
    }
    
    /// Create pending article (for state restoration or entry:// links when dict not loaded)
    static func pending(word: String, dictId: String, dictName: String) -> ArticleDisplayItem {
        ArticleDisplayItem(word: word, dictId: dictId, dictName: dictName, contentState: .pending)
    }
}
