//
//  MockData.swift
//  OpenMDict-iOS
//

import UIKit

// MARK: - Article Item

nonisolated struct ArticleItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let dictName: String
    let html: String  // HTML content for WKWebView
    
    init(title: String, dictName: String, html: String? = nil) {
        self.id = "\(dictName):\(title)"
        self.title = title
        self.dictName = dictName
        self.html = html ?? StubHTML.placeholder(for: title, dictName: dictName)
    }
    
    init(id: String, title: String, dictName: String, html: String? = nil) {

        self.id = id
        self.title = title
        self.dictName = dictName
        self.html = html ?? StubHTML.placeholder(for: title, dictName: dictName)
    }
    
    static func == (lhs: ArticleItem, rhs: ArticleItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ArticleItem {
    static let activityType = "com.openmdict.viewArticle"
    
    var userActivity: NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = title
        activity.userInfo = ["id": id, "title": title, "dictName": dictName]
        activity.isEligibleForHandoff = true
        return activity
    }
    
    static func from(userActivity: NSUserActivity) -> ArticleItem? {
        guard userActivity.activityType == activityType,
              let info = userActivity.userInfo,
              let id = info["id"] as? String,
              let title = info["title"] as? String,
              let dictName = info["dictName"] as? String else { return nil }
        return ArticleItem(id: id, title: title, dictName: dictName)
    }
}

// MARK: - Dictionary Item

nonisolated struct DictionaryItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let entryCount: Int
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DictionaryItem, rhs: DictionaryItem) -> Bool { lhs.id == rhs.id }
    
    static let mockData: [DictionaryItem] = [
        DictionaryItem(id: "dict-a", name: "Sample Dictionary A", entryCount: 86000),
        DictionaryItem(id: "dict-b", name: "Sample Dictionary B", entryCount: 72000),
        DictionaryItem(id: "dict-c", name: "Sample Dictionary C", entryCount: 95000),
        DictionaryItem(id: "dict-d", name: "Sample Dictionary D", entryCount: 68000),
    ]
    
    static func find(id: String) -> DictionaryItem? {
        mockData.first { $0.id == id }
    }
}

// MARK: - Dictionary Group

nonisolated struct DictionaryGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
    var dictionaryIds: [String]
    
    var dictionaries: [DictionaryItem] {
        dictionaryIds.compactMap { DictionaryItem.find(id: $0) }
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DictionaryGroup, rhs: DictionaryGroup) -> Bool { lhs.id == rhs.id }
    
    static let mockData: [DictionaryGroup] = [
        DictionaryGroup(id: "all", name: "All Dictionaries", isDefault: true,
                        dictionaryIds: ["dict-a", "dict-b", "dict-c", "dict-d"]),
        DictionaryGroup(id: "ielts", name: "IELTS Prep", isDefault: false,
                        dictionaryIds: ["dict-a", "dict-d"]),
        DictionaryGroup(id: "gre", name: "GRE Prep", isDefault: false,
                        dictionaryIds: ["dict-c", "dict-b", "dict-d"]),
    ]
}

// MARK: - Sidebar Item

nonisolated enum SidebarItem: Hashable, Sendable {
    case header(String, isBold: Bool)
    case dictGroup(DictionaryGroup, isDefault: Bool)
    case dict(DictionaryItem, group: DictionaryGroup)
    case importDict
    case deleteDict
    case settings
    
    var id: String {
        switch self {
        case .header(let t, _): return "header:\(t)"
        case .dictGroup(let g, _): return "dictGroup:\(g.id)"
        case .dict(let d, let g): return "dict:\(g.id):\(d.id)"
        case .importDict: return "action:import"
        case .deleteDict: return "action:delete"
        case .settings: return "action:settings"
        }
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool { lhs.id == rhs.id }
}

// MARK: - Word Item

nonisolated struct WordItem: Identifiable, Hashable, Sendable {
    let id: String
    let word: String
    let dictId: String
    
    init(word: String, dictId: String) {
        self.id = "\(dictId):\(word)"
        self.word = word
        self.dictId = dictId
    }
    
    static func mockWords(for prefix: String, dictId: String) -> [WordItem] {
        ["", "s", "ed", "ing", "er", "est", "ly", "ness"].map { WordItem(word: prefix + $0, dictId: dictId) }
    }
}
