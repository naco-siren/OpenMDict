#!/usr/bin/env python3
"""
Build the JMdict (Japanese-English) MDX dictionary.

Features:
  - One article per JMdict entry, reachable from EVERY written form and
    reading (kanji, kana, search-only forms), plus half-width (NFKC),
    no-middle-dot and hiragana spellings of katakana words
  - Homophones and homographs ordered by JMdict priority (common words first)
  - Romaji (Hepburn) for English-speaking users
  - Pitch accent from Kanjium (CC BY-SA 4.0), all variants, odaka marked
  - Usage labels, dialects, notes, loanword sources, sense restrictions
    and alternate spellings / readings
  - Dark mode support

How the app looks a word up (the record layout below depends on it):
  * every record whose key matches the query (ignoring case) is shown,
    exact-case first, then in MDX order, joined with a separator;
  * a record "@@@LINK=X" shows the FIRST record of key X (one level only:
    X's first record must be an article, never another link).
So each entry's article lives under its display headword; every other form
gets a @@@LINK to that headword when the entry is the first record there,
or a copy of the article when it is not (homographs, e.g. 刑事 でか/けいじ).
Records under one key are written in priority order; the packer's key sort
is stable, so that order survives into the MDX.

Usage:
    python build_jmdict_mdx.py

Input:  ../data/jmdict/<JMDICT_RELEASE>/JMdict_e.gz (pinned below),
        ../data/kanjium_accents.txt
Output: ../output/JMdict-JA-EN/JMdict-JA-EN.mdx

Updating the data (EDRDG licence section 4 requires a regular refresh from
the latest release): fetch the current JMdict_e.gz into
data/jmdict/<its "JMdict created" date>/, set JMDICT_RELEASE and
JMDICT_SHA256 below, rebuild. The build warns once the pinned release is
older than MAX_DATA_AGE_DAYS.
"""

import datetime
import gzip
import hashlib
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import (get_css, GLOSS, ORDERED_LIST, DOMAIN_BADGE,
                          TEXT_SECONDARY, TEXT_LINK)
from shared.html import (esc, entry_link, has_rtl, rtl_span, kana_to_romaji_morae,
                         split_morae, _KATA_TO_HIRA)
from shared.build import (pack_mdx, generate_preview as _shared_preview,
                          write_catalog_metadata, description_html)

DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "JMdict-JA-EN"

# Pinned upstream data. JMdict_e.gz is a daily, unversioned file at
# JMDICT_URL; the release is identified by its "JMdict created" date.
JMDICT_URL = "https://www.edrdg.org/pub/Nihongo/JMdict_e.gz"
JMDICT_RELEASE = "2026-10-27"
JMDICT_SHA256 = "aacc8703771759ad302f01199db13e83043fdf8cabb2357df742e9e758e8aa8d"
JMDICT_FILE = DATA_DIR / "jmdict" / JMDICT_RELEASE / "JMdict_e.gz"
MAX_DATA_AGE_DAYS = 31

KANJIUM_COMMIT = "685d4d723d6d20bf9beb169103aeac188eb067ad"
KANJIUM_URL = ("https://raw.githubusercontent.com/mifunetoshiro/kanjium/"
               f"{KANJIUM_COMMIT}/data/source_files/raw/accents.txt")
KANJIUM_SHA256 = "8bd0dd127dab32ceec94cb03ab1ba6b68858ea73421dfa1731af2f373deb4f20"
KANJIUM_FILE = DATA_DIR / "kanjium_accents.txt"


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def check_inputs() -> None:
    """Fail loudly unless the pinned inputs are present and unchanged."""
    for path, want, url in ((JMDICT_FILE, JMDICT_SHA256, JMDICT_URL),
                            (KANJIUM_FILE, KANJIUM_SHA256, KANJIUM_URL)):
        if not path.exists():
            hint = ""
            if path == JMDICT_FILE:
                hint = (" JMdict_e.gz is replaced daily upstream: run `scripts/fetch_data.sh jmdict`, "
                        "which stores it under data/jmdict/<JMdict created date>/, then set "
                        "JMDICT_RELEASE and JMDICT_SHA256 here to that release.")
            raise SystemExit(f"ERROR: missing {path} (source: {url}).{hint}")
        got = _sha256(path)
        if got != want:
            raise SystemExit(f"ERROR: {path} sha256 {got} != pinned {want}. "
                             "Update the pin in build_jmdict_mdx.py when refreshing the data.")
    age = (datetime.date.today() - datetime.date.fromisoformat(JMDICT_RELEASE)).days
    if age > MAX_DATA_AGE_DAYS:
        print(f"  WARNING: JMdict release {JMDICT_RELEASE} is {age} days old. The EDRDG "
              "licence (section 4) requires regular updates: refresh the data.")


# ── Kana helpers ──────────────────────────────────────────────

_HIRA_TO_KATA = {v: k for k, v in _KATA_TO_HIRA.items()}
_KANA_RE = re.compile(r'^[ぁ-ゟ゠-ヿ]+$')
_KATA_RE = re.compile(r'[ァ-ヺヽヾ]')


def to_hira(s: str) -> str:
    return s.translate(_KATA_TO_HIRA)


def to_kata(s: str) -> str:
    return s.translate(_HIRA_TO_KATA)


# ── Pitch accent (Kanjium) ────────────────────────────────────

# Kanjium qualifies some accents with a Japanese part of speech: "(名)1,(副)0".
KANJIUM_POS = {'名': 'n.', '副': 'adv.', '形動': 'adj-na', '代': 'pron.', '感': 'interj.'}
_ACC_TOKEN = re.compile(r'^(?:\(([^)]*)\))?(\d+)$')


