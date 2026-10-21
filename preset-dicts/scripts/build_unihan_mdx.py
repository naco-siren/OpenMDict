#!/usr/bin/env python3
"""
Build Unihan CJK Character Database MDX dictionary.

Usage:
    python build_unihan_mdx.py

Input:  ../data/unihan/Unihan_*.txt  (Unicode 17.0.0 Unihan.zip, all files)
Output: ../output/Unihan-CJK/Unihan-CJK.mdx

Every code point in the Unihan database gets an entry (each has at least a
radical-stroke index, a total stroke count and IRG sources). The readings
shown, in order:

    拼音    kMandarin (most customary), then the other modern readings of
            kTGHZ2013 and kXHC1983 (General Standard / Modern Chinese
            dictionaries); kHanyuPinyin only when there is no modern reading.
            A second kMandarin value (preferred in Taiwan) that neither
            mainland dictionary lists is marked '(TW)'.
    又音    kHanyuPinyin (Hanyu Da Zidian) readings not listed above
    粵拼    kCantonese, then the other kSMSZD2003Readings Cantonese readings
    中古音  kTang (Middle Chinese of the Tang dynasty, Stimson's
            reconstruction; '*' = frequent in Tang poetry)
    反切    kFanqie
    音/訓   kJapanese (kana: katakana = on, hiragana = kun), then readings
            of kJapaneseOn / kJapaneseKun (Hepburn) not already listed
    한국    kHangul, romanized here (Revised Romanization)
    한국 (Yale, 참고)  kKorean readings whose syllable kHangul lacks, as
            Hangul (converted from Yale) + the Yale value; '참고' (for
            reference) marks the lower-confidence source (TR38 does not
            recommend kKorean). Never paired with kHangul by position.
    Việt    kVietnamese
    Cuengh  kZhuang ('*' = not in the Standard Zhuang lexicon)

Then kDefinition, the simplified / traditional / semantic / specialized
variant links (never to the entry itself or a canonical equivalent: the app
shows a compatibility ideograph's record together with its unified form's),
the canonical form of a compatibility ideograph (as text) and the IRG
sources.
"""

import hashlib
import re
import sys
import unicodedata
from pathlib import Path
from collections import defaultdict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, CJK_READING_TAGS, TEXT_SECONDARY, TEXT_LINK
from shared.html import esc, entry_link, kana_to_romaji
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data" / "unihan"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "Unihan-CJK"

# The Unihan release this build is pinned to (fetch_data.sh downloads
# /Public/<version>/ucd/Unihan.zip). Every Unihan_*.txt header must match,
# so a newer release cannot slip in silently.
UNIHAN_VERSION = "17.0.0"
UNIHAN_URL = f"https://www.unicode.org/Public/{UNIHAN_VERSION}/ucd/Unihan.zip"
UNIHAN_ZIP_SHA256 = "f7a48b2b545acfaa77b2d607ae28747404ce02baefee16396c5d2d7a8ef34b5e"
UNIHAN_COPYRIGHT_YEARS = "1991-2025"   # the 17.0.0 files say "© 2025 Unicode®, Inc."

# TR38 §4.3: the database is the concatenation of all Unihan_*.txt files.
# (kRSUnicode / kTotalStrokes / kCompatibilityVariant / kIRG_*Source live in
# Unihan_IRGSources.txt.)
UNIHAN_FILES = (
    "Unihan_DictionaryIndices.txt",
    "Unihan_DictionaryLikeData.txt",
    "Unihan_IRGSources.txt",
    "Unihan_NumericValues.txt",
    "Unihan_OtherMappings.txt",
    "Unihan_RadicalStrokeCounts.txt",
    "Unihan_Readings.txt",
    "Unihan_Variants.txt",
)

# ── HTML ───────────────────────────────────────────────────────

DIR_LABEL = '🇨🇳🇹🇼🇭🇰🇯🇵🇰🇷 漢字'
# Row label for kKorean-only readings: '참고' (for reference) marks the
# lower-confidence source next to the kHangul row.
YALE_LABEL = '한국 (Yale, 참고)'

_SEC_L, _SEC_D = TEXT_SECONDARY
_LINK_L, _LINK_D = TEXT_LINK

