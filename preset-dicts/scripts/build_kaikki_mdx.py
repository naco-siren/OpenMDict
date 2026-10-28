#!/usr/bin/env python3
"""
Build bilingual MDX dictionaries from Kaikki.org (Wiktextract) JSONL data.

Uses per-language extracts from the English Wiktionary edition, which contain
foreign-language headwords with English glosses, IPA, examples, and more.

Supports: Spanish, Arabic, French, Russian, Italian, Portuguese,
          Greek, Turkish, Latin, Korean

Usage:
    python3 build_kaikki_mdx.py          # build all languages
    python3 build_kaikki_mdx.py es       # build Spanish only
    python3 build_kaikki_mdx.py fr ru    # build French and Russian

Input:  ../data/kaikki-{Language}.jsonl
Output: ../output/Kaikki-{XX}-EN/Kaikki-{XX}-EN.mdx

How the keys are built (the app shows EVERY record of a key, follows one
@@@LINK hop, and shows only the FIRST record of a @@@LINK target):

1. Article keys. Every page title with at least one real (non form-of)
   sense gets exactly one article record, written first. The article
   renders all the page's records, including its form-of senses as
   "plural of <entry://base>" lines.
2. Form keys. A title whose senses are all form-of ("plural of X",
   "first-person singular present indicative of Y") gets one @@@LINK per
   lemma it resolves to. An article key that is also an inflection of
   other lemmas ("sono" -> essere, suonare) gets those @@@LINKs after its
   article. Bases are resolved through the sense's own same-language
   links, the page titles, the forms[] 'canonical' spellings and a
   per-language mark fold (amō -> amo, كَتَبَ -> كتب), sanitized when
   upstream left junk ('avere and', '령/영', 'niño Boys or children'),
   and flattened through chains (form -> form -> lemma), so every target
   is an article key. A form whose base never reaches an article is
   kept as a small article of its own.
3. Inflection-table keys (Korean, Greek, Turkish, Latin): conjugation /
   declension forms[] that have no page of their own -> @@@LINK lemma
   (not from tables of bare endings or of another word, not forms that
   start with a dash or a symbol; see table_forms()).
4. Canonical keys (Latin, Russian, Arabic): the marked spelling of a
   lemma (amō, соба́ка, كِتَاب) -> @@@LINK lemma, for pasted text.
   Arabic nouns and adjectives also get their definite form (اللغة),
   and defective (manqūṣ) ones their -ي spellings (محامي, المحامي).
5. Typing-variant keys: spellings the keyboard or habit produces that
   are not keys (Arabic bare alef / ي / ه, Russian е for ё, French oe
   for œ, Greek without tonos, Turkish dotted/dotless i and no
   circumflex) -> @@@LINK to the article(s). A variant that is already
   a page keeps its records first and gets the @@@LINKs after them
   (Turkish ırak 'far' then Irak; Russian все then всё). Greek variants
   of class-3 keys only become new keys.
Classes 3-4 only add keys that do not exist yet (case-insensitively).
"""

import json
import re
import sys
import unicodedata
from collections import Counter
from difflib import SequenceMatcher
from itertools import combinations
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, PRONUNCIATION, ROMANIZATION, GLOSS, \
    ORDERED_LIST, DOMAIN_BADGE, TAG_BADGE, EXAMPLES_BILINGUAL, \
    TEXT_SECONDARY, TEXT_LINK
from shared.html import esc, esc_attr, dir_attr, has_rtl, strip_bidi_controls
from shared.build import pack_mdx, generate_preview, write_catalog_metadata, \
    description_html

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output"

# Month the kaikki-{Language}.jsonl extracts were downloaded; stated in the
# MDX header description and kept constant so the header is reproducible.
KAIKKI_DOWNLOADED = "February 2026"

# ── Language definitions ───────────────────────────────────────
#
# wiki        Language section name on English Wiktionary; same-language
#             sense links point to "<title>#<wiki>".
# fold        Marks removed when resolving a form-of base to a page title.
# variants    Typing-variant generators (see VARIANT_FUNCS).
# canon_keys  Add the lemma's marked canonical spelling as a key.
# tables      Inflection-table policy for forms[] keys (see table_forms()).
# infl_resolve  Resolve a base that has no page of its own through the
#             lemmas' inflection tables (Latin participles: tirāns -> tīrō).
# table_variants_new  Typing variants of inflection-table keys only become
#             new keys, never extra @@@LINKs on a page (Greek: a form typed
#             without tonos is often another word, ού -> ου, άς -> ας;
#             Turkish kârdan -> the page kardan keeps kâr).

LANGUAGES = {
    'es': {
        'code': 'es',
        'name_en': 'Spanish',
        'name_native': 'Español',
        'flag': '\U0001F1EA\U0001F1F8',  # 🇪🇸
        'file': 'kaikki-Spanish.jsonl',
        'rtl': False,
    },
    'ar': {
        'code': 'ar',
        'name_en': 'Arabic',
        'name_native': 'العربية',
        'flag': '\U0001F1F8\U0001F1E6',  # 🇸🇦
        'file': 'kaikki-Arabic.jsonl',
        'rtl': True,
        'fold': 'ar',
        'variants': ('ar',),
        'canon_keys': True,
    },
    'fr': {
        'code': 'fr',
        'name_en': 'French',
        'name_native': 'Français',
        'flag': '\U0001F1EB\U0001F1F7',  # 🇫🇷
        'file': 'kaikki-French.jsonl',
        'rtl': False,
        'variants': ('fr',),
    },
    'ru': {
        'code': 'ru',
        'name_en': 'Russian',
        'name_native': 'Русский',
        'flag': '\U0001F1F7\U0001F1FA',  # 🇷🇺
        'file': 'kaikki-Russian.jsonl',
        'rtl': False,
        'fold': 'ru',
        'variants': ('ru',),
        'canon_keys': True,
    },
    'it': {
        'code': 'it',
        'name_en': 'Italian',
        'name_native': 'Italiano',
        'flag': '\U0001F1EE\U0001F1F9',  # 🇮🇹
        'file': 'kaikki-Italian.jsonl',
        'rtl': False,
    },
    'pt': {
        'code': 'pt',
        'name_en': 'Portuguese',
        'name_native': 'Português',
        'flag': '\U0001F1F5\U0001F1F9\U0001F1E7\U0001F1F7',  # 🇵🇹🇧🇷
        'file': 'kaikki-Portuguese.jsonl',
        'rtl': False,
    },
    'el': {
        'code': 'el',
        'name_en': 'Greek',
        'name_native': 'Ελληνικά',
        'flag': '\U0001F1EC\U0001F1F7',  # 🇬🇷
        'file': 'kaikki-Greek.jsonl',
        'rtl': False,
        'variants': ('el',),
        'tables': 'el',
        'table_variants_new': True,
    },
    'tr': {
        'code': 'tr',
        'name_en': 'Turkish',
        'name_native': 'Türkçe',
        'flag': '\U0001F1F9\U0001F1F7',  # 🇹🇷
        'file': 'kaikki-Turkish.jsonl',
        'rtl': False,
        'variants': ('tr',),
        'tables': 'tr',
    },
    'la': {
        'code': 'la',
        'name_en': 'Latin',
        'name_native': 'Latina',
        'flag': '\U0001F3DB\uFE0F',  # classical building
        'file': 'kaikki-Latin.jsonl',
        'rtl': False,
        'fold': 'la',
        'canon_keys': True,
        'tables': 'la',
        'infl_resolve': True,
    },
    'ko': {
        'code': 'ko',
        'name_en': 'Korean',
        'name_native': '한국어',
        'flag': '\U0001F1F0\U0001F1F7',  # 🇰🇷
        'file': 'kaikki-Korean.jsonl',
        'rtl': False,
        'tables': 'all',
    },
}

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸

MAX_TARGETS = 6        # @@@LINK records per key
MAX_CHAIN = 4          # form -> form -> ... -> lemma hops resolved at build time
MAX_EXAMPLES = 3       # shown per sense; the others sit in a collapsed <details>
MAX_EXAMPLES_KEPT = 50  # per sense in all (upstream max is 45: es meridiem)
MAX_IPAS = 5           # distinct IPA strings per reading
MAX_IPAS_REGIONS = 8   # ... more when that many regions need one each
MAX_TAGS = 6           # tag badges per sense
MAX_TOPICS = 3         # topic badges per sense


def nfc(text: str) -> str:
    return unicodedata.normalize('NFC', text)


# Wiktionary splits its longest pages into subpages: the entries of 'a'
# for Spanish, Portuguese and Turkish live on 'a/languages M to Z', those
# for French, Italian and Latin on 'a/languages A to L'. Both the page
# title and the same-language links use the subpage name.
_SUBPAGE_RE = re.compile(r'/languages [A-Z] to [A-Z]$')


def page_title(text: str) -> str:
    return _SUBPAGE_RE.sub('', text) if '/languages ' in text else text


# ── Mark folding (resolution, canonical validation, variants) ──

