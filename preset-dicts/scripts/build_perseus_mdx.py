#!/usr/bin/env python3
"""
Build LSJ (Greek-English) and Lewis & Short (Latin-English) MDX dictionaries
from Perseus Digital Library TEI P4 XML.

Usage:
    python build_perseus_mdx.py [--only LSJ-GRC-EN|Lewis-Short-LA-EN]

Input:  ../data/perseus/lsj/grc.lsj.perseus-eng1..27.xml (all 27 parts),
        ../data/perseus/ls-eng2/lat.ls.perseus-eng2.xml (the maintained
        Unicode edition of Lewis & Short, pinned in fetch_data.sh)
Output: ../output/LSJ-GRC-EN/LSJ-GRC-EN.mdx
        ../output/Lewis-Short-LA-EN/Lewis-Short-LA-EN.mdx

Every upstream entry is rendered in full: the entry-level text before the
first sense (principal parts, dialect forms, etymology, "v. X" references)
becomes an intro block, every sense is kept untruncated, citations keep
author, work and passage, and cross-references become entry:// links when
the target is a headword.

Lookup: the app matches keys ignoring case only (no diacritic folding), so
the build adds @@@LINK redirect keys for the spellings readers actually
type -- monotonic and unaccented Greek, grave-accented oxytones as they
appear in running text, i/u spellings of L&S j/v words, macronized Latin --
and for the alternate spellings both lexica list.
"""

import argparse
import difflib
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import (get_css, INFLECTION, DEFINITION, SENSE_NUMBER, EXAMPLES,
                          GREEK_TEXT, CROSSREF, NESTED_SENSES,
                          TEXT_SECONDARY, TEXT_LINK)
from shared.html import esc, esc_attr
from shared.build import (pack_mdx, generate_preview as _shared_preview, write_catalog_metadata,
                          description_html)

DATA_DIR = SCRIPT_DIR.parent / "data" / "perseus"
OUTPUT_BASE = SCRIPT_DIR.parent / "output"

# ── Politically-correct flag constants ────────────────────────
FLAG_EN = '🇬🇧🇺🇸'
FLAG_GRC = '🇬🇷'
FLAG_LA = '🏛️'

# ── Beta Code → Unicode Greek ─────────────────────────────────
#
# Perseus beta code: lowercase ASCII letters are Greek letters, '*' marks a
# capital (its breathing/accent may stand before the letter: *)/a = Ἄ), and
# the marks below follow the letter. Perseus adds ^ and _ for short and long
# vowel quantity, and writes '<*>' where the scan was illegible.

_BETA_LOWER = {
    'a': 'α', 'b': 'β', 'g': 'γ', 'd': 'δ', 'e': 'ε', 'z': 'ζ',
    'h': 'η', 'q': 'θ', 'i': 'ι', 'k': 'κ', 'l': 'λ', 'm': 'μ',
    'n': 'ν', 'c': 'ξ', 'o': 'ο', 'p': 'π', 'r': 'ρ', 's': 'σ',
    't': 'τ', 'u': 'υ', 'f': 'φ', 'x': 'χ', 'y': 'ψ', 'w': 'ω',
    'v': 'ϝ',   # digamma (epigraphic and dialect forms)
}
_BETA_UPPER = {k: v.upper() for k, v in _BETA_LOWER.items()}

# Unicode combining diacritics for Greek
_SMOOTH = '\u0313'      # psili / smooth breathing
_ROUGH = '\u0314'       # dasia / rough breathing
_ACUTE = '\u0301'       # oxia / acute
_GRAVE = '\u0300'       # varia / grave
_CIRCUMFLEX = '\u0342'  # perispomeni / circumflex
_DIAERESIS = '\u0308'
_IOTA_SUB = '\u0345'    # ypogegrammeni / iota subscript
_BREVE = '\u0306'       # Perseus '^' (short vowel)
_MACRON = '\u0304'      # Perseus '_' (long vowel)
_KORONIS = '\u0343'
_KERAIA = '\u0374'      # Greek numeral sign (NFC turns it into U+02B9)

_MARKS = {
    ')': _SMOOTH, '(': _ROUGH, '/': _ACUTE, '\\': _GRAVE, '=': _CIRCUMFLEX,
    '+': _DIAERESIS, '|': _IOTA_SUB, '^': _BREVE, '_': _MACRON,
}
# Order of stacked marks. Several of them share canonical combining class
# 230, so NFC composes ΐ, ΰ or ἄ only when they come in this order
# (quantity, diaeresis, breathing, accent; iota subscript last).
_MARK_RANK = {_BREVE: 0, _MACRON: 0, _DIAERESIS: 1, _SMOOTH: 2, _ROUGH: 2,
              _ACUTE: 3, _GRAVE: 3, _CIRCUMFLEX: 3, _IOTA_SUB: 4}
_GREEK_VOWELS = set('αεηιουωΑΕΗΙΟΥΩ')
_ACCENTS = {_ACUTE, _GRAVE, _CIRCUMFLEX}
# Consonants that end an elided word: δ' ἀπ' ἀλλ' (written 'd)', 'a)p)').
_ELIDING = set('βγδθκλμπτφχ')
_BETA_VOWELS = set('aehiouw')
# '<*>' marks a place the scan could not read. Between two letters it is a
# lost mark (join the word); before a mark it is a lost letter, and anywhere
# else lost text: both become '…'.
_GAP_IN_WORD = re.compile(r'<\*>(?=[a-z*])')
_GAP_BEFORE_MARK = re.compile(r'<\*>[()/\\=+|^_]+')
# Runs of quantity marks with no letter are metrical schemes ('^__^__').
_METRICAL = {'^': '⏑', '_': '–'}


def _marks_end(beta: str, j: int) -> int:
    while j < len(beta) and beta[j] in _MARKS:
        j += 1
    return j


def _starts_vowel_word(rest: str) -> bool:
    """rest begins with whitespace and then a vowel-initial Greek word."""
    if not rest[:1].isspace():
        return False
    rest = rest.lstrip()
    return bool(rest) and (rest[0] in _BETA_VOWELS or rest[0] == '*' and
                           re.match(r'\*[()/\\=+|]*[aehiouw]', rest) is not None)


def _is_breathing(beta: str, j: int, letter: str, word: list, open_parens: int,
                  accented: bool) -> bool:
    """Is the '(' or ')' at beta[j], right after `letter`, a breathing?

    Beta code writes breathings, parentheses and (with ')') the elision
    apostrophe alike. A breathing sits on ρ, on a word-initial vowel (or
    the second vowel of an initial diphthong, αἰ, οὐ), or on a medial vowel
    as the koronis of a crasis (κἀγώ 'ka)gw/', τἆλλα, χὠ) or a Laconian
    aspirate (Μῶἁ). It is a parenthesis when it closes a '(' still open,
    when '(' opens a parenthesised letter ('parake/krou(s)mai'), after any
    other consonant, and after a vowel of a word that already has its
    accent (that word is complete: '(bre/mw)'); before a vowel-initial word
    such a ')' is an elision mark ('e)/sqi) e(/khlos', handled by the
    caller).
    """
    m, n = beta[j], len(beta)
    k = _marks_end(beta, j)
    nxt = beta[k] if k < n else ''
    letter_follows = bool(nxt) and (nxt.lower() in _BETA_LOWER or nxt == '*')
    closes = m == ')' and open_parens > 0 and not (j + 1 < n and beta[j + 1] in _MARKS)
    initial = not word or (len(word) == 1 and word[0] in _GREEK_VOWELS
                           and letter in 'ιυΙΥ')
    if letter in 'ρΡ' and word and m == '(' and re.match(r'\([a-z]\)', beta[j:]):
        return False                    # 'pula^-(j)or(v)o/-': a bracketed ϝ after ρ
    if letter in 'ρΡ' and m == ')' and open_parens and j >= 2 and beta[j - 2] == '(':
        return False                    # 'katar(r)a/q-': a bracketed ρ
    if letter in 'ρΡ' or (initial and letter in _GREEK_VOWELS):
        return not (closes and not letter_follows)
    if letter not in _GREEK_VOWELS:
        return False
    if m == '(':
        return re.match(r'\([a-z/\\=+|^_]{1,6}\)', beta[j:]) is None
    if open_parens > 0:
        return False
    return letter_follows or not accented


def _compose(letter: str, marks: list) -> str:
    if not marks:
        return letter
    if marks == [_ACUTE] and letter not in _GREEK_VOWELS:
        # An acute on a consonant is the numeral sign (β´ = 2).
        return ('σ' if letter == 'ς' else letter) + _KERAIA
    ordered = sorted(dict.fromkeys(marks), key=_MARK_RANK.get)
    return unicodedata.normalize('NFC', letter + ''.join(ordered))


def _sigma_is_final(beta: str, j: int) -> bool:
    """σ at the end of beta[:j]: final unless the word goes on. It goes on
    before a letter, an elision mark (ὅσ'), a parenthesised letter
    ('krou(s)mai'), or a word-formation hyphen (βᾰναυσ-ία, πρόσ-ψαυσις,
    and the stem προσ-)."""
    nxt = beta[j] if j < len(beta) else ''
    if not nxt:
        return True
    if nxt.lower() in _BETA_LOWER or nxt == '*' or nxt in "'’-":
        return False
    if nxt in ')]([' and j + 1 < len(beta) and beta[j + 1].lower() in _BETA_LOWER:
        return False
    return True


def beta_to_unicode(beta: str, open_parens: int = 0) -> str:
    """Convert Perseus beta code to Unicode polytonic Greek (NFC).

    open_parens: literal '(' still open in the text before this string
    (the Renderer tracks them across elements)."""
    if '<*>' in beta:
        beta = _GAP_IN_WORD.sub('', beta)
        beta = _GAP_BEFORE_MARK.sub('…', beta).replace('<*>', '…')
    out = []
    word: list[str] = []          # Greek letters of the current word so far
    accented = False              # the current word has an accent already
    # open_parens: literal '(' not yet closed (an argument; see docstring)
    carry: list[str] = []         # a mark that belongs on the next letter
    i, n = 0, len(beta)
    while i < n:
        ch = beta[i]
        pre: list[str] = []
        j = i
        if ch in _MARKS:
            k = _marks_end(beta, i)
            if k < n and beta[k] == '*':
                pre = list(beta[i:k])          # ')/*ai+dos': marks before '*'
                j = k
            else:
                # Marks with no letter to carry them: parentheses, '=',
                # an elision apostrophe, or a metrical scheme.
                run = beta[i:k]
                if all(m in '^_' for m in run):
                    out.append(''.join(_METRICAL[m] for m in run))
                for m in run:
                    if m == '(':
                        out.append('(')
                        open_parens += 1
                    elif m == ')':
                        # γ' ἐμὴν 'g) e)mh\\n', ἔσθι' ἕκηλος 'e)/sqi) e(/khlos'
                        if (not open_parens and word and _starts_vowel_word(beta[k:])
                                and (word[-1] in _ELIDING
                                     or word[-1] in _GREEK_VOWELS and accented)):
                            out.append("'")
                        else:
                            out.append(')')
                            open_parens = max(0, open_parens - 1)
                    elif m == '=':
                        out.append('=')
                        word, accented = [], False
                i = k
                continue
        upper = False
        if beta[j] == '*':
            upper = True
            j += 1
            while j < n and beta[j] in _MARKS:
                pre.append(beta[j])
                j += 1
        if j >= n or beta[j].lower() not in _BETA_LOWER:
            if j == i:                          # an ordinary character
                out.append(ch)
                word, accented = [], False
                i += 1
            else:                               # '*' with no letter: drop it
                i = j
            continue
        base = beta[j].lower()
        j += 1
        letter = _BETA_UPPER[base] if upper else _BETA_LOWER[base]
        marks = [_MARKS[m] for m in pre]
        while j < n and beta[j] in _MARKS:
            if beta[j] in '()' and not _is_breathing(
                    beta, j, letter, word, open_parens,
                    accented or bool(_ACCENTS & set(marks))):
                break                           # a parenthesis, not a breathing
            marks.append(_MARKS[beta[j]])
            j += 1
        if letter == 'σ' and _sigma_is_final(beta, j):
            letter = 'ς'
        marks = carry + marks
        carry = []
        if (_DIAERESIS in marks and letter not in 'ιυΙΥ' and j < n
                and beta[j].lower() in 'iu'):
            # 'e)pi-klh/+iw': the diaeresis belongs on the ι that follows
            # (ἐπικληΐω), not on η.
            marks = [m for m in marks if m != _DIAERESIS]
            carry = [_DIAERESIS]
        out.append(_compose(letter, marks))
        word.append(letter)
        accented = accented or bool(_ACCENTS & set(marks))
        i = j
    return unicodedata.normalize('NFC', ''.join(out))


