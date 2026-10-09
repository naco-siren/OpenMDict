#!/usr/bin/env python3
"""
Build Unihan CJK Character Database MDX dictionary.

Usage:
    python build_unihan_mdx.py

Input:  ../data/unihan/Unihan_*.txt
Output: ../output/Unihan-CJK/Unihan-CJK.mdx
"""

import sys
from pathlib import Path
from collections import defaultdict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, CJK_READING_TAGS
from shared.html import esc
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data" / "unihan"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "Unihan-CJK"

# Files to parse
READINGS_FILE = DATA_DIR / "Unihan_Readings.txt"
RADSTROKE_FILE = DATA_DIR / "Unihan_RadicalStrokeCounts.txt"
VARIANTS_FILE = DATA_DIR / "Unihan_Variants.txt"
DICTLIKE_FILE = DATA_DIR / "Unihan_DictionaryLikeData.txt"

# ── HTML ───────────────────────────────────────────────────────

DIR_LABEL = '🇨🇳🇹🇼🇭🇰🇯🇵🇰🇷 漢字'

CSS = get_css(
    CJK_READING_TAGS,
    extra_light=(
        '.ch{font-size:2.5em;font-weight:400;display:block;padding:8px 0}'
        '.ucp{font-size:0.8em;color:#8e8e93;display:block}'
        '.info{font-size:0.85em;color:#8e8e93;display:block;margin-bottom:8px}'
        '.rd{margin:6px 0;display:flex;flex-wrap:wrap;align-items:baseline;gap:2px}'
        '.rd-label{font-size:0.8em;color:#8e8e93;margin-right:4px;min-width:50px}'
        '.df{font-size:1.15em}'
        '.vr{font-size:0.9em;color:#636366;margin:4px 0}'
        '.vr a{color:#0071e3;text-decoration:underline}'
    ),
    extra_dark=(
        '.ucp{color:#636366}'
        '.info{color:#636366}'
        '.vr{color:#98989d}'
        '.vr a{color:#64d2ff}'
    ),
)


# ── Romaji → Kana converter ──────────────────────────────────

