#!/usr/bin/env python3
"""
Build KANJIDIC2 MDX dictionary from kanjidic2.xml.

Usage:
    python build_kanjidic2_mdx.py

Input:  ../data/kanjidic2/kanjidic2.xml
Output: ../output/KANJIDIC2-JA/KANJIDIC2-JA.mdx
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, CJK_READING_TAGS
from shared.html import esc, kana_to_romaji
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata
DATA_DIR = SCRIPT_DIR.parent / "data" / "kanjidic2"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "KANJIDIC2-JA"
KANJIDIC2_FILE = DATA_DIR / "kanjidic2.xml"

# ── HTML ───────────────────────────────────────────────────────

FLAG_JP = '\U0001F1EF\U0001F1F5'  # 🇯🇵
DIR_LABEL = f'{FLAG_JP} 漢字'

CSS = get_css(
    CJK_READING_TAGS,
    extra_light=(
        '.k{font-size:2.5em;font-weight:400;display:block;padding:8px 0}'
        '.info{font-size:0.85em;color:#8e8e93;display:block;margin-bottom:2px}'
        '.info b{color:#1d1d1f;font-weight:600}'
        '.rd{margin:6px 0;display:flex;flex-wrap:wrap;align-items:baseline;gap:2px}'
        '.rd-label{font-size:0.8em;color:#8e8e93;margin-right:4px;min-width:36px}'
        '.df{font-size:1.15em}'
    ),
    extra_dark=(
        '.info{color:#636366}.info b{color:#f5f5f7}'
    ),
)


# ── Grade labels ───────────────────────────────────────────────

GRADE_LABELS = {
    '1': 'G1', '2': 'G2', '3': 'G3', '4': 'G4', '5': 'G5', '6': 'G6',
    '8': 'Jōyō', '9': 'Jinmeiyō', '10': 'Jinmeiyō (variant)',
}

JLPT_LABELS = {
    '1': 'N1', '2': 'N2', '3': 'N3', '4': 'N4',
}


def _kun_to_romaji(kun: str) -> str:
    """Convert kun reading to romaji, preserving '.' and '-' markers."""
    import re
    # Split on markers, convert each kana segment, rejoin
    parts = re.split(r'([.\-])', kun)
    return ''.join(kana_to_romaji(p) if p not in ('.', '-') else p for p in parts)


# ── Parser ─────────────────────────────────────────────────────

def parse_kanjidic2(filepath: Path):
    """Parse kanjidic2.xml, yield character dicts."""
    context = ET.iterparse(str(filepath), events=('end',))

    for event, elem in context:
        if elem.tag != 'character':
            continue

        literal = elem.findtext('literal', '')
        if not literal:
            elem.clear()
            continue

        # Misc
        misc = elem.find('misc')
        grade = misc.findtext('grade', '') if misc is not None else ''
        stroke_count = misc.findtext('stroke_count', '') if misc is not None else ''
        freq = misc.findtext('freq', '') if misc is not None else ''
        jlpt = misc.findtext('jlpt', '') if misc is not None else ''

        # Radical
        rad_elem = elem.find('radical')
        radical = ''
        if rad_elem is not None:
            for rv in rad_elem.findall('rad_value'):
                if rv.get('rad_type') == 'classical':
                    radical = rv.text or ''
                    break

        # Readings and meanings
        rm_elem = elem.find('reading_meaning')
        on_readings = []
        kun_readings = []
        pinyin_readings = []
        korean_r = []
        korean_h = []
        vietnamese = []
        meanings_en = []
        nanori = []

        if rm_elem is not None:
            for rmg in rm_elem.findall('rmgroup'):
                for r in rmg.findall('reading'):
                    rt = r.get('r_type', '')
                    txt = (r.text or '').strip()
                    if not txt:
                        continue
                    if rt == 'ja_on':
                        on_readings.append(txt)
                    elif rt == 'ja_kun':
                        kun_readings.append(txt)
                    elif rt == 'pinyin':
                        pinyin_readings.append(txt)
                    elif rt == 'korean_r':
                        korean_r.append(txt)
                    elif rt == 'korean_h':
                        korean_h.append(txt)
                    elif rt == 'vietnam':
                        vietnamese.append(txt)

                for m in rmg.findall('meaning'):
                    lang = m.get('m_lang', '')
                    if not lang:  # English (default)
                        meanings_en.append((m.text or '').strip())

            for n in rm_elem.findall('nanori'):
                if n.text:
                    nanori.append(n.text.strip())

        # Skip characters with no readings and no meanings
        if not meanings_en and not on_readings and not kun_readings:
            elem.clear()
            continue

        yield {
            'literal': literal,
            'grade': grade,
            'stroke_count': stroke_count,
            'freq': freq,
            'jlpt': jlpt,
            'radical': radical,
            'on': on_readings,
            'kun': kun_readings,
            'pinyin': pinyin_readings,
            'korean_r': korean_r,
            'korean_h': korean_h,
            'vietnamese': vietnamese,
            'meanings': meanings_en,
            'nanori': nanori,
        }

        elem.clear()


# ── HTML generation ────────────────────────────────────────────

def make_html(ch: dict) -> str:
    """Generate HTML for a single kanji entry."""
    parts = [f'<span class="dir">{DIR_LABEL}</span>']
    parts.append(f'<span class="k">{esc(ch["literal"])}</span>')

    # Info line 1: grade, JLPT, freq  (e.g. "G1 · N4 · #1")
    line1_items = []
    if ch['grade']:
        label = GRADE_LABELS.get(ch['grade'], f'G{ch["grade"]}')
        line1_items.append(label)
    if ch['jlpt']:
        label = JLPT_LABELS.get(ch['jlpt'], f'JLPT {ch["jlpt"]}')
        line1_items.append(label)
    if ch['freq']:
        line1_items.append(f'#{ch["freq"]}')
    if line1_items:
        parts.append(f'<span class="info">{" · ".join(line1_items)}</span>')

    # Info line 2: strokes, radical  (e.g. "4 strokes · radical 72")
    line2_items = []
    if ch['stroke_count']:
        line2_items.append(f'{ch["stroke_count"]} strokes')
    if ch['radical']:
        line2_items.append(f'radical {ch["radical"]}')
    if line2_items:
        parts.append(f'<span class="info">{" · ".join(line2_items)}</span>')

    # ON readings (katakana + romaji)
    if ch['on']:
        tags = ''.join(
            f'<span class="tag tag-on">{esc(r)} {esc(kana_to_romaji(r))}</span>'
            for r in ch['on']
        )
        parts.append(f'<div class="rd"><span class="rd-label">音</span>{tags}</div>')

    # KUN readings (hiragana + romaji; preserve '.' and '-' markers)
    if ch['kun']:
        tags = ''.join(
            f'<span class="tag tag-kun">{esc(r)} {esc(_kun_to_romaji(r))}</span>'
            for r in ch['kun']
        )
        parts.append(f'<div class="rd"><span class="rd-label">訓</span>{tags}</div>')

    # Pinyin
    if ch['pinyin']:
        tags = ''.join(f'<span class="tag tag-py">{esc(r)}</span>' for r in ch['pinyin'])
        parts.append(f'<div class="rd"><span class="rd-label">拼音</span>{tags}</div>')

    # Korean (pair hangul + romanization)
    if ch['korean_h']:
        tags_list = []
        for i, h in enumerate(ch['korean_h']):
            rom = ch['korean_r'][i] if i < len(ch['korean_r']) else ''
            label = f'{h} {rom}' if rom else h
            tags_list.append(f'<span class="tag tag-ko">{esc(label)}</span>')
        parts.append(f'<div class="rd"><span class="rd-label">한국</span>{"".join(tags_list)}</div>')
    elif ch['korean_r']:
        tags = ''.join(f'<span class="tag tag-ko">{esc(r)}</span>' for r in ch['korean_r'])
        parts.append(f'<div class="rd"><span class="rd-label">한국</span>{tags}</div>')

    # Vietnamese
    if ch['vietnamese']:
        tags = ''.join(f'<span class="tag tag-vi">{esc(r)}</span>' for r in ch['vietnamese'])
        parts.append(f'<div class="rd"><span class="rd-label">Việt</span>{tags}</div>')

    # Meanings
    if ch['meanings']:
        meanings_html = '; '.join(esc(m) for m in ch['meanings'])
        parts.append(f'<div class="sn"><span class="df">{meanings_html}</span></div>')

    # Nanori
    if ch['nanori']:
        nanori_html = ', '.join(esc(n) for n in ch['nanori'])
        parts.append(f'<div class="rd"><span class="rd-label">名</span>'
                     f'<span style="font-size:0.95em;color:#6e6e73">{nanori_html}</span></div>')

    return f'{CSS}<div class="e">{"".join(parts)}</div>'


# ── Preview ────────────────────────────────────────────────────

SAMPLE_WORDS = ['日', '本', '人', '大', '山', '水', '火', '金']


def _generate_preview(entries: dict):
    entries_html = []
    for hw in SAMPLE_WORDS:
        if hw in entries:
            entries_html.append(make_html(entries[hw]))
    preview_path = OUTPUT_DIR / "kanjidic2_preview.html"
    _shared_preview(entries_html, preview_path, 'KANJIDIC2 — preview')


# ── Main ───────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Parsing KANJIDIC2...")

    entries = {}  # literal → char dict
    for ch in parse_kanjidic2(KANJIDIC2_FILE):
        entries[ch['literal']] = ch

    print(f"  {len(entries)} kanji parsed")

    # Write MDict source
    txt_path = OUTPUT_DIR / "kanjidic2_entries.txt"
    print(f"Writing → {txt_path}...")

    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for hw in sorted(entries.keys()):
            html = make_html(entries[hw])
            f.write(f"{hw}\n{html}\n</>\n")
            count += 1

    print(f"  {count} entries written")

    # Pack MDX
    mdx_path = OUTPUT_DIR / "KANJIDIC2-JA.mdx"
    desc_html = (
        "<p><b>KANJIDIC2 — Kanji Dictionary</b></p>"
        "<p>Comprehensive kanji dictionary with readings, meanings, stroke counts, "
        "radical information, and JLPT/school grade levels.</p>"
        "<p>By the Electronic Dictionary Research and Development Group (EDRDG).</p>"
        "<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/4.0/'>CC BY-SA 4.0</a>.</p>"
        "<p>Source: <a href='https://www.edrdg.org/wiki/index.php/KANJIDIC_Project'>edrdg.org</a></p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "KANJIDIC2 — Kanji Dictionary", desc_html, mdx_path)
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="KANJIDIC2 漢字",
        description="Comprehensive kanji dictionary with stroke counts, radicals, readings (on/kun/pinyin/Korean), meanings, and JLPT/grade levels.",
        direction={"src": "JA", "dest": ["EN"]},
        entries=count,
        license="CC BY-SA 4.0",
        data_source="KANJIDIC2 (EDRDG)",
        tier=2,
    )

    _generate_preview(entries)


if __name__ == '__main__':
    main()
