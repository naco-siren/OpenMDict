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
                print("✅ [MDictReader] Loaded: \(_reader!.info.title)")
                print("   Entries: \(_reader!.info.entryCount), Resources: \(_reader!.resourceCount)")
            } catch {
                print("❌ [MDictReader] Failed: \(error)")
            }
        }
        return _reader
    }
    
    // MARK: - Facade API Tests
    
    @Test("Facade provides dictionary info")
    func facadeInfo() throws {
        let reader = try #require(Self.reader)
        
        #expect(!reader.info.title.isEmpty)
        #expect(reader.info.entryCount > 0)
    }
    
    @Test("Facade lookup delegates to MDXParser")
    func facadeLookup() throws {
        let reader = try #require(Self.reader)
        
        let entry = reader.lookup("hello")
        #expect(entry != nil)
        #expect(entry?.definition.isEmpty == false)
    }
    
    @Test("Facade subscript works")
    func facadeSubscript() throws {
        let reader = try #require(Self.reader)
        
        let first = reader[0]
        #expect(first != nil)
        
        let last = reader[reader.info.entryCount - 1]
        #expect(last != nil)
    }
    
    @Test("Facade search works")
    func facadeSearch() throws {
        let reader = try #require(Self.reader)
        
        let results = reader.search(prefix: "test", limit: 10)
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
        let definition = entry.definition
        let hasResourceRef = definition.contains("href=") || 
                            definition.contains("src=") ||
                            definition.contains(".css")
        
        if hasResourceRef && reader.resourceCount > 0 {
            // Extract a referenced resource and try to load it
            if let cssMatch = definition.range(of: #"href="([^"]+\.css)""#, options: .regularExpression) {
                let cssPath = String(definition[cssMatch]).replacingOccurrences(of: "href=\"", with: "").replacingOccurrences(of: "\"", with: "")
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
    
    // MARK: - Navigation Integration
    
    @Test("Entry navigation works through facade")
    func navigationIntegration() throws {
        let reader = try #require(Self.reader)
        let entry = try #require(reader.lookup("hello"))
        
        // Navigate and verify we can still access resources
        if let next = entry.next {
            #expect(!next.definition.isEmpty)
        }
        
        if let prev = entry.prev {
            #expect(!prev.definition.isEmpty)
        }
    }
}