CSS = get_css(
    CJK_READING_TAGS,
    extra_light=(
        '.ch{font-size:2.5em;font-weight:400;display:block;padding:8px 0}'
        f'.ucp{{font-size:0.8em;color:{_SEC_L};display:block}}'
        f'.info{{font-size:0.85em;color:{_SEC_L};display:block;margin-bottom:8px}}'
        '.rd{margin:6px 0;display:flex;flex-wrap:wrap;align-items:baseline;gap:2px}'
        f'.rd-label{{font-size:0.8em;color:{_SEC_L};margin-right:4px;min-width:50px}}'
        '.tag-za{background:#eceff1;color:#455a64}'
        '.df{font-size:1.15em}'
        '.vr{font-size:0.9em;color:#636366;margin:4px 0}'
        f'.vr a{{color:{_LINK_L};text-decoration:underline}}'
    ),
    extra_dark=(
        f'.ucp{{color:{_SEC_D}}}'
        f'.info{{color:{_SEC_D}}}'
        f'.rd-label{{color:{_SEC_D}}}'
        '.tag-za{background:#2f3437;color:#b0bec5}'
        '.vr{color:#98989d}'
        f'.vr a{{color:{_LINK_D}}}'
    ),
)


# ── Unicode blocks (CJK ideographs, Unicode 17.0) ─────────────

_BLOCKS = (
    (0x3400, 0x4DBF, 'CJK Unified Ideographs Extension A'),
    (0x4E00, 0x9FFF, 'CJK Unified Ideographs'),
    (0xF900, 0xFAFF, 'CJK Compatibility Ideographs'),
    (0x20000, 0x2A6DF, 'CJK Unified Ideographs Extension B'),
    (0x2A700, 0x2B73F, 'CJK Unified Ideographs Extension C'),
    (0x2B740, 0x2B81F, 'CJK Unified Ideographs Extension D'),
    (0x2B820, 0x2CEAF, 'CJK Unified Ideographs Extension E'),
    (0x2CEB0, 0x2EBEF, 'CJK Unified Ideographs Extension F'),
    (0x2EBF0, 0x2EE5F, 'CJK Unified Ideographs Extension I'),
    (0x2F800, 0x2FA1F, 'CJK Compatibility Ideographs Supplement'),
    (0x30000, 0x3134F, 'CJK Unified Ideographs Extension G'),
    (0x31350, 0x323AF, 'CJK Unified Ideographs Extension H'),
    (0x323B0, 0x3347F, 'CJK Unified Ideographs Extension J'),
)


def block_name(code: int) -> str:
    for lo, hi, name in _BLOCKS:
        if lo <= code <= hi:
            return name
    return ''


# kIRG_*Source property → region, in display order.
_IRG_SOURCES = (
    ('kIRG_GSource', 'China'), ('kIRG_HSource', 'Hong Kong'),
    ('kIRG_MSource', 'Macao'), ('kIRG_TSource', 'Taiwan'),
    ('kIRG_JSource', 'Japan'), ('kIRG_KSource', 'South Korea'),
    ('kIRG_KPSource', 'North Korea'), ('kIRG_VSource', 'Vietnam'),
    ('kIRG_UKSource', 'UK'), ('kIRG_SSource', 'SAT Daizōkyō'),
    ('kIRG_USource', 'UTC'),
)


# ── Radicals ───────────────────────────────────────────────────

def kangxi_radical_char(num: int) -> str:
    """The unified ideograph of Kangxi radical `num` (1-214).

    The Kangxi Radicals block (U+2F00..U+2FD5) is in radical order and each
    character's compatibility decomposition is the unified ideograph.
    """
    return unicodedata.normalize('NFKC', chr(0x2F00 + num - 1))


def build_radical_chars(data: dict) -> dict:
    """Map every radical id used in kRSUnicode ('72', "149'", "212''") to
    the character shown for it.

    Plain numbers use the Kangxi radical. Apostrophe forms (simplified
    radicals) have no Kangxi character; take the ideograph that is itself
    that radical with 0 residual strokes, preferring the BMP and kIICore
    characters (e.g. 149' → 讠, 210'' → 斉). When the only such ideograph
    is outside the BMP (182'' and 212''' are Extension H), no glyph is
    shown: the iOS 15 system fonts have none, and the number alone is
    clearer than a missing-glyph box.
    """
    cands: dict[str, list[tuple]] = defaultdict(list)
    for cp, props in data.items():
        for part in props.get('kRSUnicode', '').split():
            rad, _, rest = part.partition('.')
            if "'" in rad and rest == '0':
                code = int(cp[2:], 16)
                is_compat = unicodedata.normalize('NFC', chr(code)) != chr(code)
                cands[rad].append((is_compat, code > 0xFFFF,
                                   'kIICore' not in props, code))
    out = {str(n): kangxi_radical_char(n) for n in range(1, 215)}
    for rad, lst in cands.items():
        code = min(lst)[3]
        out[rad] = chr(code) if code <= 0xFFFF else ''
    return out


