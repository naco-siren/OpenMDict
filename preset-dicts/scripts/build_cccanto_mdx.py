#!/usr/bin/env python3
"""
Build the CC-Canto (Cantonese-English) MDX dictionary.

Sources (both from Pleco, https://cantonese.org/, CC BY-SA 3.0):

* ``cccanto-webdist.txt`` (CC-Canto, version 2017-02-02): Cantonese words,
  slang and idioms in CC-CEDICT format with an added ``{jyutping}`` field.
  8,882 single-character lines end in ``# adapted from cc-cedict``.
* ``cccedict-canto-readings-150923.txt`` (CC-CEDICT Cantonese Readings,
  version 2015-09-23): Jyutping for about 100,000 CC-CEDICT words, without
  definitions. NOT shipped (INCLUDE_READINGS = False): as reading-only
  articles it would add about 100,000 entries without a meaning (+520 %).
  Upstream designed CC-Canto as a Cantonese supplement to CC-CEDICT, so
  everyday words that mean the same as in Mandarin (香港, 多謝, 你好) are
  not in this dictionary. With INCLUDE_READINGS = True, words that
  CC-Canto already defines are skipped.

``cedict_ts.u8`` (CC-CEDICT) is read only as a character table: traditional
→ simplified, to derive simplified lookup keys where the CC-Canto
"simplified" column was left unconverted or converted wrongly, and its
"variant of" entries, to link spelling variants. fetch_data.sh downloads
the latest CC-CEDICT, so the build prints the release it read and warns
when it is not CEDICT_TESTED (the release the shipped MDX was built
with): another release can change a few simplified headings and keys.

Layout:
* One article per traditional headword (the upstream editorial form, what
  Hong Kong users type). Records that differ only in Jyutping or pinyin
  are merged into one block ("ding1 / zaang1 / zang1").
* @@@LINK keys: simplified forms, standard-variant traditional forms
  (説 → 說, 衞 → 衛 ...), NFKC forms of full-width Latin (阿ｓｉｒ → 阿sir),
  punctuation-free forms of proverbs and frame patterns.
* Jyutping keys: toned with spaces ("m4 goi1"), toned without spaces
  ("m4goi1") and toneless ("mgoi"). A reading shared by up to
  JYUTPING_DIRECT_MAX words links straight to those articles (the app shows
  every record of a key); a busier reading gets an index article, most
  common word first. Jyutping keys that are words of English or keys of
  another preset (JYUTPING_STOP: "cat", "be", "man", "co2") are left out,
  except for words glossed by that very word ("wok" → 鑊, "fit" → 弗).
* Spelling variants (same simplified form; same syllables or only variant
  characters such as 剷/鏟, 閑/閒) link to each other.

Usage:
    python build_cccanto_mdx.py

Input:  ../data/cc-canto/cccanto-webdist.txt
        ../data/cc-canto/cccedict-canto-readings-150923.txt
        ../data/cedict_ts.u8
Output: ../output/CC-Canto-YUE-EN/CC-Canto-YUE-EN.mdx
"""

from __future__ import annotations

import hashlib
import html
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, ORDERED_LIST, TEXT_SECONDARY, TEXT_LINK
from shared.html import esc, entry_link, headword, mark_badge
from shared.build import (pack_mdx, generate_preview as _shared_preview, write_catalog_metadata,
                          description_html)

DATA_ROOT = SCRIPT_DIR.parent / "data"
DATA_DIR = DATA_ROOT / "cc-canto"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "CC-Canto-YUE-EN"
DICT_NAME = "CC-Canto-YUE-EN"
CANTO_FILE = DATA_DIR / "cccanto-webdist.txt"
READINGS_FILE = DATA_DIR / "cccedict-canto-readings-150923.txt"
CEDICT_FILE = DATA_ROOT / "cedict_ts.u8"
# The CC-CEDICT release the shipped MDX was built with (header date, SHA-256).
CEDICT_TESTED = ("2026-01-02T04:01:30Z",
                 "fca2b8d7912c0bb0f4ac87e47692a197bcdefb4fd33a088bd6b5c2d8747c0c86")

# Ship the CC-CEDICT Cantonese Readings as reading-only articles.
INCLUDE_READINGS = False
# Jyutping lookup keys (see module docstring).
JYUTPING_INDEX = True
JYUTPING_DIRECT_MAX = 3
# Jyutping keys that are also words (lower-cased) in English or keys of
# another OpenMDict preset: the keys of the other 63 presets plus
# /usr/share/dict/web2, intersected with this dictionary's Jyutping keys
# (2026-10-20; all toneless but 'bo1' 'bo3' 'ce1' 'ce2' 'co2'). See the
# Jyutping-key loops in main().
JYUTPING_STOP = frozenset("""
bo1 bo3 ce1 ce2 co2
aa aak aam aap ai aidan ak am amsi an ang ap at au aulo baa baan bai bak bam
ban bang bangji banpo bansan bat batman baton bau be bei beice bek beng bi
bibi bin bindi bing bingo bit bo bogwan bok bokho bokje bong bosi bou boudin
boudou bouse bousin bui buk bun bundou bung but caam cai cam can cansan cap
cat catze cau cauce caulou cause causei ce ceci cefo cejan cek ceng ci cici
cik cim cin cinsin cintai cintou cisam ciso cit co coco cogo coi coisou
coitou cok colin coman cong cosam cosei cosi cou coudai cuk cung dai daici
dak dam dan dang dap dat dau de dedi dedim dei deito dek deng deot dep deu
di dik dim din ding dingdong dip dit diu do dodi doe dogai doi dok doksan
domo dong dongguk dongsam dongsi dose dosi dou doudou douse dousing duk dung
dut e ei faa fai fan fang fat fe fedai fei fim fing fit fo fok fosi fu fuci
fui fun fuso fut gaap gai gaitau gam gamdong gamso gan gang gangan gangdo
gap gat gatou gau gaucin gaudai gauging ge gebe gei geze gi gim gin ging gip
gipon git go gobo godi goe goek gogo goi gok golo gon gong gongbo gonggong
gonggu gonggun gongsik gosi got gou gozai gozan gu gugu gui guk gun gung
gungmin gungsi gusan gut guze gwan gwang gwangdung gwanse gyun haak hai hak
ham hamdi han hando hang hanghang hanzi hap hapdong hat hau he hei heizung
heng hi him hin hing hip hit ho hoe hoeng hoi hoise hok hoksi hon hong hot
hou houtou huk hung jaa jam jamban jan janjan jap japji jat jau je jeguk
jeje jeng jeoi jeon ji jice jiji jijin jik jikbun jim jiman jin jing jingjip
jingo jinji jip jisang jisi jit jo juk jukgan jung jungban kai kak kam kan
kang kap kat kauze ke kei kek kele kesi kesime kim kin king kip kit koe
koeng koi kok kong ku kui kuk kung kusan kut kwai kwan la laang lai lak lam
lan lang lap lat latto lau laudai le lei lek lem leng leon li lim lin lince
lindai ling lip lit lo lobo loe loi lok long lou loutou lung m maa maat mai
mak mam man mang mangai mangam mango manning mansi manzi mat mau mci me mei
meiji meme meng mi min mincing ming mingam mingling minjung minsi mit miu mo
moi mok mong mosam moto mou mouco moujik moulai mousing mto mui muk mun mung
munse munsi mut naa naam naan nai nak nam nan nang nap nat nau nausei ne nei
neige neoi ng ngai ngandi ngo ni nidi nik nim nin ning nip no noi nok nomai
nong nou nung o ogo oi ok oke on ong osi ou paan pai pan pang pat pau pausam
pe pei peiji pek peng pik pin pince ping pinji pit piu po pok poksik pong
popo pou poutou pui puk pun pung put saa saak saam saan saat sai saisi sak
sam samhan sammei samsam samsat san sandei sang sangei sangse sangsik sangu
sanjan sanje sansam sansi sansin sap sapsan sat sau sauce saucing saude
saudo saudou sautai se sebo sece sedai sei seigo seising seize seje sek
semei seng seoi seon seonban seondong seot seu si sibe sibo sidik sifu sigo
sije sik siling sim simo sin sincan sing singfo singsing singulam sinim
sinin sinsi sip sipo sisan sisi sisin sisuk sit siting siu siusi so soi sok
solei solou song sopo sosong sotong sou souping suk sukhoi sung syu syun
syut taa tai taiwan tam tan tance tang tangai tau tausi tek teng tik tim tin
ting tingting tinjam tintam tintou tip tit tithon tiu to toe toi tok tong
tongman tosou tou toulou touse tung uk ung waa waasi wai waise wan wang
wantan wat we wing wo wok wong wu wun wut zaa zak zam zambo zan zap zat ze
zek zeoidei zi zico zincou zing zingo zinnai zip zipei zit zizi zo zoe zogan
zongzi zou zouzou
""".split())

HAN = r'\u2e80-\u2fdf\u3005\u3007\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0003ffff'
_HAN_RE = re.compile(f'[{HAN}]')
_HAN_RUN_RE = re.compile(f'[{HAN}]+')


def is_han(ch: str) -> bool:
    return _HAN_RE.match(ch) is not None


# ── Upstream records ──────────────────────────────────────────

