//
//  HTMLResourceRewriter.swift
//  OpenMDict-iOS
//
//  Rewrites resource paths in HTML to use the mdict:// custom URL scheme.
//  Shared between main app (MDictSchemeHandler) and Action Extension.
//

import Foundation

/// Rewrites resource paths in HTML to use mdict:// scheme for WKWebView loading.
nonisolated enum HTMLResourceRewriter {

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

    // MARK: - Resource Path Extraction

    /// Schemes and prefixes to skip (same list as rewriteResourcePaths)
    private static let skippedPrefixes = [
        "http://", "https://", "mdict://", "data:",
        "#", "entry://", "sound://", "javascript:"
    ]

    /// Extract all relative resource paths referenced in HTML.
    /// Inverse of `rewriteResourcePaths`: uses the same regex patterns and skip list,
    /// but collects paths instead of rewriting them.
    /// - Parameter html: Original HTML content (before rewriting)
    /// - Returns: Deduplicated set of relative resource paths
    static func extractResourcePaths(from html: String) -> Set<String> {
        var paths = Set<String>()

        let patterns: [(pattern: String, groupIndex: Int)] = [
            (#"(src\s*=\s*")([^"]+)(")"#, 2),
            (#"(href\s*=\s*")([^"]+)(")"#, 2),
            (#"(url\s*\(\s*'?)([^')]+)('?\s*\))"#, 2)
        ]

        for (pattern, groupIndex) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, range: range)

            for match in matches {
                guard let pathRange = Range(match.range(at: groupIndex), in: html) else {
                    continue
                }

                let path = String(html[pathRange])

                // Skip paths that already have a scheme or are special
                if skippedPrefixes.contains(where: { path.hasPrefix($0) }) {
                    continue
                }

                paths.insert(path)
            }
        }

        return paths
    }
}