_AR_MARKS = frozenset(chr(c) for c in range(0x064B, 0x0660)) | {'\u0670', '\u0640'}  # harakat, superscript alef, tatweel
_LA_MARKS = frozenset('\u0300\u0301\u0302\u0304\u0306\u0308')  # grave acute circumflex macron breve diaeresis
_RU_MARKS = frozenset('\u0300\u0301')  # stress marks


def _strip_marks(text: str, marks) -> str:
    d = unicodedata.normalize('NFD', text)
    return nfc(''.join(c for c in d if c not in marks))


def fold_ar(text: str) -> str:
    """Arabic: drop harakat/tatweel, alef wasla -> alef (كَتَبَ -> كتب)."""
    text = text.replace('ٱ', 'ا')
    return nfc(''.join(c for c in text if c not in _AR_MARKS))


FOLDS = {
    'ar': fold_ar,
    'la': lambda t: _strip_marks(t, _LA_MARKS),     # amō -> amo, adā̆giō -> adagio
    'ru': lambda t: _strip_marks(t, _RU_MARKS),     # соба́ка -> собака (keeps ё)
}


def fold_all(text: str) -> str:
    """Every combining mark removed; only used to compare two spellings."""
    text = text.replace('\u0671', '\u0627').replace('\u0640', '')   # alef wasla -> alef, drop tatweel
    d = unicodedata.normalize('NFD', text)
    return nfc(''.join(c for c in d if unicodedata.category(c) != 'Mn'))


def _mark_clusters(text: str) -> list:
    """[(letter, [marks])]; a tatweel and its marks, and a mark with no
    letter before it, are left out (ـَان, َـانـ)."""
    out = []
    for c in unicodedata.normalize('NFD', text.replace('\u0671', '\u0627')):
        if unicodedata.category(c) != 'Mn':
            out.append((c, []))
        elif out:
            out[-1][1].append(c)
    return [x for x in out if x[0] != '\u0640']


def keeps_marks(marked: str, plain: str) -> bool:
    """True when `marked` has every combining mark of `plain` on the same
    letter: it may add marks (amo -> amō, كتاب -> كِتَاب), never drop or
    move one (Día -> Diá, sana âşığım -> sana aşığım, آمر -> أَمَرَ)."""
    a, b = _mark_clusters(plain), _mark_clusters(marked)
    if len(a) != len(b):
        return False
    for (ca, ma), (cb, mb) in zip(a, b):
        if ca != cb or Counter(ma) - Counter(mb):
            return False
    return True


# ── Typing variants ────────────────────────────────────────────

def _variants_ar(key: str) -> list:
    steps = (
        lambda k: re.sub('[آأإٱ]', 'ا', k),   # أ إ آ ٱ -> ا
        lambda k: re.sub('ى(?=\\s|$)', 'ي', k),               # final ى -> ي
        lambda k: re.sub('ة(?=\\s|$)', 'ه', k),               # final ة -> ه
    )
    out = []
    for n in range(1, len(steps) + 1):
        for combo in combinations(steps, n):
            v = key
            for f in combo:
                v = f(v)
            out.append(v)
    return out


def _variants_el(key: str) -> list:
    # Greek typed without tonos / dialytika (and polytonic marks).
    d = unicodedata.normalize('NFD', key)
    return [nfc(''.join(c for c in d if unicodedata.category(c) != 'Mn'))]


def _variants_ru(key: str) -> list:
    return [key.replace('ё', 'е').replace('Ё', 'Е')]


def _variants_fr(key: str) -> list:
    return [key.replace('œ', 'oe').replace('Œ', 'Oe')
               .replace('æ', 'ae').replace('Æ', 'Ae')]


_TR_CIRC = str.maketrans({'â': 'a', 'î': 'i', 'û': 'u',
                          'Â': 'A', 'Î': 'İ', 'Û': 'U'})


def tr_lower(text: str) -> str:
    """Turkish lowercase: İ -> i, I -> ı (str.lower() gives i̇ / i)."""
    return text.replace('İ', 'i').replace('I', 'ı').lower()


def _variants_tr(key: str) -> list:
    plain = key.translate(_TR_CIRC)
    return [plain, tr_lower(key), tr_lower(plain)]


VARIANT_FUNCS = {
    'ar': _variants_ar, 'el': _variants_el, 'ru': _variants_ru,
    'fr': _variants_fr, 'tr': _variants_tr,
}


# ── POS normalization ──────────────────────────────────────────

POS_MAP = {
    'noun': 'n.', 'verb': 'v.', 'adj': 'adj.', 'adv': 'adv.',
    'prep': 'prep.', 'conj': 'conj.', 'intj': 'interj.',
    'pron': 'pron.', 'name': 'proper n.', 'suffix': 'suffix',
    'prefix': 'prefix', 'particle': 'part.', 'phrase': 'phrase',
    'num': 'num.', 'det': 'det.', 'article': 'art.',
    'character': 'char.', 'symbol': 'sym.', 'proverb': 'proverb',
    'affix': 'affix', 'infix': 'infix', 'interfix': 'interfix',
    'circumfix': 'circumfix', 'contraction': 'contr.',
    'prep_phrase': 'prep. phr.', 'adv_phrase': 'adv. phr.',
    'participle': 'part.', 'postposition': 'postp.',
    'punct': 'punct.',
}


# ── HTML generation ────────────────────────────────────────────

_EXTRA_LIGHT = (
    f'.gl a{{color:{TEXT_LINK[0]};text-decoration:underline}}'
    f'.pl{{font-style:normal;font-size:0.75em;color:{TEXT_SECONDARY[0]}}}'
    '.d li .tg,.d li .dm{margin-right:4px}'
)
_EXTRA_DARK = (
    f'.gl a{{color:{TEXT_LINK[1]}}}'
    f'.pl{{color:{TEXT_SECONDARY[1]}}}'
)
# '<n> more examples' (collapsed extra examples): only in the few articles
# that have them, so the other 99% do not carry the rule.
_EXM_LIGHT = (f'.exm summary{{margin:2px 0 2px 10px;font-size:0.8em;'
              f'color:{TEXT_SECONDARY[0]};cursor:pointer}}')
_EXM_DARK = f'.exm summary{{color:{TEXT_SECONDARY[1]}}}'

_CSS_PARTS = (PRONUNCIATION, ROMANIZATION, GLOSS, ORDERED_LIST,
              DOMAIN_BADGE, TAG_BADGE, EXAMPLES_BILINGUAL)
CSS = get_css(*_CSS_PARTS, extra_light=_EXTRA_LIGHT, extra_dark=_EXTRA_DARK)
CSS_EXM = get_css(*_CSS_PARTS, extra_light=_EXTRA_LIGHT + _EXM_LIGHT,
                  extra_dark=_EXTRA_DARK + _EXM_DARK)


# Register/usage tags worth showing; tags that start with a capital letter
# are regions, dialects and varieties (Brazil, Quebec, Rioplatense,
# Classical-Latin, Sino-Korean) and are shown as well.
SHOW_TAGS = {
    'colloquial', 'informal', 'formal', 'literary', 'archaic',
    'dated', 'obsolete', 'rare', 'poetic', 'vulgar', 'slang',
    'derogatory', 'euphemistic', 'humorous', 'figurative',
    'transitive', 'intransitive', 'reflexive', 'pronominal',
    'countable', 'uncountable', 'masculine', 'feminine', 'neuter',
    'dialectal', 'regional', 'nonstandard', 'proscribed', 'historical',
    'idiomatic', 'offensive', 'pejorative', 'childish', 'honorific',
}


def tag_label(tag: str) -> str:
    return tag.replace('-', ' ').replace('_', ' ')


# ── Upstream text cleanup (wiki-markup leftovers) ─────────────

_TPL_RE = re.compile(r'\{\{[^{}]*\}\}?\s?')                        # {{lb|la|la-med} / {{...}}
_WLINK_RE = re.compile(r'\[\[([^\[\]]*)\]\]')                      # [[a]], [[a|b]], [[w:a|b]]
_TPL_NAME_RE = re.compile(r'^:?Template:([A-Za-z][A-Za-z -]*?)( of)?$')
_UNSUPPORTED = {'Vertical line': '|'}


def _wlink(m) -> str:
    parts = m.group(1).split('|')
    label = next((p for p in reversed(parts) if p.strip()), '')
    target = parts[0]
    if not label.strip() or label == target:
        if target.startswith('Unsupported titles/'):
            return _UNSUPPORTED.get(target.split('/', 1)[1], '')
        label = target
    if label.startswith(('w:', ':')) and '|' not in m.group(1):
        label = label.split(':', 1)[1]
    # '[[#Ancient Greek]]' is a section anchor; '[[#]]' is the sign itself.
    return label[1:] if label.startswith('#') and len(label) > 1 else label


def clean_text(text) -> str:
    """Plain text from an upstream field: bidi marks and wiki markup removed."""
    if not text or not isinstance(text, str):
        return ''
    text = strip_bidi_controls(text)
    if '{{' in text:
        text = _TPL_RE.sub('', text)
    if '}}' in text:
        text = text.replace('}}', '')
    if '[[' in text or ']]' in text:
        prev = None
        while prev != text:
            prev = text
            text = _WLINK_RE.sub(_wlink, text)
        text = text.replace('[[', '[').replace(']]', ']')
    if 'Template:' in text:
        m = _TPL_NAME_RE.match(text.strip())
        if m:
            # The gloss is an unexpanded template call: 'Template:acronym of'
            # (upstream lost the expansion) -> 'acronym (expansion not given)'.
            text = m.group(1) + (' (expansion not given)' if m.group(2) else '')
        text = text.replace(':Template:..', '…').replace('Template:..', '…')
    return ' '.join(text.split())


