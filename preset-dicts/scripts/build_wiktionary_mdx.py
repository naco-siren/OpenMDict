#!/usr/bin/env python3
"""
Build MDX dictionaries from Vuizur/Wiktionary-Dictionaries TSV data.

Supports: Korean→English, Arabic→English

Usage:
    python build_wiktionary_mdx.py          # build all
    python build_wiktionary_mdx.py ko       # Korean only
    python build_wiktionary_mdx.py ar       # Arabic only

Input:  ../data/wiktionary-{Lang}-English.tsv
        (Vuizur/Wiktionary-Dictionaries commit 296bb74c5b, 2022-11-09)
Output: ../output/Wiktionary-{XX}-EN/Wiktionary-{XX}-EN.mdx

TSV format: ``headword|form|form|...<TAB><i>pos</i><br><ol><li>…</li></ol>…``.
The form list is an unordered bag taken from Wiktextract: inflected and
vocalized forms, romanizations/transliterations, Hanja spellings, counters
and some tags. This script classifies it:

Korean
  * Hangul forms        -> ``@@@LINK`` redirects (먹었다 -> 먹다)
  * romanization        -> the candidate that is a Revised Romanization of
                           the headword (checked against an RR computed from
                           the Hangul), shown and keyed (haksaeng -> 학생)
  * Hanja               -> every Hanja spelling, each with the gloss of its
                           'Hanja form of' entry; pure 'Hanja form of X'
                           entries become redirects to X
Arabic
  * vocalized forms     -> redirects keyed by their typable spelling
                           (harakat/tatweel stripped: الكتب -> كتاب), plus
                           hamza-less (اكل -> أكل) and tanween (شكراً) spellings
  * transliterations    -> paired with the vocalized lemma they transliterate
                           (كِتَاب kitāb · كُتَّاب kuttāb)

The app matches keys ignoring case and shows every record of a key, so a
form shared by several headwords simply gets one redirect per headword.
"""

import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, GLOSS, ORDERED_LIST, TEXT_SECONDARY, TEXT_LINK
from shared.html import (esc, entry_link, dir_attr, wrap_entry, headword,
                         strip_bidi_controls)
from shared.build import (pack_mdx, generate_preview as _shared_preview, write_catalog_metadata,
                          description_html)

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output"

UPSTREAM_REPO = "https://github.com/Vuizur/Wiktionary-Dictionaries"
UPSTREAM_COMMIT = "296bb74c5bd1b51dcdfa59cd38d092edc741a50f"
UPSTREAM_DATE = "2022-11-09"

# ── Language definitions ───────────────────────────────────────

LANGUAGES = {
    'ko': {
        'code': 'ko',
        'name_en': 'Korean',
        'name_native': '한국어',
        'flag': '\U0001F1F0\U0001F1F7',  # 🇰🇷
        'tsv_file': 'wiktionary-Korean-English.tsv',
        'upstream_file': 'Korean-English Wiktionary dictionary.tsv',
        'features': 'Hanja spellings, Revised Romanization, and redirects from '
                    'inflected forms, Hanja spellings and romanized spellings',
        'changes': 'romanizations checked against the Hangul, Hanja word stubs turned into '
                   'redirects, eumhun readings shown, cross-reference links and lookup '
                   'redirects added',
        'catalog_description': (
            'Korean-English glosses from English Wiktionary (2022 snapshot) with Hanja, '
            'romanization, and lookup by inflected form, Hanja or romanized spelling.'),
    },
    'ar': {
        'code': 'ar',
        'name_en': 'Arabic',
        'name_native': 'العربية',
        'flag': '\U0001F1F8\U0001F1E6',  # 🇸🇦
        'tsv_file': 'wiktionary-Arabic-English.tsv',
        'upstream_file': 'Arabic-English Wiktionary dictionary.tsv',
        'features': 'vocalized readings with transliteration, and redirects from '
                    'inflected, definite, unvocalized and hamza-less spellings',
        'changes': 'transliterations paired with their vocalized forms, '
                   'cross-reference links and lookup redirects added',
        'catalog_description': (
            'Arabic-English glosses from English Wiktionary (2022 snapshot) with vocalized '
            'readings, transliterations, and lookup by inflected or definite form.'),
    },
}

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸

# ── POS normalization ──────────────────────────────────────────

POS_MAP = {
    'noun': 'n.', 'verb': 'v.', 'adj': 'adj.', 'adv': 'adv.',
    'prep': 'prep.', 'conj': 'conj.', 'intj': 'interj.',
    'pron': 'pron.', 'name': 'proper n.', 'suffix': 'suffix',
    'prefix': 'prefix', 'particle': 'part.', 'phrase': 'phrase',
    'det': 'det.', 'num': 'num.', 'symbol': 'sym.',
    'punct': 'punct.', 'root': 'root', 'romanization': 'rom.',
    'infix': 'infix', 'circumfix': 'circumfix', 'interfix': 'interfix',
    'proverb': 'proverb', 'character': 'char.',
    'counter': 'counter', 'classifier': 'cl.',
    'affix': 'affix', 'syllable': 'syllable', 'prep_phrase': 'prep. phrase',
    'article': 'art.',
}


# ── CSS ────────────────────────────────────────────────────────
_SEC_L, _SEC_D = TEXT_SECONDARY
_LINK_L, _LINK_D = TEXT_LINK
CSS = get_css(
    GLOSS, ORDERED_LIST,
    extra_light=(
        f'.rm{{font-size:1.15em;color:{_LINK_L};font-style:italic;display:block;margin-top:2px}}'
        f'.alt{{font-size:1.25em;color:{_SEC_L};display:block;margin-top:2px}}'
        '.alt .hg{font-size:0.62em}'
        f'.alt a{{color:{_LINK_L};text-decoration:none}}'
        '.rd{display:block;margin-top:2px;font-size:1.1em}'
        '.rd .vz{font-size:1.2em}'
        f'.rd .tl{{color:{_LINK_L};font-style:italic}}'
        f'.sp{{color:{_SEC_L}}}'
        f'.rn{{display:block;font-size:0.85em;color:{_SEC_L}}}'
        f'.gl a{{color:{_LINK_L};text-decoration:underline}}'
    ),
    extra_dark=(
        f'.rm{{color:{_LINK_D}}}'
        f'.alt,.sp,.rn{{color:{_SEC_D}}}'
        f'.alt a,.rd .tl,.gl a{{color:{_LINK_D}}}'
    ),
)


# ── Script detection ───────────────────────────────────────────

_HAN = '\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\U00020000-\U0003FFFF'
_HANJA_RE = re.compile(f'[{_HAN}]')
_PURE_HANJA_RE = re.compile(f'^[{_HAN}\u3005\u3007]+$')
_HANGUL_SYL = '\uAC00-\uD7A3'
_HANGUL_RE = re.compile(r'[\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]')
_HANGUL_WORD_RE = re.compile(f'^[{_HANGUL_SYL}]+(?: [{_HANGUL_SYL}]+)*$')
_ARABIC_RE = re.compile(r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]')
_ARABIC_LETTER_RE = re.compile(r'[\u0621-\u063A\u0641-\u064A\u0671-\u06D3\u06FA-\u06FF\u0750-\u077F]')
_LATIN_RE = re.compile(r'[A-Za-z]')


# ── Upstream gloss cleanup ─────────────────────────────────────

def clean_gloss(text: str) -> str:
    """Strip HTML and leftover wiki markup from one upstream gloss."""
    text = re.sub(r'<[^>]+>', '', text)
    # 'seven{l|en|day}} cycle' (upstream lost the '-{' of 'seven-{{l|en|day}}')
    text = re.sub(r'(?<=\w)\{+l\|[a-z-]+\|([^{}|]+)(?:\|[^{}]*)?\}+', r'-\1', text)
    text = re.sub(r'\{+l\|[a-z-]+\|([^{}|]+)(?:\|[^{}]*)?\}+', r'\1', text)
    # '[[w:Page#Anchor|label]]' -> 'label'
    text = re.sub(r'\[\[w:[^|\]]*\|([^\]]*)\]\]', r'\1', text)
    text = re.sub(r'\[\[(?:[^|\]]*\|)?([^\]]*)\]\]', r'\1', text)
    # '{{n-g|follows nouns…' / stray '}}' / '…가}complement'
    text = re.sub(r'\{\{[a-z-]+\|', '', text)
    text = text.replace('}}', ' ').replace('{{', ' ')
    text = re.sub(r'(?<=\S)\}(?=\S)', ' ', text).replace('}', '')
    # a lone '{' left by a broken template ('especially {Alpinia officinarum)')
    text = text.replace('{', '')
    return re.sub(r'\s{2,}', ' ', text).strip()


_READING_NOTE_RE = re.compile(r'^\((eumhun reading|MC reading|hanja):\s*(.*)\)$')


def parse_tsv_html(html: str) -> list:
    """
    Parse the pre-formatted HTML from TSV into [(pos, [(gloss, [notes])])].

    Input HTML example:
      <i>noun</i><br><ol><li>def1</li><li>def2</li></ol><br><i>verb</i><br><ol><li>def3</li></ol>

    Korean 'syllable' blocks list each Hanja as three sibling items
    ('進: progression', '(eumhun reading: …)', '(MC reading: …)'); the
    reading items are attached to the preceding item as notes. Nothing is
    truncated.
    """
    result = []
    pos_pattern = re.compile(r'<i>([^<]+)</i>\s*<br>\s*<ol>(.*?)</ol>', re.DOTALL)
    for match in pos_pattern.finditer(html):
        raw_pos = match.group(1).strip().lower()
        pos = POS_MAP.get(raw_pos, raw_pos)
        items = []
        for d in re.findall(r'<li>(.*?)</li>', match.group(2), re.DOTALL):
            d = clean_gloss(d)
            if not d:
                continue
            m = _READING_NOTE_RE.match(d)
            # '(MC reading: 乫)' carries no reading, only the character
            if m and m.group(1) == 'MC reading' and _PURE_HANJA_RE.match(m.group(2).strip()):
                continue
            if m and items and m.group(1) != 'hanja':
                items[-1][1].append(f'{m.group(1)}: {m.group(2).strip()}')
                continue
            items.append((d, []))
        if items and pos:
            result.append((pos, items))
    return result