# L&S eng2 ships Greek already converted to Unicode; a few dozen strings
# kept artefacts of that conversion: marks before a capital ('̓Ηώς'), a
# '?' for a lost space or '=' ('ἀμβολή?͂ ἀναβολή', 'Αὐλίρκιοι?̓Εβουραϊκοί'),
# and literal quantity marks ('βα^ρύς').
_LEAD_MARKS = re.compile('(^|[\\s(\\[,;—-])([\u0300-\u036f]+)([\u0391-\u03a9])')
_QMARK_CAPITAL = re.compile('\\?([\u0313\u0314][\u0300-\u036f]*)([\u0391-\u03a9])')
_QUANTITY = re.compile('([αεηιουωΑΕΗΙΟΥΩ\u1f00-\u1fff][\u0300-\u036f]*)([\\^_])')


def repair_unicode_greek(text: str) -> str:
    text = unicodedata.normalize('NFD', text)
    text = text.replace('?\u0342', ' =')
    text = _QMARK_CAPITAL.sub(lambda m: ' ' + m.group(2) + m.group(1), text)
    text = _LEAD_MARKS.sub(lambda m: m.group(1) + m.group(3) + m.group(2), text)
    text = _QUANTITY.sub(lambda m: m.group(1)[0] + (_BREVE if m.group(2) == '^' else _MACRON)
                         + m.group(1)[1:], text)
    return unicodedata.normalize('NFC', text)


def _convertible(text: str) -> bool:
    """Beta code is pure ASCII. Text in a lang="greek" element that already
    holds non-ASCII letters (Unicode Greek, or a Sanskrit/Lithuanian cognate
    mis-tagged as Greek) is passed through unchanged."""
    return all(ord(c) < 128 for c in text if c.isalpha())


# A few upstream <tr> (translation) elements hold Greek in beta code without
# lang="greek" ('<tr>kinh/mata</tr>' in κίνημα, 'to be kaqa/rios'). A word
# is taken for beta code only when every mark follows a vowel (or ρ), and a
# text is converted only when one word is unmistakable: an accent plus a
# letter English, Sanskrit and Latin cognates do not write that way (η ω θ
# ξ χ ψ ζ), or a breathing on the first vowel. 'hva/rate', 'dasra/s',
# 'one/s', 'well=made', 'cor(d)-' stay as they are.
_BETA_TOKEN = re.compile(r"[A-Za-z)(/\\=|+]+")


def _beta_word(t: str) -> bool:
    if not re.fullmatch(r"[a-z][a-z)(/\\=|+]*", t) or set(t) & set('jv'):
        return False
    return all(t[m.start() - 1] in 'aehiouwr' for m in re.finditer(r"[)(/\\=|+]+", t))


def _unmistakable_beta(t: str) -> bool:
    return (_beta_word(t) and re.search(r"[aehiouw][)(]?[/\\=]", t) is not None and
            bool(set(t) & set('hwqcxyz') or re.match(r"[aehiouw]+[)(]", t)))


def _beta_words(text: str) -> list:
    """The whole words of a text (not stems or endings: '-mws', 'u(e)d-')."""
    return [m for m in _BETA_TOKEN.finditer(text)
            if text[m.start() - 1:m.start()] != '-' and text[m.end():m.end() + 1] != '-']


def tr_beta_html(text: str):
    """HTML for a <tr> text with its beta-code words as Greek, or None."""
    words = _beta_words(text)
    if '<*>' in text or not any(_unmistakable_beta(m.group()) for m in words):
        return None
    out, pos = [], 0
    for m in words:
        if _beta_word(m.group()) and re.search(r"[)(/\\=|+]", m.group()):
            out.append(esc(text[pos:m.start()]))
            out.append(f'<span class="grk">{esc(beta_to_unicode(m.group()))}</span>')
            pos = m.end()
    out.append(esc(text[pos:]))
    return ''.join(out)


# ── Greek spelling variants for lookup ────────────────────────
#
# The iOS Greek keyboard is monotonic: it has the tonos (= acute) and the
# diaeresis but no breathings, circumflex, grave or iota subscript, and many
# readers type without any accents. Running text writes an oxytone's final
# acute as a grave (καὶ, ἀγαθὸς), which is what a reader selects and looks up.

_MONO_DROP = {_SMOOTH, _ROUGH, _IOTA_SUB, _MACRON, _BREVE, _KORONIS}


def acute_for_grave(text: str) -> str:
    d = unicodedata.normalize('NFD', text).replace(_GRAVE, _ACUTE)
    return unicodedata.normalize('NFC', d)


def monotonic(text: str) -> str:
    """ἄνθρωπος → άνθρωπος, οἶκος → οίκος, ᾠδή → ωδή."""
    out = []
    for c in unicodedata.normalize('NFD', text):
        if c in _MONO_DROP:
            continue
        if c in (_GRAVE, _CIRCUMFLEX):
            c = _ACUTE
        if c == _ACUTE and out and out[-1] == _ACUTE:
            continue
        out.append(c)
    return unicodedata.normalize('NFC', ''.join(out))


def unaccented(text: str) -> str:
    """Strip every combining mark: ἄνθρωπος → ανθρωπος, πραΰς → πραυς."""
    return unicodedata.normalize('NFC', ''.join(
        c for c in unicodedata.normalize('NFD', text) if not unicodedata.combining(c)))


def grave_form(text: str) -> str:
    """The running-text form of an oxytone (ἀγαθός → ἀγαθὸς), else ''."""
    d = unicodedata.normalize('NFD', text)
    if d.count(_ACUTE) != 1 or _CIRCUMFLEX in d or _GRAVE in d:
        return ''
    k = d.index(_ACUTE)
    if any(c in _GREEK_VOWELS or c.lower() in 'αεηιουω' for c in d[k + 1:]):
        return ''
    return unicodedata.normalize('NFC', d[:k] + _GRAVE + d[k + 1:])


def greek_variants(form: str) -> list[str]:
    """Spellings that should redirect to the key `form`."""
    out = []
    for v in (monotonic(form), unaccented(form), grave_form(form)):
        if v and v != form and v not in out:
            out.append(v)
    return out


# ── Latin spelling variants for lookup ────────────────────────
#
# L&S writes consonantal i and u as j and v (jus, juvenis); most modern
# texts write ius, iuvenis, and critical texts uita, uideo.

def latin_plain(text: str) -> str:
    """Drop macrons/breves (and the Cyrillic ў upstream uses for y-breve)."""
    text = text.replace('ў', 'y').replace('Ў', 'Y')
    return unicodedata.normalize('NFC', ''.join(
        c for c in unicodedata.normalize('NFD', text) if not unicodedata.combining(c)))


def latin_variants(form: str) -> list[str]:
    out = []
    i_form = form.replace('j', 'i').replace('J', 'I')
    for v in (i_form, form.replace('v', 'u').replace('V', 'U'),
              i_form.replace('v', 'u').replace('V', 'U')):
        if v != form and v not in out:
            out.append(v)
    return out


# ── HTML ───────────────────────────────────────────────────────

CSS = get_css(
    INFLECTION, DEFINITION, SENSE_NUMBER,
    EXAMPLES, GREEK_TEXT, CROSSREF, NESTED_SENSES,
    extra_light=(f'.e a{{color:{TEXT_LINK[0]}}}'
                 f'.bibl{{color:{TEXT_SECONDARY[0]}}}'
                 f'.hn{{font-size:0.55em;font-weight:500;color:{TEXT_SECONDARY[0]};'
                 'margin-left:4px;vertical-align:0.7em}'),
    extra_dark=(f'.e a{{color:{TEXT_LINK[1]}}}'
                f'.bibl{{color:{TEXT_SECONDARY[1]}}}'
                f'.hn{{color:{TEXT_SECONDARY[1]}}}'),
)

# Cross-reference placeholders; resolved to <a href="entry://…"> once every
# headword is known (a link is made only when its target is a key).
_L_OPEN, _L_MID, _L_CLOSE = '\ue000', '\ue001', '\ue002'
_LINK_RE = re.compile('\ue000([^\ue001]*)\ue001([^\ue002]*)\ue002')


def _link(target: str, label_html: str) -> str:
    return f'{_L_OPEN}{target}{_L_MID}{label_html}{_L_CLOSE}'


def _bracketed_letter(html: str, m) -> bool:
    """A one-letter reference in brackets that is not a reference: movable
    nu ('κε(ν)', 'λελογχᾰσι (ν)'), a letter glued to a word, or a noun's
    gender ('παῖς (ὁ)')."""
    target = m.group(1)
    if sum(not unicodedata.combining(c) for c in unicodedata.normalize('NFD', target)) != 1:
        return False
    before = re.sub('<[^>]*>|\ue000[^\ue001]*\ue001|\ue002', '', html[max(0, m.start() - 300):m.start()])
    after = re.sub(r'^(?:<[^>]*>)+', '', html[m.end():])
    if not (before.endswith('(') and after.startswith(')')):
        return False
    return target in ('ὁ', 'ἡ', 'ν') or (len(before) > 1 and before[-2].isalpha())


# Words that continue a Latin reference ('v. ad init.', 'cf. at and autem').
_LATIN_REF_NEXT = {'init', 'fin', 'med', 'sq', 'extr', 'and'}


def _english_word(html: str, m) -> bool:
    """An English word read as a Latin reference because markup split it from
    the word after it ('cf. an old formula', 'cf. as <pos>adj.</pos>'), which
    Renderer._latin_xrefs cannot see."""
    if m.group(1) not in _LATIN_ENGLISH:
        return False
    after = re.sub('<[^>]*>', '', html[m.end():m.end() + 200])
    nxt = re.match(r'\s+([a-z]{2,})\b', after)
    return nxt is not None and nxt.group(1) not in _LATIN_REF_NEXT


def resolve_links(html: str, keys, stats: dict, own_key: str = '') -> str:
    def repl(m):
        target, label = m.group(1), m.group(2)
        if target in keys and target != own_key and not _bracketed_letter(html, m) \
                and not _english_word(html, m):
            stats['linked'] = stats.get('linked', 0) + 1
            return f'<a href="entry://{esc_attr(target)}">{label}</a>'
        stats['unlinked'] = stats.get('unlinked', 0) + 1
        return label
    return _LINK_RE.sub(repl, html)


def _wrap(open_tag: str, inner: str, close_tag: str) -> str:
    """Wrap inner HTML, keeping its surrounding whitespace outside the tag."""
    core = inner.strip()
    if not core:
        return inner
    lead = inner[:len(inner) - len(inner.lstrip())]
    trail = inner[len(inner.rstrip()):]
    return f'{lead}{open_tag}{core}{close_tag}{trail}'


_PUNCT_EDGE = ' ,.;:·()[]—'


def _greek_link_target(text: str) -> str:
    """Lookup key for a one-word Greek reference ('' when it is a phrase)."""
    t = text.strip().strip(_PUNCT_EDGE).strip()
    if not t or ' ' in t or not any('Ͱ' <= c <= 'Ͽ' or 'ἀ' <= c <= '῿'
                                    for c in t):
        return ''
    t = ''.join(c for c in unicodedata.normalize('NFD', t) if c not in (_BREVE, _MACRON))
    return acute_for_grave(t.replace('-', ''))


# Greek words after these cues are references to another headword.
_XREF_CUE = re.compile(r'(?:\bv\.|\bcf\.|=|\bfor|\bfr\.|\bfrom|\bs\.\s?v\.)\s*\(?\s*$')
# L&S writes its cross-references as plain text: "v. publicus", "cf. sequor".
# A homograph number may stand between the cue and the word ("v. 2. cum").
_LATIN_XREF = re.compile(r'\b(v\.|cf\.|=|v(?=\s\d\.))(\s*(?:\d\.\s*)?)'
                         r'([A-Za-z\u00c0-\u024f\u0300-\u036f\u045e\u040e]{2,})')
