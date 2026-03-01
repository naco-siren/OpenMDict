//
//  EnglishInflectionRules.swift
//  OpenMDict-iOS
//
//  English inflection data: irregular forms table + suffix rules.
//  The resolution algorithm is provided by the InflectionRules protocol extension.
//

import Foundation

/// English inflection data — irregular forms + suffix rules.
/// Thread-safe: all properties are immutable static data.
nonisolated enum EnglishInflectionRules: InflectionRules {

    static let languageCode = "en"

    // MARK: - Suffix Rules

    /// Ordered by specificity (longer/more specific suffixes first).
    /// Each rule may produce multiple candidates since English is ambiguous.
    static let suffixRules: [InflectionSuffixRule] = [
        // -ied → -y (carried → carry, studied → study)
        InflectionSuffixRule(suffix: "ied", replacements: [
            { stem in stem + "y" },
        ]),

        // -ies → -y (carries → carry, studies → study)
        InflectionSuffixRule(suffix: "ies", replacements: [
            { stem in stem + "y" },
        ]),

        // -ves → -f / -fe (wolves → wolf, knives → knife, lives → life)
        InflectionSuffixRule(suffix: "ves", replacements: [
            { stem in stem + "f" },
            { stem in stem + "fe" },
        ]),

        // -ness → base (happiness → happy needs -iness rule, sadness → sad)
        InflectionSuffixRule(suffix: "iness", replacements: [
            { stem in stem + "y" },
        ]),
        InflectionSuffixRule(suffix: "ness", replacements: [
            { stem in stem },
        ]),

        // -ment → base (movement → move, agreement → agree)
        InflectionSuffixRule(suffix: "ment", replacements: [
            { stem in stem },
            { stem in stem + "e" },
        ]),

        // -ation → base (creation → create, information → inform)
        InflectionSuffixRule(suffix: "ation", replacements: [
            { stem in stem + "ate" },
            { stem in stem },
        ]),

        // -tion → base (reduction → reduce, addition → add)
        InflectionSuffixRule(suffix: "tion", replacements: [
            { stem in stem + "e" },
            { stem in stem },
        ]),

        // -zing → -ze (analyzing → analyze)
        InflectionSuffixRule(suffix: "zing", replacements: [
            { stem in stem + "ze" },
        ]),

        // -ling → -le (handling → handle, but also: darling)
        InflectionSuffixRule(suffix: "ling", replacements: [
            { stem in stem + "le" },
        ]),

        // -ying → -y (studying → study, applying → apply)
        InflectionSuffixRule(suffix: "ying", replacements: [
            { stem in stem + "y" },
        ]),

        // -ing → base / +e / undouble (walking → walk, making → make, running → run)
        InflectionSuffixRule(suffix: "ing", replacements: [
            { stem in stem },                               // walk
            { stem in stem + "e" },                         // make
            { stem in undoubleConsonant(stem) },            // running → run
        ]),

        // -iest → -y (happiest → happy)
        InflectionSuffixRule(suffix: "iest", replacements: [
            { stem in stem + "y" },
        ]),

        // -est → base / undouble (tallest → tall, biggest → big)
        InflectionSuffixRule(suffix: "est", replacements: [
            { stem in stem },
            { stem in stem + "e" },
            { stem in undoubleConsonant(stem) },
        ]),

        // -ier → -y (happier → happy)
        InflectionSuffixRule(suffix: "ier", replacements: [
            { stem in stem + "y" },
        ]),

        // -er → base / undouble (taller → tall, bigger → big, nicer → nice)
        InflectionSuffixRule(suffix: "er", replacements: [
            { stem in stem },
            { stem in stem + "e" },
            { stem in undoubleConsonant(stem) },
        ]),

        // -ably → -able (probably → probable, comfortably → comfortable)
        InflectionSuffixRule(suffix: "ably", replacements: [
            { stem in stem + "able" },
        ]),

        // -ibly → -ible (terribly → terrible)
        InflectionSuffixRule(suffix: "ibly", replacements: [
            { stem in stem + "ible" },
        ]),

        // -ily → -y (happily → happy, easily → easy)
        InflectionSuffixRule(suffix: "ily", replacements: [
            { stem in stem + "y" },
        ]),

        // -ly → base (quickly → quick, slowly → slow)
        InflectionSuffixRule(suffix: "ly", replacements: [
            { stem in stem },
        ]),

        // -es → base (watches → watch, goes → go, boxes → box)
        InflectionSuffixRule(suffix: "es", replacements: [
            { stem in stem },
            { stem in stem + "e" },
        ]),

        // -ed → base / +e / undouble (walked → walk, loped → lope, stopped → stop)
        InflectionSuffixRule(suffix: "ed", replacements: [
            { stem in stem },
            { stem in stem + "e" },
            { stem in undoubleConsonant(stem) },
        ]),

        // -s → base (cats → cat, dogs → dog)
        // Must be last among s-rules (least specific)
        InflectionSuffixRule(suffix: "s", replacements: [
            { stem in stem },
        ]),
    ]

    // MARK: - English-Specific Helpers

    /// Undo consonant doubling: "stopp" → "stop", "runn" → "run"
    /// Only applies when the stem ends with two identical consonants.
    private static func undoubleConsonant(_ stem: String) -> String {
        guard stem.count >= 3 else { return stem }
        let chars = Array(stem)
        let last = chars[chars.count - 1]
        let secondLast = chars[chars.count - 2]

        // Must end with two identical consonant letters
        guard last == secondLast, isConsonantLetter(last) else { return stem }

        return String(chars.dropLast())
    }

    /// Check if a character is a consonant letter (not a vowel).
    private static func isConsonantLetter(_ c: Character) -> Bool {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        return c.isLetter && !vowels.contains(c)
    }

    // MARK: - Irregular Forms Table

    /// Irregular English forms → base form.
    /// Covers common verbs, nouns, adjectives.
    static let irregularForms: [String: String] = [
        // be
        "am": "be", "is": "be", "are": "be",
        "was": "be", "were": "be", "been": "be", "being": "be",

        // have
        "has": "have", "had": "have", "having": "have",

        // do
        "does": "do", "did": "do", "done": "do", "doing": "do",

        // go
        "goes": "go", "went": "go", "gone": "go", "going": "go",

        // say
        "says": "say", "said": "say",

        // get
        "gets": "get", "got": "get", "gotten": "get",

        // make
        "made": "make", "makes": "make",

        // know
        "knew": "know", "known": "know",

        // think
        "thought": "think",

        // take
        "took": "take", "taken": "take",

        // see
        "saw": "see", "seen": "see",

        // come
        "came": "come",

        // give
        "gave": "give", "given": "give",

        // find
        "found": "find",

        // tell
        "told": "tell",

        // become
        "became": "become",

        // leave
        "left": "leave",

        // feel
        "felt": "feel",

        // put
        // "put" is its own base form

        // bring
        "brought": "bring",

        // begin
        "began": "begin", "begun": "begin",

        // keep
        "kept": "keep",

        // hold
        "held": "hold",

        // write
        "wrote": "write", "written": "write",

        // stand
        "stood": "stand",

        // hear
        "heard": "hear",

        // let
        // "let" is its own base form

        // mean
        "meant": "mean",

        // set
        // "set" is its own base form

        // meet
        "met": "meet",

        // run
        "ran": "run",

        // pay
        "paid": "pay",

        // sit
        "sat": "sit",

        // speak
        "spoke": "speak", "spoken": "speak",

        // lie (recline)
        "lay": "lie", "lain": "lie",

        // lead
        "led": "lead",

        // read (past tense pronounced "red")
        // "read" is its own base form

        // grow
        "grew": "grow", "grown": "grow",

        // lose
        "lost": "lose",

        // fall
        "fell": "fall", "fallen": "fall",

        // send
        "sent": "send",

        // build
        "built": "build",

        // understand
        "understood": "understand",

        // draw
        "drew": "draw", "drawn": "draw",

        // break
        "broke": "break", "broken": "break",

        // spend
        "spent": "spend",

        // cut
        // "cut" is its own base form

        // rise
        "rose": "rise", "risen": "rise",

        // drive
        "drove": "drive", "driven": "drive",

        // buy
        "bought": "buy",

        // wear
        "wore": "wear", "worn": "wear",

        // choose
        "chose": "choose", "chosen": "choose",

        // seek
        "sought": "seek",

        // throw
        "threw": "throw", "thrown": "throw",

        // catch
        "caught": "catch",

        // deal
        "dealt": "deal",

        // win
        "won": "win",

        // fight
        "fought": "fight",

        // teach
        "taught": "teach",

        // sell
        "sold": "sell",

        // shake
        "shook": "shake", "shaken": "shake",

        // sing
        "sang": "sing", "sung": "sing",

        // ring
        "rang": "ring", "rung": "ring",

        // swim
        "swam": "swim", "swum": "swim",

        // drink
        "drank": "drink", "drunk": "drink",

        // fly
        "flew": "fly", "flown": "fly",

        // freeze
        "froze": "freeze", "frozen": "freeze",

        // wake
        "woke": "wake", "woken": "wake",

        // hide
        "hid": "hide", "hidden": "hide",

        // bite
        "bit": "bite", "bitten": "bite",

        // blow
        "blew": "blow", "blown": "blow",

        // tear
        "tore": "tear", "torn": "tear",

        // eat
        "ate": "eat", "eaten": "eat",

        // forgive
        "forgave": "forgive", "forgiven": "forgive",

        // forget
        "forgot": "forget", "forgotten": "forget",

        // swear
        "swore": "swear", "sworn": "swear",

        // steal
        "stole": "steal", "stolen": "steal",

        // sleep
        "slept": "sleep",

        // sweep
        "swept": "sweep",

        // feed
        "fed": "feed",

        // bleed
        "bled": "bleed",

        // breed
        "bred": "breed",

        // speed
        "sped": "speed",

        // dig
        "dug": "dig",

        // hang
        "hung": "hang",

        // stick
        "stuck": "stick",

        // strike
        "struck": "strike", "stricken": "strike",

        // swing
        "swung": "swing",

        // cling
        "clung": "cling",

        // sting
        "stung": "sting",

        // wring
        "wrung": "wring",

        // sling
        "slung": "sling",

        // spin
        "spun": "spin",

        // bind
        "bound": "bind",

        // grind
        "ground": "grind",

        // wind
        "wound": "wind",

        // shine
        "shone": "shine",

        // shoot
        "shot": "shoot",

        // slide
        "slid": "slide",

        // ride
        "rode": "ride", "ridden": "ride",

        // stride
        "strode": "stride", "stridden": "stride",

        // arise
        "arose": "arise", "arisen": "arise",

        // awake
        "awoke": "awake", "awoken": "awake",

        // bear
        "bore": "bear", "borne": "bear",

        // beat
        "beaten": "beat",

        // bend
        "bent": "bend",

        // bet
        // "bet" is its own base form

        // burst
        // "burst" is its own base form

        // cast
        // "cast" is its own base form

        // cost
        // "cost" is its own base form

        // creep
        "crept": "creep",

        // deal
        // "dealt" already above

        // dream
        "dreamt": "dream",

        // dwell
        "dwelt": "dwell",

        // flee
        "fled": "flee",

        // fling
        "flung": "fling",

        // forbid
        "forbade": "forbid", "forbidden": "forbid",

        // forecast
        // "forecast" is its own base form

        // hurt
        // "hurt" is its own base form

        // kneel
        "knelt": "kneel",

        // lay
        "laid": "lay",

        // lean
        "leant": "lean",

        // leap
        "leapt": "leap",

        // learn
        "learnt": "learn",

        // lend
        "lent": "lend",

        // light
        "lit": "light",

        // overcome
        "overcame": "overcome",

        // quit
        // "quit" is its own base form

        // shed
        // "shed" is its own base form

        // shrink
        "shrank": "shrink", "shrunk": "shrink",

        // shut
        // "shut" is its own base form

        // sink
        "sank": "sink", "sunk": "sink",

        // sow
        "sowed": "sow", "sown": "sow",

        // spit
        "spat": "spit",

        // split
        // "split" is its own base form

        // spread
        // "spread" is its own base form

        // spring
        "sprang": "spring", "sprung": "spring",

        // knit
        // "knit" is its own base form

        // smell
        "smelt": "smell",

        // spell
        "spelt": "spell",

        // spill
        "spilt": "spill",

        // spoil
        "spoilt": "spoil",

        // weave
        "wove": "weave", "woven": "weave",

        // weep
        "wept": "weep",

        // withhold
        "withheld": "withhold",

        // withdraw
        "withdrew": "withdraw", "withdrawn": "withdraw",

        // withstand
        "withstood": "withstand",

        // undergo
        "underwent": "undergo", "undergone": "undergo",

        // undertake
        "undertook": "undertake", "undertaken": "undertake",

        // upset
        // "upset" is its own base form

        // Irregular nouns
        "children": "child",
        "men": "man",
        "women": "woman",
        "mice": "mouse",
        "teeth": "tooth",
        "feet": "foot",
        "geese": "goose",
        "oxen": "ox",
        "lice": "louse",
        "dice": "die",
        "people": "person",
        "phenomena": "phenomenon",
        "criteria": "criterion",
        "data": "datum",
        "alumni": "alumnus",
        "fungi": "fungus",
        "cacti": "cactus",
        "stimuli": "stimulus",
        "syllabi": "syllabus",
        "nuclei": "nucleus",
        "analyses": "analysis",
        "theses": "thesis",
        "crises": "crisis",
        "hypotheses": "hypothesis",
        "parentheses": "parenthesis",
        "diagnoses": "diagnosis",
        "oases": "oasis",
        "appendices": "appendix",
        "indices": "index",
        "matrices": "matrix",
        "vertices": "vertex",
        "formulae": "formula",
        "larvae": "larva",
        "antennae": "antenna",
        "curricula": "curriculum",
        "media": "medium",
        "memoranda": "memorandum",
        "bacteria": "bacterium",
        "strata": "stratum",

        // Irregular adjectives (comparative/superlative)
        "better": "good",
        "best": "good",
        "worse": "bad",
        "worst": "bad",
        "more": "much",
        "most": "much",
        "less": "little",
        "least": "little",
        "further": "far",
        "furthest": "far",
        "farther": "far",
        "farthest": "far",
        "elder": "old",
        "eldest": "old",
    ]
}
