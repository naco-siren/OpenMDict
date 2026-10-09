#!/usr/bin/env python3
"""
Build CC-Canto (Cantonese-English) MDX dictionary from CC-Canto data.

CC-Canto provides Cantonese-specific vocabulary with Jyutping romanization
and English definitions.  Data format is CC-CEDICT-compatible with an added
{jyutping} field.

Usage:
    python build_cccanto_mdx.py

Input:  ../data/cc-canto/cccanto-webdist.txt
Output: ../output/CC-Canto-YUE-EN/CC-Canto-YUE-EN.mdx
"""

import re
import sys
from pathlib import Path
from collections import defaultdict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, ORDERED_LIST
from shared.html import esc
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata
DATA_DIR = SCRIPT_DIR.parent / "data" / "cc-canto"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "CC-Canto-YUE-EN"
DICT_NAME = "CC-Canto-YUE-EN"
CANTO_FILE = DATA_DIR / "cccanto-webdist.txt"

# ── Pinyin tone conversion (reused from CEDICT) ──────────────

TONE_MARKS = {
    'a': 'āáǎàa', 'e': 'ēéěèe', 'i': 'īíǐìi',
    'o': 'ōóǒòo', 'u': 'ūúǔùu', 'ü': 'ǖǘǚǜü',
    'A': 'ĀÁǍÀA', 'E': 'ĒÉĚÈE', 'I': 'ĪÍǏÌI',
    'O': 'ŌÓǑÒO', 'U': 'ŪÚǓÙU', 'Ü': 'ǕǗǙǛÜ',
}


def _pinyin_syllable_to_unicode(syllable: str) -> str:
    """Convert a single pinyin syllable like 'zhong1' to 'zhōng'."""
    if not syllable:
        return syllable
    match = re.match(r'^([a-zü]+)(\d)$', syllable, re.IGNORECASE)
    if not match:
        return syllable
    base, tone_str = match.group(1), match.group(2)
    tone = int(tone_str)
    if tone < 1 or tone > 5:
        return syllable
    if tone == 5:
        return base
    base = base.replace('v', 'ü').replace('V', 'Ü')

    for i, ch in enumerate(base):
        if ch in 'aeAE':
            return base[:i] + TONE_MARKS[ch][tone - 1] + base[i + 1:]
    if 'ou' in base.lower():
        for i, ch in enumerate(base):
            if ch in 'oO':
                return base[:i] + TONE_MARKS[ch][tone - 1] + base[i + 1:]
    vowels = 'aeiouüAEIOUÜ'
    for i in range(len(base) - 1, -1, -1):
        if base[i] in vowels:
            ch = base[i]
            return base[:i] + TONE_MARKS[ch][tone - 1] + base[i + 1:]
    return base


def pinyin_to_unicode(pinyin_numbered: str) -> str:
    """Convert numbered pinyin string to Unicode tone marks."""
    parts = pinyin_numbered.split()
    return ' '.join(_pinyin_syllable_to_unicode(p) for p in parts)


# ── CC-Canto parser ──────────────────────────────────────────

def parse_cccanto(filepath: Path):
    """Parse CC-Canto file.

    Format: 繁體 简体 [pinyin] {jyutping} /def1/def2/.../
    Yield: (traditional, simplified, pinyin_unicode, jyutping, definitions[])
    """
    pattern = re.compile(
        r'^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+\{([^}]+)\}\s+/(.+)/$'
    )
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            m = pattern.match(line)
            if not m:
                continue
            trad, simp, pinyin_raw, jyutping, defs_str = m.groups()
            pinyin_unicode = pinyin_to_unicode(pinyin_raw)
            definitions = [d.strip() for d in defs_str.split('/') if d.strip()]
            yield trad, simp, pinyin_unicode, jyutping, definitions


# ── HTML generation ──────────────────────────────────────────

FLAG_HK = '\U0001F1ED\U0001F1F0'  # 🇭🇰
FLAG_CN = '\U0001F1E8\U0001F1F3'  # 🇨🇳
FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_HK}{FLAG_CN} 粵語 → English {FLAG_EN}'

