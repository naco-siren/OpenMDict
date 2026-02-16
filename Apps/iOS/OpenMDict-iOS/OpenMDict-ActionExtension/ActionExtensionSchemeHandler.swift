//
//  ActionExtensionSchemeHandler.swift
//  OpenMDict-ActionExtension
//
//  Lightweight WKURLSchemeHandler for the Action Extension.
//  Loads MDD resources directly via MDictReader instances instead of
//  going through the main app's DictionaryService / DictionaryStorageService singletons.
//
//  URL format: mdict://dictId/path/to/resource
//

import WebKit
import OpenMDict

final class ActionExtensionSchemeHandler: NSObject, WKURLSchemeHandler {

    nonisolated static let scheme = "mdict"

    /// dictId → MDictReader mapping, injected at init time.
    private let readers: [String: MDictReader]

    /// Root URL for dictionary storage in the App Group container.
    private let dictionariesRoot: URL

    init(readers: [String: MDictReader], dictionariesRoot: URL) {
        self.readers = readers
        self.dictionariesRoot = dictionariesRoot
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

        // 1. Try MDD via MDictReader with multiple path variations
        if let reader = readers[dictId] {
            let pathsToTry = [
                resourcePath,                           // /1.png
                String(resourcePath.dropFirst()),       // 1.png (without leading /)
                "\\" + String(resourcePath.dropFirst()) // \1.png (MDD format)
            ]

            for path in pathsToTry {
                if let data = reader.resource(for: path) {
                    resourceData = data
                    break
                }
            }
        }

        // 2. Fall back to dictionary directory on disk
        if resourceData == nil {
            let dictDir = dictionariesRoot.appendingPathComponent(dictId)
            let filePath = dictDir.appendingPathComponent(filename).path

            if FileManager.default.fileExists(atPath: filePath) {
                resourceData = try? Data(contentsOf: URL(fileURLWithPath: filePath))
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

        guard let data = resourceData else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
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