_LATIN_XREF_STOP = {
    'infra', 'supra', 'the', 'foll', 'sub', 'under', 'in', 'id', 'ib', 'init',
    'fin', 'al', 'also', 'esp', 'etc', 'and', 'or', 'of', 'to', 'Gr', 'Sanscr',
    'Germ', 'Engl', 'Lat', 'Fr', 'Ital', 'Goth', 'Lith', 'Zend', 'Umbr', 'Osc',
    'Dor', 'Ion', 'Att', 'Aeol', 'Ep', 'act', 'pass', 'dep', 'adj', 'adv',
    'ex', 'nom', 'gen', 'dat', 'acc', 'abl', 'voc', 'sing', 'plur', 'h', 'l',
}

# Latin words that are also English, and the English words that show they
# are English after 'cf.'/'v.' ('cf. for syn.: …', 'cf. as a subst.'). 'for'
# followed by any word is English ('v. l. for olfactatrix').
_LATIN_ENGLISH = {'for', 'at', 'as', 'an', 'is', 'me', 'do', 'tu', 'ac', 'ad'}
_ENGLISH_NEXT = {'the', 'a', 'an', 'syn', 'full', 'this', 'that', 'further', 'more', 'adj', 'subst'}

_SKIP_TAGS = {'cb', 'pb', 'figure'}


def _skipped(child, parent) -> bool:
    """Page/column breaks, and a <sic> that has its <corr> beside it."""
    return child.tag in _SKIP_TAGS or (
        child.tag == 'sic' and any(c.tag == 'corr' for c in parent))
_CYRILLIC_Y = str.maketrans({'ў': 'y\u0306', 'Ў': 'Y\u0306'})


class Renderer:
    """TEI → HTML for one lexicon. Greek is converted wherever the element
    (or an ancestor) carries lang="greek"; other text is escaped as is."""

    def __init__(self, lsj: bool):
        self.lsj = lsj
        # '(' still open in the entry so far, so that beta code can tell a
        # closing parenthesis from a breathing ('(<foreign>bre/mw)</foreign>').
        self.parens = 0
        self.in_tr = False      # inside an LSJ <tr> (see tr_beta_html)

    def _track(self, text: str):
        self.parens = max(0, self.parens + text.count('(') - text.count(')'))

    # Text nodes ------------------------------------------------------
    def text(self, s: str, greek: bool, xref: bool) -> str:
        if not s:
            return ''
        if greek and _convertible(s):
            out = beta_to_unicode(s, self.parens)
            self._track(out)
            return esc(out)
        self._track(s)
        if self.in_tr and not greek:
            html = tr_beta_html(s)
            if html is not None:
                return html
        if greek:
            s = repair_unicode_greek(s)
        s = s.replace('<*>', '…')
        if not self.lsj:
            s = unicodedata.normalize('NFC', s.translate(_CYRILLIC_Y))
            if xref:
                return self._latin_xrefs(s)
        return esc(s)

    def _latin_xrefs(self, s: str) -> str:
        out, pos = [], 0
        for m in _LATIN_XREF.finditer(s):
            word = m.group(3)
            if word in _LATIN_XREF_STOP or word.lower() in _LATIN_XREF_STOP:
                continue
            nxt = re.match(r'\s*([A-Za-z]+)', s[m.end(3):])
            if word.lower() in _LATIN_ENGLISH and nxt and (
                    nxt.group(1).lower() in _ENGLISH_NEXT or word.lower() == 'for'):
                continue                # 'cf. for syn.', 'v. at the end of this art.'
            out.append(esc(s[pos:m.start(3)]))
            out.append(_link(latin_plain(word), esc(word)))
            pos = m.end(3)
        out.append(esc(s[pos:]))
        return ''.join(out)

    # Elements --------------------------------------------------------
    def children(self, el, greek: bool, xref: bool) -> str:
        parts = [self.text(el.text, greek, xref)]
        prev_text = el.text or ''
        for child in el:
            if child.tag != 'sense' and not _skipped(child, el):
                parts.append(self.element(child, greek, xref, prev_text))
            parts.append(self.text(child.tail, greek, xref))
            prev_text = child.tail or ''
        return ''.join(parts)

    def element(self, el, greek: bool, xref: bool, prev_text: str = '') -> str:
        tag = el.tag
        if tag in _SKIP_TAGS:
            return ''
        lang = el.get('lang')
        if lang is not None:
            greek = lang == 'greek'
        if tag == 'bibl':
            inner = re.sub(r'\s+', ' ', self.children(el, False, False)).strip()
            return f'<span class="bibl">{inner}</span>' if inner else ''
        if tag in ('quote', 'q'):
            inner = self.children(el, greek, False).strip()
            return f'"{inner}"' if inner else ''
        if tag == 'cit':
            return self.children(el, greek, False)
        if tag == 'reg':                       # <reg><sic/><corr/></reg>
            return self.children(el, greek, xref)
        if tag in ('tr', 'orth'):
            in_tr, self.in_tr = self.in_tr, self.in_tr or (self.lsj and tag == 'tr')
            inner = self.children(el, greek, xref)
            self.in_tr = in_tr
            return _wrap('<b>', inner, '</b>')
        if tag == 'xr':
            return _wrap('<span class="xr">', self.children(el, greek, xref), '</span>')
        if tag == 'ref':
            inner = self.children(el, greek, False)
            if greek:
                target = _greek_link_target(_strip_tags(inner))
                if target:
                    inner = _wrap('', _link(target, inner.strip()), '')
                return _wrap('<span class="grk">', inner, '</span>')
            if not self.lsj and el.get('type') != 'sym':
                word = _text_of(el).strip()
                if re.fullmatch(r'[A-Za-z\u00c0-\u024f\u0300-\u036f\u045e]{2,}', word):
                    inner = _wrap('', _link(latin_plain(word), inner.strip()), '')
            return inner
        if tag == 'foreign':
            inner = self.children(el, greek, False)
            if not greek:
                return _wrap('<i>', inner, '</i>')
            if self.lsj and _XREF_CUE.search(prev_text):
                target = _greek_link_target(_strip_tags(inner))
                if target:
                    inner = _wrap('', _link(target, inner.strip()), '')
            return _wrap('<span class="grk">', inner, '</span>')
        if tag == 'etym' and greek and self.lsj:
            inner = self.children(el, greek, False)
            target = _greek_link_target(_strip_tags(inner))
            if target:
                inner = _wrap('', _link(target, inner.strip()), '')
            return _wrap('<span class="grk">', inner, '</span>')
        # author, title, biblScope, gen, itype, pos, gramGrp/gram, lbl, usg,
        # tns, mood, case, number, per, date, placeName, abbr, name, hi,
        # trans, corr, note …: their text, in place.
        return self.children(el, greek, xref and tag in ('etym', 'hi', 'usg', 'lbl'))


def _text_of(el) -> str:
    """Text content without the skipped elements (see _skipped)."""
    parts = [el.text or '']
    for child in el:
        if not _skipped(child, el):
            parts.append(_text_of(child))
        parts.append(child.tail or '')
    return ''.join(parts)


def _strip_tags(html: str) -> str:
    return re.sub(r'<[^>]*>', '', html).replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>')


# '<itype>pros</itype>-' renders as 'προς-': each element is converted on
# its own, so a stem split from its hyphen gets a final ς. Same rule as
# _sigma_is_final (not before an English word: 'the Κόμπος-deme').
_SIGMA_HYPHEN = re.compile('(?<=[\u0370-\u03ff\u1f00-\u1fff\u0300-\u036f])ς((?:</[a-z]+>)*-)(?![A-Za-z])')


# Closing tags and/or the end of a link placeholder (see _link).
_CLOSES = '((?:</[a-z]+>|' + _L_CLOSE + ')+)'


def _clean_body(html: str) -> str:
    """Collapse whitespace and the punctuation the source markup leaves."""
    html = re.sub(r'\s+', ' ', html).strip()
    html = _SIGMA_HYPHEN.sub(r'σ\1', html)
    html = re.sub(r',((?:</[a-z]+>)+)\s*,', r',\1', html)     # 'sumptuously,</b>,'
    html = re.sub(r'(?<=[A-Za-z])\.\.(?![.])', '.', html)        # '<etym>id.</etym>.'
    html = re.sub(r'(:\s*){2,}', ': ', html)
    html = re.sub(r'\s+([,;:])(?=\s|$|<)', r'\1', html)
    # 'Arist. HA 488b7 .', 'v. ζῶ .', 'Plu. Caes. 29 :—', 'ἡ</span> ,= sq.',
    # 'Hdt. 7.9 .ά': whitespace the markup leaves between a closing tag and
    # the punctuation after it (not the gap dots '… . . γε').
    html = re.sub(_CLOSES + r'\s+([,;:])', r'\1\2', html)
    html = re.sub(_CLOSES + r'\s+\.(?!\s*\.)', r'\1.', html)
    # ... and before an element that opens with it ('ἡ <foreign>, (ἔχω)',
    # '-υος <foreign>, -υες', 'ἠγρεύσω</foreign> <tr>;</tr>')
    html = re.sub(r'\s+((?:<[a-z]+[^>]*>)+)([,;:])', r'\1\2', html)
    html = re.sub(r'\s+:—', ':—', html)                           # '(lyr.) :— Pass.'
    # ... and the space after a comma that upstream glued to the next word
    # ('Th. 2.60,al.', '<gen>ἡ</gen>,= sq.')
    html = re.sub(_CLOSES[:-1] + r'[,;])(?=[=A-Za-z\u0370-\u03ff\u1f00-\u1fff])', r'\1 ', html)
    html = re.sub(r'^(?:[\s,;:]|\.(?![.\w]))+', '', html)
    html = re.sub(r'(?:,\s*){2,}', ', ', html)
    html = re.sub(r'\s*[,;:]\s*$', '', html)
    html = re.sub(r';\s*\.—', '.—', html)
    html = re.sub(r'^\s*[.—\-]+\s*$', '', html)
    return html.strip()


def _has_words(html: str) -> bool:
    """Any letter at all: a lone 'ἡ' or 'e' is content, punctuation is not."""
    return any(c.isalpha() for c in _strip_tags(html))


# ── Headwords and keys ─────────────────────────────────────────
# Each entry has two spellings upstream:
#   key="yuxh/"          the plain lemma (homographs carry a trailing digit)
#   <orth>yu_x-h/</orth>  the printed form, with vowel-quantity marks (^ short,
#                         _ long) and the word-formation hyphens LSJ/L&S print.
# The printed form is what readers expect to see, but nobody can type it, so
# it is NOT a usable lookup key. Lookup keys come from `key`; the printed
# form is shown inside the article.

def _clean_key(key: str) -> str:
    """Strip homograph digits and editorial marks from an upstream key."""
    key = re.sub(r'\d+$', '', key.strip())
    key = key.replace('aelig;', 'ae').replace('oelig;', 'oe')
    key = key.replace('<*>', '')
    key = re.sub(r'[\[\]<>^_]', '', key)
    return key.strip()


def homograph_number(key: str) -> int:
    m = re.search(r'(\d+)$', key.strip())
    return int(m.group(1)) if m else 0


def greek_lookup_key(key: str) -> str:
    # A '(' or ')' that is not a breathing is never part of the word
    # ('e)piqeia/zw)', '*mw=a(').
    k = acute_for_grave(beta_to_unicode(_clean_key(key)))
    return re.sub(r'[()]', '', k).strip()


def _breathless(word: str) -> bool:
    """A vowel-initial form with no breathing on its first vowel or diphthong
    is an ending or a fragment that upstream tagged as <orth> ('μαστ-ιστής,
    <orth>οῦ</orth>, ὁ': the genitive), never a spelling."""
    g = _graphemes(word)
    if not g or g[0][0].lower() not in _GVOWELS:
        return False
    marks = g[0][1] + (g[1][1] if len(g) > 1 and g[1][0].lower() in 'ιυ' else '')
    return not ({_SMOOTH, _ROUGH} & set(marks))


