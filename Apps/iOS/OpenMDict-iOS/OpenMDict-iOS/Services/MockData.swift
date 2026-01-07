//
//  MockData.swift
//  OpenMDict-iOS
//
//  Prototype mock data for testing UI without real dictionary integration
//

import UIKit

// MARK: - Article Item (Mock)

/// Represents a dictionary article/entry
/// In real app, this would come from MDictWordEntry
struct ArticleItem: Identifiable, Equatable, Hashable {
    let id: String
    let title: String       // headword
    let dictName: String    // which dictionary
    let color: UIColor      // for prototype visualization
    
    init(title: String, dictName: String) {
        // Use title + dictName as stable id (same word = same id)
        self.id = "\(dictName):\(title)"
        self.title = title
        self.dictName = dictName
        self.color = Self.randomPastelColor()
    }
    
    /// Create with explicit id (for restoration)
    init(id: String, title: String, dictName: String, color: UIColor? = nil) {
        self.id = id
        self.title = title
        self.dictName = dictName
        self.color = color ?? Self.randomPastelColor()
    }
    
    private static func randomPastelColor() -> UIColor {
        let hue = CGFloat.random(in: 0...1)
        return UIColor(hue: hue, saturation: 0.3, brightness: 0.95, alpha: 1.0)
    }
    
    static func == (lhs: ArticleItem, rhs: ArticleItem) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - NSUserActivity Support

extension ArticleItem {
    
    static let activityType = "com.openmdict.viewArticle"
    
    var userActivity: NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = title
        activity.userInfo = [
            "id": id,
            "title": title,
            "dictName": dictName
        ]
        activity.isEligibleForHandoff = true
        return activity
    }
    
    static func from(userActivity: NSUserActivity) -> ArticleItem? {
        guard userActivity.activityType == activityType,
              let info = userActivity.userInfo,
              let id = info["id"] as? String,
              let title = info["title"] as? String,
              let dictName = info["dictName"] as? String else {
            return nil
        }
        return ArticleItem(id: id, title: title, dictName: dictName)
    }
}

// MARK: - Dictionary Item (Mock)

struct DictionaryItem: Identifiable {
    let id: String
    let name: String
    let entryCount: Int
    var isLoaded: Bool
    
    static let mockData: [DictionaryItem] = [
        DictionaryItem(id: "dict-a", name: "Sample Dictionary A", entryCount: 86000, isLoaded: true),
        DictionaryItem(id: "dict-b", name: "Sample Dictionary B", entryCount: 72000, isLoaded: false),
        DictionaryItem(id: "dict-c", name: "Sample Dictionary C", entryCount: 95000, isLoaded: false),
        DictionaryItem(id: "dict-d", name: "Sample Dictionary D", entryCount: 68000, isLoaded: true),
    ]
}

// MARK: - Word Item (Mock)

struct WordItem: Identifiable, Hashable {
    let id: String
    let word: String
    let dictId: String
    
    init(word: String, dictId: String) {
        self.id = "\(dictId):\(word)"
        self.word = word
        self.dictId = dictId
    }
    
    static func mockWords(for prefix: String, dictId: String) -> [WordItem] {
        let suffixes = ["", "s", "ed", "ing", "er", "est", "ly", "ness", "tion", "able"]
        return suffixes.prefix(8).map { suffix in
            WordItem(word: prefix + suffix, dictId: dictId)
        }
    }
}
