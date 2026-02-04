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
    
    var id: String { "\(dictId):\(word)" }
}

// MARK: - Factory

extension WordDisplayItem {
    
    /// Create from WordSearchResult (from reactive lookup pipeline)
    init(from result: WordSearchResult) {
        self.word = result.word
        self.dictId = result.dictId
        self.dictName = result.dictName
    }
    
    /// Create items from MDict search results (MainActor required for MDict access)
    @MainActor
    static func from(words: [String], dict: MDict) -> [WordDisplayItem] {
        let name = dict.metadata?.title ?? dict.id
        return words.map { WordDisplayItem(word: $0, dictId: dict.id, dictName: name) }
    }
}
