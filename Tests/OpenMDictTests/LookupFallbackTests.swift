import Testing
import Foundation
import NaturalLanguage
@testable import OpenMDict

// MARK: - Folding

@Suite struct LookupFoldingTests {

    @Test("Full-width ASCII and the ideographic space become ASCII")
    func widthFolding() {
        #expect(LookupFolding.widthFolded("ヨハネ３：１６") == "ヨハネ3:16")
        #expect(LookupFolding.widthFolded("ｊｏｈｎ　３：１６") == "john 3:16")
        #expect(LookupFolding.widthFolded("ＪＯＨＮ") == "JOHN")
        #expect(LookupFolding.widthFolded("约翰福音3:16") == "约翰福音3:16")
        // Half-width katakana and other compatibility forms are left alone.
        #expect(LookupFolding.widthFolded("ｶﾀｶﾅ") == "ｶﾀｶﾅ")
    }

    @Test("Latin: accents, macrons, breves and cedillas go; case folds")
    func latin() {
        #expect(LookupFolding.folded("Café") == "cafe")
        #expect(LookupFolding.folded("amō") == "amo")
        #expect(LookupFolding.folded("Ēheu") == "eheu")
        #expect(LookupFolding.folded("naïve") == "naive")
        #expect(LookupFolding.folded("façade") == "facade")
        #expect(LookupFolding.folded("Ăă") == "aa")
        #expect(LookupFolding.folded("İstanbul") == "istanbul")
        // A mark typed as a separate character goes too.
        #expect(LookupFolding.folded("cafe\u{301}") == "cafe")
    }

    @Test("Letters that are not marks stay")
    func distinctLetters() {
        #expect(LookupFolding.folded("Straße") == "straße")
        #expect(LookupFolding.folded("Øre") == "øre")
        #expect(LookupFolding.folded("Łódź") == "łodz")
        #expect(LookupFolding.folded("Đường") == "đuong")
        #expect(LookupFolding.folded("ıslak") == "ıslak")
        #expect(LookupFolding.folded("Æther") == "æther")
        // Kana voicing marks belong to their letters.
        #expect(LookupFolding.folded("がっこう") == "がっこう")
        #expect(LookupFolding.folded("がっこう") != "かっこう")
        #expect(LookupFolding.folded("≠") == "≠")
    }

    @Test("Greek: tonos, oxia, varia, perispomeni, breathings, diaeresis, iota subscript; final sigma")
    func greek() {
        #expect(LookupFolding.folded("Ἀθῆναι") == "αθηναι")
        #expect(LookupFolding.folded("ὁδός") == "οδοσ")
        #expect(LookupFolding.folded("ΟΔΟΣ") == "οδοσ")
        #expect(LookupFolding.folded("ᾄδω") == "αδω")
        #expect(LookupFolding.folded("ὰ") == "α")
        #expect(LookupFolding.folded("ϊ ΐ") == "ι ι")
        #expect(LookupFolding.folded("λόγος") == LookupFolding.folded("ΛΟΓΟΣ"))
    }

    @Test("Arabic: harakat and tatweel go, hamza and madda decompose")
    func arabic() {
        #expect(LookupFolding.folded("كِتَاب") == "كتاب")
        #expect(LookupFolding.folded("مُحَمَّد") == "محمد")
        #expect(LookupFolding.folded("كتـــاب") == "كتاب")
        #expect(LookupFolding.folded("أحمد") == "احمد")
        #expect(LookupFolding.folded("آمن") == "امن")
    }

    @Test("Full-width text folds too")
    func widthInFolded() {
        #expect(LookupFolding.folded("ＪＯＨＮ　３：１６") == "john 3:16")
    }

    /// The table-driven fold must agree with canonical decomposition for
    /// every character, and flag exactly the characters whose fold differs
    /// from their lowercase form.
    @Test("Every character folds as its canonical decomposition with the marks removed")
    func agreesWithDecomposition() {
        func reference(_ text: String) -> String {
            var scalars = String.UnicodeScalarView()
            for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars
            where !LookupFolding.isFoldedAway(scalar) {
                scalars.append(scalar)
            }
            let lowered = LookupFolding.widthFolded(String(scalars)).lowercased()
            return lowered.replacingOccurrences(of: "\u{03C2}", with: "\u{03C3}")
        }
        var mismatches: [String] = []
        for value in UInt32(0x80)...0x2FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(scalar)
            let expected = reference(text)
            if LookupFolding.folded(text) != expected
                || LookupFolding.foldsBeyondCase(text) != (expected != text.lowercased()) {
                mismatches.append(String(format: "U+%04X", value))
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20))")
    }

    @Test("The folded-key index holds only keys with marks, in folded order")
    func foldedIndex() {
        let keys = ["apple", "Ἀθῆναι", "café", "がっこう", "cafe", "ἀθῆναι", "Straße", "ＡＢＣ"]
        let index = FoldedKeyIndex.build(count: keys.count) { keys[$0] }
        #expect(index.indices.map { keys[Int($0)] } == ["ＡＢＣ", "café", "Ἀθῆναι", "ἀθῆναι"])
        #expect(index.matches("αθηναι", prefix: false) { keys[$0] } == [1, 5])
        #expect(index.matches("αθη", prefix: true) { keys[$0] } == [1, 5])
        #expect(index.matches("αθη", prefix: true, limit: 1) { keys[$0] } == [1])
        #expect(index.matches("caf", prefix: false) { keys[$0] }.isEmpty)
        #expect(FoldedKeyIndex.build(count: 2) { ["a", "b"][$0] }.indices.isEmpty)
    }
}

