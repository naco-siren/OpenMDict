#!/usr/bin/env python3
"""
Build an English thesaurus MDX dictionary from Moby Thesaurus II.

Uses the public domain data from Project Gutenberg:
  https://www.gutenberg.org/ebooks/3202

Format: Each line is "headword,syn1,syn2,syn3,..."
30,259 root words with ~2.5 million synonym links.

Usage:
    python3 build_moby_thesaurus_mdx.py

Input:  ../data/mthesaur.txt
Output: ../output/Moby-Thesaurus-EN/Moby-Thesaurus-EN.mdx
"""

import sys
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css
from shared.html import esc, wrap_entry
from shared.build import pack_mdx, generate_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "Moby-Thesaurus-EN"

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_EN} English'

# ── CSS ────────────────────────────────────────────────────────
# Moby Thesaurus uses unique classes (.ct, .sg, .sl) and
# overrides .e line-height to 1.6.
CSS = get_css(
    extra_light=(
        '.e{line-height:1.6}'
        '.ct{font-size:0.8em;color:#8e8e93;display:block;margin:2px 0 6px}'
        '.sg{margin:8px 0;padding:8px 10px;background:#f8f8fa;border-radius:6px;'
        'border:1px solid #e5e5ea}'
        '.sl{font-size:1.05em;line-height:1.7;color:#1d1d1f}'
        '.sl a{color:#0071e3;text-decoration:none}'
        '.sl a:hover{text-decoration:underline}'
    ),
    extra_dark=(
        '.ct{color:#636366}'
        '.sg{background:#2c2c2e;border-color:#38383a}'
        '.sl{color:#f5f5f7}'
        '.sl a{color:#64d2ff}'
    ),
)

# Approximate column count thresholds for grouping
GROUP_SIZE = 15


def build_entry_html(headword: str, synonyms: list, entry_lookup: set) -> str:
    """Build HTML for one thesaurus entry."""
    parts = [f'<span class="dir">{DIR_LABEL}</span>',
             f'<span class="hw">{esc(headword)}</span>']
    parts.append(f'<span class="ct">{len(synonyms)} synonyms</span>')

    # Render synonyms as comma-separated list with links to entries that exist
    parts.append('<div class="sg"><span class="sl">')
    syn_parts = []
    for s in synonyms:
        if s.lower() in entry_lookup:
            syn_parts.append(f'<a href="entry://{esc(s)}">{esc(s)}</a>')
        else:
            syn_parts.append(esc(s))
    parts.append(', '.join(syn_parts))
    parts.append('</span></div>')

    return wrap_entry(''.join(parts), CSS)


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    data_file = DATA_DIR / "mthesaur.txt"
    if not data_file.exists():
        print(f"ERROR: {data_file} not found.")
        print("Download from: https://www.gutenberg.org/files/3202/files/mthesaur.txt")
        return

    print("Building Moby Thesaurus...")
    print(f"  Source: {data_file}")

    # ── Phase 1: Parse ──
    entries = {}
    with open(data_file, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split(',')
            if len(parts) < 2:
                continue
            headword = parts[0].strip()
            synonyms = [s.strip() for s in parts[1:] if s.strip()]
            if headword and synonyms:
                entries[headword] = synonyms

    print(f"  {len(entries)} headwords parsed")

    # Build lookup set for cross-linking
    entry_lookup = {hw.lower() for hw in entries}

    # ── Phase 2: Write MDict source ──
    txt_path = OUTPUT_DIR / "moby_thesaurus_entries.txt"
    print(f"  Writing → {txt_path}...")

    total_syns = 0
    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for headword in sorted(entries.keys(), key=str.lower):
            synonyms = entries[headword]
            total_syns += len(synonyms)
            html = build_entry_html(headword, synonyms, entry_lookup)
            f.write(f"{headword}\n{html}\n</>\n")
            count += 1

    print(f"  {count} entries, {total_syns} total synonym links")

    # ── Phase 3: Pack MDX ──
    mdx_path = OUTPUT_DIR / "Moby-Thesaurus-EN.mdx"
    success, size_mb, _ = pack_mdx(
        txt_path,
        "Moby Thesaurus II",
        "<p><b>Moby Thesaurus II</b></p>"
        "<p>The largest and most comprehensive thesaurus data source in English, "
        "with over 30,000 root words and 2.5 million synonyms.</p>"
        "<p>Compiled by Grady Ward. <b>Public Domain</b> — released January 2001.</p>"
        "<p>Source: <a href='https://www.gutenberg.org/ebooks/3202'>Project Gutenberg</a></p>",
        mdx_path,
    )
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="Moby Thesaurus II",
        description="English thesaurus with 2.5 million synonym links. Public domain, no restrictions.",
        direction={"src": "EN", "dest": ["EN"]},
        entries=count,
        license="Public Domain",
        data_source="Moby Thesaurus II (Grady Ward)",
        tier=3,
    )

    # ── Preview ──
    samples = ['happy', 'walk', 'big', 'beautiful', 'think', 'fast']
    entries_html = []
    for word in samples:
        if word in entries:
            html = build_entry_html(word, entries[word], entry_lookup)
            entries_html.append(html)

    preview_path = OUTPUT_DIR / "moby_thesaurus_preview.html"
    generate_preview(entries_html, preview_path, 'Moby Thesaurus II — preview')


if __name__ == '__main__':
    main()
