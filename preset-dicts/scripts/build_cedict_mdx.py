#!/usr/bin/env python3
"""
Build CC-CEDICT MDX dictionary from cedict_ts.u8 source.

Usage:
    python build_cedict_mdx.py

Input:  ../data/cedict_ts.u8
Output: ../output/CEDICT-ZH-EN/CEDICT-ZH-EN.mdx

Keys
    * every Simplified headword gets one article with all of its readings;
    * a Traditional form that is also a Simplified headword (於, 乾, 著 ...)
      gets those readings merged into its own article;
    * a Traditional form with several Simplified counterparts (參, 餘, 麼 ...)
      gets an article of exactly its rows;
    * every other Traditional form is an @@@LINK to its Simplified article;
    * @@@LINK aliases for headwords typed without their punctuation
      (一不做二不休, 乔治华盛顿) and for multi-character words typed with the
      Taiwan / Hong Kong variant characters that CC-CEDICT itself lists as
      "variant of" (汙染, 祕密, 爲了, 説話, 甚麼 ...).
    Readings inside an article are ordered real meanings first, then
    surname-only readings, then variant / "used in" / "see" stubs; ties go
    to the reading used in more CC-CEDICT compounds.
"""

import itertools
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, ORDERED_LIST, TEXT_SECONDARY, TEXT_LINK
from shared.html import esc, esc_attr, wrap_entry
from shared.build import (pack_mdx, generate_preview as _shared_preview, write_catalog_metadata,
                          description_html)

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "CEDICT-ZH-EN"
CEDICT_FILE = DATA_DIR / "cedict_ts.u8"


# ── Pinyin tone conversion ─────────────────────────────────────

TONE_MARKS = {
    'a': 'āáǎàa', 'e': 'ēéěèe', 'i': 'īíǐìi',
    'o': 'ōóǒòo', 'u': 'ūúǔùu', 'ü': 'ǖǘǚǜü',
    'A': 'ĀÁǍÀA', 'E': 'ĒÉĚÈE', 'I': 'ĪÍǏÌI',
    'O': 'ŌÓǑÒO', 'U': 'ŪÚǓÙU', 'Ü': 'ǕǗǙǛÜ',
}
# Syllabic m / n (呣 m2, 嘸 m2, 姆 m1, 哼 hng): the mark goes on the nasal.
NASAL_MARKS = {
    'm': ('m̄', 'ḿ', 'm̌', 'm̀'),
    'M': ('M̄', 'Ḿ', 'M̌', 'M̀'),
    'n': ('n̄', 'ń', 'ň', 'ǹ'),
    'N': ('N̄', 'Ń', 'Ň', 'Ǹ'),
}

# CC-CEDICT writes ü as "u:" (nu:3, lu:e4); "v" is accepted as well.
_SYLLABLE_RE = re.compile(r'([A-Za-züÜ]+)([1-5])')


def _normalize_u(syllable: str) -> str:
    return (syllable.replace('u:', 'ü').replace('U:', 'Ü')
            .replace('v', 'ü').replace('V', 'Ü'))


def _pinyin_syllable_to_unicode(syllable: str) -> str | None:
    """'zhong1' -> 'zhōng', 'nu:3' -> 'nǚ', 'm2' -> 'ḿ', 'de5' -> 'de'.

    Returns the token unchanged when it is not a numbered syllable
    ('A', ',', '·'), and None for 'xx5' (CC-CEDICT's "no known reading").
    """
    match = _SYLLABLE_RE.fullmatch(_normalize_u(syllable))
    if not match:
        return syllable
    base, tone = match.group(1), int(match.group(2))
    if base.lower() == 'xx':
        return None
    if tone == 5:
        return base
    for i, ch in enumerate(base):
        if ch in 'aeAE':
            return base[:i] + TONE_MARKS[ch][tone - 1] + base[i + 1:]
    if 'ou' in base.lower():
        for i, ch in enumerate(base):
            if ch in 'oO':
                return base[:i] + TONE_MARKS[ch][tone - 1] + base[i + 1:]
    for i in range(len(base) - 1, -1, -1):
        if base[i] in 'iouüIOUÜ':
            return base[:i] + TONE_MARKS[base[i]][tone - 1] + base[i + 1:]
    for i, ch in enumerate(base):
        if ch in NASAL_MARKS:
            return base[:i] + NASAL_MARKS[ch][tone - 1] + base[i + 1:]
    return base