@dataclass
class Rec:
    line: int
    trad: str
    simp: str
    pinyin: str          # raw upstream pinyin
    jyutping: str        # raw upstream Jyutping
    defs: str            # raw '/'-joined definitions ('' for readings)
    adapted: bool        # '# adapted from cc-cedict'
    source: str          # 'canto' | 'readings'
    aliases: tuple[str, ...] = ()   # upstream spellings replaced by PLACEHOLDERS


# 繁體 简体 [pinyin] {jyutping} /def1/def2/.../ [# comment]
# The pinyin may be empty ('[]', 31 lines) and 8,882 lines carry a trailing
# '# adapted from cc-cedict', so neither may be required by the pattern.
_CANTO_LINE = re.compile(
    r'^(\S+)\s+(\S+)\s+\[([^\]]*)\]\s+\{(.*?)\}\s+/(.*)/\s*(?:#\s*(.*?))?\s*$')
_READING_LINE = re.compile(r'^(\S+)\s+(\S+)\s+\[([^\]]*)\]\s+\{(.*?)\}\s*$')

# Upstream writes '０' for a 口-radical character it could not encode; the
# same words exist elsewhere in CC-Canto with the real character (𡃁仔,
# 氹死人). The pinyin of those records is a placeholder too ('０¿ jing4').
PLACEHOLDERS = {'０靚': '𡃁', '０靓': '𡃁', '０氹': '氹'}


def _read_lines(path: Path):
    with open(path, encoding='utf-8') as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip('\n')
            if line.strip() and not line.startswith('#'):
                yield n, line


def parse_cccanto(path: Path) -> list[Rec]:
    """Parse every CC-Canto line; abort if any data line does not parse."""
    recs, failed, total = [], [], 0
    for n, line in _read_lines(path):
        total += 1
        m = _CANTO_LINE.match(line)
        if not m:
            failed.append((n, line))
            continue
        trad, simp, pinyin, jyutping, defs, comment = m.groups()
        adapted = bool(comment) and 'cc-cedict' in comment.lower()
        # One simplified form is a Pleco private-use glyph (讟 U+EA3C):
        # untypable and unrenderable, so the word has no simplified spelling.
        if any(unicodedata.category(c) == 'Co' for c in simp):
            simp = trad
        aliases: tuple[str, ...] = ()
        if any(bad in trad or bad in simp for bad in PLACEHOLDERS):
            aliases, pinyin = tuple(dict.fromkeys((trad, simp))), ''
            for bad, good in PLACEHOLDERS.items():
                trad, simp = trad.replace(bad, good), simp.replace(bad, good)
        recs.append(Rec(n, trad, simp, pinyin, jyutping, defs, adapted, 'canto', aliases))
    if failed or len(recs) != total:
        for n, line in failed[:20]:
            print(f"  UNPARSED {path.name}:{n}: {line}")
        raise SystemExit(f"ERROR: {len(failed)} of {total} lines in {path.name} did not parse")
    return recs


def parse_readings(path: Path) -> list[Rec]:
    recs, failed, total = [], [], 0
    for n, line in _read_lines(path):
        total += 1
        m = _READING_LINE.match(line)
        if not m:
            failed.append((n, line))
            continue
        trad, simp, pinyin, jyutping = m.groups()
        recs.append(Rec(n, trad, simp, pinyin, jyutping, '', False, 'readings'))
    if failed or len(recs) != total:
        for n, line in failed[:20]:
            print(f"  UNPARSED {path.name}:{n}: {line}")
        raise SystemExit(f"ERROR: {len(failed)} of {total} lines in {path.name} did not parse")
    return recs


# ── Pinyin (Mandarin cross-reference) ─────────────────────────

TONE_MARKS = {
    'a': 'āáǎàa', 'e': 'ēéěèe', 'i': 'īíǐìi',
    'o': 'ōóǒòo', 'u': 'ūúǔùu', 'ü': 'ǖǘǚǜü',
    'A': 'ĀÁǍÀA', 'E': 'ĒÉĚÈE', 'I': 'ĪÍǏÌI',
    'O': 'ŌÓǑÒO', 'U': 'ŪÚǓÙU', 'Ü': 'ǕǗǙǛÜ',
}
# Tone marks for syllabic n / m (唔 n2 → ń). Combining marks are written
# as escapes: U+0304 macron, U+0301 acute, U+030C caron, U+0300 grave.
_SYLLABIC_TONES = ('\u0304', '\u0301', '\u030c', '\u0300')


def _pinyin_syllable_to_unicode(base: str, tone: int) -> str | None:
    """'zhong', 1 → 'zhōng'. None if `base` is not a pinyin syllable."""
    base = base.replace('u:', 'ü').replace('U:', 'Ü').replace('v', 'ü').replace('V', 'Ü')
    low = base.lower()
    if not re.search('[aeiouü]', low):
        if low in ('n', 'm', 'ng', 'hm', 'hng'):
            if tone == 5:
                return base
            i = low.index('m') if 'm' in low else low.index('n')
            return unicodedata.normalize(
                'NFC', base[:i + 1] + _SYLLABIC_TONES[tone - 1] + base[i + 1:])
        if low == 'r' and tone == 5:                      # erhua 儿 r5
            return base
        return None
    if tone == 5:
        return base
    for i, ch in enumerate(base):
        if ch in 'aeAE':
            return base[:i] + TONE_MARKS[ch][tone - 1] + base[i + 1:]
    if 'ou' in low:
        i = low.index('o')
        return base[:i] + TONE_MARKS[base[i]][tone - 1] + base[i + 1:]
    for i in range(len(base) - 1, -1, -1):
        if base[i] in TONE_MARKS:
            return base[:i] + TONE_MARKS[base[i]][tone - 1] + base[i + 1:]
    return None


_PY_TOKEN = re.compile(
    r'(?P<lit>[A-Za-z]+\d+)¿'                  # 'Ｈ５¿' = literal, not pinyin
    r'|(?P<syl>(?:[A-Za-zü]|u:|U:)+)(?P<tone>[1-5])'
    r'|(?P<word>[A-Za-z]+)'
    r'|(?P<space>\s+)'
    r'|(?P<other>.)', re.S)


def pinyin_display(raw: str) -> str:
    """Numbered pinyin → tone marks, one syllable per space.

    Upstream often runs syllables together ('yi1fan1feng1shun4') or glues
    them to Latin words ('you3ｆｅｅｌ'); both are split. Letters spoken
    as letters ('Ｉ Q5') lose the neutral-tone digit.
    """
    s = unicodedata.normalize('NFKC', raw.replace('０¿', ''))
    out: list[str] = []
    prev = ''                                   # 'syl' | 'word' | 'space' | ''
    for m in _PY_TOKEN.finditer(s):
        kind = m.lastgroup
        if kind == 'tone':
            kind = 'syl'
        if kind == 'lit':
            text, kind = m.group('lit'), 'word'
        elif kind == 'syl':
            base, tone = m.group('syl'), int(m.group('tone'))
            conv = _pinyin_syllable_to_unicode(base, tone)
            if conv is None:                     # 'Q5', 'g5': not a syllable
                text, kind = (base if tone == 5 else base + str(tone)), 'word'
            else:
                text = conv
        elif kind == 'space':
            text = ' '
        else:
            text = m.group(0)
        if kind in ('syl', 'word') and prev in ('syl', 'word') and (kind == 'syl' or prev == 'syl'):
            out.append(' ')
        out.append(text)
        prev = kind
    s = re.sub(r'\s+', ' ', ''.join(out)).strip()
    # English spelled letter by letter: 'san4 b a n d' → 'sàn band'.
    return re.sub(r'(?<![^\W\d_])(?:[A-Za-z] ){2,}[A-Za-z](?![^\W\d_])',
                  lambda m: m.group(0).replace(' ', ''), s)


def pinyin_syllables(raw: str) -> list[str]:
    """Toneless lowercase pinyin syllables, for character alignment."""
    s = unicodedata.normalize('NFKC', raw).lower().replace('u:', 'v').replace('ü', 'v')
    return re.findall(r'[a-z]+(?=[1-5])', s)


# ── Jyutping ──────────────────────────────────────────────────

_JP_SYLLABLE = re.compile(
    r'^(?:(?:b|p|m|f|d|t|n|l|gw|kw|g|k|ng|h|w|z|c|s|j)?'
    r'(?:aa(?:i|u|m|n|ng|p|t|k)?|a(?:i|u|m|n|ng|p|t|k)?|e(?:i|u|m|n|ng|p|t|k)?'
    r'|i(?:u|m|n|ng|p|t|k)?|o(?:i|u|n|ng|t|k)?|u(?:i|n|ng|t|k)?'
    r'|oe(?:ng|t|k)?|eo(?:i|n|t)|yu(?:n|t)?)|m|ng)[1-6]$')


def is_jyutping_syllable(s: str) -> bool:
    return _JP_SYLLABLE.match(s) is not None