// MARK: - Inflection candidates

@Suite struct InflectionCandidateTests {

    @Test("English rules undo regular inflections")
    func englishRules() {
        func has(_ word: String, _ base: String) -> Bool {
            InflectionCandidates.englishRuleCandidates(word).contains(base)
        }
        #expect(has("books", "book"))
        #expect(has("watches", "watch"))
        #expect(has("makes", "make"))
        #expect(has("studies", "study"))
        #expect(has("walked", "walk"))
        #expect(has("loved", "love"))
        #expect(has("stopped", "stop"))
        #expect(has("carried", "carry"))
        #expect(has("walking", "walk"))
        #expect(has("making", "make"))
        #expect(has("running", "run"))
        #expect(has("dying", "die"))
        #expect(has("bigger", "big"))
        #expect(has("nicest", "nice"))
        #expect(has("happier", "happy"))
        #expect(has("happiest", "happy"))
        #expect(InflectionCandidates.englishRuleCandidates("hoping").first == "hope")
        #expect(InflectionCandidates.englishRuleCandidates("walking").first == "walk")
        #expect(InflectionCandidates.englishRuleCandidates("dying").first == "die")
        #expect(InflectionCandidates.englishRuleCandidates("glass").isEmpty)
        #expect(InflectionCandidates.englishRuleCandidates("o'clock").isEmpty)
    }

    @Test("German rules undo finite-verb endings and participles")
    func germanRules() {
        func first(_ word: String) -> String? { InflectionCandidates.germanRuleCandidates(word).first }
        func has(_ word: String, _ base: String) -> Bool {
            InflectionCandidates.germanRuleCandidates(word).contains(base)
        }
        #expect(first("machte") == "machen")
        #expect(first("spielten") == "spielen")
        #expect(first("machtest") == "machen")
        #expect(first("gehst") == "gehen")
        #expect(first("kommt") == "kommen")
        #expect(has("arbeitet", "arbeiten"))
        #expect(has("gewinnt", "gewinnen"))
        #expect(first("gemacht") == "machen")
        #expect(first("geredet") == "reden")
        #expect(first("gesehen") == "sehen")
        #expect(first("aufgemacht") == "aufmachen")
        #expect(has("wanderst", "wandern"))
        #expect(has("fährst", "fahren"))
        #expect(has("kleinen", "klein"))
    }

    @Test("German: strong and irregular verbs, with prefixes; noun plurals")
    func germanIrregular() {
        func first(_ word: String) -> String? { InflectionCandidates.germanRuleCandidates(word).first }
        func has(_ word: String, _ base: String) -> Bool {
            InflectionCandidates.germanRuleCandidates(word).contains(base)
        }
        #expect(first("ging") == "gehen")
        #expect(first("gingen") == "gehen")
        #expect(first("gegangen") == "gehen")
        #expect(first("ist") == "sein")
        #expect(first("wurde") == "werden")
        #expect(first("nimmt") == "nehmen")
        #expect(first("saßen") == "sitzen")
        #expect(first("dachtest") == "denken")
        #expect(first("aufgestanden") == "aufstehen")
        #expect(first("angefangen") == "anfangen")
        #expect(first("verstand") == "verstehen")
        #expect(first("erkannte") == "erkennen")
        #expect(has("Häuser", "haus"))
        #expect(has("Kindern", "kind"))
        #expect(has("Väter", "vater"))
        #expect(has("Tage", "tag"))
    }

