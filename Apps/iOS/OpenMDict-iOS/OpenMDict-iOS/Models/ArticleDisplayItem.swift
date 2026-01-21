//
//  ArticleDisplayItem.swift
//  OpenMDict-iOS
//
//  ViewModel for article cells with support for pending/loaded states
//

import Foundation
import UIKit
import OpenMDictKit

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
    let word: String
    let dictId: String
    let dictName: String
    var contentState: ArticleContentState
    
    init(word: String, dictId: String, dictName: String, contentState: ArticleContentState = .pending) {
        self.id = "\(dictId):\(word)"
        self.word = word
        self.dictId = dictId
        self.dictName = dictName
        self.contentState = contentState
    }
}

// MARK: - Handoff Support

extension ArticleDisplayItem {
    static let activityType = "com.openmdict.viewArticle"
    
    var userActivity: NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = word
        activity.userInfo = ["id": id, "word": word, "dictId": dictId, "dictName": dictName]
        activity.isEligibleForHandoff = true
        return activity
    }
    
    /// Create from NSUserActivity (state restoration / handoff)
    /// Content will be in pending state - needs to be loaded after dictionary is ready
    static func from(userActivity: NSUserActivity) -> ArticleDisplayItem? {
        guard userActivity.activityType == activityType,
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

// MARK: - Factory (MainActor required for MDict access)

extension ArticleDisplayItem {
    
    /// Create from MDictLookupResult
    @MainActor
    init(from result: MDictLookupResult) {
        self.init(
            word: result.entry.key,
            dictId: result.dict.id,
            dictName: result.dict.metadata?.title ?? result.dict.id,
            contentState: .loaded(html: result.entry.article.html, css: nil)
        )
    }
    
    /// Create from MDict and entry
    @MainActor
    init(from entry: MDictWordEntry, dict: MDict, css: String? = nil) {
        self.init(
            word: entry.key,
            dictId: dict.id,
            dictName: dict.metadata?.title ?? dict.id,
            contentState: .loaded(html: entry.article.html, css: css)
        )
    }
    
    /// Create pending article (for state restoration or entry:// links when dict not loaded)
    static func pending(word: String, dictId: String, dictName: String) -> ArticleDisplayItem {
        ArticleDisplayItem(word: word, dictId: dictId, dictName: dictName, contentState: .pending)
    }
}