_ATTACHED_PUNCT = {',', '，'}       # 'zuo4 , er4' -> 'zuò, èr'


def pinyin_to_unicode(pinyin_numbered: str) -> str:
    """'ni3 hao3' -> 'nǐ hǎo'; erhua 'r5' joins the previous syllable
    ('wan2 r5' -> 'wánr'); a comma joins the previous syllable too;
    'xx5' placeholders are dropped."""
    out: list[str] = []
    for token in pinyin_numbered.split():
        if token in ('r5', 'R5') and out and out[-1][-1:].isalpha():
            out[-1] += token[0]
            continue
        if token in _ATTACHED_PUNCT and out:
            out[-1] += ','
            continue
        conv = _pinyin_syllable_to_unicode(token)
        if conv is not None:
            out.append(conv)
    return ' '.join(out)


def _syllable_base(token: str) -> str | None:
    m = _SYLLABLE_RE.fullmatch(_normalize_u(token))
    return m.group(1).lower() if m else None


# ── CC-CEDICT parser ──────────────────────────────────────────

_LINE_RE = re.compile(r'^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+/(.+)/$')


def parse_cedict(filepath: Path):
    """Parse a CC-CEDICT (V1 syntax) file.

    Returns (rows, header) with rows = [(trad, simp, pinyin_numbered, defs)]
    and header = the '#! key=value' metadata. Fails loudly instead of
    silently skipping lines: every data line must parse, and the row count
    must equal the header's '#! entries='.
    """
    rows: list[tuple[str, str, str, list[str]]] = []
    header: dict[str, str] = {}
    bad: list[tuple[int, str]] = []
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip('\r\n')
            if not line.strip():
                continue
            if line.startswith('#'):
                if line.startswith('#!') and '=' in line:
                    k, _, v = line[2:].partition('=')
                    header[k.strip()] = v.strip()
                continue
            m = _LINE_RE.match(line)
            if not m or '[[' in line:
                bad.append((lineno, line))
                continue
            trad, simp, pinyin_raw, defs_str = m.groups()
            definitions = [d.strip() for d in defs_str.split('/') if d.strip()]
            rows.append((trad, simp, pinyin_raw, definitions))
    if bad:
        hint = (" (CC-CEDICT V2 syntax '[[...]]' is not supported; use the V1 export)"
                if any('[[' in l for _, l in bad) else '')
        sample = '\n'.join(f'    line {n}: {l[:120]}' for n, l in bad[:5])
        raise SystemExit(f"ERROR: {len(bad)} unparsable CC-CEDICT lines{hint}:\n{sample}")
    expected = header.get('entries')
    if expected is not None and int(expected) != len(rows):
        raise SystemExit(f"ERROR: parsed {len(rows)} rows but the header says "
                         f"entries={expected}")
    if not rows:
        raise SystemExit(f"ERROR: no CC-CEDICT rows in {filepath}")
    return rows, header


def read_referenced_works(filepath: Path) -> list[str]:
    """The upstream '# Referenced works:' copyright lines, verbatim."""
    lines, on = [], False
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        for line in f:
            if not line.startswith('#'):
                break
            text = line[1:].strip()
            if text.lower().startswith('referenced works'):
                on = True
                continue
            if on:
                if not text:
                    break
                lines.append(text)
    return lines


# ── Reading order (real meanings first) ───────────────────────

_NOTE_RE = re.compile(r'^(?:Taiwan pr\.|also pr\.|pr\.|CL:)')
_STUB_RE = re.compile(
    r'^(?:\([^()]*\)\s*)*'
    r'(?:(?:[A-Za-z-]+\s+){0,3}variant of|used in|see|see also|also written|same as|'
    r'(?:old|archaic|ancient) form of)\b', re.IGNORECASE)
_SURNAME_RE = re.compile(
    r'^(?:surname\b|\(?used as a surname|\(?used in given names and as a surname|'
    r'\(used as a surname and in given names\))', re.IGNORECASE)


