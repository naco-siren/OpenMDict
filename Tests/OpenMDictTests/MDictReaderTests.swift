import Testing
import Foundation
@testable import OpenMDict

/// Integration tests for MDictReader (MDX + MDD combined)
/// Tests the facade API and resource integration
/// Run with: MDICT_TEST_FILE=path/to/dict.mdx swift test
@Suite(.serialized)
struct MDictReaderTests {
    
    // Shared reader instance
    static var _reader: MDictReader?
    static var _initialized = false
    
    static var reader: MDictReader? {
        if !_initialized {
            _initialized = true
            guard let path = ProcessInfo.processInfo.environment["MDICT_TEST_FILE"],
                  !path.isEmpty else {
                print("⚠️ Set MDICT_TEST_FILE environment variable to run tests")
                return nil
            }
            do {
                _reader = try MDictReader(path: path)
                print("✅ [MDictReader] Loaded: \(_reader!.metadata.title)")
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
        
        #expect(!reader.metadata.title.isEmpty)
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
        
        let entry = reader.lookup("hello")
        #expect(entry != nil)
        #expect(entry?.key.lowercased() == "hello")
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
        
        let results: [MDictWordKey] = reader.search(prefix: "test", limit: 10)
        // May or may not find results depending on dictionary
        #expect(results.count <= 10)
    }
    
    // MARK: - MDX + MDD Integration Tests
    
    @Test("Resource count reflects MDD status")
    func resourceCount() throws {
        let reader = try #require(Self.reader)
        
        // resourceCount should be >= 0
        // If MDD exists, should be > 0
        #expect(reader.resourceCount >= 0)
        
        if reader.resourceCount > 0 {
            #expect(!reader.allResourcePaths.isEmpty)
        }
    }
    
    @Test("Definition references resources")
    func definitionReferencesResources() throws {
        let reader = try #require(Self.reader)
        let entry = try #require(reader.lookup("hello"))
        
        // Check if definition references CSS or images
        let html = entry.article.html
        let hasResourceRef = html.contains("href=") || 
                            html.contains("src=") ||
                            html.contains(".css")
        
        if hasResourceRef && reader.resourceCount > 0 {
            // Extract a referenced resource and try to load it
            if let cssMatch = html.range(of: #"href="([^"]+\.css)""#, options: .regularExpression) {
                let cssPath = String(html[cssMatch]).replacingOccurrences(of: "href=\"", with: "").replacingOccurrences(of: "\"", with: "")
                let cssData = reader.resource(for: cssPath)
                // Resource may or may not exist in MDD
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
        
        // Try to get first resource
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
        
        // Find a CSS file
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
        
        // Non-existent resource
        #expect(!reader.hasResource("nonexistent_file_12345.xyz"))
        
        // Existing resource (if MDD loaded)
        if let firstPath = reader.allResourcePaths.first {
            #expect(reader.hasResource(firstPath))
        }
    }
    
    // MARK: - Navigation Tests
    
    @Test("Navigation via subscript")
    func navigationViaSubscript() throws {
        let reader = try #require(Self.reader)
        let entry = try #require(reader.lookup("hello"))
        
        // Navigate using index
        let nextIndex = entry.index + 1
        if nextIndex < reader.entryCount {
            let next = reader[nextIndex]
            #expect(next != nil)
            #expect(!next!.article.html.isEmpty)
        }
        
        let prevIndex = entry.index - 1
        if prevIndex >= 0 {
            let prev = reader[prevIndex]
            #expect(prev != nil)
            #expect(!prev!.article.html.isEmpty)
        }
    }
    
    @Test("Entry index is internal but usable for navigation")
    func entryIndexNavigation() throws {
        let reader = try #require(Self.reader)
        
        // Get first entry
        let first = reader[0]
        #expect(first != nil)
        
        // Get second via first's index
        let second = reader[first!.index + 1]
        #expect(second != nil)
        #expect(second?.key != first?.key)
    }
}
