import Testing
import Foundation
@testable import OpenMDict

/// Integration tests for MDictReader (MDX + MDD combined)
/// Tests the facade API and resource integration
///
/// Environment variables:
///   MDICT_TEST_FILE   - Path to .mdx file (optional; defaults to Tests/Fixtures/tiny.mdx)
///   MDICT_TEST_WORD   - Specific word to test lookup (optional)
///   MDICT_TEST_SAMPLE - Number of entries to sample for testing, default 5 (optional)
@Suite(.serialized)
struct MDictReaderTests {
    
    // MARK: - Test Configuration
    
    static var sampleSize: Int {
        if let val = ProcessInfo.processInfo.environment["MDICT_TEST_SAMPLE"],
           let n = Int(val), n > 0 {
            return n
        }
        return 5
    }
    
    static var testWord: String? {
        ProcessInfo.processInfo.environment["MDICT_TEST_WORD"]
    }
    
    // Shared reader instance.
    //
    // `nonisolated(unsafe)` is the correct escape hatch for Swift 6 strict
    // concurrency here: the enclosing `@Suite(.serialized)` already
    // guarantees these tests run sequentially, so there is no actual data
    // race on this lazy-init fixture.
    nonisolated(unsafe) static var _reader: MDictReader?
    nonisolated(unsafe) static var _initialized = false

    static var reader: MDictReader? {
        if !_initialized {
            _initialized = true
            let path = TestFixtures.mdxPath
            do {
                _reader = try MDictReader(path: path)
                let title = _reader!.metadata.title ?? "(untitled)"
                print("✅ [MDictReader] Loaded: \(title)")
                print("   Entries: \(_reader!.entryCount), Resources: \(_reader!.resourceCount)")
            } catch {
                print("❌ [MDictReader] Failed: \(error)")
            }
        }
        return _reader
    }
    
    // MARK: - Facade API Tests
    
    @Test("Facade provides dictionary metadata")
    func facadeMetadata() throws {
        let reader = try #require(Self.reader)

        // `title` is Optional — either there is no title at all (some
        // MDX files ship a placeholder) or there is a non-empty one.
        if let title = reader.metadata.title {
            #expect(!title.isEmpty)
        }
        #expect(reader.entryCount > 0)
    }
    
    @Test("Static metadata loading (fast)")
    func staticMetadataLoading() throws {
        let reader = try #require(Self.reader)
        
        // Load metadata without full parse
        let metadata = MDictReader.loadMetadata(from: reader.metadata.path)
        #expect(metadata != nil)
        #expect(metadata?.title == reader.metadata.title)
    }
    
    @Test("Facade lookup returns MDictWordEntry")
    func facadeLookup() throws {
        let reader = try #require(Self.reader)
        
        // Use specified word or first entry
        let testWord = Self.testWord ?? reader[0]?.key
        let word = try #require(testWord)
        
        let entry = reader.lookup(word)
        #expect(entry != nil, "Should find '\(word)'")
        #expect(entry?.key.lowercased() == word.lowercased())
        #expect(entry?.article.html.isEmpty == false)
    }
    
    @Test("Facade subscript works")
    func facadeSubscript() throws {
        let reader = try #require(Self.reader)
        
        let first = reader[0]
        #expect(first != nil)
        #expect(!first!.key.isEmpty)
        
        let last = reader[reader.entryCount - 1]
        #expect(last != nil)
    }
    
    @Test("Facade search returns word keys")
    func facadeSearch() throws {
        let reader = try #require(Self.reader)
        
        // Use prefix from test word or first entry
        let word = Self.testWord ?? reader[0]?.key ?? "a"
        let prefix = String(word.prefix(2))
        
        let results: [MDictWordKey] = reader.search(prefix: prefix, limit: 10)
        #expect(results.count <= 10)
    }
    
    // MARK: - MDX + MDD Integration Tests
    
    @Test("Resource count reflects MDD status")
    func resourceCount() throws {
        let reader = try #require(Self.reader)
        
        #expect(reader.resourceCount >= 0)
        
        if reader.resourceCount > 0 {
            #expect(!reader.allResourcePaths.isEmpty)
        }
    }
    
    @Test("Definition references resources")
    func definitionReferencesResources() throws {
        let reader = try #require(Self.reader)
        let firstEntry = try #require(reader[0])
        
        let html = firstEntry.article.html
        let hasResourceRef = html.contains("href=") || 
                            html.contains("src=") ||
                            html.contains(".css")
        
        if hasResourceRef && reader.resourceCount > 0 {
            if let cssMatch = html.range(of: #"href="([^"]+\.css)""#, options: .regularExpression) {
                let cssPath = String(html[cssMatch]).replacingOccurrences(of: "href=\"", with: "").replacingOccurrences(of: "\"", with: "")
                let cssData = reader.resource(for: cssPath)
                if cssData != nil {
                    #expect(cssData!.count > 0, "CSS resource should have content")
                }
            }
        }
    }
    
    @Test("Resource lookup via facade")
    func resourceLookup() throws {
        let reader = try #require(Self.reader)
        
        guard reader.resourceCount > 0 else {
            print("ℹ️ No MDD resources, skipping")
            return
        }
        
        let firstPath = reader.allResourcePaths.first!
        let data = reader.resource(for: firstPath)
        
        #expect(data != nil, "Should load resource: \(firstPath)")
        #expect(data!.count > 0)
    }
    
    @Test("Resource string convenience")
    func resourceString() throws {
        let reader = try #require(Self.reader)
        
        guard reader.resourceCount > 0 else {
            print("ℹ️ No MDD resources, skipping")
            return
        }
        
        let cssPaths = reader.allResourcePaths.filter { $0.lowercased().hasSuffix(".css") }
        
        if let cssPath = cssPaths.first {
            let cssString = reader.resourceString(for: cssPath)
            #expect(cssString != nil)
            #expect(cssString?.contains("{") == true, "CSS should have style rules")
        }
    }
    
    @Test("hasResource check")
    func hasResourceCheck() throws {
        let reader = try #require(Self.reader)
        
        #expect(!reader.hasResource("nonexistent_file_12345.xyz"))
        
        if let firstPath = reader.allResourcePaths.first {
            #expect(reader.hasResource(firstPath))
        }
    }
    
    // MARK: - Navigation Tests
    
    @Test("Navigation via subscript")
    func navigationViaSubscript() throws {
        let reader = try #require(Self.reader)
        
        // Use test word or middle entry
        let entry: MDictWordEntry?
        if let word = Self.testWord {
            entry = reader.lookup(word)
        } else {
            entry = reader[reader.entryCount / 2]
        }
        let testEntry = try #require(entry)
        
        let nextIndex = testEntry.index + 1
        if nextIndex < reader.entryCount {
            let next = reader[nextIndex]
            #expect(next != nil)
            #expect(!next!.article.html.isEmpty)
        }
        
        let prevIndex = testEntry.index - 1
        if prevIndex >= 0 {
            let prev = reader[prevIndex]
            #expect(prev != nil)
            #expect(!prev!.article.html.isEmpty)
        }
    }
    
    @Test("Entry index is internal but usable for navigation")
    func entryIndexNavigation() throws {
        let reader = try #require(Self.reader)
        
        let first = reader[0]
        #expect(first != nil)
        
        let second = reader[first!.index + 1]
        #expect(second != nil)
        #expect(second?.key != first?.key)
    }
}