def reading_rank(defs: list[str]) -> int:
    """0 = real meaning, 1 = surname / given-name only, 2 = variant stub."""
    content = [d for d in defs if not _NOTE_RE.match(d)]
    surname = [bool(_SURNAME_RE.match(d)) for d in content]
    stub = [not s and bool(_STUB_RE.match(d)) for d, s in zip(content, surname)]
    if all(stub):
        return 2
    if all(a or b for a, b in zip(surname, stub)):
        return 1
    return 0


def compound_counts(rows) -> Counter:
    """How many multi-character headwords use (trad char, simp char, syllable)."""
    counts: Counter = Counter()
    for trad, simp, pinyin, _ in rows:
        syl = pinyin.split()
        if len(trad) < 2 or len(syl) != len(trad) or len(simp) != len(trad):
            continue
        for i in range(len(trad)):
            counts[(trad[i], simp[i], _normalize_u(syl[i]))] += 1
    return counts


# ── HTML generation (V3: compact, direction labels as top bar) ─

FLAG_CN = '\U0001F1E8\U0001F1F3\U0001F1F9\U0001F1FC'  # 🇨🇳🇹🇼
FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_CN} 中文 → English {FLAG_EN}'

CSS = get_css(
    ORDERED_LIST,
    extra_light=(
        '.s{font-size:1.7em;font-weight:600;display:block}'
        f'.t{{font-size:1.25em;color:{TEXT_SECONDARY[0]};display:block;margin-top:2px}}'
        f'.p{{font-size:1.25em;color:{TEXT_LINK[0]};font-style:italic;display:block;margin-top:2px}}'
    ),
    extra_dark=(
        f'.t{{color:{TEXT_SECONDARY[1]}}}.p{{color:{TEXT_LINK[1]}}}'
    ),
)


# Cross-references follow CC-CEDICT's own grammar: TRAD|SIMP[pin1 yin1],
# WORD[pin1 yin1], TRAD|SIMP or a bare WORD. A word is a run of CJK
# characters (incl. Extension B+ and the ·，、－： that headwords contain)
# that may carry Latin letters/digits (T恤, 3C, 九價HPV疫苗); a purely
# Latin token counts only when a [pinyin] follows it ('see 3C[san1 C]'),
# so 'abbr. for Beijing 北京' links 北京, not the key 'B'.
_CJK = ('⺀-⿟々〇〡-〩〸-〻㄀-ㄯ'
        'ㆠ-ㆿ㐀-䶿一-鿿豈-﫿\U00020000-\U0003ffff')
_PUNCT = '·，、－：'          # · ， 、 － ：
_RUN = f'[{_CJK}{_PUNCT}A-Za-z0-9Ͱ-Ͽ]+'
_REF_RE = re.compile(rf'({_RUN})(?:\|({_RUN}))?(\[[^\[\]]*\])?')
_HAS_CJK = re.compile(f'[{_CJK}]')
_LATIN_EDGE = re.compile(r'^([A-Za-z0-9Ͱ-Ͽ]*)(.*?)([A-Za-z0-9Ͱ-Ͽ]*)$', re.S)
# Kana / full-width letters right before or after a run: part of a
# Japanese or full-width word (うｐ主), not a reference.
_FOREIGN_NEIGHBOR = re.compile('[぀-ヿ０-９Ａ-Ｚａ-ｚ]')
# Characters cited as Japanese / Taiwanese / Cantonese words, not Mandarin.
_FOREIGN_CONTEXT = re.compile(
    r'\b(?:Japanese|Taiwanese|Cantonese|Korean|Hokkien|Hakka|Shanghainese|Teochew|'
    r'Vietnamese|Okinawan)\s*:?\s*$')
_BRACKET_RE = re.compile(r'\[([^\[\]]+)\]')
_BROKEN_UMLAUT = re.compile(r'\b([A-Za-z]+) : ([1-5])\b')   # upstream '[lu : 4]'
_PINYIN_PUNCT = {',', '·', ':', '-', '，', '：', '…'}
_NON_PINYIN_TOKEN = re.compile(r'[A-Z0-9]+|[\u0370-\u03ff]+')   # 'C' in [san1 C], 'γ'
_PIECE_RE = re.compile(r'[A-Za-zü:]+?[1-5]|-')
# Syllables CC-CEDICT uses in definitions but never in a headword reading.
EXTRA_SYLLABLES = {'yai'}          # 崖 Taiwan pr. [yai2]