def clean_ipa(ipa) -> str:
    if not ipa or not isinstance(ipa, str):
        return ''
    if '[[' in ipa or '{{' in ipa or 'Template:' in ipa:
        return ''
    return ' '.join(strip_bidi_controls(ipa).split())


# ── Parsed record model ────────────────────────────────────────

class Sense:
    __slots__ = ('glosses', 'tags', 'topics', 'examples', 'form', 'deriv',
                 'alt', 'hanja', 'bases', 'links', 'link_titles', 'resolved',
                 'untagged', 'en_words')

    def __init__(self):
        self.resolved = []          # [(surface, title)] filled by resolve phase
        self.deriv = False
        self.alt = False
        self.untagged = False       # form-of found from the gloss text only
        self.en_words = frozenset()  # words of the gloss's English links

    @property
    def pointer(self) -> bool:
        """Sense that only points at another headword (form/alt/derived)."""
        return self.form or self.deriv or self.alt or self.hanja


class Rec:
    __slots__ = ('word', 'pos', 'senses', 'sounds', 'roman', 'canon',
                 'canon_all', 'eumhun', 'tables', 'infl', 'article', 'ar_def')


_DERIV_RE = re.compile(
    r'^(?:(?:endearing|affectionate|pejorative|euphemistic|emphatic)\s+)?'
    r'(?:diminutive|augmentative|verbal noun|causative|intensive|reflexive|'
    r'reciprocal|frequentative|iterative|agent noun|abstract noun|'
    r'(?:feminine|female|masculine|male) equivalent|relative adjectival|'
    r'gender-neutral|endearing form|pejorative form|euphemistic form|'
    r'emphatic form|nominalization|deverbal|inchoative|passive of|'
    r'(?:im)?perfective(?: aspect| form)? of|simultaneous adverbial form)\b',
    re.IGNORECASE)


# Form-of glosses that upstream left without a form_of list, mostly where
# a template combined two slots: 'third-person plural preterite/pluperfect
# indicative of ir' (pt foram), 'genitive/locative singular of bellum'.
_FORM_GLOSS_RE = re.compile(r'^(?P<desc>[A-Za-z/ -]+?) of (?P<base>[^\s(]+)(?: \([^)]*\))?$')
_INFL_WORDS = frozenset('''
    first second third first-person second-person third-person person
    singular plural dual nominative accusative genitive dative ablative
    locative vocative instrumental prepositional present past future
    imperfect perfect pluperfect preterite aorist indicative subjunctive
    imperative conditional infinitive participle gerund gerundive supine
    active passive masculine feminine neuter definite indefinite
    comparative superlative short animate inanimate and or'''.split())
_INFL_STRONG = frozenset('''
    singular plural dual nominative accusative genitive dative ablative
    locative vocative instrumental prepositional present past future
    imperfect perfect pluperfect preterite aorist indicative subjunctive
    imperative conditional infinitive participle gerund gerundive
    supine'''.split())


def gloss_form_base(gloss: str):
    """Base of an untagged inflection gloss, or None ('first of all' -> None)."""
    m = _FORM_GLOSS_RE.match(gloss)
    if not m:
        return None
    words = [w for w in re.split(r'[ /-]+', m.group('desc').lower()) if w]
    if words and all(w in _INFL_WORDS for w in words) and any(w in _INFL_STRONG for w in words):
        return m.group('base')
    return None


_AR_LINE_RE = re.compile(
    r'^#\s*(?P<voc>[^\s(]+)\s*\((?P<tr>[^)]*)\)\s*(?:/[^/]*/)?\s*:\s*(?P<rest>.+)$')
_AR_REST_RE = re.compile(r'^(?P<desc>.+?)\s+of\s+(?P<bases>.+)$')
_AR_BASE_RE = re.compile(r'(\S+)\s*\(([^)]*)\)')


def parse_ar_verb_forms(entry: dict) -> list:
    """Synthetic form-of senses for gloss-less 'ar-verb form' pages.

    The meaning is only in head_templates[].expansion:
        كتبت (form I, form II)
        # كَتَبْتُ (katabtu) /ka.tab.tu/: first-person singular past active of كَتَبَ (kataba)
    or, for a single reading:
        عَرِّبِي • (ʕarribī) (form II) /ʕar.ri.biː/
        # second-person feminine singular imperative of عَرَّبَ (ʕarraba)
    """
    senses = []
    for ht in entry.get('head_templates') or []:
        if ht.get('name') != 'ar-verb form':
            continue
        lines = (ht.get('expansion') or '').split('\n')
        voc0 = tr0 = ''
        if lines and '•' in lines[0]:
            voc0 = lines[0].split('•', 1)[0].strip()
            m = re.search(r'\(([^)]*)\)', lines[0].split('•', 1)[1])
            tr0 = m.group(1).strip() if m else ''
        for line in lines[1:]:
            line = strip_bidi_controls(line).strip()
            if not line.startswith('#'):
                continue
            m = _AR_LINE_RE.match(line)
            if m:
                voc, tr, rest = m.group('voc'), m.group('tr').strip(), m.group('rest')
            else:
                voc, tr, rest = voc0, tr0, line[1:].strip()
            m2 = _AR_REST_RE.match(rest)
            if not m2:
                continue
            bases = [b for b, _ in _AR_BASE_RE.findall(m2.group('bases'))]
            if not bases:
                continue
            s = Sense()
            head = f'{voc} ({tr}): ' if voc and tr else (f'{voc}: ' if voc else '')
            s.glosses = [clean_text(head + rest)]
            s.tags = []
            s.topics = []
            s.examples = []
            s.form = True
            s.hanja = False
            s.bases = bases
            s.links = {}
            s.link_titles = []
            senses.append(s)
    return senses


_TABLE_GLOSS = 'More information * '


def parse_sense(raw: dict, wiki: str, rtl: bool):
    glosses = [clean_text(g) for g in raw.get('glosses') or []]
    # A flattened bullet table ('More information * 混: to mix (...) * 婚:
    # to marry (...)', Korean syllable pages) -> '混: to mix (...); 婚: ...'
    glosses = [g[len(_TABLE_GLOSS):].replace(' * ', '; ') if g.startswith(_TABLE_GLOSS) else g
               for g in glosses]
    glosses = [g for g in glosses if g]
    if not glosses:
        return None
    s = Sense()
    s.glosses = glosses
    tags = raw.get('tags') or []
    s.tags = tags
    s.topics = [t for t in raw.get('topics') or [] if isinstance(t, str)]
    s.hanja = 'hanja' in tags and bool(raw.get('form_of'))
    form_of = bool(raw.get('form_of')) or 'form-of' in tags
    gloss_base = None
    if not form_of and not raw.get('alt_of'):
        gloss_base = gloss_form_base(glosses[-1])
        form_of = gloss_base is not None
    # Derived words ("diminutive of X", "causative of X") are words of their
    # own: kept as articles (with a link and a @@@LINK to X), not redirects.
    s.deriv = form_of and not s.hanja and bool(_DERIV_RE.match(glosses[-1]))
    s.form = form_of and not s.hanja and not s.deriv
    s.untagged = s.form and gloss_base is not None
    s.alt = bool(raw.get('alt_of')) or 'alt-of' in tags
    bases = []
    for key in ('form_of', 'alt_of'):
        for item in raw.get(key) or []:
            w = item.get('word') if isinstance(item, dict) else None
            if w and isinstance(w, str):
                w = page_title(nfc(strip_bidi_controls(w).strip()))
                if w and w not in bases:
                    bases.append(w)
    if gloss_base:
        b = nfc(strip_bidi_controls(gloss_base))
        if b not in bases:
            bases.append(b)
    s.bases = bases
    links = {}
    link_titles = []
    en_words = set()
    anchor = '#' + wiki
    for ln in raw.get('links') or []:
        if not isinstance(ln, list) or len(ln) < 2:
            continue
        text, target = ln[0], ln[1]
        if not isinstance(text, str) or not isinstance(target, str):
            continue
        if anchor not in target:
            if bases and not target.startswith('w:') and (
                    '#' not in target or '#English' in target):
                en_words.update(nfc(text).split())
            continue
        title = page_title(nfc(target.split('#', 1)[0].strip()))
        if not title:
            continue
        links.setdefault(nfc(text.strip()), title)
        if title not in link_titles:
            link_titles.append(title)
    s.links = links
    s.link_titles = link_titles
    if en_words:
        s.en_words = frozenset(en_words)
    exs = []
    for ex in raw.get('examples') or []:
        text = clean_text(ex.get('text'))
        if not text:
            continue
        tr = clean_text(ex.get('english') or ex.get('translation') or '')
        if (text, tr) not in exs:
            exs.append((text, tr))
        if len(exs) >= MAX_EXAMPLES_KEPT:
            break
    s.examples = exs
    return s