def load_kanjium(filepath: Path) -> dict[tuple[str, str], list[tuple[str, int]]]:
    """Load Kanjium accents: {(word, reading): [(pos_label, accent), ...]}.

    Kana-only words have an empty reading field: ('テレビ', '').
    """
    accents: dict[tuple[str, str], list[tuple[str, int]]] = {}
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 3:
                continue
            variants: list[tuple[str, int]] = []
            for tok in parts[2].split(','):
                m = _ACC_TOKEN.match(tok.strip())
                if not m:
                    continue
                label = '/'.join(KANJIUM_POS.get(p, p) for p in m.group(1).split(';')) \
                    if m.group(1) else ''
                v = (label, int(m.group(2)))
                if v not in variants:
                    variants.append(v)
            if variants:
                accents[(parts[0], parts[1])] = variants
    return accents


CIRCLED_NUMS = '⓪①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳'


def _accent_num(acc: int) -> str:
    return CIRCLED_NUMS[acc] if acc < len(CIRCLED_NUMS) else str(acc)


def _compute_pitch(n: int, accent_pos: int) -> list[bool]:
    """High/low for each mora (True = high)."""
    if accent_pos == 0:
        return [i > 0 for i in range(n)]          # heiban: L H H H ...
    if accent_pos == 1:
        return [i == 0 for i in range(n)]         # atamadaka: H L L L ...
    return [1 <= i < accent_pos for i in range(n)]  # nakadaka / odaka


def _render_contour(segments: list[str], pitch: list[bool], drop_at_end: bool) -> str:
    """Wrap segments in pitch spans: high = overline, drop = right border.

    drop_at_end marks odaka (and one-mora atamadaka) words, whose pitch
    falls only on the following particle; without it 橋② looks like 端⓪.
    """
    n = len(segments)
    parts = []
    i = 0
    while i < n:
        is_high = pitch[i]
        j = i + 1
        while j < n and pitch[j] == is_high:
            j += 1
        text = ''.join(segments[i:j])
        if is_high:
            drop = (j < n and not pitch[j]) or (j == n and drop_at_end)
            cls = 'phd' if drop else 'ph'
        else:
            cls = 'pl'
        parts.append(f'<span class="{cls}">{esc(text)}</span>')
        i = j
    return ''.join(parts)


def _variant_label(label: str) -> str:
    return f'<span class="ap">{esc(label)}</span>' if label else ''


# Punctuation inside readings (シー・ディー, あ、そう) as written in romaji.
_ROMAJI_PUNCT = {'・': ' ', '、': ', ', '。': '.', '〜': '~', '～': '~', '＝': '='}
_HALFWIDTH_KANA = re.compile(r'[ｦ-ﾟ]')


def render_reading(reading: str, variants: list[tuple[str, int]],
                   wa_positions: set[int]) -> tuple[str, str]:
    """(kana_html, romaji_html) for a reading, with pitch contours.

    Every accent variant is drawn on the kana line (the first one at full
    size); the romaji line carries the first variant.
    """
    morae = split_morae(reading)
    n = len(morae)
    if _HALFWIDTH_KANA.search(reading):       # ﾀﾋ: romanize the full-width form
        roms = kana_to_romaji_morae(unicodedata.normalize('NFKC', reading))
    else:
        roms = kana_to_romaji_morae(reading)
    roms = [_ROMAJI_PUNCT.get(x, x) for x in roms]
    for i in wa_positions:
        if i < len(roms):
            roms[i] = 'wa'
    aligned = len(roms) == n
    variants = [(lab, a) for lab, a in variants if n and a <= n]
    if not variants:
        return esc(reading), esc(''.join(roms))
    kana_parts = []
    for idx, (label, acc) in enumerate(variants):
        pitch = _compute_pitch(n, acc)
        html = (f'{_variant_label(label)}<span class="an">{_accent_num(acc)}</span>'
                f'{_render_contour(morae, pitch, acc == n)}')
        kana_parts.append(html if idx == 0 else f'<span class="av">{html}</span>')
    label, acc = variants[0]
    if aligned:
        rom = _render_contour(roms, _compute_pitch(n, acc), acc == n)
    else:
        rom = esc(''.join(roms))
    return ''.join(kana_parts), f'<span class="an">{_accent_num(acc)}</span>{rom}'


# ── JMdict parser ────────────────────────────────────────────

class KEle:
    __slots__ = ('keb', 'inf', 'pri')

    def __init__(self, keb, inf, pri):
        self.keb, self.inf, self.pri = keb, inf, pri


class REle:
    __slots__ = ('reb', 'nokanji', 'restr', 'inf', 'pri')

    def __init__(self, reb, nokanji, restr, inf, pri):
        self.reb, self.nokanji, self.restr, self.inf, self.pri = reb, nokanji, restr, inf, pri

    def applies_to(self, keb: str) -> bool:
        return not self.nokanji and (not self.restr or keb in self.restr)


class Sense:
    __slots__ = ('stagk', 'stagr', 'pos', 'xref', 'ant', 'field', 'misc',
                 's_inf', 'lsource', 'dial', 'glosses')

    def __init__(self):
        for name in self.__slots__:
            setattr(self, name, [])


class JMdictEntry:
    __slots__ = ('ent_seq', 'k', 'r', 'senses', 'idx',
                 'disp_k', 'disp_r', 'kana_display', 'key', 'rank')

    def __init__(self):
        self.ent_seq = 0
        self.k: list[KEle] = []
        self.r: list[REle] = []
        self.senses: list[Sense] = []


_STD_ENTITIES = {'amp', 'lt', 'gt', 'quot', 'apos'}


def read_jmdict_text(filepath: Path) -> str:
    opener = gzip.open if filepath.suffix == '.gz' else open
    with opener(filepath, 'rt', encoding='utf-8') as f:
        return f.read()