# Elements that label the form after them (dialect, case, number …).
_LABEL_TAGS = {'gramGrp', 'gram', 'case', 'number', 'tns', 'mood', 'per', 'lbl', 'usg', 'itype', 'pos'}
# Text that makes the <orth> after it a reference to another word, not a
# spelling ('v. sub ἄγω' in ἄξεινος, 'cf. X').
_XREF_BEFORE = re.compile(r'(?:\bv\.|\bcf\.|\bq\.\s?v\.|\bs\.\s?v\.|\bsub)\s*$')


def _labelled(before: str, prev_el, labelled: set) -> bool:
    """Whether a grammatical label introduces an <orth>: 'Dor. Ζάν', 'comp.
    major', '= X', a label element right before it, or a list that continues
    a labelled form ('Dor. Ζάν, Δάν, Τάν')."""
    if _XREF_BEFORE.search(before):
        return False
    return (re.search(r'[A-Za-z]{2,}\.\s*$|=\s*$', before) is not None or
            (prev_el is not None and not before.strip() and prev_el.tag in _LABEL_TAGS) or
            (prev_el in labelled and before.strip() in ('', ',', 'and', 'or')))

# Forms of the article that upstream tags as <orth> inside other entries
# ('abs., <orth>to\\</orth> -qrhnei=n' in ἐπιθρηνέω): not spellings.
_ARTICLE_FORMS = {'τό', 'τά', 'τώ', 'τοῦ', 'τῆς', 'τῷ', 'τῇ', 'τόν', 'τήν', 'τῶν',
                  'τοῖς', 'ταῖς', 'τούς', 'τάς', 'τοῖν', 'ταῖν'}


def _has_accent(word: str) -> bool:
    return bool(_ACCENTS & set(unicodedata.normalize('NFD', word)))


_GREEK_WORD = re.compile("[\u0370-\u03ff\u1f00-\u1fff\u0300-\u036f']+")


def greek_form_key(printed: str) -> str:
    """Lookup form of a printed Greek spelling: no quantity marks or hyphens,
    grave → acute ('ἀγᾰθός' → 'ἀγαθός', 'κενοδρομ-ία' → 'κενοδρομία')."""
    d = unicodedata.normalize('NFD', printed)
    d = ''.join(c for c in d if c not in (_BREVE, _MACRON))
    d = re.sub(r'[\s\-\u2010]+', '', d).strip(_PUNCT_EDGE + "'")
    return acute_for_grave(d)


# LSJ keys whose 'v' is an upstream typo for ν (the orth has it too).
_LSJ_KEY_FIXES = {
    'διοικοϝομέω': 'διοικονομέω',
    'προαναλαμβάϝω': 'προαναλαμβάνω',
    'προοικοϝομία': 'προοικονομία',
    'ἱερομηϝία': 'ἱερομηνία',
    'ἀποκρημϝιζω': 'ἀποκρημνίζω',
}
# Upstream keys cut short at a '<*>' gap or a stray '.', or mistyped, where
# the article makes the word certain (θρῖναξ 'trident', ἐπαλκής 'strong',
# ἀμαράκινος 'of marjoram', πλουμάκιον 'embroidery', ἐμπλατύνω, λαβή
# 'handle'). Keyed by the raw upstream key.
_LSJ_RAW_KEY_FIXES = {
    'qr': 'θρῖναξ',
    'e)palk': 'ἐπαλκής',
    'a)mara/kin': 'ἀμαράκινος',
    'ploum': 'πλουμάκιον',
    'e)mpla\\': 'ἐμπλατύνω',
    'labh(': 'λαβή',                    # 'la^b-h(': '(' for the acute
}


def latin_lookup_key(key: str) -> str:
    # Keys are plain ASCII (no macrons/breves); a stray accent slash appears twice.
    key = _clean_key(key).replace('/', '').strip()
    return key.rstrip('!?').strip()


# Upstream L&S keys that are not words.
_LS_KEY_FIXES = {
    'cardu .s': ('carduus', ['cardus']),
    'bissenus and bisseni': ('bissenus', ['bisseni']),
    'Regium (Rheg': ('Regium', ['Rhegium']),
}


def display_form(printed: str) -> str:
    """The printed headword without the source's trailing punctuation (and
    with y-breve for the Cyrillic ў that L&S uses for it)."""
    text = printed.translate(_CYRILLIC_Y).replace('^', '\u0306').replace('_', '\u0304')
    text = text.strip().rstrip(',:;.').strip()
    # LSJ phrase headwords write the space as '.' ('kai\\.ga/r' καὶ γάρ) and
    # the words left out as dots ('kai\\...ge' καὶ . . . γε).
    text = _DOTTED_PHRASE.sub(lambda m: ' ' if len(m.group()) == 1 else
                              ' ' + ' '.join(m.group()) + ' ', text)
    return unicodedata.normalize('NFC', text)


_DOTTED_PHRASE = re.compile('(?<=[\u0370-\u03ff\u1f00-\u1fff\u0300-\u036f])\\.+(?=[\u0370-\u03ff\u1f00-\u1fff])')


def _align(part: str, hw: str, at: int) -> int:
    """Index in hw of the letter `part` stands for: the occurrence of that
    letter closest to `at` (-1 when hw does not have it)."""
    letter = part.lower()
    hits = [i for i, c in enumerate(hw.lower()) if c == letter]
    return min(hits, key=lambda i: (abs(i - at), i)) if hits else -1


def _infix_form(mid: str, hw: str) -> str:
    """'-temt-' for contemptus → contemtus: replace the stretch of the
    headword that runs from mid's first to its last letter and looks most
    like it."""
    best, best_ratio = '', 0.0
    low = hw.lower()
    for a in (i for i, c in enumerate(low) if c == mid[0].lower()):
        for b in range(a + len(mid) - 3, a + len(mid) + 2):
            if a < 1 or b < a or b >= len(hw) - 1 or low[b] != mid[-1].lower():
                continue
            ratio = difflib.SequenceMatcher(None, low[a:b + 1], mid.lower()).ratio()
            if ratio > best_ratio:
                best, best_ratio = hw[:a] + mid + hw[b + 1:], ratio
    return best if best_ratio >= 0.6 else ''


# English labels that upstream tags as alternate spellings.
_LATIN_ALT_STOP = {'rare'}


def _latin_alt_form(alt: str, headword_plain: str) -> str:
    """Expand an L&S alternate spelling into a full word, or ''.

    Full words pass through. A prefix form replaces the start of the
    headword up to its last letter ('inm-' for immisericors → inmisericors,
    'Rhēg-' for Rēgium → Rhegium, 'adc.' for accumbo → adcumbo); a suffix
    form replaces the end from its first letter ('-ējus' for plēbēĭus →
    plebejus); an infix replaces the matching stretch ('-temt-' for
    contemptus → contemtus). Labels ('trisyl.', 'class.') are dropped.
    """
    raw = alt.strip().rstrip(',;:').strip()
    if raw.endswith('.'):
        # 'adc.' abbreviates a prefix; anything longer is a label.
        if len(raw) > 5 or '-' in raw:
            return ''
        raw = raw[:-1] + '-'
    if '.' in raw or ' ' in raw:
        return ''                               # notes, phrases
    alt = latin_plain(raw).strip().strip(',;:.()').strip()
    if alt == raw and alt.lower() in _LATIN_ALT_STOP:
        return ''
    hw = headword_plain
    if alt.endswith('-') and alt.startswith('-'):
        mid = alt.strip('-')
        if len(mid) < 2 or not mid.isalpha():
            return ''
        word = _infix_form(mid, hw)
    elif alt.endswith('-'):
        stem = alt[:-1].replace('-', '')
        if len(stem) < 2 or not stem.isalpha() or len(stem) >= len(hw):
            return ''
        p = _align(stem[-1], hw, len(stem) - 1)
        if p < 0 or abs(p - (len(stem) - 1)) > 2:
            return ''
        word = stem + hw[p + 1:]
    elif alt.startswith('-'):
        tail = alt[1:].replace('-', '')
        if len(tail) < 2 or not tail.isalpha() or len(tail) >= len(hw):
            return ''
        p = _align(tail[0], hw, len(hw) - len(tail))
        if p < 1 or abs(p - (len(hw) - len(tail))) > 2:
            return ''
        word = hw[:p] + tail
    else:
        word = alt.replace('-', '')
    if word.lower() == hw.lower():
        return ''
    return word if len(word) >= 3 and re.fullmatch(r"[A-Za-z]+", word) else ''


# LSJ writes a variant spelling as the ending that replaces the end of the
# headword ('κατ-ᾰράσσω, Att. -ττω'; 'πατρι-ώτης, Dor. -ώτας'). Perseus tags
# it <orth extent="suff"> and expands it by gluing a stem in front, often the
# wrong one ('κάτ-ττω', 'πάτρι-τας', and under ἀπατάω the previous entry's
# 'ἀπασχολ-έω'). Only the ending is trusted: it is aligned with the end of
# the headword again.
_GVOWELS = set('αεηιουω')
_GREEK_LETTERS = set('αβγδεζηθικλμνξοπρστυφχψωϝ')


def _graphemes(word: str) -> list[list[str]]:
    """[[base letter, marks], …] of a word; marks belong to the letter before."""
    out: list[list[str]] = []
    for c in unicodedata.normalize('NFD', word):
        if unicodedata.combining(c):
            if out:
                out[-1][1] += c
        else:
            out.append([c, ''])
    return out


def _gbase(letters) -> str:
    return ''.join(('σ' if g[0] in 'ςσΣ' else g[0].lower()) for g in letters)


def _gjoin(letters) -> str:
    return unicodedata.normalize('NFC', ''.join(g[0] + g[1] for g in letters))


def _no_accent(letters):
    return [[g[0], ''.join(c for c in g[1] if c not in _ACCENTS)] for g in letters]


def greek_suffix_form(alt: str, headword: str) -> str:
    """The whole word an LSJ ending stands for, or '' when it cannot be placed.

    alt is Perseus' expansion 'stem-ending', headword the printed headword.
    LSJ joins an ending either at the headword's hyphen ('ἀβλαβ-ής … -ία',
    'χορᾱγ-εῖον … -ός') or where its first letter lines up with the end of
    the headword ('πατρι-ώτης, Dor. -ώτας', '-ττω' for -σσω, '-ττω' for -ζω,
    '-βῶς' for -βής). Tried in order, the first that gives a new word wins:
    a one-vowel ending for the last vowel (Dor. -ά for -ή); a vowel ending at
    the hyphen when Perseus' stem is the headword's; the same first letter at
    the same distance from the end, then up to two letters off; a changed
    first vowel when the rest of the ending matches (Ion. -έω for -άω); and
    last, any ending at the hyphen after the headword's own stem.
    """
    alt = alt.replace('\u2010', '-')
    if alt.count('-') != 1:
        return ''
    stem, tail = (_graphemes(x) for x in alt.split('-'))
    hw = _graphemes(headword.replace('\u2010', '-'))
    hyphen = next((i for i, g in enumerate(hw) if g[0] == '-'), -1)
    hw = [g for g in hw if g[0] not in '- ']
    hb, tb, sb = _gbase(hw), _gbase(tail), _gbase(stem)
    if not tb or len(hb) < 2 or not all(c in _GREEK_LETTERS for c in hb + tb):
        return ''
    n = len(hb)
    own_stem = hyphen > 0 and sb == hb[:hyphen]

    def at(d):                          # where the ending starts, d letters off
        q = n - len(tb) - d
        return q if 1 <= q < n else -1

    def tries():
        if len(tb) == 1:
            if tb in _GVOWELS and hb[-1] in _GVOWELS:
                yield n - 1
        if own_stem and tb[0] in _GVOWELS and hb[hyphen] in _GVOWELS:
            yield hyphen
        if len(tb) >= 2:
            q = at(0)
            if q > 0 and (hb[q] == tb[0] or (tb[:2], hb[q:q + 2]) in (('ττ', 'σσ'), ('ρρ', 'ρσ'))):
                yield q
            q1 = at(-1)
            if tb[:2] == 'ττ' and q1 > 0 and hb[q1] == 'ζ':
                yield q1                    # Att. ἁρμόττω for ἁρμόζω
            near = sorted((abs(d), -difflib.SequenceMatcher(None, hb[at(d):], tb).ratio(), at(d))
                          for d in (1, -1, 2, -2) if at(d) > 0 and hb[at(d)] == tb[0])
            yield from (x[2] for x in near)
            if q > 0 and hb[q] in _GVOWELS and tb[0] in _GVOWELS and \
                    difflib.SequenceMatcher(None, hb[q + 1:], tb[1:]).ratio() >= 0.5:
                yield q
        if own_stem:
            yield hyphen

    whole = _gjoin(hw)
    for p in tries():
        # Perseus' stem carries the variant's accent when it is the right stem.
        front = stem if sb == hb[:p] else hw[:p]
        if any(set(g[1]) & _ACCENTS for g in tail):
            front = _no_accent(front)
        word = _gjoin(front + tail)
        if word != whole and (_has_accent(word) or not _has_accent(whole)):
            return word
    return ''