    @Test("Candidates: the headword language decides; never the query itself; capped")
    func candidates() {
        // NLTagger lemmas (English and German lemmatization ship with the OS).
        #expect(InflectionCandidates.candidates(for: "walked", headwordLanguage: "EN").first == "walk")
        #expect(InflectionCandidates.candidates(for: "went", headwordLanguage: "en").first == "go")
        #expect(InflectionCandidates.candidates(for: "ging", headwordLanguage: "DE").first == "gehen")
        #expect(InflectionCandidates.candidates(for: "Häuser", headwordLanguage: "de").first?.lowercased() == "haus")
        #expect(InflectionCandidates.candidates(for: "looked up", headwordLanguage: "en").first == "look up")
        // Unknown language: Latin-script queries get English and German candidates.
        #expect(InflectionCandidates.candidates(for: "spielten", headwordLanguage: nil).contains("spielen"))
        #expect(InflectionCandidates.candidates(for: "walked", headwordLanguage: nil).first == "walk")
        // Other languages and scripts get none.
        #expect(InflectionCandidates.candidates(for: "mangé", headwordLanguage: "FR").isEmpty)
        #expect(InflectionCandidates.candidates(for: "ὁδοί", headwordLanguage: nil).isEmpty)
        #expect(InflectionCandidates.candidates(for: "走った", headwordLanguage: nil).isEmpty)
        #expect(InflectionCandidates.candidates(for: "3:16", headwordLanguage: nil).isEmpty)
        for word in ["walked", "Walk", "spielten", "xyzzyings", "fährst"] {
            let candidates = InflectionCandidates.candidates(for: word, headwordLanguage: nil)
            #expect(!candidates.contains { $0.lowercased() == word.lowercased() })
            #expect(candidates.count <= InflectionCandidates.maxCandidates)
            #expect(Set(candidates).count == candidates.count)
        }
    }
}

@Suite struct TaggerModelLoadingTests {

    @Test("Without waiting, the first tagging in a language loads its model in the background")
    func backgroundModelLoad() async throws {
        // French is tagged nowhere else in the tests.
        #expect(InflectionCandidates.taggerLemmas("mangé", language: .french, waitsForModel: false).isEmpty)
        var lemmas: [String] = []
        for _ in 0..<300 {
            lemmas = InflectionCandidates.taggerLemmas("mangé", language: .french, waitsForModel: false)
            if !lemmas.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(lemmas == ["manger"])
    }
}

// MARK: - Lookups (Tests/Fixtures/fallbacks.mdx, regenerated by make-fixture.py)

@Suite(.serialized)
struct LookupFallbackTests {

    nonisolated(unsafe) static var _reader: MDictReader?

    static var path: String {
        TestFixtures.fixturesDirectory.appendingPathComponent("fallbacks.mdx").path
    }

    static func reader() throws -> MDictReader {
        if let r = _reader { return r }
        let r = try MDictReader(path: path)
        _reader = r
        return r
    }

    static func keys(_ entries: [MDictWordEntry]) -> [String] { entries.map(\.key) }

    @Test("A direct hit uses no fallback and returns no folded neighbours")
    func directHit() throws {
        let reader = try Self.reader()
        let entries = reader.lookupAll("resume")
        #expect(Self.keys(entries) == ["resume"])
        #expect(entries.allSatisfy { $0.fallback == nil })
        #expect(reader.lookup("WALK")?.fallback == nil)
        #expect(reader.lookup("booke")?.key == "booke")
        #expect(reader.lookup("booke")?.fallback == nil)
    }

    @Test("Full-width verse references find their ASCII keys")
    func widthFallback() throws {
        let reader = try Self.reader()
        let ja = try #require(reader.lookup("ヨハネ３：１６"))
        #expect(ja.key == "ヨハネ3:16")
        #expect(ja.fallback == .widthFolded)
        #expect(reader.lookup("约翰福音３：１６")?.key == "约翰福音3:16")
        #expect(reader.lookup("ｊｏｈｎ　３：１６")?.key == "John 3:16")
        // The ideographic space becomes a space; that key redirects.
        #expect(reader.lookup("ヨハネ　３：１６")?.key == "ヨハネ3:16")
    }

    @Test("Queries without diacritics find keys with them, and the reverse")
    func diacriticFallback() throws {
        let reader = try Self.reader()
        let athens = try #require(reader.lookup("αθηναι"))
        #expect(athens.key == "Ἀθῆναι")
        #expect(athens.fallback == .diacriticInsensitive)
        #expect(reader.lookup("ΟΔΟΣ")?.key == "ὁδός")
        #expect(reader.lookup("οδος")?.key == "ὁδός")
        #expect(reader.lookup("αδω")?.key == "ᾄδω")
        #expect(reader.lookup("amo")?.key == "amō")
        #expect(reader.lookup("Cafe")?.key == "café")
        #expect(reader.lookup("cafè")?.key == "café")
        #expect(reader.lookup("كتاب")?.key == "كِتَاب")
        #expect(reader.lookup("احمد")?.key == "أحمد")
        // Every key that folds the same, in dictionary order.
        #expect(Self.keys(reader.lookupAll("resumé")).sorted() == ["resume", "résumé"])
    }