def parse_jmdict(filepath: Path) -> tuple[list[JMdictEntry], dict[str, str], str]:
    """Parse JMdict XML.

    Entity references from the DTD (&n; &uk; &ksb; ...) are replaced by
    their NAME, so POS / misc / field / dialect / *_inf values arrive as
    JMdict codes; their expansions come back in the returned dict. The
    XML-standard &amp; &lt; &gt; are left for the XML parser.

    Returns (entries, {code: expansion}, created_date).
    """
    print("  Reading file...")
    raw = read_jmdict_text(filepath)
    dtd_end = raw.find(']>')
    if dtd_end == -1:
        raise SystemExit(f"ERROR: {filepath}: no internal DTD found")
    entities = {m.group(1): m.group(2) for m in
                re.finditer(r'<!ENTITY\s+(\S+)\s+"([^"]*)">', raw[:dtd_end])}
    m = re.search(r'<!-- JMdict created: (\d{4}-\d{2}-\d{2}) -->', raw)
    created = m.group(1) if m else ''

    def replacer(mo):
        name = mo.group(1)
        if name in entities and name not in _STD_ENTITIES:
            return name
        return mo.group(0)

    print("  Resolving entities...")
    body = '<?xml version="1.0" encoding="UTF-8"?>\n' + raw[dtd_end + 2:]
    del raw
    body = re.sub(r'&([\w-]+);', replacer, body)

    print("  Parsing XML...")
    root = ET.fromstring(body)
    del body
    XML_LANG = '{http://www.w3.org/XML/1998/namespace}lang'

    entries = []
    for entry_el in root.iter('entry'):
        e = JMdictEntry()
        e.ent_seq = int(entry_el.findtext('ent_seq', '0'))
        for k_ele in entry_el.findall('k_ele'):
            keb = k_ele.findtext('keb', '')
            if keb:
                e.k.append(KEle(keb, [x.text for x in k_ele.findall('ke_inf') if x.text],
                                [x.text for x in k_ele.findall('ke_pri') if x.text]))
        for r_ele in entry_el.findall('r_ele'):
            reb = r_ele.findtext('reb', '')
            if reb:
                e.r.append(REle(reb, r_ele.find('re_nokanji') is not None,
                                [x.text for x in r_ele.findall('re_restr') if x.text],
                                [x.text for x in r_ele.findall('re_inf') if x.text],
                                [x.text for x in r_ele.findall('re_pri') if x.text]))
        for sense_el in entry_el.findall('sense'):
            s = Sense()
            for child in sense_el:
                tag = child.tag
                if tag == 'gloss':
                    if child.text:
                        s.glosses.append((child.text, child.get('g_type', '')))
                elif tag == 'lsource':
                    s.lsource.append((child.get(XML_LANG, 'eng'), child.text or '',
                                      child.get('ls_type', ''), child.get('ls_wasei', '')))
                elif tag in ('stagk', 'stagr', 'pos', 'xref', 'ant', 'field',
                             'misc', 's_inf', 'dial'):
                    if child.text:
                        getattr(s, tag).append(child.text)
            if s.glosses:
                e.senses.append(s)
        if e.senses and e.r:
            entries.append(e)
    return entries, entities, created


# ── Priority ──────────────────────────────────────────────────

COMMON_PRI = {'news1', 'ichi1', 'spec1', 'spec2', 'gai1'}
# Popularity weights. ichi1 (the Ichimango basic-vocabulary list) outranks
# the newspaper bands, because basic words written in kana (する, 居る, 人)
# carry ichi1 but no news/nfXX rank.
PRI_WEIGHT = {'ichi1': 40, 'news1': 30, 'spec1': 25, 'gai1': 25,
              'spec2': 15, 'news2': 10, 'ichi2': 10, 'gai2': 10}


def pri_rank(pri) -> tuple[int, float]:
    """Sort key for a ke_pri/re_pri set: (tier, -score); smaller sorts first.

    tier 0 = common (news1/ichi1/spec1/spec2/gai1), 1 = other priority,
    2 = none. The score adds the marker weights and the nfXX band.
    """
    if not pri:
        return (2, 0.0)
    tier = 0 if any(p in COMMON_PRI for p in pri) else 1
    score = float(sum(PRI_WEIGHT.get(p, 0) for p in pri))
    nf = min((int(p[2:]) for p in pri if p.startswith('nf') and p[2:].isdigit()), default=0)
    if nf:
        score += (50 - nf) / 2
    return (tier, -score)


def pair_pri(e: 'JMdictEntry', form) -> set[str]:
    """Priority of a written form together with its partner.

    A reading's re_pri is combined with the ke_pri of the kanji it belongs
    to, and a kanji's ke_pri with its first reading's re_pri (JMdict often
    puts the news/nfXX bands on only one of the two). A form without its
    own priority stays unranked: 九 is common, its rare reading ここ is not.
    """
    if not form.pri:
        return set()
    out = set(form.pri)
    if isinstance(form, REle):
        partner = next((k for k in ([e.disp_k] if e.disp_k else []) + e.k
                        if form.applies_to(k.keb)), None)
    else:
        partner = next((r for r in e.r if r.applies_to(form.keb)), None)
    if partner is not None:
        out.update(partner.pri)
    return out


def is_common(e: JMdictEntry) -> bool:
    return any(p in COMMON_PRI for x in (*e.k, *e.r) for p in x.pri)


# ── Display headword selection ────────────────────────────────

HIDDEN_K = {'sK'}            # search-only kanji: never displayed
HIDDEN_R = {'sk'}            # search-only kana: never displayed
NON_PREFERRED_K = {'sK', 'rK', 'oK'}