class Linker:
    """Renders definition text: cross-reference links, tone-mark pinyin."""

    def __init__(self, article_keys: set[str], redirects: dict[str, str],
                 valid_syllables: set[str]):
        self.article_keys = article_keys
        self.redirects = redirects            # LINK key -> article key
        self.valid = (valid_syllables | EXTRA_SYLLABLES) - {'xx'}
        self.links = 0
        self.self_refs = 0

    # -- pinyin in [brackets] ----------------------------------
    def _token(self, tok: str) -> tuple[str, bool] | None:
        """(converted, is_pinyin) for one bracket token, None if not pinyin.
        Run-together syllables ('xia4hai2', 'yi1mo2-yi1yang4') are
        converted piece by piece; 'xx5' (unknown syllable) becomes '…'.
        A capitalised one-vowel syllable ('A1', 'E4') is pinyin; other
        capitals and digits ('C' in [san1 C], 'HPV', '3') pass through."""
        if tok in _PINYIN_PUNCT:
            return tok, False
        pieces = _PIECE_RE.findall(tok)
        if pieces and ''.join(pieces) == tok:
            out = []
            for piece in pieces:
                if piece == '-':
                    out.append(piece)
                    continue
                base = _syllable_base(piece)
                if base == 'xx':
                    out.append('…')
                elif base in self.valid:
                    out.append(_pinyin_syllable_to_unicode(piece))
                else:
                    break
            else:
                return ''.join(out), True
        if _NON_PINYIN_TOKEN.fullmatch(tok):
            return tok, False
        return None

    def bracket_pinyin(self, content: str) -> str | None:
        """Tone-mark the content of a [..] if it is numbered Mandarin pinyin."""
        content = _BROKEN_UMLAUT.sub(r'\1:\2', content)
        out: list[str] = []
        seen = False
        for tok in content.split():
            conv = self._token(tok)
            if conv is None:
                return None
            text, is_pinyin = conv
            seen = seen or is_pinyin
            if tok in ('r5', 'R5') and out and out[-1][-1:].isalpha():
                out[-1] += text          # erhua: 'wan2 r5' -> 'wánr'
            elif tok in _ATTACHED_PUNCT and out:
                out[-1] += ','           # 'zuo4 , er4' -> 'zuò, èr'
            else:
                out.append(text)
        return ' '.join(out) if seen else None

    def text(self, raw: str) -> str:
        """Escape plain text, tone-marking stand-alone [pinyin]."""
        out, last = [], 0
        for m in _BRACKET_RE.finditer(raw):
            conv = self.bracket_pinyin(m.group(1))
            if conv is None:
                continue
            out.append(esc(raw[last:m.start()]))
            out.append(esc(f'[{conv}]'))
            last = m.end()
        out.append(esc(raw[last:]))
        return ''.join(out)

    # -- references --------------------------------------------
    def resolve(self, word: str) -> str | None:
        """Article key a reference to `word` should open, or None."""
        if not word or '#' in word:
            return None
        if word in self.article_keys:
            return word
        return self.redirects.get(word)

    def _link(self, target: str, label: str, current: str) -> str:
        if target == current:
            self.self_refs += 1
            return esc(label)
        self.links += 1
        return f'<a href="entry://{esc_attr(target)}">{esc(label)}</a>'

    def _word(self, word: str, current: str, allow_bare: bool) -> str:
        """A single run without |/[]: link it (or its punctuation-separated
        parts) when it is a headword; otherwise plain text."""
        if not allow_bare or not _HAS_CJK.search(word):
            return esc(word)
        target = self.resolve(word)
        if target:
            return self._link(target, word, current)
        lead, core, tail = _LATIN_EDGE.match(word).groups()
        if (lead or tail) and core and _HAS_CJK.search(core):
            target = self.resolve(core)
            if target:
                return esc(lead) + self._link(target, core, current) + esc(tail)
        if any(p in word for p in _PUNCT):
            parts = re.split(f'([{_PUNCT}])', word)
            return ''.join(p if p in _PUNCT else self._word(p, current, True)
                           for p in parts)
        return esc(word)

    def render(self, raw: str, current: str) -> str:
        """HTML for one definition of the article keyed `current`."""
        out, last = [], 0
        for m in _REF_RE.finditer(raw):
            first, second, py = m.groups()
            if not (_HAS_CJK.search(first) or py or second):
                continue                       # an English word
            before = raw[m.start() - 1] if m.start() else ''
            after = raw[m.end()] if m.end() < len(raw) else ''
            if _FOREIGN_NEIGHBOR.match(before) or (_FOREIGN_NEIGHBOR.match(after) and not py):
                continue
            out.append(self.text(raw[last:m.start()]))
            last = m.end()
            py_html = ''
            if py:
                conv = self.bracket_pinyin(py[1:-1])
                py_html = esc(f'[{conv}]' if conv is not None else py)
            foreign = not py and bool(_FOREIGN_CONTEXT.search(raw[:m.start()]))
            if second is not None:
                label = f'{first}|{second}'
                target = None
                if not foreign and (_HAS_CJK.search(first + second) or py):
                    target = self.resolve(second) or self.resolve(first)
                out.append((self._link(target, label, current) if target else esc(label))
                           + py_html)
            elif py:
                target = self.resolve(first) if (_HAS_CJK.search(first)
                                                 or first in self.article_keys) else None
                out.append((self._link(target, first, current) if target
                            else self._word(first, current, True)) + py_html)
            else:
                out.append(self._word(first, current, not foreign))
        out.append(self.text(raw[last:]))
        return ''.join(out)