def jyutping_display(raw: str) -> str:
    """Clean upstream Jyutping for display.

    Keeps upstream conventions ('cin4*2' changed tone, 'hang4*haang4',
    ' / ' alternatives) and fixes noise: stray braces, 'X:' character
    prefixes ('一檔 jat1 檔:dong2'), characters, full-width letters and
    punctuation, capitals, run-together syllables ('bou3syu4'), detached
    tone digits ('mat 6') and lone digits ('dau6 2 fu6').
    """
    s = raw.replace('{', '').replace('}', '')
    s = re.sub(f'[{HAN}]+:', '', s)
    s = _HAN_RUN_RE.sub(' ', s)
    s = unicodedata.normalize('NFKC', s).lower()
    s = re.sub(r'(?:(?<=\s)|^):', '', s)
    s = re.sub(r'(?<=[1-6])(?=[a-z])', ' ', s)            # bou3syu4 → bou3 syu4
    s = re.sub(r'\b([a-z]+) ([1-6])(?=\s|$|[,;/])', r'\1\2', s)   # mat 6 → mat6
    s = re.sub(r'(?:(?<=\s)|^)[1-6](?=\s|$)', ' ', s)    # lone digits
    # Spelled-out English with neutral tones: 'p5 o5 w5 e5 r5' → 'power'
    s = re.sub(r'\b(?:[a-z]5 ){2,}[a-z]5\b', lambda m: m.group(0).replace('5', '').replace(' ', ''), s)
    s = re.sub(r'\s*,\s*', ', ', s)
    s = re.sub(r'\s*;\s*', '; ', s)
    s = re.sub(r'\s*/\s*', ' / ', s)
    s = re.sub(r'\s*(?:…+|\.{2,})\s*', ' … ', s)
    s = re.sub(r'\s+([!?)])', r'\1', s)
    s = re.sub(r'([(])\s+', r'\1', s)
    s = re.sub(r'(?<=[1-6])\(', ' (', s)                  # fu2(gei1) → fu2 (gei1)
    s = re.sub(r'(?<=[1-6])-\s+', '-', s)                  # aa3- hak1 → aa3-hak1
    s = re.sub(r'\s+', ' ', s).strip()
    s = re.sub(r'^[,;/… ]+|[,;/… ]+$', '', s)
    return s


def jyutping_readings(display: str, n_syllables: int | None) -> list[list[str]]:
    """Valid syllable sequences of a cleaned Jyutping string (for lookup keys).

    Alternatives are separated by ' / ' or ';'. An alternative shorter than
    the first one replaces its tail ('naa4 dou3 / dou2' → naa4 dou2).
    'cin4*2' yields both cin4 and cin2; 'hang4*haang4' both syllables.
    Readings with invalid syllables, or (when n_syllables is given) with
    the wrong number of syllables, are dropped.
    """
    alts = [a.split() for a in re.split(r' / |; ', display)]
    out: list[list[str]] = []
    first: list[str] | None = None
    for toks in alts:
        toks = [x.strip('(),!?…') for t in toks for x in t.split('-')]
        toks = [t for t in toks if t]
        if not toks:
            continue
        if first is not None and len(toks) < len(first) and n_syllables and len(first) == n_syllables:
            toks = first[:len(first) - len(toks)] + toks
        variants: list[list[str]] = [[]]
        ok = True
        for t in toks:
            opts: list[str] = []
            if '*' in t:
                head, _, tail = t.partition('*')
                opts.append(head)
                opts.append(re.sub(r'[1-6]$', tail, head) if re.fullmatch(r'[1-6]', tail) else tail)
            else:
                opts.append(t)
            if not all(is_jyutping_syllable(o) for o in opts):
                ok = False
                break
            variants = [v + [o] for v in variants for o in dict.fromkeys(opts)][:8]
        if not ok:
            continue
        if n_syllables and len(toks) != n_syllables:
            continue
        if first is None:
            first = toks
        for v in variants:
            if v not in out:
                out.append(v)
    return out


# ── Definitions ───────────────────────────────────────────────

# In original CC-Canto lines (not in CC-CEDICT ones, where 'she/her' is two
# senses) these pairs are one phrase, not two senses.
_PRON = r'(?:he|she|it|him|her|his|its|they|them|their)'
_SLASH_PHRASE = re.compile(
    rf'(?i)\b(?:and/ ?or|{_PRON}/ ?{_PRON}|himself/ ?herself|herself/ ?himself'
    r'|s/he|a/an)\b|\d/(?=\d)')
_DANGLING = re.compile(
    r'(?i)\b(?:and|or|the|a|an|of|to|for|with|his|her|their|by|in|on|at|from|as|is|are|be)$')
_SENTINEL = '\x00'

# Usage labels: '(noun)', '(of people)', '(Cantonese)'. Part-of-speech
# labels always introduce what follows them; other labels only when they
# open the text or follow ';' / ',' / a list number ('giant grouper (fish)'
# and 'too salty (spoken)' qualify the gloss before them).
_LABEL = r'\((?:[A-Za-z][A-Za-z .,/+\'-]{0,30})\)'
_POS = (r'(?:noun|verb|adjective|adverb|pronoun|conjunction|preposition|interjection'
        r'|(?:final )?particle|modal verb|measure word|classifier)')
_POS_LABEL = rf'\({_POS}\)'
_INTRO_LABEL_END = re.compile(
    rf'(?:(?:^|[;,]|\b\d{{1,2}}\.)\s*(?:{_LABEL}\s*)+|\s{_POS_LABEL}\s*|=\s*)$')


def split_definitions(defs: str, adapted: bool) -> list[str]:
    """Split the '/'-joined definition field into senses.

    Only a bare '/' separates senses: ' / ' with spaces joins alternatives
    inside one sense in both sources ('M: 件jiàn [件] / 桩zhuāng [桩]',
    'to extort / interrogate'). A '/' inside balanced parentheses never
    separates. Original CC-Canto lines also keep 'and/or', 'his/her',
    'a/an', '1/2/3' and fragments that end in 'and', 'the', ... together,
    and a part that ends in a label belongs to the next one: upstream
    '(adverb) 1. so; might (noun)/microphone; 2. mile' is one numbered
    list, and '(Cantonese)/to enjoy or relax' one sense.
    """
    s = defs
    if not adapted:
        s = _SLASH_PHRASE.sub(lambda m: m.group(0).replace('/', _SENTINEL), s)
    depth, low = 0, 0
    for ch in s:
        depth += ch in '(（'
        depth -= ch in ')）'
        low = min(low, depth)
    balanced = depth == 0 and low == 0
    parts, cur, depth = [], [], 0
    for i, ch in enumerate(s):
        if ch in '(（':
            depth += 1
        elif ch in ')）':
            depth -= 1
        if (ch == '/' and (depth == 0 or not balanced)
                and not (i > 0 and s[i - 1].isspace())
                and not (i + 1 < len(s) and s[i + 1].isspace())):
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append(''.join(cur))
    senses: list[str] = []
    for p in parts:
        p = p.replace(_SENTINEL, '/').strip()
        if not p:
            continue
        if senses and not adapted and _INTRO_LABEL_END.search(senses[-1]):
            senses[-1] = senses[-1] + ' ' + p
        elif senses and not adapted and _DANGLING.search(senses[-1]):
            senses[-1] = senses[-1] + '/' + p
        else:
            senses.append(p)
    return senses


_NUM_MARK = re.compile(r'(?:(?<=^)|(?<=[\s;:,()]))(\d{1,2})\.(?=[\s(A-Za-z"\'‘“]|$)')
_LABEL_ONLY = re.compile(rf'^(?:{_LABEL}\s*)+$')
_LABEL_BOUNDARY = re.compile(rf';\s*(?={_LABEL})')
# 'so; might (noun) microphone': a part-of-speech label after a word.
_POS_BOUNDARY = re.compile(rf'(?<=[A-Za-z.!?)\'"])\s+(?={_POS_LABEL}\s*[^\s;,])')
# Labels right before a list number belong to that item: a list that
# starts ('strength (of time or distance) 1. length') takes any label,
# a list that goes on only part-of-speech labels ('2. hardly study
# (adverb) 1. so' → 'hardly study' | '(adverb) so'), since a label before
# '2.' may qualify the gloss before it ('giant grouper (fish)').
_TRAILING_POS = re.compile(rf'(?<=\S)(?:\s+{_POS_LABEL})+\s*$')
_TRAILING_LABELS = re.compile(rf'(?<=\S)(?:\s+{_LABEL})+\s*$')
_ENDS_WITH_LABEL = re.compile(rf'(?:{_LABEL}|;)\s*$')
# A stray list number at the end of a sense: 'culture 2.', 'tyre (car)1.'.
_STRAY_END_NUMBER = re.compile(r'(?<=[A-Za-z)])\s*[1-9]\.$')
# A list that a '/' cut in two goes on after '; ': 'Clear up; (of
# computer) 3. Delete', 'microphone; 2. mile'.
_AFTER_SEMICOLON = re.compile(rf';\s*(?:{_LABEL}\s*)*$')