# '喝: rebuke', then '喝: rebuke (eumhun reading: …) (MC reading: …)' twice:
# Korean syllable pages list each hanja item three times.
_READING_TAIL_RE = re.compile(r'\s*\((?:eumhun|MC) reading:[^()]*(?:\([^()]*\)[^()]*)*\)')


def dedupe_senses(senses: list) -> list:
    """Drop repeated senses of one record.

    Two senses are the same when their gloss paths (ignoring a Korean
    '(eumhun reading: …)' / '(MC reading: …)' tail), tags, topics and bases
    are equal: Korean hanja items, and senses that upstream lists twice
    (es agazapada 'feminine singular of agazapado', ko -에서 'from'). The
    first one keeps its place, takes the fullest gloss of the copies, and
    their examples are merged into it.
    """
    out = []
    kept = {}
    for s in senses:
        key = (tuple(_READING_TAIL_RE.sub('', g) for g in s.glosses), tuple(s.tags),
               tuple(s.topics), tuple(s.bases), s.form, s.deriv, s.alt, s.hanja)
        k0 = kept.get(key)
        if k0 is None:
            kept[key] = s
            out.append(s)
            continue
        if len(s.glosses[-1]) > len(k0.glosses[-1]):
            k0.glosses = s.glosses
        for ex in s.examples:
            if ex not in k0.examples and len(k0.examples) < MAX_EXAMPLES_KEPT:
                k0.examples.append(ex)
    return out


_CLOSED_POS = frozenset(('pron', 'article', 'det'))


def table_forms(entry: dict, policy: str, title: str) -> list:
    """Inflection-table forms[] that should become @@@LINK keys.

    'all'  every single-word conjugation/declension/inflection form.
    'el'   Greek: as 'all', but a pronoun, article or determiner table
           only gives forms of the title's own stem (ετούτος -> ετούτη):
           upstream gives τα the whole personal-pronoun paradigm (γώ,
           σύ, μείς, σείς), and the other closed-class forms are pages.
    'tr'   Turkish: the first table of each kind only (noun cases, the main
           positive/negative verb table); the possessive and the
           potential/impotential tables would add ~1.5M keys.
    'la'   Latin: all single-word table forms, added without macrons
           (amāvisset -> amavisset); most are form-of pages already.

    Left out: a table of bare endings or of another word (upstream gives
    αριός the endings ός, ά, ό, οί ..., inclamito the forms of clāmitō):
    the title is not in it and one of its forms is a shorter tail of the
    title. Also forms that do not start with a letter (‑ομε, —쩍다, ➤,
    ◻e, ☉lis, _), except the hyphenated forms of an affix (-이다 ->
    -이에요, -cık -> -cıklar).
    """
    rows = []
    block = 0
    for f in entry.get('forms') or []:
        tags = f.get('tags') or []
        if 'inflection-template' in tags:
            block += 1
            continue
        if 'table-tags' in tags or 'class' in tags or 'romanization' in tags:
            continue
        if f.get('source') not in ('conjugation', 'declension', 'inflection'):
            continue
        form = f.get('form')
        if not isinstance(form, str):
            continue
        form = nfc(strip_bidi_controls(form).strip())
        if form:
            rows.append((block, form))
    if not rows:
        return []
    ft = fold_all(title).lower()
    folded = {fold_all(form).lower() for _, form in rows}
    if not title.startswith('-') and ft not in folded and any(
            0 < len(x) < len(ft) and ft.endswith(x) for x in folded):
        return []
    stem = ft[:1] if policy == 'el' and entry.get('pos') in _CLOSED_POS else None
    affix = title.startswith('-')
    out = []
    for block, form in rows:
        if policy == 'tr' and block > 1:
            continue
        if (form == title or ' ' in form or len(form) > 40
                or any(c in form for c in '()[]{}<>/#:;,|*?!')):
            continue
        if not unicodedata.category(form[0]).startswith('L') and not (
                affix and form[0] == '-' and len(form) > 1):
            continue
        if stem is not None and fold_all(form).lower()[:1] != stem:
            continue
        if form not in out:
            out.append(form)
    return out


def parse_kaikki_file(filepath: Path, lang: dict, side: dict = None):
    """Parse a Kaikki JSONL file into Rec objects (JSONL order).

    `side`, when given, collects Arabic gloss-less 'with-definite-article'
    pages (محامي, وادي) under 'ar_definite'.
    """
    code = lang['code']
    wiki = lang['name_en']
    rtl = lang.get('rtl', False)
    tables_policy = lang.get('tables')
    infl_resolve = lang.get('infl_resolve', False)
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            entry = json.loads(line)
            if entry.get('source') == 'thesaurus':
                continue
            if entry.get('lang_code') != code:
                continue
            word = page_title(nfc(strip_bidi_controls(entry.get('word', '')).strip()))
            if not word or '\n' in word:
                continue

            senses = []
            for raw in entry.get('senses') or []:
                s = parse_sense(raw, wiki, rtl)
                if s is not None:
                    senses.append(s)
            if not senses and code == 'ar' and entry.get('pos') == 'verb':
                senses = parse_ar_verb_forms(entry)
            if not senses:
                raws = entry.get('senses') or []
                if (side is not None and code == 'ar' and raws and all(
                        'with-definite-article' in (x.get('tags') or []) for x in raws)):
                    side.setdefault('ar_definite', []).append(word)
                continue
            senses = dedupe_senses(senses)

            r = Rec()
            r.word = word
            pos_raw = entry.get('pos', '')
            r.pos = POS_MAP.get(pos_raw, pos_raw)
            r.senses = senses
            # A page with a real sense is an article. So is a page whose
            # form-of senses were only recognised from the gloss text
            # ('third-person plural preterite/pluperfect indicative of
            # abandonar'): it keeps its description, as it did before that
            # detection, and gets @@@LINKs to the lemmas after it.
            r.article = any(not s.form or s.untagged for s in senses)

            sounds = []
            for snd in entry.get('sounds') or []:
                ipa = clean_ipa(snd.get('ipa'))
                if not ipa:
                    continue
                tags = tuple(t for t in snd.get('tags') or [] if isinstance(t, str))
                note = clean_text(snd.get('note') or '')
                sounds.append((ipa, tags, note))
            r.sounds = sounds

            roman = ''
            canon_all = []
            eumhun = ''
            for fm in entry.get('forms') or []:
                tags = fm.get('tags') or []
                form = fm.get('form')
                if not isinstance(form, str):
                    continue
                if not roman and 'romanization' in tags:
                    roman = clean_text(form)
                elif 'canonical' in tags:
                    c = nfc(strip_bidi_controls(form).strip())
                    # Arabic: the hamza seat is a letter, not a mark (the
                    # form page آمر has the canonical أَمَرَ of أمر).
                    if (c and c != word and fold_all(c) == fold_all(word) and c not in canon_all
                            and (code != 'ar' or keeps_marks(c, word))):
                        canon_all.append(c)
                elif not eumhun and 'eumhun' in tags:
                    rom = fm.get('roman') or ''
                    eumhun = clean_text(f'{form} ({rom})' if rom else form)
            r.roman = roman
            r.canon = canon_all[0] if canon_all else ''
            r.canon_all = canon_all
            r.eumhun = eumhun
            r.tables = (table_forms(entry, tables_policy, word)
                        if tables_policy and r.article else [])
            r.infl = (r.tables if tables_policy in ('all', 'la') else
                      table_forms(entry, 'all', word)) if infl_resolve and r.article else []
            # Arabic nouns/adjectives: the first definite form (الْمُحَامِي
            # for مُحَامٍ), for the manqūṣ keys of phase 5.
            r.ar_def = next((nfc(fm['form']) for fm in entry.get('forms') or []
                             if 'definite' in (fm.get('tags') or [])
                             and isinstance(fm.get('form'), str)), '') \
                if code == 'ar' and r.article and pos_raw in ('noun', 'adj') else ''
            yield r


# ── Base resolution ────────────────────────────────────────────

_SPLIT_RE = re.compile(r'\s*/\s*|\s+and\s+|\s+or\s+|\s*,\s*|\s*;\s*|\s+[~=+]\s+|\s*\n\s*')
_GENDER_RE = re.compile(r'\s+(?:m|f|n|c|mf|pl|m pl|f pl|n pl|m or f|m and f)\.?$')
_COMBINED_RE = re.compile(r'^(.+?)\s+combined with\b')
# 'intransitive exolescō', 'alternative form of surripio' -> the last part
_QUALIFIED_RE = re.compile(
    r'^(?:(?:in)?transitive|reflexive|pronominal|'
    r'(?:(?:alternative|archaic|obsolete|dated|rare|nonstandard|dialectal|'
    r'informal|colloquial|superseded|older|uncommon|standard|letter-case|'
    r'eye dialect|pronunciation) )+(?:form|spelling|variant) of)\s+(\S.*)$',
    re.IGNORECASE)
