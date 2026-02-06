//
//  MDictDescriptionParser.swift
//  OpenMDict
//
//  Utilities for parsing and cleaning MDict description HTML.
//  Used by both CLI and GUI.
//
//  Architecture:
//  - These are "best effort" extraction methods that may return nil
//  - Core API (MDictReader.resolveTitle) provides safe fallbacks
//  - UI layer can use these to suggest better display names
//

import Foundation

/// Utilities for parsing MDict description HTML
public enum MDictDescriptionParser {
    
    // MARK: - Title Extraction
    
    /// Try to extract a meaningful title from description HTML.
    /// Useful when MDX title is a placeholder.
    ///
    /// Strategy: Look for title in structural elements (h1, first large font, first paragraph)
    /// Stop at boundary markers like "By", "Thanks", dates, entry counts
    ///
    /// - Parameter html: Raw description HTML from MDX header
    /// - Returns: Extracted title, or nil if extraction fails or result looks invalid
    public static func tryExtractTitle(from html: String) -> String? {
        guard !html.isEmpty else { return nil }
        
        // Strategy 1: Look for <h1> content (most reliable)
        if let h1Content = extractFirstTagContent(from: html, tag: "h1") {
            let cleaned = stripInlineTags(h1Content)
            if isValidTitle(cleaned) {
                return cleaned
            }
        }
        
        // Strategy 2: Look for <strong> with nested content (as some dictionary headers use)
        if let strongContent = extractFirstTagContent(from: html, tag: "strong") {
            let cleaned = stripInlineTags(strongContent)
            if isValidTitle(cleaned) {
                return cleaned
            }
        }

        // Strategy 2b: Look for styled span with large font-size
        if let styledSpan = extractLargeFontSizeSpan(from: html) {
            if isValidTitle(styledSpan) {
                return styledSpan
            }
        }

        // Strategy 3: Look for first large font tag (size >= 5)
        if let largeFont = extractLargeFontContent(from: html) {
            let cleaned = stripInlineTags(largeFont)
            if isValidTitle(cleaned) {
                return cleaned
            }
        }
        
        // Strategy 4: Look for first <p> content, but stop at boundaries
        if let firstP = extractFirstTagContent(from: html, tag: "p") {
            // Check if this paragraph contains ONLY title-like content
            let cleaned = stripInlineTags(firstP)
            let truncated = truncateAtBoundary(cleaned)
            if isValidTitle(truncated) {
                return truncated
            }
        }
        
        // Strategy 5: First non-empty line after stripping, with boundary detection
        let stripped = stripAllHTML(html)
        let firstLine = stripped.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        
        if let line = firstLine {
            let truncated = truncateAtBoundary(line)
            if isValidTitle(truncated) {
                return truncated
            }
        }
        
        return nil
    }
    
    // MARK: - Description Cleaning
    
