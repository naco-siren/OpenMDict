//
//  ArticleDisplayItem.swift
//  OpenMDict-iOS
//
//  ViewModel for article cells
//

import Foundation
import OpenMDict
import OpenMDictKit

/// Article cell ViewModel
/// Contains HTML content and optional custom CSS from dictionary
struct ArticleDisplayItem: Identifiable, Hashable, Sendable {
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

// MARK: - Factory

extension ArticleDisplayItem {
    
    /// Create from MDictLookupResult
    init(from result: MDictLookupResult) {
        self.id = "\(result.dict.id):\(result.entry.key)"
        self.word = result.entry.key
        self.dictId = result.dict.id
        self.dictName = result.dict.metadata?.title ?? result.dict.id
        self.html = result.entry.article.html
        self.css = nil  // TODO: Load from MDD in future milestone
    }
    
    /// Create from MDict and entry
    init(from entry: MDictWordEntry, dict: MDict, css: String? = nil) {
        self.id = "\(dict.id):\(entry.key)"
        self.word = entry.key
        self.dictId = dict.id
        self.dictName = dict.metadata?.title ?? dict.id
        self.html = entry.article.html
        self.css = css
    }
}