def choose_display(e: JMdictEntry) -> None:
    """Set disp_k / disp_r / kana_display / key / rank on an entry.

    Display kanji: the first k_ele that is not search-only, rare or
    outdated (else the first not search-only). Display reading: the first
    non-search-only reading that belongs to that kanji (re_restr,
    re_nokanji). Words whose first sense is "usually kana" are displayed
    and keyed under their kana form, with the kanji listed as alternates.
    """
    shown_k = [k for k in e.k if not (set(k.inf) & HIDDEN_K)]
    disp_k = next((k for k in shown_k if not (set(k.inf) & NON_PREFERRED_K)),
                  shown_k[0] if shown_k else None)
    shown_r = [r for r in e.r if not (set(r.inf) & HIDDEN_R)] or e.r
    uk = 'uk' in e.senses[0].misc
    kana_display = disp_k is None or uk
    if disp_k is not None and not kana_display:
        disp_r = next((r for r in shown_r if r.applies_to(disp_k.keb)), None)
        if disp_r is None:
            disp_r = next((r for r in e.r if r.applies_to(disp_k.keb)), None)
        if disp_r is None:          # no reading belongs to any kanji: show kana
            kana_display = True
            disp_r = shown_r[0]
    else:
        disp_r = shown_r[0]
    e.disp_k = disp_k
    e.disp_r = disp_r
    e.kana_display = kana_display
    e.key = disp_r.reb if kana_display else disp_k.keb
    e.rank = min([pri_rank(x.pri) for x in (*e.k, *e.r)])


def find_accents(e: JMdictEntry, accents: dict) -> list[tuple[str, int]]:
    """Kanjium accents for the displayed reading of an entry."""
    r = e.disp_r.reb
    hira = to_hira(r)
    cands: list[tuple[str, str]] = []
    kanji = ([e.disp_k] if e.disp_k else []) + [k for k in e.k if k is not e.disp_k]
    for k in kanji:
        if e.disp_r.applies_to(k.keb) or e.kana_display:
            cands += [(k.keb, r), (k.keb, hira)]
    if e.kana_display:
        kana_first = [(r, ''), (hira, ''), (to_kata(r), '')]
        cands = kana_first + cands if not e.k else cands + kana_first
    for c in cands:
        v = accents.get(c)
        if v:
            return v
    return []


# ── Labels ────────────────────────────────────────────────────

POS_LABEL = {
    'n': 'n.', 'adv': 'adv.', 'exp': 'expr.', 'int': 'interj.', 'conj': 'conj.',
    'ctr': 'ctr.', 'suf': 'suf.', 'pref': 'pref.', 'pn': 'pron.', 'cop': 'cop.',
    'prt': 'prt.', 'num': 'num.', 'aux': 'aux.', 'unc': '',
}

MISC_LABEL = {
    'uk': 'usually kana', 'abbr': 'abbr.', 'arch': 'archaic', 'rare': 'rare',
    'hist': 'historical', 'col': 'colloquial', 'on-mim': 'onomatopoeia',
    'yoji': 'yojijukugo', 'id': 'idiom', 'sl': 'slang', 'proverb': 'proverb',
    'hon': 'honorific', 'form': 'formal', 'obs': 'obsolete', 'dated': 'dated',
    'derog': 'derogatory', 'pol': 'polite', 'net-sl': 'Internet slang',
    'hum': 'humble', 'vulg': 'vulgar', 'joc': 'jocular', 'sens': 'sensitive',
    'poet': 'poetic', 'fam': 'familiar', 'chn': "children's language",
    'fem': 'female term', 'male': 'male term', 'euph': 'euphemism',
    'm-sl': 'manga slang', 'quote': 'quotation', 'organization': 'organization',
    'work': 'title of a work', 'company': 'company', 'product': 'product',
    'serv': 'service', 'char': 'character', 'surname': 'surname', 'place': 'place',
    'ev': 'event', 'person': 'person', 'dei': 'deity', 'fict': 'fiction',
    'myth': 'mythology', 'leg': 'legend', 'given': 'given name', 'obj': 'object',
    'unclass': 'name', 'ship': 'ship', 'doc': 'document', 'creat': 'creature',
    'relig': 'religion', 'group': 'group', 'litf': 'literary', 'tsug': 'Tsugaru-ben',
}

FORM_LABEL = {
    'ateji': 'ateji', 'gikun': 'gikun', 'ik': 'irregular kana', 'iK': 'irregular kanji',
    'io': 'irregular okurigana', 'oK': 'outdated kanji', 'rK': 'rare kanji',
    'ok': 'outdated kana', 'rk': 'rare kana',
}

GLOSS_TYPE = {'lit': 'lit.', 'fig': 'fig.', 'expl': 'expl.', 'tm': 'trademark'}