CSS = get_css(
    ORDERED_LIST,
    extra_light=(
        '.s{font-size:1.7em;font-weight:600;display:block}'
        '.t{font-size:1.25em;color:#6e6e73;display:block;margin-top:2px}'
        '.jp{font-size:1.15em;color:#0071e3;display:block;margin-top:2px}'
        '.py{font-size:0.95em;color:#8e8e93;font-style:italic;display:block;margin-top:1px}'
    ),
    extra_dark=(
        '.t{color:#98989d}.jp{color:#64d2ff}.py{color:#636366}'
    ),
)


def make_html(simp: str, trad: str, jyutping: str, pinyin: str,
              defs: list[str], entry_lookup: set = None) -> str:
    """Generate HTML for a single reading block."""
    if entry_lookup:
        defs_html = ''.join(f'<li>{_linkify_def(d, entry_lookup)}</li>' for d in defs)
    else:
        defs_html = ''.join(f'<li>{esc(d)}</li>' for d in defs)
    trad_line = f'<span class="t">{esc(trad)}</span>' if trad != simp else ''
    return (
        f'{CSS}<div class="e">'
        f'<span class="dir">{DIR_LABEL}</span>'
        f'<span class="s">{esc(simp)}</span>{trad_line}'
        f'<span class="jp">{esc(jyutping)}</span>'
        f'<span class="py">普 {esc(pinyin)}</span>'
        f'<div class="sn"><ol class="d">{defs_html}</ol></div></div>'
    )


def make_combined_html(simp: str, parts: list[tuple[str, str, str, list[str]]],
                       entry_lookup: set = None) -> str:
    """Generate HTML for a headword with potentially multiple readings."""
    if len(parts) == 1:
        trad, jyutping, pinyin, defs = parts[0]
        return make_html(simp, trad, jyutping, pinyin, defs, entry_lookup)

    sections = []
    for i, (trad, jyutping, pinyin, defs) in enumerate(parts):
        if entry_lookup:
            defs_html = ''.join(f'<li>{_linkify_def(d, entry_lookup)}</li>' for d in defs)
        else:
            defs_html = ''.join(f'<li>{esc(d)}</li>' for d in defs)
        trad_line = f'<span class="t">{esc(trad)}</span>' if trad != simp else ''
        section = ''
        if i == 0:
            section += f'<span class="dir">{DIR_LABEL}</span>'
        section += (
            f'<span class="s">{esc(simp)}</span>{trad_line}'
            f'<span class="jp">{esc(jyutping)}</span>'
            f'<span class="py">普 {esc(pinyin)}</span>'
            f'<div class="sn"><ol class="d">{defs_html}</ol></div>'
        )
        sections.append(section)
    body = '<hr class="sep">'.join(sections)
    return f'{CSS}<div class="e">{body}</div>'


# ── Cross-reference linking ──────────────────────────────────

_XREF_RE = re.compile(
    r'((?:see(?: also)?|[Vv]ariant of|[Oo]ld variant of|'
    r'[Aa]bbr\. for|[Ss]hort for|[Aa]lso written|[Ss]ame as|'
    r'[Ee]rhua variant of|[Cc]lassifier for|[Aa]lso pr\.) )'
    r'([\u4e00-\u9fff\u3400-\u4dbf\u3000-\u303fA-Z0-9]+'
    r'(?:\|[\u4e00-\u9fff\u3400-\u4dbf\u3000-\u303fA-Z0-9]+)?)'
    r'(\[[^\]]*\])?'
)


def _linkify_def(text: str, entry_lookup: set) -> str:
    """Replace cross-reference patterns with entry:// links."""
    def _replace(m):
        prefix = m.group(1)
        chars = m.group(2)
        pinyin = m.group(3) or ''
        simp = chars.split('|')[-1] if '|' in chars else chars
        if simp in entry_lookup:
            return f'{esc(prefix)}<a href="entry://{esc(simp)}">{esc(chars)}</a>{esc(pinyin)}'
        return esc(m.group(0))
    result = []
    last_end = 0
    for m in _XREF_RE.finditer(text):
        result.append(esc(text[last_end:m.start()]))
        result.append(_replace(m))
        last_end = m.end()
    result.append(esc(text[last_end:]))
    return ''.join(result)


