import XCTest
@testable import OpenMDict

final class MDictReaderTests: XCTestCase {
    
    // Set this to your test dictionary path
    // In real tests, you'd use a fixture file bundled with tests
    static let testDictPath = ProcessInfo.processInfo.environment["MDICT_TEST_FILE"] ?? ""
    
    var dict: MDictReader?
    
    override func setUpWithError() throws {
        // Skip tests if no dictionary file is configured
        guard !Self.testDictPath.isEmpty else {
            throw XCTSkip("Set MDICT_TEST_FILE environment variable to run tests")
        }
        dict = try MDictReader(path: Self.testDictPath)
    }
    
    // MARK: - Basic Tests
    
    func testLoadDictionary() throws {
        let dict = try XCTUnwrap(self.dict)
        
        XCTAssertFalse(dict.info.title.isEmpty, "Dictionary should have a title")
        XCTAssertGreaterThan(dict.info.entryCount, 0, "Dictionary should have entries")
        print("Loaded: \(dict.info.title) with \(dict.info.entryCount) entries")
    }
    
    func testQueryExistingWord() throws {
        let dict = try XCTUnwrap(self.dict)
        
        // Test common words that should exist in most English dictionaries
        let testWords = ["the", "hello", "world", "apple", "book"]
        
        for word in testWords {
            if let entry = dict.query(word) {
                XCTAssertEqual(entry.keyword.lowercased(), word.lowercased())
                XCTAssertFalse(entry.definition.isEmpty, "\(word) should have a definition")
                print("✓ Found '\(word)': \(entry.definition.prefix(100))...")
            }
        }
    }
    
    func testQueryNonExistentWord() throws {
        let dict = try XCTUnwrap(self.dict)
        
        let result = dict.query("xyznonexistent123")
        XCTAssertNil(result, "Non-existent word should return nil")
    }
    
    func testCaseInsensitiveQuery() throws {
        let dict = try XCTUnwrap(self.dict)
        
        // Skip if dictionary is case-sensitive
        guard !dict.info.isCaseSensitive else {
            throw XCTSkip("Dictionary is case-sensitive")
        }
        
        let lowercase = dict.query("hello")
        let uppercase = dict.query("HELLO")
        let mixedcase = dict.query("HeLLo")
        
        // All should find the same entry
        XCTAssertEqual(lowercase?.keyword, uppercase?.keyword)
        XCTAssertEqual(lowercase?.keyword, mixedcase?.keyword)
    }
    
    // MARK: - Navigation Tests
    
    func testPrevNextNavigation() throws {
        let dict = try XCTUnwrap(self.dict)
        
        // Get an entry in the middle
        guard let entry = dict.query("hello") else {
            throw XCTSkip("'hello' not found in dictionary")
        }
        
        print("Current: [\(entry.index)] '\(entry.keyword)'")
        
        // Test prev
        if let prev = entry.prev {
            XCTAssertEqual(prev.index, entry.index - 1)
            print("Prev: [\(prev.index)] '\(prev.keyword)'")
            
            // prev.next should be original entry
            XCTAssertEqual(prev.next?.keyword, entry.keyword)
        }
        
        // Test next
        if let next = entry.next {
            XCTAssertEqual(next.index, entry.index + 1)
            print("Next: [\(next.index)] '\(next.keyword)'")
            
            // next.prev should be original entry
            XCTAssertEqual(next.prev?.keyword, entry.keyword)
        }
    }
    
    func testNavigationChain() throws {
        let dict = try XCTUnwrap(self.dict)
        
        // Start from first entry
        guard let first = dict.entry(at: 0) else {
            XCTFail("Should be able to get first entry")
            return
        }
        
        XCTAssertTrue(first.isFirst)
        XCTAssertNil(first.prev, "First entry should have no prev")
        
        // Walk forward 5 entries
        var current: MDictEntry? = first
        var count = 0
        while let entry = current, count < 5 {
            print("[\(entry.index)] \(entry.keyword)")
            current = entry.next
            count += 1
        }
        
        XCTAssertEqual(count, 5, "Should be able to walk 5 entries")
    }
    
    func testLastEntry() throws {
        let dict = try XCTUnwrap(self.dict)
        
        guard let last = dict.entry(at: dict.info.entryCount - 1) else {
            XCTFail("Should be able to get last entry")
            return
        }
        
        XCTAssertTrue(last.isLast)
        XCTAssertNil(last.next, "Last entry should have no next")
        XCTAssertNotNil(last.prev, "Last entry should have prev")
        
        print("Last entry: [\(last.index)] '\(last.keyword)'")
    }
    
    // MARK: - Search Tests
    
    func testPrefixSearch() throws {
        let dict = try XCTUnwrap(self.dict)
        
        let results = dict.search(prefix: "hel", limit: 10)
        
        XCTAssertFalse(results.isEmpty, "Should find words starting with 'hel'")
        
        for word in results {
            XCTAssertTrue(word.lowercased().hasPrefix("hel"), "'\(word)' should start with 'hel'")
        }
        
        print("Words starting with 'hel': \(results)")
    }
    
    func testSearchLimit() throws {
        let dict = try XCTUnwrap(self.dict)
        
        let results5 = dict.search(prefix: "a", limit: 5)
        let results20 = dict.search(prefix: "a", limit: 20)
        
        XCTAssertLessThanOrEqual(results5.count, 5)
        XCTAssertLessThanOrEqual(results20.count, 20)
    }
    
    func testSuggestions() throws {
        let dict = try XCTUnwrap(self.dict)
        
        // Test with a typo
        let suggestions = dict.suggestions(for: "helo", limit: 5)
        
        print("Suggestions for 'helo': \(suggestions)")
        
        // Should suggest words starting with 'hel'
        XCTAssertFalse(suggestions.isEmpty)
    }
    
    // MARK: - Performance Tests
    
    func testQueryPerformance() throws {
        let dict = try XCTUnwrap(self.dict)
        
        let testWords = ["hello", "world", "apple", "banana", "computer"]
        
        measure {
            for _ in 0..<1000 {
                for word in testWords {
                    _ = dict.query(word)
                }
            }
        }
    }
    
    func testSearchPerformance() throws {
        let dict = try XCTUnwrap(self.dict)
        
        let prefixes = ["a", "ab", "abc", "he", "hel", "the"]
        
        measure {
            for _ in 0..<100 {
                for prefix in prefixes {
                    _ = dict.search(prefix: prefix, limit: 20)
                }
            }
        }
    }
}