def read_tsv(path: Path):
    """Yield (headword, [forms], html) for every upstream line."""
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\r\n')
            col, _, html = line.partition('\t')
            forms = [unicodedata.normalize('NFC', strip_bidi_controls(x)).strip()
                     for x in col.split('|')]
            yield forms[0], forms[1:], html


# ══════════════════════════════════════════════════════════════
# Korean
# ══════════════════════════════════════════════════════════════

# ── Revised Romanization (Wiktionary style) ────────────────────
#
# Used to recognise which ASCII form in the upstream bag romanizes the
# headword itself (the bag also holds romanizations of counters,
# inflections and Middle Korean forms, plus English tags), and as the
# displayed romanization when upstream has none. Covers liaison,
# nasalization, lateralization, aspiration by ㅎ, palatalization and
# ㄴ-insertion; rr_variants() returns every spelling these rules allow.

_RR_INI = ['g', 'kk', 'n', 'd', 'tt', 'r', 'm', 'b', 'pp', 's', 'ss', '', 'j', 'jj',
           'ch', 'k', 't', 'p', 'h']
_RR_VOW = ['a', 'ae', 'ya', 'yae', 'eo', 'e', 'yeo', 'ye', 'o', 'wa', 'wae', 'oe',
           'yo', 'u', 'wo', 'we', 'wi', 'yu', 'eu', 'ui', 'i']
_G, _KK, _N, _D, _TT, _R, _M, _B, _PP, _S, _SS, _O, _J, _JJ, _CH, _K, _T, _P, _H = range(19)
# final index -> (coda before a consonant / at the end,
#                 (coda kept, consonant moved) before a vowel)
_RR_FIN = {
    0: ('', ('', None)),
    1: ('k', ('', _G)), 2: ('k', ('', _KK)), 3: ('k', ('k', _S)),
    4: ('n', ('', _N)), 5: ('n', ('n', _J)), 6: ('n', ('', _N)),
    7: ('t', ('', _D)), 8: ('l', ('', _R)), 9: ('k', ('l', _G)),
    10: ('m', ('l', _M)), 11: ('l', ('l', _B)), 12: ('l', ('l', _S)),
    13: ('l', ('l', _T)), 14: ('p', ('l', _P)), 15: ('l', ('', _R)),
    16: ('m', ('', _M)), 17: ('p', ('', _B)), 18: ('p', ('p', _S)),
    19: ('t', ('', _S)), 20: ('t', ('', _SS)), 21: ('ng', ('ng', None)),
    22: ('t', ('', _J)), 23: ('t', ('', _CH)), 24: ('k', ('', _K)),
    25: ('t', ('', _T)), 26: ('p', ('', _P)), 27: ('t', ('', None)),
}
_RR_FIN_H = {6: 'n', 15: 'l', 27: ''}         # ㄶ ㅀ ㅎ aspirate the next consonant
_RR_ASPIRATE = {_G: _K, _D: _T, _J: _CH, _B: _P}
_RR_NASAL = {'k': 'ng', 't': 'n', 'p': 'm'}
# double finals whose second consonant merges with a following ㅎ (밝히다 balkida)
_RR_DOUBLE_H = {3: ('k', _K), 9: ('l', _K), 11: ('l', _P), 13: ('l', _T),
                14: ('l', _P), 18: ('p', _P), 5: ('n', _CH)}
# single obstruent finals before ㅎ: Wiktionary keeps the h (chukha, iphak);
# the merged spelling (japyeo) is accepted as a variant
_RR_SINGLE_H = {1: _K, 2: _K, 24: _K, 7: _T, 19: _T, 20: _T, 22: _CH, 23: _CH,
                25: _T, 17: _P, 26: _P}
_RR_Y_DROP = {2: 'a', 3: 'ae', 6: 'eo', 7: 'e', 12: 'o', 17: 'u'}   # 져 jeo, 쥬 ju
_RR_I_LIKE = (20, 2, 6, 12, 17, 3, 7)            # vowels that trigger ㄴ-insertion
# Before a vowel-initial root (not a suffix or particle) a final ㅅ ㅈ ㅊ ㅌ …
# is first neutralized to ㄷ, then linked: 맛없다 madeopda, 웃옷 udot,
# 끝없다 kkeudeopda; but 웃음 useum (음 is a suffix).
_RR_NEUTRAL = (7, 19, 20, 22, 23, 25)
_KO_SUFFIX_SYL = frozenset('이 음 을 은 아 어 의 으 여 요 와 야 았 었 였 임'.split())


