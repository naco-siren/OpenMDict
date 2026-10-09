#!/usr/bin/env python3
"""
Build MDX dictionaries from Vuizur/Wiktionary-Dictionaries TSV data.

Supports: Korean↔English, Arabic↔English

Usage:
    python build_wiktionary_mdx.py          # build all
    python build_wiktionary_mdx.py ko       # Korean only
    python build_wiktionary_mdx.py ar       # Arabic only

Input:  ../data/wiktionary-{Lang}-English.tsv
Output: ../output/Wiktionary-{XX}-EN.mdx
"""

import re
import sys
from pathlib import Path
from collections import defaultdict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, GLOSS, ORDERED_LIST
from shared.html import esc
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output"

# ── Language definitions ───────────────────────────────────────

LANGUAGES = {
    'ko': {
        'code': 'ko',
        'name_en': 'Korean',
        'name_native': '한국어',
        'flag': '\U0001F1F0\U0001F1F7',  # 🇰🇷
        'tsv_file': 'wiktionary-Korean-English.tsv',
    },
    'ar': {
        'code': 'ar',
        'name_en': 'Arabic',
        'name_native': 'العربية',
        'flag': '\U0001F1F8\U0001F1E6',  # 🇸🇦
        'tsv_file': 'wiktionary-Arabic-English.tsv',
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
    'affix': 'affix',
}


# ── CSS ────────────────────────────────────────────────────────
CSS = get_css(
    GLOSS, ORDERED_LIST,
    extra_light=(
        '.rm{font-size:1.15em;color:#0071e3;font-style:italic;display:block;margin-top:2px}'
        '.alt{font-size:1.25em;color:#6e6e73;display:block;margin-top:2px}'
    ),
    extra_dark=(
        '.rm{color:#64d2ff}'
        '.alt{color:#98989d}'
    ),
)


# ── Korean-specific processing ─────────────────────────────────

# Simple romanization detector: if it's purely ASCII letters/spaces/apostrophes
_ROMAJI_RE = re.compile(r"^[A-Za-z\s''·\-]+$")

# Hanja detector: CJK Unified Ideographs
_HANJA_RE = re.compile(r'[\u4E00-\u9FFF\u3400-\u4DBF]')

# Korean (Hangul) detector
_HANGUL_RE = re.compile(r'[\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]')

# Arabic script detector
_ARABIC_RE = re.compile(r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]')


def classify_korean_alts(headword: str, alt_forms: list) -> dict:
    """Classify alternative forms for Korean entries."""
    result = {'romanization': None, 'hanja': None, 'hangul_alts': []}

    rom_candidates = []

    for form in alt_forms:
        form = form.strip()
        if not form or form == headword:
            continue

        # Skip counter/classifier markers
        if form in ('명', '名', '마리', '개', '대', '장', '벌', '켤레', '채'):
            continue

        # Skip IPA-like forms and annotations
        if (form.startswith('/') and form.endswith('/')) or ' of ' in form or form.startswith('\\'):
            continue

        if _ROMAJI_RE.match(form) and not _HANJA_RE.search(form):
            rom_candidates.append(form)
        elif _HANJA_RE.search(form) and not _HANGUL_RE.search(form):
            # Pure Hanja
            if result['hanja'] is None:
                # Clean up forms like 十月／10月
                result['hanja'] = form.split('／')[0]
        elif _HANGUL_RE.search(form) and len(form) < 20:
            # Hangul alternative (skip long inflected forms)
            if len(result['hangul_alts']) < 2:
                result['hangul_alts'].append(form)

    # Pick best romanization: prefer one closest in length to headword
    # (1 hangul syllable ≈ 2-3 romaji chars)
    if rom_candidates:
        expected_len = len(headword) * 2.5
        rom_candidates.sort(key=lambda r: (abs(len(r) - expected_len), len(r)))
        result['romanization'] = rom_candidates[0]

    return result


def classify_arabic_alts(headword: str, alt_forms: list) -> dict:
    """Classify alternative forms for Arabic entries."""
    result = {'transliteration': None}

    for form in alt_forms:
        form = form.strip()
        if not form or form == headword:
            continue

        # Transliteration: ASCII text with diacritics
        if not _ARABIC_RE.search(form) and _ROMAJI_RE.match(form):
            if result['transliteration'] is None:
                result['transliteration'] = form

    return result


# ── HTML generation from TSV ───────────────────────────────────

def parse_tsv_html(html: str) -> list:
    """
    Parse the pre-formatted HTML from TSV into structured (pos, definitions[]).

    Input HTML example:
      <i>noun</i><br><ol><li>def1</li><li>def2</li></ol><br><i>verb</i><br><ol><li>def3</li></ol>

    Returns: list of (pos_tag, [definition_strings])
    """
    result = []

    # Split by POS sections
    # Pattern: <i>pos</i><br><ol><li>...</li></ol>
    pos_pattern = re.compile(
        r'<i>([^<]+)</i>\s*<br>\s*<ol>(.*?)</ol>',
        re.DOTALL
    )

    for match in pos_pattern.finditer(html):
        raw_pos = match.group(1).strip().lower()
        pos = POS_MAP.get(raw_pos, raw_pos)
        ol_content = match.group(2)

        # Extract definitions from <li> tags
        defs = re.findall(r'<li>(.*?)</li>', ol_content, re.DOTALL)
        # Clean up definitions: strip HTML tags, unescape
        cleaned_defs = []
        for d in defs:
            # Remove internal HTML markup but keep text
            d = re.sub(r'<[^>]+>', '', d)
            d = d.strip()
            if d:
                cleaned_defs.append(d)

        if cleaned_defs and pos:
            result.append((pos, cleaned_defs))

    return result


def make_entry_html_ko(headword: str, alts: dict, pos_defs: list, dir_label: str) -> str:
    """Build HTML for a Korean entry."""
    # Direction label as top bar (above headword)
    inner = f'<span class="dir">{dir_label}</span>'
    inner += f'<span class="hw">{esc(headword)}</span>'

    # Hanja line (below headword, above romanization — consistent with JMdict kanji→kana→romaji)
    if alts['hanja']:
        inner += f'<span class="alt">{esc(alts["hanja"])}</span>'

    # Romanization line
    if alts['romanization']:
        inner += f'<span class="rm">{esc(alts["romanization"])}</span>'

    # POS + definitions (card-style)
    for pos, defs in pos_defs:
        inner += '<div class="sn">'
        if pos:
            inner += f'<div class="sn-hd"><span class="pos">{esc(pos)}</span></div>'
        if len(defs) == 1:
            inner += f'<span class="gl">{esc(defs[0])}</span>'
        else:
            li_html = ''.join(f'<li>{esc(d)}</li>' for d in defs[:8])
            inner += f'<ol class="d">{li_html}</ol>'
        inner += '</div>'

    return f'{CSS}<div class="e">{inner}</div>'


def make_entry_html_ar(headword: str, alts: dict, pos_defs: list, dir_label: str) -> str:
    """Build HTML for an Arabic entry."""
    # Direction label as top bar (above headword)
    inner = f'<span class="dir">{dir_label}</span>'
    inner += f'<span class="hw" style="direction:rtl">{esc(headword)}</span>'

    # Transliteration line
    if alts['transliteration']:
        inner += f'<span class="rm">{esc(alts["transliteration"])}</span>'

    # POS + definitions (card-style)
    for pos, defs in pos_defs:
        inner += '<div class="sn">'
        if pos:
            inner += f'<div class="sn-hd"><span class="pos">{esc(pos)}</span></div>'
        if len(defs) == 1:
            inner += f'<span class="gl">{esc(defs[0])}</span>'
        else:
            li_html = ''.join(f'<li>{esc(d)}</li>' for d in defs[:8])
            inner += f'<ol class="d">{li_html}</ol>'
        inner += '</div>'

    return f'{CSS}<div class="e">{inner}</div>'


# ── Main build logic ───────────────────────────────────────────

def build_language(lang_code: str):
    """Build MDX for a single language."""
    lang = LANGUAGES[lang_code]
    code = lang['code']
    name_en = lang['name_en']
    name_native = lang['name_native']
    flag = lang['flag']
    tsv_file = lang['tsv_file']
    dir_label = f'{flag} {name_native} → English {FLAG_EN}'

    tsv_path = DATA_DIR / tsv_file
    if not tsv_path.exists():
        print(f"ERROR: {tsv_path} not found")
        return None

    print(f"\n{'='*60}")
    print(f"Building Wiktionary-{code.upper()}-EN ({name_en}-English)")
    print(f"{'='*60}")

    # Parse TSV
    print(f"Parsing {tsv_file}...")
    entries = {}  # headword → (alts_dict, pos_defs)
    redirect_keys = []  # (alt_form, headword)

    skipped_no_def = 0
    skipped_root = 0
    total_lines = 0

    with open(tsv_path, 'r', encoding='utf-8') as f:
        for line in f:
            total_lines += 1
            line = line.rstrip('\n')
            parts = line.split('\t', 1)
            if len(parts) < 2 or not parts[1].strip():
                skipped_no_def += 1
                continue

            headword_col, html = parts
            forms = headword_col.split('|')
            headword = forms[0].strip()

            if not headword:
                continue

            # Parse HTML into structured data
            pos_defs = parse_tsv_html(html)
            if not pos_defs:
                skipped_no_def += 1
                continue

            # Skip "root" entries for Arabic (they just describe morphological roots)
            if code == 'ar' and all(p == 'root' for p, _ in pos_defs):
                skipped_root += 1
                continue

            # Skip romanization-only entries (e.g., Korean romanization forms)
            if code == 'ko' and all(p == 'rom.' for p, _ in pos_defs):
                continue

            # Classify alternative forms
            alt_forms = forms[1:] if len(forms) > 1 else []
            if code == 'ko':
                alts = classify_korean_alts(headword, alt_forms)
            else:
                alts = classify_arabic_alts(headword, alt_forms)

            # Merge if headword already exists (multiple entries)
            if headword in entries:
                existing_alts, existing_defs = entries[headword]
                existing_defs.extend(pos_defs)
                entries[headword] = (existing_alts, existing_defs)
            else:
                entries[headword] = (alts, pos_defs)

    print(f"  Total lines: {total_lines}")
    print(f"  Skipped (no definitions): {skipped_no_def}")
    if skipped_root:
        print(f"  Skipped (root-only): {skipped_root}")
    print(f"  Unique headwords: {len(entries)}")

    # Generate MDX entries
    dict_dir = OUTPUT_DIR / f"Wiktionary-{code.upper()}-EN"
    dict_dir.mkdir(parents=True, exist_ok=True)
    txt_path = dict_dir / f"wiktionary_{code}_entries.txt"

    print(f"Generating entries → {txt_path}...")
    count = 0

    with open(txt_path, 'w', encoding='utf-8') as f:
        for hw in sorted(entries.keys()):
            alts, pos_defs = entries[hw]

            if code == 'ko':
                html = make_entry_html_ko(hw, alts, pos_defs, dir_label)
            else:
                html = make_entry_html_ar(hw, alts, pos_defs, dir_label)

            f.write(f"{hw}\n{html}\n</>\n")
            count += 1

            # Add romanization as redirect (Korean)
            if code == 'ko' and alts.get('romanization'):
                rom = alts['romanization']
                if rom != hw and rom not in entries:
                    f.write(f"{rom}\n@@@LINK={hw}\n</>\n")
                    count += 1

    print(f"  {count} total entries written")

    # Pack MDX
    dict_name = f"Wiktionary {name_en}-English"
    mdx_path = dict_dir / f"Wiktionary-{code.upper()}-EN.mdx"
    desc_html = (
        f"<p><b>{dict_name} Dictionary</b></p>"
        f"<p>{name_en}→English dictionary extracted from English Wiktionary.</p>"
        f"<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/3.0/'>CC-BY-SA 3.0</a> / "
        f"<a href='https://www.gnu.org/copyleft/fdl.html'>GFDL</a>.</p>"
        f"<p>Source: <a href='https://en.wiktionary.org/'>English Wiktionary</a> "
        f"via <a href='https://kaikki.org/'>kaikki.org</a></p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, dict_name, desc_html, mdx_path)
    if not success:
        return None
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB ({count} entries)")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name=dict_name,
        description=f"Wiktionary {name_en}-English with {count:,} entries. Alternative to the Kaikki version for comparison.",
        direction={"src": code.upper(), "dest": ["EN"]},
        entries=count,
        license="CC-BY-SA 3.0 / GFDL",
        data_source="English Wiktionary",
        tier=3,
    )

    return mdx_path


def _generate_preview(lang_code: str, sample_words: list):
    """Generate a preview HTML for visual review."""
    lang = LANGUAGES[lang_code]
    code = lang['code']
    name_en = lang['name_en']
    name_native = lang['name_native']
    flag = lang['flag']
    dir_label = f'{flag} {name_native} → English {FLAG_EN}'

    tsv_path = DATA_DIR / lang['tsv_file']

    # Load sample entries for preview
    all_entries = {}
    with open(tsv_path, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.rstrip('\n').split('\t', 1)
            if len(parts) < 2:
                continue
            forms = parts[0].split('|')
            hw = forms[0].strip()
            if hw in sample_words:
                pos_defs = parse_tsv_html(parts[1])
                if pos_defs:
                    alt_forms = forms[1:] if len(forms) > 1 else []
                    if code == 'ko':
                        alts = classify_korean_alts(hw, alt_forms)
                    else:
                        alts = classify_arabic_alts(hw, alt_forms)
                    all_entries[hw] = (alts, pos_defs)

    entries_html = []
    for hw in sample_words:
        if hw in all_entries:
            alts, pos_defs = all_entries[hw]
            if code == 'ko':
                entries_html.append(make_entry_html_ko(hw, alts, pos_defs, dir_label))
            else:
                entries_html.append(make_entry_html_ar(hw, alts, pos_defs, dir_label))

    dict_dir = OUTPUT_DIR / f"Wiktionary-{code.upper()}-EN"
    dict_dir.mkdir(parents=True, exist_ok=True)
    preview_path = dict_dir / f"wiktionary_{code}_preview.html"
    _shared_preview(entries_html, preview_path, f'Wiktionary {name_en}→English — preview')


# ── Entry point ────────────────────────────────────────────────

SAMPLE_WORDS = {
    'ko': ['안녕하세요', '사랑', '한국', '학생', '물', '컴퓨터', '먹다', '아름답다'],
    'ar': ['مرحبا', 'كتاب', 'ماء', 'جميل', 'بيت', 'حاسوب', 'أكل', 'عربي'],
}


def main():
    langs = sys.argv[1:] if len(sys.argv) > 1 else list(LANGUAGES.keys())

    for code in langs:
        if code not in LANGUAGES:
            print(f"Unknown language: {code}")
            print(f"Supported: {', '.join(LANGUAGES.keys())}")
            continue

        mdx = build_language(code)
        if mdx:
            samples = SAMPLE_WORDS.get(code, [])
            if samples:
                _generate_preview(code, samples)


if __name__ == '__main__':
    main()
