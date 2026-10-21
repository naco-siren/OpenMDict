#!/usr/bin/env python3
"""
Build bilingual MDX dictionaries from WikDict SQLite data.

Supports:
  - EN↔XX: fr, de, es, ru, pt, it, tr, la, el (9 languages, 18 files)
  - Cross-language: de-ru, es-pt, fr-es, fr-ru (4 pairs, 8 files)

Every file is unidirectional (WikDict-{A}-{B}.mdx: A headwords, B
translations); the key is the bare headword.

Input:  ../data/wikdict/{xx-yy}.sqlite3 -- WikDict release 2_2025-11
        (https://download.wikdict.com/dictionaries/sqlite/2_2025-11/)
        ../data/entries-*.json -- Open English WordNet (irregular English
        forms and British/American spelling pairs, for redirects)
Output: ../output/WikDict-{A}-{B}/WikDict-{A}-{B}.mdx

What goes into an A→B file
  1. Direct rows of {a}-{b}.sqlite3: WikDict's is_good rows, plus rows
     with a Wiktionary lexical entry and score >= 10 (sense-aligned
     translations just under WikDict's cut-off of 20). They are rendered
     one card per sense: the sense's own translations under its own
     definition. A translation set that upstream attached to several
     senses is shown once, without a definition (the alignment is not
     trustworthy then). Homonym lexical entries stay separate.
  2. Headwords with no direct row (upstream keeps only weak "reverse"
     rows for them) are rebuilt from the direct rows of the opposite file
     {b}-{a}.sqlite3: every B headword whose translations include the A
     word, with its B definition as a hint. These cards are badged
     "via B → A". Rows WikDict inferred itself (score >= 4) are the last
     resort, badged "inferred". Headwords whose direct rows are all below
     the is_good cut-off get the "via" card as well, and words that occur
     only as translations in {b}-{a} (with at least one good row attached
     to a single sense) get one of their own.
  3. @@@LINK redirects for forms users type but that are not keys:
     English irregular / regular inflections and British/American
     spellings, ASCII spellings of accented English loanwords, Russian е
     for ё, Turkish dotless/undotted I and circumflex-free spellings,
     macron-free Latin, monotonic Greek.

The English redirects need the Open English WordNet JSON
(scripts/fetch_data.sh wordnet); the build stops when it is missing.

Usage:
    python build_wikdict_mdx.py               # build all EN↔XX
    python build_wikdict_mdx.py fr             # build French EN↔FR only
    python build_wikdict_mdx.py de-ru fr-es    # build cross-language pairs
    python build_wikdict_mdx.py --cross        # build all cross-language pairs
    python build_wikdict_mdx.py --all          # build everything (26 files)
"""

from __future__ import annotations

import html as _stdlib_html
import json
import re
import sqlite3
import sys
import unicodedata
from collections import Counter, OrderedDict, defaultdict
from pathlib import Path
from typing import NamedTuple

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, GLOSS, ORDERED_LIST, DOMAIN_BADGE, TEXT_SECONDARY
from shared.html import esc, strip_bidi_controls, wrap_entry, headword as headword_html, dir_label
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_ROOT = SCRIPT_DIR.parent / "data"
DATA_DIR = DATA_ROOT / "wikdict"
OUTPUT_DIR = SCRIPT_DIR.parent / "output"

# The SQLite files in data/wikdict are this WikDict release (sizes and
# SHA-256 checked against the server; see fetch_data.sh).
WIKDICT_RELEASE = "2025-11"

# WikDict's is_good cut-off: in every table, a row with a Wiktionary
# lexical entry is is_good exactly when its score is at least 20.
GOOD_SCORE = 20
# Rows below the cut-off that still carry a Wiktionary lexical entry are
# admitted from this score up.
DIRECT_MIN_SCORE = 10
# WikDict's own inferred rows (no lexical entry) are used only from here up,
# and only when nothing better exists for the headword.
INFERRED_MIN_SCORE = 4

# ── Language definitions ───────────────────────────────────────

LANGUAGES = {
    'en': {'code': 'en', 'name_en': 'English', 'name_native': 'English',
           'flag': '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8', 'script': 'Latn'},   # 🇬🇧🇺🇸
    'fr': {'code': 'fr', 'name_en': 'French', 'name_native': 'Français',
           'flag': '\U0001F1EB\U0001F1F7', 'script': 'Latn'},                       # 🇫🇷
    'de': {'code': 'de', 'name_en': 'German', 'name_native': 'Deutsch',
           'flag': '\U0001F1E9\U0001F1EA', 'script': 'Latn'},                       # 🇩🇪
    'es': {'code': 'es', 'name_en': 'Spanish', 'name_native': 'Español',
           'flag': '\U0001F1EA\U0001F1F8', 'script': 'Latn'},                       # 🇪🇸
    'ru': {'code': 'ru', 'name_en': 'Russian', 'name_native': 'Русский',
           'flag': '\U0001F1F7\U0001F1FA', 'script': 'Cyrl'},                       # 🇷🇺
    'pt': {'code': 'pt', 'name_en': 'Portuguese', 'name_native': 'Português',
           'flag': '\U0001F1F5\U0001F1F9\U0001F1E7\U0001F1F7', 'script': 'Latn'},   # 🇵🇹🇧🇷
    'it': {'code': 'it', 'name_en': 'Italian', 'name_native': 'Italiano',
           'flag': '\U0001F1EE\U0001F1F9', 'script': 'Latn'},                       # 🇮🇹
    'tr': {'code': 'tr', 'name_en': 'Turkish', 'name_native': 'Türkçe',
           'flag': '\U0001F1F9\U0001F1F7', 'script': 'Latn'},                       # 🇹🇷
    'la': {'code': 'la', 'name_en': 'Latin', 'name_native': 'Latina',
           'flag': '\U0001F3DB\uFE0F', 'script': 'Latn'},                           # 🏛️
    'el': {'code': 'el', 'name_en': 'Greek', 'name_native': 'Ελληνικά',
           'flag': '\U0001F1EC\U0001F1F7', 'script': 'Grek'},                       # 🇬🇷
}

FLAG_EN = LANGUAGES['en']['flag']

# ── Cross-language pairs ──────────────────────────────────────
# Each tuple (a, b) builds WikDict-{A}-{B}.mdx and WikDict-{B}-{A}.mdx
# from {a}-{b}.sqlite3 and {b}-{a}.sqlite3

CROSS_PAIRS = [
    ('de', 'ru'),   # German ↔ Russian
    ('es', 'pt'),   # Spanish ↔ Portuguese
    ('fr', 'es'),   # French ↔ Spanish
    ('fr', 'ru'),   # French ↔ Russian
]

# ── POS normalization ──────────────────────────────────────────
# Maps raw POS strings (lowercased, from the lexentry field) to display tags

