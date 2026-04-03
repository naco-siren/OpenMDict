//
//  TutorialDictionaryProvider.swift
//  OpenMDict-iOS
//
//  Provides static HTML articles for tutorial levels.
//  No real MDX parsing — content is embedded as Swift string literals
//  styled using the same CSS classes as the GCIDE preset dictionary.
//  Definitions and examples: Open English WordNet 2025 (CC BY 4.0).
//

import UIKit

enum TutorialDictionaryProvider {

    static let dictId   = "__tutorial__"
    static let dictName = "Tutorial Dictionary"

    /// Returns full rendered HTML for a tutorial word, ready to load in a WebView.
    static func articleHTML(for word: String, traitCollection: UITraitCollection) -> String {
        let body = articleBodies[word.lowercased()] ?? fallbackBody(for: word)
        return ArticleHTMLRenderer.renderArticle(
            html: body,
            dictId: dictId,
            traitCollection: traitCollection
        )
    }

    // MARK: - Shared GCIDE-style CSS (inlined per article, same as preset build output)

    // swiftlint:disable line_length
    /// Standard CSS with system dark-mode adaptation — used by most tutorial articles.
    private static let gcideCSS = "<style>.e{font-family:-apple-system,system-ui,sans-serif;max-width:600px;line-height:1.5;color:#1d1d1f;padding:0 12px}.hw{font-size:1.7em;font-weight:600;display:block}.sn{margin:8px 0;padding:8px 10px;background:#f8f8fa;border-radius:6px;border:1px solid #e5e5ea}.sn+.sn{margin-top:6px}.sn-hd{display:flex;flex-wrap:wrap;align-items:center;gap:4px;margin-bottom:4px}.pos{display:inline-block;font-size:0.85em;color:#fff;background:#aeaeb2;border-radius:3px;padding:0 5px}.pr{font-size:1.1em;color:#0071e3;font-style:italic;display:block;margin-top:2px}.et{font-size:0.85em;color:#6e6e73;margin:4px 0;line-height:1.4;display:block}.df{font-size:1.1em}.ex{font-size:0.85em;color:#6e6e73;margin:4px 0 2px 10px;padding:4px 0 4px 10px;border-left:3px solid #d1d1d6;line-height:1.4}.ex-q{display:block;font-style:italic}.syn{font-size:0.85em;color:#636366;margin:4px 0 0}.sep{margin:10px 0;border:none;border-top:1px solid #e5e5ea}.xr a{color:#0071e3;text-decoration:underline}@media(prefers-color-scheme:dark){.e{color:#f5f5f7}.sn{background:#2c2c2e;border-color:#38383a}.pos{background:#636366}.sep{border-color:#38383a}.pr{color:#64d2ff}.et{color:#98989d}.ex{color:#98989d;border-color:#48484a}.syn{color:#98989d}.xr a{color:#64d2ff}}</style>"

    /// Hardcoded light-mode CSS with NO dark-mode @media adaptation.
    /// Used for the Enhance Dark Mode tutorial so the user can actually see the problem
    /// the feature solves: a third-party dictionary that bakes in light-mode colors.
    private static let gcideCSSLightOnly = "<style>.e{font-family:-apple-system,system-ui,sans-serif;max-width:600px;line-height:1.5;color:#1d1d1f;padding:0 12px}.hw{font-size:1.7em;font-weight:600;display:block}.sn{margin:8px 0;padding:8px 10px;background:#f8f8fa;border-radius:6px;border:1px solid #e5e5ea}.sn+.sn{margin-top:6px}.sn-hd{display:flex;flex-wrap:wrap;align-items:center;gap:4px;margin-bottom:4px}.pos{display:inline-block;font-size:0.85em;color:#fff;background:#aeaeb2;border-radius:3px;padding:0 5px}.pr{font-size:1.1em;color:#0071e3;font-style:italic;display:block;margin-top:2px}.et{font-size:0.85em;color:#6e6e73;margin:4px 0;line-height:1.4;display:block}.df{font-size:1.1em}.ex{font-size:0.85em;color:#6e6e73;margin:4px 0 2px 10px;padding:4px 0 4px 10px;border-left:3px solid #d1d1d6;line-height:1.4}.ex-q{display:block;font-style:italic}.syn{font-size:0.85em;color:#636366;margin:4px 0 0}.sep{margin:10px 0;border:none;border-top:1px solid #e5e5ea}.xr a{color:#0071e3;text-decoration:underline}</style>"
    // swiftlint:enable line_length

    // MARK: - Article bodies (GCIDE-format HTML fragments)

