//
//  StubData.swift
//  OpenMDict-iOS
//
//  Static mock data for SwiftUI Previews and UI testing
//

import Foundation
import OpenMDictKit

enum StubData {
    
    // MARK: - Mock Groups (for sidebar previews)
    
    static let groups: [MDicts] = [
        MDicts(
            id: "all",
            name: "All Dictionaries",
            isDefault: true,
            dictionaryIds: ["dict-a", "dict-b", "dict-c"]
        ),
        MDicts(
            id: "ielts",
            name: "IELTS Prep",
            isDefault: false,
            dictionaryIds: ["dict-a", "dict-b"]
        ),
    ]
    
    // MARK: - Mock Words (for word list previews)
    
    static func stubWords(prefix: String, dictId: String, dictName: String) -> [WordDisplayItem] {
        ["", "s", "ed", "ing", "er", "ly"].map {
            WordDisplayItem(word: prefix + $0, dictId: dictId, dictName: dictName)
        }
    }
    
    // MARK: - Mock Articles (for article previews)
    
    static func stubArticle(word: String, dictName: String) -> ArticleDisplayItem {
        ArticleDisplayItem(
            word: word,
            dictId: "stub",
            dictName: dictName,
            html: StubHTML.placeholder(for: word, dictName: dictName),
            css: nil
        )
    }
    
    static let sampleArticles: [ArticleDisplayItem] = [
        ArticleDisplayItem(
            word: "hello",
            dictId: "sample-learners",
            dictName: "Sample Learner's Dictionary",
            html: StubHTML.sampleLearners_hello,
            css: nil
        ),
        ArticleDisplayItem(
            word: "do",
            dictId: "sample-thesaurus",
            dictName: "Sample Thesaurus",
            html: StubHTML.sampleThesaurus_do,
            css: nil
        ),
    ]
}
