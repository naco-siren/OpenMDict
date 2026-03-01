//
//  InflectionRules.swift
//  OpenMDict-iOS
//
//  Protocol for language-specific inflection resolution.
//  Conformers provide data (language code, irregular forms, suffix rules);
//  the default `resolve()` implementation handles the standard flow:
//  irregular lookup → suffix rule application → dedup + sort.
//
//  TODO: When scaling to more languages, consider loading irregularForms
//  and suffixRules from bundled JSON files for easier maintenance and
//  potential outsourcing of linguistic data to non-programmers.
//

import Foundation

// MARK: - Suffix Rule (shared across languages)

/// A suffix-based inflection rule: strip `suffix`, apply each replacement to the stem.
/// Applicable to any language with concatenative morphology (English, Spanish, German, etc.).
///
/// Example: `InflectionSuffixRule(suffix: "ing", replacements: [{ $0 }, { $0 + "e" }])`
/// matches "walking" → stem "walk" → candidates ["walk", "walke"].
struct InflectionSuffixRule: Sendable {
    let suffix: String
    /// Each replacement closure takes the stem (word minus suffix) and returns a candidate.
    let replacements: [@Sendable (String) -> String]
}

// MARK: - Protocol

/// Protocol for language-specific inflection resolution.
/// Given an inflected word form, produces candidate base forms.
/// Dictionary search determines which candidates actually exist.
///
/// Conformers are `nonisolated enum` namespaces that provide:
/// - `languageCode`: ISO 639-1 code for runtime dispatch and logging
/// - `irregularForms`: inflected → base lookup table (highest priority)
/// - `suffixRules`: ordered by specificity (longest suffix first)
///
/// The default `resolve()` implementation in the protocol extension handles
/// the standard flow. Override only if a language needs non-standard logic.
nonisolated protocol InflectionRules {
    /// ISO 639-1 language code (e.g. "en", "es", "de").
    static var languageCode: String { get }

    /// Irregular forms: inflected → base (e.g. "went" → "go").
    static var irregularForms: [String: String] { get }

    /// Suffix rules ordered by specificity (longer/more specific suffixes first).
    static var suffixRules: [InflectionSuffixRule] { get }
}

// MARK: - Default Implementation

nonisolated extension InflectionRules {

    /// Standard inflection resolution: irregular lookup → suffix rules → dedup + sort.
    /// Returns empty array if no rules apply. Results are lowercased and deduplicated.
    static func resolve(_ word: String) -> [String] {
        let lower = word.lowercased()
        guard lower.count >= 2 else { return [] }

        var candidates = Set<String>()

        // 1. Irregular forms table (highest priority)
        if let base = irregularForms[lower] {
            candidates.insert(base)
        }

        // 2. Suffix rules (may produce multiple candidates per rule)
        for rule in suffixRules {
            guard lower.hasSuffix(rule.suffix), lower.count > rule.suffix.count else { continue }
            let stem = String(lower.dropLast(rule.suffix.count))
            for replacement in rule.replacements {
                let candidate = replacement(stem)
                if !candidate.isEmpty && candidate != lower {
                    candidates.insert(candidate)
                }
            }
        }

        // Remove the original word if it somehow appeared
        candidates.remove(lower)

        return Array(candidates).sorted()
    }
}