# ISO 639-2/B codes used by <lsource xml:lang>: (English name, BCP 47 tag)
LANGS = {
    'afr': ('Afrikaans', 'af'), 'ain': ('Ainu', 'ain'), 'alb': ('Albanian', 'sq'),
    'alg': ('Algonquian', 'alg'), 'amh': ('Amharic', 'am'), 'ara': ('Arabic', 'ar'),
    'arm': ('Armenian', 'hy'), 'arn': ('Mapudungun', 'arn'), 'aze': ('Azerbaijani', 'az'),
    'bel': ('Belarusian', 'be'), 'ben': ('Bengali', 'bn'), 'bnt': ('Bantu', 'bnt'),
    'bre': ('Breton', 'br'), 'bul': ('Bulgarian', 'bg'), 'bur': ('Burmese', 'my'),
    'cat': ('Catalan', 'ca'), 'chi': ('Chinese', 'zh'), 'cze': ('Czech', 'cs'),
    'dan': ('Danish', 'da'), 'div': ('Dhivehi', 'dv'), 'dut': ('Dutch', 'nl'),
    'eng': ('English', 'en'), 'epo': ('Esperanto', 'eo'), 'est': ('Estonian', 'et'),
    'fil': ('Filipino', 'fil'), 'fin': ('Finnish', 'fi'), 'fre': ('French', 'fr'),
    'geo': ('Georgian', 'ka'), 'ger': ('German', 'de'), 'gle': ('Irish', 'ga'),
    'glg': ('Galician', 'gl'), 'grc': ('Ancient Greek', 'grc'), 'gre': ('Greek', 'el'),
    'haw': ('Hawaiian', 'haw'), 'heb': ('Hebrew', 'he'), 'hin': ('Hindi', 'hi'),
    'hun': ('Hungarian', 'hu'), 'ice': ('Icelandic', 'is'), 'ind': ('Indonesian', 'id'),
    'ita': ('Italian', 'it'), 'kaz': ('Kazakh', 'kk'), 'khm': ('Khmer', 'km'),
    'kir': ('Kyrgyz', 'ky'), 'kor': ('Korean', 'ko'), 'kur': ('Kurdish', 'ku'),
    'lao': ('Lao', 'lo'), 'lat': ('Latin', 'la'), 'lit': ('Lithuanian', 'lt'),
    'mal': ('Malayalam', 'ml'), 'mao': ('Maori', 'mi'), 'may': ('Malay', 'ms'),
    'mlg': ('Malagasy', 'mg'), 'mnc': ('Manchu', 'mnc'), 'mon': ('Mongolian', 'mn'),
    'nep': ('Nepali', 'ne'), 'nor': ('Norwegian', 'no'), 'per': ('Persian', 'fa'),
    'pol': ('Polish', 'pl'), 'por': ('Portuguese', 'pt'), 'rum': ('Romanian', 'ro'),
    'rus': ('Russian', 'ru'), 'san': ('Sanskrit', 'sa'), 'scr': ('Croatian', 'hr'),
    'slo': ('Slovak', 'sk'), 'slv': ('Slovenian', 'sl'), 'smo': ('Samoan', 'sm'),
    'som': ('Somali', 'so'), 'sot': ('Sotho', 'st'), 'spa': ('Spanish', 'es'),
    'swa': ('Swahili', 'sw'), 'swe': ('Swedish', 'sv'), 'tah': ('Tahitian', 'ty'),
    'tam': ('Tamil', 'ta'), 'tgk': ('Tajik', 'tg'), 'tgl': ('Tagalog', 'tl'),
    'tha': ('Thai', 'th'), 'tib': ('Tibetan', 'bo'), 'tuk': ('Turkmen', 'tk'),
    'tur': ('Turkish', 'tr'), 'ukr': ('Ukrainian', 'uk'), 'urd': ('Urdu', 'ur'),
    'uzb': ('Uzbek', 'uz'), 'vie': ('Vietnamese', 'vi'), 'yid': ('Yiddish', 'yi'),
}

# Kana-only words whose final は is the topic particle (read "wa"). Kana
# alone cannot tell it from a lexical は (あはは, ウハウハ, ロハ, おは).
PARTICLE_HA_KANA = frozenset({
    'では', 'ならでは', 'さては', 'からには', 'とは', 'にかけては', 'こんちは',
    'ただでは', 'にしては', 'それは', 'にあっては', 'には', 'としては',
    'それはそれは', 'ては', 'ずは', 'ってのは', 'ようによっては', 'こんばんにちは',
    'ってことは', 'ではでは', 'おはこんばんちは', 'おはこんばんにちは', 'のでは',
    'いずれは', 'からは',
})


def wa_positions(e: JMdictEntry, reading: str) -> set[int]:
    """Mora indices of a reading where は is the particle "wa"."""
    if not reading.endswith('は'):
        return set()
    if e.k:
        particle = any(k.keb.endswith('は') for k in e.k)
    else:
        particle = reading in PARTICLE_HA_KANA or (
            reading == 'は' and any('prt' in s.pos for s in e.senses))
    if not particle:
        return set()
    morae = split_morae(reading)
    pos = {len(morae) - 1}
    half = len(reading) // 2
    if len(reading) % 2 == 0 and reading[:half] == reading[half:]:   # これはこれは
        pos.add(len(split_morae(reading[:half])) - 1)
    return pos


# ── HTML generation ──────────────────────────────────────────

FLAG_JP = '\U0001F1EF\U0001F1F5'  # 🇯🇵
FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_JP} 日本語 → English {FLAG_EN}'

_SEC, _SEC_D = TEXT_SECONDARY
_LINK, _LINK_D = TEXT_LINK

CSS = get_css(
    GLOSS, ORDERED_LIST, DOMAIN_BADGE,
    extra_light=(
        '.k{font-size:1.7em;font-weight:600;display:block}'
        f'.r{{font-size:1.25em;color:{_SEC};display:block;margin-top:2px}}'
        f'.rm{{font-size:1.15em;color:{_LINK};font-style:italic;display:block;margin-top:2px}}'
        f'.an{{font-size:1.0em;color:{_SEC};margin-right:2px;font-style:normal}}'
        '.av{font-size:0.8em;margin-left:0.8em}'
        f'.ap{{font-size:0.7em;color:{_SEC};margin-right:2px;font-style:normal}}'
        '.ph{display:inline;border-top:2px solid #ff3b30;padding-top:1px}'
        '.phd{display:inline;border-top:2px solid #ff3b30;border-right:2px solid #ff3b30;padding-top:1px;padding-right:1px}'
        '.pl{display:inline;padding-top:3px}'
        '.fi{display:inline-block;font-size:0.75em;font-weight:400;font-style:normal;color:#636366;'
        'background:#e8e8ed;border-radius:3px;padding:0 4px;margin-left:4px;vertical-align:middle}'
        '.k .fi{font-size:0.45em}'
        f'.fm{{font-size:0.95em;color:{_SEC};display:block;margin-top:4px}}'
        '.fl{font-size:0.85em;font-weight:600;margin-right:6px}'
        '.fv{color:#1d1d1f}'
        f'.rs{{font-size:0.8em;color:{_SEC}}}'
        f'.gt{{font-style:italic;color:{_SEC};margin-right:4px}}'
        f'.nt{{font-size:0.85em;color:{_SEC};margin:4px 0 0}}'
        f'.xr{{font-size:0.85em;color:{_SEC};margin:4px 0 0}}'
        f'.xr a{{color:{_LINK};text-decoration:underline}}'
        '.at{font-size:0.85em;color:#d70015;margin:2px 0 0}'
        '.at a{color:#d70015;text-decoration:underline}'
    ),
    extra_dark=(
        f'.r{{color:{_SEC_D}}}.rm{{color:{_LINK_D}}}'
        f'.an,.ap{{color:{_SEC_D}}}'
        '.fi{color:#aeaeb2;background:#3a3a3c}'
        f'.fm,.rs,.gt,.nt{{color:{_SEC_D}}}.fv{{color:#f5f5f7}}'
        f'.xr{{color:{_SEC_D}}}.xr a{{color:{_LINK_D}}}'
        '.at{color:#ff6961}.at a{color:#ff6961}'
        '.ph,.phd{border-color:#ff453a}'
    ),
)


