//
//  InflectionCandidates.swift
//  OpenMDict
//
//  Base forms to look up when an English or German query is an inflected
//  form that the dictionary has no key for ("walked" → "walk",
//  "ging" → "gehen").
//

import Foundation
import NaturalLanguage

public enum InflectionCandidates {

    /// The most candidates `candidates(for:headwordLanguage:waitsForSetup:)` returns.
    public static let maxCandidates = 12

    /// Queries longer than this (in characters) get no candidates: they are
    /// not words, and tagging very long text costs time it is not worth.
    public static let maxQueryLength = 100

    /// Lemma candidates for `query`, most likely first, none equal to the
    /// query ignoring case and diacritics (the tagger "lemmatizes" resumé
    /// to résumé; that is left to diacritic-insensitive matching): the
    /// `likely` candidates of `rankedCandidates`, then the `loose` ones.
    ///
    /// - Parameters:
    ///   - headwordLanguage: The dictionary's headword language as an ISO 639
    ///     code ("EN", "de", "deu" …), when known. Other languages get no
    ///     candidates. When nil, a Latin-script query gets candidates for
    ///     English and German, the likelier language first.
    ///   - waitsForSetup: The first tagging in a language loads its model
    ///     (on the order of 100 ms). When false (a caller on the main
    ///     thread) and the model is not loaded yet, it is loaded in the
    ///     background and this call uses the rules alone.
    public static func candidates(for query: String, headwordLanguage: String?,
                                  waitsForSetup: Bool = true) -> [String] {
        let ranked = rankedCandidates(for: query, headwordLanguage: headwordLanguage, waitsForSetup: waitsForSetup)
        return ranked.likely + ranked.loose
    }

    /// The candidates of `candidates(for:headwordLanguage:waitsForSetup:)`
    /// in two tiers, together at most `maxCandidates`.
    ///
    /// `likely`: the lemmas `NLTagger` gives (for German also with the
    /// umlauts its model writes as "oe", "ae", "ue" restored), then the
    /// forms the rules undo with little doubt: English -s/-es/-ies,
    /// -ed/-ied, -ing (with a dropped e or a doubled consonant restored);
    /// German strong and irregular verbs (a table of common ones), ge…t /
    /// ge…en participles, finite-verb endings. The rules run after the
    /// tagger even when it gave a lemma: its German model mistakes common
    /// forms ("dachte" → "dachen", "kostet" → "kosen").
    ///
    /// `loose`: bare stems that are often other words — English -er/-est
    /// comparatives and German adjective and noun endings ("Muller" →
    /// "Mull"). A lookup tries them after diacritic-insensitive matching. A
    /// capitalised German query is read as a noun: all its rule candidates
    /// are loose, the noun stems first (see `germanRules`).
    static func rankedCandidates(for query: String, headwordLanguage: String?,
                                 waitsForSetup: Bool = true) -> (likely: [String], loose: [String]) {
        let word = query.trimmingCharacters(in: .whitespaces)
        guard word.count <= maxQueryLength, isLatinScript(word) else { return ([], []) }
        let languages = languages(for: word, headwordLanguage: headwordLanguage)
        guard !languages.isEmpty else { return ([], []) }

        var seen: Set<String> = []
        let foldedWord = LookupFolding.folded(word)
        /// The new candidates among `candidates`, within the overall cap.
        func accepted(_ candidates: [String]) -> [String] {
            var out: [String] = []
            for candidate in candidates where seen.count < maxCandidates {
                guard LookupFolding.folded(candidate) != foldedWord else { continue }
                if seen.insert(candidate.lowercased()).inserted { out.append(candidate) }
            }
            return out
        }
        var likely: [String] = []
        var loose: [String] = []
        for language in languages {
            let lemmas = taggerLemmas(word, language: language, waitsForModel: waitsForSetup)
            likely += accepted(language == .german ? lemmas.flatMap(germanTransliterationsUndone) : lemmas)
        }
        for language in languages {
            let rules = language == .german ? germanRules(word) : englishRules(word)
            likely += accepted(rules.likely)
            loose += accepted(rules.loose)
        }
        return (likely, loose)
    }

