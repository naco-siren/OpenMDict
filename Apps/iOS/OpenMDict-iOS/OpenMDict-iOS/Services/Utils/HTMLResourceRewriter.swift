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

        // Patterns to match: src="...", <a>/<link> href="...", url(...)
        // Note: href is restricted to <a> and <link> tags to avoid matching
        // non-standard href on <span> etc. (e.g. MDict cross-reference metadata).
        let patterns: [(pattern: String, groupIndex: Int)] = [
            (#"(src\s*=\s*")([^"]+)(")"#, 2),
            (#"(<(?:a|link)\b[^>]*?href\s*=\s*")([^"]+)(")"#, 2),
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

                // Some MDX dicts write resource refs as
                // `file://\filename.css` — Windows-style absolute path with
                // the `file://` scheme.  WKWebView refuses to load `file://`
                // from an `mdict://` origin, AND treating it as a literal
                // relative path produces gibberish like `mdict://<id>/file://...`.
                // Normalize to a forward-slash relative path so the rewrite
                // below produces a real mdict:// URL the scheme handler can
                // resolve.
                let normalizedPath = normalizeResourcePath(path)

                // Construct mdict:// URL (percent-encode path for valid URL)
                let cleanPath = normalizedPath.hasPrefix("/") ? normalizedPath : "/\(normalizedPath)"
                let encodedPath = cleanPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanPath
                let mdictURL = "mdict://\(dictId)\(encodedPath)"

                // Reconstruct the full match with new URL
                let prefix = String(result[Range(match.range(at: 1), in: result)!])
                let suffix = String(result[Range(match.range(at: 3), in: result)!])
                let replacement = "\(prefix)\(mdictURL)\(suffix)"

                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        return result
    }

    /// Pre-percent-encode non-ASCII chars inside `<a href="entry://...">`
    /// cross-reference URLs.  Workaround for an iOS WKWebView bug: when
    /// constructing a URL request from a `<a>` click for a **custom URL
    /// scheme** (anything other than http/https/file), WebKit takes the
    /// UTF-8 bytes of non-ASCII chars in the href and re-encodes them as
    /// if they were Latin-1.  Middle-dot homograph disambiguators show this
    /// dramatically: `entry://bank · n.` (DOM string with U+00B7 = UTF-8
    /// `C2 B7`) becomes URL `entry://bank%20%C3%82%C2%B7%20n.` — those four
    /// percent-bytes decode to `Â·`, not `·`.  Pre-encoding here gives
    /// WebKit pure ASCII it doesn't need to touch, so the URL round-trips
    /// cleanly through `request.url.absoluteString` →
    /// `removingPercentEncoding` (UTF-8) on the receiving side.
    ///
    /// Idempotent: existing `%XX` sequences are preserved (the encoder's
    /// allowed set includes `%`).  Fragment-aware: splits on the first
    /// `#` so the anchor delimiter survives and is not itself encoded.
    static func percentEncodeEntryLinks(in html: String) -> String {
        let pattern = #"(<a\b[^>]*?href\s*=\s*"entry://)([^"]+)(")"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        var result = html
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()

        var allowed = CharacterSet.urlPathAllowed
        allowed.insert("%")  // don't re-encode existing %XX sequences

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let prefixRange = Range(match.range(at: 1), in: result),
                  let pathRange = Range(match.range(at: 2), in: result),
                  let suffixRange = Range(match.range(at: 3), in: result) else {
                continue
            }
            let raw = String(result[pathRange])

            // Skip pure ASCII (no spaces, no non-ASCII) — nothing for WebKit
            // to mojibake, no encoding needed.
            let needsEncoding = raw.unicodeScalars.contains { $0.value > 0x7F || $0.value == 0x20 }
            guard needsEncoding else { continue }

            // Split on first `#` to encode word and fragment separately,
            // preserving the delimiter.
            let encoded: String = {
                if let hashIdx = raw.firstIndex(of: "#") {
                    let word = String(raw[..<hashIdx])
                    let frag = String(raw[raw.index(after: hashIdx)...])
                    let encWord = word.addingPercentEncoding(withAllowedCharacters: allowed) ?? word
                    let encFrag = frag.addingPercentEncoding(withAllowedCharacters: allowed) ?? frag
                    return "\(encWord)#\(encFrag)"
                }
                return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
            }()

            if encoded != raw {
                let prefix = String(result[prefixRange])
                let suffix = String(result[suffixRange])
                result.replaceSubrange(fullRange, with: "\(prefix)\(encoded)\(suffix)")
            }
        }
        return result
    }

    /// Rewrite resource paths inside a CSS file's text content to use the
    /// mdict:// scheme.  Only matches the `url(...)` pattern — `src=` and
    /// `<a>/<link>` are HTML-specific and don't appear in CSS.
    ///
    /// Needed because some dicts ship `@font-face { src: url("file://\X.ttf") }`
    /// inside their CSS.  Without this rewrite, even though the CSS itself
    /// loads via mdict://, the fonts referenced from it still fail with the
    /// same `file://`-vs-`mdict://` origin mismatch as the HTML stylesheet
    /// links did before HTML rewriting was added.
    static func rewriteResourcePathsInCSS(_ css: String, dictId: String) -> String {
        var result = css
        let pattern = #"(url\s*\(\s*'?)([^')]+)('?\s*\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return result
        }

        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let pathRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            let path = String(result[pathRange])
            if skippedPrefixes.contains(where: { path.hasPrefix($0) }) {
                continue
            }

            let normalizedPath = normalizeResourcePath(path)
            let cleanPath = normalizedPath.hasPrefix("/") ? normalizedPath : "/\(normalizedPath)"
            let encodedPath = cleanPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanPath
            let mdictURL = "mdict://\(dictId)\(encodedPath)"

            let prefix = String(result[Range(match.range(at: 1), in: result)!])
            let suffix = String(result[Range(match.range(at: 3), in: result)!])
            result.replaceSubrange(fullRange, with: "\(prefix)\(mdictURL)\(suffix)")
        }

        return result
    }

    // MARK: - Resource Path Extraction

    /// Schemes and prefixes to skip (same list as rewriteResourcePaths)
    private static let skippedPrefixes = [
        "http://", "https://", "mdict://", "data:",
        "#", "entry://", "sound://", "javascript:"
    ]

    /// MDX-specific path normalization.  Strips `file://` (used by some dicts
    /// with Windows backslashes as if it were a relative path) and
    /// flips backslashes to forward slashes so downstream callers get a
    /// uniform forward-slash relative path.  Other inputs are returned as-is.
    private static func normalizeResourcePath(_ path: String) -> String {
        guard path.lowercased().hasPrefix("file://") else { return path }
        let stripped = String(path.dropFirst("file://".count))
        return stripped.replacingOccurrences(of: "\\", with: "/")
    }

    /// Extract all relative resource paths referenced in HTML.
    /// Inverse of `rewriteResourcePaths`: uses the same regex patterns and skip list,
    /// but collects paths instead of rewriting them.
    /// - Parameter html: Original HTML content (before rewriting)
    /// - Returns: Deduplicated set of relative resource paths
    static func extractResourcePaths(from html: String) -> Set<String> {
        var paths = Set<String>()

        let patterns: [(pattern: String, groupIndex: Int)] = [
            (#"(src\s*=\s*")([^"]+)(")"#, 2),
            (#"(<(?:a|link)\b[^>]*?href\s*=\s*")([^"]+)(")"#, 2),
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

                // Normalize file://-prefixed Windows-style paths so callers
                // (e.g. Action Extension MDD preloader) match the same key
                // the rewriter produces.  See `rewriteResourcePaths` for the
                // `file://` example.
                paths.insert(normalizeResourcePath(path))
            }
        }

        return paths
    }
}
