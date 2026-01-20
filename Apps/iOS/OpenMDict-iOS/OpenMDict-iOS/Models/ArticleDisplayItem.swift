//
//  ArticleDisplayItem.swift
//  OpenMDict-iOS
//
//  ViewModel for article cells
//

import Foundation
import UIKit
import OpenMDictKit

/// Article cell ViewModel
/// Contains HTML content and optional custom CSS from dictionary
nonisolated struct ArticleDisplayItem: Identifiable, Hashable, Sendable {
    let id: String
    let word: String
    let dictId: String
    let dictName: String
    let html: String
    let css: String?
    
    init(word: String, dictId: String, dictName: String, html: String, css: String? = nil) {
        self.id = "\(dictId):\(word)"
        self.word = word
        self.dictId = dictId
        self.dictName = dictName
        self.html = html
        self.css = css
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
    
    static func from(userActivity: NSUserActivity) -> ArticleDisplayItem? {
        guard userActivity.activityType == activityType,
              let info = userActivity.userInfo,
              let id = info["id"] as? String,
              let word = info["word"] as? String,
              let dictId = info["dictId"] as? String,
              let dictName = info["dictName"] as? String else { return nil }
        // Note: html is not restored from handoff, will need to re-lookup
        return ArticleDisplayItem(word: word, dictId: dictId, dictName: dictName, html: "", css: nil)
    }
}

// MARK: - Factory (MainActor required for MDict access)

extension ArticleDisplayItem {
    
    /// Create from MDictLookupResult
    @MainActor
    init(from result: MDictLookupResult) {
        self.id = "\(result.dict.id):\(result.entry.key)"
        self.word = result.entry.key
        self.dictId = result.dict.id
        self.dictName = result.dict.metadata?.title ?? result.dict.id
        self.html = result.entry.article.html
        self.css = nil  // TODO: Load from MDD in future milestone
    }
    
    /// Create from MDict and entry
    @MainActor
    init(from entry: MDictWordEntry, dict: MDict, css: String? = nil) {
        self.id = "\(dict.id):\(entry.key)"
        self.word = entry.key
        self.dictId = dict.id
        self.dictName = dict.metadata?.title ?? dict.id
        self.html = entry.article.html
        self.css = css
    }
}
