//
//  LookupFolding.swift
//  OpenMDict
//
//  The normalised forms a lookup falls back to when the query is not a key:
//  full-width ASCII folded to ASCII, and case, accents and other combining
//  marks ignored.
//

import Foundation

public enum LookupFolding {

    // MARK: - Width

    /// `query` with full-width ASCII (U+FF01–U+FF5E, e.g. "３：１６",
    /// "ｊｏｈｎ") and the ideographic space (U+3000) replaced by their ASCII
    /// forms. CJK keyboards type these where dictionary keys have ASCII.
    public static func widthFolded(_ query: String) -> String {
        guard query.unicodeScalars.contains(where: isWide) else { return query }
        var scalars = String.UnicodeScalarView()
        for scalar in query.unicodeScalars { scalars.append(narrowed(scalar)) }
        return String(scalars)
    }

    @inline(__always)
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        (0xFF01...0xFF5E).contains(scalar.value) || scalar.value == 0x3000
    }

    @inline(__always)
    private static func narrowed(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0xFF01...0xFF5E: return Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar
        case 0x3000: return " "
        default: return scalar
        }
    }

    // MARK: - Case and diacritics

    /// The form under which keys match regardless of case, width and
    /// diacritics: width-folded, with the combining marks below removed —
    /// both those typed separately and those canonical decomposition (NFD)
    /// separates from a precomposed letter — lowercased, and final sigma
    /// (ς) as σ.
    ///
    /// Removed: the combining diacritical marks (U+0300–U+036F and their
    /// extension blocks — Latin acute, grave, macron, breve, cedilla …; Greek
    /// tonos, oxia, varia, perispomeni, breathings, diaeresis, iota
    /// subscript), the Arabic harakat (U+064B–U+065F, U+0670) and tatweel
    /// (U+0640). Only what NFD separates from a letter is removed: letters
    /// such as ß, ø, ł, đ or ı stay as they are, and marks that belong to
    /// other scripts (kana voicing marks, Indic vowel signs) are kept.
    ///
    /// Characters are folded one by one (precomposed letters through a
    /// table built from their canonical decompositions); compare results
    /// with `==` or by their UTF-8 bytes.
    public static func folded(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            _ = fold(scalar) { scalars.append($0) }
        }
        return String(scalars)
    }

    /// Appends the UTF-8 bytes of `folded(key)` to `bytes`.
    static func appendFoldedUTF8(_ key: String, to bytes: inout [UInt8]) {
        for scalar in key.unicodeScalars {
            _ = fold(scalar) { UTF8.encode($0) { bytes.append($0) } }
        }
    }

    /// Whether `folded(key)` differs from `key.lowercased()`: whether `key`
    /// has a mark, a full-width character or a final sigma.
    static func foldsBeyondCase(_ key: String) -> Bool {
        for scalar in key.unicodeScalars {
            let v = scalar.value
            if v < 0xC0 { continue }
            if FoldTable.range.contains(v) {
                if FoldTable.shared.changesBeyondCase(v) { return true }
                continue
            }
            switch v {
            case 0x3000, 0xFE20...0xFE2F, 0xFF01...0xFF5E: return true
            default: continue
            }
        }
        return false
    }

    /// Emits the folded form of one character; returns whether it differs
    /// from the character's lowercase form.
    @inline(__always)
    private static func fold(_ scalar: Unicode.Scalar, emit: (Unicode.Scalar) -> Void) -> Bool {
        let v = scalar.value
        if v < 0x80 {
            emit(v >= 0x41 && v <= 0x5A ? Unicode.Scalar(UInt8(v + 0x20)) : scalar)
            return false
        }
        if FoldTable.range.contains(v) {
            return FoldTable.shared.fold(v, emit: emit)
        }
        switch v {
        case 0xFF01...0xFF5E, 0x3000:
            let narrow = narrowed(scalar)
            emit(narrow.value >= 0x41 && narrow.value <= 0x5A ? Unicode.Scalar(UInt8(narrow.value + 0x20)) : narrow)
            return true
        case 0xFE20...0xFE2F:
            return true
        default:
            if scalar.properties.changesWhenLowercased {
                for lower in scalar.properties.lowercaseMapping.unicodeScalars { emit(lower) }
            } else {
                emit(scalar)
            }
            return false
        }
    }

    /// Marks `folded(_:)` removes after decomposition.
    static func isFoldedAway(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0337, 0x0338:            // solidus overlays: they negate symbols (≠, ∉)
            return false
        case 0x0300...0x036F,           // Combining Diacritical Marks
             0x1AB0...0x1AFF,           // … Extended
             0x1DC0...0x1DFF,           // … Supplement
             0xFE20...0xFE2F,           // Combining Half Marks
             0x064B...0x065F, 0x0670,   // Arabic harakat
             0x0640:                    // Arabic tatweel
            return true
        default:
            return false
        }
    }

    /// The folded form of every character from U+00C0 to U+214F — the
    /// blocks with precomposed letters whose decomposition holds a removed
    /// mark (Latin, Greek, Cyrillic, Arabic, Latin and Greek Extended,
    /// letterlike symbols), and most of the marks themselves. Outside it a
    /// character folds to its lowercase form, except full-width ASCII, the
    /// ideographic space and the combining half marks. Built on first use
    /// (about 10 ms).
    private final class FoldTable: Sendable {
        static let range: ClosedRange<UInt32> = 0xC0...0x214F
        static let shared = FoldTable()

        /// `starts[i]..<starts[i + 1]` are the folded scalars of
        /// `range.lowerBound + i` in `output`; the top bit of `starts[i]`
        /// marks a fold that differs from the lowercase form.
        private let starts: [UInt32]
        private let output: [Unicode.Scalar]
        private static let changedBit: UInt32 = 1 << 31

        private init() {
            var starts: [UInt32] = []
            var output: [Unicode.Scalar] = []
            starts.reserveCapacity(Self.range.count + 1)
            for v in Self.range {
                var start = UInt32(output.count)
                if let scalar = Unicode.Scalar(v) {
                    let char = String(scalar)
                    var folded = String.UnicodeScalarView()
                    for part in char.decomposedStringWithCanonicalMapping.unicodeScalars
                    where !LookupFolding.isFoldedAway(part) {
                        folded.append(part)
                    }
                    var lowered = String(folded).lowercased()
                    if lowered.unicodeScalars.contains("\u{03C2}") {
                        lowered = String(String.UnicodeScalarView(
                            lowered.unicodeScalars.map { $0 == "\u{03C2}" ? "\u{03C3}" : $0 }))
                    }
                    output.append(contentsOf: lowered.unicodeScalars)
                    if lowered != char.lowercased() { start |= Self.changedBit }
                }
                starts.append(start)
            }
            starts.append(UInt32(output.count))
            self.starts = starts
            self.output = output
        }

        @inline(__always)
        func changesBeyondCase(_ v: UInt32) -> Bool {
            starts[Int(v - Self.range.lowerBound)] & Self.changedBit != 0
        }

        @inline(__always)
        func fold(_ v: UInt32, emit: (Unicode.Scalar) -> Void) -> Bool {
            let i = Int(v - Self.range.lowerBound)
            let start = starts[i]
            let end = starts[i + 1] & ~Self.changedBit
            for j in Int(start & ~Self.changedBit)..<Int(end) { emit(output[j]) }
            return start & Self.changedBit != 0
        }
    }
}

