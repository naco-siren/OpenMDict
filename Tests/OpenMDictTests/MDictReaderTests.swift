import Testing
import Foundation
@testable import OpenMDict

/// Tests for MDictReader
/// Run with: MDICT_TEST_FILE=path/to/dict.mdx swift test
@Suite(.serialized)  // Run tests serially to avoid race conditions
struct MDictReaderTests {
    
    // Shared dictionary instance (loaded once)
    static var _dict: MDictReader?
    static var _initialized = false
    
    static var dict: MDictReader? {
        if !_initialized {
            _initialized = true
            guard let path = ProcessInfo.processInfo.environment["MDICT_TEST_FILE"],
                  !path.isEmpty else {
                print("⚠️ Set MDICT_TEST_FILE environment variable to run tests")
                return nil
            }
            do {
                _dict = try MDictReader(path: path)
                print("✅ Loaded: \(_dict!.info.title) with \(_dict!.info.entryCount) entries")
            } catch {
                print("❌ Failed to load dictionary: \(error)")
            }
        }
        return _dict
    }
    
    // MARK: - Basic Tests
    
    @Test("Load dictionary and verify info")
    func loadDictionary() throws {
        let dict = try #require(Self.dict, "Dictionary not loaded")
        
        #expect(!dict.info.title.isEmpty, "Dictionary should have a title")
        #expect(dict.info.entryCount > 0, "Dictionary should have entries")
    }
    
    @Test("Lookup existing words", arguments: ["the", "hello", "world", "apple", "book"])
    func lookupExistingWord(word: String) throws {
        let dict = try #require(Self.dict)
        
        let entry = dict.lookup(word)
        #expect(entry != nil, "'\(word)' should exist in dictionary")
        
        if let entry {
            #expect(entry.keyword.lowercased() == word.lowercased())
            #expect(!entry.definition.isEmpty, "\(word) should have a definition")
        }
    }
    
    @Test("Lookup non-existent word returns nil")
    func lookupNonExistentWord() throws {
        let dict = try #require(Self.dict)
        
        let result = dict.lookup("xyznonexistent123")
        #expect(result == nil, "Non-existent word should return nil")
    }
    
    @Test("Case-insensitive lookup")
    func caseInsensitiveLookup() throws {
        let dict = try #require(Self.dict)
        
        // Skip if dictionary is case-sensitive
        try #require(!dict.info.isCaseSensitive, "Dictionary is case-sensitive")
        
        let lowercase = dict.lookup("hello")
        let uppercase = dict.lookup("HELLO")
        let mixedcase = dict.lookup("HeLLo")
        
        #expect(lowercase != nil)
        #expect(uppercase != nil)
        #expect(mixedcase != nil)
        #expect(lowercase?.keyword == uppercase?.keyword)
        #expect(lowercase?.keyword == mixedcase?.keyword)
    }
    
    // MARK: - Navigation Tests
    
    @Test("Prev/Next navigation")
    func prevNextNavigation() throws {
        let dict = try #require(Self.dict)
        let entry = try #require(dict.lookup("hello"), "'hello' not found")
        
        // Test prev
        if let prev = entry.prev {
            #expect(prev.index == entry.index - 1)
            #expect(prev.next?.keyword == entry.keyword, "prev.next should return to original")
        }
        
        // Test next
        if let next = entry.next {
            #expect(next.index == entry.index + 1)
            #expect(next.prev?.keyword == entry.keyword, "next.prev should return to original")
        }
    }
    
    @Test("Navigation chain from first entry")
    func navigationChain() throws {
        let dict = try #require(Self.dict)
        let first = try #require(dict.entry(at: 0), "Should get first entry")
        
        #expect(first.isFirst)
        #expect(first.prev == nil, "First entry should have no prev")
        
        // Walk forward 5 entries
        var current: MDictEntry? = first
        var count = 0
        while let entry = current, count < 5 {
            current = entry.next
            count += 1
        }
        
        #expect(count == 5, "Should be able to walk 5 entries")
    }
    
    @Test("Last entry navigation")
    func lastEntry() throws {
        let dict = try #require(Self.dict)
        let last = try #require(dict.entry(at: dict.info.entryCount - 1), "Should get last entry")
        
        #expect(last.isLast)
        #expect(last.next == nil, "Last entry should have no next")
        #expect(last.prev != nil, "Last entry should have prev")
    }
    
    // MARK: - Search Tests
    
    @Test("Prefix search")
    func prefixSearch() throws {
        let dict = try #require(Self.dict)
        
        let results = dict.search(prefix: "hel", limit: 10)
        
        #expect(!results.isEmpty, "Should find words starting with 'hel'")
        
        for word in results {
            #expect(word.lowercased().hasPrefix("hel"), "'\(word)' should start with 'hel'")
        }
    }
    
    @Test("Search respects limit", arguments: [5, 10, 20])
    func searchLimit(limit: Int) throws {
        let dict = try #require(Self.dict)
        
        let results = dict.search(prefix: "a", limit: limit)
        #expect(results.count <= limit)
    }
    
    @Test("Suggestions for misspelled word")
    func suggestions() throws {
        let dict = try #require(Self.dict)
        
        let suggestions = dict.suggestions(for: "helo", limit: 5)
        #expect(!suggestions.isEmpty, "Should have suggestions for 'helo'")
    }
}