# What may follow the base word in a multiword base for the first word to
# be the base: gender / number / aspect markers ('вду́маться pf', 'отде́л m
# inan', 'avere and'), an English usage note ('su used before a vowel', 'a
# for euphony', '-da after the vowels A', 'María when used as part of a male
# name') or a second English description ('boulevard alternative form of
# boul', 'Mtl abbreviation of Montréal').
_MARKERS = frozenset('m f n c mf pl sg du pf impf inan anim and or indecl'.split())
_USAGE = (r'(?:used|usually|especially|chiefly|mostly|only|often|also|after|'
          r'before|for|when|with|without|found|followed|preceding|occurring|'
          r'appended)\b.*|(?:in|as) (?:a|an|any|the|its|some|most|masculine|'
          r'feminine|names?|compounds?)\b[\x00-\x7f]*')
_NOTE_RE = re.compile(r'^(?:' + _USAGE + r'|(?:[a-z-]+ )+of\b.*)$')
_USAGE_RE = re.compile(r'^(?:' + _USAGE + r')$')     # a usage note only, no 'X of Y'
# Senses whose base is an expansion or a longer phrase: its first word is
# not what the headword means (USA -> 'the', ZIP -> 'zona', NLP -> 'nique').
_PHRASE_TAGS = frozenset(('abbreviation', 'initialism', 'acronym', 'ellipsis', 'clipping'))


_CODE_RE = re.compile(r'^[a-z]{1,2}$')     # 'n', 'm', 'en': a gender or language code


_COMPASS = frozenset(('Northern', 'Southern', 'Eastern', 'Western', 'Central',
                      'Northeastern', 'Northwestern', 'Southeastern', 'Southwestern'))


def pick_ipas(items: list) -> list:
    """Choose the (ipa, labels) pairs to show, in their upstream order.

    Up to MAX_IPAS. When there are more, every region label first gets
    one string (phonemic /.../ before phonetic [...]), so a Portuguese
    entry that lists five Brazilian variants first still shows Portugal;
    the slots left are filled with phonemic, then phonetic strings.
    """
    if len(items) <= MAX_IPAS:
        return items
    order = ([i for i, (ipa, _) in enumerate(items) if not ipa.startswith('[')]
             + [i for i, (ipa, _) in enumerate(items) if ipa.startswith('[')])
    keep = []
    covered = set()
    for i in order:
        # The unlabelled (standard) pronunciation counts as a region of its
        # own: French soir keeps /swaʁ/ beside five Canadian strings.
        labels = items[i][1] or ['']
        if any(lb not in covered for lb in labels):
            keep.append(i)
            covered.update(labels)
    keep = keep[:MAX_IPAS_REGIONS]
    for i in order:
        if len(keep) >= MAX_IPAS:
            break
        if i not in keep:
            keep.append(i)
    return [items[i] for i in sorted(keep)]


def likeness(a: str, b: str) -> float:
    """How alike two spellings are, marks and case ignored (0..1)."""
    fa, fb = fold_all(a).lower(), fold_all(b).lower()
    return 1.0 if fa == fb else SequenceMatcher(None, fa, fb).ratio()


class Resolver:
    def __init__(self, titles: set, canon_map: dict, fold, infl_map=None):
        self.titles = titles
        self.canon_map = canon_map
        self.fold = fold
        self.infl_map = infl_map or {}
        self.fold_map = {}
        if fold:
            for t in titles:
                ft = fold(t)
                if ft != t:
                    self.fold_map.setdefault(ft, t)

    def one(self, b: str, links: dict, head: str = ''):
        if not b:
            return None
        t = links.get(b)
        if t and t in self.titles:
            if (t == b or not _CODE_RE.match(t) or likeness(t, b) >= 0.5
                    or (head and likeness(t, head) >= 0.5)):
                return t
            # A link to a language or gender code that upstream took from
            # another template slot ('quantumlibet' -> 'n', 'tabernacle' ->
            # 'm', 'cosplay' -> 'en'): the base is resolved by its spelling.
            # Other unlike links are kept: there the base is the slip
            # ('2' -> vider for vidas, 'supporting' -> caeliger for coeliger,
            # '日(일)本(본)' -> 일본).
        return self.direct(b)

    def direct(self, b: str):
        """Title for a base by spelling alone (page, canonical, fold, table)."""
        if b in self.titles:
            return b
        ts = self.canon_map.get(b)
        if ts:
            # Several pages share the canonical spelling: the one it folds
            # to first (أَطِبَّاء -> أطباء before the hamza-less اطباء).
            if len(ts) > 1 and self.fold and self.fold(b) in ts:
                return self.fold(b)
            return ts[0]
        if self.fold:
            fb = self.fold(b)
            if fb in self.titles:
                return fb
            ts = self.canon_map.get(fb)
            if ts:
                return ts[0]
            t = self.fold_map.get(fb)
            if t:
                return t
        if self.infl_map:
            # A base without a page of its own that is an inflected form
            # (participle, plural) in a lemma's table: tirāns -> tīrō.
            ts = self.infl_map.get(b) or (self.infl_map.get(self.fold(b)) if self.fold else None)
            if ts:
                return ts[0]
        return None

    def sense(self, s: Sense, head: str = '') -> list:
        """[(surface, title)] for a sense's form_of / alt_of bases (head: page title)."""
        out = []
        seen = set()

        def add(surface, title):
            if title and title not in seen:
                seen.add(title)
                out.append((surface, title))

        link_set = set(s.link_titles)
        tags = set(s.tags)
        note = False
        for b in s.bases:
            if note and b not in s.links:
                # The tail of a usage note that upstream split into bases:
                # '-gaç after the vowels E', 'İ', 'Ö', 'Ü' (Turkish -geç).
                continue
            words = b.split()
            qualified = _QUALIFIED_RE.match(b)
            # '<base> <usage note>' ('su used before a vowel', '-den after
            # the vowels A, I, O, U'): the note's words are no bases.
            noted = (len(words) > 1 and '\n' not in b and not qualified
                     and bool(_USAGE_RE.match(b.split(None, 1)[1])))
            note = note or noted
            t = self.one(b, s.links, head)
            if t:
                add(b, t)
                continue
            # Sanitize junk bases: 'avere and', '령/영', 'uovo m',
            # 'niño Boys or children', 'X combined with ...',
            # 'intransitive exolescō', 'alternative form of surripio'.
            cands = []
            m = _COMBINED_RE.match(b)
            if m:
                cands.append(m.group(1))
            if qualified:
                cands.append(qualified.group(1))
            # Parts: 'stupéfier ~ stupéfaire', '너는 = 너', and a glued second
            # line ('obtendō\nFuture active participle of obtineo'); of a
            # noted base only the first ('X, used in compounds').
            parts = _SPLIT_RE.split(b)
            for part in parts[:1] if noted else parts:
                part = _GENDER_RE.sub('', part.strip())
                if part and part != b:
                    cands.append(part)
                    fb = gloss_form_base(part)
                    if fb:
                        cands.append(fb)
            if len(words) > 1 and '\n' not in b and not qualified:
                rest = b.split(None, 1)[1]
                others = [w.strip('?!.,;:()') for w in words[1:]]
                if (all(w.rstrip('.') in _MARKERS for w in words[1:])
                        or _NOTE_RE.match(rest) or len(set(words)) == 1):
                    # 'вду́маться pf', 'María when used as part of a male
                    # name', '빨리 빨리'
                    cands.append(words[0])
                elif 'contraction' in tags:
                    # 'contraction of in il' (nel) -> in, il: every word the
                    # sense links in its own language.
                    cands.extend(w for w in words if w in s.links)
                elif words[0] in s.links and not any(w in s.links for w in others) and (
                        not tags & _PHRASE_TAGS or all(w in s.en_words for w in others)):
                    # The rest is an English gloss: 'chilometro kilometres',
                    # and for clippings and apocopes only when the gloss
                    # links it as English ('santo saint', 'saxofón sax').
                    cands.append(words[0])
            for c in cands:
                t = self.one(c, s.links, head)
                if t and (not link_set or t in link_set or c in s.links):
                    add(c, t)
        if not out and s.form and not s.bases:
            # form-of tag without a form_of list: use the sense's own links
            for text, title in s.links.items():
                if title in self.titles:
                    add(text, title)
                    break
        return out


# ── HTML rendering ─────────────────────────────────────────────

def link_html(target: str, label: str, rtl_lang: str = '') -> str:
    attrs = dir_attr('rtl', rtl_lang) if rtl_lang and has_rtl(label) else ''
    return f'<a href="entry://{esc_attr(target)}"{attrs}>{esc(label)}</a>'


_NOSPACE_RE = re.compile('[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0003134f]')


# Where a gloss names its bases: after 'of', up to ';', ':', '(' or a
# quoted meaning ('contraction of in il; in the', 'inflection of ir:',
# 'plural of casa (“house”)').
_BASE_REGION_RE = re.compile(r'(?<!\w)of ([^;:“(]+)')