POS_MAP = {
    # English (en-xx databases)
    'noun': 'n.', 'verb': 'v.', 'adjective': 'adj.', 'adverb': 'adv.',
    'preposition': 'prep.', 'conjunction': 'conj.', 'interjection': 'interj.',
    'pronoun': 'pron.', 'proper_noun': 'proper n.', 'suffix': 'suffix',
    'prefix': 'prefix', 'particle': 'part.', 'phrase': 'phrase',
    'prepositional_phrase': 'prep. phr.', 'proverb': 'proverb',
    'symbol': 'sym.', 'article': 'art.', 'determiner': 'det.',
    'numeral': 'num.', 'number': 'num.', 'postposition': 'postp.', 'interfix': 'interfix',

    # German (de-en, de-ru)
    'substantiv': 'n.', 'adjektiv': 'adj.', 'interjektion': 'interj.',
    'eigenname': 'proper n.', 'redewendung': 'phrase', 'sprichwort': 'proverb',
    'abkürzung': 'abbr.', 'wortverbindung': 'phrase',
    'possessivpronomen': 'pron.', 'grußformel': 'interj.',
    'nachname': 'proper n.', 'toponym': 'proper n.',
    'gebundenes_lexem': 'affix', 'merkspruch': 'phrase',
    'formel': 'phrase', 'präfix': 'prefix', 'suffixoid': 'suffix',
    'präfixoid': 'prefix',
    'numerale': 'num.', 'präposition': 'prep.', 'zirkumposition': 'prep.',
    'konjunktion': 'conj.', 'subjunktion': 'conj.',
    'indefinitpronomen': 'pron.', 'personalpronomen': 'pron.',
    'demonstrativpronomen': 'pron.', 'relativpronomen': 'pron.',
    'interrogativpronomen': 'pron.', 'reflexivpronomen': 'pron.',
    'reziprokpronomen': 'pron.',
    'lokaladverb': 'adv.', 'temporaladverb': 'adv.', 'modaladverb': 'adv.',
    'pronominaladverb': 'adv.', 'konjunktionaladverb': 'adv.',
    'interrogativadverb': 'adv.',
    'partikel': 'part.', 'antwortpartikel': 'part.', 'gradpartikel': 'part.',
    'fokuspartikel': 'part.', 'modalpartikel': 'part.', 'vergleichspartikel': 'part.',
    'artikel': 'art.', 'kontraktion': 'contr.', 'onomatopoetikum': 'interj.',
    'ortsnamengrundwort': 'affix', 'geflügeltes_wort': 'phrase',
    'straßenname': 'proper n.',

    # French (fr-en)
    'nom': 'n.', 'adj': 'adj.', 'adv': 'adv.',
    'adjectif': 'adj.', 'verbe': 'v.', 'adverbe': 'adv.',
    'conjonction': 'conj.', 'préposition': 'prep.', 'pronom': 'pron.',
    'nompr': 'proper n.', 'prénom': 'proper n.',
    'nom_de_famille': 'proper n.', 'patronyme': 'proper n.',
    'locutionphrase': 'phrase', 'locution_phrase': 'phrase',
    'onomatopée': 'interj.', 'article_indéfini': 'art.',
    'article_défini': 'art.', 'article_partitif': 'art.',
    'pronom_personnel': 'pron.', 'pronom_indéfini': 'pron.',
    'pronom_relatif': 'pron.', 'pronom_démonstratif': 'pron.',
    'pronom_interrogatif': 'pron.', 'pronom_possessif': 'pron.',
    'adjectif_indéfini': 'adj.', 'adjectif_numéral': 'num.',
    'adjectif_interrogatif': 'adj.', 'adjectif_possessif': 'adj.',
    'adjectif_exclamatif': 'adj.',
    'adverbe_interrogatif': 'adv.', 'adverbe_relatif': 'adv.',
    'conjonction_de_coordination': 'conj.',
    'variante_typographique': '',
    'proverbe': 'proverb',

    # Spanish (es-en, es-fr, es-pt)
    'sustantivo': 'n.', 'sustantivo_masculino': 'n.m.',
    'sustantivo_femenino': 'n.f.',
    'sustantivo_masculino_y_femenino': 'n.m/f.',
    'sustantivo_femenino_y_masculino': 'n.f/m.',
    'sustantivo_ambiguo': 'n.m/f.',
    'sustantivo_propio': 'proper n.',
    'adjetivo': 'adj.', 'verbo': 'v.', 'verbo_transitivo': 'v.t.',
    'verbo_intransitivo': 'v.i.', 'verbo_pronominal': 'v.pron.',
    'verbo_auxiliar': 'v.aux.', 'verbo_impersonal': 'v.',
    'adverbio': 'adv.',
    'adverbio_de_modo': 'adv.', 'adverbio_de_tiempo': 'adv.',
    'adverbio_de_cantidad': 'adv.', 'adverbio_de_lugar': 'adv.',
    'adverbio_de_negación': 'adv.', 'adverbio_de_duda': 'adv.',
    'adverbio_de_afirmación': 'adv.', 'adverbio_comparativo': 'adv.',
    'adverbio_relativo': 'adv.', 'adverbio_interrogativo': 'adv.',
    'adjetivo_ordinal': 'num.', 'adjetivo_cardinal': 'num.',
    'adjetivo_posesivo': 'adj.', 'adjetivo_indefinido': 'adj.',
    'adjetivo_demostrativo': 'adj.', 'adjetivo_interrogativo': 'adj.',
    'preposición': 'prep.', 'conjunción': 'conj.',
    'conjunción_adversativa': 'conj.', 'conjunción_ilativa': 'conj.',
    'pronombre': 'pron.', 'pronombre_personal': 'pron.',
    'pronombre_indefinido': 'pron.', 'pronombre_posesivo': 'pron.',
    'pronombre_interrogativo': 'pron.', 'pronombre_relativo': 'pron.',
    'artículo': 'art.', 'artículo_determinado': 'art.',
    'artículo_indeterminado': 'art.',
    'interjección': 'interj.', 'onomatopeya': 'interj.',
    'locución': 'phrase', 'locución_adjetiva': 'adj. phr.',
    'locución_adverbial': 'adv. phr.', 'locución_conjuntiva': 'conj. phr.',
    'locución_prepositiva': 'prep. phr.', 'locución_sustantiva': 'n. phr.',
    'locución_verbal': 'v. phr.', 'locución_interjectiva': 'interj.',
    'locución_pronominal': 'pron.', 'expresión': 'phrase',
    'prefijo': 'prefix', 'sufijo': 'suffix', 'sufijo_flexivo': 'suffix',
    'refrán': 'proverb', 'símbolo': 'sym.', 'letra': 'letter',

    # Russian (ru-en)
    'сущ': 'n.', 'гл': 'v.', 'прил': 'adj.', 'мест': 'pron.',
    'числ': 'num.', 'деепр': 'v.', 'прич': 'adj.',
    'predic': 'pred.', 'intro': 'interj.', 'onomatop': 'interj.',
    'part': 'part.', 'prep': 'prep.', 'conj': 'conj.',
    'interj': 'interj.',
    'фам': 'proper n.',

    # Portuguese (pt-en)
    'substantivo': 'n.', 'advérbio': 'adv.',

    # Italian (it-en)
    'nome': 'n.', 'sost': 'n.', 'agg': 'adj.',
    'avv': 'adv.', 'cong': 'conj.', 'inter': 'interj.',
    'pronome': 'pron.', 'pron_dim': 'pron.', 'pron_poss': 'pron.',
    'art': 'art.', 'espr': 'phrase', 'acron': 'abbr.',
    'agg_num': 'num.', 'agg_poss': 'adj.',
    'loc_agg': 'adj. phr.', 'loc_avv': 'adv. phr.',
    'loc_cong': 'conj. phr.', 'loc_inter': 'interj.',
    'loc_nom': 'n. phr.', 'loc_verb': 'v. phr.',
    'pref': 'prefix', 'suff': 'suffix',

    # Turkish (tr-en)
    'ad': 'n.', 'eylem': 'v.', 'belirteç': 'adv.',
    'bağlaç': 'conj.', 'edat': 'prep.', 'ünlem': 'interj.',
    'adıl': 'pron.', 'ön_ad': 'adj.', 'ön_ek': 'prefix',
    'son_ek': 'suffix', 'özel_ad': 'proper n.', 'özel_isim': 'proper n.',
    'deyim': 'phrase', 'atasözü': 'proverb', 'ifade': 'phrase',
    'isim': 'n.',

    # Latin (la-en)
    'nomen': 'n.', 'nomensubst': 'n.', 'substantivum': 'n.',
    'nomenadj': 'adj.', 'adiectivum': 'adj.',
    'verbum': 'v.', 'verbumtr': 'v.t.', 'verbumintr': 'v.i.',
    'intransitivum': 'v.i.',
    'adverbium': 'adv.', 'praepositio': 'prep.', 'praep': 'prep.',
    'coniunctio': 'conj.', 'interiectio': 'interj.',
    'pronomen': 'pron.', 'participium': 'part.',
    'nomenprop': 'proper n.', 'proprium': 'proper n.',
    'numerus': 'num.', 'cardinalis': 'num.', 'ordinalis': 'num.',
    'proverbium': 'proverb',

    # Greek (el-en)
    'ουσιαστικό': 'n.', 'επίθετο': 'adj.', 'ρήμα': 'v.',
    'επίρρημα': 'adv.', 'πρόθεση': 'prep.', 'σύνδεσμος': 'conj.',
    'επιφώνημα': 'interj.', 'αντωνυμία': 'pron.', 'μετοχή': 'part.',
    'άρθρο': 'art.', 'μόριο': 'part.', 'αριθμητικό': 'num.',
    'κύριο_όνομα': 'proper n.', 'πρόθημα': 'prefix', 'επίθημα': 'suffix',
    'έκφραση': 'phrase', 'φράση': 'phrase', 'παροιμία': 'proverb', 'σύμβολο': 'sym.',
    'πολυλεκτικός_όρος': 'phrase', 'πρόσφυμα': 'affix',
    'συντομομορφή': 'abbr.', 'ένθημα': 'infix',
    'μεταγραφή': '',
    'μορφή_ουσιαστικού': 'n.', 'μορφή_ρήματος': 'v.',
    'μορφή_επιθέτου': 'adj.', 'μορφή_αντωνυμίας': 'pron.',
    'μορφή_μετοχής': 'part.', 'μορφή_κυρίου_ονόματος': 'proper n.',
    'μορφή_πολυλεκτικού_όρου': 'phrase', 'μορφή_άρθρου': 'art.',
}


def extract_pos(lexentry: str) -> str:
    """POS badge text for a lexentry like 'eng/hello__Interjection__1'."""
    if not lexentry or '__' not in lexentry:
        return ''
    parts = lexentry.split('__')
    raw_pos = parts[-2] if len(parts) == 3 else parts[1]
    # 'İsim'.lower() is 'i̇sim' (i + U+0307); fold the Turkish capital first.
    raw_pos = raw_pos.strip().replace('İ', 'i').lower()
    if '/' in raw_pos:
        raw_pos = raw_pos.split('/')[-1]
    return POS_MAP.get(raw_pos, '')


# ── Unicode helpers ────────────────────────────────────────────

_ZERO_WIDTH = dict.fromkeys(map(ord, '\u200b\u200c\u200d\u2060\ufeff\u00ad'))
_NBSP = re.compile('[\u00a0\u2007\u2009\u202f]')
_WS = re.compile(r'[ \t\r\n]+')


def _decode(text: str) -> str:
    """Decode HTML entities (the data carries '&#769;', '&nbsp;', '&equals;'),
    drop zero-width and bidi control characters."""
    text = _stdlib_html.unescape(text)
    return strip_bidi_controls(text).translate(_ZERO_WIDTH)


def _strip_marks(text: str, marks: str) -> str:
    """Remove the given combining marks (NFD) and recompose."""
    nfd = unicodedata.normalize('NFD', text)
    return unicodedata.normalize('NFC', ''.join(c for c in nfd if c not in marks))


RU_STRESS = '\u0301\u0300'          # acute / grave stress marks
LA_QUANTITY = '\u0304\u0306'        # macron / breve


def _script(ch: str) -> str:
    """'Latn', 'Cyrl', 'Grek' or 'Other' for a letter."""
    cp = ord(ch)
    if cp < 0x250 or 0x1E00 <= cp <= 0x1EFF or 0x2C60 <= cp <= 0x2C7F or 0xA720 <= cp <= 0xA7FF:
        return 'Latn'
    if 0x370 <= cp <= 0x3FF or 0x1F00 <= cp <= 0x1FFF:
        return 'Grek'
    if 0x400 <= cp <= 0x52F or 0x2DE0 <= cp <= 0x2DFF or 0xA640 <= cp <= 0xA69F:
        return 'Cyrl'
    return 'Other'


def _letters(text: str) -> list[str]:
    return [c for c in text if c.isalpha()]


def _scripts(text: str) -> Counter:
    return Counter(_script(c) for c in text if c.isalpha())


# Homoglyph pairs: a stray letter of another script inside a word
# ('cто́лбчатая' with a Latin c, 'Meridiоnal' with a Cyrillic о).
# Accented Latin vowels inside Cyrillic/Greek words stand for a stressed
# vowel ('обыкновéнный' -> 'обыкнове́нный', 'αμαξουργóς' -> 'αμαξουργός').
_LAT_CYR = {**dict(zip('aceopxykmtACEHKMOPTXBëË', 'асеорхукмтАСЕНКМОРТХВёЁ')),
            'á': 'а\u0301', 'é': 'е\u0301', 'ó': 'о\u0301', 'ý': 'у\u0301',
            'Á': 'А\u0301', 'É': 'Е\u0301', 'Ó': 'О\u0301'}
_LAT_GRK = {**dict(zip('ABEZHIKMNOPTYXoxyvkiaµmdsutn', 'ΑΒΕΖΗΙΚΜΝΟΡΤΥΧοχυνκιαμμδσυτη')),
            'ó': 'ό', 'á': 'ά', 'é': 'έ', 'í': 'ί', 'ú': 'ύ'}       # 'mαρέγκα', 'σκάνdιο', 'φασιανόs'
_TO_SCRIPT = {
    'Cyrl': _LAT_CYR,
    'Grek': _LAT_GRK,
    'Latn': {**{v: k for k, v in _LAT_CYR.items() if len(v) == 1 and k not in 'ëË'},
             **dict(zip('ΑΒΕΖΗΙΚΜΝΟΡΤΥΧοιανκχερτ', 'ABEZHIKMNOPTYXoiavkxept')),
             'і': 'i', 'І': 'I', 'ј': 'j', 'ѕ': 's'},
}
_WORD_RUN = re.compile(r'(?:[^\W\d_][\u0300-\u036f]*)+')


def _map_word(word: str, script: str) -> str | None:
    """word with every letter of another script mapped into `script`, or
    None when some letter has no look-alike there."""
    table = _TO_SCRIPT.get(script)
    if table is None:
        return None
    out = []
    for i, c in enumerate(word):
        if c.isalpha() and _script(c) != script:
            if c not in table:
                return None
            c = table[c]
            if c == 'σ' and i == len(word) - 1:
                c = 'ς'                             # word-final sigma
        out.append(c)
    return ''.join(out)


def fix_homoglyphs(text: str, prefer: str = '') -> str:
    """Map look-alike letters of another script into the script of the
    word they sit in: the `prefer`red script (the language's own) when the
    word uses it and every stray letter has a look-alike there ('Теrnе' ->
    'Terne' in German), else the word's majority script. Words with letters
    that have no look-alike are left alone."""
    def fix(m: re.Match) -> str:
        word = m.group(0)
        counts = _scripts(word)
        if len(counts) < 2:
            return word
        if prefer and counts.get(prefer):
            mapped = _map_word(word, prefer)
            if mapped is not None:
                return mapped
        major, n = counts.most_common(1)[0]
        if n < 2:
            return word
        mapped = _map_word(word, major)
        return word if mapped is None else mapped
    return _WORD_RUN.sub(fix, text)


# ── Wiki markup ────────────────────────────────────────────────

_NOWIKI = re.compile(r'<nowiki\s*/>|</?nowiki>')
_LINK = re.compile(r'\[\[([^\[\]]*)\]\]')
_HALF_LINK = re.compile(r'(?<!\[)\[([^\[\]|]*)\|([^\[\]]*)\]\]')     # [a|b]]
_OPEN_PIPED = re.compile(r'\[\[([^\[\]|]*)\|([^\[\]]*)$')            # [[a|b  (unclosed)
_ANCHOR = re.compile(r'(?<=\w)#(?=[^\W\d_])[^#|\]]*')                # word#Noun
_TAG = re.compile(r'</?[a-zA-Z][^<>]*>')


