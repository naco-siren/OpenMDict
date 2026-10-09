#!/usr/bin/env python3
"""
Build German-English MDX dictionaries from FreeDict TEI P5 XML data.

Produces TWO separate unidirectional MDX files:
  - FreeDict-DE-EN.mdx  (German headwords → English definitions)
  - FreeDict-EN-DE.mdx  (English headwords → German definitions)

Usage:
    python build_freedict_mdx.py

Input:  ../data/freedict/deu-eng/deu-eng.tei
        ../data/freedict/eng-deu/eng-deu.tei
Output: ../output/FreeDict-DE-EN/FreeDict-DE-EN.mdx
        ../output/FreeDict-EN-DE/FreeDict-EN-DE.mdx
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import defaultdict

# ── Paths ──────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, GLOSS, ORDERED_LIST, DOMAIN_BADGE, TAG_BADGE, EXAMPLES_BILINGUAL
from shared.html import esc
from shared.build import pack_mdx, generate_preview, write_catalog_metadata

DATA_DIR = SCRIPT_DIR.parent / "data" / "freedict"
OUTPUT_BASE = SCRIPT_DIR.parent / "output"

DEU_ENG_FILE = DATA_DIR / "deu-eng" / "deu-eng.tei"
ENG_DEU_FILE = DATA_DIR / "eng-deu" / "eng-deu.tei"

NS = 'http://www.tei-c.org/ns/1.0'

FLAG_DE = '\U0001F1E9\U0001F1EA'  # 🇩🇪
FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸

DIR_DE_EN = f'{FLAG_DE} Deutsch \u2192 English {FLAG_EN}'
DIR_EN_DE = f'{FLAG_EN} English \u2192 Deutsch {FLAG_DE}'

# ── POS / Gender normalization ─────────────────────────────────

POS_MAP = {
    'n': 'n.', 'v': 'v.', 'adj': 'adj.', 'adv': 'adv.',
    'prep': 'prep.', 'conj': 'conj.', 'interj': 'interj.',
    'pron': 'pron.', 'art': 'art.', 'num': 'num.',
    'part': 'part.', 'abbr': 'abbr.',
}

GENDER_MAP = {
    'masc': 'm', 'fem': 'f', 'neut': 'nt',
}

SUBC_MAP = {
    'intr': 'intr.', 'trans': 'tr.', 'refl': 'refl.',
}

# ── HTML generation ────────────────────────────────────────────

CSS = get_css(GLOSS, ORDERED_LIST, DOMAIN_BADGE, TAG_BADGE, EXAMPLES_BILINGUAL)


# ── TEI XML parser ─────────────────────────────────────────────

def _text(elem, default=''):
    """Get text content of an element."""
    if elem is None:
        return default
    return (elem.text or '').strip()


def parse_tei_file(filepath: Path):
    """
    Parse FreeDict TEI P5 file using iterparse.

    Yields: (headword, pos, gender, subc, domains, translations, examples)
      translations: list of str
      examples: list of (source_text, [translated_text])
      domains: list of str
    """
    context = ET.iterparse(str(filepath), events=('end',))

    for event, elem in context:
        if elem.tag != f'{{{NS}}}entry':
            continue

        # Headword
        orth_elem = elem.find(f'{{{NS}}}form/{{{NS}}}orth')
        headword = _text(orth_elem)
        if not headword:
            elem.clear()
            continue

        # Grammar: POS, gender, subcategory
        gram = elem.find(f'{{{NS}}}gramGrp')
        pos_raw = _text(gram.find(f'{{{NS}}}pos')) if gram is not None else ''
        gen_raw = _text(gram.find(f'{{{NS}}}gen')) if gram is not None else ''
        subc_raw = _text(gram.find(f'{{{NS}}}subc')) if gram is not None else ''

        pos = POS_MAP.get(pos_raw, pos_raw)
        gender = GENDER_MAP.get(gen_raw, '')
        subc = SUBC_MAP.get(subc_raw, '')

        # Senses (there may be multiple <sense> elements)
        for sense_elem in elem.findall(f'{{{NS}}}sense'):
            # Domain/usage tags
            domains = []
            for usg in sense_elem.findall(f'{{{NS}}}usg'):
                usg_text = _text(usg)
                if usg_text:
                    domains.append(usg_text)

            # Translations
            translations = []
            for cit in sense_elem.findall(f'{{{NS}}}cit'):
                cit_type = cit.get('type', '')
                if cit_type == 'trans':
                    quote = cit.find(f'{{{NS}}}quote')
                    q_text = _text(quote)
                    if q_text:
                        translations.append(q_text)

            # Examples
            examples = []
            for cit in sense_elem.findall(f'{{{NS}}}cit'):
                cit_type = cit.get('type', '')
                if cit_type == 'example':
                    src_quote = cit.find(f'{{{NS}}}quote')
                    src_text = _text(src_quote)
                    # Translation(s) of the example
                    ex_translations = []
                    for sub_cit in cit.findall(f'{{{NS}}}cit'):
                        if sub_cit.get('type') == 'trans':
                            sub_quote = sub_cit.find(f'{{{NS}}}quote')
                            sub_text = _text(sub_quote)
                            if sub_text:
                                ex_translations.append(sub_text)
                    if src_text:
                        examples.append((src_text, ex_translations))

            if translations:
                yield headword, pos, gender, subc, domains, translations, examples

        elem.clear()


# ── Entry building ─────────────────────────────────────────────

def build_sense_card(pos: str, gender: str, subc: str,
                     domains: list, translations: list,
                     examples: list, is_first: bool) -> str:
    """Build HTML for a single sense card."""
    parts = []
    parts.append('<div class="sn">')

    # Header: POS + gender + subcategory + domains
    header_parts = []
    if is_first and pos:
        pos_label = pos
        if gender:
            pos_label += f' {gender}'
        if subc:
            pos_label += f' {subc}'
        header_parts.append(f'<span class="pos">{esc(pos_label)}</span>')
    for dm in domains:
        header_parts.append(f'<span class="dm">{esc(dm)}</span>')
    if header_parts:
        parts.append(f'<div class="sn-hd">{"".join(header_parts)}</div>')

    # Translations
    if len(translations) == 1:
        parts.append(f'<span class="gl">{esc(translations[0])}</span>')
    else:
        items = ''.join(f'<li>{esc(t)}</li>' for t in translations)
        parts.append(f'<ol class="d">{items}</ol>')

    # Examples (limit to 3 per sense)
    for src, trans_list in examples[:3]:
        parts.append('<div class="ex">')
        parts.append(f'<span class="ex-src">{esc(src)}</span>')
        for tr in trans_list[:1]:  # just first translation
            parts.append(f'<span class="ex-tr">{esc(tr)}</span>')
        parts.append('</div>')

    parts.append('</div>')
    return ''.join(parts)


def make_entry_html(headword: str, dir_label: str,
                    senses: list) -> str:
    """
    Build complete entry HTML.

    senses: list of (pos, gender, subc, domains, translations, examples)
    """
    inner = f'<span class="dir">{esc(dir_label)}</span>'
    inner += f'<span class="hw">{esc(headword)}</span>'

    for i, (pos, gender, subc, domains, translations, examples) in enumerate(senses):
        inner += build_sense_card(pos, gender, subc, domains,
                                  translations, examples, is_first=(i == 0))

    return f'{CSS}<div class="e">{inner}</div>'


def make_combined_html(headword: str, dir_label: str,
                       readings: list) -> str:
    """
    Build HTML for headword with multiple entry groups (same word, different senses).

    readings: list of list of senses
    """
    if len(readings) == 1:
        return make_entry_html(headword, dir_label, readings[0])

    sections = []
    for i, senses in enumerate(readings):
        section = ''
        if i == 0:
            section += f'<span class="dir">{esc(dir_label)}</span>'
        section += f'<span class="hw">{esc(headword)}</span>'
        for j, (pos, gender, subc, domains, translations, examples) in enumerate(senses):
            section += build_sense_card(pos, gender, subc, domains,
                                        translations, examples, is_first=(j == 0))
        sections.append(section)

    body = '<hr class="sep">'.join(sections)
    return f'{CSS}<div class="e">{body}</div>'


# ── Main build logic ──────────────────────────────────────────

SAMPLE_WORDS_DE = ['Wasser', 'Buch', 'Haus', 'Apfel', 'laufen', 'schön']
SAMPLE_WORDS_EN = ['water', 'book', 'house', 'apple', 'run', 'beautiful']


def main():
    print("="*60)
    print("Building FreeDict German↔English (split into 2 MDX files)")
    print("="*60)

    # ── Parse both directions ──
    de_entries = defaultdict(list)
    en_entries = defaultdict(list)

    def parse_direction(filepath, entries_dict):
        """Parse TEI file and group senses by headword."""
        sense_count = 0
        current_word = None
        current_senses = []

        for hw, pos, gender, subc, domains, trans, examples in parse_tei_file(filepath):
            sense = (pos, gender, subc, domains, trans, examples)

            if hw != current_word:
                if current_word and current_senses:
                    entries_dict[current_word].append(current_senses)
                current_word = hw
                current_senses = [sense]
            else:
                current_senses.append(sense)

            sense_count += 1

        if current_word and current_senses:
            entries_dict[current_word].append(current_senses)

        return sense_count

    print(f"\nParsing {DEU_ENG_FILE}...")
    de_sense_count = parse_direction(DEU_ENG_FILE, de_entries)
    print(f"  {len(de_entries)} unique headwords, {de_sense_count} senses")

    print(f"\nParsing {ENG_DEU_FILE}...")
    en_sense_count = parse_direction(ENG_DEU_FILE, en_entries)
    print(f"  {len(en_entries)} unique headwords, {en_sense_count} senses")

    # ── File 1: FreeDict-DE-EN.mdx (German → English) ──
    dir_1 = OUTPUT_BASE / "FreeDict-DE-EN"
    dir_1.mkdir(parents=True, exist_ok=True)
    txt_1 = dir_1 / "freedict_de_en_entries.txt"

    print(f"\n--- DE→EN direction ---")
    count_1 = 0
    with open(txt_1, 'w', encoding='utf-8') as f:
        for hw in sorted(de_entries.keys(), key=str.lower):
            readings = de_entries[hw]
            html = make_combined_html(hw, DIR_DE_EN, readings)
            f.write(f"{hw}\n{html}\n</>\n")
            count_1 += 1
    print(f"  {count_1} entries written")

    desc_1 = (
        "<p><b>FreeDict German-English</b></p>"
        "<p>German → English dictionary based on the Ding dictionary by Frank Richter (TU Chemnitz).</p>"
        "<p>Licensed under GPLv3 / AGPLv3.</p>"
        "<p>Source: <a href='https://freedict.org/'>freedict.org</a> / "
        "<a href='https://dict.tu-chemnitz.de/'>dict.tu-chemnitz.de</a></p>"
    )
    mdx_1 = dir_1 / "FreeDict-DE-EN.mdx"
    ok_1, size_1, _ = pack_mdx(txt_1, "FreeDict German-English", desc_1, mdx_1)
    if ok_1:
        print(f"  {mdx_1.name}: {size_1:.1f} MB ({count_1} entries)")
        write_catalog_metadata(
            mdx_path=mdx_1,
            display_name="FreeDict German-English",
            description="German-English dictionary with examples and domain labels from FreeDict / Ding.",
            direction={"src": "DE", "dest": ["EN"]},
            entries=count_1,
            license="GPL-3.0-or-later",
            data_source="FreeDict (deu-eng TEI P5)",
            tier=3,
        )

    # ── File 2: FreeDict-EN-DE.mdx (English → German) ──
    dir_2 = OUTPUT_BASE / "FreeDict-EN-DE"
    dir_2.mkdir(parents=True, exist_ok=True)
    txt_2 = dir_2 / "freedict_en_de_entries.txt"

    print(f"\n--- EN→DE direction ---")
    count_2 = 0
    with open(txt_2, 'w', encoding='utf-8') as f:
        for hw in sorted(en_entries.keys(), key=str.lower):
            readings = en_entries[hw]
            html = make_combined_html(hw, DIR_EN_DE, readings)
            f.write(f"{hw}\n{html}\n</>\n")
            count_2 += 1
    print(f"  {count_2} entries written")

    desc_2 = (
        "<p><b>FreeDict English-German</b></p>"
        "<p>English → German dictionary based on the Ding dictionary by Frank Richter (TU Chemnitz).</p>"
        "<p>Licensed under GPLv3 / AGPLv3.</p>"
        "<p>Source: <a href='https://freedict.org/'>freedict.org</a> / "
        "<a href='https://dict.tu-chemnitz.de/'>dict.tu-chemnitz.de</a></p>"
    )
    mdx_2 = dir_2 / "FreeDict-EN-DE.mdx"
    ok_2, size_2, _ = pack_mdx(txt_2, "FreeDict English-German", desc_2, mdx_2)
    if ok_2:
        print(f"  {mdx_2.name}: {size_2:.1f} MB ({count_2} entries)")
        write_catalog_metadata(
            mdx_path=mdx_2,
            display_name="FreeDict English-German",
            description="English-German dictionary with examples and domain labels from FreeDict / Ding.",
            direction={"src": "EN", "dest": ["DE"]},
            entries=count_2,
            license="GPL-3.0-or-later",
            data_source="FreeDict (eng-deu TEI P5)",
            tier=3,
        )

    # ── Generate previews ──
    _generate_previews(de_entries, en_entries)

    print("\nDone!")


# ── Preview ────────────────────────────────────────────────────

def _generate_previews(de_entries: dict, en_entries: dict):
    """Generate preview HTML for visual review."""
    entries_html = []

    # DE→EN samples
    for word in SAMPLE_WORDS_DE:
        if word in de_entries:
            readings = de_entries[word]
            html = make_combined_html(word, DIR_DE_EN, readings)
            entries_html.append(html)

    # EN→DE samples
    for word in SAMPLE_WORDS_EN:
        if word in en_entries:
            readings = en_entries[word]
            html = make_combined_html(word, DIR_EN_DE, readings)
            entries_html.append(html)

    preview_title = "FreeDict German-English \u2014 preview"

    preview_path_1 = OUTPUT_BASE / "FreeDict-DE-EN" / "freedict_de_preview.html"
    generate_preview(entries_html, preview_path_1, preview_title)

    preview_path_2 = OUTPUT_BASE / "FreeDict-EN-DE" / "freedict_en_de_preview.html"
    generate_preview(entries_html, preview_path_2, preview_title)


if __name__ == '__main__':
    main()