def linkify(text: str, links: list, keys, rtl_lang: str = '') -> str:
    """Escape text and turn each (surface, key) into an entry:// link.

    Each surface is linked once: at its last occurrence after an 'of'
    ('... of <base>'), else at its last occurrence, so the Italian 'in' of
    'contraction of in il; in the' is linked and the English one is not.
    Keys not in `keys` stay plain text. A surface must stand as a word of
    its own, except in scripts written without spaces (hanja, kana), where
    it may touch other characters.
    """
    regions = [m.span(1) for m in _BASE_REGION_RE.finditer(text)] if 'of ' in text else []
    spans = []
    for surface, key in links:
        if not surface or key not in keys:
            continue
        pat = re.compile(r'(?<!\w)' + re.escape(surface) + r'(?!\w)')
        found = [m.span() for m in pat.finditer(text)]
        if not found and _NOSPACE_RE.search(surface):
            i = text.find(surface)
            while i >= 0:
                found.append((i, i + len(surface)))
                i = text.find(surface, i + 1)
        if not found:
            continue            # never link 'ir' inside 'first'
        in_region = [sp for sp in found
                     if any(a <= sp[0] and sp[1] <= b for a, b in regions)]
        start, end = (in_region or found)[-1]
        if any(start < e and s < end for s, e, _ in spans):
            continue
        spans.append((start, end, key))
    if not spans:
        return esc(text)
    spans.sort()
    out = []
    pos = 0
    for start, end, key in spans:
        out.append(esc(text[pos:start]))
        out.append(link_html(key, text[start:end], rtl_lang))
        pos = end
    out.append(esc(text[pos:]))
    return ''.join(out)


def sense_badges(sense, skip_tags=frozenset(), text: str = '') -> list:
    """Topic and tag badges; a tag the gloss already says ('feminine' for
    'feminine singular of fiancé') is not repeated as a badge."""
    out = []
    for topic in sense.topics[:MAX_TOPICS]:
        out.append(f'<span class="dm">{esc(tag_label(topic))}</span>')
    n = 0
    low = text.lower()
    for t in sense.tags:
        if t in skip_tags:
            continue
        if t in SHOW_TAGS or (t[:1].isupper() and len(t) > 1):
            label = tag_label(t)
            # (only usage tags: a region in the gloss, 'Brazil nut', is no label)
            if low and t in SHOW_TAGS and re.search(r'(?<!\w)' + re.escape(label) + r'(?!\w)', low):
                continue
            out.append(f'<span class="tg">{esc(label)}</span>')
            n += 1
            if n >= MAX_TAGS:
                break
    return out


class Node:
    __slots__ = ('text', 'key', 'sense', 'children')

    def __init__(self, text, key, sense=None):
        self.text = text
        self.key = key
        self.sense = sense
        self.children = []


def _gloss_key(g: str) -> str:
    return g.rstrip(':').strip()


def build_tree(senses: list) -> list:
    """Group wiktextract's [parent, child] gloss paths into a tree.

    Consecutive senses that share a parent gloss become sub-senses of one
    card instead of repeating the parent in each of them.
    """
    roots = []
    stack = []
    for s in senses:
        path = s.glosses
        keys = [_gloss_key(g) for g in path]
        i = 0
        while i < len(stack) and i < len(path) - 1 and stack[i].key == keys[i]:
            i += 1
        del stack[i:]
        for j in range(i, len(path)):
            node = Node(path[j], keys[j], s if j == len(path) - 1 else None)
            (stack[-1].children if stack else roots).append(node)
            stack.append(node)
    return roots


_HANJA_ITEM_RE = re.compile(
    '^([㐀-䶿一-鿿豈-﫿\U00020000-\U0003134f]+)(?::\\s|$)')


class Renderer:
    def __init__(self, lang: dict, keys: set):
        self.lang = lang
        self.keys = keys
        self.rtl_lang = lang['code'] if lang.get('rtl') else ''
        self.code = lang['code']
        self.title = None           # article being rendered: never linked to itself

    def _linkify(self, text: str, links: list) -> str:
        links = [x for x in links if x[1] != self.title]
        return linkify(text, links, self.keys, self.rtl_lang) if links else esc(text)

    @staticmethod
    def _leaf_links(node: Node) -> list:
        out = []
        stack = list(node.children)
        while stack:
            n = stack.pop(0)
            if n.sense is not None:
                out.extend(x for x in n.sense.resolved if x not in out)
            stack.extend(n.children)
        return out

    def gloss(self, node: Node) -> str:
        text = node.text
        # Flattened hanja tables of Korean syllable pages: 'More
        # information(eumhun reading: ...)(MC reading: ...)' and bare
        # '(MC reading: 突 (MC dwot))' rows carry no meaning of their own.
        if text.startswith('More information(') or text == 'More information' or (
                text.startswith('(MC reading:') and not node.children):
            return ''
        if node.sense is None and node.children:
            # Parent gloss shared by sub-senses: 'inflection of ir:' links ir.
            links = self._leaf_links(node)
            if links:
                return self._linkify(text, links)
        if node.sense is not None:
            if node.sense.resolved:
                return self._linkify(text, node.sense.resolved)
            if self.code == 'ko':
                # Hanja list items of a syllable page: '四: four' -> link 四
                # (the item head, not the copy in '(MC reading: 四 …)')
                m = _HANJA_ITEM_RE.match(text)
                if m and m.group(1) in self.keys and m.group(1) != self.title:
                    h = m.group(1)
                    return link_html(h, h) + esc(text[len(h):])
        return esc(text)

    def examples(self, sense) -> str:
        """The first MAX_EXAMPLES examples, then the rest collapsed under
        '<n> more examples' (a native <details>, no script needed)."""
        if sense is None:
            return ''
        out = []
        for text, tr in sense.examples:
            attrs = dir_attr('rtl', self.rtl_lang) if self.rtl_lang and has_rtl(text) else ''
            h = f'<div class="ex"><span class="ex-src"{attrs}>{esc(text)}</span>'
            if tr:
                h += f'<span class="ex-tr">{esc(tr)}</span>'
            out.append(h + '</div>')
        if len(out) <= MAX_EXAMPLES:
            return ''.join(out)
        more = len(out) - MAX_EXAMPLES
        label = f'{more} more example' + ('s' if more > 1 else '')
        return (''.join(out[:MAX_EXAMPLES]) + f'<details class="exm"><summary>{label}</summary>'
                + ''.join(out[MAX_EXAMPLES:]) + '</details>')

    def sublist(self, node: Node, tags: frozenset) -> str:
        items = ''.join(self.li(c, tags) for c in node.children)
        return f'<ol class="d">{items}</ol>' if items else ''

    def li(self, node: Node, parent_tags: frozenset) -> str:
        """One sub-sense; '' when it has nothing to show."""
        body = self.gloss(node) + self.examples(node.sense)
        if node.children:
            tags = frozenset(node.sense.tags) if node.sense else parent_tags
            body += self.sublist(node, tags)
        if not body:
            return ''
        badges = ''.join(sense_badges(node.sense, parent_tags, node.text)) if node.sense else ''
        return f'<li>{badges}{body}</li>'

    def card(self, node: Node, pos_badge: str) -> str:
        """One top-level sense; '' when it has nothing to show."""
        body = []
        g = self.gloss(node)
        if g:
            body.append(f'<span class="gl">{g}</span>')
        body.append(self.examples(node.sense))
        if node.children:
            tags = frozenset(node.sense.tags) if node.sense else frozenset()
            body.append(self.sublist(node, tags))
        body = ''.join(body)
        if not body:
            return ''
        badges = sense_badges(node.sense, text=node.text) if node.sense else []
        if pos_badge:
            badges.insert(0, pos_badge)
        hd = f'<div class="sn-hd">{"".join(badges)}</div>' if badges else ''
        return f'<div class="sn">{hd}{body}</div>'

    def senses(self, rec: Rec) -> str:
        pos_badge = f'<span class="pos">{esc(rec.pos)}</span>' if rec.pos else ''
        out = []
        seen = set()
        for node in build_tree(rec.senses):
            # A card that renders exactly like an earlier one (senses that
            # differ only in tags that are not shown) is left out.
            h = self.card(node, '')
            if not h or h in seen:
                continue
            seen.add(h)
            out.append(h if out else self.card(node, pos_badge))
        return ''.join(out)

    @staticmethod
    def ipa(sounds: list) -> str:
        if not sounds:
            return ''
        common = None
        for _, tags, _ in sounds:
            common = set(tags) if common is None else common & set(tags)
        common = common or set()
        groups = {}
        for ipa, tags, note in sounds:
            # 'Northern Portugal', not 'Portugal Southern' (upstream order varies)
            shown = sorted((t for t in tags if t not in common), key=lambda t: t not in _COMPASS)
            label = ' '.join(tag_label(t) for t in shown) or note
            labels = groups.setdefault(ipa, [])
            if label and label not in labels:
                labels.append(label)
        items = pick_ipas(list(groups.items()))
        if len(items) == 1:
            return f'<span class="pr">{esc(items[0][0])}</span>'
        parts = []
        any_label = False
        for ipa, labels in items:
            p = esc(ipa)
            if labels:
                any_label = True
                p += f' <span class="pl">{esc(", ".join(labels[:MAX_TAGS]))}</span>'
            parts.append(p)
        sep = ' · ' if any_label else ', '
        return f'<span class="pr">{sep.join(parts)}</span>'

    def reading(self, title: str, rec: Rec, senses: str) -> str:
        # The canonical spelling only when it adds marks to the title
        # (amo -> amō); upstream's 'Diá de la Madre' and 'είκοσι δυο'
        # drop or move one.
        shown = next((c for c in rec.canon_all if keeps_marks(c, title)), title)
        if self.rtl_lang:
            h = f'<span class="hw"{dir_attr("rtl", self.rtl_lang)}>{esc(shown)}</span>'
        else:
            h = f'<span class="hw">{esc(shown)}</span>'
        h += self.ipa(rec.sounds)
        rm = rec.roman
        if rec.eumhun:
            rm = f'eumhun {rec.eumhun}'
        if rm:
            h += f'<span class="rm">{esc(rm)}</span>'
        return h + senses

    def article(self, title: str, recs: list, dir_label: str) -> str:
        self.title = title
        rendered = [(r, self.senses(r)) for r in recs]
        # A record whose senses all render empty (a Korean syllable page
        # that only had flattened hanja tables) is left out, unless it is
        # the only one.
        shown = [x for x in rendered if x[1]] or rendered[:1]
        body = '<hr class="sep">'.join(self.reading(title, r, s) for r, s in shown)
        self.title = None
        css = CSS_EXM if '<details class="exm">' in body else CSS
        return f'{css}<div class="e"><span class="dir">{esc(dir_label)}</span>{body}</div>'


