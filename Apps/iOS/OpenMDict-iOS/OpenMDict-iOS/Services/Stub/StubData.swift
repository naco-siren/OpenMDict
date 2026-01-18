//
//  StubData.swift
//  OpenMDict-iOS
//
//  Static mock data for UI testing and previews
//

import Foundation

enum StubData {
    
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
    
    static var sampleArticles: [ArticleDisplayItem] {
        [
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
}
