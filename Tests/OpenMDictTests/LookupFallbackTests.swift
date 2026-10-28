import Testing
import Foundation
import NaturalLanguage
@testable import OpenMDict

/// Whether this host has NLTagger's lemma model for `language`; the
/// expectations that need one are gated on it, so the suite passes where a
/// model is missing (the rules still work there).
func hasLemmaModel(_ language: NLLanguage) -> Bool {
    NLTagger.availableTagSchemes(for: .word, language: language).contains(.lemma)
}

// MARK: - Folding

@Suite struct LookupFoldingTests {

    @Test("Full-width ASCII and the ideographic space become ASCII")
    func widthFolding() {
        #expect(LookupFolding.widthFolded("ヨハネ３：１６") == "ヨハネ3:16")
        #expect(LookupFolding.widthFolded("ｊｏｈｎ　３：１６") == "john 3:16")
        #expect(LookupFolding.widthFolded("ＪＯＨＮ") == "JOHN")
        #expect(LookupFolding.widthFolded("约翰福音3:16") == "约翰福音3:16")
    }

    @Test("Half-width katakana and ligatures become their ordinary characters")
    func compatibilityForms() {
        #expect(LookupFolding.widthFolded("ｶﾀｶﾅ") == "カタカナ")
        #expect(LookupFolding.widthFolded("ｺｰﾋｰ") == "コーヒー")
        // The half-width voicing mark composes with its letter.
        #expect(LookupFolding.widthFolded("ｶﾞｯｺｰ") == "ガッコー")
        #expect(LookupFolding.widthFolded("ﬁnd ﬂower ofﬁce") == "find flower office")
        #expect(LookupFolding.widthFolded("ﬀ ﬃ ﬄ") == "ff ffi ffl")
        #expect(LookupFolding.widthFolded("￥１００") == "¥100")
        // Other compatibility characters are left alone: no general NFKC.
        #expect(LookupFolding.widthFolded("①²ſ") == "①²ſ")
        #expect(LookupFolding.folded("ﬁnd") == "find")
        #expect(LookupFolding.folded("ｺｰﾋｰ") == "コーヒー")
        #expect(LookupFolding.foldsBeyondCase("ﬁnd"))
        #expect(LookupFolding.foldsBeyondCase("ｺｰﾋｰ"))
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
        // Marks of the extension blocks.
        #expect(LookupFolding.folded("a\u{1DC4}") == "a")
        #expect(LookupFolding.folded("e\u{1AB0}") == "e")
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
        // Decomposed kana and conjoining jamo compose into their letters
        // and syllables — compared by scalars, which == does not
        // distinguish from the decomposed forms.
        #expect(Array(LookupFolding.folded("\u{304B}\u{3099}っこう").unicodeScalars) == Array("がっこう".unicodeScalars))
        #expect(Array(LookupFolding.folded("\u{1112}\u{1161}\u{11AB}").unicodeScalars) == Array("한".unicodeScalars))
        #expect(Array(LookupFolding.folded("\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}").unicodeScalars)
                == Array("한국".unicodeScalars))
        #expect(LookupFolding.folded("≠") == "≠")
    }

    @Test("Cyrillic: й ў ї ѓ ќ ѝ are letters; ё and stress accents fold")
    func cyrillic() {
        for letter in ["й", "Й", "ў", "Ў", "ї", "Ї", "ѓ", "Ѓ", "ќ", "Ќ", "ѝ", "Ѝ"] {
            #expect(LookupFolding.folded(letter) == letter.lowercased(), "\(letter)")
            #expect(!LookupFolding.foldsBeyondCase(letter), "\(letter)")
        }
        #expect(LookupFolding.folded("Индии") != LookupFolding.folded("индий"))
        #expect(LookupFolding.folded("войн") != LookupFolding.folded("воин"))
        #expect(LookupFolding.folded("ещё") == "еще")
        #expect(LookupFolding.folded("Ёлка") == "елка")
        #expect(LookupFolding.folded("за́йка") == "зайка")
        #expect(LookupFolding.folded("сто̀й") == "стой")
        // A breve typed separately composes into й first and stays; an
        // acute typed on a vowel has no letter to compose into and goes.
        #expect(LookupFolding.folded("за\u{0438}\u{0306}ка") == "зайка")
        #expect(LookupFolding.folded("з\u{0430}\u{0301}йка") == "зайка")
        #expect(LookupFolding.folded("e\u{0301}") == "e")
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

    @Test("Arabic: harakat and tatweel go, hamza and madda only on alef")
    func arabic() {
        #expect(LookupFolding.folded("كِتَاب") == "كتاب")
        #expect(LookupFolding.folded("مُحَمَّد") == "محمد")
        #expect(LookupFolding.folded("كتـــاب") == "كتاب")
        #expect(LookupFolding.folded("أحمد") == "احمد")
        #expect(LookupFolding.folded("إن") == "ان")
        #expect(LookupFolding.folded("آمن") == "امن")
        #expect(LookupFolding.folded("هٰذَا") == "هذا")
        // Hamza on waw and yeh makes other letters: ؤ ئ stay.
        #expect(LookupFolding.folded("ؤ") == "ؤ")
        #expect(LookupFolding.folded("ئ") == "ئ")
        #expect(LookupFolding.folded("فئة") != LookupFolding.folded("فيه"))
        #expect(LookupFolding.folded("رؤس") != LookupFolding.folded("روس"))
        #expect(!LookupFolding.foldsBeyondCase("ؤ"))
        #expect(!LookupFolding.foldsBeyondCase("ئ"))
        // A hamza typed separately composes with its letter and stays too.
        #expect(LookupFolding.folded("و\u{0654}") == "ؤ")
        #expect(LookupFolding.folded("ى") == "ى")
        #expect(LookupFolding.folded("ة") == "ة")
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
        func reference(_ scalar: Unicode.Scalar) -> String {
            let text = String(scalar)
            if LookupFolding.isKeptWhole(scalar) { return text.lowercased() }
            if LookupFolding.isAlefWithMark(scalar) { return "\u{0627}" }
            let decomposed = text.decomposedStringWithCanonicalMapping.unicodeScalars
            var kept = String.UnicodeScalarView()
            for part in decomposed where !LookupFolding.isFoldedAway(part) { kept.append(part) }
            let stripped = decomposed.contains(where: LookupFolding.isFoldedAway)
                ? String(kept).precomposedStringWithCanonicalMapping : text
            return stripped.lowercased().replacingOccurrences(of: "\u{03C2}", with: "\u{03C3}")
        }
        var mismatches: [String] = []
        for value in UInt32(0x80)...0x2FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(scalar)
            // Compatibility forms are folded first; what they map to is then
            // folded character by character (U+FFE3 maps to a space and a
            // combining macron).
            let expected = LookupFolding.widthFolded(text).unicodeScalars.map(reference).joined()
            if LookupFolding.folded(text) != expected
                || LookupFolding.foldsBeyondCase(text) != (expected != text.lowercased()) {
                mismatches.append(String(format: "U+%04X", value))
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20))")
    }

    @Test("The marks typed in a query must be on the key")
    func markPattern() {
        func admits(_ query: String, _ key: String, prefix: Bool = false) -> Bool {
            LookupFolding.MarkPattern(query).admits(key, prefix: prefix)
        }
        #expect(LookupFolding.MarkPattern("Muller").marked == [false, false, false, false, false, false])
        #expect(!LookupFolding.MarkPattern("Muller").hasMarks)
        #expect(LookupFolding.MarkPattern("cafè").marked == [false, false, false, true])
        #expect(LookupFolding.MarkPattern("cafe\u{300}").marked == [false, false, false, true])
        // Marks the query lacks are wildcards; marks it has must be matched.
        #expect(admits("Muller", "Müller"))
        #expect(admits("cafè", "café"))
        #expect(admits("resumé", "résumé"))
        #expect(!admits("resumé", "resume"))
        #expect(!admits("è", "e"))
        #expect(!admits("está", "esta"))
        #expect(!admits("tenía", "tenia"))
        #expect(!admits("χωριά", "χώρια"))
        #expect(admits("χωρια", "χώρια"))
        #expect(!admits("çök", "çok"))
        #expect(!admits("dönmüş", "donmuş"))
        #expect(!admits("uñas", "unas"))
        #expect(admits("ΟΔΟΣ", "ὁδός"))
        // Prefixes: the marks of the typed part must match.
        #expect(admits("wä", "wären", prefix: true))
        #expect(!admits("wä", "Waren", prefix: true))
        #expect(admits("résum", "résumé", prefix: true))
        #expect(!admits("resúm", "résumé", prefix: true))
        // Reading aids are not typed marks: stress accents, harakat, hamza on alef.
        #expect(!LookupFolding.MarkPattern("за́йка").hasMarks)
        #expect(admits("за́йка", "зайка"))
        #expect(!LookupFolding.MarkPattern("مُحَمَّد").hasMarks)
        #expect(admits("مُحَمَّد", "محمد"))
        #expect(admits("أحمد", "احمد"))
        // ё and the Greek and Latin accents are.
        #expect(LookupFolding.MarkPattern("ещё").hasMarks)
        #expect(!admits("ещё", "еще"))
        #expect(admits("еще", "ещё"))
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
        // `accept` filters before the limit counts.
        #expect(index.matches("αθη", prefix: true, limit: 1, keyAt: { keys[$0] }, accept: { $0 == 5 }) == [5])
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
        // A two-letter stem gets its e back first: hued → hue, not hu.
        #expect(InflectionCandidates.englishRuleCandidates("hued").first == "hue")
        #expect(InflectionCandidates.englishRuleCandidates("hued").contains("hu"))
        // Names are no comparatives.
        #expect(InflectionCandidates.englishRules("Oliver").loose.isEmpty)
        #expect(InflectionCandidates.englishRules("Chester").loose.isEmpty)
        #expect(InflectionCandidates.englishRules("oliver").loose.contains("olive"))
        #expect(InflectionCandidates.englishRules("Parked").likely.contains("park"))
    }

    @Test("German rules undo finite-verb endings and participles")
    func germanRules() {
        func first(_ word: String) -> String? { InflectionCandidates.germanRuleCandidates(word).first }
        func has(_ word: String, _ base: String) -> Bool {
            InflectionCandidates.germanRuleCandidates(word).contains(base)
        }
        #expect(has("machte", "machen"))
        #expect(first("spielten") == "spielen")
        #expect(has("machtest", "machen"))
        #expect(first("gehst") == "gehen")
        #expect(first("kommt") == "kommen")
        #expect(first("sagt") == "sagen")
        #expect(first("arbeitet") == "arbeiten")
        #expect(has("gewinnt", "gewinnen"))
        #expect(first("gemacht") == "machen")
        #expect(first("geredet") == "reden")
        #expect(first("gesehen") == "sehen")
        #expect(first("aufgemacht") == "aufmachen")
        #expect(has("wanderst", "wandern"))
        #expect(has("fährst", "fahren"))
        #expect(has("kleinen", "klein"))
        // Weak preterites of stems in t/d.
        for form in ["wartete", "warteten", "wartetest", "wartetet"] {
            #expect(first(form) == "warten", "\(form)")
        }
        #expect(first("arbeitete") == "arbeiten")
        #expect(first("redete") == "reden")
        // A stem in t/d comes before the shorter stem a longer ending leaves.
        #expect(first("kostet") == "kosten")
        #expect(first("hafte") == "haften")
        #expect(first("wartet") == "warten")
        #expect(first("rastet") == "rasten")
        // The umlaut-strip rule for strong verbs the table lacks.
        #expect(has("gräbt", "graben"))
        #expect(has("stößt", "stoßen"))
    }

    @Test("Comparatives and adjective and noun stems are loose candidates, verb forms likely ones")
    func tiers() {
        #expect(InflectionCandidates.englishRules("walked").likely.contains("walk"))
        #expect(InflectionCandidates.englishRules("bigger").loose.contains("big"))
        #expect(!InflectionCandidates.englishRules("bigger").likely.contains("big"))
        #expect(InflectionCandidates.germanRules("machte").likely.contains("machen"))
        #expect(InflectionCandidates.germanRules("muller").loose.contains("mull"))
        #expect(!InflectionCandidates.germanRules("muller").likely.contains("mull"))
        let ranked = InflectionCandidates.rankedCandidates(for: "blorpier", headwordLanguage: "EN")
        #expect(ranked.likely.isEmpty && ranked.loose.first == "blorpy")
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
        #expect(first("kann") == "können")
        #expect(first("dachte") == "denken")
        #expect(first("waren") == "sein")
        #expect(has("Häuser", "haus"))
        #expect(has("Kindern", "kind"))
        #expect(has("Väter", "vater"))
        #expect(has("Tage", "tag"))
    }

    @Test("A capitalised German word is a noun: stems first, -n before -en, no preterites")
    func capitalisedGerman() {
        func candidates(_ word: String) -> [String] { InflectionCandidates.germanRuleCandidates(word) }
        let rules = InflectionCandidates.germanRules("Waren")
        #expect(rules.likely.isEmpty)
        #expect(rules.loose.first == "ware")
        #expect(!rules.loose.contains("sein"))
        #expect(candidates("waren").first == "sein")
        #expect(candidates("Gaben").first == "gabe")
        #expect(!candidates("Gaben").contains("geben"))
        #expect(candidates("Boten").first == "bote")
        #expect(candidates("Seiten").first == "seite")
        #expect(candidates("Kammern").first == "kammer")
        #expect(candidates("Kindern").contains("kind"))
        #expect(candidates("Wege").first == "weg")
        // The ge…en participle rule is skipped, ge…t is not.
        #expect(!candidates("Gerichten").contains("richten"))
        #expect(candidates("Gerichten").contains("gericht"))
        #expect(candidates("gerichten").contains("richten"))
        #expect(candidates("Gemacht").contains("machen"))
        // Participles and present forms of the table still count.
        #expect(candidates("Gegangen").contains("gehen"))
        #expect(candidates("Ist").contains("sein"))
        #expect(InflectionCandidates.isCapitalised("Häuser"))
        #expect(!InflectionCandidates.isCapitalised("HÄUSER"))
        #expect(!InflectionCandidates.isCapitalised("häuser"))
        #expect(!InflectionCandidates.isCapitalised("H"))
    }

    @Test("The German lemma model's transliterations are undone")
    func transliterations() {
        #expect(InflectionCandidates.germanTransliterationsUndone("koennen") == ["koennen", "können"])
        #expect(InflectionCandidates.germanTransliterationsUndone("muessen") == ["muessen", "müssen", "müßen"])
        #expect(InflectionCandidates.germanTransliterationsUndone("Haeuser") == ["Haeuser", "Häuser"])
        #expect(InflectionCandidates.germanTransliterationsUndone("gehen") == ["gehen"])
        #expect(InflectionCandidates.germanTransliterationsUndone("können") == ["können"])
    }

    @Test("Candidates: the headword language decides; never the query itself; capped")
    func candidates() {
        func candidates(_ word: String, _ language: String?) -> [String] {
            InflectionCandidates.candidates(for: word, headwordLanguage: language)
        }
        // The rules give these whether or not NLTagger has a model.
        #expect(candidates("walked", "EN").first == "walk")
        #expect(candidates("ging", "DE").first == "gehen")
        #expect(candidates("Häuser", "de").contains { $0.lowercased() == "haus" })
        #expect(candidates("spielten", nil).contains("spielen"))
        #expect(candidates("walked", nil).first == "walk")
        // ISO 639-2 codes.
        #expect(InflectionCandidates.languages(for: "x", headwordLanguage: "deu") == [.german])
        #expect(InflectionCandidates.languages(for: "x", headwordLanguage: "ger") == [.german])
        #expect(InflectionCandidates.languages(for: "x", headwordLanguage: "eng") == [.english])
        #expect(InflectionCandidates.languages(for: "x", headwordLanguage: "en-US") == [.english])
        #expect(InflectionCandidates.languages(for: "x", headwordLanguage: "fr").isEmpty)
        // NLTagger lemmas, where the system has the models.
        if hasLemmaModel(.english) {
            #expect(candidates("went", "en").first == "go")
            #expect(candidates("looked up", "en").first == "look up")
        }
        if hasLemmaModel(.german) {
            #expect(candidates("Häuser", "de").first?.lowercased() == "haus")
            // The rules still run after the tagger: its lemma for "dachte"
            // is wrong on some systems, the table's never.
            #expect(candidates("dachte", "de").contains("denken"))
            #expect(candidates("kann", "de").contains("können"))
        }
        // A form that differs only by diacritics is no inflection.
        #expect(!candidates("resumé", "EN").contains("résumé"))
        // Other languages and scripts get none.
        #expect(candidates("mangé", "FR").isEmpty)
        #expect(candidates("ὁδοί", nil).isEmpty)
        #expect(candidates("走った", nil).isEmpty)
        #expect(candidates("3:16", nil).isEmpty)
        for word in ["walked", "Walk", "spielten", "xyzzyings", "fährst", "Waren"] {
            let candidates = candidates(word, nil)
            #expect(!candidates.contains { LookupFolding.folded($0) == LookupFolding.folded(word) })
            #expect(candidates.count <= InflectionCandidates.maxCandidates)
            #expect(Set(candidates).count == candidates.count)
        }
    }

    @Test("Very long queries get no candidates and never crash the tagger")
    func longQueries() {
        let letters = String(repeating: "a", count: 70_000)
        #expect(InflectionCandidates.candidates(for: letters, headwordLanguage: "EN").isEmpty)
        #expect(InflectionCandidates.candidates(for: letters, headwordLanguage: nil).isEmpty)
        let sentence = String(repeating: "the dog walked home ", count: 3600)
        #expect(InflectionCandidates.candidates(for: sentence, headwordLanguage: "EN").isEmpty)
        #expect(InflectionCandidates.taggerLemmas(sentence, language: .english).isEmpty)
        #expect(InflectionCandidates.taggerLemmas(letters, language: .german).isEmpty)
        // Just over the query cap, still no candidates; under it, the usual ones.
        let justOver = String(repeating: "walked ", count: 15)
        #expect(justOver.count > InflectionCandidates.maxQueryLength)
        #expect(InflectionCandidates.candidates(for: justOver, headwordLanguage: "EN").isEmpty)
        #expect(!InflectionCandidates.candidates(for: "walked walked", headwordLanguage: "EN").isEmpty)
    }
}