def format_radical_strokes(props: dict, radical_chars: dict) -> str:
    """'radical 72 日 + 0 · 4 strokes' (kRSUnicode may list several)."""
    items = []
    rs_values = []
    for part in props.get('kRSUnicode', '').split():
        rad, _, residual = part.partition('.')
        if not rad or not residual:
            continue
        num = rad.rstrip("'")
        primes = len(rad) - len(num)
        label = num + '′' * primes          # 149' → 149′ (prime, not apostrophe)
        rc = radical_chars.get(rad, '')
        sign = '−' if residual.startswith('-') else '+'
        rs_values.append(f'{label} {rc} {sign} {residual.lstrip("-")}'
                         if rc else f'{label} {sign} {residual.lstrip("-")}')
    if rs_values:
        items.append('radical ' + ' / '.join(rs_values))
    ts = props.get('kTotalStrokes', '')
    if ts:
        n = ts.split()[0]
        items.append(f'{n} stroke' + ('' if n == '1' else 's'))
    return ' · '.join(items)


# ── Romaji → Kana converter (kJapaneseOn / kJapaneseKun only) ───

# Longest-match-first romaji→katakana table
_ROMAJI_KATA = {
    # 4-char: non-standard 'shy-' / 'chy-' spellings in kJapaneseOn
    'SHYA': 'シャ', 'SHYU': 'シュ', 'SHYO': 'ショ',
    'CHYA': 'チャ', 'CHYU': 'チュ', 'CHYO': 'チョ',
    # 3-char combos (must try first)
    'SHA': 'シャ', 'SHI': 'シ', 'SHU': 'シュ', 'SHE': 'シェ', 'SHO': 'ショ',
    'CHA': 'チャ', 'CHI': 'チ', 'CHU': 'チュ', 'CHE': 'チェ', 'CHO': 'チョ',
    'TSU': 'ツ', 'TSA': 'ツァ',
    'KYA': 'キャ', 'KYU': 'キュ', 'KYO': 'キョ',
    'GYA': 'ギャ', 'GYU': 'ギュ', 'GYO': 'ギョ',
    'NYA': 'ニャ', 'NYU': 'ニュ', 'NYO': 'ニョ',
    'HYA': 'ヒャ', 'HYU': 'ヒュ', 'HYO': 'ヒョ',
    'MYA': 'ミャ', 'MYU': 'ミュ', 'MYO': 'ミョ',
    'RYA': 'リャ', 'RYU': 'リュ', 'RYO': 'リョ',
    'BYA': 'ビャ', 'BYU': 'ビュ', 'BYO': 'ビョ',
    'PYA': 'ピャ', 'PYU': 'ピュ', 'PYO': 'ピョ',
    # 2-char
    'KA': 'カ', 'KI': 'キ', 'KU': 'ク', 'KE': 'ケ', 'KO': 'コ',
    'SA': 'サ', 'SI': 'シ', 'SU': 'ス', 'SE': 'セ', 'SO': 'ソ',
    'TA': 'タ', 'TI': 'チ', 'TU': 'ツ', 'TE': 'テ', 'TO': 'ト',
    'NA': 'ナ', 'NI': 'ニ', 'NU': 'ヌ', 'NE': 'ネ', 'NO': 'ノ',
    'HA': 'ハ', 'HI': 'ヒ', 'HU': 'フ', 'FU': 'フ', 'HE': 'ヘ', 'HO': 'ホ',
    'FA': 'ファ', 'FI': 'フィ', 'FE': 'フェ', 'FO': 'フォ',
    'MA': 'マ', 'MI': 'ミ', 'MU': 'ム', 'ME': 'メ', 'MO': 'モ',
    'YA': 'ヤ', 'YU': 'ユ', 'YO': 'ヨ',
    'RA': 'ラ', 'RI': 'リ', 'RU': 'ル', 'RE': 'レ', 'RO': 'ロ',
    'WA': 'ワ', 'WI': 'ヰ', 'WE': 'ヱ', 'WO': 'ヲ',
    'GA': 'ガ', 'GI': 'ギ', 'GU': 'グ', 'GE': 'ゲ', 'GO': 'ゴ',
    'ZA': 'ザ', 'ZI': 'ジ', 'ZU': 'ズ', 'ZE': 'ゼ', 'ZO': 'ゾ',
    'DA': 'ダ', 'DI': 'ヂ', 'DU': 'ヅ', 'DE': 'デ', 'DO': 'ド',
    'BA': 'バ', 'BI': 'ビ', 'BU': 'ブ', 'BE': 'ベ', 'BO': 'ボ',
    'PA': 'パ', 'PI': 'ピ', 'PU': 'プ', 'PE': 'ペ', 'PO': 'ポ',
    'JA': 'ジャ', 'JI': 'ジ', 'JU': 'ジュ', 'JE': 'ジェ', 'JO': 'ジョ',
    # 1-char
    'A': 'ア', 'I': 'イ', 'U': 'ウ', 'E': 'エ', 'O': 'オ',
    'N': 'ン',
}

