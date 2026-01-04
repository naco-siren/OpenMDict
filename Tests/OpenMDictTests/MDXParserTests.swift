import Testing
import Foundation
@testable import OpenMDict

/// Unit tests for MDXParser
/// Tests MDX parsing functionality in isolation
/// Run with: MDICT_TEST_FILE=path/to/dict.mdx swift test
@Suite(.serialized)
struct MDXParserTests {
    
    // Shared parser instance
    static var _parser: MDXParser?
    static var _initialized = false
    
    static var parser: MDXParser? {
        if !_initialized {
            _initialized = true
            guard let path = ProcessInfo.processInfo.environment["MDICT_TEST_FILE"],
                  !path.isEmpty else {
                print("⚠️ Set MDICT_TEST_FILE environment variable to run tests")
                return nil
            }
            do {
                _parser = try MDXParser(path: path)
                print("✅ [MDXParser] Loaded: \(_parser!.info.title) with \(_parser!.info.entryCount) entries")
            } catch {
                print("❌ [MDXParser] Failed: \(error)")
            }
        }
        return _parser
    }
    
    // MARK: - Header Parsing Tests
    
    @Test("Parse dictionary info")
    func parseInfo() throws {
        let parser = try #require(Self.parser, "Parser not loaded")
        
        #expect(!parser.info.title.isEmpty, "Should have title")
        #expect(parser.info.entryCount > 0, "Should have entries")
        #expect(!parser.info.encoding.isEmpty, "Should have encoding")
        #expect(!parser.info.engineVersion.isEmpty, "Should have engine version")
    }
    
    @Test("Entry count matches keyword count")
    func entryCountMatchesKeywords() throws {
        let parser = try #require(Self.parser)
        
        #expect(parser.info.entryCount == parser.allKeywords.count)
    }
    
    // MARK: - Lookup Tests
    
    @Test("Lookup existing words", arguments: ["the", "hello", "world", "apple", "book"])
    func lookupExisting(word: String) throws {
        let parser = try #require(Self.parser)
        
        let entry = parser.lookup(word)
        #expect(entry != nil, "'\(word)' should exist")
        
        if let entry {
            #expect(entry.keyword.lowercased() == word.lowercased())
            #expect(!entry.definition.isEmpty)
        }
    }
    
    @Test("Lookup non-existent returns nil")
    func lookupNonExistent() throws {
        let parser = try #require(Self.parser)
        
        #expect(parser.lookup("xyznonexistent123") == nil)
    }
    
    @Test("Case-insensitive lookup")
    func caseInsensitive() throws {
        let parser = try #require(Self.parser)
        try #require(!parser.info.isCaseSensitive)
        
        let lower = parser.lookup("hello")
        let upper = parser.lookup("HELLO")
        
        #expect(lower?.keyword == upper?.keyword)
    }
    
    // MARK: - Subscript Access Tests
    
    @Test("Subscript access by index")
    func subscriptAccess() throws {
        let parser = try #require(Self.parser)
        
        let first = parser[0]
        #expect(first != nil, "Should access first entry")
        
        let last = parser[parser.info.entryCount - 1]
        #expect(last != nil, "Should access last entry")
        
        let outOfBounds = parser[-1]
        #expect(outOfBounds == nil, "Negative index should return nil")
        
        let beyondEnd = parser[parser.info.entryCount]
        #expect(beyondEnd == nil, "Beyond end should return nil")
    }
    
    // MARK: - Navigation Tests
    
    @Test("Entry navigation prev/next")
    func entryNavigation() throws {
        let parser = try #require(Self.parser)
        let entry = try #require(parser.lookup("hello"))
        
        if let prev = entry.prev {
            #expect(prev.index == entry.index - 1)
            #expect(prev.next?.keyword == entry.keyword)
        }
        
        if let next = entry.next {
            #expect(next.index == entry.index + 1)
            #expect(next.prev?.keyword == entry.keyword)
        }
    }
    
    @Test("First entry has no prev")
    func firstEntryNoPrev() throws {
        let parser = try #require(Self.parser)
        let first = try #require(parser[0])
        
        #expect(first.isFirst)
        #expect(first.prev == nil)
        #expect(first.next != nil)
    }
    
    @Test("Last entry has no next")
    func lastEntryNoNext() throws {
        let parser = try #require(Self.parser)
        let last = try #require(parser[parser.info.entryCount - 1])
        
        #expect(last.isLast)
        #expect(last.next == nil)
        #expect(last.prev != nil)
    }
    
    // MARK: - Search Tests
    
    @Test("Prefix search")
    func prefixSearch() throws {
        let parser = try #require(Self.parser)
        
        let results = parser.search(prefix: "hel", limit: 10)
        
        #expect(!results.isEmpty)
        for word in results {
            #expect(word.lowercased().hasPrefix("hel"))
        }
    }
    
    @Test("Search respects limit", arguments: [5, 10, 20])
    func searchLimit(limit: Int) throws {
        let parser = try #require(Self.parser)
        
        let results = parser.search(prefix: "a", limit: limit)
        #expect(results.count <= limit)
    }
    
    @Test("Suggestions for typo")
    func suggestions() throws {
        let parser = try #require(Self.parser)
        
        let suggestions = parser.suggestions(for: "helo", limit: 5)
        #expect(!suggestions.isEmpty)
    }
    
    // MARK: - Definition Content Tests
    
    @Test("Definition contains HTML")
    func definitionHasHTML() throws {
        let parser = try #require(Self.parser)
        let entry = try #require(parser.lookup("hello"))
        
        // Most MDict dictionaries use HTML format
        let hasHTML = entry.definition.contains("<") && entry.definition.contains(">")
        #expect(hasHTML, "Definition should contain HTML tags")
    }
}