@Suite struct TaggerModelLoadingTests {

    @Test("Without waiting, the first tagging in a language loads its model in the background")
    func backgroundModelLoad() async throws {
        // French is tagged nowhere else in the tests.
        #expect(InflectionCandidates.taggerLemmas("mangé", language: .french, waitsForModel: false).isEmpty)
        guard hasLemmaModel(.french) else { return }
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

extension SidecarCacheSuites {

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
        #expect(reader.lookup("Mächte")?.key == "Mächte")
        #expect(reader.lookup("Mächte")?.fallback == nil)
    }

    @Test("Whitespace and decomposed characters are no fallback: the trimmed, composed query is direct")
    func trimmedAndComposedQueries() throws {
        let reader = try Self.reader()
        for query in ["walk ", " walk", "\twalk", "walk\n", "walk\u{3000}"] {
            let entry = try #require(reader.lookup(query), "\(query)")
            #expect(entry.key == "walk", "\(query)")
            #expect(entry.fallback == nil, "\(query)")
        }
        // NFD text (file names, PDFs) finds composed keys directly.
        #expect(reader.lookup("cafe\u{301}")?.fallback == nil)
        #expect(reader.lookup("cafe\u{301}")?.key == "café")
        // Decomposed Hangul orders after the keys 한국 sorts before (한국
        // 사람, 한국어) in Swift's String ordering: the binary search only
        // finds 한국 when the query is composed first.
        let hangul = reader.lookup("\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}")
        #expect(hangul?.key == "한국")
        #expect(hangul?.fallback == nil)
        let hangulWord = reader.lookup("\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}\u{110B}\u{1165}")
        #expect(hangulWord?.key == "한국어")
        #expect(hangulWord?.fallback == nil)
        let kana = reader.lookup("\u{304B}\u{3099}っこう")
        #expect(kana?.key == "がっこう")
        #expect(kana?.fallback == nil)
        #expect(reader.search(prefix: "\u{1112}\u{1161}\u{11AB}") == ["한국", "한국 사람", "한국어"])
        #expect(reader.lookupAll("   ").isEmpty)
    }

    @Test("Full-width verse references and compatibility forms find their ordinary keys")
    func widthFallback() throws {
        let reader = try Self.reader()
        let ja = try #require(reader.lookup("ヨハネ３：１６"))
        #expect(ja.key == "ヨハネ3:16")
        #expect(ja.fallback == .widthFolded)
        #expect(reader.lookup("约翰福音３：１６")?.key == "约翰福音3:16")
        #expect(reader.lookup("ｊｏｈｎ　３：１６")?.key == "John 3:16")
        // The ideographic space becomes a space; that key redirects.
        #expect(reader.lookup("ヨハネ　３：１６")?.key == "ヨハネ3:16")
        // Trailing ideographic space: still the width fallback, not diacritics.
        #expect(reader.lookup("ヨハネ３：１６　")?.fallback == .widthFolded)
        // Ligatures and half-width katakana.
        #expect(reader.lookup("ﬁnd")?.key == "find")
        #expect(reader.lookup("ﬁnd")?.fallback == .widthFolded)
        #expect(reader.lookup("ofﬁce")?.key == "office")
        #expect(reader.lookup("ｺｰﾋｰ")?.key == "コーヒー")
        #expect(reader.lookup("ｺｰﾋｰ")?.fallback == .widthFolded)
        #expect(reader.search(prefix: "ｺｰ") == ["コーヒー"])
    }

    @Test("Queries without diacritics find keys with them")
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
        #expect(reader.lookup("كتاب")?.key == "كِتَاب")
        #expect(reader.lookup("احمد")?.key == "أحمد")
        #expect(reader.lookup("هذا")?.key == "هٰذَا")
        #expect(reader.lookup("χωρια")?.key == "χώρια")
        // With the other apostrophe, too.
        #expect(reader.lookup("l’ecole")?.key == "l'école")
        #expect(reader.lookup("l’ecole")?.fallback == .diacriticInsensitive)
    }