_ASCII_ROMAJI_RE = re.compile(r'[A-Za-z]+')


def _romaji_to_katakana(text: str) -> str:
    """Convert uppercase Hepburn romaji (kJapaneseOn/Kun syntax [A-Z]+) to
    katakana. Returns '' for anything that is not plain ASCII letters, so
    kana or other text is never pushed through the doubled-letter rule."""
    if not _ASCII_ROMAJI_RE.fullmatch(text):
        return ''
    result = []
    i = 0
    s = text.upper()
    n = len(s)
    while i < n:
        matched = False
        for length in (4, 3, 2, 1):
            chunk = s[i:i + length]
            if chunk in _ROMAJI_KATA:
                # 'N' alone: only match if NOT followed by a vowel or Y
                if chunk == 'N' and length == 1 and i + 1 < n and s[i + 1] in 'AIUEOY':
                    continue
                result.append(_ROMAJI_KATA[chunk])
                i += length
                matched = True
                break
        if not matched:
            # Doubled consonant → ッ
            if i + 1 < n and s[i] == s[i + 1] and s[i] not in 'AIUEON':
                result.append('ッ')
                i += 1
            else:
                return ''          # not convertible: never show half-Latin kana
    return ''.join(result)


def _kata_to_hira(text: str) -> str:
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c
                   for c in text)


def _romaji_to_hiragana(text: str) -> str:
    """Convert uppercase Hepburn romaji to hiragana ('' if not convertible)."""
    return _kata_to_hira(_romaji_to_katakana(text))


_KATAKANA_RE = re.compile(r'[ァ-ヺー]+')
_HIRAGANA_RE = re.compile(r'[ぁ-ゖ゙゚ー]+')


def japanese_readings(props: dict) -> tuple[list[str], list[str]]:
    """(on, kun) kana readings.

    kJapanese (kana, Unicode 15.1+) first: katakana = on, hiragana = kun
    (TR38). Then the older kJapaneseOn / kJapaneseKun (Hepburn) readings
    that kJapanese does not already list, converted to kana. A converted
    reading that sounds like one kJapanese already gives (same romaji, in
    either list) is skipped: Hepburn loses the spelling, so ZU/JI come back
    as ず/じ where kJapanese has づ/ぢ (続 つづく, not つずく), loanwords lose
    their katakana (呎 フィート, not ふぃいと), and some kJapaneseKun values
    are on readings that kJapanese files as katakana (个 コ, not こ).
    """
    on: list[str] = []
    kun: list[str] = []
    for tok in props.get('kJapanese', '').split():
        if _KATAKANA_RE.fullmatch(tok):
            target = on
        elif _HIRAGANA_RE.fullmatch(tok):
            target = kun
        else:
            continue
        if tok not in target:
            target.append(tok)
    known = {kana_to_romaji(r) for r in on + kun}
    for field, convert, target in (('kJapaneseOn', _romaji_to_katakana, on),
                                   ('kJapaneseKun', _romaji_to_hiragana, kun)):
        for tok in props.get(field, '').split():
            kana = convert(tok)
            if kana and kana not in target and kana_to_romaji(kana) not in known:
                target.append(kana)
    return on, kun


# ── Mandarin / Cantonese ──────────────────────────────────────

def _located_readings(value: str, multi: bool) -> list[str]:
    """Readings from 'loc[,loc]:reading' tokens (kTGHZ2013, kXHC1983) or
    'loc[,loc]:r1,r2' tokens (kHanyuPinyin, multi=True)."""
    out = []
    for tok in value.split():
        _, sep, readings = tok.rpartition(':')
        if not sep:
            continue
        for r in (readings.split(',') if multi else [readings]):
            r = r.strip()
            if r and r not in out:
                out.append(r)
    return out


def mandarin_readings(props: dict) -> tuple[list[str], list[str], str]:
    """(main, extra, tw) pinyin.

    main:  kMandarin (most customary; CN then TW when two), then the other
           readings of kTGHZ2013 and kXHC1983. If none of these exist, the
           Hanyu Da Zidian readings (kHanyuPinyin) take their place.
    extra: kHanyuPinyin readings not in main.
    tw:    the second kMandarin value (TR38: preferred for zh-Hant, TW)
           when the two mainland dictionaries do not list it, else ''.
    """
    main: list[str] = []
    mandarin = props.get('kMandarin', '').split()
    for r in mandarin:
        if r not in main:
            main.append(r)
    modern: list[str] = []
    for field in ('kTGHZ2013', 'kXHC1983'):
        for r in _located_readings(props.get(field, ''), multi=False):
            if r not in modern:
                modern.append(r)
            if r not in main:
                main.append(r)
    tw = ''
    if len(mandarin) == 2 and mandarin[0] != mandarin[1] and mandarin[1] not in modern:
        tw = mandarin[1]
    hdz = _located_readings(props.get('kHanyuPinyin', ''), multi=True)
    if not main:
        return hdz, [], ''
    return main, [r for r in hdz if r not in main], tw


