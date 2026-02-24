//
//  Levenshtein.swift
//  OpenMDict
//
//  Levenshtein edit distance — space-optimized single-row DP.
//  Used by MDXParser.suggestions() for ranking candidates.
//

/// Compute Levenshtein edit distance between two strings.
/// Uses Unicode scalars for O(1) indexing (avoids Character's grapheme cluster overhead).
/// Space: O(min(n, m)).  Time: O(n * m).
func levenshteinDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a.unicodeScalars)
    let b = Array(b.unicodeScalars)
    let n = a.count
    let m = b.count

    if n == 0 { return m }
    if m == 0 { return n }

    // Optimise: make 'b' the shorter string for reduced memory.
    if n < m { return levenshteinDistance(String(b.map { Character($0) }),
                                         String(a.map { Character($0) })) }

    // Single-row DP — prev[j] = distance(a[0..<i-1], b[0..<j])
    var prev = Array(0...m)
    var curr = Array(repeating: 0, count: m + 1)

    for i in 1...n {
        curr[0] = i
        for j in 1...m {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            curr[j] = min(
                prev[j] + 1,       // deletion
                curr[j - 1] + 1,   // insertion
                prev[j - 1] + cost // substitution
            )
        }
        swap(&prev, &curr)
    }
    return prev[m]
}