    @Test("A mark the user typed must be on the key letter; marks the query lacks are wildcards")
    func typedMarksConstrainMatches() throws {
        let reader = try Self.reader()
        // Accepted: a different mark on the same letter, or no mark at all.
        #expect(reader.lookup("cafè")?.key == "café")
        #expect(reader.lookup("cafè")?.fallback == .diacriticInsensitive)
        #expect(reader.lookup("Muller")?.key == "Müller")
        let resume = reader.lookupAll("resumé")
        #expect(Self.keys(resume) == ["résumé"])
        #expect(resume.first?.fallback == .diacriticInsensitive)
        // Rejected: the key has no mark where the query has one.
        for query in ["è", "está", "tenía", "χωριά", "çök", "dönmüş", "uñas"] {
            #expect(reader.lookup(query) == nil, "\(query)")
            #expect(reader.lookup(query, headwordLanguage: "ES") == nil, "\(query)")
        }
        // The keys those would wrongly have found are there.
        for key in ["e", "esta", "tenia", "χώρια", "çok", "donmuş", "unas"] {
            #expect(reader.lookup(key)?.fallback == nil, "\(key)")
        }
        // Prefix search follows the same rule.
        #expect(reader.search(prefix: "resúm").isEmpty)
        #expect(reader.search(prefix: "résum") == ["résumé"])
        #expect(reader.search(prefix: "tení").isEmpty)
        #expect(reader.search(prefix: "χωριά").isEmpty)
        #expect(reader.search(prefix: "χωρια") == ["χώρια"])
        #expect(reader.search(prefix: "ΧΩΡ") == ["χώρια"])
    }