def expand_numbering(sense: str) -> list[str]:
    """'(adverb) 1. no; 2. nothing' → ['(adverb) no', 'nothing'].

    Inline numbering inside a sense would print as '1. (adverb) 1. no; 2.
    nothing' in the numbered list. Markers count only when they run
    1, 2, 3 ... (a restart at 1 or one skipped number is tolerated), so
    'Miss 13. Dot' or 'Year 1997.' never split. Inside a numbered sense,
    '; (verb) ...' and 'word (verb) ...' also start a new item.
    """
    sense = _STRAY_END_NUMBER.sub('', sense)
    marks, prev = [], None
    for m in _NUM_MARK.finditer(sense):
        n = int(m.group(1))
        # The first marker is 1, or any number that opens the sense (an
        # upstream line may continue another line's list: 上 '8. to climb')
        # or follows '; ' (the rest of a list that a '/' cut in two).
        after_semicolon = n <= 9 and _AFTER_SEMICOLON.search(sense[:m.start()]) is not None
        if prev is None:
            ok = n == 1 or m.start() == 0 or after_semicolon
        else:
            # '3. lie on (bed); 2. share (with cost)': upstream miscounts.
            ok = n == 1 or prev < n <= prev + 2 or after_semicolon
        if ok:
            marks.append(m)
            prev = n
    if not marks:
        return [sense]
    prefix = sense[:marks[0].start()]
    lone_one = len(marks) == 1 and int(marks[0].group(1)) == 1
    # A lone '1.' is a list number after labels or '; ' ('Rectify; (noun)
    # 1. Rectification'), not after a plain word.
    if lone_one and prefix.strip() and not _ENDS_WITH_LABEL.search(prefix):
        return [sense]
    chunks = [prefix]
    for a, b in zip(marks, marks[1:] + [None]):
        chunks.append(sense[a.end():b.start() if b else len(sense)])
    for i in range(len(chunks) - 1):
        trailing = _TRAILING_LABELS if int(marks[i].group(1)) == 1 else _TRAILING_POS
        m = trailing.search(chunks[i])
        if m:
            chunks[i + 1] = m.group(0) + ' ' + chunks[i + 1]
            chunks[i] = chunks[i][:m.start()]
    pieces: list[str] = []
    for c in chunks:
        for p in _LABEL_BOUNDARY.split(c):
            pieces.extend(_POS_BOUNDARY.split(p))
    items: list[str] = []
    carry = ''
    for p in pieces:
        p = re.sub(r'\s+', ' ', p).strip().rstrip(';,').strip()
        if not p:
            continue
        if _LABEL_ONLY.match(p):
            carry = (carry + ' ' + p).strip()
            continue
        items.append(f'{carry} {p}'.strip() if carry else p)
        carry = ''
    if carry:
        items.append(carry)
    if len(items) < 2:
        # A lone '1.' after the labels: '(noun) 1. Route 1/2/3'.
        if lone_one and len(items) == 1:
            return items
        return [sense]
    return items


def definition_items(defs: str, adapted: bool) -> list[str]:
    out: list[str] = []
    for sense in split_definitions(defs, adapted):
        for item in expand_numbering(sense):
            if item not in out:
                out.append(item)
    return out


# ── Simplified forms ──────────────────────────────────────────

class SimpConverter:
    """Traditional → simplified character table built from CC-CEDICT.

    CEDICT pairs every traditional character of a headword with its
    simplified counterpart; with aligned pinyin the table is also keyed by
    reading (閒 xian → 闲, 閒 jian → 间; 乾 gan → 干, 乾 qian → 乾).
    """

    def __init__(self, path: Path):
        self.by_char: dict[str, Counter] = defaultdict(Counter)
        self.by_reading: dict[tuple[str, str], Counter] = defaultdict(Counter)
        # Spelling variants: 'variant of X' pairs (歎/嘆, 剷/鏟, 閑/閒), the
        # characters CEDICT defines only as a variant (歎 → 嘆, 晒 → 曬),
        # and the definitions of each single character.
        self.variant_pairs: set[frozenset] = set()
        self.variant_only: dict[str, set[str]] = defaultdict(set)
        self.char_defs: dict[str, set[str]] = defaultdict(set)
        not_variant_only: set[str] = set()
        pat = re.compile(r'^(\S+)\s+(\S+)\s+\[([^\]]*)\]\s*/(.*)/\s*$')
        with open(path, encoding='utf-8') as f:
            for line in f:
                if line.startswith('#'):
                    continue
                m = pat.match(line)
                if not m:
                    continue
                t, s, py, defs = m.groups()
                for v in _VARIANT_OF.findall(defs):
                    if len(v) == len(t):
                        self.variant_pairs.update(frozenset((a, b)) for a, b in zip(t, v) if a != b)
                if len(t) == 1:
                    senses = [d.strip() for d in defs.split('/') if d.strip()]
                    targets = [_VARIANT_ONLY.match(d) for d in senses]
                    if senses and all(targets):
                        self.variant_only[t].update(x.group(1) for x in targets if x.group(1) != t)
                    else:
                        not_variant_only.add(t)
                    self.char_defs[t].update(d for d in senses if not _NOT_A_MEANING.match(d))
                if len(t) != len(s):
                    continue
                sylls = pinyin_syllables(py)
                aligned = len(sylls) == len(t) and all(is_han(c) for c in t)
                for i, (tc, sc) in enumerate(zip(t, s)):
                    if not is_han(tc):
                        continue
                    self.by_char[tc][sc] += 1
                    if aligned:
                        self.by_reading[(tc, sylls[i])][sc] += 1
        self.simp_targets = {sc for tc, cands in self.by_char.items() for sc in cands if sc != tc}
        for t in not_variant_only:
            self.variant_only.pop(t, None)

    def variant_chars(self, a: str, b: str) -> bool:
        """Whether two characters are spellings of one character in words:
        a standard/variant pair (説/說), a CEDICT 'variant of' pair (剷/鏟,
        閑/閒, 晒/曬), one character's meanings a subset of the other's
        (骾 'to choke on a piece of food' ⊂ 鯁), or 麵 that upstream wrote for
        面 'face' (黑口黑麵, 麵青青)."""
        if VARIANT_TO_STANDARD.get(a) == b or VARIANT_TO_STANDARD.get(b) == a:
            return True
        if frozenset((a, b)) in self.variant_pairs or frozenset((a, b)) in UPSTREAM_SAME_IN_WORDS:
            return True
        da, db = self.char_defs.get(a), self.char_defs.get(b)
        return bool(da and db and (da <= db or db <= da))

    def pure_variant(self, a: str, b: str) -> bool:
        """Whether one character is only a variant spelling of the other
        (歎 of 嘆, 羣 of 群), as opposed to characters that share a simplified
        form but differ in traditional writing (台/臺, 摺/折, 制/製)."""
        if a in HK_WRITTEN or b in HK_WRITTEN:
            return False
        if VARIANT_TO_STANDARD.get(a) == b or VARIANT_TO_STANDARD.get(b) == a:
            return True
        return b in self.variant_only.get(a, ()) or a in self.variant_only.get(b, ())

    def simplified_only(self, word: str) -> int:
        """How many characters of `word` CEDICT only ever uses as a
        simplified form (养, 话, 沥), never in a traditional headword.
        Characters that Hong Kong Cantonese writing uses as they are
        (諗吓 haa5, 着 zoek6, 叠 dip6) do not count."""
        return sum(1 for c in word if c in self.simp_targets and c not in self.by_char
                   and c not in HK_WRITTEN)

    def trad_frequency(self, word: str) -> int:
        """How often CEDICT writes the characters of `word` in traditional headwords."""
        return sum(sum(self.by_char[c].values()) for c in word if c in self.by_char)

    def keeps_itself(self, tc: str) -> bool:
        """False for a traditional-only character (膠, 濕, 衞) that a
        simplified spelling must convert; True if CEDICT also writes it
        unchanged (乾, 著) or does not know it (Cantonese 嘅, 冚)."""
        cands = self.by_char.get(tc)
        std = VARIANT_TO_STANDARD.get(tc)
        if std and (not cands or set(cands) == {tc}):
            return std in self.by_char.get(std, ())
        return not cands or tc in cands

    def _cands(self, tc: str, syll: str | None) -> tuple[Counter | None, bool]:
        """Simplified candidates for `tc`, and whether they are reading-specific."""
        cands = self.by_reading.get((tc, syll)) if syll else None
        specific = bool(cands)
        if not cands:
            cands = self.by_char.get(tc)
        std = VARIANT_TO_STANDARD.get(tc)
        # CEDICT lists variant characters (衞, 説) as entries of their own
        # that keep the variant; simplify through the standard form instead.
        if std and (not cands or set(cands) == {tc}):
            by_std = self.by_reading.get((std, syll)) if syll else None
            specific = bool(by_std)
            cands = by_std or self.by_char.get(std)
        return cands, specific

    def _best(self, tc: str, syll: str | None) -> str:
        if tc in CANTONESE_KEEP:
            return tc
        cands, _ = self._cands(tc, syll)
        if not cands:
            return tc
        sc = cands.most_common(1)[0][0]
        # Cantonese characters whose CEDICT simplification is a rare
        # extension-block character (劏 → 㓥, 嗰 → 𠮶, 餸 → 𩠌) stay as
        # they are, as simplified Cantonese writes them.
        if sc != tc and not '\u4e00' <= sc <= '\u9fff':
            return tc
        return sc

    def derive(self, trad: str, pinyin_raw: str, jyutping_raw: str = '') -> str:
        sylls = pinyin_syllables(pinyin_raw)
        aligned = len(sylls) == len(trad) and all(is_han(c) for c in trad)
        jp = jyutping_syllables(trad, jyutping_raw)
        out = []
        for i, tc in enumerate(trad):
            by_jp = READING_SIMP.get((tc, jp[i])) if jp else None
            if by_jp:
                out.append(by_jp)
            elif is_han(tc):
                out.append(self._best(tc, sylls[i] if aligned else None))
            else:
                out.append(tc)
        return ''.join(out)

    def correct(self, trad: str, simp: str, pinyin_raw: str, jyutping_raw: str = '') -> str:
        """Upstream simplified form with its known errors fixed (for display).

        Upstream's simplified column follows the PRC variant tables (甚 →
        什, 絃 → 弦, 想像 → 想象, 捱 → 挨), which a character table cannot
        verify, so a character is changed only when upstream left a
        traditional-only character unconverted (免稅店 → 免税店, 吹波膠 →
        吹波胶) or used one of the wrong pairs in WRONG_SIMPLIFIED (偷雞唔到
        蝕揸米: upstream 偷鸡唔到食揸米 → 偷鸡唔到蚀揸米; 佢哋: 渠哋 → 佢哋).
        """
        if len(trad) != len(simp):
            return simp
        sylls = pinyin_syllables(pinyin_raw)
        aligned = len(sylls) == len(trad) and all(is_han(c) for c in trad)
        jp = jyutping_syllables(trad, jyutping_raw)
        out = []
        for i, (tc, sc) in enumerate(zip(trad, simp)):
            syll = sylls[i] if aligned else None
            fix = WRONG_SIMPLIFIED.get((tc, sc))
            # 甚 is simplified to 什 only in 甚麼 → 什么 (甚至無: 甚至无).
            if ((tc, sc) == ('甚', '什') and len(trad) > 1
                    and trad[i + 1:i + 2] not in ('麼', '麽', '么')):
                fix = '甚'
            by_jp = READING_SIMP.get((tc, jp[i])) if jp else None
            if by_jp:
                out.append(by_jp)
            elif fix:
                out.append(fix)
            elif sc == tc and is_han(tc) and not self.keeps_itself(tc):
                out.append(self._best(tc, syll))
            else:
                out.append(sc)
        return ''.join(out)