def make_article(key: str, parts: list[tuple[str, str, str, list[str]]],
                 linker: Linker) -> str:
    """One article: every reading in `parts` = [(trad, simp, pinyin, defs)]."""
    sections = []
    for i, (trad, simp, pinyin, defs) in enumerate(parts):
        defs_html = ''.join(f'<li>{linker.render(d, key)}</li>' for d in defs)
        py = pinyin_to_unicode(pinyin)
        section = f'<span class="dir">{DIR_LABEL}</span>' if i == 0 else ''
        section += f'<span class="s">{esc(simp)}</span>'
        if trad != simp:
            section += f'<span class="t">{esc(trad)}</span>'
        if py:
            section += f'<span class="p">{esc(py)}</span>'
        section += f'<div class="sn"><ol class="d">{defs_html}</ol></div>'
        sections.append(section)
    return wrap_entry('<hr class="sep">'.join(sections), CSS)


# ── Lookup aliases ────────────────────────────────────────────

def strip_punct(word: str) -> str:
    return re.sub(f'[{_PUNCT}]', '', word)


# Variant characters that Taiwan (MOE standard forms) or Hong Kong text
# uses where CC-CEDICT's Traditional headwords use another character. Only
# CC-CEDICT's own mapping is applied, per reading: a row 'V V [py] /variant
# of X[py]/' turns X into V wherever X is read py in a headword, so 甚
# replaces 什 only in shén (甚麼) and 衹 replaces 只 only in zhǐ.
FOLD_VARIANTS = frozenset(
    '汙祕脣溼綑唸甚衹祇喫'            # Taiwan standard / common forms
    '啓衞爲説衆麪羣歎綫峯牀僞敍産鷄裏録'  # Hong Kong / OpenCC forms
    '粧鈎舖嫺綉癡搾啣蹟勛'
)
_VARIANT_OF_RE = re.compile(r'^(?:Japanese )?variant of (\S)(?:\|\S)?\[([^\]\s]+)\]')
# Pairs CC-CEDICT gives as a meaning rather than as 'variant of':
# 妳 [ni3] 'you (used in Taiwan to address females)', so 妳好 finds 你好.
EXTRA_FOLDS = {('你', 'ni3'): {'妳'}}
# A variant that stands for only one sense of its standard character is
# applied only to headwords with that sense: 唸 is 念 'to read aloud'
# (唸書, 唸經, 唸咒), never 念 'to think of' (紀念, 概念, 想念).
FOLD_SENSE = {'唸': re.compile(r'\b(?:read|recit|chant|stud|incant)', re.IGNORECASE)}
MAX_FOLD_COMBOS = 16


def variant_table(rows) -> dict[tuple[str, str], set[str]]:
    table: dict[tuple[str, str], set[str]] = defaultdict(set)
    for key, variants in EXTRA_FOLDS.items():
        table[key] |= variants
    for trad, simp, pinyin, defs in rows:
        if trad not in FOLD_VARIANTS or not defs:
            continue
        m = _VARIANT_OF_RE.match(defs[0])
        if not m or m.group(1) == trad:
            continue
        if _normalize_u(m.group(2)).lower() != _normalize_u(pinyin).lower():
            continue
        table[(m.group(1), _normalize_u(pinyin).lower())].add(trad)
    return table