    @Test("Letters that are not marks do not fold to other keys")
    func distinctLettersDoNotMatch() throws {
        let reader = try Self.reader()
        #expect(reader.lookup("strasse") == nil)
        #expect(reader.lookup("ore") == nil)
        #expect(reader.lookup("lodz") == nil)
        #expect(reader.lookup("łodz")?.key == "łódź")
        // Cyrillic й is a letter; stress accents and ё fold.
        #expect(reader.lookup("Индии", headwordLanguage: "RU") == nil)
        #expect(reader.lookup("за́йка", headwordLanguage: "RU")?.key == "зайка")
        #expect(reader.lookup("зайка")?.fallback == nil)
        #expect(reader.lookup("еще")?.key == "ещё")
        #expect(reader.lookup("ещё")?.fallback == nil)
        // Arabic hamza on yeh is a letter; harakat are reading aids.
        #expect(reader.lookup("فيه", headwordLanguage: "AR") == nil)
        #expect(reader.lookup("مُحَمَّد")?.key == "محمد")
        #expect(reader.lookup("مُحَمَّد")?.fallback == .diacriticInsensitive)
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
        #expect(reader.lookup("hued", headwordLanguage: "EN")?.key == "hue")
        if hasLemmaModel(.english) {
            #expect(reader.lookup("went", headwordLanguage: "EN")?.key == "go")
        }
        #expect(reader.lookup("ging", headwordLanguage: "DE")?.key == "gehen")
        #expect(reader.lookup("machte", headwordLanguage: "DE")?.key == "machen")
        #expect(reader.lookup("gespielt", headwordLanguage: "DE")?.key == "spielen")
        #expect(reader.lookup("aufgemacht", headwordLanguage: "DE")?.key == "aufmachen")
        #expect(reader.lookup("Häuser", headwordLanguage: "DE")?.key == "Haus")
        #expect(reader.lookup("gräbt", headwordLanguage: "DE")?.key == "graben")
        #expect(reader.lookup("wartete", headwordLanguage: "DE")?.key == "warten")
        // The table's irregular bases hold even where the lemma model
        // errs or transliterates (dachte → dachen, kann → koennen).
        #expect(reader.lookup("dachte", headwordLanguage: "DE")?.key == "denken")
        #expect(reader.lookup("kann", headwordLanguage: "DE")?.key == "können")
        #expect(reader.lookup("konnte", headwordLanguage: "DE")?.key == "können")
        // A word no model knows goes through the rules end to end.
        #expect(reader.lookup("blorpte", headwordLanguage: "DE")?.key == "blorpen")
        #expect(reader.lookup("blorpte", headwordLanguage: "DE")?.fallback == .inflection(lemma: "blorpen"))
        #expect(reader.lookup("blorpte", headwordLanguage: "deu")?.key == "blorpen")
        // Capitalised German words are nouns, not preterites or participles.
        #expect(reader.lookup("Waren", headwordLanguage: "DE")?.key == "Ware")
        #expect(reader.lookup("waren", headwordLanguage: "DE")?.key == "sein")
        #expect(reader.lookup("Seiten", headwordLanguage: "DE")?.key == "Seite")
        #expect(reader.lookup("Gerichten", headwordLanguage: "DE")?.key == "Gericht")
        // Names are no comparatives.
        #expect(reader.lookup("Oliver", headwordLanguage: "EN") == nil)
        #expect(reader.lookup("oliver", headwordLanguage: "EN")?.key == "olive")
        // Without a known language, the query's script decides.
        #expect(reader.lookup("walked")?.key == "walk")
        #expect(reader.lookup("spielten")?.key == "spielen")
        // A dictionary of another language does not try English or German forms.
        #expect(reader.lookup("walked", headwordLanguage: "FR") == nil)
        // Nor does a lookup limited to direct or width matches.
        #expect(reader.lookup("walked", headwordLanguage: "EN", fallbacks: .none) == nil)
        #expect(reader.lookup("walked", headwordLanguage: "EN", fallbacks: .width) == nil)
        #expect(reader.lookup("ｗａｌｋ", fallbacks: .width)?.fallback == .widthFolded)
        #expect(reader.lookup("ｗａｌｋ", fallbacks: .none) == nil)
        #expect(reader.lookup("WALK", fallbacks: .none)?.key == "walk")
        #expect(reader.lookup("Muller", headwordLanguage: "DE", fallbacks: .width) == nil)
    }

