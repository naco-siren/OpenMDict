//
//  ActionExtensionSchemeHandler.swift
//  OpenMDict-ActionExtension
//
//  Lightweight WKURLSchemeHandler for the Action Extension.
//  Serves resources from disk: dictionary directory, MDD cache, and css/js subdirs.
//  MDD resources are pre-extracted by MDDResourceExtractor during the scan loop.
//
//  URL format: mdict://dictId/path/to/resource
//

import WebKit

final class ActionExtensionSchemeHandler: NSObject, WKURLSchemeHandler {

    nonisolated static let scheme = "mdict"

    /// Root URL for dictionary storage in the App Group container.
    private let dictionariesRoot: URL

    /// Root URL for MDD resource cache: AppGroup/Library/Caches/MDD/
    private let mddCacheRoot: URL

    init(dictionariesRoot: URL, mddCacheRoot: URL) {
        self.dictionariesRoot = dictionariesRoot
        self.mddCacheRoot = mddCacheRoot
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == Self.scheme else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        guard let dictId = url.host, !dictId.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let resourcePath = url.path  // e.g., "/1.png" or "/css/style.css"

        // Load resource data
        var resourceData: Data?
        let filename = String(resourcePath.dropFirst()) // Remove leading /
        let fileExtension = (filename as NSString).pathExtension.lowercased()

        // 1. Check dictionary directory on disk (e.g., extracted files at root level)
        if resourceData == nil {
            let dictDir = dictionariesRoot.appendingPathComponent(dictId)
            let filePath = dictDir.appendingPathComponent(filename).path

            if FileManager.default.fileExists(atPath: filePath) {
                resourceData = try? Data(contentsOf: URL(fileURLWithPath: filePath))
                if resourceData != nil {
                    print("🌐 scheme[\(dictId)] HIT tier1 (dictDir): '\(filename)'")
                }
            }
        }

        // 2. Check MDD cache (resources extracted during scan by MDDResourceExtractor)
        if resourceData == nil {
            let cachedPath = mddCacheRoot
                .appendingPathComponent(dictId)
                .appendingPathComponent(filename).path
            if FileManager.default.fileExists(atPath: cachedPath) {
                resourceData = try? Data(contentsOf: URL(fileURLWithPath: cachedPath))
                if resourceData != nil {
                    print("🌐 scheme[\(dictId)] HIT tier2 (cache): '\(filename)'")
                }
            }
        }

        // 3. Check css/ or js/ subdirectory with case-insensitive matching
        if resourceData == nil {
            let dictDir = dictionariesRoot.appendingPathComponent(dictId)
            var subDirURL: URL?

            switch fileExtension {
            case "css":
                subDirURL = dictDir.appendingPathComponent("css", isDirectory: true)
            case "js":
                subDirURL = dictDir.appendingPathComponent("js", isDirectory: true)
            default:
                break
            }

            if let dirURL = subDirURL {
                // Exact match
                let exactURL = dirURL.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: exactURL.path) {
                    resourceData = try? Data(contentsOf: exactURL)
                }

                // Case-insensitive fallback
                if resourceData == nil,
                   let contents = try? FileManager.default.contentsOfDirectory(
                    at: dirURL, includingPropertiesForKeys: nil
                   ) {
                    let lowercased = filename.lowercased()
                    for fileURL in contents {
                        if fileURL.lastPathComponent.lowercased() == lowercased {
                            resourceData = try? Data(contentsOf: fileURL)
                            break
                        }
                    }
                }
            }
        }

        guard var data = resourceData else {
            print("🌐 scheme[\(dictId)] MISS all tiers: '\(filename)'")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // For CSS, rewrite any `url(file://...)` font / image references
        // inside the file (e.g. `@font-face` directives) so they
        // route through this same mdict:// scheme handler.  See the main
        // app's MDictSchemeHandler for the matching write of this rewrite.
        if fileExtension == "css", let cssText = String(data: data, encoding: .utf8) {
            let rewritten = HTMLResourceRewriter.rewriteResourcePathsInCSS(cssText, dictId: dictId)
            if let rewrittenData = rewritten.data(using: .utf8) {
                data = rewrittenData
            }
        }

        // Determine MIME type
        let mimeType = Self.mimeType(for: resourcePath)

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

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to cancel — we complete synchronously
    }

    // MARK: - MIME Type Detection

    private nonisolated static func mimeType(for path: String) -> String {
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
