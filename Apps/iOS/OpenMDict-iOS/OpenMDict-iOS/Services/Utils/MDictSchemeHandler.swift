//
//  MDictSchemeHandler.swift
//  OpenMDict-iOS
//
//  WKURLSchemeHandler for loading MDD resources (CSS, images, audio)
//  URL format: mdict://dictId/path/to/resource.css
//

import WebKit
import OpenMDictKit

final class MDictSchemeHandler: NSObject, WKURLSchemeHandler {
    
    static let scheme = "mdict"
    static let shared = MDictSchemeHandler()
    
    private override init() {
        super.init()
    }
    
    // MARK: - WKURLSchemeHandler
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == Self.scheme else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        
        // Parse URL: mdict://dictId/path/to/resource
        // host = dictId, path = /path/to/resource
        guard let dictId = url.host, !dictId.isEmpty else {
            print("⚠️ MDictSchemeHandler: Missing dictId in URL: \(url)")
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        
        let resourcePath = url.path  // e.g., "/1.png" or "/css/style.css"
        
        // Get dictionary from service
        guard let dict = DictionaryService.shared.dict(id: dictId) else {
            print("⚠️ MDictSchemeHandler: Dictionary not found: \(dictId)")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        
        // Load resource - try multiple sources in order
        // All dictionaries live in Library/Dictionaries/{sha256}/ (no bundled/imported distinction)
        var resourceData: Data?
        let filename = String(resourcePath.dropFirst()) // Remove leading /
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        let isStylesheetOrScript = (fileExtension == "css" || fileExtension == "js")

        // 0. CSS/JS ONLY: a loose file in the dict's css/ or js/ storage dir
        //    OVERRIDES the MDD-embedded copy.  This matches the GoldenDict /
        //    Eudic(欧路) convention: a dictionary ships loose .css/.js next to
        //    the .mdx/.mdd specifically to patch the resources baked into the
        //    (often huge) MDD without repacking it — "overhaul"/patch packages
        //    depend on this.  Images/audio keep MDD-first (steps 1–2 below);
        //    loose copies of those are rare and the MDD is the canonical source.
        if isStylesheetOrScript {
            resourceData = Self.loadFromStorageDir(dictId: dictId, filename: filename, fileExtension: fileExtension)
        }

        // 1. Try MDD with multiple path variations
        if resourceData == nil {
            let pathsToTry = [
                resourcePath,                           // /1.png
                String(resourcePath.dropFirst()),       // 1.png (without leading /)
                "\\" + String(resourcePath.dropFirst()) // \1.png (MDD format)
            ]

            for path in pathsToTry {
                if let data = dict.resource(for: path) {
                    resourceData = data
                    break
                }
            }
        }

        // 2. Fall back to dictionary directory (Library/Dictionaries/{id}/)
        if resourceData == nil, let dictPath = dict.metadata?.path {
            let dictDir = (dictPath as NSString).deletingLastPathComponent
            let filePath = (dictDir as NSString).appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: filePath) {
                resourceData = try? Data(contentsOf: URL(fileURLWithPath: filePath))
                if resourceData != nil {
                    print("📄 MDictSchemeHandler: Loaded from directory: \(filename)")
                }
            }
        }
        
        guard var data = resourceData else {
            print("⚠️ MDictSchemeHandler: Resource not found: \(resourcePath) in \(dictId)")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // For CSS, rewrite any `url(file://...)` font / image references inside
        // the file so they go through the same mdict:// scheme handler.  HTML
        // rewriting at load time only fixes `<link href="file://...">`; the
        // font URLs nested inside an MDX dict's CSS (e.g. `@font-face`)
        // need this second pass or they silently 404 against the mdict origin.
        if fileExtension == "css", let cssText = String(data: data, encoding: .utf8) {
            let rewritten = HTMLResourceRewriter.rewriteResourcePathsInCSS(cssText, dictId: dictId)
            if let rewrittenData = rewritten.data(using: .utf8) {
                data = rewrittenData
            }
        }

        // Determine MIME type
        let mimeType = Self.mimeType(for: resourcePath)

        // Create response
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to cancel - we complete synchronously
    }

    // MARK: - Loose CSS/JS Override

    /// Load a CSS/JS resource from the dictionary's `css/` or `js/` storage
    /// directory — the location loose .css/.js files are copied to at import.
    /// Tries an exact filename match first, then a case-insensitive match.
    /// Returns `nil` if the directory or file doesn't exist (caller then falls
    /// back to the MDD-embedded copy).
    private static func loadFromStorageDir(dictId: String, filename: String, fileExtension: String) -> Data? {
        let storage = DictionaryStorageService.shared
        let dirURL: URL
        switch fileExtension {
        case "css": dirURL = storage.cssDirectoryURL(id: dictId)
        case "js":  dirURL = storage.jsDirectoryURL(id: dictId)
        default:    return nil
        }

        // Exact match
        let exactURL = dirURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: exactURL.path),
           let data = try? Data(contentsOf: exactURL) {
            print("📄 MDictSchemeHandler: Loaded from storage [\(fileExtension)]: \(filename)")
            return data
        }

        // Case-insensitive match
        if let contents = try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
            let lowercasedFilename = filename.lowercased()
            for fileURL in contents where fileURL.lastPathComponent.lowercased() == lowercasedFilename {
                if let data = try? Data(contentsOf: fileURL) {
                    print("📄 MDictSchemeHandler: Loaded from storage (case-insensitive) [\(fileExtension)]: \(fileURL.lastPathComponent)")
                    return data
                }
            }
        }

        return nil
    }

    // MARK: - MIME Type Detection
    
    private static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "css":  return "text/css"
        case "js":   return "application/javascript"
        case "html", "htm": return "text/html"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "svg":  return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico":  return "image/x-icon"
        case "mp3":  return "audio/mpeg"
        case "wav":  return "audio/wav"
        case "ogg":  return "audio/ogg"
        case "spx":  return "audio/x-speex"
        case "ttf":  return "font/ttf"
        case "otf":  return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "json": return "application/json"
        case "xml":  return "application/xml"
        default:     return "application/octet-stream"
        }
    }
}

// MARK: - HTML Resource Path Rewriting

extension MDictSchemeHandler {

    /// Rewrite resource paths in HTML to use mdict:// scheme.
    /// Delegates to `HTMLResourceRewriter` (shared with Action Extension).
    static func rewriteResourcePaths(in html: String, dictId: String) -> String {
        HTMLResourceRewriter.rewriteResourcePaths(in: html, dictId: dictId)
    }
}