    @Test("Fallbacks run in order: width, then inflection, then diacritics, then loose stems")
    func fallbackOrder() throws {
        let reader = try Self.reader()
        // "machte" is a form of "machen" and folds to the key "Mächte":
        // inflection comes first.
        for language in ["DE", nil] {
            let entries = reader.lookupAll("machte", headwordLanguage: language)
            #expect(Self.keys(entries) == ["machen"])
            #expect(entries.allSatisfy { $0.fallback == .inflection(lemma: "machen") })
        }
        // Diacritic folding finds "Müller" for "Muller" before the loose
        // noun stem "Mull" is tried.
        for language in ["DE", nil] {
            let entry = try #require(reader.lookup("Muller", headwordLanguage: language))
            #expect(entry.key == "Müller")
            #expect(entry.fallback == .diacriticInsensitive)
        }
        // A loose stem is tried last: "blorpier" → "blorpy".
        let loose = try #require(reader.lookup("blorpier", headwordLanguage: "EN"))
        #expect(loose.key == "blorpy")
        #expect(loose.fallback == .inflection(lemma: "blorpy"))
        // A dictionary of another language skips inflection, not diacritics.
        #expect(reader.lookup("machte", headwordLanguage: "FR")?.key == "Mächte")
        #expect(reader.lookup("machte", headwordLanguage: "FR")?.fallback == .diacriticInsensitive)
        // Width folding comes before both.
        #expect(reader.lookup("ｍａｃｈｅｎ")?.fallback == .widthFolded)
        #expect(reader.lookup("ｍａｃｈｔｅ", headwordLanguage: "DE")?.fallback == .inflection(lemma: "machen"))
        #expect(reader.lookup("ＭＵＬＬＥＲ", headwordLanguage: "DE")?.key == "Müller")
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
        #expect(reader.search(prefix: "zzz").isEmpty)
        // Prefix search has no inflection step: width, then diacritics.
        #expect(reader.search(prefix: "Mull") == ["Mull"])
        #expect(reader.search(prefix: "Mulle") == ["Müller"])
        #expect(reader.search(prefix: "ｍｕｌ") == ["Mull"])
        #expect(reader.search(prefix: "ｍｕｌｌｅ") == ["Müller"])
        #expect(reader.search(prefix: "macht") == ["Mächte"])
        #expect(reader.search(prefix: "mach") == ["machen"])
        // The fallback that found the keys is reported; a direct search can be asked for.
        #expect(reader.searchWithFallback(prefix: "Mulle").fallback == .diacriticInsensitive)
        #expect(reader.searchWithFallback(prefix: "ｍｕｌ").fallback == .widthFolded)
        #expect(reader.searchWithFallback(prefix: "Mull").fallback == nil)
        #expect(reader.searchWithFallback(prefix: " Mull ").fallback == nil)
        #expect(reader.searchWithFallback(prefix: "zzz").fallback == nil)
        #expect(reader.searchWithFallback(prefix: "Mulle", fallbacks: .none).keys.isEmpty)
        #expect(reader.searchWithFallback(prefix: "ｍｕｌ", fallbacks: .none).keys.isEmpty)
        #expect(reader.searchWithFallback(prefix: "ｍｕｌ", fallbacks: .width).keys == ["Mull"])
        #expect(reader.searchWithFallback(prefix: "Mulle", fallbacks: .width).keys.isEmpty)
    }