    /// Clean description by removing HTML, scripts, styles, and redundant metadata.
    ///
    /// - Parameter html: Raw description HTML from MDX header
    /// - Returns: Cleaned plain text description (may be empty)
    public static func cleanDescription(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        
        var text = html
        
        // Remove <style> and <script> blocks entirely (including content across newlines)
        if let styleRegex = try? NSRegularExpression(
            pattern: "<style[^>]*>.*?</style>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            text = styleRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if let scriptRegex = try? NSRegularExpression(
            pattern: "<script[^>]*>.*?</script>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            text = scriptRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        
        // Strip HTML and normalize
        text = stripAllHTML(text)
        text = removeMetadataPatterns(from: text)
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Clean HTML for display, preserving formatting tags but removing dangerous/useless ones.
    /// Suitable for rendering with NSAttributedString.
    ///
    /// - Parameter html: Raw description HTML from MDX header
    /// - Returns: Cleaned HTML with basic formatting preserved
    public static func cleanHTMLForDisplay(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        
        var text = html
        
        // Remove <style> blocks entirely
        if let styleRegex = try? NSRegularExpression(
            pattern: "<style[^>]*>.*?</style>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            text = styleRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        
        // Remove <script> blocks entirely
        if let scriptRegex = try? NSRegularExpression(
            pattern: "<script[^>]*>.*?</script>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            text = scriptRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        
        // Remove <link> tags (CSS imports)
        if let linkRegex = try? NSRegularExpression(
            pattern: "<link[^>]*>",
            options: .caseInsensitive
        ) {
            text = linkRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        
        // Remove <meta> tags
        if let metaRegex = try? NSRegularExpression(
            pattern: "<meta[^>]*>",
            options: .caseInsensitive
        ) {
            text = metaRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        
        // Normalize whitespace (collapse multiple spaces/newlines)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Try to extract author/creator from description.
    ///
    /// - Parameter html: Raw description HTML
    /// - Returns: Author name, or nil if not found
    public static func tryExtractAuthor(from html: String) -> String? {
        // Strategy 1: Look for "By xxx" in its own paragraph/tag
        // This is more reliable than searching in full text
        
        // Find <p> or <font> containing "By "
        let byPatterns: [(String, Int)] = [
            // "By" at start of element content
            (#"<(?:p|font|span)[^>]*>\s*(?:<[^>]+>)*\s*[Bb]y\s+([\w\-]+)"#, 1),
            // "制作人：xxx" / "制作：xxx" pattern
            (#"制\s*作\s*人\s*[：:]\s*([\w\u4e00-\u9fff]+)"#, 1),
            (#"制\s*作\s*[：:]\s*([\w\u4e00-\u9fff]+)"#, 1),
            // "Converted by xxx"
            (#"[Cc]onverted\s+by\s+(?:<[^>]+>\s*)*(\w+)"#, 1),
            // "Modified by xxx"
            (#"[Mm]odified\s+by\s+(?:<[^>]+>\s*)*(\w+)"#, 1),
        ]
        
        for (pattern, groupIndex) in byPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges > groupIndex,
               let range = Range(match.range(at: groupIndex), in: html) {
                let author = String(html[range]).trimmingCharacters(in: .whitespaces)
                // Validate: should be a name, not common words
                if isValidAuthorName(author) {
                    return author
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Private: HTML Extraction
    
    /// Extract content from first occurrence of a tag
    private static func extractFirstTagContent(from html: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        
        return String(html[range])
    }
    
    /// Extract content from span with large font-size in style attribute
    private static func extractLargeFontSizeSpan(from html: String) -> String? {
        // Match <span style="...font-size:Npx/em/pt...">content</span> where N >= 16
        let pattern = #"<span[^>]*style\s*=\s*"[^"]*font-size\s*:\s*(\d+)(?:px|pt|em)?[^"]*"[^>]*>(.*?)</span>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }

        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 2,
              let sizeRange = Range(match.range(at: 1), in: html),
              let contentRange = Range(match.range(at: 2), in: html),
              let size = Int(html[sizeRange]), size >= 16 else { return nil }

        return stripInlineTags(String(html[contentRange]))
    }

    /// Extract content from first large font tag (size >= 5)
    private static func extractLargeFontContent(from html: String) -> String? {
        // Match <font size=N> where N >= 5
        let pattern = #"<font[^>]*\bsize\s*=\s*"?([5-9]|\d{2,})"?[^>]*>(.*?)</font>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 2,
              let range = Range(match.range(at: 2), in: html) else {
            return nil
        }
        
        return String(html[range])
    }
    
    /// Strip inline formatting tags but preserve text
    private static func stripInlineTags(_ html: String) -> String {
        var text = html
        
        // Replace <br> with space (in title context, <br> is visual line-break, not paragraph)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        
        // Remove inline tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Strip all HTML and normalize
    private static func stripAllHTML(_ html: String) -> String {
        var text = html
        
        // 1. Normalize line endings (CRLF -> LF)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        
        // 2. Remove inline tags first (they don't affect text flow)
        // Note: <c> is a custom inline tag used in some dictionaries
        let inlineTags = "font|span|a|b|i|strong|em|u|s|strike|sub|sup|small|big|img|mark|code|tt|c"
        text = text.replacingOccurrences(
            of: "</?(?:\(inlineTags))\\b[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // 3. Handle <br> contextually:
        //    - <br> followed by newline (formatting br) -> single space
        //    - <br> not followed by newline (semantic br) -> newline
        text = text.replacingOccurrences(of: "<br\\s*/?>\n", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        
        // 4. Replace <hr> with newline
        text = text.replacingOccurrences(of: "<hr\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        
        // 5. Replace closing block elements with newline
        text = text.replacingOccurrences(
            of: "</(?:p|div|h[1-6]|blockquote|li|tr|td|th|table|section|article|header|footer)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // 6. Remove all remaining tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        
        // 7. Decode HTML entities
        text = decodeHTMLEntities(text)
        
        // 8. Normalize horizontal whitespace (preserve newlines)
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        
        // 9. Normalize multiple newlines to max 2
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        
        // 10. Trim each line
        text = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Private: Boundary Detection
    
    /// Truncate text at common boundary markers
    private static func truncateAtBoundary(_ text: String) -> String {
        // Boundary patterns that indicate end of title
        let boundaries: [String] = [
            #"\s+[Bb]y\s+"#,                    // "By author"
            #"\s+[Tt]hanks\s+"#,                // "Thanks to..."
            #"\s+[Ll]atest\s+update"#,          // "Latest update:..."
            #"\s+[Vv]ersion\s*[:\d]"#,          // "Version 1.0"
            #"\s+\d+\s*entries"#,               // "12345 entries"
            #"\s+\d{4}[-./]\d+"#,               // Date patterns
            #"\s+[Cc]onverted\s+"#,             // "Converted by..."
            #"\s+[Mm]odified\s+"#,              // "Modified by..."
            #"\s+制\s*作"#,                      // Chinese "制作人"
            #"\s+词\s*条"#,                      // Chinese "词条数"
        ]
        
        var result = text
        for pattern in boundaries {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
               let range = Range(match.range, in: result) {
                result = String(result[..<range.lowerBound])
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Private: Validation
    
    /// Check if extracted text looks like a valid title
    private static func isValidTitle(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Too short or too long
        guard trimmed.count >= 3 && trimmed.count <= 150 else { return false }
        
        // Looks like garbage (CSS, code, single word placeholder)
        let invalidPatterns = [
            #"^\s*faq-?\w*\s*$"#,           // "faq-index" etc
            #"^\{.*\}$"#,                    // JSON/CSS block
            #"^\s*\d+\s*$"#,                 // Just numbers
            #"font-size|padding|margin"#,   // CSS properties
            #"^[a-z\-]+$"#,                  // Single lowercase word (like "index")
        ]
        
        for pattern in invalidPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                return false
            }
        }
        
        return true
    }
    
    /// Check if text looks like a valid author name
    private static func isValidAuthorName(_ name: String) -> Bool {
        // Should be reasonable length
        guard name.count >= 2 && name.count <= 30 else { return false }
        
        // Should not be common English words
        let commonWords = Set([
            "the", "and", "for", "from", "with", "this", "that", "have", "has",
            "been", "were", "was", "are", "which", "their", "other", "some",
            "evidence", "shown", "made", "html", "version", "dictionary", "dict"
        ])
        
        return !commonWords.contains(name.lowercased())
    }
    
    /// Remove metadata patterns from text
    private static func removeMetadataPatterns(from text: String) -> String {
        var result = text
        
        let patterns: [String] = [
            #"Headwords\s*:\s*\d+"#,
            #"Entries\s*:\s*\d+"#,
            #"Version\s*:\s*[\d.]+"#,
            #"Date\s*:\s*[\d.\-/]+"#,
            #"词\s*条\s*数\s*[：:]\s*\d+"#,
            #"制作日期\s*[：:]\s*\d+"#,
            #"\d+\s*/\s*\d+"#,              // "2889/2881" pattern
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        
        // Normalize horizontal whitespace only (preserve newlines)
        result = result.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        // Normalize multiple newlines
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Decode common HTML entities
    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&copy;", "©"),
            ("&reg;", "®"),
        ]
        
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        
        // Handle numeric entities like &#123;
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result),
                   let numRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[numRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }
        
        return result
    }
}