def _link_text(m: re.Match) -> str:
    inner = m.group(1)
    if '|' in inner:
        return inner.rsplit('|', 1)[1]          # [[target|display]] -> display
    if inner.startswith('w:'):
        inner = inner[2:]
    return _ANCHOR.sub('', inner)               # [[target#Noun]] -> target


def resolve_links(text: str) -> str:
    text = text.replace('[w:[', '[[').replace(']][[', ']] [[')    # '[[même]][[moi-même]]'
    text = _LINK.sub(_link_text, text)
    text = _HALF_LINK.sub(r'\2', text)
    text = _OPEN_PIPED.sub(r'\2', text)
    return text.replace('[[', '').replace(']]', '')


def _balance(text: str, op: str, cl: str) -> str:
    """Drop unmatched brackets ('[closed', 'Rosaceae)')."""
    out, stack = list(text), []
    for i, c in enumerate(text):
        if c == op:
            stack.append(i)
        elif c == cl:
            if stack:
                stack.pop()
            else:
                out[i] = ''
    for i in stack:
        out[i] = ''
    return ''.join(out)


_SUP = dict(zip('0123456789+-=()abcdefghijklmnoprstuvwxyz',
                '⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻ'))
_SUB = dict(zip('0123456789+-=()aehijklmnoprstuvx',
                '₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ'))
_SUPSUB = re.compile(r'<(sup|sub)>(.*?)</\1>', re.S)


def _supsub(m: re.Match) -> str:
    table = _SUP if m.group(1) == 'sup' else _SUB
    inner = _TAG.sub('', m.group(2))
    if inner and all(c in table for c in inner):
        return ''.join(table[c] for c in inner)
    return inner


# ── Translation (gloss) cleaning ───────────────────────────────

class Gloss(NamedTuple):
    text: str
    labels: tuple = ()       # source-language usage labels ('разг.')


_DECL_MARKER = re.compile(r'\s{2,}(?:=|-\s?[^\W\d_]{0,3})(?=\s|$)')    # 'Heer  -s', 'August  ='
_LEAD_MARKER = re.compile(r'^(?:-[^\W\d_]{1,3}|=)\s*/\s*')               # '-n / Selbstbiografie'
_BARE_SUFFIX = re.compile(r'^-\s?[^\W\d_]{0,3}\.?$')                      # '-en', '-s', '-e.', '-'
_BRACES = re.compile(r'\(\)\}+|\{\{|\}\}')
_ENUM = re.compile(r'^\[\d+\]\s*')


def _wrong_script(text: str, tgt_script: str) -> bool:
    """True for a gloss written entirely in a script the target language
    does not use ('подобно' in an Italian→English gloss list)."""
    counts = _scripts(text)
    n = sum(counts.values())
    if n < 2 or counts.get(tgt_script):
        return False
    if tgt_script == 'Latn':
        return True
    # Latin-only glosses in Cyrillic/Greek targets are acronyms (DVD, CD-ROM)
    return 'Latn' not in counts


_REDIRECT_PAGE = re.compile(r'^\s*#\s*(?:перенаправление|redirect|weiterleitung|redirection)', re.I)
_BRACE_IN_LIST = re.compile(r'[(,]\s*\}\}')


def clean_gloss(raw: str, tgt: str, affix_headword: bool = False,
                numeric_headword: bool = False, src: str = '') -> Gloss | None:
    """Clean one WikDict translation; None when nothing usable is left.

    numeric_headword: the headword has digits ('1984', '21st', 'H24'), so
    a translation without letters ('1984', '21.', '24/7') is kept.
    """
    t = _decode(raw)
    t = _NOWIKI.sub('', t)
    t = resolve_links(t)
    t = _SUPSUB.sub(_supsub, t)
    t = _TAG.sub('', t)                       # <u>stress</u>, <i>…</i>, <b>
    n_braces = len(re.findall(r'\{\{|\}\}', t))
    if n_braces >= 2 and len(_BRACE_IN_LIST.findall(t)) < n_braces:
        return None                           # '}} de la }}', '}} }}' (but keep 'quel jour ( }} de la semaine, }} du mois)')
    t = _BRACES.sub('', t)
    if _REDIRECT_PAGE.match(t) or re.search(r'#\s+#', t):
        return None                           # '#перенаправление', 'a# # # b'
    t = re.sub(r'^\s*#\s*', '', t)            # '#Lüderitz (Englisch)'
    t = t.replace('\\*', '*')                 # '\*69'
    t = _ANCHOR.sub('', t)                    # 'claro#Interjection'
    t = _DECL_MARKER.sub('', t)
    t = _LEAD_MARKER.sub('', t)
    t = _ENUM.sub('', t)
    t = _balance(_balance(t, '(', ')'), '[', ']')
    if tgt == 'el':
        # ';' is the Greek question mark: 'πώς είσαι;', 'ναι;' (answering the phone)
        t = re.sub(r'\s+;$', ';', _WS.sub(' ', t).strip(' ,/|')).lstrip('; ')
    else:
        t = _WS.sub(' ', t).strip(' ,;/|')
    t = re.sub(r'\(\s*', '(', re.sub(r'\s*\)', ')', t))
    if '|' in t:                              # leftover of a split link 'Sicily|Syracuse'
        t = t.rsplit('|', 1)[1].strip()
    tgt_script = LANGUAGES[tgt]['script']
    labels: tuple = ()
    if tgt_script != 'Cyrl':
        words = t.split(' ')
        i = 0
        while i < len(words) and _scripts(words[i]).get('Cyrl') and not _scripts(words[i]).get('Latn'):
            i += 1
        if 0 < i < len(words):
            labels = (' '.join(words[:i]),)   # 'разг. chopine'
            t = ' '.join(words[i:])
    if not _letters(t) and not (numeric_headword and re.search(r'\d', t)):
        return None                           # '=', 'разг. =', '~'
    if tgt == 'de' and not affix_headword and (
            _BARE_SUFFIX.match(t) or (src == 'ru' and t.startswith('-'))):
        return None                           # German declension endings ('-en', '-s', '-e.'; RU→DE also '-stände')
    t = fix_homoglyphs(t, tgt_script).strip('<> ')
    if not t:
        return None
    if _wrong_script(t, tgt_script):
        return None
    return Gloss(t, labels)


def gloss_key(text: str, lang: str) -> str:
    """Key that identifies duplicate translations ('вода' / 'вода́')."""
    k = text.lower().replace('’', "'").replace('ʼ', "'")
    if lang == 'ru':
        k = _strip_marks(k, RU_STRESS)
    elif lang == 'la':
        k = _strip_marks(k, LA_QUANTITY)
    return k


def _n_marks(text: str) -> int:
    return sum(1 for c in unicodedata.normalize('NFD', text) if unicodedata.combining(c))


def add_gloss(glosses: list, seen: dict, g: Gloss, lang: str) -> None:
    """Append g unless it duplicates one already there; prefer the form
    with stress marks / macrons."""
    k = gloss_key(g.text, lang)
    if k in seen:
        i = seen[k]
        if _n_marks(g.text) > _n_marks(glosses[i].text):
            glosses[i] = Gloss(g.text, glosses[i].labels or g.labels)
        return
    seen[k] = len(glosses)
    glosses.append(g)


# ── Definition cleaning ────────────────────────────────────────

# English Wiktionary label qualifiers that bind to the following label
# ('usually transitive'), and connectors that bind to both sides
# ('alone or postpositive'); '_' joins its neighbours with a space.
_LABEL_JOIN_NEXT = {
    'also', 'and', 'chiefly', 'especially', 'esp.', 'except', 'excluding', 'extremely',
    'frequently', 'generally', 'including', 'later', 'mainly', 'many', 'mildly', 'more',
    'mostly', 'now', 'nowadays', 'occasionally', 'of', 'often', 'or', 'originally',
    'particularly', 'possibly', 'potentially', 'primarily', 'principally', 'rarely',
    'slightly', 'sometimes', 'somewhat', 'strongly', 'than', 'then', 'typically',
    'usually', 'very', 'with', 'by', 'outside', 'in', 'formerly', 'archaically',
    'less', 'not', 'when', 'where',
}
_LABEL_JOIN_PREV = {'and', 'or', 'by', 'than', 'with', 'except', 'outside', 'in'}

_DEF_ANCHOR = re.compile(r'(?<=\w)#(?:Noun|Verb|Adjective|Adverb|Pronoun|Preposition|Conjunction|'
                         r'Interjection|Proper_noun|Etymology_\d+\w*|English|Русский)\b')
_MAINT_HUB = re.compile(r'\s*\((?:This (?:entry|sense) is a )?translation hub\.?\)\s*', re.I)
_MAINT_MOVE = re.compile(r'^\(Should we move, merge or split\(.*?\)\s*this sense\?\)\s*', re.S)
_TEMPLATE_PARAMS = re.compile(r'\|\s*[^\W\d]\w*\s*=.*\}\}', re.S)     # '|lang=fr |cat=… }}'
_ATTESTATION = re.compile(
    r'\s*\[(?:from|since|in use|attested|first attested|recorded|mid|early|late|'
    r'c\.|ca\.|circa|\d)[^\[\]]{0,80}\]\s*$', re.I)
_LATEX_SYMBOLS = {
    'alpha': 'α', 'beta': 'β', 'gamma': 'γ', 'delta': 'δ', 'epsilon': 'ε',
    'varepsilon': 'ε', 'zeta': 'ζ', 'eta': 'η', 'theta': 'θ', 'iota': 'ι',
    'kappa': 'κ', 'lambda': 'λ', 'mu': 'μ', 'nu': 'ν', 'xi': 'ξ', 'pi': 'π',
    'rho': 'ρ', 'sigma': 'σ', 'tau': 'τ', 'upsilon': 'υ', 'phi': 'φ',
    'varphi': 'φ', 'chi': 'χ', 'psi': 'ψ', 'omega': 'ω', 'Gamma': 'Γ',
    'Delta': 'Δ', 'Theta': 'Θ', 'Lambda': 'Λ', 'Xi': 'Ξ', 'Pi': 'Π',
    'Sigma': 'Σ', 'Phi': 'Φ', 'Psi': 'Ψ', 'Omega': 'Ω',
    'cdot': '·', 'times': '×', 'pm': '±', 'mp': '∓', 'div': '÷',
    'infty': '∞', 'in': '∈', 'notin': '∉', 'cup': '∪', 'cap': '∩',
    'subset': '⊂', 'subseteq': '⊆', 'supset': '⊃', 'emptyset': '∅',
    'rightarrow': '→', 'to': '→', 'leftarrow': '←', 'Rightarrow': '⇒',
    'leftrightarrow': '↔', 'Leftrightarrow': '⇔', 'mapsto': '↦',
    'leq': '≤', 'le': '≤', 'leqslant': '≤', 'geq': '≥', 'ge': '≥',
    'geqslant': '≥', 'neq': '≠', 'ne': '≠', 'approx': '≈', 'equiv': '≡',
    'sim': '∼', 'vee': '∨', 'wedge': '∧', 'neg': '¬', 'forall': '∀',
    'exists': '∃', 'partial': '∂', 'nabla': '∇', 'sum': '∑', 'prod': '∏',
    'int': '∫', 'sqrt': '√', 'circ': '∘', 'oplus': '⊕', 'otimes': '⊗',
    'perp': '⊥', 'parallel': '∥', 'angle': '∠', 'ldots': '…', 'dots': '…',
    'cdots': '⋯', 'langle': '⟨', 'rangle': '⟩', 'hbar': 'ℏ', 'ell': 'ℓ',
    'sin': 'sin', 'cos': 'cos', 'tan': 'tan', 'log': 'log', 'ln': 'ln',
    'exp': 'exp', 'lim': 'lim', 'max': 'max', 'min': 'min',
}
_BLACKBOARD = {'N': 'ℕ', 'Z': 'ℤ', 'Q': 'ℚ', 'R': 'ℝ', 'C': 'ℂ', 'P': 'ℙ', 'H': 'ℍ'}