    @Test("A query of tens of thousands of letters is looked up without crashing")
    func longQuery() throws {
        let reader = try Self.reader()
        let letters = String(repeating: "a", count: 70_000)
        #expect(reader.lookup(letters, headwordLanguage: "EN") == nil)
        #expect(reader.lookup(letters, headwordLanguage: "DE") == nil)
        #expect(reader.lookup(letters) == nil)
        #expect(reader.lookup(String(repeating: "the dog walked home ", count: 3600), headwordLanguage: "EN") == nil)
        #expect(reader.search(prefix: letters).isEmpty)
    }

    @Test("Without a saved index, a main-thread miss builds the folded index in the background")
    func backgroundIndexBuild() async throws {
        let reader = try MDictReader(path: Self.path)
        // Keys without marks are found before the index exists.
        #expect(reader.lookup("ＷＡＬＫ", waitsForSetup: false)?.key == "walk")
        // The first miss that needs the index does not build it: nil now —
        // and no loose stem in place of the key a mark would find.
        #expect(reader.lookup("Muller", headwordLanguage: "DE", waitsForSetup: false) == nil)
        var found: MDictWordEntry?
        for _ in 0..<200 {
            found = reader.lookup("αθηναι", waitsForSetup: false)
            if found != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(found?.key == "Ἀθῆναι")
        #expect(reader.lookup("Muller", headwordLanguage: "DE", waitsForSetup: false)?.key == "Müller")
        #expect(reader.search(prefix: "αθη", waitsForSetup: false) == ["Ἀθῆναι"])
    }

    @Test("Where indexes are not built, diacritic matching and loose stems are skipped, not the rest")
    func noIndexBuilds() throws {
        let saved = MDictSidecarCache.buildsFoldedKeyIndexes
        defer { MDictSidecarCache.buildsFoldedKeyIndexes = saved }
        MDictSidecarCache.buildsFoldedKeyIndexes = false
        let reader = try MDictReader(path: Self.path)
        let builds = FoldedKeyIndex.builds.value
        #expect(reader.lookup("αθηναι") == nil)
        #expect(reader.lookup("Muller", headwordLanguage: "DE") == nil)
        #expect(reader.lookup("Muller", headwordLanguage: "DE", waitsForSetup: false) == nil)
        #expect(reader.search(prefix: "αθη").isEmpty)
        #expect(reader.lookup("machte", headwordLanguage: "DE")?.key == "machen")
        #expect(reader.lookup("ＷＡＬＫ")?.key == "walk")
        #expect(reader.lookup("Mächte")?.key == "Mächte")
        #expect(FoldedKeyIndex.builds.value == builds)
        // Asked for by name, the index is built all the same.
        #expect(reader.prepareFoldedKeyIndex() > 0)
        #expect(FoldedKeyIndex.builds.value == builds + 1)
        #expect(reader.lookup("αθηναι")?.key == "Ἀθῆναι")
        #expect(reader.lookup("Muller", headwordLanguage: "DE")?.key == "Müller")
    }
}

}