# ── Main build logic ──────────────────────────────────────────

def build_language(lang_key: str, *, pack: bool = True):
    """Build MDX for one language."""
    lang = LANGUAGES[lang_key]
    code = lang['code']
    name_en = lang['name_en']
    name_native = lang['name_native']
    flag = lang['flag']
    data_file = DATA_DIR / lang['file']

    if not data_file.exists():
        print(f"ERROR: {data_file} not found. Download from kaikki.org first.")
        return None

    dict_name = f"Kaikki-{code.upper()}-EN"
    dict_dir = OUTPUT_DIR / dict_name
    dict_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"Building {name_en}-English from Kaikki.org...")
    print(f"  Source: {data_file}")

    dir_label = f'{flag} {name_native} → English {FLAG_EN}'

    # ── Phase 1: parse, grouped by page title (JSONL order) ──
    by_title = {}
    side = {}
    for r in parse_kaikki_file(data_file, lang, side):
        by_title.setdefault(r.word, []).append(r)
    titles = set(by_title)
    canon_map = {}
    for title, recs in by_title.items():
        for r in recs:
            for c in r.canon_all:
                lst = canon_map.setdefault(c, [])
                if title not in lst:
                    lst.append(title)
    fold = FOLDS.get(lang.get('fold'))
    infl_map = {}
    if lang.get('infl_resolve'):
        for title, recs in by_title.items():
            for r in recs:
                for form in r.infl:
                    for k in {form, fold(form) if fold else form}:
                        if k in titles:
                            continue
                        lst = infl_map.setdefault(k, [])
                        if title not in lst:
                            lst.append(title)
    resolver = Resolver(titles, canon_map, fold, infl_map)
    article_titles = {t for t, recs in by_title.items() if any(r.article for r in recs)}
    # Articles that are only inflections (their form-of senses were found
    # from the gloss text): chains pass through them to the lemma.
    form_articles = {t for t in article_titles
                     if all(s.form for r in by_title[t] for s in r.senses)}
    n_records = sum(len(v) for v in by_title.values())
    print(f"  Records with glosses: {n_records:,}  titles: {len(titles):,}"
          f"  with an article: {len(article_titles):,}")

    # ── Phase 2: resolve form-of / alt-of bases ──
    for title, recs in by_title.items():
        for r in recs:
            for s in r.senses:
                if s.bases or s.form:
                    s.resolved = resolver.sense(s, title)

    def direct_bases(title):
        out = []
        for r in by_title[title]:
            if r.article and title not in form_articles:
                continue
            for s in r.senses:
                for _, t in s.resolved:
                    if t != title and t not in out:
                        out.append(t)
        return out

    memo = {}

    def targets_of(title):
        """Article titles a form-only title leads to (chains flattened)."""
        if title in memo:
            return memo[title]
        out = []
        frontier = [title]
        seen = {title}
        for _ in range(MAX_CHAIN):
            nxt = []
            for t in frontier:
                for b in direct_bases(t):
                    if b in seen:
                        continue
                    seen.add(b)
                    if b in article_titles:
                        if b not in out:
                            out.append(b)
                        if b in form_articles:
                            nxt.append(b)
                    else:
                        nxt.append(b)
            if not nxt:
                break
            frontier = nxt
        memo[title] = out
        return out

    # Form-only titles whose bases reach no article stay as small articles.
    form_targets = {}
    orphans = set()
    for title, recs in by_title.items():
        if title in article_titles:
            continue
        tg = targets_of(title)
        if tg:
            form_targets[title] = tg[:MAX_TARGETS]
        else:
            orphans.add(title)
    article_keys = article_titles | orphans

    # Extra @@@LINKs after an article, so the headword it points to is shown
    # too: first its pure form-of records ('sono' -> essere, suonare), then
    # the form-of senses of mixed records ('есть' -> быть, 'parole' ->
    # parola), then records that only point elsewhere ('alternative form of
    # X', 'diminutive of X', Korean multi-character hanja 學校 -> 학교). A
    # single hanja is not linked to its hangul syllable page (hundreds of
    # senses).
    extra_links = {}
    for title in article_titles:
        out = []
        recs = by_title[title]
        firsts = [(r, r.senses) for r in recs if not r.article]
        mixed = [(r, [s for s in r.senses if s.form]) for r in recs
                 if r.article and any(s.form for s in r.senses)]
        pointers = [(r, r.senses) for r in recs
                    if r.article and all(s.pointer for s in r.senses)
                    and not (code == 'ko' and len(title) == 1
                             and all(s.hanja for s in r.senses))]
        for r, senses in firsts + mixed + pointers:
            for s in senses:
                for _, t in s.resolved:
                    if t == title:
                        continue
                    for tt in ([t] + (targets_of(t) if t in form_articles else [])
                               if t in article_keys else targets_of(t)):
                        if tt != title and tt not in out:
                            out.append(tt)
        if out:
            extra_links[title] = out[:MAX_TARGETS]

    primary = {}                      # key -> list of @@@LINK targets ([] = article only)
    for t in by_title:
        if t in article_keys:
            primary[t] = extra_links.get(t, [])
        else:
            primary[t] = form_targets[t]
    lower_keys = {k.lower() for k in primary}

    def lead(k):
        if k in article_keys:
            return ([k] + primary[k])[:MAX_TARGETS]
        return primary[k]

    added = {}                        # secondary key -> targets
    stats = Counter()

    def add_key(key, tg, kind):
        key = nfc(key.strip())
        if not key or '\n' in key:
            return
        low = key.lower()
        if low in lower_keys and key not in added:
            return
        lst = added.setdefault(key, [])
        if not lst:
            lower_keys.add(low)
            stats[kind] += 1
        for t in tg:
            if t not in lst and len(lst) < MAX_TARGETS:
                lst.append(t)

    # ── Phase 3: inflection-table keys ──
    if lang.get('tables'):
        for title, recs in by_title.items():
            if title not in article_titles:
                continue
            for r in recs:
                for form in r.tables:
                    if code == 'la':
                        form = fold(form)
                        if form == title:
                            continue
                    add_key(form, [title], 'table')
    table_keys = set(added)

    # ── Phase 4: canonical (marked) spellings of lemmas ──
    # A spelling that folds to another article is that article's (the
    # hamza-less page اطباء has the canonical أَطِبَّاء of أطباء).
    if lang.get('canon_keys'):
        for title, recs in by_title.items():
            if title not in article_titles:
                continue
            for r in recs:
                if r.article:
                    for c in r.canon_all[:2]:
                        fc = fold(c) if fold else c
                        if fc != title and fc in article_titles:
                            continue
                        add_key(c, [title], 'canonical')

    # ── Phase 5: typing variants ──
    # A variant that is a page of its own keeps its records first and gets
    # the variant's headwords as extra @@@LINKs (Turkish ırak 'far' + Irak,
    # Russian все + всё, Arabic امر + أمر); otherwise it becomes a new key.
    # Greek variants of inflection-table keys only become new keys: ό, ού,
    # άς (endings, or forms of rare words) must not add a headword to ο,
    # ου, ας.
    primary_lower = {k.lower() for k in primary}
    if not lang.get('table_variants_new'):
        table_keys = set()

    def add_variant(v, tg, label='variant', new_only=False):
        v = nfc(v.strip())
        if not v or '\n' in v:
            return
        if new_only and (v in primary or v.lower() in primary_lower):
            return
        if v in primary:
            lst = primary[v]
            kind = label + ' on a page'
        else:
            lst = added.get(v)
            kind = label
            if lst is None:
                lst = added[v] = []
        n0 = len(lst)
        low = v.lower()
        for t in tg:
            # A target that differs only in case is shown by the lookup anyway.
            if t.lower() != low and t not in lst and len(lst) < MAX_TARGETS:
                lst.append(t)
        if not lst:
            if kind == label:
                del added[v]
            return
        if len(lst) > n0 and (n0 == 0 or kind != label):
            stats[kind] += 1

    # Arabic definite forms of nouns and adjectives: text has اللغة, the page
    # is لغة (sun letters are not written differently, so the prefix is
    # always ال). An existing page (الكتاب 'the Book') keeps its own record.
    if code == 'ar':
        for title in sorted(article_titles):
            if (' ' not in title and not title.startswith('ال') and len(title) > 1
                    and any(r.article and r.pos in ('n.', 'adj.') for r in by_title[title])):
                add_variant('ال' + title, [title], 'definite')
        # Defective (manqūṣ) nouns and adjectives: the page is مُحَامٍ (محام),
        # text has محامي and المحامي. Taken from the lemma's own definite
        # form (forms[]: الْمُحَامِي) and from upstream's gloss-less
        # 'with-definite-article' pages (وادي, معاني -> معان -> معنى).
        # A spelling with an article of its own (حالي 'current') is left
        # alone; a form key (نادي, imperative of نادى) gets the noun too.
        manqus = {}
        for title in sorted(article_titles):
            for r in by_title[title]:
                if r.ar_def and fold(r.ar_def) == 'ال' + title + 'ي':
                    manqus.setdefault(title + 'ي', title)
        for w in side.get('ar_definite', ()):
            if w.endswith('ي') and w[:-1] in primary:
                manqus.setdefault(w, w[:-1])
        for w, stem in sorted(manqus.items()):
            if w in article_keys:
                continue
            tg = lead(stem)
            add_variant(w, tg, 'manqus')
            add_variant('ال' + w, tg, 'manqus')

    if lang.get('variants'):
        leads = {k: lead(k) for k in primary}
        leads.update((k, list(v)) for k, v in added.items())
        for vname in lang['variants']:
            fn = VARIANT_FUNCS[vname]
            for k, tg in leads.items():
                kl = k.lower()
                for v in fn(k):
                    # A variant that only changes case (Ankara'da -> ankara'da)
                    # is found by the case-insensitive lookup already.
                    if v.lower() != kl:
                        add_variant(v, tg, new_only=k in table_keys)

    keys = set(primary) | set(added)

    # ── Phase 6: write MDict source ──
    renderer = Renderer(lang, keys)
    txt_path = dict_dir / f"kaikki_{code}_entries.txt"
    print(f"  Writing → {txt_path}...")
    n_art = n_link = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for key in sorted(keys, key=lambda k: (k.lower(), k)):
            if key in primary:
                if key in article_keys:
                    html = renderer.article(key, by_title[key], dir_label)
                    f.write(f"{key}\n{html}\n</>\n")
                    n_art += 1
                links = primary[key]
            else:
                links = added[key]
            for t in links:
                f.write(f"{key}\n@@@LINK={t}\n</>\n")
                n_link += 1

    # ── Integrity checks ──
    bad = [t for k, v in list(primary.items()) + list(added.items())
           for t in v if t not in article_keys]
    if bad:
        raise SystemExit(f"  ERROR: {len(bad)} @@@LINK targets are not article keys: {bad[:5]}")
    n_keys = len(keys)
    print(f"  Article keys: {len(article_keys):,} (orphan forms kept as articles: {len(orphans):,})")
    print(f"  Form keys (@@@LINK only): {len(form_targets):,};"
          f" articles with extra @@@LINKs: {len(extra_links):,}")
    print(f"  Added keys: " + ', '.join(f'{k} {v:,}' for k, v in sorted(stats.items())))
    print(f"  {n_art:,} articles + {n_link:,} @@@LINK records = {n_art + n_link:,} records,"
          f" {n_keys:,} keys")

    result = {'articles': n_art, 'links': n_link, 'records': n_art + n_link,
              'keys': n_keys, 'stats': dict(stats), 'orphans': len(orphans),
              'form_keys': len(form_targets), 'extra_links': len(extra_links),
              'titles': len(titles)}
    if not pack:
        return result

    # ── Phase 7: pack MDX ──
    mdx_path = dict_dir / f"Kaikki-{code.upper()}-EN.mdx"
    success, size_mb, _ = pack_mdx(
        txt_path,
        f"Kaikki {name_en}-English",
        header_description(name_en),
        mdx_path,
        inputs=[data_file],
    )
    if not success:
        return None
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name=f"Kaikki {name_en}-English",
        description=(f"{name_en}-English dictionary with {n_art:,} headwords: English "
                     f"glosses, IPA and usage examples; inflected forms and spelling "
                     f"variants lead to their headwords. From the English Wiktionary "
                     f"(https://en.wiktionary.org/), © Wiktionary contributors, "
                     f"extracted by Wiktextract / Kaikki.org (https://kaikki.org/). "
                     f"Converted to MDict and modified by OpenMDict. License: "
                     f"CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/)."),
        direction={"src": code.upper(), "dest": ["EN"]},
        entries=n_art + n_link,
        license="CC-BY-SA-4.0",
        # Must start with "Kaikki.org": gen_third_party_notices.py keys its
        # attribution rows by dataSource prefix.
        data_source="Kaikki.org (English Wiktionary extract, © Wiktionary contributors)",
        tier=3,
    )
    # Headword count alongside the record count.
    meta_path = mdx_path.with_suffix('.meta.json')
    meta = json.loads(meta_path.read_text(encoding='utf-8'))
    meta['headwords'] = n_art
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + '\n',
                         encoding='utf-8')

    # ── Phase 8: preview ──
    _generate_preview(lang_key, by_title, renderer, article_keys, dir_label, dict_dir)
    return result


