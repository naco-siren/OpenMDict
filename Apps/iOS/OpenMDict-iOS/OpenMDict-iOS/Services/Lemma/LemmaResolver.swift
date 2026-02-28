//
//  LemmaResolver.swift
//  OpenMDict-iOS
//
//  Pure string processing for lemma resolution.
//  No dictionary access — generates candidate search terms from user queries.
//
//  Layered approach:
//  1. Normalize: strip punctuation, collapse whitespace, lowercase
//  2. Strip stopwords: remove function words, return remaining tokens
//  3. NLTagger: attempt lemma extraction via Apple's NLP
//

import Foundation
import NaturalLanguage

/// Lemma candidate generation — pure string processing, no dictionary access.
/// Thread-safe: all methods are pure functions on immutable data.
nonisolated enum LemmaResolver {

    // MARK: - Layer 1: Normalize

    /// Strip leading/trailing punctuation, collapse whitespace, lowercase.
    /// e.g. "to loped?" → "to loped", "  Hello!!! " → "hello"
    static func normalize(_ query: String) -> String {
        // 1. Trim whitespace
        var s = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // 2. Strip leading/trailing punctuation (keep internal punctuation like hyphens)
        let punctuation = CharacterSet.punctuationCharacters
            .union(.symbols)
        while let first = s.unicodeScalars.first, punctuation.contains(first) {
            s = String(s.dropFirst())
        }
        while let last = s.unicodeScalars.last, punctuation.contains(last) {
            s = String(s.dropLast())
        }

        // 3. Collapse multiple whitespace into single space
        let components = s.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        s = components.joined(separator: " ")

        // 4. Lowercase
        return s.lowercased()
    }

    // MARK: - Layer 2: Strip Stopwords

    /// Remove English function words, return remaining tokens as candidate words.
    /// Entropy guard: if stripping removes ALL words, return the original (lowercased) as-is.
    ///
    /// Returns an array of non-empty candidate strings (individual words).
    /// e.g. "to loped" → ["loped"], "the big house" → ["big", "house"]
    static func stripStopwords(_ normalized: String) -> [String] {
        guard !normalized.isEmpty else { return [] }

        let tokens = normalized.components(separatedBy: " ")
        let filtered = tokens.filter { !englishStopwords.contains($0) }

        // Entropy guard: if everything was stripped, keep original tokens
        if filtered.isEmpty {
            return tokens
        }
        return filtered
    }

    // MARK: - Layer 3: NLTagger Lemma

    /// Attempt lemma extraction via Apple's NLTagger.
    /// Wraps single word in "I {word}" for minimal sentence context (improves verb lemma detection).
    /// Returns empty array if NLTagger has no insight (common for rare/inflected single words).
    static func nltaggerLemmas(_ word: String) -> [String] {
        // Provide minimal sentence context for better verb detection
        let sentence = "I \(word)"
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = sentence

        var lemmas: [String] = []
        let range = sentence.startIndex..<sentence.endIndex

        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma) { tag, tokenRange in
            let token = String(sentence[tokenRange])
            // Skip the "I" we prepended
            if token.lowercased() != "i", let tag {
                let lemma = tag.rawValue.lowercased()
                // Only keep if lemma differs from the input
                if lemma != word.lowercased() && !lemma.isEmpty {
                    lemmas.append(lemma)
                }
            }
            return true
        }

        return lemmas
    }

    // MARK: - English Stopwords

    /// Common English function words that are unlikely to be dictionary headwords.
    /// Kept compact — covers determiners, prepositions, auxiliaries, pronouns.
    private static let englishStopwords: Set<String> = [
        // Determiners / articles
        "the", "a", "an", "this", "that", "these", "those",
        "my", "your", "his", "her", "its", "our", "their",
        // Prepositions
        "to", "of", "in", "on", "at", "for", "with", "from",
        "by", "about", "into", "through", "during", "before",
        "after", "above", "below", "between", "under", "over",
        // Auxiliaries / modals
        "is", "am", "are", "was", "were", "be", "been", "being",
        "do", "does", "did",
        "have", "has", "had",
        "will", "would", "shall", "should",
        "can", "could", "may", "might", "must",
        // Pronouns
        "i", "me", "you", "he", "him", "she", "we", "us", "they", "them",
        "it", "who", "whom", "what", "which",
        // Conjunctions / particles
        "and", "or", "but", "not", "no", "if", "so", "as", "than",
    ]
}
