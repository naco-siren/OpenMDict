import Testing
import Foundation
@testable import OpenMDict

/// Unit tests for MDXParser (internal)
/// Tests MDX parsing functionality in isolation
///
/// Environment variables:
///   MDICT_TEST_FILE   - Path to .mdx file (required)
///   MDICT_TEST_WORD   - Specific word to test lookup (optional)
///   MDICT_TEST_SAMPLE - Number of entries to sample for testing, default 5 (optional)
///
/// Examples:
///   MDICT_TEST_FILE=dict.mdx swift test
///   MDICT_TEST_FILE=dict.mdx MDICT_TEST_WORD=hello swift test
///   MDICT_TEST_FILE=dict.mdx MDICT_TEST_SAMPLE=10 swift test
@Suite(.serialized)
struct MDXParserTests {
    
    // MARK: - Test Configuration
    
    /// Number of entries to sample for testing
    static var sampleSize: Int {
        if let val = ProcessInfo.processInfo.environment["MDICT_TEST_SAMPLE"],
           let n = Int(val), n > 0 {
            return n
        }
        return 5
    }
    
    /// Specific word to test (if provided)
    static var testWord: String? {
        ProcessInfo.processInfo.environment["MDICT_TEST_WORD"]
    }
    
    /// Words to use for lookup tests
    static var testWords: [String] {
        if let word = testWord {
            return [word]
        }
        guard let parser = parser else { return [] }
        let count = min(sampleSize, parser.entryCount)
        return Array(parser.allKeywords.prefix(count))
    }
    
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
                if let word = testWord {
                    print("   Test word: \(word)")
                } else {
                    print("   Sample size: \(sampleSize)")
                }
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
    
    @Test("Lookup test words")
    func lookupTestWords() throws {
        let parser = try #require(Self.parser)
        let words = Self.testWords
        
        #expect(!words.isEmpty, "Should have test words")
        
        for word in words {
            let result = parser.lookupWithIndex(word)
            #expect(result != nil, "'\(word)' should exist")
            
            if let (definition, _) = result {
                #expect(!definition.isEmpty, "Definition for '\(word)' should not be empty")
            }
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
        
        // Use first test word that has alphabetic characters
        let testWord = Self.testWords.first { $0.rangeOfCharacter(from: .letters) != nil } 
                       ?? parser.allKeywords.first { $0.rangeOfCharacter(from: .letters) != nil }
                       ?? parser.allKeywords[0]
        
        let lower = parser.lookupWithIndex(testWord.lowercased())
        let upper = parser.lookupWithIndex(testWord.uppercased())
        
        #expect(lower != nil, "Lowercase lookup should work")
        #expect(upper != nil, "Uppercase lookup should work")
        #expect(lower?.1 == upper?.1, "Should return same index")
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
        
        // Use first test word or middle entry
        let testWord = Self.testWords.first ?? parser.allKeywords[parser.entryCount / 2]
        
        let result = parser.lookupWithIndex(testWord)
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
        
        // Get prefix from first test word
        let firstWord = Self.testWords.first ?? parser.allKeywords[0]
        let prefix = String(firstWord.prefix(min(3, firstWord.count)))
        
        let results = parser.search(prefix: prefix, limit: 10)
        
        #expect(!results.isEmpty, "Should find entries starting with '\(prefix)'")
        for word in results {
            #expect(word.lowercased().hasPrefix(prefix.lowercased()))
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
        
        // Create typo from first test word
        let firstWord = Self.testWords.first ?? parser.allKeywords[0]
        let typo = firstWord.count > 2 ? String(firstWord.dropLast()) + "x" : firstWord + "x"
        
        let suggestions = parser.suggestions(for: typo, limit: 5)
        #expect(suggestions.count <= 5)
    }
    
    // MARK: - Definition Content Tests
    
    @Test("Definition contains HTML")
    func definitionHasHTML() throws {
        let parser = try #require(Self.parser)
        let firstWord = Self.testWords.first ?? parser.allKeywords[0]
        let result = parser.lookupWithIndex(firstWord)
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
        _ = try #require(Self.parser)
        // This test validates that parser loaded successfully
        // Path access would be tested via MDictReader
    }
}
