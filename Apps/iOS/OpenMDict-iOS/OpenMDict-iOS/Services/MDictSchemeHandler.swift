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
        
        // Load resource from MDD
        // Try multiple path variations (MDD paths can be inconsistent)
        let pathsToTry = [
            resourcePath,                           // /1.png
            String(resourcePath.dropFirst()),       // 1.png (without leading /)
            "\\" + String(resourcePath.dropFirst()) // \1.png (MDD format)
        ]
        
        var resourceData: Data?
        for path in pathsToTry {
            if let data = dict.resource(for: path) {
                resourceData = data
                break
            }
        }
        
        guard let data = resourceData else {
            print("⚠️ MDictSchemeHandler: Resource not found: \(resourcePath) in \(dictId)")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
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
    
    /// Rewrite resource paths in HTML to use mdict:// scheme
    /// - Parameters:
    ///   - html: Original HTML content
    ///   - dictId: Dictionary ID for constructing URLs
    /// - Returns: HTML with rewritten resource paths
    static func rewriteResourcePaths(in html: String, dictId: String) -> String {
        var result = html
        
        // Patterns to match: src="...", href="...", url(...)
        let patterns: [(pattern: String, groupIndex: Int)] = [
            (#"(src\s*=\s*")([^"]+)(")"#, 2),
            (#"(href\s*=\s*")([^"]+)(")"#, 2),
            (#"(url\s*\(\s*'?)([^')]+)('?\s*\))"#, 2)
        ]
        
        for (pattern, groupIndex) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            
            // Process matches in reverse order to preserve indices
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range).reversed()
            
            for match in matches {
                guard let fullRange = Range(match.range, in: result),
                      let pathRange = Range(match.range(at: groupIndex), in: result) else {
                    continue
                }
                
                let path = String(result[pathRange])
                
                // Skip if already has scheme, is anchor, or is special link
                if path.hasPrefix("http://") || path.hasPrefix("https://") ||
                   path.hasPrefix("mdict://") || path.hasPrefix("data:") ||
                   path.hasPrefix("#") || path.hasPrefix("entry://") ||
                   path.hasPrefix("sound://") || path.hasPrefix("javascript:") {
                    continue
                }
                
                // Construct mdict:// URL
                let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
                let mdictURL = "mdict://\(dictId)\(cleanPath)"
                
                // Reconstruct the full match with new URL
                let prefix = String(result[Range(match.range(at: 1), in: result)!])
                let suffix = String(result[Range(match.range(at: 3), in: result)!])
                let replacement = "\(prefix)\(mdictURL)\(suffix)"
                
                result.replaceSubrange(fullRange, with: replacement)
            }
        }
        
        return result
    }
}