# ── TEI parser ─────────────────────────────────────────────────

def _segments(entry):
    """Split an entryFree into entries. L&S occasionally appends a further
    headword after the senses ('… </sense> †† <orth>optostrōtum</orth> …');
    that orth starts an entry of its own."""
    segs = [[]]
    seen_sense = False
    for child in entry:
        if child.tag == 'orth' and seen_sense:
            segs.append([])
            seen_sense = False
        segs[-1].append(child)
        if child.tag == 'sense':
            seen_sense = True
    return segs


def parse_perseus_xml(filepath: Path, is_greek: bool, stats: dict):
    """Parse a Perseus TEI P4 XML dictionary file.

    Yields dicts: key, hom, headword, pos, intro, senses, alts (alternate
    spellings in lookup form), printed_plain (L&S: printed form with macrons).
    """
    r = Renderer(lsj=is_greek)
    print(f"  Parsing {filepath.name}...")
    count = 0

    for _event, elem in ET.iterparse(str(filepath), events=('end',)):
        if elem.tag != 'entryFree':
            continue
        raw_key = elem.get('key', '')
        before = count
        for seg_no, seg in enumerate(_segments(elem)):
            entry = _parse_segment(r, elem, seg, raw_key if seg_no == 0 else '',
                                   first=(seg_no == 0), is_greek=is_greek, stats=stats)
            if entry:
                count += 1
                yield entry
        if count // 20000 != before // 20000:
            print(f"    {count} entries processed...")
        elem.clear()

    print(f"    Total: {count} entries")


def _parse_segment(r: Renderer, elem, seg: list, raw_key: str, first: bool,
                   is_greek: bool, stats: dict):
    r.parens = 0
    orth_el = next((c for c in seg if c.tag == 'orth'), None)
    orth_text = _text_of(orth_el).strip() if orth_el is not None else ''

    # Lookup key from `key`; printed form from <orth> (see "Headwords").
    alts: list[str] = []
    suffix_alts: list[str] = []         # LSJ endings ('Att. -ττω'), see greek_suffix_form
    compound = False
    repaired = False            # key rebuilt from the orth: its number is not a homograph's
    if is_greek:
        printed = beta_to_unicode(orth_text) if orth_text else ''
        key = greek_lookup_key(raw_key) if raw_key else ''
        if key in _LSJ_KEY_FIXES:               # the printed form has the typo too
            key = _LSJ_KEY_FIXES[key]
            printed = printed.replace('ϝ', 'ν')
        if raw_key in _LSJ_RAW_KEY_FIXES:
            key = printed = _LSJ_RAW_KEY_FIXES[raw_key]   # not 'θρ…ναξ'
            repaired = True
        elif '<*>' in orth_text and printed:
            whole = greek_form_key(printed)
            if whole.startswith(key) and '…' not in whole and whole != key:
                stats.setdefault('gap_keys', []).append((key, whole))
                if len(key) == 1:
                    # A key cut to one letter at the gap: there letters are
                    # lost ('c<*>nodoth/r', '-k<*>mos'), not a mark. The key
                    # stays the joined form (the letter itself must find the
                    # letter's article first); the headword shows the gap.
                    printed = '…'.join(beta_to_unicode(p) for p in orth_text.split('<*>'))
                key = whole                     # 'ἡδονοκ' → 'ἡδονοκρασία'
                repaired = True
        if not key and printed:
            key = greek_form_key(printed)
    else:
        printed = orth_text
        if raw_key in _LS_KEY_FIXES:
            key, extra = _LS_KEY_FIXES[raw_key]
            alts.extend(extra)
            if raw_key == 'cardu .s':
                printed = 'carduus'
        else:
            key = latin_lookup_key(raw_key) if raw_key else ''
        plain = latin_plain(printed).replace("^", "").replace("_", "")
        # 'rĕ -sisto' / 'ĭn-aequālis' under key="re3" / "in5": the word is
        # the joined orth.
        m = re.fullmatch(r"([A-Za-z]+) ?-([A-Za-z]+)", plain.strip())
        if m and key.lower() == m.group(1).lower():
            stats.setdefault('compound_keys', []).append((raw_key, m.group(1) + m.group(2)))
            key = m.group(1) + m.group(2)
            compound = True             # its number counts the 'in' homographs
        if not key:
            key = re.sub(r"[^A-Za-z']", '', plain)
    if not key:
        return None
    headword = display_form(printed) or key

    # Upstream numbers homographs in the key ('le/gw1', 'le/gw2'); whether a
    # number is shown is decided per article (assign_hom_labels).
    hom = homograph_number(raw_key) if first and not (compound or repaired) else 0

    # Badge: the first entry-level <pos>. Everything else before the first
    # sense (inflection, dialect forms, etymology, "v. X") is the intro.
    pos_el = next((c for c in seg if c.tag == 'pos'), None)
    pos = re.sub(r'\s+', ' ', _text_of(pos_el)).strip() if pos_el is not None else ''

    skip = {orth_el, pos_el}
    intro_parts, senses = [], []
    lead_text = elem.text if first else ''
    intro_parts.append(r.text(lead_text, False, True))
    prev_text = lead_text or ''
    # An <orth> that no grammatical label introduces ('nom.', 'Ep.', 'Dor.',
    # 'comp.') may be another word cited in the entry: 'v. sub ἄγω' in
    # ἄξεινος, 'commūnĭcārius (dies)', 'Stellātis ăger or campus', in the
    # senses 'κατὰ ξυστάσεις' under σύστασις: marked 'bare' (indexes into alts).
    bare: set[int] = set()
    labelled_orths: set = set()
    prev_el = None
    for child in seg:
        before_el, prev_el = prev_el, child
        if child.tag == 'orth' and child is not orth_el and \
                not (is_greek and child.get('extent', 'full') != 'full'):
            if _labelled(prev_text, before_el, labelled_orths):
                labelled_orths.add(child)
            else:
                bare.add(len(alts))
        if child.tag == 'sense':
            body = _clean_body(r.children(child, False, True))
            senses.append({'num': child.get('n', ''), 'level': child.get('level', ''),
                           'html': body})
            tail = r.text(child.tail, False, True)
            if senses and _has_words(tail):      # text between senses
                senses[-1]['html'] = _clean_body(senses[-1]['html'] + ' ' + tail)
                stats['between_sense_text'] = stats.get('between_sense_text', 0) + 1
            prev_text = child.tail or ''
            continue
        part = '' if child in skip else r.element(child, False, True, prev_text)
        part += r.text(child.tail, False, True)
        if senses:                              # after the first sense
            if _has_words(part):
                senses[-1]['html'] = _clean_body(senses[-1]['html'] + ' ' + part)
                stats['between_sense_text'] = stats.get('between_sense_text', 0) + 1
        else:
            intro_parts.append(part)
        prev_text = child.tail or ''
        # Alternate spellings → redirect keys
        if child.tag == 'orth' and child is not orth_el:
            if is_greek and child.get('extent', 'full') != 'full':
                suffix_alts.append(_text_of(child))
            else:
                alts.append(_text_of(child))

    intro = _clean_body(''.join(intro_parts))
    senses = [s for s in senses if s['html']]
    if senses and intro:
        # 'εἶμι (<sense>ibo), …', 'ἡ, = <sense>…': a bracket or '=' that
        # opens just before the first sense belongs to it.
        m = re.search(r'([(\[=][(\[=\s]*)$', intro)
        # (not 'denoting (<sense n="1">) sharp': there the bracket holds the number)
        if m and not _strip_tags(senses[0]['html']).lstrip().startswith(')'):
            moved = m.group(1).strip()
            senses[0]['html'] = moved + ' ' * moved.endswith('=') + senses[0]['html']
            intro = _clean_body(intro[:m.start()])
    # A single letter is still content: the gender (ὁ, ἡ), a quantity note
    # ([ῡ]), an L&S ending ('Agonalis, e'). Only punctuation is dropped.
    if not _has_words(intro):
        intro = ''
    if not senses and not intro:
        # Upstream lost the text ('χηρ-δύπτης).'); keep the headword so the
        # word is still found.
        stats['headword_only'] = stats.get('headword_only', 0) + 1

    # Sub-lemma spellings inside the senses (adverbs, participles, variants);
    # unlabelled ones ('τί πρακτέον', 'Arnŏbĭus (junior)') are marked 'bare'.
    for s_el in (c for c in seg if c.tag == 'sense'):
        prev_of = {}
        for parent in s_el.iter():
            before, prev_el = parent.text or '', None
            for c in parent:
                prev_of[c] = (before, prev_el)
                before, prev_el = c.tail or '', c
        labelled_orths = set()
        for o in s_el.iter('orth'):
            before, prev_el = prev_of.get(o, ('', None))
            labelled = _labelled(before, prev_el, labelled_orths)
            if labelled:
                labelled_orths.add(o)
            if is_greek and o.get('extent', 'full') != 'full':
                continue
            if not labelled:
                bare.add(len(alts))
            alts.append(_text_of(o))

    if is_greek:
        alt_keys, bare_keys = [], set()
        forms = []                              # (form, bare)
        for i, a in enumerate(alts):
            if '<*>' in a:
                continue
            form = beta_to_unicode(a.strip()).strip().strip(',.;:·')
            if form.startswith('-') or form.endswith('-'):
                continue                        # 'Ion. μουνο-': a fragment
            forms.append((form, i in bare))
        for a in suffix_alts:
            if '<*>' not in a and printed:
                word = greek_suffix_form(beta_to_unicode(a.strip()).strip().strip(',.;:·'), printed)
                if word:
                    forms.append((word, False))
                    stats['suffix_alts'] = stats.get('suffix_alts', 0) + 1
                else:
                    stats['suffix_alts_dropped'] = stats.get('suffix_alts_dropped', 0) + 1
        for form, is_bare in forms:
            # Editorial brackets mark supplied or lost letters: 'κεσκι<ον>'.
            k = greek_form_key(re.sub(r'[\[\]<>{}()]', '', form))
            # An unaccented form beside an accented headword is an ending or
            # a stem cited in the article ('εως', 'κατ', 'μουνο'), not a word.
            if (k and k != key and sum(c.isalpha() for c in k) >= 2
                    and _GREEK_WORD.fullmatch(k)
                    and (_has_accent(k) or not _has_accent(key))
                    and k not in _ARTICLE_FORMS and not _breathless(k)):
                alt_keys.append(k)
                if is_bare:
                    bare_keys.add(k)
        # a form that is also given with a label elsewhere in the entry is not bare
        bare_keys -= {greek_form_key(re.sub(r'[\[\]<>{}()]', '', f)) for f, b in forms if not b}
    else:
        hw_plain = latin_plain(printed).replace(' -', '').replace('-', '').replace('^', '').replace('_', '')
        alt_keys, bare_keys, labelled_keys = [], set(), set()
        for i, a in enumerate(alts):
            k = _latin_alt_form(a, hw_plain)
            if k and k != key:
                alt_keys.append(k)
                (bare_keys if i in bare else labelled_keys).add(k)
        bare_keys -= labelled_keys

    return {
        'key': key, 'hom': hom, 'headword': headword,
        'series': re.sub(r'\d+$', '', raw_key.strip()),     # upstream key without its number
        'pos': pos, 'intro': intro, 'senses': senses,
        'alts': list(dict.fromkeys(alt_keys)),
        'bare_alts': bare_keys,          # alts with no label before them (see 'bare')
        # Spelling as printed (quantity marks stripped), for macron redirects
        'printed_plain': '' if is_greek else unicodedata.normalize('NFC', ''.join(
            c for c in unicodedata.normalize('NFD', printed.replace('ў', 'y').replace('Ў', 'Y'))
            if c != '\u0306')).replace('^', ''),
    }