    // MARK: - Language

    static func languages(for word: String, headwordLanguage: String?) -> [NLLanguage] {
        if let code = headwordLanguage {
            let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            switch base {
            case "en", "eng": return [.english]
            case "de", "deu", "ger": return [.german]
            default: return []
            }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .german]
        recognizer.processString(word)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        return (hypotheses[.german] ?? 0) > (hypotheses[.english] ?? 0) ? [.german, .english] : [.english, .german]
    }

    /// Letters of the Latin script (with spaces, hyphens and apostrophes
    /// between words), and at least one letter.
    static func isLatinScript(_ text: String) -> Bool {
        var hasLetter = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF:
                hasLetter = true
            case 0x20, 0x2D, 0x27, 0x2019, 0x300...0x36F:
                continue
            default:
                return false
            }
        }
        return hasLetter
    }

    /// A word written with an initial capital and the rest in lowercase
    /// ("Häuser", not "HÄUSER" or "häuser"): in German, a noun.
    static func isCapitalised(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        let rest = word.dropFirst()
        return !rest.isEmpty && !rest.contains(where: \.isUppercase)
    }

    // MARK: - NLTagger

    /// The most UTF-16 units `taggerLemmas` tags; longer text gets no lemma.
    static let maxTaggedLength = 4096

    /// The query with each word replaced by the lemma `NLTagger` gives for
    /// it, or nothing when it gives no lemma that differs from the word.
    static func taggerLemmas(_ text: String, language: NLLanguage, waitsForModel: Bool = true) -> [String] {
        guard text.utf16.count <= maxTaggedLength else { return [] }
        if !waitsForModel, !TaggerModels.shared.isLoaded(language) {
            if TaggerModels.shared.beginLoading(language) {
                let raw = language.rawValue
                DispatchQueue.global(qos: .utility).async {
                    _ = taggerLemmas("loading", language: NLLanguage(rawValue: raw))
                }
            }
            return []
        }
        if let cached = TaggerModels.shared.cachedLemmas(text, language: language) { return cached }
        defer { TaggerModels.shared.markLoaded(language) }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        let whole = text.startIndex..<text.endIndex
        tagger.setLanguage(language, range: whole)
        var lemmatized = ""
        var cursor = text.startIndex
        var changed = false
        tagger.enumerateTags(in: whole, unit: .word, scheme: .lemma,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            // Over very long text the tagger has handed back ranges that
            // start before the previous token's end; skip them.
            guard range.lowerBound >= cursor else { return true }
            lemmatized += text[cursor..<range.lowerBound]
            let token = String(text[range])
            if let lemma = tag?.rawValue, !lemma.isEmpty, lemma.lowercased() != token.lowercased() {
                lemmatized += lemma
                changed = true
            } else {
                lemmatized += token
            }
            cursor = range.upperBound
            return true
        }
        lemmatized += text[cursor...]
        let lemmas = changed ? [lemmatized] : []
        TaggerModels.shared.cacheLemmas(lemmas, for: text, language: language)
        return lemmas
    }

    /// The German lemma model writes some lemmas without umlauts and ß
    /// ("kann" → "koennen", "muss" → "muessen"): the lemma, then the forms
    /// with them restored, when the lemma has none of its own.
    static func germanTransliterationsUndone(_ lemma: String) -> [String] {
        guard !lemma.contains(where: { "äöüÄÖÜß".contains($0) }) else { return [lemma] }
        var out = [lemma]
        var restored = lemma
        for (ascii, umlaut) in [("ae", "ä"), ("oe", "ö"), ("ue", "ü"), ("Ae", "Ä"), ("Oe", "Ö"), ("Ue", "Ü")]
        where restored.contains(ascii) {
            restored = restored.replacingOccurrences(of: ascii, with: umlaut)
        }
        if restored != lemma { out.append(restored) }
        if restored.contains("ss") { out.append(restored.replacingOccurrences(of: "ss", with: "ß")) }
        return out
    }

    /// The languages whose lemma model this process has loaded, and the
    /// lemmas of the last few queries — a group lookup asks the same word
    /// of every dictionary.
    private final class TaggerModels: @unchecked Sendable {
        static let shared = TaggerModels()
        private let lock = NSLock()
        private var loaded: Set<String> = []
        private var loading: Set<String> = []
        private var cache: [(key: String, lemmas: [String])] = []
        private static let cacheSize = 16

        func isLoaded(_ language: NLLanguage) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return loaded.contains(language.rawValue)
        }

        /// True for the first caller only.
        func beginLoading(_ language: NLLanguage) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return loading.insert(language.rawValue).inserted
        }

        func markLoaded(_ language: NLLanguage) {
            lock.lock(); defer { lock.unlock() }
            loaded.insert(language.rawValue)
        }

        func cachedLemmas(_ text: String, language: NLLanguage) -> [String]? {
            lock.lock(); defer { lock.unlock() }
            let key = language.rawValue + "\u{0}" + text
            return cache.first { $0.key == key }?.lemmas
        }

        func cacheLemmas(_ lemmas: [String], for text: String, language: NLLanguage) {
            lock.lock(); defer { lock.unlock() }
            let key = language.rawValue + "\u{0}" + text
            cache.removeAll { $0.key == key }
            cache.append((key, lemmas))
            if cache.count > Self.cacheSize { cache.removeFirst() }
        }
    }

    // MARK: - English rules

    /// Base forms of a regular English inflection, most likely first.
    static func englishRuleCandidates(_ query: String) -> [String] {
        let rules = englishRules(query)
        return rules.likely + rules.loose
    }

    /// `englishRuleCandidates` in the tiers of `rankedCandidates`. A
    /// capitalised query — a name, as often as not: "Oliver", "Chester" —
    /// gets no comparative stems.
    static func englishRules(_ query: String) -> (likely: [String], loose: [String]) {
        let word = query.lowercased()
        guard word.count >= 4, word.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return ([], []) }
        var out: [String] = []
        func drop(_ n: Int) -> String { String(word.dropLast(n)) }

        if word.hasSuffix("ies") {                  // studies → study, ties → tie
            out += [drop(3) + "y", drop(1)]
        } else if word.hasSuffix("es") {            // makes → make, watches → watch
            out += [drop(1), drop(2)]
        } else if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            out.append(drop(1))                     // books → book
        }

        if word.hasSuffix("ied") {                  // carried → carry, tied → tie
            out += [drop(3) + "y", drop(1)]
        } else if word.hasSuffix("ed") {            // loved → love, walked → walk, stopped → stop
            out += verbStems(drop(2))
        }

        // dying → die (not dye); a longer stem keeps its y (studying → study).
        let ieVerb = word.hasSuffix("ying") ? drop(4) + "ie" : nil
        if let ieVerb, word.count <= 6 { out.append(ieVerb) }
        if word.hasSuffix("ing") {                  // walking, making, running
            out += verbStems(drop(3))
        }
        if let ieVerb, word.count > 6 { out.append(ieVerb) }

        // Comparatives: many words end in -er/-est without being one.
        var comparatives: [String] = []
        if !isCapitalised(query) {
            if word.hasSuffix("iest") {             // happiest → happy
                comparatives.append(drop(4) + "y")
            } else if word.hasSuffix("est") {       // nicest, tallest, biggest
                comparatives += verbStems(drop(3))
            }
            if word.hasSuffix("ier") {              // happier → happy
                comparatives.append(drop(3) + "y")
            } else if word.hasSuffix("er") {        // nicer, taller, bigger
                comparatives += verbStems(drop(2))
            }
        }
        return (out.filter { $0.count >= 2 }, comparatives.filter { $0.count >= 2 })
    }

    /// The base forms a stem left by removing -ed, -ing, -er or -est can
    /// come from: with a silent e restored and with a doubled final
    /// consonant undone, in the order most likely for the stem's shape.
    private static func verbStems(_ stem: String) -> [String] {
        guard stem.count >= 2 else { return [] }
        // A two-letter stem is rarely a word of its own (hued → hue, not hu).
        guard stem.count >= 3 else { return [stem + "e", stem] }
        let chars = Array(stem)
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        let last = chars[chars.count - 1]
        let beforeLast = chars[chars.count - 2]
        if last == beforeLast, !vowels.contains(last) {
            return [stem, String(chars.dropLast())]                 // falling → fall, running → run
        }
        // Consonant–vowel–consonant ends usually lost a silent e (hoping,
        // making); other stems usually lost nothing (walking, eating).
        let cvc = !vowels.contains(last) && !"wxy".contains(last)
            && vowels.contains(beforeLast) && !vowels.contains(chars[chars.count - 3])
        return cvc ? [stem + "e", stem] : [stem, stem + "e"]
    }

    // MARK: - German rules

    /// Prefixes that separate from the verb and precede "ge" in its
    /// participle (aufgemacht → aufmachen).
    private static let separablePrefixes = [
        "zusammen", "zurück", "voran", "vorbei", "weiter", "nach", "fest", "fort", "heim", "her", "hin",
        "los", "mit", "vor", "weg", "auf", "aus", "bei", "ein", "ab", "an", "zu",
    ]

    /// Prefixes that stay on the verb (verstand → verstehen).
    private static let inseparablePrefixes = ["miss", "ent", "emp", "ver", "zer", "be", "er", "ge"]

    /// Endings of finite verb forms, longest first; the -ete- ones are the
    /// weak preterite of stems in t/d (wartete, redeten).
    private static let verbEndings = ["etest", "etet", "eten", "test", "tet", "ten", "est", "ete",
                                      "te", "st", "et", "en", "t", "e"]

    /// Noun and adjective endings, in the order tried for a lowercase word.
    private static let nounEndings = ["ern", "en", "em", "er", "es", "e", "n", "s"]

    /// The same for a capitalised word, a noun: -n before -en and -ern
    /// (Seiten → Seite, not seit; Kammern → Kammer, not Kamm).
    private static let capitalisedNounEndings = ["n", "e", "s", "er", "es", "en", "ern", "em"]

    /// Infinitives a German word form may come from, most likely first:
    /// irregular verbs, participles, finite forms; then the bare stems of
    /// inflected adjectives and nouns (kleinen → klein, Häuser → Haus).
    static func germanRuleCandidates(_ query: String) -> [String] {
        let rules = germanRules(query)
        return rules.likely + rules.loose
    }

    /// `germanRuleCandidates` in the tiers of `rankedCandidates`: verb
    /// forms, then the adjective and noun stems.
    ///
    /// A capitalised query is read as a noun (Waren, Gaben, Boten are
    /// plurals, not preterites): its noun stems come first, with -n before
    /// -en, the preterite forms of the irregular table and the ge…en
    /// participle rule are skipped, and every candidate is loose — tried
    /// after diacritic-insensitive matching.
    static func germanRules(_ query: String) -> (likely: [String], loose: [String]) {
        let word = query.lowercased()
        guard word.count >= 3, !word.contains(" ") else { return ([], []) }
        let capitalised = isCapitalised(query)
        var verbs: [String] = []
        func infinitives(_ stem: String) -> [String] {
            stem.count >= 2 ? [stem + "en", stem + "n"] : []
        }

        // Strong and irregular verbs: ging → gehen, aufgestanden → aufstehen.
        if let base = germanIrregularBase(word, includingPreterites: !capitalised) { verbs.append(base) }

        // Participles: gemacht → machen, geredet → reden, gesehen → sehen,
        // aufgemacht → aufmachen. The verb stem after "ge" needs a vowel
        // ("gehst" is not one).
        func isStem(_ stem: Substring) -> Bool {
            stem.count >= 2 && stem.contains { "aeiouäöüy".contains($0) }
        }
        for prefix in [""] + separablePrefixes where word.hasPrefix(prefix + "ge") {
            let rest = word.dropFirst(prefix.count + 2)
            if rest.hasSuffix("et"), isStem(rest.dropLast(2)) { verbs += infinitives(prefix + rest.dropLast(2)) }
            if rest.hasSuffix("t"), isStem(rest.dropLast(1)) { verbs += infinitives(prefix + rest.dropLast(1)) }
            if !capitalised, rest.hasSuffix("en"), isStem(rest.dropLast(2)) { verbs.append(prefix + rest) }
        }

        // Finite forms: machte → machen, gehst → gehen, wanderst → wandern,
        // wartete → warten. A stem in t or d comes first: it is the one the
        // shorter ending leaves (kostet → kosten before kosen, hafte →
        // haften before Hafen).
        var stems: [String] = []
        for ending in verbEndings where word.hasSuffix(ending) && word.count - ending.count >= 2 {
            stems.append(String(word.dropLast(ending.count)))
        }
        stems = stems.filter { $0.hasSuffix("t") || $0.hasSuffix("d") } + stems.filter { !$0.hasSuffix("t") && !$0.hasSuffix("d") }
        verbs += stems.map { $0 + "en" }
        verbs += stems.filter { $0.hasSuffix("el") || $0.hasSuffix("er") }.map { $0 + "n" }
        // Strong verbs that take an umlaut: fährst → fahren, läuft → laufen.
        verbs += stems.compactMap(withoutUmlaut).map { $0 + "en" }

        // Adjectives and noun plurals: kleine, kleinen → klein; Tage → Tag;
        // Häuser → Haus; Kindern → Kind; Väter → Vater.
        var nouns: [String] = []
        for ending in capitalised ? capitalisedNounEndings : nounEndings
        where word.hasSuffix(ending) && word.count - ending.count >= 3 {
            let stem = String(word.dropLast(ending.count))
            nouns.append(stem)
            if let plain = withoutUmlaut(stem) { nouns.append(plain) }
        }
        if let plain = withoutUmlaut(word) { nouns.append(plain) }

        verbs = verbs.filter { $0 != word }
        nouns = nouns.filter { $0 != word }
        return capitalised ? ([], nouns + verbs) : (verbs, nouns)
    }

    /// `stem` with its last umlaut replaced by the plain vowel, or nil.
    private static func withoutUmlaut(_ stem: String) -> String? {
        guard let index = stem.lastIndex(where: { "äöü".contains($0) }) else { return nil }
        let plain: Character = ["ä": "a", "ö": "o", "ü": "u"][stem[index]] ?? stem[index]
        var result = stem
        result.replaceSubrange(index...index, with: String(plain))
        return result
    }

    /// The infinitive of a form of a common strong or irregular verb, also
    /// with a prefix (angefangen → anfangen, verstand → verstehen), or nil.
    /// Without `includingPreterites`, the preterite forms (gab, gaben,
    /// gabst …) are not recognised.
    static func germanIrregularBase(_ word: String, includingPreterites: Bool = true) -> String? {
        func base(_ form: String) -> String? {
            guard let entry = germanIrregularForms[form], includingPreterites || !entry.preterite else { return nil }
            return entry.infinitive
        }
        if let infinitive = base(word) { return infinitive }
        for prefix in separablePrefixes + inseparablePrefixes where word.hasPrefix(prefix) {
            if let infinitive = base(String(word.dropFirst(prefix.count))) { return prefix + infinitive }
        }
        return nil
    }

    /// Form → infinitive for `germanIrregularVerbs`, each form flagged when
    /// it is the preterite stem or one of its person forms (ging: gingst,
    /// gingen, gingt).
    private static let germanIrregularForms: [String: (infinitive: String, preterite: Bool)] = {
        var forms: [String: (infinitive: String, preterite: Bool)] = [:]
        for line in germanIrregularVerbs.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard words.count >= 3 else { continue }
            let infinitive = words[0]
            let preterite = words[1]
            var preterites = [preterite]
            if preterite.hasSuffix("e") {                               // dachte, dachtest, dachten, dachtet
                preterites += [preterite + "st", preterite + "n", preterite + "t"]
            } else if let last = preterite.last, "sßzx".contains(last) { // saß, saßest, saßen, saßt
                preterites += [preterite + "est", preterite + "en", preterite + "t"]
            } else {                                                     // ging, gingst, gingen, gingt
                preterites += [preterite + "st", preterite + "en", preterite + "t"]
                if let last = preterite.last, "td".contains(last) { preterites += [preterite + "est", preterite + "et"] }
            }
            for form in preterites where forms[form] == nil { forms[form] = (infinitive, true) }
            for form in words.dropFirst(2) where forms[form] == nil { forms[form] = (infinitive, false) }
        }
        return forms
    }()

    /// Common German verbs whose forms the endings rules cannot undo:
    /// "infinitive preterite-stem participle other-forms…" (present-tense
    /// vowel changes and common subjunctives). NLTagger's German model,
    /// where the system has it, covers the rest.
    private static let germanIrregularVerbs = """
        sein war gewesen bin bist ist sind seid wäre wären wärst
        haben hatte gehabt habe hast hat habt hätte hätten hättest
        werden wurde geworden wirst wird würde würden würdest
        gehen ging gegangen ginge
        kommen kam gekommen käme kämen
        sehen sah gesehen sieht siehst
        geben gab gegeben gibt gibst
        nehmen nahm genommen nimmt nimmst
        finden fand gefunden
        stehen stand gestanden
        tun tat getan tue tust tut
        wissen wusste gewusst weiß weißt wisst
        können konnte gekonnt kann kannst könnte könnten
        müssen musste gemusst muss musst müsste müssten
        dürfen durfte gedurft darf darfst dürfte
        mögen mochte gemocht mag magst möchte möchten
        wollen wollte gewollt will willst
        denken dachte gedacht
        bringen brachte gebracht
        kennen kannte gekannt
        nennen nannte genannt
        rennen rannte gerannt
        brennen brannte gebrannt
        wenden wandte gewandt
        sprechen sprach gesprochen spricht sprichst
        helfen half geholfen hilft hilfst
        lesen las gelesen liest
        essen aß gegessen isst
        treffen traf getroffen trifft triffst
        werfen warf geworfen wirft wirfst
        sterben starb gestorben stirbt stirbst
        werben warb geworben wirbt
        brechen brach gebrochen bricht brichst
        stehlen stahl gestohlen stiehlt
        empfehlen empfahl empfohlen empfiehlt
        befehlen befahl befohlen befiehlt
        gelten galt gegolten gilt
        vergessen vergaß vergessen vergisst
        messen maß gemessen misst
        treten trat getreten tritt trittst
        schreiben schrieb geschrieben
        bleiben blieb geblieben
        steigen stieg gestiegen
        scheinen schien geschienen
        schreien schrie geschrien
        schweigen schwieg geschwiegen
        scheiden schied geschieden
        leihen lieh geliehen
        weisen wies gewiesen
        greifen griff gegriffen
        reiten ritt geritten
        leiden litt gelitten
        schneiden schnitt geschnitten
        streiten stritt gestritten
        gleichen glich geglichen
        fahren fuhr gefahren fährt fährst
        tragen trug getragen trägt trägst
        schlagen schlug geschlagen schlägt schlägst
        waschen wusch gewaschen wäscht
        wachsen wuchs gewachsen wächst
        laufen lief gelaufen läuft läufst
        schlafen schlief geschlafen schläft schläfst
        fallen fiel gefallen fällt fällst
        halten hielt gehalten hält hältst
        lassen ließ gelassen lässt
        fangen fing gefangen fängt fängst
        heißen hieß geheißen
        rufen rief gerufen
        liegen lag gelegen
        sitzen saß gesessen
        bitten bat gebeten
        trinken trank getrunken
        singen sang gesungen
        sinken sank gesunken
        springen sprang gesprungen
        zwingen zwang gezwungen
        binden band gebunden
        beginnen begann begonnen
        gewinnen gewann gewonnen
        schwimmen schwamm geschwommen
        ziehen zog gezogen
        fliegen flog geflogen
        fliehen floh geflohen
        verlieren verlor verloren
        frieren fror gefroren
        bieten bot geboten
        schieben schob geschoben
        heben hob gehoben
        lügen log gelogen
        riechen roch gerochen
        schließen schloss geschlossen
        genießen genoss genossen
        gießen goss gegossen
        fließen floss geflossen
        schießen schoss geschossen
        """
}