def _rr_word(word: str, merge_h: bool = False, alt: bool = False,
             n_insert: bool = False, neutral: bool = False):
    """Romanize one Hangul word; returns the list of syllable strings or None."""
    syl = []
    for ch in word:
        c = ord(ch) - 0xAC00
        if not 0 <= c < 11172:
            return None
        syl.append((c // 588, (c % 588) // 28, c % 28))
    n = len(syl)
    ini = [s[0] for s in syl]
    ini_rom = [None] * n
    coda = [''] * n
    for i, (_, _, F) in enumerate(syl):
        if i + 1 == n:
            coda[i] = _RR_FIN[F][0]
            continue
        NI, NV = ini[i + 1], syl[i + 1][1]
        if F == 0:
            continue
        if n_insert and NI == _O and NV in _RR_I_LIKE and F != 27:
            ini[i + 1] = _N                              # 깻잎 kkaennip, 태평양 taepyeongnyang
            c = _RR_FIN[F][0]
            if c in _RR_NASAL:
                c = _RR_NASAL[c]
            elif c == 'l':
                ini_rom[i + 1] = 'l'
            coda[i] = c
            continue
        if NI == _O:                                     # liaison
            if F == 21:
                coda[i] = 'ng'
                continue
            if neutral and F in _RR_NEUTRAL and word[i + 1] not in _KO_SUFFIX_SYL:
                coda[i] = ''                             # 맛없다 madeopda, 곧이어 godieo
                ini[i + 1] = _D
                continue
            stay, moved = _RR_FIN[F][1]
            coda[i] = stay
            if moved is not None:
                if NV == 20 and moved == _D:
                    moved = _J                           # 굳이 guji
                elif NV == 20 and moved == _T:
                    moved = _CH                          # 같이 gachi
                ini[i + 1] = moved
            continue
        if F in _RR_FIN_H:                               # ㅎ ㄶ ㅀ + consonant
            c = _RR_FIN_H[F]
            if NI in _RR_ASPIRATE:
                coda[i] = c
                ini[i + 1] = _RR_ASPIRATE[NI]
            elif NI == _N:
                coda[i] = 'l' if F == 15 else 'n'
                if F == 15:
                    ini_rom[i + 1] = 'l'
            elif NI == _R and F == 15:
                coda[i] = 'l'
                ini_rom[i + 1] = 'l'
            elif NI == _S:
                coda[i] = c
            else:
                coda[i] = c or 't'
            continue
        if NI == _H:                                     # obstruent + ㅎ
            if F in _RR_DOUBLE_H:
                c, asp = _RR_DOUBLE_H[F]
                coda[i] = c
                ini[i + 1] = asp
                continue
            if merge_h and F in _RR_SINGLE_H:
                asp = _RR_SINGLE_H[F]
                coda[i] = ''
                ini[i + 1] = _CH if (NV == 20 and asp == _T) else asp
                continue
            if F == 7 and NV == 20:                      # 굳히다 guchida
                coda[i] = ''
                ini[i + 1] = _CH
                continue
            coda[i] = _RR_FIN[F][0]
            continue
        c = _RR_FIN[F][0]
        if alt and F == 11:
            c = 'p'                                      # 밟다 bapda
        if alt and F == 9 and NI in (_G, _KK):
            c = 'l'                                      # 읽고 ilgo
        if NI in (_N, _M):                               # nasalization
            if c in _RR_NASAL:
                c = _RR_NASAL[c]
            elif c == 'l' and NI == _N:
                ini_rom[i + 1] = 'l'                     # 설날 seollal
            coda[i] = c
            continue
        if NI == _R:
            if alt and c == 'n':
                coda[i] = 'n'                            # 의견란 uigyeonnan
                ini_rom[i + 1] = 'n'
            elif c in ('n', 'l'):
                coda[i] = 'l'                            # 신라 silla
                ini_rom[i + 1] = 'l'
            elif c in ('m', 'ng'):
                coda[i] = c                              # 종로 jongno
                ini_rom[i + 1] = 'n'
            elif c in _RR_NASAL:
                coda[i] = _RR_NASAL[c]                   # 독립 dongnip
                ini_rom[i + 1] = 'n'
            else:
                coda[i] = c
            continue
        coda[i] = c
    parts = []
    for i in range(n):
        r = ini_rom[i] if ini_rom[i] is not None else _RR_INI[ini[i]]
        v = _RR_VOW[syl[i][1]]
        if ini[i] in (_J, _JJ, _CH) and syl[i][1] in _RR_Y_DROP:
            v = _RR_Y_DROP[syl[i][1]]
        parts.append(r + v + coda[i])
    return parts


def _rr_join(parts: list) -> str:
    """Join syllables with Wiktionary's apostrophe at ambiguous boundaries
    (chin'gu, jung'ang, Hae'undae)."""
    out = parts[0]
    for p in parts[1:]:
        if (out.endswith('n') and p.startswith('g')) or \
           (out.endswith('ng') and p[:1] in 'aeiouwy') or \
           (out[-1:] in 'aeiou' and p[:1] in 'aeiou' and
                out[-1] + p[0] in ('ae', 'eo', 'eu', 'oe', 'ui')):
            out += "'" + p
        else:
            out += p
    return out


def rr_romanize(text: str):
    """Primary RR spelling of a Hangul phrase, or None if it is not all Hangul."""
    if not _HANGUL_WORD_RE.match(text):
        return None
    return ' '.join(_rr_join(_rr_word(w)) for w in text.split())


def rr_variants(text: str, neutral: bool = False) -> set:
    """Every spelling the RR rules allow, normalized with rom_norm(); with
    `neutral`, the spellings with ㄷ-neutralization before a root instead."""
    if not _HANGUL_WORD_RE.match(text):
        return set()
    flags = [(m, a, ni, neutral) for m in (False, True) for a in (False, True)
             for ni in (False, True)]
    words = text.split()
    if len(words) > 3:
        # 8 spellings per word would mean 8**n combinations (8**10 for the
        # longest proverbs); apply one rule set to the whole phrase instead.
        return {''.join(''.join(_rr_word(w, *f)) for w in words) for f in flags}
    out = {''}
    for w in words:
        vs = {''.join(_rr_word(w, *f)) for f in flags}
        out = {a + b for a in out for b in vs}
    return out


def rr_letterwise(text: str) -> str:
    """Syllable-by-syllable RR with no sound changes (적면 jeokmyeon, where
    the RR is jeongmyeon): a spelling learners type, keyed when upstream
    also gives it."""
    out = []
    for ch in text.replace(' ', ''):
        c = ord(ch) - 0xAC00
        if not 0 <= c < 11172:
            return ''
        out.append(_RR_INI[c // 588] + _RR_VOW[(c % 588) // 28] + _RR_FIN[c % 28][0])
    return ''.join(out)


def rom_norm(s: str) -> str:
    return re.sub(r"[\s'\-’ʼ‘.·?!,]", '', s).lower()


def _levenshtein(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


_ROM_CAND_RE = re.compile(r"^[A-Za-z][A-Za-z' \-]*[A-Za-z]$|^[A-Za-z]$")


def pick_korean_romanization(hw: str, forms: list):
    """Return (display, [key spellings]) for a Hangul headword, or (None, [])."""
    cands = [f for f in forms if _ROM_CAND_RE.match(f)]
    variants = rr_variants(hw)
    if not variants:
        return None, []
    valid = [c for c in cands if rom_norm(c) in variants]
    if not valid:
        neutral = rr_variants(hw, neutral=True)
        valid = [c for c in cands if rom_norm(c) in neutral]
    extra = []
    if valid:
        display = valid[0]
    else:
        base = rom_norm(rr_romanize(hw))
        near = sorted((_levenshtein(rom_norm(c), base), i, c) for i, c in enumerate(cands)
                      if rom_norm(c)[:1] == base[:1])
        # a near miss is accepted only where the rules allow several spellings
        # (붙여넣기 bucheoneoki); with one spelling it is an upstream slip
        # (웃음 'udeum' for useum)
        if len(variants) > 1 and near and near[0][0] <= max(1, len(base) // 5):
            display = near[0][2]
            valid = [display]
        else:
            display = rr_romanize(hw)                    # no usable upstream form
            valid = [display]
            if near and near[0][0] <= 1:
                extra = [near[0][2]]                     # still a key: udeum -> 웃음
    keys = []
    # also key the RR without optional rules (검열 geomyeol next to
    # Wiktionary's geomnyeol) and an upstream letter-by-letter spelling
    # (적면 jeokmyeon), which is what a learner types
    lw = rr_letterwise(hw)
    letterwise = [c for c in cands if lw and rom_norm(c) == lw and c not in valid]
    for v in valid + [rr_romanize(hw)] + letterwise + extra:
        for k in (v, v.replace("'", '').replace('-', '')):
            if k.lower() not in (x.lower() for x in keys):     # lookup ignores case
                keys.append(k)
    return display, keys


_GLOSS_LABEL_RE = re.compile(r'^(?:\([^)]*\)\s*)+')
# where the name in a first sense ends and its explanation starts:
# 'lemon (fruit)', 'kimchi, a dish made with …', 'Hangul, the Korean alphabet'
_GLOSS_EXPL_RE = re.compile(r' \(|, (?:a|an|the|one)\b| [-–—] |[.:](?:\s|$)')
_GLOSS_ITEM_RE = re.compile(r"^[A-Za-z][A-Za-z'\- ]*$")


def gloss_spellings(hw: str, senses: list) -> list:
    """English spellings of the word itself, taken from a first sense that
    only names it: 김치 'kimchi, a dish made with …', 한글 '(chiefly South
    Korea) Hangul, the Korean alphabet', 레몬 'lemon (fruit)', 김밥 'kimbap,
    gimbap (…)'. Every item of that name list must be a spelling of the
    headword (close to its RR). A spelling in a later sense (다시 'again, once
    more' … '(typography) dash') or among translations (많이 'many, much, a
    lot') is not keyed: an English lookup of 'dash' or 'many' must not open
    these articles."""
    if not senses:
        return []
    v = rr_variants(hw)
    if not v:
        return []
    name = _GLOSS_EXPL_RE.split(_GLOSS_LABEL_RE.sub('', senses[0]).strip(), 1)[0]
    items = [re.sub(r'^(?:a|an|the) ', '', x.strip()) for x in re.split(r'[;,] ?', name)]
    items = [x for x in items if x]

    def dist(tok):
        n = rom_norm(unicodedata.normalize('NFD', tok))
        n = ''.join(c for c in n if not unicodedata.combining(c))
        return n, min(_levenshtein(n, x) for x in v)

    out = []
    for tok in items:
        if re.search('[ŏŭ]', tok):
            continue                # McCune–Reischauer: 'Gyeonggi, Kyŏnggi'
        n, d = dist(tok)
        if d > max(1, len(n) // 4):
            return []               # 'gasoline, petrol': a translation list
        if len(n) >= 4 and d and _GLOSS_ITEM_RE.match(tok) and tok not in out:
            out.append(tok)
    return out


# ── Headwords with digits, Latin letters or Hanja (4월, PC방, 先生님) ──

_JAMO_RE = re.compile(r'[\u1100-\u11FF\u3130-\u318F]')
_SINO_DIGIT = {'0': ('영', '공'), '1': ('일',), '2': ('이',), '3': ('삼',), '4': ('사',),
               '5': ('오',), '6': ('육', '륙', '유'), '7': ('칠',), '8': ('팔',), '9': ('구',)}
_LETTER_NAMES = {
    'A': ('에이',), 'B': ('비',), 'C': ('씨', '시'), 'D': ('디',), 'E': ('이',), 'F': ('에프',),
    'G': ('지',), 'H': ('에이치',), 'I': ('아이',), 'J': ('제이',), 'K': ('케이',), 'L': ('엘',),
    'M': ('엠',), 'N': ('엔',), 'O': ('오',), 'P': ('피',), 'Q': ('큐',), 'R': ('알',),
    'S': ('에스',), 'T': ('티',), 'U': ('유',), 'V': ('브이',), 'W': ('더블유',), 'X': ('엑스',),
    'Y': ('와이',), 'Z': ('제트',),
}
_MIXED_TOKEN_RE = re.compile(r'[0-9]+|[A-Za-z]+|.', re.DOTALL)


def _sino_number(n: int) -> str:
    """386 -> 삼백팔십육 (0 < n < 10000)."""
    out = ''
    for unit, name in ((1000, '천'), (100, '백'), (10, '십')):
        d, n = divmod(n, unit)
        if d:
            out += ('' if d == 1 else _SINO_DIGIT[str(d)][0]) + name
    return out + (_SINO_DIGIT[str(n)][0] if n else '')


def _spell_out(hw: str) -> list:
    """Hangul readings of digits and Latin letters: 386 -> 삼팔육, 삼백팔십육;
    PC방 -> 피씨방, 피시방. At most 32 readings."""
    out = ['']
    for tok in _MIXED_TOKEN_RE.findall(hw):
        if tok.isdigit():
            opts = ['']
            for d in tok:
                opts = [a + b for a in opts for b in _SINO_DIGIT[d]]
            if tok[0] != '0' and 0 < int(tok) < 10000 and len(tok) > 1:
                opts.append(_sino_number(int(tok)))
        elif tok.isascii() and tok.isalpha():
            opts = ['']
            for ch in tok.upper():
                opts = [a + b for a in opts for b in _LETTER_NAMES[ch]]
        else:
            opts = [tok]
        out = [a + b for a in out for b in opts][:32]
    return out


def mixed_romanization(hw: str, forms: list):
    """(display, [key spellings]) for a headword partly written in digits,
    Latin letters or Hanja (4월 sawol, PC방 pissibang, 386 sampallyuk,
    先生님 seonsaengnim): the upstream candidate that romanizes one of its
    Hangul readings, taken from the bag (사월) or spelled out; (None, [])
    when no candidate does."""
    pat = []
    for tok in _MIXED_TOKEN_RE.findall(hw):
        if tok.isdigit() or (tok.isascii() and tok.isalpha()):
            pat.append(f'[{_HANGUL_SYL}]+')
        elif _HANJA_RE.match(tok):
            pat.append(f'[{_HANGUL_SYL}]')
        elif tok in ' -':
            pat.append('[- ]?')             # 오스트리아-헝가리 Oseuteuria-Heonggari
        elif _HANGUL_WORD_RE.match(tok):
            pat.append(re.escape(tok))
        else:
            return None, []
    pat = re.compile(''.join(pat))
    readings = [f for f in forms if _HANGUL_WORD_RE.match(f) and pat.fullmatch(f)]
    readings += [r for r in (x.replace('-', ' ') for x in _spell_out(hw))
                 if _HANGUL_WORD_RE.match(r) and r not in readings]
    cands = [f for f in forms if _ROM_CAND_RE.match(f)]
    valid, spelled = [], []
    for r in readings:
        v = rr_variants(r) | rr_variants(r, neutral=True)
        ok = [c for c in cands if rom_norm(c) in v and c not in valid]
        if ok:
            valid += ok
            spelled.append(rr_romanize(r))
    if not valid:
        return None, []
    keys = []
    for v in valid + spelled:
        for k in (v, v.replace("'", '').replace('-', '')):
            if k.lower() not in (x.lower() for x in keys):
                keys.append(k)
    return valid[0], keys


# Romanizations that are also English words. The app looks a query up in
# every active dictionary, so a key 'but' (붓 'brush'), 'son' (손 'hand') or
# 'jot' (좆) would add an unrelated Korean article to an English lookup.
# These get no romanization key (the romanization is still shown in the
# article):
#   * English function words, and 'jot' (a vulgar target), always;
#   * the other listed English words unless the target's own glosses use the
#     word (펜 'pen', 핀 'pin': loanwords).
# So 'iron' (이론), 'data' (닿다), 'son' (손), 'man' (만) and 'rye' (례) get no
# key. The list holds English words only (no chemical symbols, Greek letters
# or solfège syllables): this data's romanizations that are English WordNet
# lemmas used in English glosses, plus known problem cases found in the output.
_EN_FUNCTION_WORDS = frozenset(
    'a an i o u e at in on to it do go no so me we hi ok am but yet more use sure'.split())
_EN_VULGAR_TARGET = frozenset({'jot'})
_EN_HOMOGRAPHS = frozenset('''
    ado ai bam ban bang bat bin bit boon bum bun bung cause chin chip chum dado dal dam
    data datum dip doe don dot dun gage gang gap goon got gun gut ham hang hangman hap
    hat hoe hop hot hung ire iron jam jap japan jason jean join king mail mama man manta
    mat mojo mom mot nan nap nasa net nil nip nun pail pal pan pap pat pen pin ping pip
    pun rain ram ran rap rebel roe rome rot rube rut rye sago sandal sang sap sarin sat
    set sin sinai sing sip son song sot sum sun sundae sung swim tail tan tap taro tat
    tip ton top tot usa yak
'''.split())
_GLOSS_WORD_RE = re.compile(r"[a-z]+")
# the romanization in a cross-reference ('form of 밭 (bat, “dry field”)')
# is not the gloss using the English word
_GLOSS_XREF_ROM_RE = re.compile(f"(?<=[{_HANGUL_SYL}{_HAN}]) ?\\([A-Za-z'\\- ]+(?=[,)])")


def english_homograph(key: str, gloss_text: str) -> bool:
    """True when `key` should not become a romanization key (see above)."""
    k = key.lower()
    if k in _EN_FUNCTION_WORDS or k in _EN_VULGAR_TARGET:
        return True
    gloss_text = _GLOSS_XREF_ROM_RE.sub(' (', gloss_text)
    return k in _EN_HOMOGRAPHS and k not in _GLOSS_WORD_RE.findall(gloss_text.lower())


# ── Hangul forms ───────────────────────────────────────────────

# Speech-level names that upstream puts in the form bag of verbs.
_KO_SPEECH_LEVELS = frozenset({
    '해체', '해라체', '해요체', '하오체', '하게체', '하십시오체', '합쇼체', '하소서체',
})
# Counters in the form bag of nouns (학생|學生|명|名|haksaeng|myeong).
_KO_COUNTERS = frozenset({
    '마리', '명', '개', '대', '장', '벌', '켤레', '채', '권', '그루', '곡', '통', '송이',
    '잔', '병', '자루', '척', '필', '쌍', '분', '살', '편', '줄', '알', '톨', '포기',
    '근', '첩', '갑', '군데', '칸', '층', '번', '판', '쪽', '부', '점', '수', '량',
    '동', '문', '정', '좌', '인', '두', '매', '본', '건', '회', '차례', '가지', '닢',
    '끼', '짝', '쌈', '축', '접', '손', '꾸러미', '촉', '자', '평',
})
# one character class, not (?:[A-Za-z]+[ :]*)+ : that nesting backtracks
# exponentially on long English tags with no Hangul after them
_KO_LABEL_PREFIX = re.compile(r'^[A-Za-z][A-Za-z :]*(?=[\uAC00-\uD7A3])')


def _ko_initial(s: str):
    c = ord(s[0]) - 0xAC00
    return c // 588 if 0 <= c < 11172 else None


def _ko_ini_vowel(s: str):
    c = ord(s[0]) - 0xAC00
    return c // 28 if 0 <= c < 11172 else None


def korean_form_candidates(hw: str, forms: list) -> list:
    """Hangul forms from the upstream bag (labels like 'past: ' removed)."""
    out = []
    for f in forms:
        if not f or 'Category:' in f or ' of ' in f:
            continue
        f = _KO_LABEL_PREFIX.sub('', f).strip()
        if f == hw or not _HANGUL_WORD_RE.match(f) or f in _KO_SPEECH_LEVELS:
            continue
        if f not in out:
            out.append(f)
    return out


_DASHES = '—―‒–'
_HANJA_SPLIT_RE = re.compile(r'[／/·・]')


def _hanja_spelling_re(form: str):
    """Regex for the Hangul spelling that a (mixed or partial) Hanja spelling
    stands for: a Hanja is one syllable, a dash one or more native syllables,
    a Hangul letter itself."""
    out = []
    for ch in form:
        if _HANJA_RE.match(ch):
            out.append(f'[{_HANGUL_SYL}]')
        elif ch in _DASHES:
            out.append(f'[{_HANGUL_SYL}]+')
        elif _HANGUL_WORD_RE.match(ch):
            out.append(re.escape(ch))
        else:
            return None
    return re.compile(''.join(out))


def hanja_candidates(hw: str, forms: list) -> list:
    """Hanja spellings of a Hangul headword, for display only: pure (學生),
    mixed (監守하다, 先生님), several words (家宅 軟禁) or partial with a dash
    for the native part (韓國— for 한국말). Each must spell the whole
    headword, one Hanja per syllable, so counters (학생 名) and partial
    spellings without a dash (요리사 料理) are dropped."""
    target = hw.replace(' ', '')
    words = hw.split(' ')
    out, per_word = [], [[] for _ in words]
    for f in forms:
        if f.startswith('Hanja in this term'):
            f = f.split()[-1]               # table caption '… 多 分 多分': the last word
        if not _HANJA_RE.search(f) or _LATIN_RE.search(f):
            continue
        for part in _HANJA_SPLIT_RE.split(f):
            part = re.sub(r'\s+', ' ', part.replace('•', '')).strip()
            if not part or part == hw or part in out or not _HANJA_RE.search(part):
                continue
            pat = _hanja_spelling_re(part.replace(' ', ''))
            if pat and pat.fullmatch(target):
                out.append(part)
            elif pat and len(words) > 1:
                for i, w in enumerate(words):
                    if pat.fullmatch(w) and part not in per_word[i]:
                        per_word[i].append(part)
    if not out and len(words) > 1 and all(per_word):
        # one spelling per word (호사유피 인사유명: 虎死留皮 + 人死留名)
        out.append(' '.join(p[0] for p in per_word))
    return out


# eumhun of a single Hanja: Korean meaning + reading ('하늘 건', '넷째 천간 (天干) 정')
_EUMHUN_RE = re.compile(f'^[{_HANGUL_SYL}]+(?: (?:[{_HANGUL_SYL}]+|\\([{_HAN}{_HANGUL_SYL}]+\\)))*'
                        f' [{_HANGUL_SYL}]$')


def eumhun_forms(forms: list) -> list:
    out = []
    for f in forms:
        if _EUMHUN_RE.match(f) and f not in out:
            out.append(f)
    return out


_HANJA_FORM_RE = re.compile(
    r'^(\([^)]*\)\s*)?Hanja form of ([\uAC00-\uD7A3]+(?: [\uAC00-\uD7A3]+)*)(.*)$')


def hanja_form_target(gloss: str):
    """'Hanja form of 시간 (“time, an hour”).' -> ('시간', 'time, an hour').
    A leading label is kept: '(prefix) Hanja form of 건 (“dry”)' -> ('건', '(prefix) dry')."""
    m = _HANJA_FORM_RE.match(gloss)
    if not m:
        return None
    rest = m.group(3).strip()
    if rest and not rest.startswith(('(', '.', ';', ',')):
        return None
    # the outermost quotes: a gloss may quote again ('“Root of 가각하다
    # (gagakhada, “苛刻하다”). Rarely used alone.”')
    q = re.search(r'“(.*)”', rest) or re.search(r'“(.*)$', rest)
    g = q.group(1).strip().rstrip('.,;') if q else ''
    g = re.sub(r'^\(\(', '(', g)          # '((Chinese character classification) …'
    if g and g.count('(') != g.count(')'):
        g = g.split('(')[0].strip() if g.count('(') > g.count(')') else g
    if g and m.group(1):
        g = f'{m.group(1).strip()} {g}'
    return m.group(2), g


_WORD_RE = re.compile(r'[a-z]{3,}')
_STOP = frozenset({'the', 'and', 'for', 'with', 'from', 'that', 'this', 'which', 'its',
                   'one', 'used', 'form', 'hanja', 'etc', 'something', 'someone'})


def _sense_index(gloss: str, senses: list) -> int:
    """Index of the sense that shares the most words with `gloss` (or a large number)."""
    gw = set(_WORD_RE.findall(gloss.lower())) - _STOP
    if not gw:
        return 10 ** 6
    best, best_i = 0, 10 ** 6
    for i, s in enumerate(senses):
        n = len(gw & set(_WORD_RE.findall(s.lower())))
        if n > best:
            best, best_i = n, i
    return best_i


# ══════════════════════════════════════════════════════════════
# Arabic
# ══════════════════════════════════════════════════════════════

_AR_STRIP = re.compile(r'[\u0610-\u061A\u064B-\u065F\u0670\u0640\u06D6-\u06ED\u08D3-\u08FF]')
_AR_MARKS = '\u064E\u064F\u0650\u064B\u064C\u064D\u0651\u0652\u0670'


def ar_typable(text: str) -> str:
    """The spelling an Arabic keyboard user types: no harakat, tatweel or
    Quranic marks; alef wasla as plain alef."""
    text = _AR_STRIP.sub('', text).replace('ٱ', 'ا')
    return re.sub(r'\s+', ' ', text).strip()


_HAMZA_FOLD = str.maketrans({'أ': 'ا', 'إ': 'ا', 'آ': 'ا'})


# ── Wiktionary-style transliteration of vocalized Arabic ───────
#
# Used only to pair upstream transliterations (kitāb) with the vocalized
# form they belong to (كِتَاب); the transliteration shown is upstream's.

_AR_CONS = {
    'ء': 'ʾ', 'أ': 'ʾ', 'إ': 'ʾ', 'ؤ': 'ʾ', 'ئ': 'ʾ',
    'ب': 'b', 'ت': 't', 'ث': 'ṯ', 'ج': 'j', 'ح': 'ḥ', 'خ': 'ḵ', 'د': 'd',
    'ذ': 'ḏ', 'ر': 'r', 'ز': 'z', 'س': 's', 'ش': 'š', 'ص': 'ṣ', 'ض': 'ḍ',
    'ط': 'ṭ', 'ظ': 'ẓ', 'ع': 'ʿ', 'غ': 'ḡ', 'ف': 'f', 'ق': 'q', 'ك': 'k',
    'ل': 'l', 'م': 'm', 'ن': 'n', 'ه': 'h', 'و': 'w', 'ي': 'y',
    'پ': 'p', 'چ': 'č', 'ڤ': 'v', 'گ': 'g', 'ژ': 'ž', 'ی': 'y', 'ک': 'k',
}
_AR_SHORT = {'\u064E': 'a', '\u064F': 'u', '\u0650': 'i'}
_AR_TANWEEN = {'\u064B': 'an', '\u064C': 'un', '\u064D': 'in'}
_AR_SHADDA, _AR_DAGGER = '\u0651', '\u0670'
_AR_SUN = set('تثدذرزسشصضطظلن')
_AR_VOWEL_END = ('a', 'i', 'u', 'ā', 'ī', 'ū')


def _ar_translit_word(word: str, after_vowel: bool = False, construct: bool = False,
                      assimilate: bool = False):
    """Transliteration of one vocalized word. `construct`: a final unmarked
    ة is read -at (كُرَة الْقَدَم kurat al-qadam); `assimilate`: al- before an
    unmarked sun letter is assimilated (الصَفْرَة ṣ-ṣafra)."""
    t = []
    for ch in word:
        if ch in _AR_MARKS:
            if t:
                t[-1][1].append(ch)
        elif ch != 'ـ':
            t.append([ch, []])
    if not t:
        return ''
    bare = ''.join(c for c, _ in t)
    if bare in ('الله', 'ٱلله', 'لله'):
        case = [_AR_SHORT[m] for m in t[-1][1] if m in _AR_SHORT]
        pre = 'li' if bare == 'لله' else ('' if after_vowel else 'a')
        return pre + 'llāh' + (case[0] if case else '')
    res = []
    i, n = 0, len(t)
    skip_double = False
    if n >= 3 and t[0][0] in 'اٱ' and t[1][0] == 'ل' \
            and not any(m in _AR_SHORT for m in t[1][1]) \
            and not any(m in ('\u064F', '\u0650') for m in t[0][1]):
        a = '' if after_vowel else 'a'
        if t[2][0] in _AR_SUN and (_AR_SHADDA in t[2][1] or (
                assimilate and '\u0652' not in t[1][1])):
            res.append(a + _AR_CONS[t[2][0]] + '-')
            skip_double = _AR_SHADDA in t[2][1]
        else:
            res.append(a + 'l-')
        i = 2
    while i < n:
        ch, marks = t[i]
        if ch == 'آ':
            res.append('ʾā')
        elif ch in 'اٱ':
            if i == 0:
                v = [_AR_SHORT[m] for m in marks if m in _AR_SHORT]
                res.append(v[0] if v else ('' if ch == 'ٱ' else 'a'))
            elif '\u064B' in marks:                      # نِسْبِيّاً nisbiyyan
                if res and res[-1].endswith('a'):
                    res[-1] = res[-1][:-1]
                res.append('an')
            elif any(m in _AR_TANWEEN for m in t[i - 1][1]):
                pass                                     # tanween + alef: the alef is silent
            elif i == n - 1 and res and res[-1].endswith('ū'):
                pass                                     # كَتَبُوا katabū
            elif res and res[-1].endswith('a'):
                res[-1] = res[-1][:-1] + 'ā'
            else:
                res.append('ā')
        elif ch == 'ى':
            if res and res[-1].endswith('a'):
                res[-1] = res[-1][:-1] + 'ā'
            elif not (res and res[-1].endswith('an')):
                res.append('ā')
        elif ch == 'ة':
            if res and not res[-1].endswith(_AR_VOWEL_END):
                res.append('a')
            v = [m for m in marks if m in _AR_SHORT or m in _AR_TANWEEN]
            if v:
                res.append('t' + (_AR_SHORT.get(v[0]) or _AR_TANWEEN[v[0]]))
            elif construct:
                res.append('t')
        elif ch in 'وي' and not any(m in _AR_SHORT or m in _AR_TANWEEN or m == _AR_SHADDA
                                    for m in marks) and res and \
                ((ch == 'و' and res[-1].endswith('u')) or (ch == 'ي' and res[-1].endswith('i'))):
            res[-1] = res[-1][:-1] + ('ū' if ch == 'و' else 'ī')
        else:
            c = _AR_CONS.get(ch)
            if c is None:
                return None
            s = c + c if (_AR_SHADDA in marks and not skip_double) else c
            skip_double = False
            vow = ''
            for m in marks:
                if m in _AR_SHORT:
                    vow += _AR_SHORT[m]
                elif m in _AR_TANWEEN:
                    vow += _AR_TANWEEN[m]
                elif m == _AR_DAGGER:
                    vow = vow[:-1] + 'ā' if vow.endswith('a') else vow + 'ā'
            if ch == 'إ' and not vow:
                vow = 'i'
            res.append(s + vow)
        i += 1
    return ''.join(res)


def ar_translit(text: str, construct: bool = False, assimilate: bool = False):
    out, prev = [], ''
    words = text.split()
    for i, w in enumerate(words):
        p = _ar_translit_word(w, after_vowel=bool(out) and prev.endswith(_AR_VOWEL_END),
                              construct=construct and i < len(words) - 1,
                              assimilate=assimilate)
        if p is None:
            return None
        out.append(p)
        prev = p
    return ' '.join(out)


def _ar_pairing_maps(pool: list):
    """{normalized transliteration: vocalized form} (exact and fuzzy) for
    pairing upstream transliterations with the forms in `pool`. The plain
    reading of every form is entered before the construct-state (kurat
    al-qadam) and assimilated (ṣ-ṣafra) readings, so a fully marked form
    (الدَّانُوب) wins over a less marked one (الدَانُوب)."""
    exact, fuzzy = {}, {}
    for c, a in ((False, False), (True, False), (False, True), (True, True)):
        for f in pool:
            t = ar_translit(f, construct=c, assimilate=a)
            if t:
                exact.setdefault(_tl_norm(t), f)
                fuzzy.setdefault(_tl_fuzz(t), f)
    return exact, fuzzy


def _tl_norm(s: str) -> str:
    return re.sub(r"[\s'\-’ʼ‘]", '', s).lower()


_TL_FUZZ = str.maketrans({'ā': 'a', 'ī': 'i', 'ū': 'u', 'ē': 'i', 'ō': 'u', 'e': 'i', 'o': 'u'})


def _tl_fuzz(s: str) -> str:
    s = re.sub(r'at(?=\s|$)', 'a', s.lower())            # construct -at / pausal -a
    s = _tl_norm(s).translate(_TL_FUZZ)
    return re.sub(r'(?<=a)h$', '', s)                     # -āh (tāʾ marbūṭa)


def _tl_skeleton(s: str) -> str:
    s = re.sub(r"[aeiouāīūēō\s'\-’ʼ‘wy]", '', _tl_norm(s))
    s = s.replace('g', 'j')                               # جولف golf, زجرب zagrab
    return re.sub(r'(.)\1+', r'\1', s)


_TL_CAND_RE = re.compile(r"^[A-Za-zʾʿāīūēōḥṣḍṭẓḏṯḵḡšžčĀĪŪĒŌḤṢḌṬẒḎṮḴḠŠŽČ' \-]+$")
_TL_VOWEL_RE = re.compile(r'[aeiouāīūēōĀĪŪĒŌ]')


def _ar_letters(word: str) -> list:
    """[(letter, marks)] of one vocalized word."""
    t = []
    for ch in word:
        if ch in _AR_MARKS:
            if t:
                t[-1][1].append(ch)
        elif ch != 'ـ':
            t.append([ch, []])
    return t


def _ar_case_form(voc: str, has_verb: bool) -> bool:
    """A case-inflected form rather than a lemma: a short vowel on the last
    letter (أُرْدُنِّيَّ ʾurdunniyya, رِجْلَ rijla). A final fatha after a vowelled
    letter is a perfect verb (كَتَبَ kataba) when the article has a verb."""
    words = voc.split()
    t = _ar_letters(words[-1]) if words else []
    if not t or not any(m in _AR_SHORT for m in t[-1][1]):
        return False
    if len(t) >= 2 and t[-1][0] == 'ي' and _AR_SHADDA in t[-1][1] and '\u0650' in t[-2][1]:
        return True                                  # nisba -iyya (فَنِّيَّ), never a verb
    if has_verb and '\u064E' in t[-1][1] and len(t) >= 2 and \
            '\u0652' not in t[-2][1] and (t[-2][1] or t[-2][0] in 'اوي'):
        return False
    return True


def ar_passive(voc: str) -> bool:
    """A passive perfect: first vowel u, final fatha (ضُرِبَ ḍuriba)."""
    vowels = [m for _, ms in _ar_letters(voc) for m in ms if m in _AR_SHORT]
    return bool(vowels) and vowels[0] == '\u064F' and voc.endswith('\u064E')


_AR_UNINFLECTED_POS = frozenset({'part.', 'conj.', 'prep.', 'pron.', 'interj.', 'adv.'})


def arabic_readings(hw: str, forms: list, pos: list = ()) -> list:
    """[(vocalized or '', transliteration)] for the headword's own lemma(s).

    Upstream transliterations are kept only when they transliterate a
    vocalized form whose typable spelling is the headword (exactly, or
    ignoring vowel length/quality), or, failing that, when their consonant
    skeleton is the headword's. Tags ('hapax', 't', 'file') and the
    transliterations of plurals and other forms are dropped. Case-inflected
    forms (أُرْدُنِّيَّ, spelled like the feminine ʾurdunniyya) are paired only
    when nothing else is, and a verb-only article ignores dagger-alif
    spellings (كِتٰب kitāb, the noun). Exceptions: an article with a
    particle, preposition, adverb … block also pairs final-vowel forms
    (سَوْفَ sawfa, بَعْدَ baʿda); a letter shows its name and sound (ب bāʾ,
    b); a spaced root shows its root transliteration (ن س ي n-s-y).
    """
    lat_all = list(dict.fromkeys(f for f in forms if _TL_CAND_RE.match(f)))
    words = hw.split()
    if len(words) > 1 and all(len(w) == 1 for w in words):
        # spaced root (ن س ي): its own transliteration n-s-y, not the
        # readings of the derived words listed in the article
        return [('', c) for c in lat_all if len(c.split('-')) == len(words) and ' ' not in c]
    letter = 'char.' in pos and len(ar_typable(hw)) == 1
    lat = [f for f in lat_all if _TL_VOWEL_RE.search(f)]
    if not lat and not (letter and lat_all):
        return []
    has_verb = 'v.' in pos
    verb_only = bool(pos) and all(p == 'v.' for p in pos)
    vocs = [f for f in forms
            if _ARABIC_RE.search(f) and not _LATIN_RE.search(f) and ar_typable(f) == hw
            and not (verb_only and _AR_DAGGER in f)]
    out = []
    for pool in ([f for f in vocs if not _ar_case_form(f, has_verb)], vocs):
        exact, fuzzy = _ar_pairing_maps(pool)
        out = [(exact[_tl_norm(c)], c) for c in lat if _tl_norm(c) in exact]
        if not out:
            out = [(fuzzy[_tl_fuzz(c)], c) for c in lat if _tl_fuzz(c) in fuzzy]
        if out:
            break
    if out and pool is not vocs and any(p in _AR_UNINFLECTED_POS for p in pos):
        # a particle keeps its final vowel (سَوْفَ sawfa beside the verb سَوَّفَ)
        done = {c for _, c in out}
        exact = _ar_pairing_maps(vocs)[0]
        out += [(exact[_tl_norm(c)], c) for c in lat if c not in done and _tl_norm(c) in exact]
    if letter:
        # a letter: also its name and sound (ب bāʾ, b; ز zayn, zāy; ن ni, nūn)
        done = {c for _, c in out}
        out += [('', c) for c in lat_all if c not in done]
    if not out:
        sk = _tl_skeleton(ar_translit(hw) or '')
        if len(sk) >= 2:
            out = [('', c) for c in lat if _tl_skeleton(c) == sk]
        # the skeleton ignores y and final vowels: a nisba (إنجليزي) keeps
        # ʾinglīziyy, not also ʾinglīz and the feminine ʾinglīziyya
        end = {'ي': ('iyy', 'ī'), 'ة': ('a', 'at', 'ah')}.get(hw[-1:])
        if len(out) > 1 and end and any(c.endswith(end) for _, c in out):
            out = [(v, c) for v, c in out if c.endswith(end)]
    seen, res = set(), []
    for v, c in out:
        if c not in seen:
            seen.add(c)
            res.append((v, c))
    return res


def arabic_form_candidates(hw: str, forms: list) -> list:
    """Typable spellings of the vocalized forms in the upstream bag."""
    out = []
    for f in forms:
        if not _ARABIC_RE.search(f):
            continue
        for part in re.split(r'\s+or\s+', f):
            part = re.sub(r'^(?:[A-Za-z]+\s+)+', '', part.strip())   # 'state …', 'Audio …'
            if not part or _LATIN_RE.search(part) or re.search(r'[*:()\[\].\u2026,\u061B\u060C0-9]', part):
                continue
            t = ar_typable(part)
            if t and t != hw and _ARABIC_LETTER_RE.search(t) and \
                    not re.search(r'[^\u0600-\u06FF\u0750-\u077F ]', t) and t not in out:
                out.append(t)
    return out


# ══════════════════════════════════════════════════════════════
# Rendering
# ══════════════════════════════════════════════════════════════

_KO_RUN_RE = re.compile(f'[{_HANGUL_SYL}]+(?: [{_HANGUL_SYL}]+)*|[{_HAN}]+')
_AR_RUN_RE = re.compile(r'[\u0621-\u065F\u0670-\u06D3\u0640]+(?:\s+[\u0621-\u065F\u0670-\u06D3\u0640]+)*')


def link_filter(resolve):
    """can_link(key, hw) for linkify_*: the key exists and opens at least one
    article other than `hw` (a link back to the article itself goes nowhere:
    일원론 is a redirect to 一元論, so 一元論's 'Hanja form of 일원론' is not
    linked). `resolve(key)` returns the articles a key opens, or None."""
    def can_link(key, hw):
        arts = resolve(key)
        return bool(arts) and bool(set(arts) - {hw})
    return can_link


def linkify_ko(text: str, can_link, hw: str) -> str:
    """Escape a gloss, linking Hangul/Hanja words that are keys (entry://)."""
    out, pos = [], 0
    for m in _KO_RUN_RE.finditer(text):
        out.append(esc(text[pos:m.start()]))
        run = m.group(0)
        if run != hw and can_link(run, hw):
            out.append(entry_link(run))
        else:
            words = run.split(' ')
            out.append(' '.join(entry_link(w) if (w != hw and len(words) > 1 and can_link(w, hw))
                                else esc(w) for w in words))
        pos = m.end()
    out.append(esc(text[pos:]))
    return ''.join(out)


def linkify_ar(text: str, can_link, hw: str) -> str:
    """Escape a gloss; isolate each Arabic run (dir=rtl) and link it, or its
    words, when the typable spelling is a key."""
    out, pos = [], 0
    for m in _AR_RUN_RE.finditer(text):
        run = m.group(0)
        if not _ARABIC_LETTER_RE.search(run):
            continue
        out.append(esc(text[pos:m.start()]))
        bare = ar_typable(run)
        if bare != hw and can_link(bare, hw):
            inner = entry_link(bare, run)
        else:
            parts = re.split(r'(\s+)', run)
            inner = ''.join(
                entry_link(ar_typable(p), p) if (p.strip() and ar_typable(p) != hw
                                                 and len(parts) > 1 and can_link(ar_typable(p), hw))
                else esc(p) for p in parts)
        out.append(f'<span{dir_attr("rtl", "ar")}>{inner}</span>')
        pos = m.end()
    out.append(esc(text[pos:]))
    return ''.join(out)


def render_blocks(pos_defs: list, link) -> str:
    html = ''
    for pos, items in pos_defs:
        html += '<div class="sn">'
        if pos:
            html += f'<div class="sn-hd"><span class="pos">{esc(pos)}</span></div>'
        rendered = []
        for text, notes in items:
            li = link(text)
            if notes:
                li += ''.join(f'<span class="rn">{link(nt)}</span>' for nt in notes)
            rendered.append(li)
        if len(rendered) == 1 and not items[0][1]:
            html += f'<span class="gl">{rendered[0]}</span>'
        else:
            html += '<ol class="d">' + ''.join(f'<li>{r}</li>' for r in rendered) + '</ol>'
        html += '</div>'
    return html


# ══════════════════════════════════════════════════════════════
# Builders
# ══════════════════════════════════════════════════════════════

def _parse(tsv_path: Path, code: str, stats: dict) -> dict:
    """headword -> {'forms': [...], 'defs': [(pos, items)]} (first-seen order)."""
    entries = {}
    for hw, forms, html in read_tsv(tsv_path):
        stats['lines'] += 1
        if not hw:
            continue
        pos_defs = parse_tsv_html(html) if html.strip() else []
        if not pos_defs:
            if code == 'ko' and len(hw) == 1 and _PURE_HANJA_RE.match(hw) and \
                    any(_EUMHUN_RE.match(f) for f in forms):
                # '㐅|다섯 오': no English gloss, but the Korean meaning and
                # reading (eumhun) of the character
                stats['eumhun_only'] += 1
            else:
                stats['skipped_no_def'] += 1
                continue
        if code == 'ar':
            if all(p == 'root' for p, _ in pos_defs):
                stats['skipped_root'] += 1
                continue
            if re.fullmatch(r'[A-Za-z ]+', hw):
                # 'Ornate parentheses': an English page name, not an Arabic
                # word (﴾ and ﴿ have their own entries). Arabic written in
                # other scripts (Judeo-Arabic ר׳, Garshuni ܐܠܠܗ, Braille ⠐⠂)
                # is kept.
                stats['skipped_latin_headword'] += 1
                continue
        if code == 'ko' and pos_defs and all(p == 'rom.' for p, _ in pos_defs):
            stats['skipped_rom'] += 1
            continue
        if hw in entries:
            entries[hw]['forms'].extend(forms)
            entries[hw]['defs'].extend(pos_defs)
        else:
            entries[hw] = {'forms': list(forms), 'defs': pos_defs}
    return entries


def build_korean(entries: dict, dir_label: str, stats: dict) -> list:
    hangul = {hw for hw in entries if _HANGUL_WORD_RE.match(hw)}

    # 1. pure 'Hanja form of X' entries. A word (學生 'Hanja form of 학생')
    # becomes a redirect to X, whose Hanja line lists it with every gloss
    # of the stub. A single character stays an article: its senses (乾 sky;
    # king; (prefix) dry; …) and eumhun would otherwise be one item in the
    # Hanja line of a syllable article (건) that is mostly about other words.
    stub_targets = {}                      # hanja -> [hangul targets]
    hanja_gloss = defaultdict(dict)        # hangul -> {hanja: [glosses]}
    for hw, e in entries.items():
        if not _PURE_HANJA_RE.match(hw):
            continue
        pointers = [hanja_form_target(text) for _, items in e['defs'] for text, _ in items]
        for p in pointers:
            if p and p[0] in hangul:
                gl = hanja_gloss[p[0]].setdefault(hw, [])
                if p[1] and p[1] not in gl:
                    gl.append(p[1])
        if pointers and all(p and p[0] in hangul for p in pointers):
            stub_targets[hw] = list(dict.fromkeys(p[0] for p in pointers))
    redirect_stubs = {h: t for h, t in stub_targets.items() if len(h) >= 2}
    stats['hanja_stub_redirects'] = len(redirect_stubs)
    stats['hanja_char_stubs_kept'] = len(stub_targets) - len(redirect_stubs)

    def glosses(hw):
        return ' '.join(t for _, items in entries[hw]['defs'] for t, _ in items)

    rom_case = {}                           # lowercase -> first spelling (lookup ignores case)

    def add_rom(keys, hw):
        for k in keys:
            if english_homograph(k, glosses(hw)):
                stats['rom_keys_skipped_english'] += 1
                continue
            k = rom_case.setdefault(k.lower(), k)
            if hw not in rom_keys[k]:
                rom_keys[k].append(hw)

    # 2. per Hangul article: romanization, Hanja, inflected forms
    rom_display, rom_keys, hanja_line = {}, defaultdict(list), {}
    form_links = defaultdict(list)          # form -> [headwords]
    article_keys = set(entries) - set(redirect_stubs)
    for hw in sorted(hangul):
        e = entries[hw]
        forms = e['forms']
        display, keys = pick_korean_romanization(hw, forms)
        if display:
            rom_display[hw] = display
            add_rom(keys, hw)
    # English spellings from the glosses (kimchi -> 김치), after the RR keys
    # so that a key shared with an RR spelling keeps the RR's letter case
    for hw in sorted(hangul):
        sp = gloss_spellings(hw, [t for _, items in entries[hw]['defs'] for t, _ in items])
        add_rom(sp, hw)
        stats['gloss_spelling_keys'] += len(sp)
    # headwords with digits, Latin letters or Hanja: 4월 sawol, PC방 pissibang
    for hw in sorted(entries):
        if hw in hangul or _PURE_HANJA_RE.match(hw) or _JAMO_RE.search(hw):
            continue
        display, keys = mixed_romanization(hw, entries[hw]['forms'])
        if display:
            rom_display[hw] = display
            add_rom(keys, hw)
            stats['mixed_rom'] += 1
    # spellings found only in the bag of a 'Hanja form of' stub
    # (大韓民國|…|Daehan minguk -> 대한민국)
    for st in sorted(stub_targets):
        for t in stub_targets[st]:
            v = rr_variants(t)
            add_rom([k for c in entries[st]['forms'] if _ROM_CAND_RE.match(c) and rom_norm(c) in v
                     for k in (c, c.replace("'", '').replace('-', ''))], t)
    for hw in sorted(hangul):
        e = entries[hw]
        forms = e['forms']
        senses = [t for _, items in e['defs'] for t, _ in items]
        gl = hanja_gloss.get(hw, {})
        hj = hanja_candidates(hw, forms)
        for h in gl:
            if h not in hj:
                hj.append(h)

        def order_text(h):
            # a Hanja with no 'Hanja form of' gloss is placed by its own article
            if gl.get(h):
                return '; '.join(gl[h])
            return glosses(h) if h in article_keys and _PURE_HANJA_RE.match(h) else ''
        order = sorted(range(len(hj)), key=lambda i: (_sense_index(order_text(hj[i]), senses), i))
        hanja_line[hw] = [(hj[i], '; '.join(gl.get(hj[i], []))) for i in order]
        is_verb = any(p in ('v.', 'adj.') for p, _ in e['defs'])
        hw_words = hw.split(' ')
        for f in korean_form_candidates(hw, forms):
            if is_verb:
                ok = _ko_initial(f) == _ko_initial(hw) or f not in article_keys
                if f in article_keys and f.endswith('다') and not hw.endswith('다'):
                    ok = False      # 있다 is in the bag of 있어: no lemma -> form redirect
                if len(hw_words) > 1:
                    # phrases inflect their last word: 입이 가볍다 -> 입이 가벼워요,
                    # not the stray particle '이'
                    fw = f.split(' ')
                    ok = ok and len(fw) == len(hw_words) and fw[0] == hw_words[0]
            else:
                ok = (f not in article_keys and f not in _KO_COUNTERS and
                      (len(f) >= 2 or _ko_ini_vowel(f) == _ko_ini_vowel(hw)))
            if ok and hw not in form_links[f]:
                form_links[f].append(hw)

    # 2b. Hanja articles (not word stubs, which are redirects): romanization
    # of their Hangul reading, shown in the article and keyed when that
    # reading has no Hangul article of its own (白虎 'Hanja form of 백호':
    # baekho). Single characters also show their eumhun (乾: 하늘 건).
    eumhun = {}
    for hw in sorted(entries):
        if not _PURE_HANJA_RE.match(hw) or hw in redirect_stubs:
            continue
        e = entries[hw]
        readings = []
        for _, items in e['defs']:
            for text, _notes in items:
                p = hanja_form_target(text)
                if p and p[0] not in readings:
                    readings.append(p[0])
        if len(hw) == 1:
            eumhun[hw] = eumhun_forms(e['forms'])
            # reading syllables: '굴', and the last word of an eumhun ('다섯 오')
            extra = [f for f in e['forms'] if len(f) == 1 and _HANGUL_WORD_RE.match(f)]
            extra += [f[-1] for f in eumhun[hw]]
        else:
            extra = [f for f in e['forms'] if _HANGUL_WORD_RE.match(f)
                     and len(f.replace(' ', '')) == len(hw)]
        for f in extra:
            if f not in readings:
                readings.append(f)
        # single characters are left to their Hangul syllable entry (and
        # the Unihan / KANJIDIC2 presets): 'ae' would list dozens of them
        for i, r in enumerate(readings):
            display, keys = pick_korean_romanization(r, e['forms'])
            if display and i == 0:
                rom_display[hw] = display
            if len(hw) >= 2 and r not in hangul and len(r.replace(' ', '')) == len(hw):
                if display:
                    add_rom(keys, hw)
                    stats['hanja_rom_keyed'] += 1
                # the Hangul spelling has no article: 이론가 -> 理論家
                if hw not in form_links[r]:
                    form_links[r].append(hw)
                    stats['hanja_reading_redirects'] += 1

    # several headwords per key: the one with more senses first
    n_senses = {hw: sum(len(items) for _, items in e['defs']) for hw, e in entries.items()}
    for d in (form_links, rom_keys):
        for k in d:
            d[k].sort(key=lambda t: -n_senses.get(t, 0))

    def resolve(k):
        """Articles that the key k opens."""
        arts = [k] if k in article_keys else []
        for d in (redirect_stubs, form_links, rom_keys):
            arts += d.get(k, [])
        return arts
    can_link = link_filter(resolve)

    # 3. render
    out = []
    for hw in sorted(entries):
        if hw in redirect_stubs:
            for t in redirect_stubs[hw]:
                out.append((hw, f'@@@LINK={t}'))
            continue
        e = entries[hw]
        link = (lambda text, _hw=hw: linkify_ko(text, can_link, _hw))
        inner = f'<span class="dir">{dir_label}</span>' + headword(hw, lang='ko')
        # Hanja line only for Hangul headwords: the bag of a Hanja headword
        # holds the Hanja of its Hangul homographs (舍廊|…|思郞|…).
        hj = hanja_line.get(hw) or []
        if hj:
            parts = []
            for h, g in hj:
                label = entry_link(h) if (h in article_keys and h != hw) else esc(h)
                parts.append(label + (f' <span class="hg">{esc(g)}</span>' if g else ''))
            inner += (f'<span class="alt"{dir_attr("", "ko")}>'
                      + '<span class="sp"> · </span>'.join(parts) + '</span>')
        if eumhun.get(hw):
            inner += (f'<span class="alt"{dir_attr("", "ko")}><span class="hg">eumhun</span> '
                      + '<span class="sp"> · </span>'.join(link(x) for x in eumhun[hw])
                      + '</span>')
        if hw in rom_display:
            inner += f'<span class="rm">{esc(rom_display[hw])}</span>'
        inner += render_blocks(e['defs'], link)
        out.append((hw, wrap_entry(inner, CSS)))
    stats['articles'] = sum(1 for _, b in out if not b.startswith('@@@LINK='))
    stats['eumhun_lines'] = sum(1 for v in eumhun.values() if v)

    for f in sorted(form_links):
        for t in form_links[f]:
            out.append((f, f'@@@LINK={t}'))
    for k in sorted(rom_keys):
        for t in rom_keys[k]:
            out.append((k, f'@@@LINK={t}'))
    stats['form_redirects'] = sum(len(v) for v in form_links.values())
    stats['rom_redirects'] = sum(len(v) for v in rom_keys.values())
    return out


def _ar_headword(hw: str) -> str:
    """Arabic headwords are right to left; the few Arabic-language entries in
    other scripts get their own direction and script tag (Judeo-Arabic ר׳,
    Garshuni ܐܠܠܗ, Arabic Braille ⠐⠂)."""
    if re.search(r'[\u0590-\u05FF]', hw):
        return headword(hw, rtl=True, lang='ar-Hebr')
    if re.search(r'[\u0700-\u074F]', hw):
        return headword(hw, rtl=True, lang='ar-Syrc')
    if re.search(r'[\u2800-\u28FF]', hw):
        return headword(hw, lang='ar-Brai')
    return headword(hw, rtl=True, lang='ar')


def build_arabic(entries: dict, dir_label: str, stats: dict) -> list:
    article_keys = set(entries)
    form_links = defaultdict(list)
    readings = {}
    for hw in sorted(entries):
        forms = entries[hw]['forms']
        readings[hw] = arabic_readings(hw, forms, [p for p, _ in entries[hw]['defs']])
        for f in arabic_form_candidates(hw, forms):
            if hw not in form_links[f]:
                form_links[f].append(hw)

    # Variant spellings: hamza-less alef (اكل -> أكل), tanween on adverbs
    # (شكراً / شكرًا -> شكرا), final ى/ي and ة/ه. A variant that is already a
    # key still gets the redirect (the app shows every record of a key), but
    # comes after that key's own article and form redirects.
    real = article_keys | set(form_links)
    head_variants = defaultdict(list)       # variant of a headword -> [headwords]
    form_variants = defaultdict(list)       # variant of a form key -> [lemmas]

    def add_variant(d, v, k, targets):
        if v and v != k:
            for t in targets:
                if t not in d[v]:
                    d[v].append(t)

    for hw in sorted(article_keys):
        variants = [hw.translate(_HAMZA_FOLD)]
        # NFC puts fathatan before shadda (جِدًّا is stored as …دًّا), so look
        # at the marks only
        if hw.endswith('\u0627') and any(
                re.sub('[\u064C-\u065F\u0670]', '', f).endswith(('\u064B\u0627', '\u0627\u064B'))
                for f in entries[hw]['forms'] if ar_typable(f) == hw):
            variants += [hw[:-1] + '\u064B\u0627', hw + '\u064B']
        if hw.endswith('ي'):
            variants.append(hw[:-1] + 'ى')
        elif hw.endswith('ى'):
            variants.append(hw[:-1] + 'ي')
        if hw.endswith('ة') and hw[:-1] not in article_keys:
            # informal ه for ة, but not where stem + ه reads as 'his …'
            # (كتابه is 'his book', not كتابة)
            variants.append(hw[:-1] + 'ه')
        for v in variants:
            add_variant(head_variants, v, hw, [hw])
            add_variant(head_variants, v.translate(_HAMZA_FOLD), hw, [hw])
    for k in sorted(form_links):
        add_variant(form_variants, k.translate(_HAMZA_FOLD), k, form_links[k])

    # per key: own article, headwords spelled this way without hamza/tanween,
    # lemmas of the inflected form, then lemmas of its hamza-less spelling.
    # Among equals: for an al- form a noun before a verb (الكتب: كتاب, not
    # the verb كتب) and the word the article was added to (المدرسة:
    # مدرسة before مدرس); then the headword with more senses.
    n_senses = {hw: sum(len(items) for _, items in e['defs']) for hw, e in entries.items()}
    nominal = {hw for hw, e in entries.items() if any(p != 'v.' for p, _ in e['defs'])}

    def order(k, t):
        if k.startswith('ال'):
            bare = k[2:]
            return (t not in nominal, bare not in (t, t.translate(_HAMZA_FOLD)), -n_senses.get(t, 0))
        return (False, False, -n_senses.get(t, 0))

    links = defaultdict(list)
    for d in (head_variants, form_links, form_variants):
        for k in sorted(d):
            for t in sorted(d[k], key=lambda t, _k=k: order(_k, t)):
                if t != k and t not in links[k]:
                    links[k].append(t)
    def resolve(k):
        """Articles that the key k opens."""
        return ([k] if k in article_keys else []) + links.get(k, [])
    can_link = link_filter(resolve)
    out = []
    for hw in sorted(entries):
        e = entries[hw]
        link = (lambda text, _hw=hw: linkify_ar(text, can_link, _hw))
        inner = f'<span class="dir">{dir_label}</span>' + _ar_headword(hw)
        rd = readings.get(hw) or []
        if len(rd) > 1:
            # homographs share one article: list the readings in the order of
            # the POS blocks (a final fatha marks a perfect verb, قَلَمَ
            # qalama, otherwise a noun, قَلَم qalam), simpler stems first
            # (kataba before kattaba)
            pos_order = [p for p, _ in e['defs']]

            def rank(item):
                voc = item[0]
                is_v = bool(voc) and voc.endswith('\u064E')
                idx = next((i for i, p in enumerate(pos_order) if (p == 'v.') == is_v),
                           len(pos_order))
                # the active ḍaraba before the passive ḍuriba
                return idx, is_v and ar_passive(voc), voc.count('\u0651')
            rd = sorted(rd, key=rank)
        if rd:
            parts = []
            for voc, tl in rd:
                p = f'<span class="vz"{dir_attr("rtl", "ar")}>{esc(voc)}</span> ' if voc else ''
                parts.append(p + f'<span class="tl">{esc(tl)}</span>')
            inner += '<span class="rd">' + '<span class="sp"> · </span>'.join(parts) + '</span>'
        defs = e['defs']
        if re.match(r'^\S( \S)+$', hw):
            # spaced root ('ء ر ض'): the other blocks list derived words
            defs = [(p if p == 'root' else f'derived {p}', items) for p, items in defs]
        inner += render_blocks(defs, link)
        out.append((hw, wrap_entry(inner, CSS)))
    stats['articles'] = len(out)
    for k in sorted(links):
        for t in links[k]:
            out.append((k, f'@@@LINK={t}'))
    stats['form_redirects'] = sum(len(v) for v in form_links.values())
    stats['redirects'] = sum(len(v) for v in links.values())
    stats['with_readings'] = sum(1 for v in readings.values() if v)
    return out


def write_entries(records: list, txt_path: Path) -> int:
    """Write records grouped by key: each key's article first, then redirects."""
    by_key = defaultdict(list)
    for k, body in records:
        by_key[k].append(body)
    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for k in sorted(by_key):
            bodies = sorted(by_key[k], key=lambda b: b.startswith('@@@LINK='))
            for body in bodies:
                f.write(f"{k}\n{body}\n</>\n")
                count += 1
    return count


def _dict_name(lang: dict) -> str:
    """Display name of a language's dictionary ("Wiktionary Korean-English")."""
    return f"Wiktionary {lang['name_en']}-English"


def header_description(lang: dict) -> str:
    """The MDX header description of a language's dictionary, in the shared layout."""
    src = (f"{UPSTREAM_REPO}/blob/{UPSTREAM_COMMIT}/"
           + lang['upstream_file'].replace(' ', '%20'))
    return description_html(
        title=f"{_dict_name(lang)} Dictionary",
        about=[f"{lang['name_en']}→English glosses from the English Wiktionary "
               f"(snapshot of November 2022), with {lang['features']}."],
        source=('<a href="https://en.wiktionary.org/">English Wiktionary</a> contributors, '
                f'via <a href="{src}">Vuizur/Wiktionary-Dictionaries</a> '
                f"(commit {UPSTREAM_COMMIT[:10]}, {UPSTREAM_DATE}), built from "
                '<a href="https://kaikki.org/">kaikki.org</a>/Wiktextract data.'),
        license=('Dual-licensed under '
                 '<a href="https://creativecommons.org/licenses/by-sa/3.0/">CC BY-SA 3.0 Unported</a> '
                 'and the <a href="https://www.gnu.org/licenses/fdl-1.3.html">GNU Free Documentation License</a>, '
                 'as Wiktionary text was at the time.'),
        changes=lang['changes'],
    )


def descriptions() -> dict[str, str]:
    """Header description of every dictionary this script builds, by MDX file name."""
    return {f"Wiktionary-{lang['code'].upper()}-EN.mdx": header_description(lang)
            for lang in LANGUAGES.values()}


# ── Main build logic ───────────────────────────────────────────

def build_language(lang_code: str):
    """Build MDX for a single language."""
    lang = LANGUAGES[lang_code]
    code = lang['code']
    name_en = lang['name_en']
    dir_label = f'{lang["flag"]} {lang["name_native"]} → English {FLAG_EN}'

    tsv_path = DATA_DIR / lang['tsv_file']
    if not tsv_path.exists():
        print(f"ERROR: {tsv_path} not found")
        return None, None

    print(f"\n{'='*60}")
    print(f"Building Wiktionary-{code.upper()}-EN ({name_en}-English)")
    print(f"{'='*60}")
    print(f"Parsing {lang['tsv_file']}...")
    stats = defaultdict(int)
    entries = _parse(tsv_path, code, stats)
    if code == 'ko':
        records = build_korean(entries, dir_label, stats)
    else:
        records = build_arabic(entries, dir_label, stats)
    for k, v in stats.items():
        print(f"  {k}: {v:,}")

    dict_dir = OUTPUT_DIR / f"Wiktionary-{code.upper()}-EN"
    dict_dir.mkdir(parents=True, exist_ok=True)
    txt_path = dict_dir / f"wiktionary_{code}_entries.txt"
    print(f"Generating entries → {txt_path}...")
    count = write_entries(records, txt_path)
    print(f"  {count:,} total entries written ({stats['articles']:,} articles)")

    dict_name = _dict_name(lang)
    mdx_path = dict_dir / f"Wiktionary-{code.upper()}-EN.mdx"
    success, size_mb, _ = pack_mdx(txt_path, dict_name, header_description(lang),
                                   mdx_path, inputs=[tsv_path])
    if not success:
        return None, None
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB ({count} entries)")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name=dict_name,
        description=lang['catalog_description'],
        direction={"src": code.upper(), "dest": ["EN"]},
        entries=count,
        license="CC-BY-SA-3.0 OR GFDL-1.3-or-later",
        data_source="English Wiktionary via Vuizur/Wiktionary-Dictionaries (2022-11)",
        tier=3,
    )
    return mdx_path, {k: b for k, b in records if not b.startswith('@@@LINK=')}


# ── Entry point ────────────────────────────────────────────────

SAMPLE_WORDS = {
    'ko': ['안녕하세요', '사랑', '한국', '학생', '시간', '역사', '먹다', '하다', '진', '물', '컴퓨터'],
    'ar': ['مرحبا', 'كتاب', 'كتب', 'ماء', 'قلم', 'ابن', 'أكل', 'شكرا', 'عربي', 'ء ر ض'],
}


def _generate_preview(lang_code: str, records: dict):
    lang = LANGUAGES[lang_code]
    html = [records[w] for w in SAMPLE_WORDS.get(lang_code, [])
            if w in records and not records[w].startswith('@@@LINK=')]
    dict_dir = OUTPUT_DIR / f"Wiktionary-{lang_code.upper()}-EN"
    _shared_preview(html, dict_dir / f"wiktionary_{lang_code}_preview.html",
                    f'Wiktionary {lang["name_en"]}→English — preview')


def main():
    langs = sys.argv[1:] if len(sys.argv) > 1 else list(LANGUAGES.keys())
    for code in langs:
        if code not in LANGUAGES:
            print(f"Unknown language: {code}")
            print(f"Supported: {', '.join(LANGUAGES.keys())}")
            continue
        mdx, records = build_language(code)
        if mdx:
            _generate_preview(code, records)


if __name__ == '__main__':
    main()