    private static let articleBodies: [String: String] = [
        "hello": gcideCSS + """
            <div class="e"><span class="hw">Hello</span>\
            <span class="pr">/həˈloʊ/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">an expression of greeting</span><span class="ex"><span class="ex-q">every morning they exchanged polite hellos</span></span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,

        "dictionary": gcideCSS + """
            <div class="e"><span class="hw">Dictionary</span>\
            <span class="pr">/ˈdɪkʃəˌnɛri/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">a reference book containing an alphabetical list of words with information about them</span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,

        "bookmark": gcideCSS + """
            <div class="e"><span class="hw">Bookmark</span>\
            <span class="pr">/ˈbʊkmɑːrk/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">a marker (a piece of paper or ribbon) placed between the pages of a book to mark the reader's place</span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,

        "search": gcideCSS + """
            <div class="e"><span class="hw">Search</span>\
            <span class="pr">/sɜːrtʃ/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">v.</span></div>\
            <span class="df">try to locate or discover, or try to establish the existence of</span><span class="ex"><span class="ex-q">The police are searching for clues</span></span></div>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">the activity of looking thoroughly in order to find something or someone</span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,

        "language": gcideCSS + """
            <div class="e"><span class="hw">Language</span>\
            <span class="pr">/ˈlæŋɡwɪdʒ/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">a systematic means of communicating by the use of sounds or conventional symbols</span><span class="ex"><span class="ex-q">he taught foreign languages</span></span></div>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">the mental faculty or power of vocal communication</span><span class="ex"><span class="ex-q">language sets homo sapiens apart from all other animals</span></span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,

        "zoom": gcideCSS + """
            <div class="e"><span class="hw">Zoom</span>\
            <span class="pr">/zuːm/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">v.</span></div>\
            <span class="df">move along very quickly</span></div>\
            <div class="sn"><div class="sn-hd"><span class="pos">v.</span></div>\
            <span class="df">move with a low humming noise</span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,

        "group": gcideCSS + """
            <div class="e"><span class="hw">Group</span>\
            <span class="pr">/ɡruːp/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">any number of entities (members) considered as a unit</span></div>\
            <div class="sn"><div class="sn-hd"><span class="pos">v.</span></div>\
            <span class="df">arrange into a group or groups</span><span class="ex"><span class="ex-q">Can you group these shapes together?</span></span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,

        "moon": gcideCSSLightOnly + """
            <div class="e"><span class="hw">Moon</span>\
            <span class="pr">/muːn/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">the natural satellite of the Earth</span><span class="ex"><span class="ex-q">men first stepped on the moon in 1969</span></span></div>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">any natural satellite of a planet</span><span class="ex"><span class="ex-q">Jupiter has sixteen moons</span></span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,

        "find": gcideCSS + """
            <div class="e"><span class="hw">Find</span>\
            <span class="pr">/faɪnd/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">v.</span></div>\
            <span class="df">come upon, as if by accident; meet with</span> <span class="syn">By definition, to find implies a moment of recognition.</span><span class="ex"><span class="ex-q">We find this idea in Plato</span></span></div>\
            <div class="sn"><div class="sn-hd"><span class="pos">v.</span></div>\
            <span class="df">come upon after searching; find the location of something that was missed or lost</span> <span class="syn">The definition of this sense implies intentional effort.</span><span class="ex"><span class="ex-q">Did you find your glasses?</span></span></div>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">the act of discovering something</span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0); usage notes written for this tutorial</span></div>
            """,

        "clipboard": gcideCSS + """
            <div class="e"><span class="hw">Clipboard</span>\
            <span class="pr">/ˈklɪpbɔːrd/</span>\
            <div class="sn"><div class="sn-hd"><span class="pos">n.</span></div>\
            <span class="df">a small writing board with a clip at the top for holding papers</span></div>\
            <span class="et">Definitions: Open English WordNet 2025 (CC BY 4.0)</span></div>
            """,
    ]

    /// The tutorial word to display for each level.
    static func word(for level: TutorialLevel) -> String {
        switch level {
        // Hands-on
        case .zoomAndLayout:      return "zoom"
        case .enhanceDarkMode:    return "moon"
        case .bookmarks:          return "bookmark"
        case .jumpSearch:         return "hello"
        case .findInPage:         return "find"
        // Guides (use generic articles as background)
        case .lookupBasics:       return "search"
        case .popupLookup:        return "dictionary"
        case .dictionaryGroups:   return "group"
        case .importAndResources: return "dictionary"
        case .iPadProductivity:   return "language"
        }
    }

    private static func fallbackBody(for word: String) -> String {
        gcideCSS + "<div class=\"e\"><span class=\"hw\">\(word)</span><div class=\"sn\"><span class=\"df\">Tutorial article.</span></div></div>"
    }
}