_VARIANT_OF = re.compile(rf'variant of ([{HAN}]+)')
_VARIANT_ONLY = re.compile(
    rf'^(?:\([^()]*\)\s*)?(?:old |archaic |ancient |)variant of ([{HAN}])(?:\|[{HAN}])?'
    r'(?:\[[^\]]*\])?\s*$')
_NOT_A_MEANING = re.compile(r'^(?:surname |used in |\(?(?:old |archaic |ancient |)variant of )')

# 麵 'noodles' stands for 面 'face' in some upstream traditional spellings
# (黑口黑麵 next to 黑口黑面): in words these are one spelling.
UPSTREAM_SAME_IN_WORDS = {frozenset('麵面')}

# Simplified-looking characters that traditional Hong Kong Cantonese text
# uses as they are (諗吓, 着衫, 叠埋, 扑嘢, 黄, 痹, 响).
HK_WRITTEN = frozenset('吓着叠扑黄痹响')

# Characters written unchanged in simplified Cantonese although CEDICT maps
# them to another character: 噉 gam2 'like this' (CEDICT → 啖 daam6), 妳
# 'you (female)' (CEDICT, by its reading nǎi, → 奶 'milk').
CANTONESE_KEEP = frozenset('噉妳')

# Wrong character pairs in the upstream simplified column → the right
# simplified character.
WRONG_SIMPLIFIED: dict[tuple[str, str], str] = {
    ('阿', '啊'): '阿', ('佢', '渠'): '佢', ('囉', '罗'): '啰', ('蝕', '食'): '蚀',
    ('期', '朞'): '期', ('像', '象'): '像', ('擘', '掰'): '擘', ('撚', '捻'): '撚',
    ('恃', '特'): '恃', ('淺', '钱'): '浅',
    ('網', '纲'): '网', ('貢', '页'): '贡', ('時', '记'): '时', ('麗', '利'): '丽',
    ('妳', '奶'): '你', ('噉', '啖'): '噉', ('耶', '爷'): '耶', ('訂', '定'): '订',
}

# Characters whose simplified form depends on the reading. Upstream pinyin
# is unreliable for these (傾閒偈 has 'jian1' for haan4 and so got 倾间偈),
# so the Jyutping decides: 閒 haan4 'idle' = 闲. Other readings keep
# upstream's choice (閒 gaan3 is 间 or 闲 depending on the word).
# 乾 gon1 'dry' is 干, 乾 kin4 'heaven' (the trigram, 乾坤) stays 乾; upstream
# has the two swapped for the single character.
READING_SIMP: dict[tuple[str, str], str] = {
    ('閒', 'haan4'): '闲', ('乾', 'gon1'): '干', ('乾', 'kin4'): '乾'}


def jyutping_syllables(trad: str, jyutping_raw: str) -> list[str] | None:
    """Toned Jyutping syllables aligned one per character of `trad`, or None."""
    if not jyutping_raw or not all(is_han(c) for c in trad):
        return None
    sylls = jyutping_display(jyutping_raw).split(' / ')[0].split()
    sylls = [re.sub(r'\*.*$', '', t.strip(',;!?()…')) for t in sylls]
    return sylls if len(sylls) == len(trad) else None


# Non-standard variant characters in upstream traditional forms → the
# standard traditional character that HK/TW keyboards type.
VARIANT_TO_STANDARD = {
    '説': '說', '閲': '閱', '鋭': '銳', '悦': '悅', '脱': '脫', '蜕': '蛻',
    '兑': '兌', '衞': '衛', '羣': '群', '峯': '峰', '敍': '敘', '衆': '眾',
    '麪': '麵', '綫': '線', '裏': '裡', '裡': '裏', '着': '著', '爲': '為',
    '僞': '偽', '甯': '寧', '綉': '繡', '綳': '繃', '鈎': '鉤', '綑': '捆',
    '啓': '啟', '敎': '教', '册': '冊', '强': '強', '眞': '真', '戸': '戶',
}


def standard_variants(trad: str) -> list[str]:
    std = ''.join(VARIANT_TO_STANDARD.get(c, c) for c in trad)
    return [std] if std != trad else []


# ── Lookup-key variants (full-width Latin, punctuation) ───────

_PUNCT = re.compile(r'[\s，,、。．.…！!？?；;：:\-－‐–—·・‧（）()「」『』“”"〜~]+')
_ELLIPSIS = re.compile(r'(?:…+|\.{2,}|．{2,})')
_PAREN_GROUP = re.compile(r'[（(][^（）()]*[）)]')


def key_variants(key: str) -> list[str]:
    """Forms a user may type for `key`: NFKC (full-width Latin and digits to
    ASCII), full-width comma, the key without punctuation, ellipsis
    spellings, and without an optional parenthesised part."""
    if not _HAN_RE.search(key):
        return []
    forms: list[str] = []
    base = [key]
    nfkc = unicodedata.normalize('NFKC', key)
    if nfkc != key:
        base.append(nfkc)
    for k in base:
        if ',' in k:
            forms.append(k.replace(',', '，'))
        if _ELLIPSIS.search(k):
            for e in ('…', '……', '...'):
                forms.append(_ELLIPSIS.sub(e, k))
        if _PAREN_GROUP.search(k):
            forms.append(_PAREN_GROUP.sub('', k))
        stripped = _PUNCT.sub('', k)
        if stripped and stripped != k and _HAN_RE.search(stripped):
            forms.append(stripped)
    forms.extend(base[1:])
    seen = []
    for f in forms:
        f = f.strip()
        if f and f != key and f not in seen:
            seen.append(f)
    return seen


# ── Articles ──────────────────────────────────────────────────

@dataclass
class Block:
    simp: str                         # displayed simplified form
    defs: tuple[str, ...]
    adapted: bool
    source: str
    jyutping: list[str] = field(default_factory=list)   # cleaned, unique
    pinyin: list[str] = field(default_factory=list)     # display, unique

    def signature(self):
        return (self.simp, self.defs, self.adapted, self.source,
                tuple(self.jyutping), tuple(self.pinyin))


@dataclass
class Article:
    trad: str
    blocks: list[Block] = field(default_factory=list)
    also: list[str] = field(default_factory=list)       # merged identical trads
    forms: list[str] = field(default_factory=list)      # extra lookup forms
    lines: list[int] = field(default_factory=list)

    @property
    def source(self) -> str:
        return 'canto' if any(b.source == 'canto' for b in self.blocks) else 'readings'

    def signature(self):
        return tuple(b.signature() for b in self.blocks)


def add_record(articles: dict[str, Article], rec: Rec, simp: str, defs: list[str],
               forms: list[str]) -> None:
    art = articles.get(rec.trad)
    if art is None:
        art = articles[rec.trad] = Article(rec.trad)
    art.lines.append(rec.line)
    for f in forms:
        if f != rec.trad and f not in art.forms:
            art.forms.append(f)
    jp = jyutping_display(rec.jyutping)
    py = pinyin_display(rec.pinyin) if rec.pinyin.strip() else ''
    key = (simp, tuple(defs), rec.adapted, rec.source)
    for b in art.blocks:
        if (b.simp, b.defs, b.adapted, b.source) == key:
            block = b
            break
    else:
        block = Block(simp, tuple(defs), rec.adapted, rec.source)
        art.blocks.append(block)
    if jp and jp not in block.jyutping:
        block.jyutping.append(jp)
    if py and py not in block.pinyin:
        block.pinyin.append(py)