# ── Sense tree builder ────────────────────────────────────────

def _build_sense_tree(senses: list[dict]) -> list[dict]:
    """Convert flat list of senses (with 'level' attr) into a nested tree.

    Each node: {'sense': dict, 'children': [node, ...]}
    The hierarchy is reconstructed from the 'level' attribute:
    a sense with level N is a child of the most recent sense with level < N.
    """
    root_children: list[dict] = []
    stack: list[tuple[list, int]] = [(root_children, 0)]

    for s in senses:
        level = int(s.get('level') or '1')
        node = {'sense': s, 'children': []}
        while len(stack) > 1 and stack[-1][1] >= level:
            stack.pop()
        stack[-1][0].append(node)
        stack.append((node['children'], level))

    return root_children


def _render_sense_tree(nodes: list[dict]) -> str:
    """Recursively render sense tree nodes to nested HTML cards (untruncated)."""
    parts = []
    for node in nodes:
        sense = node['sense']
        card_parts = []
        if sense['num']:
            card_parts.append(
                f'<div class="sn-hd"><span class="sn-num">'
                f'{esc(sense["num"])}</span></div>'
            )
        if sense.get('html'):
            card_parts.append(f'<span class="df">{sense["html"]}</span>')
        if node['children']:
            card_parts.append(_render_sense_tree(node['children']))
        if card_parts:
            parts.append(f'<div class="sn">{"".join(card_parts)}</div>')
    return ''.join(parts)


# ── HTML builder ───────────────────────────────────────────────

def _hom_label(n: int, is_greek: bool) -> str:
    """LSJ prints homographs as λέγω (A), (B) …; L&S numbers them 1, 2 …"""
    if not n:
        return ''
    label = f'({chr(ord("A") + n - 1)})' if is_greek and n <= 26 else str(n)
    return f'<span class="hn">{label}</span>'


def _same_word(e: dict, is_greek: bool) -> bool:
    """The block's headword is the article's word itself, not a phrase filed
    under it ('καὶ γάρ', 'μὴ ἀλλά' are numbered in the καί / μή series)."""
    if is_greek:
        form = greek_form_key(e['headword'])
    else:
        form = latin_plain(e['headword']).replace(' ', '').replace('-', '').rstrip('!?')
    return form.lower() == e['key'].lower()


def assign_hom_labels(entries: dict, is_greek: bool) -> int:
    """Show upstream homograph numbers only where they tell homographs apart:
    two or more numbered blocks of the same word under keys that differ at
    most in case or (Greek) accents, which a reader sees together (λέγω (A),
    (B); ὁμῶς (A), ὅμως (B); ἦ (A), ἦ (B); A 1, a 2, ā 3). Upstream also
    numbers the phrases filed under a word ('kai/1' καί, 'kai/2' καί νυ, …,
    'kai\\1' καὶ γάρ): when a key's series has one block of the word itself
    and otherwise phrases, its number only counts phrases and is hidden."""
    groups = defaultdict(list)
    for key, readings in entries.items():
        groups[(unaccented(key) if is_greek else key).lower()].extend(readings)

    def series_of(e):                   # 'kai/' and 'kai\\' are one series
        return e['series'].lower().replace('\\', '/')

    shown = 0
    for readings in groups.values():
        series = defaultdict(lambda: [0, 0])            # [blocks of the word, phrases]
        for e in readings:
            if e['hom']:
                series[series_of(e)][0 if _same_word(e, is_greek) else 1] += 1
        same = set()
        for e in readings:
            if e['hom'] and _same_word(e, is_greek):
                words, phrases = series[series_of(e)]
                if words >= 2 or not phrases:
                    same.add(id(e))
        for e in readings:
            e['label'] = e['hom'] if len(same) >= 2 and id(e) in same else 0
            shown += bool(e['label'])
    return shown


# Endings printed between an LSJ headword and its letter ('ον', 'α, ον').
_GREEK_ENDINGS = '(?:[\u0370-\u03ff\u1f00-\u1fff\u0300-\u036f]+,\\s*)*[\u0370-\u03ff\u1f00-\u1fff\u0300-\u036f]+'


def build_html(e: dict, dir_label: str, is_greek: bool, first: bool = True) -> str:
    """Build HTML for one upstream entry. Homographs that share a lookup key
    are rendered as consecutive blocks; only the first carries the CSS and
    the direction label."""
    parts = [f'<span class="dir">{dir_label}</span>'] if first else []
    label = e.get('label', 0)
    parts.append(f'<span class="hw">{esc(e["headword"])}{_hom_label(label, is_greek)}</span>')
    if e['pos']:
        parts.append(f'<span class="pos">{esc(e["pos"])}</span>')
    intro = e['intro']
    if label and is_greek and label <= 26:
        # The source repeats LSJ's '(A)' after the headword, or after what
        # stands between ('*λέγω (A)', 'πάλη [ᾰ] (A), ἡ', 'ἀγαῖος, α, ον (B)',
        # 'ἤ (or ἦ) (C)'): shown as the label.
        letter = chr(ord('A') + label - 1)
        intro = re.sub(r'^((?:\*|\[[^\]<]*\]|\(or [^()]*\)|' + _GREEK_ENDINGS + r')\s*)?\(' + letter +
                       r'\)\s*[,;:]?\s*', lambda m: m.group(1) or '', intro, count=1).strip()
    if e['senses']:
        if intro:
            parts.append(f'<div class="inf">{intro}</div>')
        parts.append(_render_sense_tree(_build_sense_tree(e['senses'])))
    elif intro:
        # No senses: the entry-level text is the definition.
        parts.append(f'<div class="sn"><span class="df">{intro}</span></div>')
    body = f'<div class="e">{"".join(parts)}</div>'
    return f'{CSS}{body}' if first else body


def build_article(readings: list, dir_label: str, is_greek: bool) -> str:
    """One article per lookup key: each upstream entry as its own block."""
    return ''.join(build_html(e, dir_label, is_greek, first=(i == 0))
                   for i, e in enumerate(readings))


# ── Redirects ──────────────────────────────────────────────────

def _folded(word: str, is_greek: bool) -> str:
    """What a reader types without any marks: γυνή → γυνη, jūnior → iunior."""
    if is_greek:
        return unaccented(word).lower().replace('ς', 'σ')
    return latin_plain(word).lower().replace('j', 'i').replace('v', 'u')


def _closeness(form: str, source: str, is_greek: bool) -> int:
    """How far a redirect form is from the spelling it was made from:
    0 the same (up to case, and grave for acute), 1 monotonic / without
    macrons, 2 without any marks (Latin: i/u for j/v), 3 not even that."""
    form, source = form.lower(), source.lower()
    if is_greek:
        steps = (acute_for_grave, monotonic, lambda w: _folded(w, True))
    else:
        steps = (latin_plain, lambda w: _folded(w, False))
    for i, fold in enumerate(steps):
        if fold(form) == fold(source):
            return i
    return len(steps)


# How a redirect relates to its target (the first sort key of a form's targets).
_OWN, _LABELLED, _CITED = 0, 1, 2
# Text before a word that the article refers to ('v. beo', 'Part. of vello',
# 'comp., from parvus', 'v. 2. pando').
_REFERS_CUE = r'(?:\bv\.|\bcf\.|\bof|\bfrom|\bfor|\bunder|\bsee|=)\s*(?:\d\.\s*)?'


def build_redirects(entries: dict, is_greek: bool, sizes: dict, articles: dict) -> dict:
    """{redirect key: [target article keys]} for spellings that are not keys.

    When one spelling leads to several articles, the word whose own key it
    is comes first (γυνη → γυνή, iunior → junior, άας → ἄας), then words that
    list it as a labelled form (Dor. ἀάς under ἠώς, comp. major under
    magnus), then words that only cite it; closer spellings and then larger
    articles break ties.
    """
    ranks: dict[str, dict[str, tuple]] = defaultdict(dict)    # form → {target: rank}

    def add(form: str, target: str, kind: int, source: str):
        # A form that is itself a headword still gets the redirect: the app
        # shows every record of a key, the form's own article first.
        form = unicodedata.normalize('NFC', form.strip())
        if not form or form == target:
            return
        rank = (kind, _closeness(form, source, is_greek))
        if rank < ranks[form].get(target, (9, 9)):
            ranks[form][target] = rank

    by_lower = defaultdict(set)
    for key in entries:
        by_lower[key.lower() if is_greek else _folded(key, False)].add(key)

    def refers_to(html: str, key: str) -> bool:
        if f'href="entry://{esc_attr(key)}"' in html:
            return True
        if is_greek:
            return False
        # L&S does not mark up 'P. a., from erigo', 'v. beo', 'old form for ille'.
        text = latin_plain(re.sub(r'<[^>]+>', ' ', re.sub(r'<style.*?</style>', '', html, flags=re.S)))
        return re.search(_REFERS_CUE + re.escape(latin_plain(key)) + r'(?!\w)', text) is not None

    def cited_word(a: str, key: str) -> bool:
        """An unlabelled <orth> that is another article's word and not a
        spelling of this one: κατά quoted under σύστασις ('κατὰ ξυστάσεις'),
        γυνή under φίλιος, 'v. sub ἄγω' in ἄξεινος, 'commūnĭcārius (dies)',
        'Arnŏbĭus (junior)'. Kept when that article refers back to this one
        (θάσσων 'comp. of ταχύς', Cret. Τάν 'for Ζεύς', ērectus 'P. a., from
        erigo')."""
        others = by_lower.get(a.lower() if is_greek else _folded(a, False), set()) - {key}
        if not others:
            return False
        fa, fk = _folded(a, is_greek), _folded(key, is_greek)
        if difflib.SequenceMatcher(None, fa, fk).ratio() >= 0.5:
            return False                # ὀλώϊος under ὀλοός, aput under apud
        if len(set(fk)) == 1 and fa.startswith(fk[:1]):
            return False                # a letter's name: δέλτα under δ, κάππα under Κκ
        return not any(refers_to(articles.get(o, ''), key) for o in others)

    n_cited = 0
    if is_greek and 'ὁ' in entries:
        # LSJ files the whole article under ὁ ('ὁ, ἡ, τό'); readers look up
        # the form in front of them (ἡ, τό, τὸν, τῆς …).
        # A headword spelt the same comes first (αι → αἰ 'if', then ὁ).
        for form in ('ἡ', 'οἱ', 'αἱ', *sorted(_ARTICLE_FORMS)):
            for v in (form, *greek_variants(form)):
                add(v, 'ὁ', _LABELLED, form)
    if is_greek and 'τις' in entries:
        # The interrogative τίς, τί is treated in the article τις (upstream
        # key 'tis'), which only the indefinite's spelling reaches.
        for form in ('τίς', 'τί'):
            for v in (form, *greek_variants(form)):
                add(v, 'τις', _OWN, form)
    for key, readings in entries.items():
        if is_greek:
            for v in greek_variants(key):
                add(v, key, _OWN, key)
            for e in readings:
                for a in e['alts']:
                    bare = a in e['bare_alts']
                    if bare and cited_word(a, key):
                        n_cited += 1
                        continue
                    for v in (a, *greek_variants(a)):
                        add(v, key, _CITED if bare else _LABELLED, a)
        else:
            for v in latin_variants(key):
                add(v, key, _OWN, key)
            if "'" in key and len(key.replace("'", '')) >= 3:
                add(key.replace("'", ''), key, _OWN, key)
            for e in readings:
                pp = e['printed_plain'].replace(' -', '').replace('-', '').strip().rstrip('!?,;:.')
                if pp != key and latin_plain(pp) in (key, *latin_variants(key)) \
                        and re.fullmatch(r"[A-Za-z\u0100-\u017f\u0232\u0233']+", pp):
                    add(pp, key, _OWN, pp)              # rēx → rex, pūblicē → publice
                    add(pp.replace('j', 'i').replace('J', 'I'), key, _OWN, pp)
                for a in e['alts']:
                    bare = a in e['bare_alts']
                    if bare and cited_word(a, key):
                        n_cited += 1
                        continue
                    for v in (a, *latin_variants(a)):
                        add(v, key, _CITED if bare else _LABELLED, a)

    print(f"  {n_cited} unlabelled <orth>s that are another article's word: not redirected")
    return {form: sorted(targets, key=lambda t: (*targets[t], -sizes.get(t, 0)))
            for form, targets in ranks.items()}