def _tags(codes: list[str], hidden: set[str] = frozenset()) -> str:
    return ''.join(f'<span class="fi">{esc(FORM_LABEL.get(c, c))}</span>'
                   for c in codes if c not in hidden)


class Renderer:
    """Builds article HTML; holds the indexes needed for cross-references."""

    def __init__(self, entries: list[JMdictEntry], entities: dict[str, str],
                 accents: dict, key_items: dict[str, list]):
        self.entities = entities
        self.accents = accents
        self.key_items = key_items
        self.by_form: dict[str, list[JMdictEntry]] = defaultdict(list)
        self.by_reading: dict[str, set[int]] = defaultdict(set)
        for e in entries:
            for k in e.k:
                self.by_form[k.keb].append(e)
            for r in e.r:
                self.by_form[r.reb].append(e)
                self.by_reading[r.reb].add(e.idx)
        self.stats = defaultdict(int)

    # ── header ──
    def header(self, e: JMdictEntry) -> str:
        variants = find_accents(e, self.accents)
        if variants:
            self.stats['pitch'] += 1
        reading = e.disp_r.reb
        kana_html, romaji_html = render_reading(reading, variants, wa_positions(e, reading))
        r_tags = _tags(e.disp_r.inf, HIDDEN_R)
        if e.kana_display:
            hw = (f'<span class="k">{kana_html}{r_tags}</span>'
                  f'<span class="rm">{romaji_html}</span>')
        else:
            hw = (f'<span class="k">{esc(e.disp_k.keb)}{_tags(e.disp_k.inf, HIDDEN_K)}</span>'
                  f'<span class="r">{kana_html}{r_tags}</span>'
                  f'<span class="rm">{romaji_html}</span>')
        return f'<div class="h">{hw}{self.forms(e)}</div>'

    def forms(self, e: JMdictEntry) -> str:
        """Lines listing the other written forms and readings."""
        kanji = [k for k in e.k if k is not e.disp_k or e.kana_display]
        kanji = [k for k in kanji if not (set(k.inf) & HIDDEN_K)]
        shown_kanji = [k.keb for k in e.k if not (set(k.inf) & HIDDEN_K)]
        kana = [r for r in e.r if r is not e.disp_r and not (set(r.inf) & HIDDEN_R)]
        lines = []
        if kanji:
            label = 'Kanji' if e.kana_display else 'Also written'
            items = [f'<span class="fv">{esc(k.keb)}</span>{_tags(k.inf, HIDDEN_K)}' for k in kanji]
            lines.append(f'<span class="fm"><span class="fl">{label}</span>{"、".join(items)}</span>')
        if kana:
            label = 'Also written' if e.kana_display else 'Also read'
            items = []
            for r in kana:
                extra = _tags(r.inf, HIDDEN_R)
                if e.k and r.nokanji and not e.kana_display:
                    extra += '<span class="fi">kana only</span>'
                elif r.restr and len(shown_kanji) > 1:
                    restr = [x for x in r.restr if x in shown_kanji]
                    if restr:
                        extra += f'【{esc("、".join(restr))}】'
                items.append(f'<span class="fv">{esc(r.reb)}</span>{extra}')
            lines.append(f'<span class="fm"><span class="fl">{label}</span>{"、".join(items)}</span>')
        return ''.join(lines)

    # ── cross-references ──
    def resolve_xref(self, text: str, current: JMdictEntry) -> str:
        """JMdict xref 'keb・reb・sense' → link (or plain text)."""
        parts = text.split('・')
        if len(parts) > 1 and re.fullmatch(r'[0-9]+', parts[-1]):
            parts = parts[:-1]
        form, reading = parts[0], ''
        for i in range(len(parts), 0, -1):          # forms may contain ・ themselves
            cand = '・'.join(parts[:i])
            if cand in self.by_form:
                form, reading = cand, '・'.join(parts[i:])
                break
        targets = self.by_form.get(form, [])
        if reading and targets:
            narrowed = [t for t in targets if t.idx in self.by_reading.get(reading, ())]
            targets = narrowed or targets
        if not targets:
            self.stats['xref_plain_missing'] += 1
            return esc(form)
        if len(targets) == 1 and targets[0] is current:
            self.stats['xref_self'] += 1
            return esc(form)
        # Link to the key that shows the target with the fewest other records.
        target = min(targets, key=lambda t: (t is current, t.rank, t.ent_seq))
        best = None
        for key in (form, reading, target.key):
            if not key or key not in self.key_items:
                continue
            idxs = [it[1] for it in self.key_items[key]]
            if target.idx in idxs and (best is None or len(idxs) < best[1]):
                best = (key, len(idxs))
        if best is None:
            self.stats['xref_plain_unlinkable'] += 1
            return esc(form)
        self.stats['xref_link'] += 1
        return entry_link(best[0], form)

    # ── senses ──
    def lsource_html(self, sources) -> str:
        out = []
        for lang, text, ls_type, wasei in sources:
            name, tag = LANGS.get(lang, (lang, ''))
            if wasei:
                prefix = 'Wasei (made in Japan), from'
            elif ls_type == 'part':
                prefix = 'Partly from'
            else:
                prefix = 'From'
            item = f'{prefix} {esc(name)}'
            if text:
                if has_rtl(text):
                    word = rtl_span(text, tag)
                else:
                    word = f'<i lang="{tag}">{esc(text)}</i>' if tag else f'<i>{esc(text)}</i>'
                item += f': {word}'
            out.append(item)
        return f'<div class="nt">{"; ".join(out)}</div>' if out else ''

    def gloss_html(self, text: str, g_type: str) -> str:
        prefix = f'<span class="gt">{GLOSS_TYPE.get(g_type, g_type)}</span>' if g_type else ''
        return prefix + esc(text)

    def senses(self, e: JMdictEntry) -> str:
        out = []
        last_pos: list[str] = []
        for s in e.senses:
            if s.pos:
                last_pos = s.pos     # POS carries over to later senses
            badges = []
            for p in last_pos:
                label = POS_LABEL.get(p, p)
                if label:
                    badges.append(f'<span class="pos">{esc(label)}</span>')
            for m in s.misc:
                badges.append(f'<span class="mk">{esc(MISC_LABEL.get(m, self.entities.get(m, m)))}</span>')
            for f in s.field:
                badges.append(f'<span class="dm">{esc(self.entities.get(f, f))}</span>')
            for d in s.dial:
                badges.append(f'<span class="mk">{esc(self.entities.get(d, d))}</span>')
            restr = s.stagk + s.stagr
            if restr:
                badges.append(f'<span class="rs">only for {esc("、".join(restr))}</span>')
            card = '<div class="sn">'
            if badges:
                card += f'<div class="sn-hd">{"".join(badges)}</div>'
            if len(s.glosses) == 1:
                card += f'<span class="gl">{self.gloss_html(*s.glosses[0])}</span>'
            else:
                items = ''.join(f'<li>{self.gloss_html(*g)}</li>' for g in s.glosses)
                card += f'<ol class="d">{items}</ol>'
            for note in s.s_inf:
                card += f'<div class="nt">{esc(note)}</div>'
            card += self.lsource_html(s.lsource)
            if s.xref:
                card += f'<div class="xr">→ {", ".join(self.resolve_xref(x, e) for x in s.xref)}</div>'
            if s.ant:
                card += f'<div class="at">↔ {", ".join(self.resolve_xref(a, e) for a in s.ant)}</div>'
            card += '</div>'
            out.append(card)
        return ''.join(out)

    def article(self, e: JMdictEntry) -> str:
        body = self.header(e) + self.senses(e)
        return f'{CSS}<div class="e"><span class="dir">{DIR_LABEL}</span>{body}</div>'


