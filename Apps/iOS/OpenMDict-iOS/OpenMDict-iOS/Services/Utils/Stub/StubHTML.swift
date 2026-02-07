//
//  StubHTML.swift
//  OpenMDict-iOS
//
//  Synthetic sample entries for UI development. The text and the markup are
//  written for this project; they only mirror the two shapes of MDict content
//  the renderer has to cope with: flat V1-style paragraphs and nested
//  V2-style sense groups.
//

import Foundation

// MARK: - Stub HTML Provider

enum StubHTML {

    /// Generate a placeholder HTML for words without specific stub data
    nonisolated static func placeholder(for word: String, dictName: String) -> String {
        """
        <div class="entry">
            <div class="head">
                <h2 class="hw">\(word)</h2>
                <span class="pos">noun</span>
            </div>
            <div class="sense">
                <span class="def">Definition for "\(word)" from \(dictName).</span>
            </div>
            <div class="example">
                <span class="ex">This is an example sentence using \(word).</span>
            </div>
        </div>
        """
    }

    /// Get stub HTML for a known word, or placeholder if not available
    static func html(for word: String, dictName: String) -> String {
        let key = word.lowercased()
        if let stub = stubs[key] {
            return stub
        }
        return placeholder(for: word, dictName: dictName)
    }

    // MARK: - Known Stubs

    private static let stubs: [String: String] = [
        "do": sampleThesaurus_do,
        "hello": sampleLearners_hello,
        "query": sampleLearners_query,
    ]

    // MARK: - V1-style sample (flat markup)

    static let sampleThesaurus_do = """
<div class="entry flat">
<p class="hw"><font color="#c00000"><b>do</b></font></p>
<p class="pos">[verb]</p>
<p><b>1</b> <b>make, carry out, complete</b></p>
<p><b>2</b> <b>be good enough, suffice</b></p>
<p class="pos">[noun]</p>
<p><b>3</b> <b>party, gathering</b></p>
</div>
"""

    // MARK: - V2-style sample (nested markup)

    static let sampleLearners_hello = """
<div class="entry nested" id="hello_1">
    <div class="head">
        <h2 class="hw">hello</h2>
        <span class="pos">interjection</span>
        <span class="pron">/həˈloʊ/ <a class="audio" href="sound://hello.mp3"></a></span>
    </div>
    <ol class="senses">
        <li class="sense"><span class="num">1</span>
            <span class="def">sample sense: a greeting</span>
            <span class="examples">
                <span class="ex">Hello, everyone.</span>
                <span class="ex">She said hello and sat down.</span>
            </span>
            <span class="note">
                <span class="note-title">Sample note</span>
                <span class="note-body">A collapsible box inside a sense.</span>
            </span>
        </li>
        <li class="sense"><span class="num">2</span>
            <span class="label">(informal)</span>
            <span class="def">sample sense: a sound of surprise</span>
            <span class="examples">
                <span class="ex">Hello, what is this?</span>
            </span>
        </li>
        <span class="xref">see also <a href="entry://hi">hi</a></span>
    </ol>
</div>
"""

    static let sampleLearners_query = """
<div class="entry nested" id="query_1">
    <div class="head">
        <h2 class="hw">query</h2>
        <span class="pos">noun</span>
        <span class="pron">/ˈkwɪri/ <a class="audio" href="sound://query.mp3"></a></span>
    </div>
    <ol class="senses">
        <li class="sense"><span class="num">1</span>
            <span class="def">sample sense: a question</span>
            <span class="examples">
                <span class="ex">Send your query by email.</span>
            </span>
        </li>
    </ol>
</div>
<div class="entry nested" id="query_2">
    <div class="head">
        <h2 class="hw">query</h2>
        <span class="pos">verb</span>
    </div>
    <ol class="senses">
        <li class="sense"><span class="num">1</span>
            <span class="def">sample sense: to ask about something</span>
            <span class="examples">
                <span class="ex">He queried the total.</span>
            </span>
        </li>
    </ol>
</div>
"""
}