def _latex_to_text(t: str) -> str | None:
    """Turn the simple TeX found in Wiktionary definitions into Unicode;
    None when constructs remain that cannot be shown as text."""
    t = re.sub(r'\\mathbb\{([A-Z])\}', lambda m: _BLACKBOARD.get(m.group(1), m.group(1)), t)
    for _ in range(3):
        t = re.sub(r'\\(?:text|mathrm|mathbf|mathit|mathsf|operatorname|textrm|textit|textbf)\s*\{([^{}]*)\}', r'\1', t)
        t = re.sub(r'\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}', r'(\1)/(\2)', t)
        t = re.sub(r'\\sqrt\s*\{([^{}]*)\}', r'√(\1)', t)
        t = re.sub(r'\^\{([^{}]*)\}', lambda m: ''.join(_SUP.get(c, '\x00') for c in m.group(1)), t)
        t = re.sub(r'_\{([^{}]*)\}', lambda m: ''.join(_SUB.get(c, '\x00') for c in m.group(1)), t)
    t = re.sub(r'\^([0-9a-z])', lambda m: _SUP.get(m.group(1), '\x00'), t)
    t = re.sub(r'_([0-9])', lambda m: _SUB.get(m.group(1), '\x00'), t)
    t = re.sub(r'\\([,;:!> ]|quad|qquad)', ' ', t)
    t = re.sub(r'\\([A-Za-z]+)', lambda m: _LATEX_SYMBOLS.get(m.group(1), '\x00'), t)
    t = t.replace('{,}', ',')
    if '\x00' in t or '\\' in t or re.search(r'[{}]', t):
        return None
    return t


# Superscript exponents lost upstream: 'equal to 103 metres' is 10³.
_EXP_AFTER = re.compile(
    r'(\b(?:equal to|equals|equivalent to|equivalente a|égale à|égal à|'
    r'равное|равен|gleich) )'
    r'10(2|3|6|9|12|15|18|21|24|27|30)(?= [^\W\d_]|…|$)')
# French unit definitions: '(SI), valant 103 mètres', 'millions de mètres cubes, soit 109 m3'
_EXP_FR = re.compile(r'(\b(?:valant|soit|vaut) )10(2|3|6|9|12|15|18|21|24|27|30)(?= [^\W\d_]|…|$)')
_EXP_FR_CONTEXT = re.compile(r'\bSI\b|Système international|unité|million|milliard')
_EXP_PAREN = re.compile(r'\(10(2|3|6|9|12|15|18|21|24|27|30)\)')
_EXP_SCI = re.compile(r'(= )10(\d{1,2})(?= \(1 ?E\+\2\b)')                 # '= 103 (1 E+3'
_EXP_MILLION = re.compile(r'(\(logic: 1,000,000)([23])(?=\))')               # 'million (times a) million'
_EXP_BINARY = re.compile(r'(= )2(10|20|30|40|50|60|70|80)(?= (?:Byte|Bytes|bytes|octets)\b)')
_ZEROS = re.compile(r'zeros|zeroes|Nullen|нул|ceros|zéros|zeri', re.I)


def _superscript(n: str, base: str = '10') -> str:
    return base + ''.join(_SUP[c] for c in n)


def _fix_exponents(t: str) -> str:
    t = _EXP_AFTER.sub(lambda m: m.group(1) + _superscript(m.group(2)), t)
    if _EXP_FR_CONTEXT.search(t):
        t = _EXP_FR.sub(lambda m: m.group(1) + _superscript(m.group(2)), t)
    t = _EXP_SCI.sub(lambda m: m.group(1) + _superscript(m.group(2)), t)
    t = _EXP_MILLION.sub(lambda m: m.group(1) + _SUP[m.group(2)], t)
    t = _EXP_BINARY.sub(lambda m: m.group(1) + _superscript(m.group(2), '2'), t)
    if _ZEROS.search(t):
        t = _EXP_PAREN.sub(lambda m: '(' + _superscript(m.group(1)) + ')', t)
    return t


def _split_en_labels(tokens: list[str]) -> list[str]:
    out: list[str] = []
    join = False
    for tok in tokens:
        if tok == '_':
            join = True
            continue
        low = tok.lower()
        if out and (join or low in _LABEL_JOIN_PREV):
            out[-1] = f'{out[-1]} {tok}'
        else:
            out.append(tok)
        join = low in _LABEL_JOIN_NEXT
    return out


# A qualifier with nothing after it ('(especially) Such a day that…',
# '(taxonomy, especially) Dark…') modifies the definition, not a label.
_DEF_QUALIFIERS = {'usually', 'especially', 'often', 'sometimes', 'chiefly', 'mostly',
                   'generally', 'typically', 'frequently', 'mainly', 'occasionally',
                   'rarely', 'originally', 'also', 'now', 'particularly', 'primarily',
                   'principally', 'esp.', 'formerly', 'commonly', 'specifically'}


_PAREN_LABEL = re.compile(r'^\(([^()]{1,80})\)[,\s]*')
_PIPE_DOMAIN = re.compile(r'^([^|]{1,80})\|\s*(.*)$', re.S)
_DE_LABEL = re.compile(r'^([^\W\d][^:()\[\]=;.]{0,58}):\s*(.*)$', re.S)
_RU_LABEL = re.compile(r'^((?:[а-яё]{2,12}\.)(?:\s?[а-яё]{1,8}\.)?)(?:,\s*|\s+)')


def _short_label(item: str, max_words: int = 3) -> bool:
    item = item.strip()
    return (bool(item) and len(item) < 40 and len(item.split()) <= max_words
            and item[0].isalpha() and not re.search(r'[=\d{}\[\]<>]', item))


def parse_sense_definition(sense_text: str, lang: str = '') -> tuple[list[str], str]:
    """Split a cleaned sense into (domain labels, definition text).

    English-style: "(usually, transitive, sometimes, _, intransitive) Text"
    French/Italian/…: "(Botanique) (Par extension) Text"
    Spanish-style:  "Química| Text"   German: "Technik, Physik: Text"
    Russian:        "устар., перен. Text"
    """
    if not sense_text:
        return [], ''
    t = sense_text
    domains: list[str] = []

    # Pipe-delimited domains (Spanish Wiktionary): "Juegos| text"
    m = _PIPE_DOMAIN.match(t)
    if m:
        items = [d.strip() for d in m.group(1).split(',') if d.strip()]
        if items and all(_short_label(d) and '.' not in d for d in items):
            domains.extend(items)
            t = m.group(2).strip()

    # Leading parenthetical label groups (not for Latin, whose parentheses
    # are part of the definition: "(De avibus, apibus etc.) īre ālīs…")
    qualifier = ''
    if lang != 'la':
        while True:
            m = _PAREN_LABEL.match(t)
            if not m:
                break
            inner = m.group(1)
            if lang == 'en':
                items = _split_en_labels([x.strip() for x in inner.split(',') if x.strip()])
            else:
                items = [x.strip() for x in inner.split(',') if x.strip()]
            if not items or not all(len(x) < 40 and x[0].isalpha() and '=' not in x for x in items):
                break
            if lang == 'en' and items[-1].lower() in _DEF_QUALIFIERS:
                qualifier = items.pop()
            domains.extend(items)
            t = t[m.end():]
            if qualifier:
                break

    if lang == 'de':
        m = _DE_LABEL.match(t)
        if m:
            items = [d.strip() for d in m.group(1).split(',') if d.strip()]
            if items and all(_short_label(d) for d in items):
                domains.extend(items)
                t = m.group(2).strip()
    elif lang == 'ru':
        while True:
            m = _RU_LABEL.match(t)
            if not m or len(domains) > 4:
                break
            domains.append(m.group(1))
            t = t[m.end():]

    t = t.strip()
    if qualifier and t:
        t = f'({qualifier}) {t}'
    return domains, t


_MAX_DEF = 400


