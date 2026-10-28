//
//  WordDisplayItem.swift
//  OpenMDict-iOS
//
//  ViewModel for word list cells
//

import Foundation
import OpenMDictKit

/// Word list cell ViewModel
/// Distinguishes words from different dictionaries in group search results
struct WordDisplayItem: Identifiable, Hashable, Sendable {
    let word: String
    let dictId: String
    let dictName: String
    /// How the search found the key when no key starts with the query as
    /// typed (`WordSearchResult.fallback`); nil for a direct result.
    var fallback: MDictLookupFallback? = nil

    var id: String { "\(dictId):\(word)" }
}

// MARK: - Factory

extension WordDisplayItem {

    /// Create from WordSearchResult (from reactive lookup pipeline)
    init(from result: WordSearchResult) {
        self.init(word: result.word, dictId: result.dictId, dictName: result.dictName,
                  fallback: result.fallback)
    }
    
    /// Create items from MDict search results (MainActor required for MDict access)
    @MainActor
    static func from(words: [String], dict: MDict) -> [WordDisplayItem] {
        return words.map { WordDisplayItem(word: $0, dictId: dict.id, dictName: dict.preferredTitle) }
    }
}
