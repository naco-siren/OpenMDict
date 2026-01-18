//
//  WordDisplayItem.swift
//  OpenMDict-iOS
//
//  ViewModel for word list cells
//

import Foundation
import OpenMDict
import OpenMDictKit

/// Word list cell ViewModel
/// Distinguishes words from different dictionaries in group search results
struct WordDisplayItem: Identifiable, Hashable, Sendable {
    let word: String
    let dictId: String
    let dictName: String
    
    var id: String { "\(dictId):\(word)" }
}

// MARK: - Factory (MainActor required for MDict access)

extension WordDisplayItem {
    
    /// Create items from MDict search results
    @MainActor
    static func from(words: [String], dict: MDict) -> [WordDisplayItem] {
        let name = dict.metadata?.title ?? dict.id
        return words.map { WordDisplayItem(word: $0, dictId: dict.id, dictName: name) }
    }
}