def variant_spellings(trad: str, pinyin: str, defs: list[str], table) -> list[str]:
    syl = pinyin.split()
    if len(trad) < 2 or len(syl) != len(trad):
        return []
    gloss = ' / '.join(defs)
    opts = [[c] + sorted(v for v in table.get((c, _normalize_u(syl[i]).lower()), ())
                         if v not in FOLD_SENSE or FOLD_SENSE[v].search(gloss))
            for i, c in enumerate(trad)]
    total = 1
    for o in opts:
        total *= len(o)
    if total == 1:
        return []
    if total <= MAX_FOLD_COMBOS:
        forms = {''.join(c) for c in itertools.product(*opts)}
    else:   # each single substitution, plus every position substituted
        forms = {trad[:i] + v + trad[i + 1:] for i, o in enumerate(opts) for v in o[1:]}
        forms.add(''.join(o[-1] for o in opts))
    forms.discard(trad)
    return sorted(forms)


# ── Preview ───────────────────────────────────────────────────

SAMPLE_WORDS = ['你好', '电脑', '美丽', '水', '跑', '中国', '於', '乾', '女', '京', '參']


def _generate_preview(articles: dict[str, str]):
    """Generate a preview HTML for visual review."""
    entries_html = [articles[hw] for hw in SAMPLE_WORDS if hw in articles]
    preview_path = OUTPUT_DIR / "cedict_preview.html"
    _shared_preview(entries_html, preview_path, 'CC-CEDICT — preview')


# ── Header description ────────────────────────────────────────

def header_description(release: str, entries: int) -> str:
    """The MDX header description in the shared layout (shared.build.description_html).

    Args:
        release: CC-CEDICT release date, the first 10 characters of the
            header's '#! date=' value ('' when the header has none).
        entries: Number of CC-CEDICT rows in the data file.
    """
    works = ''.join(f"<br>{esc(w)}" for w in read_referenced_works(CEDICT_FILE))
    return description_html(
        title="CC-CEDICT Chinese-English Dictionary",
        about=[f"The community-maintained free Chinese-English dictionary: {entries:,} entries."],
        source=((f"CC-CEDICT release {release}" if release else "CC-CEDICT") + ", published by MDBG: "
                '<a href="https://www.mdbg.net/chinese/dictionary?page=cc-cedict">mdbg.net</a> · '
                '<a href="https://cc-cedict.org/wiki/">cc-cedict.org</a>.'
                + (f" Referenced works:{works}" if works else "")),
        license=('<a href="https://creativecommons.org/licenses/by-sa/4.0/">'
                 "Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)</a>."),
        changes="readings grouped and reordered by headword, pinyin shown with tone marks, "
                "cross-references linked, and lookup redirects added for Traditional, variant "
                "and punctuation-free spellings",
        adaptation_license="The modified data is shared under the same license.",
    )


def descriptions() -> dict[str, str]:
    """{"<Name>.mdx": header description} for every dictionary this script builds.

    Reads the release date and row count from CEDICT_FILE the way the build
    does (parse_cedict, well under a second); nothing is built.
    """
    rows, header = parse_cedict(CEDICT_FILE)
    return {"CEDICT-ZH-EN.mdx": header_description(header.get('date', '')[:10], len(rows))}