# ── Keys ──────────────────────────────────────────────────────

def _variants(form: str) -> set[str]:
    """Typable spellings of a form: half-width (NFKC), without ・."""
    out = set()
    nfkc = unicodedata.normalize('NFKC', form).strip()
    for v in (nfkc, form.replace('・', ''), nfkc.replace('・', '')):
        v = v.strip()
        if v and v != form:
            out.add(v)
    return out


def build_key_items(entries: list[JMdictEntry]) -> tuple[dict[str, list], dict[str, int]]:
    """{key: [(sort_key, entry_idx, is_article), ...]} in record order.

    Order under one key: common forms first (tier); within a tier, entries
    whose display headword IS the key (e.g. する for 為る, uk) before
    entries that merely have the key as another form; then popularity
    (pair_pri), number of senses, ent_seq. Derived spellings come last.
    """
    items: dict[str, dict[int, tuple]] = defaultdict(dict)
    stats = defaultdict(int)

    def add(key, e, rank, article=False, derived=False):
        tier, score = rank
        sort_key = (tier + (3 if derived else 0), 0 if article else 1, score,
                    -len(e.senses), e.ent_seq)
        cur = items[key].get(e.idx)
        new = (sort_key, e.idx, article)
        if cur is None or article or (not cur[2] and new[0] < cur[0]):
            items[key][e.idx] = new

    primary_forms = set()
    for e in entries:
        primary_forms.update(k.keb for k in e.k)
        primary_forms.update(r.reb for r in e.r)

    for e in entries:
        disp = e.disp_r if e.kana_display else e.disp_k
        add(e.key, e, pri_rank(pair_pri(e, disp)), article=True)
        forms = ([(k.keb, pri_rank(pair_pri(e, k))) for k in e.k]
                 + [(r.reb, pri_rank(pair_pri(e, r))) for r in e.r])
        for f, rank in forms:
            if f != e.key:
                add(f, e, rank)
        own = {f for f, _ in forms}
        for f, rank in forms:
            derived = _variants(f)
            # A hiragana spelling for katakana readings (input before IME
            # conversion is hiragana), unless that spelling is a real form.
            if _KANA_RE.match(f) and _KATA_RE.search(f):
                h = to_hira(f)
                if h not in primary_forms:
                    derived.add(h)
            for v in derived - own:
                stats['derived'] += 1
                add(v, e, rank, derived=True)
    out = {}
    for key, d in items.items():
        out[key] = sorted(d.values(), key=lambda it: (it[0], it[1]))
    return out, stats