// MARK: - Case-sensitive dictionary (Tests/Fixtures/casesensitive.mdx)

@Suite struct CaseSensitiveLookupTests {

    static var path: String {
        TestFixtures.fixturesDirectory.appendingPathComponent("casesensitive.mdx").path
    }

    @Test("Direct lookups match the case as typed; a rule candidate finds the capitalized noun")
    func caseSensitiveBranches() throws {
        let reader = try MDictReader(path: Self.path)
        #expect(reader.metadata.isCaseSensitive)
        #expect(reader.lookup("Kind")?.fallback == nil)
        #expect(reader.lookup("kind", fallbacks: .none) == nil)
        #expect(reader.lookup("Weg", fallbacks: .none)?.key == "Weg")
        #expect(reader.lookup("weg", fallbacks: .none)?.key == "weg")
        // The rules give lowercase stems; the dictionary has the noun capitalized.
        let kindern = try #require(reader.lookup("Kindern", headwordLanguage: "DE"))
        #expect(kindern.key == "Kind")
        let blorpen = try #require(reader.lookup("Blorpen", headwordLanguage: "DE"))
        #expect(blorpen.key == "Blorp")
        #expect(blorpen.fallback == .inflection(lemma: "blorp"))
        #expect(reader.lookup("Hauser", headwordLanguage: "DE")?.key == "Haus")
        // Diacritic folding ignores case even here.
        #expect(reader.lookup("muller")?.key == "Müller")
        #expect(reader.search(prefix: "mull") == ["Müller"])
        #expect(reader.search(prefix: "Mü") == ["Müller"])
    }
}