# ── App-like lookup (build-time checks) ────────────────────────

class Lookup:
    """Mimics the app: keys match ignoring case, exact case first; every
    matching record is shown and @@@LINK redirects are followed."""

    def __init__(self, entries: dict, redirects: dict):
        self.by_lower = defaultdict(list)
        for k in entries:
            self.by_lower[k.lower()].append(('article', k))
        for k, targets in redirects.items():
            for t in targets:
                self.by_lower[k.lower()].append(('link', k, t))

    def __call__(self, query: str) -> list[str]:
        q = query.replace('’', "'")
        recs = self.by_lower.get(q.lower(), [])
        recs = sorted(recs, key=lambda r: r[1] != q)
        out = []
        for r in recs:
            k = r[1] if r[0] == 'article' else r[2]
            if k not in out:
                out.append(k)
        return out


# ── Build one dictionary ──────────────────────────────────────

def build_dictionary(config: dict):
    """Build a single MDX dictionary."""
    name = config['name']
    xml_paths = config['xml'] if isinstance(config['xml'], list) else [config['xml']]
    is_greek = config['is_greek']
    dir_label = config['dir_label']
    output_dir = OUTPUT_BASE / name
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"Building {name}")
    print(f"{'='*60}")

    stats: dict = {}
    entries = defaultdict(list)  # lookup key → [entry dicts], upstream order
    upstream = 0
    for xml_path in xml_paths:
        for e in parse_perseus_xml(xml_path, is_greek, stats):
            entries[e['key']].append(e)
            upstream += 1
    entries = dict(entries)
    n_labels = assign_hom_labels(entries, is_greek)

    print(f"  {upstream} upstream entries → {len(entries)} headwords from {len(xml_paths)} file(s); "
          f"{n_labels} homograph labels")
    for k in ('gap_keys', 'compound_keys'):
        if k in stats:
            print(f"  {k}: {len(stats[k])} ({', '.join(f'{a}→{b}' for a, b in stats[k][:6])} …)")
    for k in ('between_sense_text', 'headword_only', 'suffix_alts', 'suffix_alts_dropped'):
        if k in stats:
            print(f"  {k}: {stats[k]}")

    expected = config.get('expect_initials')
    if expected:
        def initial(word: str) -> str:
            base = ''.join(ch for ch in unicodedata.normalize('NFD', word)
                           if not unicodedata.combining(ch))
            return base[:1].lower().replace('ς', 'σ')
        seen = {initial(hw) for hw in entries}
        missing = sorted(expected - seen)
        if missing:
            raise SystemExit(f"  ✗ {name}: no headwords for initial(s) {' '.join(missing)} "
                             f"— incomplete input?")
        print(f"  all {len(expected)} expected initial letters present")

    # Articles (cross-references resolved against the final key set)
    link_stats: dict = {}
    keys = set(entries)
    articles = {}
    for hw in entries:
        html = build_article(entries[hw], dir_label, is_greek)
        articles[hw] = resolve_links(html, keys, link_stats, own_key=hw)
    print(f"  cross-references: {link_stats.get('linked', 0)} linked, "
          f"{link_stats.get('unlinked', 0)} left as text (target is not a headword)")

    sizes = {k: len(v) for k, v in articles.items()}
    redirects = build_redirects(entries, is_greek, sizes, articles)
    n_redirect_records = sum(len(t) for t in redirects.values())
    print(f"  {len(redirects)} redirect keys ({n_redirect_records} @@@LINK records)")

    _check_output(name, articles, redirects, config)

    # Write MDict source
    prefix = name.lower().replace('-', '_')
    txt_path = output_dir / f"{prefix}_entries.txt"
    print(f"Writing → {txt_path}...")
    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for hw in sorted(articles):
            f.write(f"{hw}\n{articles[hw]}\n</>\n")
            count += 1
        for form in sorted(redirects):
            for target in redirects[form]:
                f.write(f"{form}\n@@@LINK={target}\n</>\n")
                count += 1
    print(f"  {count} records written ({len(articles)} articles + {n_redirect_records} redirects)")

    # Pack MDX
    mdx_path = output_dir / f"{name}.mdx"
    success, size_mb, _ = pack_mdx(txt_path, config['title'], config['desc'], mdx_path)
    if not success:
        raise SystemExit(f"  ✗ {name}: mdict packing failed")
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} records")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name=config['catalog_display_name'],
        description=config['catalog_description'],
        direction=config['catalog_direction'],
        entries=count,
        license=config['catalog_license'],
        data_source=config['catalog_data_source'],
        tier=3,
        flag=config.get('catalog_flag'),
    )

    _generate_preview(output_dir, prefix, name, articles, config['samples'])


_LEFTOVER_BETA = re.compile(r'[a-z][)(][/\\=]|[a-z][/\\=][a-z]|[a-z]=\s')
_GRK_SPAN = re.compile(r'<span class="grk">(.*?)</span>')
# Stylesheet, Greek text and link targets: not text that could be beta code.
_NOT_PLAIN = re.compile(r'<style.*?</style>|<span class="grk">.*?</span>|<a [^>]*>', re.S)


def _check_output(name: str, articles: dict, redirects: dict, config: dict):
    """Build-time guards against the regressions this script once shipped."""
    problems = []
    lookup = Lookup(articles, redirects)
    for query, expect in config['typed']:
        got = lookup(query)
        if expect not in got:
            problems.append(f"typed '{query}' does not reach '{expect}' (got {got[:4]})")
    for query, wrong in config.get('not_typed', []):
        if wrong in lookup(query):
            problems.append(f"typed '{query}' leads to the unrelated '{wrong}'")
    for query, expect in config.get('first', []):
        got = lookup(query)
        if got[:1] != [expect]:
            problems.append(f"typed '{query}' shows {got[:3]} first, not '{expect}'")
    for key, text in config.get('contains', []):
        if text not in articles.get(key, ''):
            problems.append(f"{key}: missing {text!r}")
    for key, text in config.get('lacks', []):
        if text in articles.get(key, text):
            problems.append(f"{key}: should not contain {text!r}")
    for form, targets in redirects.items():
        for t in targets:
            if t not in articles:
                problems.append(f"@@@LINK {form} → missing {t}")
    truncated = [k for k, h in articles.items() if re.search(r'…</span>(?:</div>)+$', h)]
    for k, h in articles.items():
        if '\ue000' in h or '\ue001' in h:
            problems.append(f"{k}: unresolved link placeholder")
        for m in re.finditer(r'href="entry://([^"]*)"', h):
            t = m.group(1).replace('&quot;', '"').replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>')
            if t not in articles:
                problems.append(f"{k}: entry://{t} is not a key")
        if config['is_greek'] and 'ινδεξλ' in h:
            problems.append(f"{k}: English 'indecl.' converted to Greek")
        if '<span…' in h or 'span…<' in h:
            problems.append(f"{k}: a cut inside a tag")
    # Raw beta code left in Greek text: only the handful of upstream strings
    # that mix beta with other letters ('bṇqu/s') may remain.
    beta_left = [k for k, h in articles.items()
                 if any(_LEFTOVER_BETA.search(re.sub(r'<[^>]*>|&[#\w]+;', '', g))
                        for g in _GRK_SPAN.findall(h))]
    if len(beta_left) > 50:
        problems.append(f"{len(beta_left)} articles with beta code in Greek text, e.g. {beta_left[:5]}")
    # ... and outside it (upstream <tr> without lang="greek", see tr_beta_html);
    # 'sense=perceptions' in φαντασία looks like it.
    beta_text = []
    if config['is_greek']:
        for k, h in articles.items():
            text = re.sub(r'<[^>]*>', ' ', _NOT_PLAIN.sub(' ', h)).replace('&amp;', '&')
            if any(_unmistakable_beta(m.group()) for m in _beta_words(text)):
                beta_text.append(k)
        if len(beta_text) > 3:
            problems.append(f"{len(beta_text)} articles with beta code outside Greek text, e.g. {beta_text[:5]}")
    if len(problems) > 0:
        for p in problems[:30]:
            print(f"  ✗ {p}")
        raise SystemExit(f"  ✗ {name}: {len(problems)} build check(s) failed")
    print(f"  build checks passed ({len(config['typed'])} typed lookups, "
          f"{len(truncated)} articles ending in an ellipsis, "
          f"{len(beta_left)} with beta-code leftovers, {len(beta_text)} outside Greek text)")


def _generate_preview(output_dir: Path, prefix: str, name: str, articles: dict,
                      sample_words: list):
    missing = [hw for hw in sample_words if hw not in articles]
    if missing:
        raise SystemExit(f"  ✗ {name}: sample word(s) not found as lookup keys: {', '.join(missing)}")
    preview_path = output_dir / f"{prefix}_preview.html"
    _shared_preview([articles[hw] for hw in sample_words], preview_path, f'{name} — preview')


# ── Attribution required by PerseusDL/lexica (CC BY-SA 4.0) ──────
# The lexica READMEs ask for this exact credit, the access date, an intact
# availability statement, the title/authors/publisher/ISBN of the source
# (from the TEI <sourceDesc>), and that modifications be offered back to
# Perseus. CC BY-SA 4.0 §3(a)(1)(B) also requires saying that the text was
# modified. The header description places them in the shared layout
# (shared.build.description_html): the bibliographic citation and the
# access date under Source, the availability statement and the Perseus
# credit under License, the list of modifications under Conversion.
CC_BY_SA_URL = 'https://creativecommons.org/licenses/by-sa/4.0/'
LEXICA_URL = 'https://github.com/PerseusDL/lexica/'

PERSEUS_CREDIT = (
    f'Text provided under a <a href="{CC_BY_SA_URL}">CC BY-SA</a> license '
    'by Perseus Digital Library, '
    '<a href="http://www.perseus.tufts.edu">http://www.perseus.tufts.edu</a>, '
    'with funding from The National Endowment for the Humanities.'
)

# Modifications common to both lexica, a sentence after each lexicon's own
# list of changes (no final period: description_html adds it), and the
# licence of the result.
COMMON_CHANGES_NOTE = (
    'Page and column breaks are omitted and, where the source marks a '
    'correction, the corrected reading is shown; the text is otherwise complete'
)
ADAPTATION_LICENSE = (
    f'This adaptation is licensed under <a href="{CC_BY_SA_URL}">CC BY-SA 4.0</a>.'
)


def perseus_access_html(access_date: str) -> str:
    """Where the data was taken from and when."""
    return f'Data accessed from <a href="{LEXICA_URL}">{LEXICA_URL}</a> [{access_date}].'


def header_description(*, title: str, subtitle: str, about: str, citation: str,
                       access_date: str, changes: str, availability: str = '') -> str:
    """The MDX header description of one lexicon in the shared layout.

    Args (HTML fragments):
        title, subtitle: the work's title and the name it is known by.
        about: one paragraph on the content and how to look words up.
        citation: authors, edition, publisher, year and ISBN of the source.
        access_date: when the data was taken from the lexica repository.
        changes: what this conversion changed, as a lower-case list
            without a final period.
        availability: the upstream availability statement, when the TEI
            header carries one.

    The list of changes is followed by the sentence COMMON_CHANGES_NOTE and the
    Conversion paragraph closes with ADAPTATION_LICENSE, which are the
    same for every lexicon.
    """
    license_html = f'{availability} {PERSEUS_CREDIT}' if availability else PERSEUS_CREDIT
    return description_html(
        title=title,
        subtitle=subtitle,
        about=(about,),
        source=f'{citation} {perseus_access_html(access_date)}',
        license=license_html,
        changes=f'{changes}. {COMMON_CHANGES_NOTE}',
        adaptation_license=ADAPTATION_LICENSE,
    )


