//
//  FuzzySuggestionsCompute.swift
//  OpenMDict-iOS
//
//  Shared Levenshtein-distance-based suggestion computation used by both
//  SpellingLookupSession (its terminal fuzzy-fallback stage) and
//  SemanticLookupSession (when the semantic compute returns weak results
//  — too few matches, or top cosine similarity below a threshold —
//  suggesting the query itself is misspelled).
//
//  Lives at file scope so both sessions can call it. Free function rather
//  than a static helper because there's nothing to hold; it's pure on
//  its inputs.
//

import Foundation
import OpenMDict
import OpenMDictKit

/// Compute distance-ranked suggestions on a background thread.
///
/// `MDictReader` is `@unchecked Sendable` with thread safety guaranteed by
/// internal NSLock guards (BinaryReader.atomicRead, ResourceProvider.cacheLock).
/// `suggestions()` operates on immutable in-memory keyword data — no I/O, no
/// locks needed.
///
/// Each reader returns `[ScoredSuggestion]` (word + distance). This function
/// merges across readers, deduplicates case-insensitively keeping the min
/// distance per word, and returns globally distance-ranked results capped at
/// `LookupPipelineConfig.maxSuggestions`.
///
/// `existingWords` are lowercased forms that should be filtered out — typically
/// the caller's already-resolved results (direct matches, lemma forms, semantic
/// matches) that shouldn't reappear as fuzzy fallback rows.
@concurrent
nonisolated func computeSuggestionsInBackground(
    readers: [MDictReader],
    query: String,
    existingWords: Set<String>
) async -> [String] {
    // Collect from all readers, dedup case-insensitively keeping best (min) distance.
    var best: [String: ScoredSuggestion] = [:]  // lowercased key → best scored suggestion

    for reader in readers {
        guard !Task.isCancelled else { return [] }
        for s in reader.suggestions(for: query, limit: LookupPipelineConfig.suggestionsPerReader) {
            let key = s.word.lowercased()
            guard !existingWords.contains(key) else { continue }
            if let existing = best[key] {
                if s.distance < existing.distance { best[key] = s }
            } else {
                best[key] = s
            }
        }
    }

    guard !Task.isCancelled, !best.isEmpty else { return [] }

    // Global rank: distance ascending, alphabetical for ties.
    return best.values
        .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.word < $1.word }
        .prefix(LookupPipelineConfig.maxSuggestions)
        .map(\.word)
}