def cantonese_readings(props: dict) -> list[str]:
    """kCantonese, then the other Cantonese readings in kSMSZD2003Readings
    ('xíng,xìng粵hang6' tokens)."""
    out = props.get('kCantonese', '').split()
    for tok in props.get('kSMSZD2003Readings', '').split():
        _, sep, yue = tok.partition('粵')
        if not sep:
            continue
        for r in yue.split(','):
            if r and r not in out:
                out.append(r)
    return out


# ── Korean ─────────────────────────────────────────────────────

_RR_INITIAL = ('g', 'kk', 'n', 'd', 'tt', 'r', 'm', 'b', 'pp', 's', 'ss', '',
               'j', 'jj', 'ch', 'k', 't', 'p', 'h')
_RR_VOWEL = ('a', 'ae', 'ya', 'yae', 'eo', 'e', 'yeo', 'ye', 'o', 'wa', 'wae',
             'oe', 'yo', 'u', 'wo', 'we', 'wi', 'yu', 'eu', 'ui', 'i')
_RR_FINAL = ('', 'k', 'k', 'k', 'n', 'n', 'n', 't', 'l', 'k', 'm', 'l', 'l',
             'l', 'p', 'l', 'm', 'p', 'p', 't', 't', 'ng', 't', 't', 'k', 't',
             'p', 't')