# Upstream splits LSJ by initial letter into 27 parts; all of them are needed.
LSJ_PARTS = [DATA_DIR / 'lsj' / f'grc.lsj.perseus-eng{i}.xml' for i in range(1, 28)]
# Every initial letter must be represented (guards against a partial download,
# which is how the preset once shipped with only α).
GREEK_INITIALS = set('αβγδεζηθικλμνξοπρστυφχψω')


# ── Main ───────────────────────────────────────────────────────

DICTS = [
    {
        'name': 'LSJ-GRC-EN',
        'xml': LSJ_PARTS,
        'expect_initials': GREEK_INITIALS,
        'title': 'LSJ — Greek-English Lexicon',
        'desc': header_description(
            title='A Greek-English Lexicon',
            subtitle='Liddell–Scott–Jones',
            about=("Ancient Greek–English lexicon (9th edition, 1940) with full citations "
                   "and linked cross-references; type with or without accents."),
            citation=("Henry George Liddell and Robert Scott, revised and augmented "
                      "throughout by Sir Henry Stuart Jones with the assistance of Roderick "
                      "McKenzie. 9th edition. Oxford: Clarendon Press, 1940. ISBN 0198642261."),
            access_date='2026-10-17',
            changes=("built from the Perseus TEI XML; Greek converted from beta code to "
                     "Unicode; entries rendered as HTML, with cross-references linked and "
                     "homograph letters shown as labels; a few damaged headword keys "
                     "repaired; redirects added for monotonic and unaccented Greek, for the "
                     "forms of the article and for alternate spellings (variant endings "
                     "written out as whole words)"),
        ),
        'dir_label': f'{FLAG_GRC} Ἑλληνικά → English {FLAG_EN}',
        'is_greek': True,
        # Article keys rendered into the preview
        'samples': ['ἀρχή', 'βίος', 'ἐπί', 'θεός', 'λόγος', 'ὕδωρ', 'ψυχή', 'λέγω'],
        # What readers type on the iOS Greek keyboard (monotonic or without
        # accents) or copy from a text, and the headword it must reach.
        'typed': [
            ('άνθρωπος', 'ἄνθρωπος'), ('αρχή', 'ἀρχή'), ('ειμί', 'εἰμί'), ('είμι', 'εἶμι'),
            ('ειμι', 'εἰμί'), ('ειμι', 'εἶμι'),
            ('και', 'καί'), ('καὶ', 'καί'), ('γη', 'γῆ'), ('ύδωρ', 'ὕδωρ'),
            ('αγαθός', 'ἀγαθός'), ('ἀγαθὸς', 'ἀγαθός'), ('αρετή', 'ἀρετή'), ('έχω', 'ἔχω'),
            ('ήλιος', 'ἥλιος'), ('ουρανός', 'οὐρανός'), ('Όμηρος', 'Ὅμηρος'), ('έρως', 'ἔρως'),
            ('ηδονή', 'ἡδονή'), ('οίκος', 'οἶκος'), ('νους', 'νοῦς'), ('φως', 'φῶς'),
            ('πυρ', 'πῦρ'), ('ο', 'ὁ'), ('λογος', 'λόγος'), ('θεος', 'θεός'), ('ψυχη', 'ψυχή'),
            ('πραΰς', 'πραΰς'), ('πραυς', 'πραΰς'), ('βαΐα', 'βαΐα'), ('ωδή', 'ᾠδή'),
            ('μη', 'μή'), ('ου', 'οὐ'), ('λόγος', 'λόγος'), ('ζάω', 'ζάω'), ('ζω', 'ζῶ'),
            ('ἡδονοκρασία', 'ἡδονοκρασία'), ('Αθήναι', 'Ἀθῆναι'), ('ρήτωρ', 'ῥήτωρ'),
            # the article's forms; Attic -ττ- spellings that LSJ gives as endings
            ('η', 'ὁ'), ('ἡ', 'ὁ'), ('το', 'ὁ'), ('τό', 'ὁ'), ('τὸν', 'ὁ'), ('τήν', 'ὁ'), ('των', 'ὁ'),
            ('ἐλαττόω', 'ἐλασσόω'), ('καταράττω', 'καταράσσω'), ('ἀπατέω', 'ἀπατάω'),
            # the interrogative (in τις); forms whose own article refers to the word
            ('τίς', 'τις'), ('τί', 'τις'), ('θάσσων', 'ταχύς'), ('Τάν', 'Ζεύς'), ('δέλτα', 'δ'),
        ],
        # ... and the article that must come first: the word whose own key
        # it is, not one that cites it (φίλιος quotes γυνή, χῶρος πίων)
        'first': [('γυνη', 'γυνή'), ('πιων', 'πίων'), ('άας', 'ἄας'), ('αβα', 'ἄβα'),
                  ('ζα', 'ζά'), ('αι', 'αἰ'), ('ο', 'ὁ'), ('το', 'ὁ'), ('λογος', 'λόγος')],
        # Typed forms that must NOT lead to an unrelated article (Perseus
        # glued endings to the wrong stem: 'ἀπασχολ-έω' under ἀπατάω).
        'not_typed': [('ἀπολύω', 'ἀπόλλυμι'), ('ἀπασχολέω', 'ἀπατάω'), ('ἀναύω', 'ἀναρρήγνυμι'),
                      ('ἄσπλαγχνος', 'ἄσπληνον'), ('ου', 'θην'), ('ου', 'μαστιστής'),
                      ('τι', 'ἐπινοητέον'),
                      # headwords cited unlabelled in other articles
                      ('κατά', 'σύστασις'), ('μετά', 'γναμπτός'), ('ἄγω', 'ἄξεινος'),
                      ('κόλπος', 'γυναικεῖος'), ('τράχηλος', 'καλοτίθηνος'), ('γυνη', 'φίλιος')],
        # Text that must be in an article (one-letter entry text: the gender)
        'contains': [('ψυχή', '<div class="inf">ἡ</div>'), ('οἶκος', '<div class="inf">ὁ</div>'),
                     ('λέγω', '<span class="hn">(B)</span>'),
                     # beta code in upstream <tr>; a gap of lost letters shown
                     ('κίνημα', '<b><span class="grk">κινήματα</span></b>'),
                     ('σπαραγμός', 'χαίτας'), ('ξνοδοτήρ', 'ξ…νοδοτήρ')],
        # ... and text that must not: καί's numbers only count its phrases
        'lacks': [('καί', '<span class="hn">'), ('ξνοδοτήρ', '<span class="hn">'),
                  # the letter once, as the label ('*λέγω (A)', 'πάλη [ᾰ] (A)')
                  ('λέγω', '* (A)'), ('πάλη', '[ᾰ] (A)'), ('ἀγαῖος', 'ον (B)'),
                  ('κακοεξία', 'ἡ <span class="grk">,')],
        'catalog_display_name': 'LSJ Greek-English Lexicon',
        'catalog_description': ('Liddell–Scott–Jones Ancient Greek–English Lexicon '
                                '(9th ed., 1940): 116K entries with full citations and '
                                'linked cross-references; type with or without accents.'),
        'catalog_direction': {'src': 'GRC', 'dest': ['EN']},
        'catalog_license': 'CC-BY-SA-4.0',
        'catalog_data_source': 'Perseus Digital Library',
        'catalog_flag': '🏺',
    },
    {
        'name': 'Lewis-Short-LA-EN',
        # eng2 is the maintained edition (Greek already in Unicode, key and
        # entry fixes); eng1 is the archival beta-code copy.
        'xml': DATA_DIR / 'ls-eng2' / 'lat.ls.perseus-eng2.xml',
        'title': 'Lewis & Short — Latin Dictionary',
        'desc': header_description(
            title='A Latin Dictionary',
            subtitle='Lewis &amp; Short',
            about=("Latin–English dictionary (1879) with etymologies, full citations and "
                   "cross-references; finds j/i and v/u spellings."),
            citation=("Founded on Andrews' edition of Freund's Latin dictionary; revised, "
                      "enlarged, and in great part rewritten by Charlton T. Lewis and Charles "
                      "Short. Oxford: Clarendon Press, 1879. ISBN 0198642016."),
            availability=("Available under a Creative Commons Attribution-ShareAlike 4.0 "
                          "International License."),
            access_date='2026-10-20',
            changes=("built from the Perseus TEI XML (lat.ls.perseus-eng2.xml, commit "
                     "edd73d8); entries rendered as HTML, with cross-references linked; "
                     "prefix compounds such as re-sisto keyed by the whole word; redirects "
                     "added for i/u spellings of j/v words, for macronized and for "
                     "alternate spellings"),
        ),
        'dir_label': f'{FLAG_LA} Latina → English {FLAG_EN}',
        'is_greek': False,
        'samples': ['amo', 'aqua', 'bellum', 'deus', 'rex', 'vir', 'volo', 'cum', 'publice'],
        'typed': [
            ('ius', 'jus'), ('iustitia', 'justitia'), ('iam', 'jam'), ('Iuppiter', 'Juppiter'),
            ('iudex', 'judex'), ('iuvenis', 'juvenis'), ('maior', 'major'), ('eius', 'ejus'),
            ('cuius', 'cujus'), ('uita', 'vita'), ('uideo', 'video'), ('pūblicē', 'publice'),
            ('rēgīna', 'regina'), ('resisto', 'resisto'), ('inaequalis', 'inaequalis'),
            ('inexplicabilis', 'inexplicabilis'), ('superemineo', 'superemineo'), ('heu', 'heu'),
            ('heus', 'heus'), ('cum', 'cum'), ('Cum', 'cum'), ('amo', 'amo'), ('jus', 'jus'),
            ('optostrotum', 'optostrotum'), ('quom', 'quom'), ('quom', 'cum'), ('carduus', 'carduus'),
            ('bisseni', 'bissenus'), ('plebejus', 'plebeius'), ('Rhegium', 'Regium'),
            ('perastutulus', 'perastutulus'), ('interordinium', 'interordinium'),
            ('Polyphemus', 'Polyphemus'), ('viden', "viden'"), ('ha', 'ha'),
            # participles treated under their verb
            ('erectus', 'erigo'), ('actus', 'ago'), ('auctus', 'augeo'),
        ],
        'not_typed': [('dies', 'communicarius'), ('quod', 'hic'), ('vinum', 'catorchites'),
                      ('pro', 'proquaestore'), ('campus', 'Stellatis ager'),
                      ('campus', 'Fenicularius'), ('iunior', 'Arnobius')],
        'first': [('iunior', 'junior'), ('maior', 'major'), ('uinum', 'vinum')],
        'contains': [('Agonalis', '<div class="inf">e</div>'),
                     ('cum', '<span class="hn">2</span>')],
        'lacks': [],
        'catalog_display_name': 'Lewis & Short Latin Dictionary',
        'catalog_description': ('Lewis & Short Latin–English dictionary (1879): 50K entries '
                                'with etymologies, full citations and cross-references; '
                                'finds j/i and v/u spellings.'),
        'catalog_direction': {'src': 'LA', 'dest': ['EN']},
        'catalog_license': 'CC-BY-SA-4.0',
        'catalog_data_source': 'Perseus Digital Library',
    },
]


def descriptions() -> dict[str, str]:
    """{'<Name>.mdx': header description} for every dictionary this script builds.

    The strings are the ones build_dictionary() stamps into the MDX header
    (config['desc']); nothing is read or built.
    """
    return {f"{config['name']}.mdx": config['desc'] for config in DICTS}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else None)
    parser.add_argument('--only', choices=[c['name'] for c in DICTS],
                        help='build just this dictionary')
    args = parser.parse_args()
    for config in DICTS:
        if args.only and config['name'] != args.only:
            continue
        paths = config['xml'] if isinstance(config['xml'], list) else [config['xml']]
        missing = [p for p in paths if not p.exists()]
        if missing:
            print(f"Warning: {len(missing)} input file(s) missing for {config['name']} "
                  f"(first: {missing[0]}); run scripts/fetch_data.sh perseus — skipping")
            continue
        build_dictionary(config)


if __name__ == '__main__':
    main()
