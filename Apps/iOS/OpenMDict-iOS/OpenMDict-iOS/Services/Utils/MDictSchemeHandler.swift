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

        // 1. Try MDD with multiple path variations
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

        // 3. Check Library/Dictionaries/{id}/css/ or js/ directory
        if resourceData == nil {
            let storage = DictionaryStorageService.shared
            var directoryURL: URL?

            switch fileExtension {
            case "css":
                directoryURL = storage.cssDirectoryURL(id: dictId)
            case "js":
                directoryURL = storage.jsDirectoryURL(id: dictId)
            default:
                break
            }

            if let dirURL = directoryURL {
                // Try exact match first
                let exactURL = dirURL.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: exactURL.path) {
                    resourceData = try? Data(contentsOf: exactURL)
                    if resourceData != nil {
                        print("📄 MDictSchemeHandler: Loaded from storage [\(fileExtension)]: \(filename)")
                    }
                }

                // Try case-insensitive match
                if resourceData == nil,
                   let contents = try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
                    let lowercasedFilename = filename.lowercased()
                    for fileURL in contents {
                        if fileURL.lastPathComponent.lowercased() == lowercasedFilename {
                            resourceData = try? Data(contentsOf: fileURL)
                            if resourceData != nil {
                                print("📄 MDictSchemeHandler: Loaded from storage (case-insensitive) [\(fileExtension)]: \(fileURL.lastPathComponent)")
                                break
                            }
                        }
                    }
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