// MARK: - Folded key index

/// The keys of a dictionary whose folded form (`LookupFolding.folded`)
/// differs from their lowercased form, sorted by folded form. With the
/// lowercase-sorted index the parser already has, it finds every key that
/// folds to a given string: keys that fold to their own lowercase form are
/// found there, the others here.
///
/// Holds key indices only (4 bytes per key with marks); folded forms are
/// recomputed for the few keys a binary search touches.
struct FoldedKeyIndex: Sendable {

    /// Indices into the parser's keyword list, sorted by the UTF-8 bytes of
    /// the folded key (ties in key order).
    let indices: [UInt32]

    static let empty = FoldedKeyIndex(indices: [])

    /// Builds the index over `count` keys; `keyAt` returns the key at an index.
    static func build(count: Int, keyAt: (Int) -> String) -> FoldedKeyIndex {
        // First pass: which keys, and about how many bytes their folded
        // forms take — so the buffers below are allocated once.
        var marked: [UInt32] = []
        var byteEstimate = 0
        for i in 0..<count {
            let key = keyAt(i)
            guard !key.utf8.allSatisfy({ $0 < 0x80 }), LookupFolding.foldsBeyondCase(key) else { continue }
            marked.append(UInt32(i))
            byteEstimate += key.utf8.count
        }
        guard !marked.isEmpty else { return .empty }

        var pool: [UInt8] = []
        pool.reserveCapacity(byteEstimate)
        var entries: [(index: UInt32, start: UInt32, length: UInt32)] = []
        entries.reserveCapacity(marked.count)
        for i in marked {
            let start = pool.count
            LookupFolding.appendFoldedUTF8(keyAt(Int(i)), to: &pool)
            entries.append((i, UInt32(start), UInt32(pool.count - start)))
        }
        marked = []
        pool.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            entries.sort { a, b in
                let c = memcmp(base + Int(a.start), base + Int(b.start), Int(min(a.length, b.length)))
                if c != 0 { return c < 0 }
                if a.length != b.length { return a.length < b.length }
                return a.index < b.index
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(entries.count)
        for entry in entries { indices.append(entry.index) }
        return FoldedKeyIndex(indices: indices)
    }

    /// Key indices whose folded form equals `folded` (or, with `prefix`,
    /// starts with it), sorted by folded form, equal forms in key order.
    /// `keyAt` returns the key at a keyword index; `limit` caps the result.
    func matches(_ folded: String, prefix: Bool, limit: Int = .max, keyAt: (Int) -> String) -> [Int] {
        guard !indices.isEmpty else { return [] }
        let target = Array(folded.utf8)
        func foldedKey(_ position: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            LookupFolding.appendFoldedUTF8(keyAt(Int(indices[position])), to: &bytes)
            return bytes
        }
        var lo = 0
        var hi = indices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if foldedKey(mid).lexicographicallyPrecedes(target) { lo = mid + 1 } else { hi = mid }
        }
        var result: [Int] = []
        var i = lo
        while i < indices.count, result.count < limit {
            let candidate = foldedKey(i)
            let hit = prefix ? candidate.starts(with: target) : candidate == target
            guard hit else { break }
            result.append(Int(indices[i]))
            i += 1
        }
        return result
    }
}
