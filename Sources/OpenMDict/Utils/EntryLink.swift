//
//  EntryLink.swift
//  OpenMDict
//
//  Parsing of MDict cross-reference links (`entry://word#anchor`).
//

import Foundation

public enum EntryLink {

    /// The word and in-page anchor of an `entry://` link.
    ///
    /// The target is everything after `entry://` up to the first `#`,
    /// percent-decoded — not the URL's host: a host stops at "/" and ":", so
    /// `entry://9/11` would have looked up "9" and `entry://A/C` "A", and a
    /// target such as "Capital: Critique…" does not even form a valid host.
    ///
    /// - Parameter absoluteString: The link as WebKit reports it
    ///   (`URL.absoluteString`), e.g. `entry://take#take-up`.
    /// - Returns: nil when `absoluteString` is not an entry link.
    public static func parse(_ absoluteString: String) -> (word: String, fragment: String?)? {
        guard let schemeEnd = absoluteString.range(of: ":"),
              absoluteString[..<schemeEnd.lowerBound].lowercased() == "entry" else { return nil }
        var rest = absoluteString[schemeEnd.upperBound...]
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }

        let word: Substring
        let fragment: Substring?
        if let hash = rest.firstIndex(of: "#") {
            word = rest[..<hash]
            fragment = rest[rest.index(after: hash)...]
        } else {
            word = rest
            fragment = nil
        }
        let decodedWord = String(word).removingPercentEncoding ?? String(word)
        let decodedFragment = fragment.map { String($0).removingPercentEncoding ?? String($0) }
        return (decodedWord, (decodedFragment?.isEmpty ?? true) ? nil : decodedFragment)
    }

    /// Characters left unencoded in an entry link's target when the app
    /// rewrites article HTML: the URL path set without the characters that
    /// end or change a host or authority ("/", ":", "?", "@") — WebKit
    /// would otherwise split `entry://Capital: Critique` at the colon — and
    /// with "%" kept so existing escapes are not encoded twice. ";" stays:
    /// the target is raw attribute text, where it ends HTML character
    /// references such as `&amp;` and `&#39;`.
    public static let targetAllowedCharacters: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/:?@")
        set.insert("%")
        return set
    }()

    /// Characters that make a pure-ASCII target need encoding.
    public static let hostEndingCharacters: Set<Unicode.Scalar> = ["/", ":", "?", "@"]
}
