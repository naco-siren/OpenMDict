import Testing
import Foundation
@testable import OpenMDict

/// Unit tests for MDXParser (internal)
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
                print("✅ [MDXParser] Loaded: \(_parser!.info.title) with \(_parser!.entryCount) entries")
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
        #expect(parser.entryCount > 0, "Should have entries")
        #expect(!parser.info.encoding.isEmpty, "Should have encoding")
        #expect(!parser.info.engineVersion.isEmpty, "Should have engine version")
    }
    
    @Test("Entry count matches keyword count")
    func entryCountMatchesKeywords() throws {
        let parser = try #require(Self.parser)
        
        #expect(parser.entryCount == parser.allKeywords.count)
    }
    
    // MARK: - Lookup Tests
    
    @Test("Lookup existing words", arguments: ["the", "hello", "world", "apple", "book"])
    func lookupExisting(word: String) throws {
        let parser = try #require(Self.parser)
        
        let result = parser.lookupWithIndex(word)
        #expect(result != nil, "'\(word)' should exist")
        
        if let (definition, _) = result {
            #expect(!definition.isEmpty)
        }
    }
    
    @Test("Lookup non-existent returns nil")
    func lookupNonExistent() throws {
        let parser = try #require(Self.parser)
        
        #expect(parser.lookupWithIndex("xyznonexistent123") == nil)
    }
    
    @Test("Case-insensitive lookup")
    func caseInsensitive() throws {
        let parser = try #require(Self.parser)
        try #require(!parser.info.isCaseSensitive)
        
        let lower = parser.lookupWithIndex("hello")
        let upper = parser.lookupWithIndex("HELLO")
        
        #expect(lower != nil)
        #expect(upper != nil)
        #expect(lower?.1 == upper?.1)  // Same index
    }
    
    // MARK: - Entry Access Tests
    
    @Test("Entry access by index")
    func entryAtIndex() throws {
        let parser = try #require(Self.parser)
        
        let first = parser.entryAt(0)
        #expect(first != nil, "Should access first entry")
        
        let last = parser.entryAt(parser.entryCount - 1)
        #expect(last != nil, "Should access last entry")
        
        let outOfBounds = parser.entryAt(-1)
        #expect(outOfBounds == nil, "Negative index should return nil")
        
        let beyondEnd = parser.entryAt(parser.entryCount)
        #expect(beyondEnd == nil, "Beyond end should return nil")
    }
    
    @Test("Entry at returns keyword and definition")
    func entryAtContent() throws {
        let parser = try #require(Self.parser)
        
        let result = parser.entryAt(0)
        #expect(result != nil)
        
        if let (keyword, definition) = result {
            #expect(!keyword.isEmpty)
            #expect(!definition.isEmpty)
        }
    }
    
    // MARK: - Navigation Tests
    
    @Test("Navigate via index")
    func navigateViaIndex() throws {
        let parser = try #require(Self.parser)
        
        // Lookup hello to get its index
        let result = parser.lookupWithIndex("hello")
        #expect(result != nil)
        
        if let (_, index) = result {
            // Navigate to prev
            if index > 0 {
                let prev = parser.entryAt(index - 1)
                #expect(prev != nil)
            }
            
            // Navigate to next
            if index < parser.entryCount - 1 {
                let next = parser.entryAt(index + 1)
                #expect(next != nil)
            }
        }
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
        let result = parser.lookupWithIndex("hello")
        #expect(result != nil)
        
        if let (definition, _) = result {
            // Most MDict dictionaries use HTML format
            let hasHTML = definition.contains("<") && definition.contains(">")
            #expect(hasHTML, "Definition should contain HTML tags")
        }
    }
    
    // MARK: - Static Header Reading
    
    @Test("Read header only (fast)")
    func readHeaderOnly() throws {
        let parser = try #require(Self.parser)
        
        // Get path from existing parser
        // We need to access path somehow... 
        // Since parser doesn't expose path, we test via MDictReader
        // This test is better suited for MDictReaderTests
    }
}
