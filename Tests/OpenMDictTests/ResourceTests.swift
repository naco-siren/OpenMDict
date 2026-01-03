import Testing
import Foundation
@testable import OpenMDict

/// Tests for MDDParser and ResourceProvider
/// Run with: MDICT_TEST_FILE=path/to/dict.mdx swift test
@Suite(.serialized)
struct ResourceTests {
    
    static var mdxPath: String?
    static var resourceProvider: ResourceProvider?
    static var _initialized = false
    
    static func initialize() {
        guard !_initialized else { return }
        _initialized = true
        
        guard let path = ProcessInfo.processInfo.environment["MDICT_TEST_FILE"],
              !path.isEmpty else {
            print("⚠️ Set MDICT_TEST_FILE to test resources")
            return
        }
        
        mdxPath = path
        resourceProvider = ResourceProvider(mdxPath: path)
        
        if let rp = resourceProvider {
            print("✅ ResourceProvider loaded with \(rp.mddResourceCount) MDD resources")
        }
    }
    
    // MARK: - MDDParser Tests
    
    @Test("Load MDD file")
    func loadMDD() throws {
        Self.initialize()
        let path = try #require(Self.mdxPath, "No test file configured")
        
        // Construct MDD path from MDX path
        let mddPath = (path as NSString).deletingPathExtension + ".mdd"
        
        guard FileManager.default.fileExists(atPath: mddPath) else {
            print("ℹ️ No MDD file found at \(mddPath)")
            return
        }
        
        let mdd = try MDDParser(path: mddPath)
        #expect(mdd.resourceCount > 0, "MDD should have resources")
        print("✅ Loaded MDD with \(mdd.resourceCount) resources")
        
        // Print first few resources
        let sample = mdd.allPaths.prefix(5)
        for path in sample {
            print("  - \(path)")
        }
    }
    
    @Test("Lookup CSS resource")
    func lookupCSS() throws {
        Self.initialize()
        let rp = try #require(Self.resourceProvider, "ResourceProvider not initialized")
        
        // Try to find a CSS file
        let cssPaths = rp.allMDDPaths.filter { $0.lowercased().hasSuffix(".css") }
        
        if let cssPath = cssPaths.first {
            let data = rp.resource(for: cssPath)
            #expect(data != nil, "Should load CSS from MDD")
            
            if let css = rp.string(for: cssPath) {
                #expect(css.contains("{"), "CSS should contain style rules")
                print("✅ Loaded CSS (\(data?.count ?? 0) bytes): \(cssPath)")
            }
        } else {
            print("ℹ️ No CSS files in MDD")
        }
    }
    
    @Test("Lookup image resource")
    func lookupImage() throws {
        Self.initialize()
        let rp = try #require(Self.resourceProvider, "ResourceProvider not initialized")
        
        // Try to find an image
        let imageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".svg"]
        let imagePaths = rp.allMDDPaths.filter { path in
            imageExtensions.contains { path.lowercased().hasSuffix($0) }
        }
        
        if let imagePath = imagePaths.first {
            let data = rp.resource(for: imagePath)
            #expect(data != nil, "Should load image from MDD")
            #expect(data?.count ?? 0 > 0, "Image should have data")
            print("✅ Loaded image (\(data?.count ?? 0) bytes): \(imagePath)")
        } else {
            print("ℹ️ No image files in MDD")
        }
    }
    
    @Test("MIME type detection")
    func mimeTypes() {
        #expect(ResourceProvider.mimeType(for: "style.css") == "text/css")
        #expect(ResourceProvider.mimeType(for: "logo.png") == "image/png")
        #expect(ResourceProvider.mimeType(for: "sound.mp3") == "audio/mpeg")
        #expect(ResourceProvider.mimeType(for: "font.woff2") == "font/woff2")
        #expect(ResourceProvider.mimeType(for: "unknown.xyz") == "application/octet-stream")
    }
    
    @Test("Resource path normalization")
    func pathNormalization() throws {
        Self.initialize()
        guard let rp = Self.resourceProvider,
              let firstPath = rp.allMDDPaths.first else {
            print("ℹ️ No resources to test path normalization")
            return
        }
        
        // Try different path formats
        let variations = [
            firstPath,
            firstPath.uppercased(),
            firstPath.replacingOccurrences(of: "/", with: "\\"),
            "/" + firstPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        ]
        
        for variant in variations {
            let exists = rp.contains(variant)
            print("  Path '\(variant)': \(exists ? "✓" : "✗")")
        }
    }
    
    @Test("External file fallback")
    func externalFileFallback() throws {
        Self.initialize()
        let path = try #require(Self.mdxPath, "No test file configured")

        let baseDir = (path as NSString).deletingLastPathComponent
        let files = try? FileManager.default.contentsOfDirectory(atPath: baseDir)
        
        // Look for external CSS/resources
        let externalResources = files?.filter { file in
            let ext = (file as NSString).pathExtension.lowercased()
            return ["css", "js", "png", "jpg"].contains(ext) && !file.hasSuffix(".mdd")
        } ?? []
        
        if let externalFile = externalResources.first {
            let rp = ResourceProvider(mdxPath: path)
            let data = rp.resource(for: externalFile)
            #expect(data != nil, "Should load external file: \(externalFile)")
            print("✅ Loaded external file (\(data?.count ?? 0) bytes): \(externalFile)")
        } else {
            print("ℹ️ No external resource files found")
        }
    }
}
