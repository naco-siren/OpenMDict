#!/usr/bin/env python3
"""
Build CC-CEDICT MDX dictionary from cedict_ts.u8 source.

Usage:
    python build_cedict_mdx.py

Input:  ../data/cedict_ts.u8
Output: ../output/CEDICT-ZH-EN/CEDICT-ZH-EN.mdx
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


# ── CC-CEDICT parser ──────────────────────────────────────────

def parse_cedict(filepath: Path):
    """Parse CC-CEDICT file, yield (traditional, simplified, pinyin_unicode, definitions[])."""
    pattern = re.compile(r'^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+/(.+)/$')
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            m = pattern.match(line)
            if not m:
                continue
            trad, simp, pinyin_raw, defs_str = m.groups()
            pinyin_unicode = pinyin_to_unicode(pinyin_raw)
            definitions = [d.strip() for d in defs_str.split('/') if d.strip()]
            yield trad, simp, pinyin_unicode, definitions


# ── HTML generation (V3: compact, direction labels as top bar) ─

FLAG_CN = '\U0001F1E8\U0001F1F3\U0001F1F9\U0001F1FC'  # 🇨🇳🇹🇼
FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_CN} 中文 → English {FLAG_EN}'

CSS = get_css(
    ORDERED_LIST,
    extra_light=(
        '.s{font-size:1.7em;font-weight:600;display:block}'
        '.t{font-size:1.25em;color:#6e6e73;display:block;margin-top:2px}'
        '.p{font-size:1.25em;color:#0071e3;font-style:italic;display:block;margin-top:2px}'
    ),
    extra_dark=(
        '.t{color:#98989d}.p{color:#64d2ff}'
    ),
)


# Regex to find Chinese cross-references in CEDICT definitions.
# Matches patterns like: "variant of 繁體|简体[pinyin]" or "see 词[pinyin]"
# Group 1 = prefix text (e.g. "variant of ")
# Group 2 = trad|simp or just word
# Group 3 = [pinyin] (optional)
_XREF_RE = re.compile(
    r'((?:see(?: also)?|[Vv]ariant of|[Oo]ld variant of|'
    r'[Aa]bbr\. for|[Ss]hort for|[Aa]lso written|[Ss]ame as|'
    r'[Ee]rhua variant of|[Cc]lassifier for|[Aa]lso pr\.) )'
    r'([\u4e00-\u9fff\u3400-\u4dbf\u3000-\u303fA-Z0-9]+'
    r'(?:\|[\u4e00-\u9fff\u3400-\u4dbf\u3000-\u303fA-Z0-9]+)?)'
    r'(\[[^\]]*\])?'
)


def _linkify_def(text: str, entry_lookup: set) -> str:
    """Replace cross-reference patterns in a CEDICT definition with entry:// links."""
    def _replace(m):
        prefix = m.group(1)       # "variant of ", "see ", etc.
        chars = m.group(2)        # "繁體|简体" or "词"
        pinyin = m.group(3) or '' # "[pinyin]"
        # Extract simplified form (after |) or the only form
        simp = chars.split('|')[-1] if '|' in chars else chars
        if simp in entry_lookup:
            return f'{esc(prefix)}<a href="entry://{esc(simp)}">{esc(chars)}</a>{esc(pinyin)}'
        return esc(m.group(0))
    # Apply regex on raw text, then escape non-matched parts
    result = []
    last_end = 0
    for m in _XREF_RE.finditer(text):
        result.append(esc(text[last_end:m.start()]))
        result.append(_replace(m))
        last_end = m.end()
    result.append(esc(text[last_end:]))
    return ''.join(result)


def make_html(simp: str, trad: str, pinyin: str, defs: list[str],
              entry_lookup: set = None) -> str:
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
        f'<span class="p">{esc(pinyin)}</span>'
        f'<div class="sn"><ol class="d">{defs_html}</ol></div></div>'
    )


def make_combined_html(simp: str, parts: list[tuple[str, str, list[str]]],
                       entry_lookup: set = None) -> str:
    """Generate HTML for a headword with potentially multiple readings."""
    if len(parts) == 1:
        trad, pinyin, defs = parts[0]
        return make_html(simp, trad, pinyin, defs, entry_lookup)

    sections = []
    for i, (trad, pinyin, defs) in enumerate(parts):
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
            f'<span class="p">{esc(pinyin)}</span>'
            f'<div class="sn"><ol class="d">{defs_html}</ol></div>'
        )
        sections.append(section)
    body = '<hr class="sep">'.join(sections)
    return f'{CSS}<div class="e">{body}</div>'


# ── Preview ───────────────────────────────────────────────────

SAMPLE_WORDS = ['你好', '电脑', '美丽', '水', '跑', '中国']


def _generate_preview(entries: dict):
    """Generate a preview HTML for visual review."""
    entries_html = []
    for hw in SAMPLE_WORDS:
        if hw in entries:
            entries_html.append(make_combined_html(hw, entries[hw]))
    preview_path = OUTPUT_DIR / "cedict_preview.html"
    _shared_preview(entries_html, preview_path, 'CC-CEDICT — preview')


# ── Main ──────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Parsing CC-CEDICT...")

    # Group by simplified headword
    entries = defaultdict(list)  # simplified → [(trad, pinyin, defs)]
    all_trads = set()

    for trad, simp, pinyin, defs in parse_cedict(CEDICT_FILE):
        entries[simp].append((trad, pinyin, defs))
        if trad != simp:
            all_trads.add(trad)

    # Traditional forms that are ALSO standalone simplified entries get full HTML
    # Others become @@@LINK redirects
    redirect_trads = all_trads - set(entries.keys())

    print(f"  {len(entries)} simplified entries")
    print(f"  {len(redirect_trads)} traditional → simplified redirects")
    print(f"  {len(all_trads) - len(redirect_trads)} traditional forms that are also simplified entries (keep full HTML)")

    # Build redirect map: trad → simp (pick first seen)
    trad_to_simp = {}
    for simp, parts in entries.items():
        for trad, _, _ in parts:
            if trad in redirect_trads and trad not in trad_to_simp:
                trad_to_simp[trad] = simp

    # Build entry lookup set for entry:// cross-linking
    entry_lookup = set(entries.keys())
    print(f"  {len(entry_lookup)} simplified headwords for cross-linking")

    # Write mdict source file
    txt_path = OUTPUT_DIR / "cedict_entries.txt"
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
    mdx_path = OUTPUT_DIR / "CEDICT-ZH-EN.mdx"
    desc_html = (
        "<p><b>CC-CEDICT Chinese-English Dictionary</b></p>"
        "<p>Community-maintained free Chinese-English dictionary with ~124K entries.</p>"
        "<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/4.0/'>CC-BY-SA 4.0</a>.</p>"
        "<p>Published by MDBG. Originally created by Paul Andrew Denisowski.</p>"
        "<p>Source: <a href='https://cc-cedict.org/'>cc-cedict.org</a></p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "CC-CEDICT Chinese-English", desc_html, mdx_path)
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="CC-CEDICT Chinese-English",
        description="Community-maintained Chinese-English dictionary with pinyin, traditional/simplified characters, and English definitions.",
        direction={"src": "ZH", "dest": ["EN"]},
        entries=count,
        license="CC-BY-SA 4.0",
        data_source="CC-CEDICT",
        tier=2,
    )

    # Generate preview
    _generate_preview(entries)


if __name__ == '__main__':
    main()