    @Test("Letters that are not marks do not fold to other keys")
    func distinctLettersDoNotMatch() throws {
        let reader = try Self.reader()
        #expect(reader.lookup("strasse") == nil)
        #expect(reader.lookup("ore") == nil)
        #expect(reader.lookup("lodz") == nil)
        #expect(reader.lookup("łodz")?.key == "łódź")
    }

    @Test("Inflected English and German forms find their base forms")
    func inflectionFallback() throws {
        let reader = try Self.reader()
        let walked = try #require(reader.lookup("walked", headwordLanguage: "EN"))
        #expect(walked.key == "walk")
        #expect(walked.fallback == .inflection(lemma: "walk"))
        #expect(reader.lookup("studies", headwordLanguage: "EN")?.key == "study")
        #expect(reader.lookup("stopped", headwordLanguage: "EN")?.key == "stop")
        #expect(reader.lookup("making", headwordLanguage: "EN")?.key == "make")
        #expect(reader.lookup("biggest", headwordLanguage: "EN")?.key == "big")
        #expect(reader.lookup("went", headwordLanguage: "EN")?.key == "go")
        #expect(reader.lookup("ging", headwordLanguage: "DE")?.key == "gehen")
        #expect(reader.lookup("machte", headwordLanguage: "DE")?.key == "machen")
        #expect(reader.lookup("gespielt", headwordLanguage: "DE")?.key == "spielen")
        #expect(reader.lookup("aufgemacht", headwordLanguage: "DE")?.key == "aufmachen")
        #expect(reader.lookup("Häuser", headwordLanguage: "DE")?.key == "Haus")
        // Without a known language, the query's script decides.
        #expect(reader.lookup("walked")?.key == "walk")
        #expect(reader.lookup("spielten")?.key == "spielen")
        // A dictionary of another language does not try English or German forms.
        #expect(reader.lookup("walked", headwordLanguage: "FR") == nil)
    }

    @Test("Fallbacks run in order: width, then diacritics, then inflection")
    func fallbackOrder() throws {
        let reader = try Self.reader()
        // "bookes" folds to the key "bóokes" and is also an inflection of "booke".
        let entry = try #require(reader.lookup("bookes", headwordLanguage: "EN"))
        #expect(entry.key == "bóokes")
        #expect(entry.fallback == .diacriticInsensitive)
        #expect(reader.lookup("ｂｏｏｋｅ")?.fallback == .widthFolded)
        #expect(reader.lookup("nothing-like-this") == nil)
        #expect(reader.lookupAll("").isEmpty)
    }

    @Test("Prefix search falls back to width and diacritic folding only when it finds nothing")
    func prefixSearch() throws {
        let reader = try Self.reader()
        #expect(reader.search(prefix: "αθην") == ["Ἀθῆναι"])
        #expect(reader.search(prefix: "ΟΔΟ") == ["ὁδός"])
        #expect(reader.search(prefix: "ヨハネ３") == ["ヨハネ3:16"])
        #expect(reader.search(prefix: "ヨハネ　") == ["ヨハネ 3:16"])
        #expect(reader.search(prefix: "ｊｏｈ") == ["John 3:16"])
        #expect(reader.search(prefix: "كتا") == ["كِتَاب"])
        // Plain matches exist: no folded keys are added.
        #expect(reader.search(prefix: "resu") == ["resume"])
        #expect(reader.search(prefix: "rés") == ["résumé"])
        #expect(reader.search(prefix: "res") == ["resume"])
        #expect(reader.search(prefix: "resúm").sorted() == ["resume", "résumé"])
        #expect(reader.search(prefix: "zzz").isEmpty)
    }

    @Test("Without index builds, a miss builds the folded index in the background")
    func backgroundIndexBuild() async throws {
        let reader = try MDictReader(path: Self.path)
        // Keys without marks are found before the index exists.
        #expect(reader.lookup("ＷＡＬＫ", waitsForSetup: false)?.key == "walk")
        // The first miss that needs the index starts building it.
        _ = reader.lookupAll("αθηναι", waitsForSetup: false)
        var found: MDictWordEntry?
        for _ in 0..<200 {
            found = reader.lookup("αθηναι", waitsForSetup: false)
            if found != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(found?.key == "Ἀθῆναι")
        #expect(reader.search(prefix: "αθη", waitsForSetup: false) == ["Ἀθῆναι"])
    }
}