# ── Preview ──────────────────────────────────────────────────

SAMPLE_WORDS = ['唔该', '食饭', '靓', '好嘢', '咩', '广东话']


def _generate_preview(entries: dict, entry_lookup: set):
    """Generate a preview HTML for visual review."""
    # Try exact sample words, then fallback to first 6 entries
    found_words = [hw for hw in SAMPLE_WORDS if hw in entries]
    if len(found_words) < 3:
        found_words = list(entries.keys())[:6]
        print(f"  ⚠ Sample words not found, using first {len(found_words)} entries")

    entries_html = []
    for hw in found_words[:6]:
        if hw in entries:
            entries_html.append(
                make_combined_html(hw, entries[hw], entry_lookup)
            )

    preview_path = OUTPUT_DIR / "cc_canto_preview.html"
    _shared_preview(entries_html, preview_path, f'{DICT_NAME} — preview')


# ── Main ──────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if not CANTO_FILE.exists():
        print(f"ERROR: {CANTO_FILE} not found")
        return

    print("Parsing CC-Canto...")

    # Group by simplified headword
    entries = defaultdict(list)  # simplified → [(trad, jyutping, pinyin, defs)]
    all_trads = set()

    for trad, simp, pinyin, jyutping, defs in parse_cccanto(CANTO_FILE):
        entries[simp].append((trad, jyutping, pinyin, defs))
        if trad != simp:
            all_trads.add(trad)

    # Traditional forms that don't exist as simplified entries → redirects
    redirect_trads = all_trads - set(entries.keys())

    print(f"  {len(entries)} simplified entries")
    print(f"  {len(redirect_trads)} traditional → simplified redirects")

    # Build redirect map: trad → simp (pick first seen)
    trad_to_simp = {}
    for simp, parts in entries.items():
        for trad, _, _, _ in parts:
            if trad in redirect_trads and trad not in trad_to_simp:
                trad_to_simp[trad] = simp

    # Build entry lookup set for cross-linking
    entry_lookup = set(entries.keys())
    print(f"  {len(entry_lookup)} headwords for cross-linking")

    # Write mdict source file
    txt_path = OUTPUT_DIR / "cc_canto_entries.txt"
    print(f"Writing → {txt_path}...")

    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for simp in sorted(entries.keys()):
            parts = entries[simp]
            html = make_combined_html(simp, parts, entry_lookup)
            f.write(f"{simp}\n{html}\n</>\n")
            count += 1

        for trad in sorted(trad_to_simp.keys()):
            simp = trad_to_simp[trad]
            f.write(f"{trad}\n@@@LINK={simp}\n</>\n")
            count += 1

    print(f"  {count} total entries written")

    # Pack MDX
    mdx_path = OUTPUT_DIR / f"{DICT_NAME}.mdx"
    desc_html = (
        "<p><b>CC-Canto Cantonese-English Dictionary</b></p>"
        "<p>Open-source Cantonese-English dictionary with Jyutping romanization "
        "and Mandarin pinyin cross-reference.</p>"
        "<p>Licensed under "
        "<a href='https://creativecommons.org/licenses/by-sa/3.0/'>CC BY-SA 3.0</a>.</p>"
        "<p>Source: <a href='https://cantonese.org'>cantonese.org</a> (Pleco Inc.)</p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "CC-Canto Cantonese-English", desc_html, mdx_path)
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="CC-Canto Cantonese-English",
        description="Open-source Cantonese-English dictionary with Jyutping romanization and Mandarin pinyin cross-reference.",
        direction={"src": "ZH", "dest": ["EN"]},
        entries=count,
        license="CC BY-SA 3.0",
        data_source="CC-Canto (Pleco Inc.)",
        tier=2,
        flag="🇭🇰🇨🇳",
    )

    # Generate preview
    _generate_preview(entries, entry_lookup)


if __name__ == '__main__':
    main()