def header_description(name_en: str) -> str:
    """MDX header description in the shared layout (shared.build.description_html):
    what the dictionary contains, the attribution required by CC BY-SA 4.0 and
    the converter credit."""
    return description_html(
        title=f"Kaikki {name_en}-English",
        about=[
            f"{name_en}-English dictionary: English glosses, IPA and usage examples; "
            "inflected forms and spelling variants lead to their headwords.",
        ],
        source=(
            f"{name_en} entries of the English Wiktionary "
            f'(<a href="https://en.wiktionary.org/">en.wiktionary.org</a>), '
            f"&copy; Wiktionary contributors. Extracted by Wiktextract "
            f"(Tatu Ylonen, LREC 2022) and published at "
            f'<a href="https://kaikki.org/dictionary/{name_en}/">kaikki.org</a> '
            f"(data downloaded {KAIKKI_DOWNLOADED})."
        ),
        license=(
            '<a href="https://creativecommons.org/licenses/by-sa/4.0/">CC BY-SA 4.0</a>. '
            "Wiktionary text is dual-licensed under CC BY-SA 4.0 and the GFDL."
        ),
        changes="filtered, restructured, and inflected-form and spelling-variant keys added",
        adaptation_license="This compilation is distributed under CC BY-SA 4.0.",
    )


def descriptions() -> dict[str, str]:
    """Header description of every Kaikki-XX-EN.mdx this script builds, keyed by
    file name, computed without building (the build stamps the same string)."""
    return {f"Kaikki-{lang['code'].upper()}-EN.mdx": header_description(lang['name_en'])
            for lang in LANGUAGES.values()}


# ── Preview ────────────────────────────────────────────────────

SAMPLE_WORDS = {
    'es': ['agua', 'casa', 'hola', 'comer', 'bonito', 'libro'],
    'ar': ['ماء', 'كتاب', 'جميل',
           'أكل', 'مدرسة', 'بيت'],
    'fr': ['maison', 'être', 'manger', 'eau', 'bonjour', 'livre'],
    'ru': ['дом', 'книга', 'вода',
           'есть', 'хорошо', 'человек'],
    'it': ['casa', 'essere', 'mangiare', 'acqua', 'libro', 'buono'],
    'pt': ['casa', 'ser', 'comer', 'água', 'livro', 'bom'],
    'el': ['σπίτι', 'νερό', 'βιβλίο',
           'καλός', 'άνθρωπος'],
    'tr': ['ev', 'su', 'kitap', 'güzel', 'gitmek', 'insan'],
    'la': ['domus', 'aqua', 'liber', 'bonus', 'homo', 'esse'],
    'ko': ['집', '물', '사람', '하다', '책', '좋다'],
}


def _generate_preview(lang_key: str, by_title: dict, renderer: Renderer,
                      article_keys: set, dir_label: str, dict_dir: Path):
    """Generate preview HTML for visual review."""
    lang = LANGUAGES[lang_key]
    code = lang['code']
    preview_path = dict_dir / f"kaikki_{code}_preview.html"
    entries_html = [renderer.article(w, by_title[w], dir_label)
                    for w in SAMPLE_WORDS.get(code, []) if w in article_keys]
    generate_preview(entries_html, preview_path,
                     f'Kaikki {lang["name_en"]}-English — preview')


# ── Main ──────────────────────────────────────────────────────

def main():
    if len(sys.argv) > 1:
        langs = sys.argv[1:]
    else:
        langs = list(LANGUAGES.keys())

    for lang_key in langs:
        if lang_key not in LANGUAGES:
            print(f"Unknown language: {lang_key}")
            print(f"Available: {', '.join(LANGUAGES.keys())}")
            continue
        build_language(lang_key)

    print("\nDone!")


if __name__ == '__main__':
    main()