# ── Main ──────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Parsing CC-CEDICT...")
    rows, header = parse_cedict(CEDICT_FILE)
    release = header.get('date', '')[:10]
    print(f"  {len(rows)} rows (header entries={header.get('entries')}, date={header.get('date')})")

    valid_syllables = {b for _, _, p, _ in rows for t in p.split()
                       if (b := _syllable_base(t)) is not None}
    counts = compound_counts(rows)

    by_simp: dict[str, list[int]] = defaultdict(list)
    by_trad: dict[str, list[int]] = defaultdict(list)
    for i, (trad, simp, _, _) in enumerate(rows):
        by_simp[simp].append(i)
        if trad != simp:
            by_trad[trad].append(i)

    def order(idxs):
        def sort_key(i):
            trad, simp, pinyin, defs = rows[i]
            n = counts.get((trad, simp, _normalize_u(pinyin)), 0) if len(trad) == 1 else 0
            return (reading_rank(defs), -n, i)
        return sorted(dict.fromkeys(idxs), key=sort_key)

    # Articles: every Simplified headword, with the rows of the same
    # spelling used as a Traditional form merged in (於 gets 於→于 yú).
    article_rows: dict[str, list[int]] = {}
    merged_trad = 0
    for simp, idxs in by_simp.items():
        extra = by_trad.get(simp, [])
        merged_trad += len(extra)
        article_rows[simp] = order(idxs + extra)

    # Traditional-only forms: a redirect when they map to one Simplified
    # headword, an article of exactly their rows when they map to several.
    redirects: dict[str, str] = {}
    multi_trad = 0
    for trad, idxs in by_trad.items():
        if trad in article_rows:
            continue
        targets = list(dict.fromkeys(rows[i][1] for i in idxs))
        if len(targets) == 1:
            redirects[trad] = targets[0]
        else:
            article_rows[trad] = order(idxs)
            multi_trad += 1

    article_keys = set(article_rows)
    print(f"  {len(by_simp)} simplified headwords; {merged_trad} traditional readings merged "
          f"into same-spelling articles; {multi_trad} traditional forms with several "
          f"simplified forms; {len(redirects)} traditional redirects")

    # Aliases: punctuation-free spellings, then Taiwan/HK variant spellings.
    aliases: dict[str, list[str]] = defaultdict(list)    # alias -> [article keys]

    def add_alias(alias: str, target: str):
        if alias and alias != target and target not in aliases[alias]:
            aliases[alias].append(target)

    for key in sorted(article_keys | set(redirects)):
        bare = strip_punct(key)
        if bare != key:
            add_alias(bare, redirects.get(key, key))
    n_punct = len(aliases)

    table = variant_table(rows)
    taken = article_keys | set(redirects) | set(aliases)
    for trad, simp, pinyin, defs in rows:
        for form in variant_spellings(trad, pinyin, defs, table):
            if form not in taken:
                add_alias(form, simp)
    aliases = {k: v for k, v in aliases.items() if v}
    print(f"  {n_punct} punctuation-free aliases, {len(aliases) - n_punct} variant-spelling "
          f"aliases ({len(table)} variant readings)")

    # Write mdict source file
    linker = Linker(article_keys, redirects, valid_syllables)
    txt_path = OUTPUT_DIR / "cedict_entries.txt"
    print(f"Writing → {txt_path}...")
    articles: dict[str, str] = {}
    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for key in sorted(article_rows):
            html = make_article(key, [rows[i] for i in article_rows[key]], linker)
            if key in SAMPLE_WORDS:
                articles[key] = html
            f.write(f"{key}\n{html}\n</>\n")
            count += 1
        for key in sorted(redirects):
            f.write(f"{key}\n@@@LINK={redirects[key]}\n</>\n")
            count += 1
        for key in sorted(aliases):
            for target in aliases[key]:
                f.write(f"{key}\n@@@LINK={target}\n</>\n")
                count += 1
    print(f"  {count} total entries written ({len(article_rows)} articles, "
          f"{count - len(article_rows)} redirects); {linker.links} cross-reference links, "
          f"{linker.self_refs} self-references left unlinked")

    # Pack MDX
    mdx_path = OUTPUT_DIR / "CEDICT-ZH-EN.mdx"
    desc_html = header_description(release, len(rows))
    success, size_mb, _ = pack_mdx(txt_path, "CC-CEDICT Chinese-English", desc_html, mdx_path,
                                   inputs=[CEDICT_FILE])
    if not success:
        raise SystemExit("ERROR: mdict packing failed")
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB")

    release_note = f" (CC-CEDICT release {release})" if release else ""
    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="CC-CEDICT Chinese-English",
        description=("Community-maintained Chinese-English dictionary with pinyin, "
                     "traditional/simplified characters, and English definitions"
                     f"{release_note}."),
        direction={"src": "ZH", "dest": ["EN"]},
        entries=count,
        license="CC-BY-SA-4.0",
        data_source="CC-CEDICT",
        tier=2,
    )

    # Generate preview
    _generate_preview(articles)


if __name__ == '__main__':
    main()