def hangul_to_rr(text: str) -> str:
    """Revised Romanization of Korean for isolated Hangul syllables
    (금 → geum, 학 → hak, 렬 → ryeol). '' if `text` is not all syllables."""
    out = []
    for ch in text:
        o = ord(ch) - 0xAC00
        if not 0 <= o < 11172:
            return ''
        out.append(_RR_INITIAL[o // 588] + _RR_VOWEL[(o % 588) // 28] + _RR_FINAL[o % 28])
    return ''.join(out)


# Yale romanization (kKorean, uppercase) → Hangul syllable. Unihan writes
# ㅜ as WU everywhere (PWU 부) and ㅡ as U (KUM 금), so a Sino-Korean
# syllable parses unambiguously as initial + vowel + final.
_YALE_INITIAL = {'K': 0, 'KK': 1, 'N': 2, 'T': 3, 'TT': 4, 'L': 5, 'M': 6, 'P': 7,
                 'PP': 8, 'S': 9, 'SS': 10, '': 11, 'C': 12, 'CC': 13, 'CH': 14,
                 'KH': 15, 'TH': 16, 'PH': 17, 'H': 18}
_YALE_VOWEL = {'A': 0, 'AY': 1, 'YA': 2, 'YAY': 3, 'E': 4, 'EY': 5, 'YE': 6, 'YEY': 7,
               'O': 8, 'WA': 9, 'WAY': 10, 'OY': 11, 'YO': 12, 'WU': 13, 'WE': 14,
               'WEY': 15, 'WI': 16, 'YU': 17, 'U': 18, 'UY': 19, 'I': 20}
_YALE_FINAL = {'': 0, 'K': 1, 'N': 4, 'T': 7, 'L': 8, 'M': 16, 'P': 17, 'S': 19,
               'NG': 21, 'C': 22}
_YALE_RE = re.compile(
    r'(KK|TT|PP|SS|CC|CH|KH|TH|PH|K|N|T|L|M|P|S|C|H|)'
    r'(YAY|YEY|WAY|WEY|AY|YA|EY|YE|WA|OY|YO|WU|WE|WI|YU|UY|A|E|O|U|I)'
    r'(NG|K|N|T|L|M|P|S|C|)')


def yale_to_hangul(yale: str) -> str:
    """'KUM' → '금', 'PWUL' → '불'; '' if it is not one Yale syllable."""
    m = _YALE_RE.fullmatch(yale.upper())
    if not m:
        return ''
    i, v, f = m.groups()
    return chr(0xAC00 + _YALE_INITIAL[i] * 588 + _YALE_VOWEL[v] * 28 + _YALE_FINAL[f])


def korean_tags(props: dict) -> tuple[list[str], list[str]]:
    """(hangul_tags, yale_tags).

    hangul_tags: kHangul readings with their Revised Romanization.
    yale_tags:   kKorean (Yale) readings whose syllable kHangul does not
                 list, shown as 'Hangul yale' on a separate row labelled
                 as a lower-confidence source (YALE_LABEL). TR38: "Use of
                 the kKorean property is not recommended". Beside kHangul
                 they are mostly rarer classical readings (乾 간, 円 원,
                 亡 무; 411 of the 563 that KANJIDIC2 also covers appear in
                 its Korean readings), with some errors (北 PEY). The two
                 fields are not parallel lists, so they are never paired
                 by position.
    """
    hangul = []
    tags = []
    for tok in props.get('kHangul', '').split():
        h = tok.split(':')[0]
        if not h or h in hangul:
            continue
        hangul.append(h)
        rom = hangul_to_rr(h)
        tags.append(f'{h} {rom}' if rom else h)
    yale = []
    seen = set(hangul)
    for tok in props.get('kKorean', '').split():
        h = yale_to_hangul(tok)
        if h and h in seen:
            continue
        seen.add(h or tok)
        yale.append(f'{h} {tok.lower()}' if h else tok.lower())
    return tags, yale


# ── Variants ───────────────────────────────────────────────────

def codepoint_list_to_chars(value: str, skipped: "list | None" = None) -> list[str]:
    """'U+91D2<kMatthews U+6DDA' → ['釒', '淚'] (source tags after '<' are
    dropped; values that still fail to parse are appended to `skipped`)."""
    chars = []
    for part in value.split():
        code = part.split('<', 1)[0]
        if code.startswith('U+'):
            try:
                c = chr(int(code[2:], 16))
            except (ValueError, OverflowError):
                c = None
            if c is not None:
                if c not in chars:
                    chars.append(c)
                continue
        if skipped is not None:
            skipped.append(part)
    return chars


# ── Parser ─────────────────────────────────────────────────────

_VERSION_RE = re.compile(r'^# Unicode Version (\S+)')


def parse_unihan_file(filepath: Path, data: dict) -> None:
    """Parse a Unihan_*.txt file, adding properties to data[codepoint]."""
    version = None
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line:
                continue
            if line.startswith('#'):
                m = _VERSION_RE.match(line)
                if m:
                    version = m.group(1)
                continue
            parts = line.split('\t', 2)
            if len(parts) < 3:
                continue
            cp, prop, value = parts
            data[cp][prop] = value
    if version != UNIHAN_VERSION:
        raise SystemExit(f"{filepath.name}: Unicode Version {version!r}, expected "
                         f"{UNIHAN_VERSION} (update UNIHAN_VERSION and review the "
                         f"field changes in TR38 before rebuilding)")


def codepoint_to_char(cp: str) -> str:
    """Convert 'U+XXXX' to the actual character."""
    return chr(int(cp[2:], 16))


# ── HTML generation ────────────────────────────────────────────

def has_reading_or_definition(props: dict) -> bool:
    """True when make_html() shows at least one reading row or kDefinition."""
    main_py, extra_py, _ = mandarin_readings(props)
    on, kun = japanese_readings(props)
    ko, ko_yale = korean_tags(props)
    return bool(main_py or extra_py or cantonese_readings(props)
                or props.get('kTang', '').split() or props.get('kFanqie', '').split()
                or on or kun or ko or ko_yale
                or props.get('kVietnamese', '').split() or props.get('kZhuang', '').split()
                or props.get('kDefinition', ''))


def _row(label: str, tags: list[str], cls: str) -> str:
    t = ''.join(f'<span class="tag {cls}">{esc(v)}</span>' for v in tags)
    return f'<div class="rd"><span class="rd-label">{esc(label)}</span>{t}</div>'


def _same_char(a: str, b: str) -> bool:
    """True when a and b are the same character or canonically equivalent
    (a CJK compatibility ideograph and its unified form). The app compares
    keys as Swift Strings, so looking up either one shows both records:
    a link between them would only reload the same page."""
    return unicodedata.normalize('NFC', a) == unicodedata.normalize('NFC', b)


def _link_row(label: str, char: str, value: str, keys: set, skipped: list,
              shown: set) -> str:
    """One variant row. Drops the entry itself (and its canonical
    equivalents) and targets already linked in an earlier row (e.g. a
    semantic variant that is also the traditional form); adds the targets
    it links to `shown`."""
    targets = [c for c in codepoint_list_to_chars(value, skipped)
               if not _same_char(c, char) and c in keys and c not in shown]
    if not targets:
        return ''
    shown.update(targets)
    links = ', '.join(entry_link(c) for c in targets)
    return f'<div class="vr">{label}: {links}</div>'


def make_html(cp: str, props: dict, radical_chars: dict, keys: set,
              skipped: "list | None" = None) -> str:
    """Generate HTML for a single CJK character entry."""
    if skipped is None:
        skipped = []
    char = codepoint_to_char(cp)
    code = int(cp[2:], 16)
    parts = [f'<span class="dir">{DIR_LABEL}</span>']
    parts.append(f'<span class="ch">{esc(char)}</span>')
    blk = block_name(code)
    parts.append(f'<span class="ucp">{esc(cp)}{" · " + esc(blk) if blk else ""}</span>')

    # Radical-stroke index and total strokes (Unihan_IRGSources.txt)
    rs = format_radical_strokes(props, radical_chars)
    if rs:
        parts.append(f'<span class="info">{esc(rs)}</span>')

    # Readings — colored tags (same style as KANJIDIC2)
    main_py, extra_py, tw_py = mandarin_readings(props)
    if main_py:
        parts.append(_row('拼音', [f'{r} (TW)' if r == tw_py else r for r in main_py],
                          'tag-py'))
    if extra_py:
        parts.append(_row('又音', extra_py, 'tag-py'))

    yue = cantonese_readings(props)
    if yue:
        parts.append(_row('粵拼', yue, 'tag-py'))

    tang = props.get('kTang', '').split()
    if tang:
        parts.append(_row('中古音', tang, 'tag-py'))

    fanqie = props.get('kFanqie', '').split()
    if fanqie:
        parts.append(_row('反切', fanqie, 'tag-py'))

    on, kun = japanese_readings(props)
    if on:
        parts.append(_row('音', [f'{r} {kana_to_romaji(r)}' for r in on], 'tag-on'))
    if kun:
        parts.append(_row('訓', [f'{r} {kana_to_romaji(r)}' for r in kun], 'tag-kun'))

    ko, ko_yale = korean_tags(props)
    if ko:
        parts.append(_row('한국', ko, 'tag-ko'))
    if ko_yale:
        parts.append(_row(YALE_LABEL, ko_yale, 'tag-ko'))

    vi = props.get('kVietnamese', '').split()
    if vi:
        parts.append(_row('Việt', vi, 'tag-vi'))

    za = props.get('kZhuang', '').split()
    if za:
        parts.append(_row('Cuengh', za, 'tag-za'))

    # Definition
    definition = props.get('kDefinition', '')
    if definition:
        parts.append(f'<div class="sn"><span class="df">{esc(definition)}</span></div>')

    # Variants (links only to entries that exist, never to the entry itself
    # or a canonical equivalent, each target once)
    shown: set = set()
    for label, field in (('Simplified', 'kSimplifiedVariant'),
                         ('Traditional', 'kTraditionalVariant'),
                         ('Semantic variant', 'kSemanticVariant'),
                         ('Specialized variant', 'kSpecializedSemanticVariant')):
        value = props.get(field, '')
        if value:
            row = _link_row(label, char, value, keys, skipped, shown)
            if row:
                parts.append(row)

    # Compatibility ideograph → its canonical (unified) form. Plain text, not
    # a link: a lookup of either character already shows both records.
    canon = codepoint_list_to_chars(props.get('kCompatibilityVariant', ''), skipped)
    if canon:
        forms = ', '.join(f'{esc(c)} U+{ord(c):04X}' for c in canon)
        parts.append(f'<div class="vr">Compatibility ideograph, canonically '
                     f'equivalent to {forms}</div>')

    # IRG sources (where the character was submitted from)
    regions = [name for prop, name in _IRG_SOURCES if prop in props]
    if regions:
        parts.append(f'<span class="ucp">IRG sources: {esc(" · ".join(regions))}</span>')

    return f'{CSS}<div class="e">{"".join(parts)}</div>'


# ── Preview ────────────────────────────────────────────────────

SAMPLE_WORDS = ['中', '人', '行', '长', '金', '说', '日', '𡨸', '不', '不']


def _generate_preview(data: dict, radical_chars: dict, keys: set):
    entries_html = []
    for hw in SAMPLE_WORDS:
        cp = f'U+{ord(hw):04X}'
        if cp in data:
            entries_html.append(make_html(cp, data[cp], radical_chars, keys))
    preview_path = OUTPUT_DIR / "unihan_preview.html"
    _shared_preview(entries_html, preview_path, 'Unihan — preview')


# ── Main ───────────────────────────────────────────────────────

def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def load_unihan() -> dict:
    zip_path = DATA_DIR / "Unihan.zip"
    if zip_path.exists():
        got = _sha256(zip_path)
        if got != UNIHAN_ZIP_SHA256:
            raise SystemExit(f"{zip_path}: sha256 {got} != pinned {UNIHAN_ZIP_SHA256} "
                             f"({UNIHAN_URL}). Update UNIHAN_VERSION / UNIHAN_ZIP_SHA256 "
                             "here when moving to a new Unicode release.")
    data = defaultdict(dict)  # codepoint → {property: value}
    for name in UNIHAN_FILES:
        path = DATA_DIR / name
        if not path.exists():
            raise SystemExit(f"{path} not found (source: {UNIHAN_URL}) -- run "
                             "scripts/fetch_data.sh unihan")
        print(f"  Loading {name}...")
        parse_unihan_file(path, data)
    print(f"    {len(data)} code points loaded (Unicode {UNIHAN_VERSION})")
    return data


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Parsing Unihan database...")
    data = load_unihan()

    # Every Unihan code point is an entry: all have kRSUnicode and
    # kTotalStrokes, and every variant link target is then a key.
    cps = sorted(data, key=lambda c: int(c[2:], 16))
    keys = {codepoint_to_char(cp) for cp in cps}
    radical_chars = build_radical_chars(data)

    # Write MDict source
    txt_path = OUTPUT_DIR / "unihan_entries.txt"
    print(f"Writing → {txt_path}...")

    count = 0
    skipped: list[str] = []
    with open(txt_path, 'w', encoding='utf-8') as f:
        for cp in cps:
            html = make_html(cp, data[cp], radical_chars, keys, skipped)
            f.write(f"{codepoint_to_char(cp)}\n{html}\n</>\n")
            count += 1

    print(f"  {count} entries written")
    if skipped:
        print(f"  WARNING: {len(skipped)} variant values could not be parsed, "
              f"e.g. {skipped[:5]}")

    n_def = sum(1 for p in data.values() if 'kDefinition' in p)
    n_bare = sum(1 for p in data.values() if not has_reading_or_definition(p))
    print(f"  {n_def} with an English definition, {n_bare} with neither a "
          "reading nor a definition")

    # Pack MDX
    mdx_path = OUTPUT_DIR / "Unihan-CJK.mdx"
    desc_html = (
        f"<p><b>Unihan — CJK Character Database</b> (Unicode {UNIHAN_VERSION})</p>"
        f"<p>All {count:,} CJK ideographs of the Unicode Han Database, each with its "
        "radical-stroke index, total strokes and IRG sources. Readings: Mandarin "
        "(pinyin, incl. the other readings of the 通用规范汉字字典, 现代汉语词典 and "
        "汉语大字典), Cantonese (jyutping), Tang-era Middle Chinese, fanqie, Japanese "
        "on/kun, Korean Hangul (readings found only in kKorean, which Unicode does "
        "not recommend, are listed separately as 참고), Vietnamese and Zhuang; "
        f"simplified, traditional and semantic variant links. Only {n_def:,} "
        "characters have an English "
        f"definition, and {n_bare:,} (about {round(100 * n_bare / count)}%) have no "
        "reading or definition, only the radical-stroke, block and IRG-source "
        "lines.</p>"
        "<p>Source: Unicode® Han Database (Unihan), "
        "<a href='https://www.unicode.org/reports/tr38/'>unicode.org/reports/tr38</a>, "
        f"<a href='https://www.unicode.org/Public/{UNIHAN_VERSION}/ucd/'>Unihan.zip "
        f"{UNIHAN_VERSION}</a>. Copyright © {UNIHAN_COPYRIGHT_YEARS} Unicode, Inc. "
        "Distributed under the <a href='https://www.unicode.org/license.txt'>Unicode "
        "License v3</a>. The kana readings (kJapanese) come from the Moji Jōhō Kiban "
        "database, owned by CITPC (文字情報技術促進協議会) and used by Unicode under "
        "license.</p>"
        "<p>Converted to MDict and reformatted by OpenMDict: Korean Revised "
        "Romanization derived from Hangul, Yale readings converted to Hangul, "
        "Japanese Hepburn romaji added, readings merged across Unihan fields.</p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "Unihan — CJK Character Database", desc_html,
                                   mdx_path, inputs=[DATA_DIR])
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="Unihan CJK Characters",
        description=(f"All {count:,} Unicode CJK ideographs with radical-stroke index and "
                     "stroke counts; Mandarin, Cantonese, Middle Chinese, Japanese on/kun, "
                     "Korean, Vietnamese and Zhuang readings; variant links. English "
                     f"definitions for {n_def:,} characters."),
        direction={"src": "ZH", "dest": ["EN"]},
        entries=count,
        license="Unicode-3.0",
        data_source=f"Unicode Unihan Database {UNIHAN_VERSION}",
        tier=3,
        flag="🇨🇳🇹🇼🇭🇰🇯🇵🇰🇷",
    )

    _generate_preview(data, radical_chars, keys)


if __name__ == '__main__':
    main()
