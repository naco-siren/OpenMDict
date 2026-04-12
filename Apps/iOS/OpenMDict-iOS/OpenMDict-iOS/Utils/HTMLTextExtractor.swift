//
//  HTMLTextExtractor.swift
//  OpenMDict-iOS
//
//  Lightweight HTML → plain text for feeding MDX article content into the
//  Foundation Models context window. Regex-based, no WKWebView, no NSAttri-
//  butedString — runs synchronously off the main actor without pulling in
//  WebKit.
//
//  This is intentionally approximate. MDX articles can contain arbitrary
//  HTML, JS, and CSS; the goal here is to strip structural noise so the
//  language model sees the lexical content (headword, part-of-speech,
//  glosses, examples) rather than tag soup. A few garbled characters in
//  the output are acceptable — the model is robust to minor noise and
//  we cap the length anyway.
//

import Foundation

nonisolated enum HTMLTextExtractor {

    /// Strip HTML tags, decode basic entities, collapse whitespace, truncate.
    ///
    /// - Parameters:
    ///   - html: raw HTML from `MDict.lookup(word)?.article.html`
    ///   - maxLength: hard cap on the returned string length. Default 400 —
    ///     enough for one or two senses with an example sentence, small
    ///     enough to leave room for the 4096-token Foundation Model context.
    /// - Returns: plain text, or empty string if nothing extractable.
    static func extract(from html: String, maxLength: Int = 400) -> String {
        var text = html

        // 1. Remove entire <script>...</script> and <style>...</style> blocks.
        //    (Some MDX dictionaries ship inline JS/CSS; we never want that in
        //    the model's context.)
        text = removeBlock(in: text, tag: "script")
        text = removeBlock(in: text, tag: "style")

        // 2. Strip all remaining tags. This is deliberately naive — it does
        //    not parse HTML, just matches `<...>` spans. Good enough for our
        //    purposes.
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )

        // 3. Decode a handful of common named entities. NSAttributedString
        //    would do a complete job but it's WebKit-backed and slow; the
        //    model is robust to unknown entities so we only handle the top
        //    offenders here.
        let entityMap: [String: String] = [
            "&nbsp;":  " ",
            "&amp;":   "&",
            "&lt;":    "<",
            "&gt;":    ">",
            "&quot;":  "\"",
            "&#39;":   "'",
            "&apos;":  "'",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…",
        ]
        for (entity, replacement) in entityMap {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities like &#8211;
        text = text.replacingOccurrences(
            of: "&#[0-9]+;",
            with: " ",
            options: .regularExpression
        )

        // 4. Collapse all runs of whitespace (including newlines, tabs, nbsp)
        //    into single spaces, then trim.
        text = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Truncate. If we need to cut, try to cut on a word boundary so
        //    the model doesn't see half-words.
        if text.count > maxLength {
            let cut = text.index(text.startIndex, offsetBy: maxLength)
            let slice = text[..<cut]
            if let lastSpace = slice.lastIndex(of: " ") {
                text = String(slice[..<lastSpace]) + "…"
            } else {
                text = String(slice) + "…"
            }
        }

        return text
    }

    // MARK: - Private

    /// Remove entire `<tag>...</tag>` blocks (including the content).
    /// Case-insensitive, multiline. Used for <script> and <style>.
    private static func removeBlock(in html: String, tag: String) -> String {
        // (?is) = case-insensitive, dotall (. matches newlines)
        let pattern = "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>"
        return html.replacingOccurrences(
            of: pattern,
            with: " ",
            options: .regularExpression
        )
    }
}