# ── HTML ──────────────────────────────────────────────────────

FLAG_HK = '\U0001F1ED\U0001F1F0'  # 🇭🇰
FLAG_CN = '\U0001F1E8\U0001F1F3'  # 🇨🇳
FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_HK}{FLAG_CN} 粵語 → English {FLAG_EN}'

_SEC_L, _SEC_D = TEXT_SECONDARY
_LINK_L, _LINK_D = TEXT_LINK

CSS = get_css(
    ORDERED_LIST,
    extra_light=(
        f'.t{{font-size:1.25em;color:{_SEC_L};display:block;margin-top:2px}}'
        f'.jp{{font-size:1.15em;color:{_LINK_L};display:block;margin-top:2px}}'
        f'.py{{font-size:0.95em;color:{_SEC_L};font-style:italic;display:block;margin-top:1px}}'
        f'.al{{font-size:0.9em;color:{_SEC_L};display:block;margin-top:2px}}'
        f'.nt{{font-size:0.9em;color:{_SEC_L}}}'
        '.rd+.rd{margin-top:10px}'
    ),
    extra_dark=(
        f'.t{{color:{_SEC_D}}}.jp{{color:{_LINK_D}}}.py{{color:{_SEC_D}}}'
        f'.al{{color:{_SEC_D}}}.nt{{color:{_SEC_D}}}'
    ),
)

CSS_INDEX = get_css(
    extra_light=(
        '.ix{list-style:none;margin:2px 0;padding:0}'
        '.ix li{margin:4px 0;font-size:1.1em}'
        f'.ix a{{color:{_LINK_L};text-decoration:none;font-size:1.15em}}'
        f'.ixj{{color:{_LINK_L};margin-left:8px}}'
        f'.ixg{{color:{_SEC_L};margin-left:8px;font-size:0.9em}}'
    ),
    extra_dark=f'.ix a,.ixj{{color:{_LINK_D}}}.ixg{{color:{_SEC_D}}}',
)

READINGS_NOTE = ('Cantonese reading from the CC-CEDICT Cantonese Readings list; '
                 'CC-Canto has no entry for this word. See CC-CEDICT for its meaning.')

# CEDICT-style references in adapted lines, as Pleco wrote them:
# '乜嘢miēyě [乜嘢]', 'M: 件jiàn [件] / 桩zhuāng [桩]', '埃及Āijí [埃及]',
# '安徽省 Ānhuī Shěng [安徽省]' (capitalised, spaced pinyin of names).
_PY_LETTERS = ('A-Za-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüńňǹḿ'
               'ĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙǕǗǙǛÜ\u0300-\u036f·\'’-')
_CEDICT_REF = re.compile(
    rf'(?P<w>[{HAN}]+(?:\|[{HAN}]+)?)'
    rf'(?: ?(?P<py>[{_PY_LETTERS}]+(?: [{_PY_LETTERS}]+)*))?\s?\[(?P<b>[{HAN}|]+)\]')
_XREF = re.compile(
    rf'(?P<p>(?:[Ss]ee(?: also)?|[Vv]ariant of|[Oo]ld variant of|[Aa]bbr\. for|[Ss]hort for'
    rf'|[Aa]lso written|[Ss]ame as|[Ee]rhua variant of|[Cc]lassifier for)\s?)(?P<w>[{HAN}]+)')


def render_definition(text: str, keys: set[str]) -> str:
    """Escape a definition, turning references to existing keys into links."""
    out, last = [], 0
    spans = []
    for m in _CEDICT_REF.finditer(text):
        spans.append((m.start(), m.end(), 'cedict', m))
    for m in _XREF.finditer(text):
        if not any(a <= m.start('w') < b for a, b, _, _ in spans):
            spans.append((m.start('w'), m.end('w'), 'xref', m))
    spans.sort(key=lambda s: s[0])
    for start, end, kind, m in spans:
        if start < last:
            continue
        out.append(esc(text[last:start]))
        if kind == 'cedict':
            word = m.group('w').split('|')[-1]
            bracket = m.group('b').split('|')[-1]
            # Prefer the traditional form ('這樣|这样'): articles are keyed by it.
            target = next((c for c in m.group('w').split('|') + m.group('b').split('|')
                           if c in keys), None)
            out.append(entry_link(target, m.group('w')) if target else esc(m.group('w')))
            if m.group('py'):
                out.append(' ' + esc(m.group('py')))
            if bracket != word:
                out.append(f' [{esc(m.group("b"))}]')
        else:
            word = m.group('w')
            if not m.group('p')[-1:].isspace():          # 'same as奶' → 'same as 奶'
                out.append(' ')
            out.append(entry_link(word) if word in keys else esc(word))
        last = end
    out.append(esc(text[last:]))
    return ''.join(out)


def plain_definition(text: str) -> str:
    """A definition as plain text: '您nín [您]' → '您 nín', '這樣|这样' → '這樣'."""
    def ref(m: re.Match) -> str:
        word = m.group('w').split('|')[0]
        return f"{word} {m.group('py')}" if m.group('py') else word
    text = _CEDICT_REF.sub(ref, text)
    return _XREF.sub(lambda m: m.group('p').rstrip() + ' ' + m.group('w'), text)


def ordered_blocks(art: Article) -> list[Block]:
    """Blocks in display order. Upstream order, except that a single
    character lists its fullest reading first: 食 sik6 'to eat; food ...'
    before ji6 'used in names of people', 金 'gold ...' before its slang
    sense, 噉 gam2 'like this' before daam6 'to eat'. On a tie the block
    adapted from CC-CEDICT, with the general meaning, comes first: 蛇
    'snake' before its slang senses, 慢 'slow' before 'eventually'."""
    if len(art.trad) == 1:
        return sorted(art.blocks, key=lambda b: (-len(b.defs), not b.adapted))
    return art.blocks


def make_article_html(art: Article, keys: set[str]) -> str:
    simps = {b.simp for b in art.blocks}
    common_simp = next(iter(simps)) if len(simps) == 1 else None
    parts = [f'<span class="dir">{DIR_LABEL}</span>', headword(art.trad, lang='zh-HK')]
    if common_simp and common_simp != art.trad:
        parts.append(f'<span class="t" lang="zh-CN">{esc(common_simp)}</span>')
    if art.also:
        parts.append(f'<span class="al">also written <span lang="zh-HK">'
                     f'{esc("、".join(art.also))}</span></span>')
    for b in ordered_blocks(art):
        blk = ['<div class="rd">']
        if common_simp is None and b.simp != art.trad:
            blk.append(f'<span class="t" lang="zh-CN">{esc(b.simp)}</span>')
        if b.jyutping:
            blk.append(f'<span class="jp">{esc(" / ".join(b.jyutping))}</span>')
        if b.pinyin:
            blk.append(f'<span class="py">普 {esc(" / ".join(b.pinyin))}</span>')
        if b.source == 'readings':
            blk.append(f'<div class="sn"><span class="nt">{esc(READINGS_NOTE)}</span></div>')
        else:
            head = (f'<div class="sn-hd">{mark_badge("adapted from CC-CEDICT")}</div>'
                    if b.adapted else '')
            items = ''.join(f'<li>{render_definition(d, keys)}</li>' for d in b.defs)
            blk.append(f'<div class="sn">{head}<ol class="d">{items}</ol></div>')
        blk.append('</div>')
        parts.append(''.join(blk))
    return f'{CSS}<div class="e">{"".join(parts)}</div>'


