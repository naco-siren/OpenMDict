import XCTest
@testable import OpenMDict

final class MDictReaderTests: XCTestCase {
    
    // Class-level: load dictionary only ONCE for all tests
    static var dict: MDictReader!
    static var testDictPath: String = ""
    
    override class func setUp() {
        super.setUp()
        testDictPath = ProcessInfo.processInfo.environment["MDICT_TEST_FILE"] ?? ""
        guard !testDictPath.isEmpty else {
            print("⚠️ Set MDICT_TEST_FILE environment variable to run tests")
            return
        }
        
        do {
            dict = try MDictReader(path: testDictPath)
            print("✅ Loaded: \(dict.info.title) with \(dict.info.entryCount) entries")
        } catch {
            print("❌ Failed to load dictionary: \(error)")
        }
    }
    
    override class func tearDown() {
        dict = nil
        super.tearDown()
    }
    
    // Instance accessor
    var dict: MDictReader {
        get throws {
            guard let d = Self.dict else {
                throw XCTSkip("Dictionary not loaded. Set MDICT_TEST_FILE env var.")
            }
            return d
        }
    }
    
    // MARK: - Basic Tests
    
    func testLoadDictionary() throws {
        let dict = try self.dict
        
        XCTAssertFalse(dict.info.title.isEmpty, "Dictionary should have a title")
        XCTAssertGreaterThan(dict.info.entryCount, 0, "Dictionary should have entries")
    }
    
    func testQueryExistingWord() throws {
        let dict = try self.dict
        
        let testWords = ["the", "hello", "world", "apple", "book"]
        
        for word in testWords {
            let entry = dict.query(word)
            XCTAssertNotNil(entry, "'\(word)' should exist in dictionary")
            if let entry = entry {
                XCTAssertEqual(entry.keyword.lowercased(), word.lowercased())
                XCTAssertFalse(entry.definition.isEmpty, "\(word) should have a definition")
            }
        }
    }
    
    func testQueryNonExistentWord() throws {
        let dict = try self.dict
        
        let result = dict.query("xyznonexistent123")
        XCTAssertNil(result, "Non-existent word should return nil")
    }
    
    func testCaseInsensitiveQuery() throws {
        let dict = try self.dict
        
        guard !dict.info.isCaseSensitive else {
            throw XCTSkip("Dictionary is case-sensitive")
        }
        
        let lowercase = dict.query("hello")
        let uppercase = dict.query("HELLO")
        let mixedcase = dict.query("HeLLo")
        
        XCTAssertNotNil(lowercase)
        XCTAssertNotNil(uppercase)
        XCTAssertNotNil(mixedcase)
        XCTAssertEqual(lowercase?.keyword, uppercase?.keyword)
        XCTAssertEqual(lowercase?.keyword, mixedcase?.keyword)
    }
    
    // MARK: - Navigation Tests
    
    func testPrevNextNavigation() throws {
        let dict = try self.dict
        
        guard let entry = dict.query("hello") else {
            throw XCTSkip("'hello' not found in dictionary")
        }
        
        // Test prev
        if let prev = entry.prev {
            XCTAssertEqual(prev.index, entry.index - 1)
            XCTAssertEqual(prev.next?.keyword, entry.keyword, "prev.next should return to original")
        }
        
        // Test next
        if let next = entry.next {
            XCTAssertEqual(next.index, entry.index + 1)
            XCTAssertEqual(next.prev?.keyword, entry.keyword, "next.prev should return to original")
        }
    }
    
    func testNavigationChain() throws {
        let dict = try self.dict
        
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
            current = entry.next
            count += 1
        }
        
        XCTAssertEqual(count, 5, "Should be able to walk 5 entries")
    }
    
    func testLastEntry() throws {
        let dict = try self.dict
        
        guard let last = dict.entry(at: dict.info.entryCount - 1) else {
            XCTFail("Should be able to get last entry")
            return
        }
        
        XCTAssertTrue(last.isLast)
        XCTAssertNil(last.next, "Last entry should have no next")
        XCTAssertNotNil(last.prev, "Last entry should have prev")
    }
    
    // MARK: - Search Tests
    
    func testPrefixSearch() throws {
        let dict = try self.dict
        
        let results = dict.search(prefix: "hel", limit: 10)
        
        XCTAssertFalse(results.isEmpty, "Should find words starting with 'hel'")
        
        for word in results {
            XCTAssertTrue(word.lowercased().hasPrefix("hel"), "'\(word)' should start with 'hel'")
        }
    }
    
    func testSearchLimit() throws {
        let dict = try self.dict
        
        let results5 = dict.search(prefix: "a", limit: 5)
        let results20 = dict.search(prefix: "a", limit: 20)
        
        XCTAssertLessThanOrEqual(results5.count, 5)
        XCTAssertLessThanOrEqual(results20.count, 20)
    }
    
    func testSuggestions() throws {
        let dict = try self.dict
        
        let suggestions = dict.suggestions(for: "helo", limit: 5)
        
        XCTAssertFalse(suggestions.isEmpty, "Should have suggestions for 'helo'")
    }
    
    // MARK: - Performance Tests
    
    func testQueryPerformance() throws {
        let dict = try self.dict
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
        let dict = try self.dict
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