# ── Preview ───────────────────────────────────────────────────

SAMPLE_WORDS = ['食べる', 'はし', '猫', 'する', 'コンピューター', '日本', 'こんにちは', '寿司']


def _generate_preview(records: dict[str, list[str]], articles: list[str]):
    """Preview HTML: each sample key with every record it shows."""
    entries_html = []
    for word in SAMPLE_WORDS:
        shown = []
        for body in records.get(word, []):
            if body.startswith('@@@LINK='):
                body = records[body[8:]][0]
            if body not in shown:
                shown.append(body)
        entries_html.extend(shown[:4])
    _shared_preview(entries_html, OUTPUT_DIR / "jmdict_preview.html", 'JMdict — preview')


# ── Header description ────────────────────────────────────────

CC_BY_SA_4 = '<a href="https://creativecommons.org/licenses/by-sa/4.0/">CC BY-SA 4.0</a>'


def header_description() -> str:
    """The MDX header description in the shared layout (shared.build.description_html).

    Depends only on the pinned JMDICT_RELEASE, so it is the same whether or
    not the data files are present.
    """
    source = (
        'The <a href="https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project">'
        f"JMdict</a> dictionary file (JMdict_e, release {JMDICT_RELEASE}), originally "
        "compiled by Jim Breen. Documentation: "
        '<a href="https://www.edrdg.org/jmdict/j_jmdict.html">JMdict project page</a>. '
        "The pitch accent notation was provided by Uros O. through his free database "
        '<a href="https://github.com/mifunetoshiro/kanjium">Kanjium</a>.'
    )
    license_text = (
        'The JMdict file is the property of the <a href="https://www.edrdg.org/">'
        "Electronic Dictionary Research and Development Group</a> (EDRDG) and is used "
        "in conformance with the Group's "
        '<a href="https://www.edrdg.org/edrdg/licence.html">licence</a> '
        f"({CC_BY_SA_4}). Kanjium is licensed under {CC_BY_SA_4}."
    )
    return description_html(
        title="JMdict Japanese-English Dictionary",
        about=[
            "Japanese-English dictionary from the EDRDG JMdict project: kanji and kana "
            "forms, romaji, part of speech, usage labels and English glosses, with "
            "Kanjium pitch accent for many words."
        ],
        source=source,
        license=license_text,
        changes="reformatted, lookup keys for every form, romaji and pitch accent added",
        adaptation_license=f"This compilation is distributed under {CC_BY_SA_4}.",
    )


def descriptions() -> dict[str, str]:
    """{"<Name>.mdx": header description} for every dictionary this script builds."""
    return {"JMdict-JA-EN.mdx": header_description()}


# ── Main ──────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    check_inputs()

    print("Loading Kanjium pitch accent data...")
    accents = load_kanjium(KANJIUM_FILE)
    print(f"  {len(accents)} accent entries loaded")

    print("Parsing JMdict...")
    entries, entities, created = parse_jmdict(JMDICT_FILE)
    if created != JMDICT_RELEASE:
        raise SystemExit(f"ERROR: {JMDICT_FILE} says 'JMdict created: {created}', "
                         f"expected {JMDICT_RELEASE}")
    print(f"  {len(entries)} entries parsed (JMdict created {created})")
    for i, e in enumerate(entries):
        e.idx = i
        choose_display(e)

    key_items, kstats = build_key_items(entries)
    renderer = Renderer(entries, entities, accents, key_items)

    # An entry is reachable through @@@LINK=<its key> only when its article
    # is the first record of that key; otherwise forms get a copy.
    reachable = [False] * len(entries)
    for e in entries:
        first = key_items[e.key][0]
        reachable[e.idx] = first[1] == e.idx and first[2]

    print("Rendering articles...")
    articles = [renderer.article(e) for e in entries]
    for html in articles:
        assert '<span class="k">' in html.split('<div class="sn">')[0]

    txt_path = OUTPUT_DIR / "jmdict_entries.txt"
    print(f"Writing → {txt_path}...")
    records: dict[str, list[str]] = {}
    n_articles = n_links = n_copies = 0
    for key in sorted(key_items):
        recs = []
        for _, idx, is_article in key_items[key]:
            e = entries[idx]
            if is_article:
                recs.append(articles[idx])
                n_articles += 1
            elif reachable[idx]:
                recs.append(f'@@@LINK={e.key}')
                n_links += 1
            else:
                recs.append(articles[idx])
                n_copies += 1
        records[key] = recs
    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for key in sorted(records):
            for body in records[key]:
                f.write(f"{key}\n{body}\n</>\n")
                count += 1
    print(f"  {len(records)} keys, {count} records: {n_articles} articles, "
          f"{n_links} links, {n_copies} article copies ({kstats['derived']} derived spellings)")
    print(f"  pitch shown for {renderer.stats['pitch']} of {len(entries)} entries")
    print(f"  xrefs: {dict(renderer.stats)}")

    mdx_path = OUTPUT_DIR / "JMdict-JA-EN.mdx"
    success, size_mb, _ = pack_mdx(txt_path, "JMdict Japanese-English", header_description(),
                                   mdx_path)
    if not success:
        raise SystemExit(1)
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="JMdict Japanese-English",
        description=("Japanese-English dictionary from the EDRDG JMdict project: kanji and kana "
                     "forms, romaji, part of speech, usage labels and English glosses, with "
                     "Kanjium pitch accent for many words."),
        direction={"src": "JA", "dest": ["EN"]},
        entries=count,
        license="CC-BY-SA-4.0",
        data_source=f"JMdict (EDRDG), release {JMDICT_RELEASE}; pitch accents from Kanjium (Uros O.)",
        tier=2,
    )

    _generate_preview(records, articles)


if __name__ == '__main__':
    main()
