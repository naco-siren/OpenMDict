//
//  LookupFolding.swift
//  OpenMDict
//
//  The normalised forms a lookup falls back to when the query is not a key:
//  full-width and other compatibility forms folded to their ordinary
//  characters, and case, accents and other combining marks ignored.
//

import Foundation

public enum LookupFolding {

    // MARK: - Width and compatibility forms

    /// `query` with full-width ASCII (U+FF01–U+FF5E, e.g. "３：１６",
    /// "ｊｏｈｎ") and the ideographic space (U+3000) replaced by ASCII, and
    /// the other compatibility forms replaced by their ordinary characters:
    /// half-width katakana and the rest of the Halfwidth and Fullwidth Forms
    /// block ("ｺｰﾋｰ" → "コーヒー", "ｶﾞ" → "ガ") and the Latin ligatures
    /// U+FB00–U+FB06 ("ﬁnd" → "find"). The compatibility mapping (NFKC) of
    /// those characters only; nothing else in the text changes. CJK
    /// keyboards type the wide forms where dictionary keys have ASCII; text
    /// copied from PDFs carries the ligatures.
    public static func widthFolded(_ query: String) -> String {
        guard query.unicodeScalars.contains(where: isCompatibilityForm) else { return query }
        var scalars = String.UnicodeScalarView()
        var composes = false
        for scalar in query.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                scalars.append(Unicode.Scalar(UInt8(scalar.value - 0xFEE0)))
            case 0x3000:
                scalars.append(" ")
            case 0xFF5F...0xFFEE, 0xFB00...0xFB06:
                scalars.append(contentsOf: String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars)
                composes = true     // "ｶﾞ" maps to カ + U+3099: compose them
            default:
                scalars.append(scalar)
            }
        }
        let folded = String(scalars)
        return composes ? folded.precomposedStringWithCanonicalMapping : folded
    }

    /// Full-width ASCII, the ideographic space, the halfwidth and fullwidth
    /// forms (the assigned ones) and the Latin ligatures: what `widthFolded`
    /// changes.
    @inline(__always)
    static func isCompatibilityForm(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000, 0xFB00...0xFB06,
             0xFF01...0xFFBE, 0xFFC2...0xFFC7, 0xFFCA...0xFFCF, 0xFFD2...0xFFD7, 0xFFDA...0xFFDC,
             0xFFE0...0xFFE6, 0xFFE8...0xFFEE:
            return true
        default:
            return false
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
    /// subscript; the Cyrillic stress accent and the diaeresis of ё), the
    /// Arabic harakat (U+064B–U+0652, U+0656–U+065F, U+0670) and tatweel
    /// (U+0640). Only what NFD separates from a letter is removed: letters
    /// such as ß, ø, ł, đ or ı stay as they are, and marks that belong to
    /// other scripts (kana voicing marks, Indic vowel signs) are kept. So
    /// are, as whole letters, the Cyrillic й Й ў Ў ї Ї ѓ Ѓ ќ Ќ ѝ Ѝ
    /// (`isKeptWhole`) and the Arabic hamza and madda marks (U+0653–U+0655:
    /// ؤ and ئ stay), except on alef (أ إ آ → ا).
    ///
    /// Characters are folded one by one (precomposed letters through a
    /// table built from their canonical decompositions); compare results
    /// with `==` or by their UTF-8 bytes.
    public static func folded(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        var scalars = String.UnicodeScalarView()
        for scalar in widthFolded(composed(text)).unicodeScalars {
            _ = fold(scalar) { scalars.append($0) }
        }
        return String(scalars)
    }

    /// Appends the UTF-8 bytes of `folded(key)` to `bytes`.
    static func appendFoldedUTF8(_ key: String, to bytes: inout [UInt8]) {
        for scalar in widthFolded(composed(key)).unicodeScalars {
            _ = fold(scalar) { UTF8.encode($0) { bytes.append($0) } }
        }
    }

    /// `text` composed (NFC) when it holds a mark that folding handles, a
    /// kana voicing mark or conjoining jamo, so that a mark typed after its
    /// letter folds like the precomposed letter ("и" + breve is "й", a
    /// letter; "e" + acute is "é") and decomposed kana and Hangul are read
    /// as their letters and syllables; otherwise `text`.
    static func composed(_ text: String) -> String {
        let needsComposition = text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0653...0x0655, 0x3099...0x309A, 0x1100...0x11FF: return true
            default: return isFoldedAway(scalar)
            }
        }
        return needsComposition ? text.precomposedStringWithCanonicalMapping : text
    }

    /// Whether `folded(key)` differs from `key.lowercased()`: whether `key`
    /// has a mark, a compatibility form or a final sigma.
    static func foldsBeyondCase(_ key: String) -> Bool {
        for scalar in composed(key).unicodeScalars {
            let v = scalar.value
            if v < 0xC0 { continue }
            if FoldTable.range.contains(v) {
                if FoldTable.shared.changesBeyondCase(v) { return true }
                continue
            }
            if isCompatibilityForm(scalar) || (0xFE20...0xFE2F).contains(v) { return true }
        }
        return false
    }

    /// Emits the folded form of one character of width-folded text; says
    /// whether it differs from the character's lowercase form, and whether
    /// a mark was removed from it.
    @inline(__always)
    private static func fold(_ scalar: Unicode.Scalar,
                             emit: (Unicode.Scalar) -> Void) -> (changed: Bool, removedMark: Bool) {
        let v = scalar.value
        if v < 0x80 {
            emit(v >= 0x41 && v <= 0x5A ? Unicode.Scalar(UInt8(v + 0x20)) : scalar)
            return (false, false)
        }
        if FoldTable.range.contains(v) {
            return FoldTable.shared.fold(v, emit: emit)
        }
        if (0xFE20...0xFE2F).contains(v) {          // combining half marks
            return (true, true)
        }
        if scalar.properties.changesWhenLowercased {
            for lower in scalar.properties.lowercaseMapping.unicodeScalars { emit(lower) }
        } else {
            emit(scalar)
        }
        return (false, false)
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
             0x064B...0x0652,           // Arabic harakat (fathatan … sukun) —
             0x0656...0x065F, 0x0670,   // not U+0653–U+0655, madda and hamza, which make letters (ؤ ئ)
             0x0640:                    // Arabic tatweel
            return true
        default:
            return false
        }
    }

    /// Letters whose canonical decomposition carries a mark but that are
    /// letters of their own alphabet, kept whole: Cyrillic й Й ў Ў ї Ї ѓ Ѓ
    /// ќ Ќ ѝ Ѝ. (ё still folds to е, and a stress accent typed on a vowel is
    /// removed — "за́йка" finds "зайка".)
    static func isKeptWhole(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0419, 0x0439,            // Й й
             0x040E, 0x045E,            // Ў ў
             0x0407, 0x0457,            // Ї ї
             0x0403, 0x0453,            // Ѓ ѓ
             0x040C, 0x045C,            // Ќ ќ
             0x040D, 0x045D:            // Ѝ ѝ
            return true
        default:
            return false
        }
    }

    /// Alef with madda, hamza above or hamza below (آ أ إ): the one letter
    /// whose madda and hamza marks are removed, to the bare alef (ا).
    static func isAlefWithMark(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x0622 || scalar.value == 0x0623 || scalar.value == 0x0625
    }

    /// Whether a removed mark on `base` counts as typed (`MarkPattern`):
    /// the accents of the Latin and Greek alphabets do — they spell words
    /// apart (está / esta, χωριά / χώρια). Reading aids that dictionaries
    /// leave out do not: the Arabic harakat and the hamza on alef, and the
    /// stress accent (acute or grave) on a Cyrillic letter.
    static func countsAsTypedMark(_ mark: Unicode.Scalar, on base: Unicode.Scalar) -> Bool {
        switch base.value {
        case 0x0600...0x06FF, 0x0750...0x077F:
            return false
        case 0x0400...0x052F:
            return mark.value != 0x0300 && mark.value != 0x0301
        default:
            return true
        }
    }

    /// The folded form of every character from U+00C0 to U+214F — the
    /// blocks with precomposed letters whose decomposition holds a removed
    /// mark (Latin, Greek, Cyrillic, Arabic, Latin and Greek Extended,
    /// letterlike symbols), and most of the marks themselves. Outside it a
    /// character folds to its lowercase form, except the compatibility forms
    /// (folded first) and the combining half marks. Built on first use
    /// (about 10 ms).
    private final class FoldTable: Sendable {
        static let range: ClosedRange<UInt32> = 0xC0...0x214F
        static let shared = FoldTable()

        /// `starts[i]..<starts[i + 1]` are the folded scalars of
        /// `range.lowerBound + i` in `output`; the top bit of `starts[i]`
        /// marks a fold that differs from the lowercase form, the next one
        /// a fold that removed a mark that counts as typed
        /// (`countsAsTypedMark`).
        private let starts: [UInt32]
        private let output: [Unicode.Scalar]
        private static let changedBit: UInt32 = 1 << 31
        private static let markBit: UInt32 = 1 << 30
        private static let flagBits: UInt32 = changedBit | markBit

        private init() {
            var starts: [UInt32] = []
            var output: [Unicode.Scalar] = []
            starts.reserveCapacity(Self.range.count + 1)
            for v in Self.range {
                var start = UInt32(output.count)
                if let scalar = Unicode.Scalar(v) {
                    let char = String(scalar)
                    let folded: String
                    var removedMark = false
                    if LookupFolding.isKeptWhole(scalar) {
                        folded = char
                    } else if LookupFolding.isAlefWithMark(scalar) {
                        folded = "\u{0627}"
                    } else {
                        let decomposed = char.decomposedStringWithCanonicalMapping.unicodeScalars
                        if let base = decomposed.first, decomposed.contains(where: LookupFolding.isFoldedAway) {
                            removedMark = decomposed.contains {
                                LookupFolding.isFoldedAway($0) && LookupFolding.countsAsTypedMark($0, on: base)
                            }
                            let kept = String.UnicodeScalarView(decomposed.filter { !LookupFolding.isFoldedAway($0) })
                            folded = String(kept).precomposedStringWithCanonicalMapping
                        } else {
                            folded = char
                        }
                    }
                    var lowered = folded.lowercased()
                    if lowered.unicodeScalars.contains("\u{03C2}") {
                        lowered = String(String.UnicodeScalarView(
                            lowered.unicodeScalars.map { $0 == "\u{03C2}" ? "\u{03C3}" : $0 }))
                    }
                    output.append(contentsOf: lowered.unicodeScalars)
                    if lowered != char.lowercased() { start |= Self.changedBit }
                    if removedMark { start |= Self.markBit }
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
        func fold(_ v: UInt32, emit: (Unicode.Scalar) -> Void) -> (changed: Bool, removedMark: Bool) {
            let i = Int(v - Self.range.lowerBound)
            let start = starts[i]
            let end = starts[i + 1] & ~Self.flagBits
            for j in Int(start & ~Self.flagBits)..<Int(end) { emit(output[j]) }
            return (start & Self.changedBit != 0, start & Self.markBit != 0)
        }
    }

    // MARK: - Marks typed in a query

    /// Where a text's marks are: for each scalar of `folded(text)`, whether
    /// the character it came from carried a mark that folding removed.
    ///
    /// Diacritic-insensitive matching is constrained by the marks the user
    /// typed: a query letter with a mark (any mark) may only match a key
    /// letter that also has one, at the same position; marks the query lacks
    /// act as wildcards. So "Muller" finds "Müller" and "cafè" finds "café",
    /// but "è" does not find "e", nor "tenía" "tenia", nor "χωριά" "χώρια".
    /// Marks that are reading aids rather than spelling — Arabic harakat, a
    /// Cyrillic stress accent — count on neither side
    /// (`countsAsTypedMark`): "за́йка" finds "зайка", "مُحَمَّد" finds "محمد".
    struct MarkPattern {
        /// One flag per scalar of the folded text.
        let marked: [Bool]
        /// Whether any letter carries a mark; without one, every key whose
        /// folded form matches is admitted.
        let hasMarks: Bool

        init(_ text: String) {
            var marked: [Bool] = []
            var lastBase: Unicode.Scalar = " "
            for scalar in LookupFolding.widthFolded(LookupFolding.composed(text)).unicodeScalars {
                if LookupFolding.isFoldedAway(scalar) {
                    // A mark typed as its own character belongs to the letter before it.
                    if !marked.isEmpty, LookupFolding.countsAsTypedMark(scalar, on: lastBase) {
                        marked[marked.count - 1] = true
                    }
                    continue
                }
                var count = 0
                let removedMark = LookupFolding.fold(scalar) { count += 1; lastBase = $0 }.removedMark
                if count == 0 {
                    if removedMark, !marked.isEmpty { marked[marked.count - 1] = true }
                    continue
                }
                marked.append(contentsOf: repeatElement(removedMark, count: count))
            }
            self.marked = marked
            self.hasMarks = marked.contains(true)
        }

        /// Whether `key` — whose folded form equals the pattern's text, or
        /// starts with it when `prefix` — has a mark wherever the text has
        /// one.
        func admits(_ key: String, prefix: Bool = false) -> Bool {
            guard hasMarks else { return true }
            let keyMarks = MarkPattern(key).marked
            guard keyMarks.count >= marked.count, prefix || keyMarks.count == marked.count else { return false }
            for i in marked.indices where marked[i] && !keyMarks[i] { return false }
            return true
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

    /// How many times `build` has run in this process — for tests of the
    /// index's lifecycle (saved copies are loaded, not built; a main-thread
    /// lookup never builds).
    static let builds = BuildCounter()

    final class BuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        fileprivate func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    /// Builds the index over `count` keys; `keyAt` returns the key at an index.
    static func build(count: Int, keyAt: (Int) -> String) -> FoldedKeyIndex {
        builds.increment()
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
    /// starts with it) and that pass `accept`, sorted by folded form, equal
    /// forms in key order. `keyAt` returns the key at a keyword index;
    /// `limit` caps the result.
    func matches(_ folded: String, prefix: Bool, limit: Int = .max, keyAt: (Int) -> String,
                 accept: (Int) -> Bool = { _ in true }) -> [Int] {
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
            let index = Int(indices[i])
            if accept(index) { result.append(index) }
            i += 1
        }
        return result
    }
}