def _truncate(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[:limit]
    end = max(cut.rfind('. '), cut.rfind('; '))
    if end >= limit // 2:
        return cut[:end + 1]
    sp = cut.rfind(' ')
    return (cut[:sp] if sp > limit // 2 else cut).rstrip(' ,;:') + '…'


def clean_definition(sense: str, lang: str) -> tuple[list[str], str]:
    """Clean an upstream sense text into (labels, definition)."""
    if not sense:
        return [], ''
    t = _decode(sense)
    t = _NOWIKI.sub('', t)
    if 'Should we move' in t or 'Wiktionary%3ARequests' in t:
        t, n = _MAINT_MOVE.subn('', t)
        if not n:
            return [], ''
    t = _MAINT_HUB.sub(' ', t)
    t = _TEMPLATE_PARAMS.sub(' ', t)
    t = re.sub(r'DEFAULTSORT.*$', '', t, flags=re.S)
    t = re.sub(r'\s*:\*.*$', '', t, flags=re.S)                # ':*\nColor:' list residue
    t = re.sub(r'\(\)\}+|\s*\}\}', '', t)
    t = t.replace('||', ';')
    t = _WS.sub(' ', t).strip()
    if re.match(r'(?:singolare|plurale)\s+(?:singolare|plurale)\b', t):
        return [], ''                                           # Italian inflection table
    t = resolve_links(t)
    t = _DEF_ANCHOR.sub('', t)                                  # 'detectable#Adjective'
    t = _SUPSUB.sub(_supsub, t)
    t = _TAG.sub('', t) if re.search(r'</?(?:sup|sub|i|b|u|span|small|br)\b', t) else t
    if lang == 'la':
        t = re.sub(r'^√\s*', '', t)
    if '\\' in t or '^{' in t or '_{' in t:
        t = _latex_to_text(t)
        if t is None:
            return [], ''
    t = _fix_exponents(t)
    while True:
        t2 = _ATTESTATION.sub('', t)
        if t2 == t:
            break
        t = t2
    t = _balance(_balance(t, '(', ')'), '[', ']')
    t = _WS.sub(' ', t).strip()
    t = re.sub(r'\(\s+', '(', re.sub(r'\s+\)', ')', t))            # '( tassonomia)'
    domains, t = parse_sense_definition(t, lang)
    t = re.sub(r'\s*:\s*\.?\s*$', '', t).strip()                # 'Canidae:' / ': .'
    t = t.strip(' ,;|')
    if not re.search(r'[^\W\d_]', t):
        t = ''
    domains = [d for d in (x.strip(' .,;:') if not x.endswith('.') else x.strip(' ,;:')
                           for x in domains) if d]
    return domains, _truncate(t, _MAX_DEF)


# ── Keys ───────────────────────────────────────────────────────

_KEY_BAD = re.compile(r'[()\[\]{}<>|"=/;:!?…#@*+%&$~≈\\]|\d|\.\.|\s[-–]|[-–]\s')
_EMOJI = re.compile('[\U0001F000-\U0001FAFF\u2600-\u27BF\uFE0F\u2B00-\u2BFF]')

# Wiktionary page names that cannot hold the real title.
_UNSUPPORTED_TITLES = {'Unsupported titles/C`num`': 'C#'}
# Upstream typos in keys.
_KEY_FIXES = {('tr', 'Gine=Bissau'): 'Gine-Bissau'}


# Gender / part-of-speech markers that Russian Wiktionary appends to
# German and French translations ('Ankömmling m', 'achten vt',
# 'abat-jour m inv.', 'Außerirdische sub m', 'sein vi irreg.', 'Arbeit sing.',
# 'tamis n.m.', 'liberté n').
_GRAMMAR_MARKER = {
    'en': re.compile(r'(?:\s+(?:vt|vi|v\.\s?t|v\.\s?i)\.?)+$'),          # 'paint vt'
    'de': re.compile(r'(?:\s+(?:sub|m|f|n|nt|mf|pl|sg|sing|vt|vi|vr|Adj|adj|Adv|adv|inv|irreg|unreg)\.?)+$'),
    'fr': re.compile(r'(?:\s+(?:n\.\s?m|n\.\s?f|nm|nf|m|f|n|mf|pl|vt|vi|vpr|inv|adj|adv|loc)\.?)+$'),
}
# The final period of a phrase or sentence goes ('palmier à cire carnauba.',
# 'Es ist angerichtet.'), and that of a long lowercase word ('bayowarisch.');
# abbreviations keep theirs ('avoir besoin de qc.', 'понед.' понедельник).
# build_direction drops a fallback 'friser.' or 'Daten.' when the word
# without the period is a headword.


def normalize_key(raw: str, lang: str) -> str:
    """Normal form of an upstream written_rep from WikDict's weak rows,
    which still carry wiki markup and Russian stress marks."""
    t = _decode(raw)
    t = resolve_links(_NOWIKI.sub('', t))
    t = _TAG.sub('', t)
    if lang == 'ru':
        t = _strip_marks(t, RU_STRESS)
    t = _NBSP.sub(' ', t)
    t = fix_homoglyphs(_WS.sub(' ', t).strip(), LANGUAGES[lang]['script'])
    while t and (unicodedata.combining(t[0]) or t[0] in '‘·†¡¿'):
        t = t[1:].lstrip()                           # '̱̱вишнёвая косточка', '‘Ilm', '¿por qué', '† fylfot'
    if t[:1] in ('‒', '–'):
        t = '-' + t[1:]                              # '‒́vel' (figure dash) -> '-́vel'
    if len(t) > 2 and t[0] in '«"“„' and t[-1] in '»"”“':
        t = t[1:-1].strip()                          # '«белый воротничок»'
    marker = _GRAMMAR_MARKER.get(lang)
    if marker:
        t = marker.sub('', t).strip()
    if re.search(r'[^\W\d_]{5}\.$' if ' ' in t else r'^[^\W\d_A-ZÀ-ÞА-ЯΑ-Ω][^\W\d_]{7,}\.$', t):
        t = t[:-1]                                   # 'palmier à cire carnauba.', 'bayowarisch.'
    if lang == 'el':
        t = t.rstrip('; ')                          # Greek question mark ('πώς είσαι;')
    if lang == 'de':
        w = t.split(' ')
        if len(w) == 3 and w[0].endswith('en') and w[0].lower().startswith(w[2].lower()):
            t = w[0]                                 # 'abgehen ging ab' -> 'abgehen'
    return t


def _run_together_affix(k: str) -> bool:
    """'mêmemoi-même' / 'selfmyself': an affix and a word that ends in it,
    run together ('-même' + 'moi-même', '-self' + 'myself')."""
    for n in range(3, len(k) // 2 + 1):
        a, rest = k[:n], k[n:]
        if len(rest) > n and rest.endswith(a):
            return True
    return False


def usable_key(key: str, lang: str) -> bool:
    """A clean, typable headword for the fallback tiers."""
    if not key or len(key) > 40 or len(key.split()) > 4:
        return False
    if key.startswith('-') and _run_together_affix(key[1:]):
        return False                          # '-mêmemoi-même', '-selfmyself'
    if _KEY_BAD.search(key) or _EMOJI.search(key):
        return False
    if not key[0].isalpha() and not (key.startswith('-') and len(key) > 1):
        return False                          # "'s", '— knee pipe', '.com'
    counts = _scripts(key)
    want = LANGUAGES[lang]['script']
    if not counts or set(counts) != {want}:
        return False
    return True


# Translations split off a longer gloss ('and tired', 'of marriage').
_FRAGMENT_START = {'en': ('and ', 'or ', 'of ', 'but ', 'nor ')}
# 'colouringcoloring', 'crewcrew member', 'woman women': two spellings run together.
_RUN_TOGETHER = re.compile(r'^([^\W\d_]{3,})[^\W\d_]*\s?\1', re.I)


def opposite_key_ok(key: str, lang: str) -> bool:
    """Extra checks for a headword taken from a translation of the opposite
    file, which is less clean than an upstream headword."""
    if re.search(r'[,—]', key) or key.startswith(_FRAGMENT_START.get(lang, ())):
        return False
    if _RUN_TOGETHER.match(key):
        return False
    return True


def is_affix(key: str) -> bool:
    return key.startswith('-') or key.endswith('-')


def skip_headword(key: str, glosses: list) -> bool:
    """Emoji 'filter-avoidance' spellings ('☪️ancer', '🍇') that have no
    real translation, only the same string or another emoji."""
    if not _EMOJI.search(key):
        return False
    return all(g.text == key or not _letters(_EMOJI.sub('', g.text)) or _EMOJI.search(g.text)
               for g in glosses)


# ── Data loading ───────────────────────────────────────────────

class Row(NamedTuple):
    lexentry: str
    pos: str
    sense_num: str
    labels: tuple
    definition: str
    glosses: tuple
    score: float


class Weak(NamedTuple):
    score: float
    forms: Counter          # raw spellings (e.g. with stress marks)
    glosses: list


def load_pair(db_path: Path, src: str, tgt: str) -> tuple[dict, dict]:
    """Load one WikDict table.

    Returns (direct, weak):
      direct: headword -> [Row]  (is_good rows + lexentry rows with score
              >= DIRECT_MIN_SCORE), sorted by score
      weak:   normalized headword -> Weak  (all other rows)
    """
    if not db_path.exists():
        sys.exit(f"ERROR: {db_path} not found. Run: scripts/fetch_data.sh wikdict")

    db = sqlite3.connect(str(db_path))
    rows = db.execute('''
        SELECT lexentry, sense_num, sense, written_rep, trans_list, score, is_good
        FROM translation
        ORDER BY written_rep, score DESC, sense_num
    ''').fetchall()
    db.close()

    direct: dict = defaultdict(list)
    weak_acc: dict = {}
    def_cache: dict = {}
    for lexentry, sense_num, sense, hw, trans_list, score, is_good in rows:
        if not hw or not trans_list:
            continue
        score = float(score or 0)
        is_direct = bool(is_good) or (bool(lexentry) and score >= DIRECT_MIN_SCORE)
        if is_direct:
            key = _UNSUPPORTED_TITLES.get(hw, hw)
            key = _KEY_FIXES.get((src, key), key)
            affix = is_affix(key)
            numeric = bool(re.search(r'\d', key))
            glosses = []
            seen: dict = {}
            for t in trans_list.split(' | '):
                g = clean_gloss(t, tgt, affix, numeric, src)
                if g:
                    add_gloss(glosses, seen, g, tgt)
            if not glosses:
                # Every translation was junk (')', '{{ | }}', a Greek word in
                # an English list): let the fallback tier rebuild the headword.
                weak_acc.setdefault(normalize_key(key, src), Weak(0.0, Counter(), []))
                continue
            ck = (sense or '')
            if ck not in def_cache:
                def_cache[ck] = clean_definition(sense or '', src)
            labels, definition = def_cache[ck]
            direct[key].append(Row(lexentry or '', extract_pos(lexentry), sense_num or '',
                                   tuple(labels), definition, tuple(glosses), score))
        else:
            key = normalize_key(hw, src)
            acc = weak_acc.get(key)
            if acc is None:
                acc = weak_acc[key] = Weak(0.0, Counter(), [])
            glosses = list(acc.glosses)
            seen = {gloss_key(g.text, tgt): i for i, g in enumerate(glosses)}
            for t in trans_list.split(' | '):
                g = clean_gloss(t, tgt, is_affix(key), bool(re.search(r'\d', key)), src)
                if g:
                    add_gloss(glosses, seen, g, tgt)
            acc.forms[_WS.sub(' ', _TAG.sub('', resolve_links(_decode(hw)))).strip()] += 1
            weak_acc[key] = Weak(max(acc.score, score), acc.forms, glosses)

    for key in direct:
        direct[key].sort(key=lambda r: -r.score)
    return dict(direct), weak_acc


def _set_key(r: "Row", lang: str) -> frozenset:
    return frozenset(gloss_key(g.text, lang) for g in r.glosses)


def build_inversion(direct_ba: dict, a: str) -> tuple[dict, dict]:
    """Index the B→A direct rows by their A translations.

    Returns (inv, forms):
      inv:   A word (normal form, see normalize_key) -> [(B headword, Row,
             aligned)], where aligned means upstream attached that
             translation set to one sense only, so the sense's definition
             can be shown as a hint.
      forms: A word (normal form) -> Counter of the spellings as written
             (Russian with stress marks: 'челове́к').
    """
    inv: dict = defaultdict(list)
    forms: dict = defaultdict(Counter)
    norm: dict = {}
    for hb, rows in direct_ba.items():
        senses: dict = defaultdict(set)
        for r in rows:
            senses[_set_key(r, a)].add((r.lexentry, r.sense_num, r.definition))
        for r in rows:
            aligned = len(senses[_set_key(r, a)]) == 1
            # A one-letter ending listed next to the word ('баварский' ->
            # 'bavarois | -e', 'улучшение' -> 'improvement | -s') is no
            # translation; an affix headword's are ('-ly' -> '-о | -е').
            ending_ok = is_affix(hb) or all(is_affix(g.text) for g in r.glosses)
            for g in r.glosses:
                if not ending_ok and g.text.startswith('-') and len(_letters(g.text)) == 1:
                    continue
                k = norm.get(g.text)
                if k is None:
                    k = norm[g.text] = normalize_key(g.text, a)
                inv[k].append((hb, r, aligned))
                forms[k][g.text] += 1
    return inv, forms


# ── Sense organisation ─────────────────────────────────────────

class Card(NamedTuple):
    pos: str
    labels: tuple            # header badges
    glosses: tuple           # Gloss, or (Gloss, hint) for reverse cards
    definition: str
    badge: str = ''          # 'via English → Português', 'inferred'


def organize_senses(rows: list, tgt: str) -> list:
    """One card per (lexical entry, sense); see the module docstring.

    rows: [Row] of one headword, sorted by score.
    """
    # How many distinct senses each translation set is attached to,
    # across the whole headword.
    def set_key(r: Row) -> frozenset:
        return _set_key(r, tgt)

    sense_count: dict = defaultdict(set)
    for r in rows:
        sense_count[set_key(r)].add((r.lexentry, r.sense_num, r.definition))

    by_lex: OrderedDict = OrderedDict()
    pos_rank: dict = {}
    for r in rows:
        by_lex.setdefault(r.lexentry or f'?{r.pos}', []).append(r)
        pos_rank.setdefault(r.pos, len(pos_rank))
    # Homonym entries stay apart, but entries of the same part of speech
    # are shown together (stable: best-scoring entry first).
    lex_order = sorted(by_lex.items(), key=lambda kv: pos_rank[kv[1][0].pos])

    cards: list = []
    for lex, lrows in lex_order:
        units: OrderedDict = OrderedDict()   # set key or definition -> merged unit
        for r in lrows:
            sk = set_key(r)
            if len(sense_count[sk]) > 1:
                ukey = ('set', sk)
            else:
                ukey = ('def', r.definition, r.labels) if (r.definition or r.labels) else ('set', sk)
            u = units.get(ukey)
            if u is None:
                u = units[ukey] = {'glosses': [], 'seen': {}, 'score': r.score,
                                   'num': r.sense_num, 'pos': r.pos,
                                   'def': r.definition if ukey[0] == 'def' else '',
                                   'labels': r.labels if ukey[0] == 'def' else ()}
            for g in r.glosses:
                add_gloss(u['glosses'], u['seen'], g, tgt)
            u['score'] = max(u['score'], r.score)
        ordered = sorted(units.values(), key=lambda u: (-u['score'], u['num']))
        for u in ordered:
            cards.append(Card(u['pos'], tuple(u['labels']), tuple(u['glosses']), u['def']))

    # Cards without a definition or label (general translations, e.g. of
    # homonym entries) only repeat each other: drop translations an earlier
    # such card of the same part of speech already lists. A translation
    # shown under one specific definition is still listed as general
    # (house: 'дом' under 'A dynasty' and as the general translation).
    shown: dict = defaultdict(set)
    out: list = []
    for c in cards:
        if not c.definition and not c.labels:
            rest = tuple(g for g in c.glosses if gloss_key(g.text, tgt) not in shown[c.pos])
            if not rest:
                continue
            c = c._replace(glosses=rest)
            shown[c.pos].update(gloss_key(g.text, tgt) for g in c.glosses)
        out.append(c)
    return out


_MAX_REVERSE = 10
_REVERSE_HINT = 90


def reverse_cards(matches: list, badge: str) -> list:
    """Cards for a headword known only from the opposite direction.

    matches: [(B headword, Row, aligned)] whose translations include the
    headword. Each B headword is listed once, under the part of speech of
    its best row; its definition is shown as a hint when aligned.
    """
    best: dict = {}
    for hb, r, aligned in matches:
        cur = best.get(hb)
        if cur is None or (r.score, aligned) > (cur[1].score, cur[2]):
            best[hb] = (hb, r, aligned)
    by_pos: OrderedDict = OrderedDict()
    for hb, r, aligned in sorted(best.values(), key=lambda x: (-x[1].score, x[0].lower())):
        by_pos.setdefault(r.pos, []).append((hb, r, aligned))
    cards = []
    for pos, items in by_pos.items():
        glosses = []
        for hb, r, aligned in items[:_MAX_REVERSE]:
            hint = ''
            if aligned:
                hint = r.definition
                if r.labels:
                    hint = f'({", ".join(r.labels)}) {hint}'.strip()
            glosses.append((Gloss(hb), _truncate(hint, _REVERSE_HINT)))
        cards.append(Card(pos, (), tuple(glosses), '', badge))
    return cards


# ── HTML generation ────────────────────────────────────────────

CSS = get_css(
    GLOSS, ORDERED_LIST, DOMAIN_BADGE,
    extra_light=(
        '.df{font-size:0.85em;color:#6e6e73;margin:6px 0 2px;padding:4px 0 4px 10px;'
        'border-left:3px solid #d1d1d6;font-style:italic;line-height:1.4}'
        f'.rh{{display:block;font-size:0.72em;color:{TEXT_SECONDARY[0]};line-height:1.35}}'
    ),
    extra_dark=f'.df{{color:#98989d;border-color:#48484a}}.rh{{color:{TEXT_SECONDARY[1]}}}',
)


def _gloss_html(item) -> str:
    if isinstance(item, Gloss):
        g, hint = item, ''
    else:
        g, hint = item
    out = ''.join(f'<span class="dm">{esc(lb)}</span> ' for lb in g.labels)
    out += esc(g.text)
    if hint:
        out += f'<span class="rh">{esc(hint)}</span>'
    return out


def build_section_html(cards: list) -> str:
    parts = []
    for c in cards:
        parts.append('<div class="sn">')
        header = []
        if c.pos:
            header.append(f'<span class="pos">{esc(c.pos)}</span>')
        if c.badge:
            header.append(f'<span class="mk">{esc(c.badge)}</span>')
        header.extend(f'<span class="dm">{esc(dm)}</span>' for dm in c.labels)
        if header:
            parts.append(f'<div class="sn-hd">{"".join(header)}</div>')
        if len(c.glosses) == 1:
            parts.append(f'<span class="gl">{_gloss_html(c.glosses[0])}</span>')
        else:
            parts.append('<ol class="d">' + ''.join(f'<li>{_gloss_html(g)}</li>' for g in c.glosses) + '</ol>')
        if c.definition:
            parts.append(f'<div class="df">{esc(c.definition)}</div>')
        parts.append('</div>')
    return ''.join(parts)


def make_entry_html(display: str, label: str, cards: list) -> str:
    """Complete article: direction label, headword, sense cards."""
    inner = dir_label(esc(label)) + headword_html(display) + build_section_html(cards)
    return wrap_entry(inner, CSS)


# ── Redirect (alias) keys ──────────────────────────────────────

# Apostrophes are left alone: the app already treats ' ’ ʼ as equal.
_LATIN_FOLD = {'æ': 'ae', 'Æ': 'Ae', 'œ': 'oe', 'Œ': 'Oe', 'ø': 'o', 'Ø': 'O',
               'ß': 'ss', 'ł': 'l', 'Ł': 'L', 'đ': 'd', 'Đ': 'D', 'ð': 'd',
               'ı': 'i', '…': '...', '–': '-'}


def fold_latin(text: str) -> str:
    """ASCII spelling of an accented loanword: 'déjà vu' -> 'deja vu'."""
    t = ''.join(_LATIN_FOLD.get(c, c) for c in text)
    nfd = unicodedata.normalize('NFD', t)
    out = []
    for c in nfd:
        if unicodedata.combining(c) and out and _script(out[-1]) == 'Latn':
            continue
        out.append(c)
    return unicodedata.normalize('NFC', ''.join(out))


_GRK_VOWELS = re.compile('[αεηιουωΑΕΗΙΟΥΩ]+')


def greek_monotonic(text: str) -> str:
    """Polytonic → monotonic Greek ('Μῶρος' -> 'Μώρος').

    A word of several syllables written with a breathing but no accent
    (upstream 'ἐσχατη', 'ἐφοδος') gets the acute on the vowel that bears
    the breathing ('έσχατη', 'έφοδος'): monotonic spelling accents every
    word of more than one syllable.
    """
    def word(m: re.Match) -> str:
        w = m.group(0)
        if ('\u0301' not in w and '\u0342' not in w and '\u0300' not in w
                and re.search('[\u0313\u0314]', w)
                and len(_GRK_VOWELS.findall(''.join(c for c in w if not unicodedata.combining(c)))) > 1):
            w = re.sub('[\u0313\u0314]', '\u0301', w, count=1)
        w = (w.replace('\u0313', '').replace('\u0314', '').replace('\u0345', '')
              .replace('\u0342', '\u0301').replace('\u0300', '\u0301'))
        n = w.count('\u0301')
        if n > 1:                                   # '\u1f44\u03c6\u03b9\u03bf\u03c6\u03bf\u03b2\u03af\u03b1' -> '\u03bf\u03c6\u03b9\u03bf\u03c6\u03bf\u03b2\u03af\u03b1'
            w = w.replace('\u0301', '', n - 1)
        return w
    nfd = unicodedata.normalize('NFD', text)
    return unicodedata.normalize('NFC', re.sub(r'[^\W\d_][\w\u0300-\u036f]*', word, nfd))


_OEWN_CACHE: dict = {}


def _load_oewn() -> tuple[dict, list, frozenset]:
    """Irregular forms (form -> {(lemma, pos)}), British/American spelling
    pairs and the set of lemmas from the Open English WordNet JSON in data/."""
    if 'v' in _OEWN_CACHE:
        return _OEWN_CACHE['v']
    forms: dict = defaultdict(set)
    syn_spell: dict = defaultdict(lambda: {'b': set(), 'a': set()})
    lemmas: set = set()
    files = sorted(DATA_ROOT.glob('entries-*.json'))
    for p in files:
        data = json.loads(p.read_text(encoding='utf-8'))
        lemmas.update(data)
        for lemma, by_pos in data.items():
            for pos, info in by_pos.items():
                for f in info.get('form', []):
                    forms[f].add((lemma, pos))
                for s in info.get('sense', []):
                    ex = ' '.join(s.get('exemplifies', []))
                    if 'british_spelling' in ex:
                        syn_spell[s['synset']]['b'].add(lemma)
                    if 'american_spelling' in ex:
                        syn_spell[s['synset']]['a'].add(lemma)
    pairs = set()
    for v in syn_spell.values():
        if len(v['b']) == 1 and len(v['a']) == 1:
            pairs.add((next(iter(v['b'])), next(iter(v['a']))))
    if not files:
        sys.exit("ERROR: no data/entries-*.json (Open English WordNet), which the English "
                 "WikDict files need for their inflection and UK/US spelling redirects. "
                 "Run: scripts/fetch_data.sh wordnet")
    _OEWN_CACHE['v'] = (dict(forms), sorted(pairs), frozenset(lemmas))
    return _OEWN_CACHE['v']


# Common British/American pairs, in case WordNet misses one.
_UK_US = [
    ('colour', 'color'), ('grey', 'gray'), ('theatre', 'theater'), ('centre', 'center'),
    ('metre', 'meter'), ('litre', 'liter'), ('fibre', 'fiber'), ('calibre', 'caliber'),
    ('defence', 'defense'), ('offence', 'offense'), ('licence', 'license'),
    ('programme', 'program'), ('catalogue', 'catalog'), ('dialogue', 'dialog'),
    ('analyse', 'analyze'), ('paralyse', 'paralyze'), ('behaviour', 'behavior'),
    ('honour', 'honor'), ('flavour', 'flavor'), ('harbour', 'harbor'),
    ('favour', 'favor'), ('favourite', 'favorite'), ('neighbour', 'neighbor'),
    ('humour', 'humor'), ('labour', 'labor'), ('rumour', 'rumor'), ('vapour', 'vapor'),
    ('armour', 'armor'), ('odour', 'odor'), ('valour', 'valor'), ('vigour', 'vigor'),
    ('mould', 'mold'), ('plough', 'plow'), ('pyjamas', 'pajamas'),
    ('aluminium', 'aluminum'), ('jewellery', 'jewelry'), ('sceptic', 'skeptic'),
    ('sceptical', 'skeptical'), ('manoeuvre', 'maneuver'), ('oestrogen', 'estrogen'),
    ('anaemia', 'anemia'), ('paediatrician', 'pediatrician'), ('encyclopaedia', 'encyclopedia'),
    ('moustache', 'mustache'), ('cheque', 'check'), ('tyre', 'tire'), ('kerb', 'curb'),
    ('storey', 'story'), ('draught', 'draft'), ('gaol', 'jail'), ('artefact', 'artifact'),
    ('ageing', 'aging'), ('judgement', 'judgment'), ('travelling', 'traveling'),
    ('cancelled', 'canceled'), ('jewellery', 'jewelry'), ('mum', 'mom'),
]

_VOWELS = 'aeiou'
# Nouns in -man whose plural is -mans.
_MAN_PLURAL_S = {'human', 'german', 'shaman', 'talisman', 'caiman', 'cayman', 'ottoman',
                 'roman', 'dolman', 'hetman', 'ataman', 'firman', 'desman', 'superhuman',
                 'nonhuman', 'subhuman', 'posthuman', 'inhuman', 'walkman', 'pacman'}


# Longer verbs that end in -ing themselves (hamstring, bowstring, upswing).
_ING_VERBS = ('string', 'spring', 'swing', 'sting', 'sling', 'cling', 'fling', 'wring', 'bring')
# Verbs whose final -l syllable is stressed keep -ll- in American English
# too (controlled, compelled), unlike travel -> traveled.
_STRESSED_FINAL_L = ('control', 'patrol', 'pel', 'rebel', 'excel', 'enrol', 'extol',
                     'distil', 'fulfil', 'instil', 'annul', 'appal', 'enthral', 'befal')


def _english_regular(lemma: str, pos: str, listed: frozenset = frozenset(),
                     lemmas: frozenset = frozenset(), short_ok: bool = False) -> list[str]:
    """Regular inflections of a one-word English noun or verb.

    listed: the forms WordNet lists for this lemma and part of speech
    (irregular ones, and doubled consonants such as stopped/preferred);
    a regular form of the same kind is not generated next to them.
    lemmas: known English lemmas (WordNet and the dictionary's own keys),
    to recognise forms that are already inflected (anchored, breaking).
    short_ok: a two-letter noun that is only a noun ('ad' -> 'ads'), not a
    pronoun or particle ('it', 'he', 'in').
    """
    w = lemma
    if not w.isalpha() or not w.islower() or len(w) < 2:
        return []
    def plural(x: str, verb: bool = False) -> str:
        if not verb and x.endswith('man') and x not in _MAN_PLURAL_S:
            return x[:-3] + 'men'                   # woman, fireman (WordNet's rule, not listed)
        if not verb and x.endswith('sis'):
            return x[:-2] + 'es'                    # analysis -> analyses
        if x.endswith(('s', 'x', 'z', 'ch', 'sh')):
            return x + 'es'
        if x.endswith('y') and x[-2] not in _VOWELS:
            return x[:-1] + 'ies'
        if verb and x.endswith('o') and not x.endswith('oo'):
            return x + 'es'                         # goes, echoes
        return x + 's'
    if pos == 'n.':
        if listed or (len(w) < 3 and not short_ok):
            return []                               # 'he' -> 'hes', 'in' -> 'ins'
        if w.endswith(('ics', 'ies', 'itis', 'ings', 'eds')):
            return []                               # acoustics, series, adenitis, heartstrings, classifieds
        if w.endswith('s') and not w.endswith(('ss', 'us', 'is', 'as', 'lens')):
            return []                               # rings, airwaves, abs, biceps, backwoods: already plural
        return [plural(w)]
    if pos not in ('v.', 'v.t.', 'v.i.'):
        return []
    if len(w) >= 4 and (
            (w.endswith('s') and not w.endswith(('ss', 'us', 'is')) and w[:-1] in lemmas)
            or (len(w) >= 6 and w.endswith('ed') and not w.endswith('eed')
                and (w[:-2] in lemmas or w[:-1] in lemmas or w.startswith('un')
                     or (w[-3] == w[-4] and w[:-3] in lemmas)))
            or (len(w) >= 6 and w.endswith('ing')
                and (w[:-3] in lemmas or w[:-3] + 'e' in lemmas
                     or (w[-4] == w[-5] and w[:-4] in lemmas)
                     or (len(w) >= 7 and not w.endswith(_ING_VERBS))))):
        return []                                   # already inflected: 'rings', 'anchored', 'embedded', 'starring'
    out = []
    if not any(f.endswith('s') for f in listed):
        out.append(plural(w, verb=True))
    past_listed = any(not f.endswith(('s', 'ing')) for f in listed)    # went, made, stopped
    ing_listed = any(f.endswith('ing') for f in listed)                  # stopping, lying
    cvc = (len(w) >= 3 and w[-1] not in _VOWELS + 'wxy' and w[-2] in _VOWELS
           and w[-3] not in _VOWELS)
    syllables = len(re.findall(r'[aeiouy]+', w))
    if w.endswith('e'):
        past = w + 'd'
        ing = (w[:-2] + 'ying' if w.endswith('ie') else
               (w + 'ing' if w.endswith(('ee', 'ye', 'oe')) or len(w) == 2 else w[:-1] + 'ing'))
    elif w.endswith('y') and w[-2] not in _VOWELS:
        past, ing = w[:-1] + 'ied', w + 'ing'
    elif w.endswith('ic') and len(w) >= 4:
        past, ing = w + 'ked', w + 'king'          # panic -> panicked
    elif cvc and syllables == 1:
        # stop -> stopped; longer words depend on stress (visited vs
        # preferred), and WordNet lists the doubled ones.
        past, ing = w + w[-1] + 'ed', w + w[-1] + 'ing'
    else:
        past, ing = w + 'ed', w + 'ing'
    if not past_listed:
        out.append(past)
    if not ing_listed:
        out.append(ing)
    if (w.endswith('l') and w + 'led' in listed       # travelled (UK) -> traveled (US)
            and not w.endswith(_STRESSED_FINAL_L)):
        out += [f for f in (w + 'ed', w + 'ing') if f not in listed]
    return out


_FUNCTION_POS = {'pron.', 'prep.', 'conj.', 'det.', 'art.', 'interj.', 'adv.', 'part.',
                 'prep. phr.', 'contr.', 'abbr.', 'sym.', 'letter', 'num.'}


def english_aliases(keys: set, pos_by_key: dict) -> list:
    """Redirects for English headwords: inflected forms, British/American
    spellings, ASCII spellings, abbreviations without the final period.

    Returns [(alias, target, strong)]; strong marks WordNet's irregular
    forms (found -> find, saw -> see, left -> leave).
    """
    forms, pairs, wn_lemmas = _load_oewn()
    lemmas = wn_lemmas | {k.lower() for k in keys}
    out = []
    pos_name = {'n': 'n.', 'v': 'v.', 'a': 'adj.', 's': 'adj.', 'r': 'adv.'}
    listed: dict = defaultdict(set)          # (lemma, 'n.'/'v.'/…) -> WordNet forms
    for form, owners in forms.items():
        for lemma, pos in owners:
            listed[(lemma, pos_name.get(pos, pos))].add(form)
            if lemma in keys and form != lemma:
                out.append((form, lemma, True))
    # Regular forms (dogs, walked, houses)
    for key, poss in pos_by_key.items():
        short_ok = not (poss & _FUNCTION_POS) and not key.endswith('y')     # 'ly' -> 'lies'
        for pos in poss:
            wn_pos = 'n.' if pos == 'n.' else 'v.'
            for f in _english_regular(key, pos, frozenset(listed.get((key, wn_pos), ())), lemmas,
                                      short_ok):
                out.append((f, key, False))
    # British / American spellings, both ways (the filter keeps the useful one)
    for uk, us in list(pairs) + _UK_US:
        out.append((us, uk, False))
        out.append((uk, us, False))
    for key in keys:
        if (len(key) >= 6 and key.endswith(('ize', 'ization', 'izing', 'ized', 'izes', 'yze'))
                and not re.search(r'(?:siz|priz|seiz)(?:e|es|ed|ing)$', key)):   # resize, capsize
            alt = re.sub(r'iz(e|ation|ing|ed|es)$', r'is\1', key)
            alt = re.sub(r'yze$', 'yse', alt)
            out.append((alt, key, False))
        folded = fold_latin(key)
        if folded != key:
            out.append((folded, key, False))
        if key.endswith('.') and len(key) > 2:
            out.append((key.rstrip('.'), key, False))
            nodots = key.replace('.', '')
            if len(nodots) >= 3:
                out.append((nodots, key, False))
    return out


def source_aliases(keys: set, src: str) -> list:
    """Redirects for spellings a native keyboard produces."""
    out = []
    for key in keys:
        if src == 'ru' and ('ё' in key or 'Ё' in key):
            out.append((key.replace('ё', 'е').replace('Ё', 'Е'), key, False))
        elif src == 'tr':
            if 'İ' in key:
                out.append((key.replace('İ', 'I'), key, False))     # matches 'istanbul'
            if re.search('[âîûÂÎÛ]', key):
                out.append((key.translate(str.maketrans('âîûÂÎÛ', 'aiuAIU')), key, False))
            if 'I' in key:                                    # Irak -> ırak
                out.append((key.replace('I', 'ı').replace('İ', 'i').lower(), key, False))
        elif src == 'la' and re.search('[\u0304\u0306]', unicodedata.normalize('NFD', key)):
            out.append((_strip_marks(key, LA_QUANTITY), key, False))
        elif src == 'el' and re.search('[\u1f00-\u1fff]', key):
            out.append((greek_monotonic(key), key, False))
        elif src in ('es', 'pt') and key.startswith('-\u0301'):
            out.append(('-' + key[2:], key, False))
    return out


# ── Direction builder ──────────────────────────────────────────

def build_direction(src: str, tgt: str, direct_ab: dict, weak_ab: dict, direct_ba: dict) -> tuple[list, list, dict]:
    """Articles and redirects of one A→B file.

    Returns (articles [(key, html)], redirects [(key, target)], stats).
    """
    la, lb = LANGUAGES[src], LANGUAGES[tgt]
    label = f'{la["flag"]} {la["name_native"]} → {lb["name_native"]} {lb["flag"]}'
    via = f'via {lb["name_native"]} → {la["name_native"]}'
    stats = Counter()

    inv, inv_forms = build_inversion(direct_ba, src)

    def matches_for(key: str) -> list:
        """B→A rows that translate into key."""
        return inv.get(key) or []

    def stressed_form(key: str, forms) -> str:
        if src == 'ru':
            stressed = {f for f in forms if _strip_marks(f, RU_STRESS) == key and f != key}
            if len(stressed) == 1:
                return stressed.pop()
        return key

    def identity_name(key: str, cards: list) -> bool:
        words = [(g if isinstance(g, Gloss) else g[0]).text for c in cards for g in c.glosses]
        return key[0].isupper() and all(w.lower() == key.lower() for w in words)

    articles: list = []
    keys: set = set()
    pos_by_key: dict = defaultdict(set)
    for hw, rows in direct_ab.items():
        cards = organize_senses(rows, tgt)
        if not cards:
            continue
        if skip_headword(hw, [g for c in cards for g in c.glosses]):
            stats['skipped_emoji'] += 1
            continue
        if max(r.score for r in rows) < GOOD_SCORE:
            # Only rows below WikDict's cut-off ('nasty' -> 'nuisible'):
            # add what the B→A data has as well.
            shown = {gloss_key(g.text, tgt) for c in cards for g in c.glosses}
            extra = [m for m in matches_for(hw) or matches_for(normalize_key(hw, src))
                     if gloss_key(m[0], tgt) not in shown]
            if extra:
                cards = cards + reverse_cards(extra, via)
                stats['direct_plus_reverse'] += 1
        articles.append((hw, make_entry_html(hw, label, cards)))
        keys.add(hw)
        for r in rows:
            if r.pos:
                pos_by_key[hw].add(r.pos)
        stats['direct'] += 1

    direct_keys = set(keys)

    # Headwords that only have weak rows: rebuild them from B→A.
    plain_keys = {_strip_marks(k, LA_QUANTITY) for k in keys} if src == 'la' else keys
    for key, weak in weak_ab.items():
        if key in keys or not usable_key(key, src):
            continue
        if src == 'la' and _strip_marks(key, LA_QUANTITY) in plain_keys:
            continue
        cards = []
        matches = matches_for(key)
        if matches:
            cards = reverse_cards(matches, via)
            tier = 'reverse'
        elif weak.score >= INFERRED_MIN_SCORE and weak.glosses and not is_affix(key):
            cards = [Card('', (), tuple(weak.glosses[:_MAX_REVERSE]), '', 'inferred')]
            tier = 'inferred'
        if not cards:
            stats['weak_dropped'] += 1
            continue
        if identity_name(key, cards):
            stats['weak_identity_name'] += 1     # 'Llandygwydd' -> 'Llandygwydd'
            continue
        display = stressed_form(key, weak.forms)
        articles.append((key, make_entry_html(display, label, cards)))
        keys.add(key)
        stats[tier] += 1

    # Words that upstream has only as translations in the B→A file (PT-ES
    # 'amigo' from es-pt 'amigo' -> 'amigo'), when at least one of those
    # rows is a good one attached to a single sense.
    if src == 'la':
        plain_keys = {_strip_marks(k, LA_QUANTITY) for k in keys}
    for key in sorted(inv):
        if key in keys or not usable_key(key, src) or not opposite_key_ok(key, src):
            continue
        if src == 'la' and _strip_marks(key, LA_QUANTITY) in plain_keys:
            continue
        matches = matches_for(key)
        good = {hb for hb, r, aligned in matches if aligned and r.score >= GOOD_SCORE}
        if not good:
            continue
        if ' ' not in key and len(key) <= 3 and not key.isupper() and len(good) < 2:
            continue                             # 'le', 'ing', 'w' split off longer glosses
        cards = reverse_cards(matches, via)
        if identity_name(key, cards):
            stats['opposite_identity_name'] += 1
            continue
        articles.append((key, make_entry_html(stressed_form(key, inv_forms[key]), label, cards)))
        keys.add(key)
        stats['opposite_only'] += 1

    # A fallback 'friser.' or 'Daten.' next to the headword 'friser' or
    # 'Daten' is the same word with a stray period; short abbreviations
    # ('Dr.', 'Mme.', 'понед.') keep their own article.
    dotted = {k for k in keys - direct_keys
              if k.endswith('.') and ' ' not in k and k[:-1] in keys
              and re.search(r'[^\W\d_]{5}\.$', k)}
    if dotted:
        articles = [(k, h) for k, h in articles if k not in dotted]
        keys -= dotted
        stats['weak_dropped_period'] = len(dotted)

    # Redirects. The app shows every record whose key matches, so an alias
    # may equal an existing headword: 'все' shows все and всё, 'ırak' shows
    # ırak 'far' and Irak 'Iraq', 'resume' shows resume and résumé. An
    # English alias that is only a fallback article points to direct
    # articles only ('colour' -> 'color'); spellings of the source
    # language's own keyboard (е for ё, I for İ, no macrons, monotonic
    # Greek) always point to their key.
    cand = [(alias, target, True) for alias, target, _ in source_aliases(keys, src)]
    if src == 'en':
        cand += [(alias, target, False) for alias, target, _ in english_aliases(keys, pos_by_key)]
    redirects = []
    seen = set()
    for alias, target, keyboard in cand:
        alias = alias.strip()
        if not alias or alias == target or target not in keys:
            continue
        if (not keyboard and alias in keys and alias not in direct_keys
                and target not in direct_keys):
            continue
        if (alias, target) in seen:
            continue
        seen.add((alias, target))
        redirects.append((alias, target))
    stats['redirects'] = len(redirects)
    return articles, redirects, stats


def write_entries(path: Path, articles: list, redirects: list) -> int:
    records = [(k, h) for k, h in articles] + [(a, f'@@@LINK={t}') for a, t in redirects]
    # Total order (the body breaks ties), so the file does not depend on
    # set iteration order and a rebuild is byte-identical.
    records.sort(key=lambda kv: (kv[0].lower(), kv[0], kv[1].startswith('@@@'), kv[1]))
    with open(path, 'w', encoding='utf-8') as f:
        for k, body in records:
            f.write(f"{k}\n{body}\n</>\n")
    return len(records)


# What the redirects of an A→B file cover, by source language.
_REDIRECT_NOTE = {
    'en': ('inflected forms and UK/US and unaccented spellings (English forms and spelling '
           'pairs from <a href="https://en-word.net/">Open English WordNet</a>, CC BY 4.0)'),
    'ru': 'spellings with е for ё',
    'tr': 'spellings without İ and circumflex accents',
    'la': 'spellings without macrons',
    'el': 'monotonic spellings of polytonic headwords',
    'es': 'suffixes written without the accent mark',
    'pt': 'suffixes written without the accent mark',
}


def describe(src: str, tgt: str, n_redirects: int, n_inferred: int = 0) -> tuple[str, str]:
    """(MDX header description HTML, one-line catalog description)."""
    a, b = LANGUAGES[src]['name_en'], LANGUAGES[tgt]['name_en']
    other = f'{b}–{a}'
    changes = ('translations filtered, cleaned and grouped by sense; headwords this direction lacks '
               f'rebuilt from the {other} data (marked “via …”)')
    if n_inferred:
        changes += '; a few use WikDict’s own inferred translations (marked “inferred”)'
    if n_redirects and src in _REDIRECT_NOTE:
        changes += f'; redirects added for {_REDIRECT_NOTE[src]}'
    desc = (
        f"<p><b>WikDict {a}-{b}</b></p>"
        f"<p>{a} → {b} translations from <a href=\"https://www.wiktionary.org/\">Wiktionary</a> "
        f"(by the Wiktionary contributors), via "
        f"<a href=\"https://kaiko.getalp.org/about-dbnary/\">DBnary</a> (Gilles Sérasset) and "
        f"<a href=\"https://www.wikdict.com/\">WikDict</a> (Karl Bartel), "
        f"WikDict release {WIKDICT_RELEASE}.</p>"
        f"<p>License: <a href=\"https://creativecommons.org/licenses/by-sa/4.0/\">CC BY-SA 4.0</a> "
        f"(DBnary dataset: <a href=\"https://creativecommons.org/licenses/by-sa/3.0/\">CC BY-SA 3.0</a>).</p>"
        f"<p>Converted to MDict and modified by OpenMDict: {changes}.</p>"
    )
    if src != 'en':
        desc += f"<p>Inflected {a} forms are not listed: look up the dictionary form.</p>"
    line = (f"{a}-{b} translations from Wiktionary (via DBnary and WikDict {WIKDICT_RELEASE}), "
            f"grouped by sense.")
    if src == 'la':
        desc += ("<p>Latin Wiktionary has few translations into English, so most entries are "
                 "rebuilt from the English–Latin data.</p>")
        line = (f"Latin-English translations from Wiktionary (via DBnary and WikDict "
                f"{WIKDICT_RELEASE}); most entries rebuilt from the English–Latin data.")
    return desc, line


def build_file(src: str, tgt: str, direct_ab: dict, weak_ab: dict, direct_ba: dict,
               inputs: list) -> tuple[Path, int] | None:
    A, B = src.upper(), tgt.upper()
    name = f"WikDict-{A}-{B}"
    out_dir = OUTPUT_DIR / name
    out_dir.mkdir(parents=True, exist_ok=True)
    txt = out_dir / f"wikdict_{src}_{tgt}_entries.txt"

    print(f"\n--- {A}→{B} ---")
    articles, redirects, stats = build_direction(src, tgt, direct_ab, weak_ab, direct_ba)
    count = write_entries(txt, articles, redirects)
    print(f"  {len(articles)} articles + {len(redirects)} redirects = {count} records  {dict(stats)}")

    a, b = LANGUAGES[src]['name_en'], LANGUAGES[tgt]['name_en']
    title = f"WikDict {a}-{b}"
    desc, line = describe(src, tgt, len(redirects), stats['inferred'])
    mdx_path = out_dir / f"{name}.mdx"
    ok, size, _ = pack_mdx(txt, title, desc, mdx_path, inputs=inputs)
    if not ok:
        return None
    print(f"  ✓ {mdx_path.name}: {size:.1f} MB")
    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name=title,
        description=line,
        direction={"src": A, "dest": [B]},
        entries=count,
        license="CC-BY-SA-4.0",
        data_source="WikDict",
        tier=3,
    )
    return mdx_path, count


def build_pair(code_a: str, code_b: str) -> tuple[list, dict]:
    """Build WikDict-{A}-{B}.mdx and WikDict-{B}-{A}.mdx."""
    print(f"\n{'='*60}")
    print(f"Building WikDict {LANGUAGES[code_a]['name_en']}↔{LANGUAGES[code_b]['name_en']}")
    print(f"{'='*60}")
    ab_path = DATA_DIR / f"{code_a}-{code_b}.sqlite3"
    ba_path = DATA_DIR / f"{code_b}-{code_a}.sqlite3"
    if 'en' in (code_a, code_b):
        _load_oewn()                 # exits when the WordNet data is missing
    print(f"Loading {ab_path.name} and {ba_path.name}...")
    direct_ab, weak_ab = load_pair(ab_path, code_a, code_b)
    direct_ba, weak_ba = load_pair(ba_path, code_b, code_a)
    print(f"  {code_a}→{code_b}: {len(direct_ab)} direct, {len(weak_ab)} weak headwords")
    print(f"  {code_b}→{code_a}: {len(direct_ba)} direct, {len(weak_ba)} weak headwords")
    inputs = [ab_path, ba_path]
    if 'en' in (code_a, code_b):
        inputs += sorted(DATA_ROOT.glob('entries-*.json'))
    results = []
    for s, t, d_st, w_st, d_ts in ((code_a, code_b, direct_ab, weak_ab, direct_ba),
                                   (code_b, code_a, direct_ba, weak_ba, direct_ab)):
        r = build_file(s, t, d_st, w_st, d_ts, inputs)
        if r:
            results.append(r)
    return results, {code_a: direct_ab, code_b: direct_ba}


# ── Previews ───────────────────────────────────────────────────

SAMPLE_WORDS = {
    'en': ['hello', 'bank', 'computer', 'house', 'water', 'love', 'run'],
    'fr': ['bonjour', 'maison', 'eau', 'avocat', 'aujourd’hui'],
    'de': ['Haus', 'Wasser', 'schön', 'laufen', 'Schloss'],
    'es': ['casa', 'agua', 'comer', 'dar', 'llevar'],
    'ru': ['дом', 'вода', 'кошка', 'бежать', 'человек'],
    'pt': ['casa', 'água', 'comer', 'você', 'obrigado'],
    'it': ['casa', 'acqua', 'mangiare', 'grazie'],
    'tr': ['ev', 'su', 'güzel', 'İstanbul'],
    'la': ['aqua', 'domus', 'rex', 'amor', 'liber'],
    'el': ['σπίτι', 'νερό', 'γάτα', 'ημέρα'],
}


def _generate_preview(code_a: str, code_b: str) -> None:
    """Preview HTML (both directions) from the entries files just written."""
    entries_html = []
    for s, t in ((code_a, code_b), (code_b, code_a)):
        txt = OUTPUT_DIR / f"WikDict-{s.upper()}-{t.upper()}" / f"wikdict_{s}_{t}_entries.txt"
        wanted = set(SAMPLE_WORDS.get(s, [])[:5])
        with open(txt, encoding='utf-8') as f:
            lines = f.read().split('\n</>\n')
        for rec in lines:
            k, _, body = rec.partition('\n')
            if k in wanted and not body.startswith('@@@'):
                entries_html.append(body)
                wanted.discard(k)
    title = f'WikDict {LANGUAGES[code_a]["name_en"]}↔{LANGUAGES[code_b]["name_en"]} — preview'
    for dirname in (f"WikDict-{code_a.upper()}-{code_b.upper()}", f"WikDict-{code_b.upper()}-{code_a.upper()}"):
        d = OUTPUT_DIR / dirname
        _shared_preview(entries_html, d / f"wikdict_{dirname.lower().replace('-', '_')}_preview.html", title)


# ── Entry point ────────────────────────────────────────────────

CROSS_PAIR_SET = {f"{a}-{b}" for a, b in CROSS_PAIRS}


def main():
    args = sys.argv[1:]

    en_langs = []
    cross_pairs = []
    for arg in args:
        if '-' in arg and arg in CROSS_PAIR_SET:
            a, b = arg.split('-', 1)
            cross_pairs.append((a, b))
        elif arg in LANGUAGES and arg != 'en':
            en_langs.append(arg)
        elif arg == '--all':
            en_langs = [k for k in LANGUAGES if k != 'en']
            cross_pairs = list(CROSS_PAIRS)
        elif arg == '--cross':
            cross_pairs = list(CROSS_PAIRS)
        else:
            print(f"Unknown argument: {arg}")
            print(f"  EN↔XX languages: {', '.join(k for k in LANGUAGES if k != 'en')}")
            print(f"  Cross-pairs: {', '.join(sorted(CROSS_PAIR_SET))}")
            print(f"  Flags: --all (everything), --cross (all cross-pairs)")
            continue

    if not args:
        en_langs = [k for k in LANGUAGES if k != 'en']

    for code in en_langs:
        results, _ = build_pair(code, 'en')
        if results:
            _generate_preview(code, 'en')

    for code_a, code_b in cross_pairs:
        results, _ = build_pair(code_a, code_b)
        if results:
            _generate_preview(code_a, code_b)


if __name__ == '__main__':
    main()