def short_gloss(art: Article, reading: str | None = None, limit: int = 48) -> str:
    """First definition, shortened; for `reading`, of a block with that reading."""
    blocks = ordered_blocks(art)
    if reading:
        bare = re.sub(r'[1-6]', '', reading.replace(' ', ''))
        def has(b: Block) -> bool:
            return any(reading == ' '.join(r) or bare == re.sub(r'[1-6]', '', ''.join(r))
                       for jp in b.jyutping for r in jyutping_readings(jp, None))
        blocks = [b for b in blocks if has(b)] + [b for b in blocks if not has(b)]
    for b in blocks:
        if b.defs:
            g = plain_definition(b.defs[0])
            if len(g) > limit:
                cut = g[:limit].rsplit(' ', 1)[0]
                g = (cut if len(cut) > limit // 2 else g[:limit]).rstrip(' ,;:(') + '…'
            return g
    return ''


def gloss_has_word(art: Article, word: str) -> bool:
    """Whether `word` is itself a gloss of `art`: 鑊 'wok (dialect)', 弗
    'fit (loanword)', 乒 '(onom.) ping, ...'; not 拖 'to drag' for 'to'."""
    for b in art.blocks:
        for d in b.defs:
            text = re.sub(r'\([^()]*\)', ' ', plain_definition(d))
            for piece in re.split(r'[,;/]', text):
                piece = re.sub(r'^(?:to|a|an|the) ', '', piece.strip(' .!?"\'').lower())
                if piece == word:
                    return True
    return False


def make_index_html(reading: str, items: list[tuple[str, str, str]]) -> str:
    """Index article for a Jyutping key: one line per word, linked."""
    lis = ''.join(
        f'<li>{entry_link(word)}<span class="ixj">{esc(jp)}</span>'
        + (f'<span class="ixg">{esc(gloss)}</span>' if gloss else '') + '</li>'
        for word, jp, gloss in items)
    return (f'{CSS_INDEX}<div class="e"><span class="dir">Jyutping → 粵語</span>'
            f'<span class="hw">{esc(reading)}</span>'
            f'<div class="sn"><ul class="ix">{lis}</ul></div></div>')


# ── Preview ──────────────────────────────────────────────────

SAMPLE_WORDS = ['佢', '唔該', '咁', '冇', '靚仔', '搞掂']


def _generate_preview(articles: dict[str, Article], keys: set[str]):
    found = [hw for hw in SAMPLE_WORDS if hw in articles]
    if len(found) < 3:
        found = list(articles)[:6]
        print(f"  ⚠ Sample words not found, using first {len(found)} entries")
    preview_path = OUTPUT_DIR / "cc_canto_preview.html"
    _shared_preview([make_article_html(articles[hw], keys) for hw in found[:6]],
                    preview_path, f'{DICT_NAME} — preview')


# ── Header description ────────────────────────────────────────

def header_description() -> str:
    """The MDX header description in the shared layout (shared.build.description_html).

    Depends only on INCLUDE_READINGS, so it is the same whether or not the
    data files are present.
    """
    about = [
        "Cantonese words, slang and idioms with Jyutping, Mandarin pinyin and "
        "English definitions. CC-Canto is a Cantonese supplement to CC-CEDICT: words "
        "that mean the same as in Mandarin (香港, 多謝) are left to CC-CEDICT. "
        "Search by traditional or simplified characters, or by Jyutping "
        "(<i>m4 goi1</i>, <i>m4goi1</i>, <i>mgoi</i>).",
    ]
    source = (
        "CC-Canto © 2015–2017 Pleco Inc., "
        '<a href="https://cantonese.org/">cantonese.org</a>. '
        "Entries marked “adapted from CC-CEDICT” are based on "
        '<a href="https://cc-cedict.org/">CC-CEDICT</a>, © its maintainers (MDBG), '
        "portions © 1997, 1998 Paul Andrew Denisowski."
    )
    if INCLUDE_READINGS:
        about.append(
            "Also includes the <i>CC-CEDICT Cantonese Readings</i>: Jyutping for about "
            "100,000 CC-CEDICT words that CC-Canto does not define, shown without "
            "definitions.")
        source += " CC-CEDICT Cantonese Readings version 2015-09-23, © 2015 Pleco Inc."
    return description_html(
        title="CC-Canto Cantonese-English Dictionary",
        subtitle="version 2017-02-02",
        about=about,
        source=source,
        license='CC-Canto is licensed under '
                '<a href="https://creativecommons.org/licenses/by-sa/3.0/">CC BY-SA 3.0</a>.',
        changes="records merged per traditional headword, Jyutping and pinyin cleaned, "
                "simplified spellings corrected, lookup keys added",
        adaptation_license="This adaptation is also licensed under CC BY-SA 3.0.",
    )


def descriptions() -> dict[str, str]:
    """{"<Name>.mdx": header description} for every dictionary this script builds."""
    return {f"{DICT_NAME}.mdx": header_description()}


# ── Main ──────────────────────────────────────────────────────

def check_cedict_release(path: Path) -> None:
    """Print the CC-CEDICT release the character table comes from, and warn
    when it is not the one the shipped MDX was built with."""
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    date = ''
    with open(path, encoding='utf-8') as f:
        for line in f:
            if not line.startswith('#'):
                break
            if line.startswith('#! date='):
                date = line.strip()[8:]
    print(f"  CC-CEDICT character table: release {date or '?'}, SHA-256 {digest[:16]}…")
    if (date, digest) != CEDICT_TESTED:
        print(f"  WARNING: {path.name} is not the tested release {CEDICT_TESTED[0]} "
              f"(SHA-256 {CEDICT_TESTED[1][:16]}…); some simplified headings and "
              "keys may differ from the shipped MDX.")


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for path in (CANTO_FILE, CEDICT_FILE) + ((READINGS_FILE,) if INCLUDE_READINGS else ()):
        if not path.exists():
            raise SystemExit(f"ERROR: {path} not found (run scripts/fetch_data.sh)")

    print("Parsing CC-Canto...")
    canto = parse_cccanto(CANTO_FILE)
    n_adapted = sum(r.adapted for r in canto)
    print(f"  {len(canto)} records ({n_adapted} adapted from CC-CEDICT), 0 unparsed")
    check_cedict_release(CEDICT_FILE)
    conv = SimpConverter(CEDICT_FILE)

    articles: dict[str, Article] = {}
    simp_fixes: list[tuple[int, str, str, str]] = []
    for r in canto:
        simp = conv.correct(r.trad, r.simp, r.pinyin, r.jyutping)
        if simp != r.simp:
            simp_fixes.append((r.line, r.trad, r.simp, simp))
        # Lines adapted from CC-CEDICT copy one pinyin to every Jyutping
        # reading (乾 [gan1] for both gon1 'dry' and kin4 'heaven'), so they
        # get no reading-based derived spelling. correct() is still safe for
        # them: it only converts characters that are never simplified as
        # themselves (傷 → 伤, 優 → 优, which upstream left unconverted).
        if r.adapted:
            forms = [simp, r.simp]
        else:
            # Lookup forms: the corrected and the CEDICT-derived simplified
            # spelling, and upstream's own unless it is a wrong single
            # character (啊 for 阿) that would add noise to that lookup.
            forms = [simp, conv.derive(r.trad, r.pinyin, r.jyutping)]
            if not (len(r.trad) == 1 and (r.trad, r.simp) in WRONG_SIMPLIFIED):
                forms.append(r.simp)
        forms += standard_variants(r.trad) + list(r.aliases)
        add_record(articles, r, simp, definition_items(r.defs, r.adapted), forms)
    print(f"  {len(articles)} traditional headwords; "
          f"{len(simp_fixes)} records with a corrected simplified form")

    # Identical articles under different traditional spellings (臺灣人 /
    # 台灣人): keep one, list the others as 'also written' and redirect them.
    # Upstream sometimes put a simplified spelling in the traditional column
    # (休养所 next to 休養所), so the kept heading is the spelling with the
    # fewest simplified-only characters, then the fewest non-standard
    # variants (麪 for 麵); a single character then takes the form CEDICT
    # uses most (館 over 舘); otherwise the first in upstream order wins.
    groups: dict[tuple, list[str]] = defaultdict(list)
    for trad, art in articles.items():
        groups[art.signature()].append(trad)
    merged = 0
    for trads in groups.values():
        if len(trads) < 2:
            continue
        keep = min(trads, key=lambda t: (
            conv.simplified_only(t),
            sum(c in VARIANT_TO_STANDARD and c not in HK_WRITTEN
                and VARIANT_TO_STANDARD[c] not in VARIANT_TO_STANDARD for c in t),
            -conv.trad_frequency(t) if len(t) == 1 else 0,
            trads.index(t)))
        target = articles[keep]
        shown_simps = {b.simp for b in target.blocks}
        for trad in trads:
            if trad == keep:
                continue
            art = articles.pop(trad)
            if trad not in shown_simps:
                target.also.append(trad)
            for f in [trad] + art.forms:
                if f != keep and f not in target.forms:
                    target.forms.append(f)
            target.lines += art.lines
            merged += 1
    print(f"  {merged} duplicate articles merged")

    n_readings_articles = 0
    if INCLUDE_READINGS:
        readings = parse_readings(READINGS_FILE)
        canto_forms = set(articles)
        for art in articles.values():
            canto_forms.update(art.also)
        # CEDICT lists some simplified-only spellings as their own entry
        # ('凄切 凄切' next to '淒切 凄切'); the simplified key covers them.
        simp_of_other = {(r.simp, jyutping_display(r.jyutping))
                         for r in readings if r.trad != r.simp}
        for r in readings:
            if r.trad in canto_forms:
                continue
            if r.trad == r.simp and (r.trad, jyutping_display(r.jyutping)) in simp_of_other:
                continue
            fresh = r.trad not in articles
            add_record(articles, r, r.simp, [], [r.simp] + standard_variants(r.trad))
            n_readings_articles += fresh
        print(f"  {len(readings)} CC-CEDICT readings → {n_readings_articles} reading-only articles")

    # ── Keys ──
    main_keys = set(articles)
    redirects: dict[str, list[str]] = defaultdict(list)

    def link(key: str, target: str):
        if key and key != target and target not in redirects[key]:
            redirects[key].append(target)

    for trad, art in articles.items():
        forms = [trad] + art.forms
        for f in art.forms:
            link(f, trad)
        for f in forms:
            # Upstream '０靚仔' spellings stay as keys (installed apps may have
            # them bookmarked), but their variants ('0靚仔') are noise.
            if any(bad in f for bad in PLACEHOLDERS):
                continue
            for v in key_variants(f):
                link(v, trad)

    # Spelling variants of one word are separate upstream records. Each
    # spelling also shows the others, as the simplified lookup does. Words
    # with the same simplified form are variants when they have the same
    # syllables (三腳凳 / 三腳櫈, 米舖 / 米鋪; tones may differ, as upstream
    # marks changed tones inconsistently) or differ only in variant
    # characters, whatever the reading (冚家剷 gam2 / 冚家鏟 ham6, 好閑 /
    # 好閒, 曬命 / 晒命). Different words that share a simplified form
    # (鬱鬱 / 郁郁, 嚇嚇 / 吓吓) stay apart. A single character shows a pure
    # variant spelling (嘆 / 歎) when that one has Cantonese senses of its
    # own; 台 / 臺, 折 / 摺 are different characters in traditional writing.
    by_simp: dict[str, list[str]] = defaultdict(list)
    for trad, art in articles.items():
        if art.source == 'canto':
            for simp in dict.fromkeys(b.simp for b in art.blocks):
                by_simp[simp].append(trad)
    sounds = {t: {re.sub(r'[1-6]', '', ' '.join(r)) for b in articles[t].blocks
                  for jp in b.jyutping for r in jyutping_readings(jp, None)}
              for trads in by_simp.values() if len(trads) > 1 for t in trads}

    def spelling_variants(a: str, b: str) -> bool:
        if len(a) != len(b):
            return False
        if len(a) == 1:
            return (conv.pure_variant(a, b)
                    and any(not blk.adapted for blk in articles[b].blocks))
        return bool(sounds[a] & sounds[b]) or all(
            x == y or conv.variant_chars(x, y) for x, y in zip(a, b))

    n_variant_links = 0
    for trads in by_simp.values():
        for a in trads:
            for b in trads:
                if a != b and b not in redirects[a] and spelling_variants(a, b):
                    link(a, b)
                    n_variant_links += 1
    print(f"  {n_variant_links} links between spelling variants")

    # Jyutping keys
    index_articles: dict[str, str] = {}
    if JYUTPING_INDEX:
        by_reading: dict[str, list[str]] = defaultdict(list)
        unkeyed: list[str] = []
        for trad, art in articles.items():
            n = len(trad) if all(is_han(c) for c in trad) else None
            if n is None:
                hans = [c for c in trad if is_han(c)]
                if len(hans) != len(re.sub(r'[\W_]', '', trad)):
                    continue                # mixed Latin/Han words: no keys
                n = len(hans)
            for b in art.blocks:
                for jp in b.jyutping:
                    valid = jyutping_readings(jp, n)
                    if not valid:
                        unkeyed.append(f'{trad} {{{jp}}}')
                    for sylls in valid:
                        reading = ' '.join(sylls)
                        if trad not in by_reading[reading]:
                            by_reading[reading].append(trad)
        # Upstream errors such as 人蔘 'jan4' (one syllable for two
        # characters) get no Jyutping key; listed for an upstream report.
        print(f"  {len(unkeyed)} readings without a valid syllable-per-character "
              f"Jyutping (no key), e.g. {', '.join(unkeyed[:6])}")
        # Homophones are listed most common first. CC-Canto has no frequency
        # data, so the proxy is how many other headwords contain the word:
        # 係 is part of 唔係, 係咪, 就係 ..., while its homophone 妎 is in none.
        in_words: Counter = Counter()
        for trad in articles:
            n = len(trad)
            in_words.update({trad[i:j] for i in range(n)
                             for j in range(i + 1, min(n, i + 4) + 1) if j - i < n})
        for words in by_reading.values():
            words.sort(key=lambda w: -in_words[w])
        def items_for(words: list[str], reading_of: dict[str, str]) -> list[tuple[str, str, str]]:
            return [(w, reading_of[w], short_gloss(articles[w], reading_of[w])) for w in words]

        toneless: dict[str, list[str]] = defaultdict(list)
        # A Jyutping key that is a word of English or a key of another preset
        # ('cat', 'be', 'man', 'co2') would add a CC-Canto page, sometimes a
        # vulgar one, to that word's lookup, since the app looks a word up in
        # every dictionary. Such keys are kept only for the words glossed by
        # that very word (wok → 鑊 'wok', fit → 弗 'fit (loanword)').
        stop_kept: dict[str, list[str]] = {}
        n_stopped = 0

        def unstopped(key: str, words: list[str]) -> list[str]:
            nonlocal n_stopped
            if key not in JYUTPING_STOP:
                return words
            kept = [w for w in words if gloss_has_word(articles[w], key)]
            if kept:
                stop_kept[key] = kept
            else:
                n_stopped += 1
            return kept

        for reading, words_all in by_reading.items():
            nospace = reading.replace(' ', '')
            toneless[re.sub(r'[1-6]', '', nospace)].append(reading)
            words = unstopped(reading, words_all)
            if not words:
                continue
            if len(words) <= JYUTPING_DIRECT_MAX:
                for w in words:
                    link(reading, w)
                    if nospace != reading:
                        link(nospace, w)
            else:
                index_articles[reading] = make_index_html(
                    reading, items_for(words, dict.fromkeys(words, reading)))
                if nospace != reading:
                    link(nospace, reading)
        def main_reading(w: str, readings_: list[str]) -> str:
            """Of a word's readings, the one of its first block (飯 faan6
            'food; cooked rice', not faan5 'to feed')."""
            for b in ordered_blocks(articles[w]):
                for jp in b.jyutping:
                    for r in jyutping_readings(jp, None):
                        if ' '.join(r) in readings_:
                            return ' '.join(r)
            return readings_[0]

        for bare, readings_ in toneless.items():
            cands: dict[str, list[str]] = {}
            for reading in sorted(readings_, key=lambda r: (re.sub(r'\d', '', r), r)):
                for w in by_reading[reading]:
                    cands.setdefault(w, []).append(reading)
            words = list(cands)
            reading_of = {w: main_reading(w, rs) for w, rs in cands.items()}
            # Most common first across all tones (係 hai6 before 閪 hai1).
            words.sort(key=lambda w: -in_words[w])
            words = unstopped(bare, words)
            if not words:
                continue
            if len(words) <= JYUTPING_DIRECT_MAX:
                for w in words:
                    link(bare, w)
            elif (len(readings_) == 1 and bare not in stop_kept
                  and readings_[0] in index_articles):
                link(bare, readings_[0])
            else:
                index_articles[bare] = make_index_html(bare, items_for(words, reading_of))
        print(f"  {len(by_reading)} Jyutping readings, {len(index_articles)} index articles; "
              f"{n_stopped} Jyutping keys dropped as words of other languages, "
              f"{len(stop_kept)} kept for their gloss: "
              + ', '.join(f'{k} → {"/".join(v)}' for k, v in sorted(stop_kept.items())))

    redirects = {k: v for k, v in redirects.items() if v}
    all_keys = main_keys | set(redirects) | set(index_articles)

    # Keys must be typable: no padding, control, format or private-use characters.
    for k in all_keys:
        if not k or k != k.strip() or any(unicodedata.category(c) in ('Cc', 'Cf', 'Co') for c in k):
            raise SystemExit(f"ERROR: untypable key {k!r}")

    # Every redirect target must be a key with content.
    for key, targets in redirects.items():
        for t in targets:
            if t not in main_keys and t not in index_articles:
                raise SystemExit(f"ERROR: @@@LINK {key} → {t}: target is not an article")

    # ── Write MDict source ──
    txt_path = OUTPUT_DIR / "cc_canto_entries.txt"
    print(f"Writing → {txt_path}...")
    records: list[tuple[str, int, str]] = []
    for trad in sorted(articles):
        records.append((trad, 0, make_article_html(articles[trad], all_keys)))
    for key in sorted(index_articles):
        records.append((key, 0, index_articles[key]))
    for key in sorted(redirects):
        for t in redirects[key]:
            records.append((key, 1, f'@@@LINK={t}'))
    # Article before redirects for a shared key (the packer's sort is stable).
    records.sort(key=lambda r: (r[0], r[1]))
    link_re = re.compile(r'href="entry://([^"]*)"')
    with open(txt_path, 'w', encoding='utf-8') as f:
        for key, _, body in records:
            for target in link_re.findall(body):
                if html.unescape(target) not in all_keys:
                    raise SystemExit(f"ERROR: {key}: entry://{target} is not a key")
            f.write(f"{key}\n{body}\n</>\n")
    count = len(records)
    n_links = sum(1 for r in records if r[1] == 1)
    print(f"  {count} records: {len(articles)} articles, {len(index_articles)} Jyutping "
          f"index articles, {n_links} @@@LINK redirects")

    # ── Pack MDX ──
    mdx_path = OUTPUT_DIR / f"{DICT_NAME}.mdx"
    desc_html = descriptions()[mdx_path.name]
    success, size_mb, _ = pack_mdx(txt_path, "CC-Canto Cantonese-English", desc_html, mdx_path)
    if not success:
        raise SystemExit(1)
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="CC-Canto Cantonese-English",
        description=(
            "Cantonese supplement to CC-CEDICT: colloquial words, slang and idioms with "
            "Jyutping, Mandarin pinyin and English definitions"
            + (", plus Jyutping readings for about 100,000 CC-CEDICT words" if INCLUDE_READINGS else "")
            + ". Search by characters or Jyutping."),
        direction={"src": "ZH", "dest": ["EN"]},
        entries=count,
        license="CC-BY-SA-3.0",
        data_source=("CC-Canto + CC-CEDICT Cantonese Readings (Pleco Inc.)"
                     if INCLUDE_READINGS else "CC-Canto (Pleco Inc.)"),
        tier=2,
        flag="🇭🇰🇨🇳",
    )

    _generate_preview(articles, all_keys)


if __name__ == '__main__':
    main()