# Longest-match-first romaji→katakana table
_ROMAJI_KATA = {
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


def _romaji_to_katakana(text: str) -> str:
    """Convert uppercase Hepburn romaji to katakana."""
    result = []
    i = 0
    s = text.upper()
    n = len(s)
    while i < n:
        matched = False
        for length in (3, 2, 1):
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
                result.append(s[i])
                i += 1
    return ''.join(result)


def _romaji_to_hiragana(text: str) -> str:
    """Convert uppercase Hepburn romaji to hiragana."""
    kata = _romaji_to_katakana(text)
    # Katakana (U+30A1..U+30F6, U+30F3) → Hiragana by subtracting 0x60
    return ''.join(
        chr(ord(c) - 0x60) if '\u30A1' <= c <= '\u30F6' or c == '\u30F3' else c
        for c in kata
    )


# ── Parser ─────────────────────────────────────────────────────

def parse_unihan_file(filepath: Path, data: dict):
    """Parse a Unihan_*.txt file, adding properties to data[codepoint]."""
    if not filepath.exists():
        print(f"  Warning: {filepath} not found, skipping")
        return
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t', 2)
            if len(parts) < 3:
                continue
            cp, prop, value = parts
            data[cp][prop] = value


def codepoint_to_char(cp: str) -> str:
    """Convert 'U+XXXX' to the actual character."""
    return chr(int(cp[2:], 16))


def codepoint_list_to_chars(value: str) -> list[str]:
    """Convert 'U+XXXX U+YYYY' to list of characters."""
    chars = []
    for part in value.split():
        part = part.strip()
        if part.startswith('U+'):
            try:
                chars.append(chr(int(part[2:], 16)))
            except (ValueError, OverflowError):
                pass
    return chars


# ── HTML generation ────────────────────────────────────────────

def make_html(cp: str, props: dict) -> str:
    """Generate HTML for a single CJK character entry."""
    char = codepoint_to_char(cp)
    parts = [f'<span class="dir">{DIR_LABEL}</span>']
    parts.append(f'<span class="ch">{esc(char)}</span>')
    parts.append(f'<span class="ucp">{esc(cp)}</span>')

    # Info line: radical-stroke, total strokes
    info_items = []
    rs = props.get('kRSKangXi', '') or props.get('kRSUnicode', '')
    if rs:
        # Format: "radical.additional_strokes"
        rs_parts = rs.split('.')
        if len(rs_parts) == 2:
            info_items.append(f'radical {rs_parts[0]}, +{rs_parts[1]} strokes')
    ts = props.get('kTotalStrokes', '')
    if ts:
        info_items.append(f'{ts} total strokes')
    if info_items:
        parts.append(f'<span class="info">{" · ".join(info_items)}</span>')

    # Readings — colored tags (same style as KANJIDIC2)
    # Order: 拼音 → 粤拼 → 唐音 → 音 → 訓 → 한국 → Việt

    mandarin = props.get('kMandarin', '')
    if mandarin:
        tags = ''.join(f'<span class="tag tag-py">{esc(v)}</span>'
                       for v in mandarin.split() if v)
        parts.append(f'<div class="rd"><span class="rd-label">拼音</span>{tags}</div>')

    cantonese = props.get('kCantonese', '')
    if cantonese:
        tags = ''.join(f'<span class="tag tag-py">{esc(v)}</span>'
                       for v in cantonese.split() if v)
        parts.append(f'<div class="rd"><span class="rd-label">粵拼</span>{tags}</div>')

    tang = props.get('kTang', '')
    if tang:
        tags = ''.join(f'<span class="tag tag-py">{esc(v)}</span>'
                       for v in tang.split() if v)
        parts.append(f'<div class="rd"><span class="rd-label">唐音</span>{tags}</div>')

    # Japanese: romaji → kana conversion (show kana + romaji paired)
    ja_on = props.get('kJapaneseOn', '')
    ja_kun = props.get('kJapaneseKun', '')
    ja_generic = props.get('kJapanese', '')
    if ja_on or ja_kun:
        if ja_on:
            tags = ''.join(
                f'<span class="tag tag-on">{esc(_romaji_to_katakana(v))} {esc(v.lower())}</span>'
                for v in ja_on.split() if v)
            parts.append(f'<div class="rd"><span class="rd-label">音</span>{tags}</div>')
        if ja_kun:
            tags = ''.join(
                f'<span class="tag tag-kun">{esc(_romaji_to_hiragana(v))} {esc(v.lower())}</span>'
                for v in ja_kun.split() if v)
            parts.append(f'<div class="rd"><span class="rd-label">訓</span>{tags}</div>')
    elif ja_generic:
        tags = ''.join(
            f'<span class="tag tag-on">{esc(_romaji_to_katakana(v))} {esc(v.lower())}</span>'
            for v in ja_generic.split() if v)
        parts.append(f'<div class="rd"><span class="rd-label">日本語</span>{tags}</div>')

    # Korean: pair kHangul (hangul) with kKorean (romanization)
    hangul = props.get('kHangul', '')
    korean = props.get('kKorean', '')
    if hangul:
        hangul_list = [v.split(":")[0] for v in hangul.split() if v]
        korean_list = [v.lower() for v in korean.split()] if korean else []
        tags_list = []
        for i, h in enumerate(hangul_list):
            rom = korean_list[i] if i < len(korean_list) else ''
            label = f'{h} {rom}' if rom else h
            tags_list.append(f'<span class="tag tag-ko">{esc(label)}</span>')
        # Extra romanizations beyond hangul count
        for j in range(len(hangul_list), len(korean_list)):
            tags_list.append(f'<span class="tag tag-ko">{esc(korean_list[j])}</span>')
        parts.append(f'<div class="rd"><span class="rd-label">한국</span>{"".join(tags_list)}</div>')
    elif korean:
        tags = ''.join(f'<span class="tag tag-ko">{esc(v.lower())}</span>'
                       for v in korean.split() if v)
        parts.append(f'<div class="rd"><span class="rd-label">한국</span>{tags}</div>')

    vietnamese = props.get('kVietnamese', '')
    if vietnamese:
        tags = ''.join(f'<span class="tag tag-vi">{esc(v)}</span>'
                       for v in vietnamese.split() if v)
        parts.append(f'<div class="rd"><span class="rd-label">Việt</span>{tags}</div>')

    # Definition
    definition = props.get('kDefinition', '')
    if definition:
        parts.append(f'<div class="sn"><span class="df">{esc(definition)}</span></div>')

    # Variants
    variant_items = []
    simp = props.get('kSimplifiedVariant', '')
    if simp:
        chars = codepoint_list_to_chars(simp)
        links = ', '.join(f'<a href="entry://{esc(c)}">{esc(c)}</a>' for c in chars)
        variant_items.append(f'Simplified: {links}')
    trad = props.get('kTraditionalVariant', '')
    if trad:
        chars = codepoint_list_to_chars(trad)
        links = ', '.join(f'<a href="entry://{esc(c)}">{esc(c)}</a>' for c in chars)
        variant_items.append(f'Traditional: {links}')
    sem = props.get('kSemanticVariant', '')
    if sem:
        chars = codepoint_list_to_chars(sem)
        if chars:
            links = ', '.join(f'<a href="entry://{esc(c)}">{esc(c)}</a>' for c in chars[:5])
            variant_items.append(f'Variant: {links}')

    for vi in variant_items:
        parts.append(f'<div class="vr">{vi}</div>')

    return f'{CSS}<div class="e">{"".join(parts)}</div>'


# ── Preview ────────────────────────────────────────────────────

SAMPLE_WORDS = ['中', '人', '大', '山', '水', '火', '日', '月']


def _generate_preview(data: dict, char_to_cp: dict):
    entries_html = []
    for hw in SAMPLE_WORDS:
        cp = char_to_cp.get(hw)
        if cp and cp in data:
            entries_html.append(make_html(cp, data[cp]))
    preview_path = OUTPUT_DIR / "unihan_preview.html"
    _shared_preview(entries_html, preview_path, 'Unihan — preview')


# ── Main ───────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Parsing Unihan database...")

    data = defaultdict(dict)  # codepoint → {property: value}

    print("  Loading Unihan_Readings.txt...")
    parse_unihan_file(READINGS_FILE, data)
    print(f"    {len(data)} codepoints so far")

    print("  Loading Unihan_RadicalStrokeCounts.txt...")
    parse_unihan_file(RADSTROKE_FILE, data)
    print(f"    {len(data)} codepoints so far")

    print("  Loading Unihan_Variants.txt...")
    parse_unihan_file(VARIANTS_FILE, data)
    print(f"    {len(data)} codepoints so far")

    print("  Loading Unihan_DictionaryLikeData.txt...")
    parse_unihan_file(DICTLIKE_FILE, data)
    print(f"    {len(data)} total codepoints loaded")

    # Filter: only include chars with kDefinition, kMandarin, or kJapanese/kJapaneseOn
    filtered = {}
    for cp, props in data.items():
        if any(k in props for k in ('kDefinition', 'kMandarin', 'kJapanese', 'kJapaneseOn')):
            filtered[cp] = props

    print(f"  {len(filtered)} characters with definitions or readings")

    # Build char → codepoint map for lookups
    char_to_cp = {}
    for cp in filtered:
        try:
            char = codepoint_to_char(cp)
            char_to_cp[char] = cp
        except (ValueError, OverflowError):
            pass

    # Write MDict source
    txt_path = OUTPUT_DIR / "unihan_entries.txt"
    print(f"Writing → {txt_path}...")

    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for cp in sorted(filtered.keys()):
            try:
                char = codepoint_to_char(cp)
            except (ValueError, OverflowError):
                continue
            html = make_html(cp, filtered[cp])
            f.write(f"{char}\n{html}\n</>\n")
            count += 1

    print(f"  {count} entries written")

    # Pack MDX
    mdx_path = OUTPUT_DIR / "Unihan-CJK.mdx"
    desc_html = (
        "<p><b>Unihan — CJK Character Database</b></p>"
        "<p>Unicode Han character database with readings in Mandarin, Cantonese, "
        "Japanese, Korean, and Vietnamese. Includes radical-stroke indices and "
        "simplified/traditional variant links.</p>"
        "<p>Unicode License (essentially public domain).</p>"
        "<p>Source: <a href='https://www.unicode.org/reports/tr38/'>unicode.org/reports/tr38</a></p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "Unihan — CJK Character Database", desc_html, mdx_path)
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="Unihan CJK Characters",
        description="Unicode CJK character database with pinyin, on/kun, Korean, Vietnamese, Cantonese readings, radical-stroke index.",
        direction={"src": "ZH", "dest": ["EN"]},
        entries=count,
        license="Unicode License",
        data_source="Unicode Unihan Database",
        tier=3,
        flag="🇨🇳🇹🇼🇭🇰🇯🇵🇰🇷",
    )

    _generate_preview(data, char_to_cp)


if __name__ == '__main__':
    main()
