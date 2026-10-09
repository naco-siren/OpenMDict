#!/usr/bin/env python3
"""
Build JMdict (Japanese-English) MDX dictionary.

Features:
  - Romaji for English-speaking users
  - Pitch accent from Kanjium (CC-BY-SA 4.0)
  - Dark mode support

Usage:
    python build_jmdict_mdx.py

Input:  ../data/JMdict_e, ../data/kanjium_accents.txt
Output: ../output/JMdict-JA-EN/JMdict-JA-EN.mdx
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import defaultdict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, GLOSS, ORDERED_LIST, DOMAIN_BADGE
from shared.html import (esc, kana_to_romaji, kana_to_romaji_morae,
                         split_morae, _KATA_TO_HIRA, _ROMAJI_MAP,
                         _ROMAJI_DIGRAPH)
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "JMdict-JA-EN"
JMDICT_FILE = DATA_DIR / "JMdict_e"
KANJIUM_FILE = DATA_DIR / "kanjium_accents.txt"

# ── Pitch accent ─────────────────────────────────────────────

def load_kanjium(filepath: Path) -> dict[tuple[str, str], list[int]]:
    """Load Kanjium accent data. Returns {(kanji, reading): [accent_positions]}."""
    accents = {}
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line:
                continue
            parts = line.split('\t')
            if len(parts) < 3:
                continue
            kanji, reading, accent_str = parts[0], parts[1], parts[2]
            positions = []
            for p in accent_str.split(','):
                p = p.strip()
                if p.isdigit():
                    positions.append(int(p))
            accents[(kanji, reading)] = positions
    return accents



CIRCLED_NUMS = '⓪①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳'


def _compute_pitch(n: int, accent_pos: int) -> list[bool]:
    """Compute high/low for each mora. True = high."""
    pitch = []
    for i in range(n):
        if accent_pos == 0:
            pitch.append(i > 0)       # heiban: L H H H ...
        elif accent_pos == 1:
            pitch.append(i == 0)      # atamadaka: H L L L ...
        else:
            pitch.append(1 <= i < accent_pos)  # nakadaka/odaka
    return pitch


def _render_contour(segments: list[str], pitch: list[bool]) -> str:
    """Render a list of text segments with pitch contour spans.

    Groups consecutive same-pitch segments. High gets overline,
    drop point gets right border.
    """
    n = len(segments)
    parts = []
    i = 0
    while i < n:
        is_high = pitch[i]
        j = i + 1
        while j < n and pitch[j] == is_high:
            j += 1
        group_text = ''.join(segments[i:j])
        if is_high:
            cls = 'phd' if (j < n and not pitch[j]) else 'ph'
        else:
            cls = 'pl'
        parts.append(f'<span class="{cls}">{esc(group_text)}</span>')
        i = j
    return ''.join(parts)


def render_pitch_kana(kana: str, accent_pos: int) -> str:
    """Render kana with pitch accent contour lines + circled number."""
    morae = split_morae(kana)
    n = len(morae)
    if n == 0:
        return esc(kana)
    pitch = _compute_pitch(n, accent_pos)
    num = CIRCLED_NUMS[accent_pos] if accent_pos < len(CIRCLED_NUMS) else str(accent_pos)
    return f'<span class="an">{num}</span>{_render_contour(morae, pitch)}'


def render_pitch_romaji(kana: str, accent_pos: int) -> str:
    """Render romaji with pitch accent contour lines."""
    morae = split_morae(kana)
    n = len(morae)
    if n == 0:
        return ''
    romaji_segs = kana_to_romaji_morae(kana)
    # Align: romaji_segs should be same length as morae
    if len(romaji_segs) != n:
        # Fallback: just return plain romaji
        return esc(''.join(romaji_segs))
    pitch = _compute_pitch(n, accent_pos)
    return _render_contour(romaji_segs, pitch)


# ── Entity resolution ─────────────────────────────────────────

def extract_entities(filepath: Path) -> dict[str, str]:
    """Extract <!ENTITY name "value"> definitions from the DTD."""
    entities = {}
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            if line.strip().startswith('<!ENTITY'):
                m = re.match(r'<!ENTITY\s+(\S+)\s+"([^"]+)">', line.strip())
                if m:
                    entities[m.group(1)] = m.group(2)
            if line.strip() == ']>':
                break
    return entities


def resolve_entities(xml_str: str, entities: dict[str, str]) -> str:
    """Replace &entity; references with their values."""
    def replacer(m):
        name = m.group(1)
        return entities.get(name, name)
    return re.sub(r'&([\w-]+);', replacer, xml_str)


# ── JMdict parser ────────────────────────────────────────────

class JMdictEntry:
    def __init__(self):
        self.ent_seq = ''
        self.kanji_forms: list[str] = []
        self.readings: list[str] = []
        self.senses: list[dict] = []


def parse_jmdict(filepath: Path) -> list[JMdictEntry]:
    """Parse JMdict XML, resolving entities first."""
    print("  Reading file...")
    entities = extract_entities(filepath)

    with open(filepath, 'r', encoding='utf-8') as f:
        raw = f.read()

    dtd_end = raw.find(']>')
    if dtd_end != -1:
        xml_body = '<?xml version="1.0" encoding="UTF-8"?>\n' + raw[dtd_end + 2:]
    else:
        xml_body = raw

    print("  Resolving entities...")
    xml_body = resolve_entities(xml_body, entities)

    print("  Parsing XML...")
    root = ET.fromstring(xml_body)

    entries = []
    for entry_el in root.findall('entry'):
        e = JMdictEntry()
        e.ent_seq = entry_el.findtext('ent_seq', '')

        for k_ele in entry_el.findall('k_ele'):
            keb = k_ele.findtext('keb', '')
            if keb:
                e.kanji_forms.append(keb)

        for r_ele in entry_el.findall('r_ele'):
            reb = r_ele.findtext('reb', '')
            if reb:
                e.readings.append(reb)

        for sense_el in entry_el.findall('sense'):
            sense = {'pos': [], 'glosses': [], 'misc': [], 'field': [],
                     'xref': [], 'ant': []}
            for pos_el in sense_el.findall('pos'):
                if pos_el.text:
                    sense['pos'].append(pos_el.text)
            for gloss_el in sense_el.findall('gloss'):
                if gloss_el.text:
                    sense['glosses'].append(gloss_el.text)
            for misc_el in sense_el.findall('misc'):
                if misc_el.text:
                    sense['misc'].append(misc_el.text)
            for field_el in sense_el.findall('field'):
                if field_el.text:
                    sense['field'].append(field_el.text)
            for xref_el in sense_el.findall('xref'):
                if xref_el.text:
                    sense['xref'].append(xref_el.text)
            for ant_el in sense_el.findall('ant'):
                if ant_el.text:
                    sense['ant'].append(ant_el.text)
            if sense['glosses']:
                e.senses.append(sense)

        if e.senses:
            entries.append(e)

    return entries


# ── POS abbreviation ─────────────────────────────────────────

POS_SHORT = {
    'noun (common) (futsuumeishi)': 'n.',
    'Ichidan verb': 'v1',
    'Godan verb with \'ru\' ending': 'v5r',
    'Godan verb with \'u\' ending': 'v5u',
    'Godan verb with \'tsu\' ending': 'v5t',
    'Godan verb with \'su\' ending': 'v5s',
    'Godan verb with \'ku\' ending': 'v5k',
    'Godan verb with \'gu\' ending': 'v5g',
    'Godan verb with \'bu\' ending': 'v5b',
    'Godan verb with \'mu\' ending': 'v5m',
    'Godan verb with \'nu\' ending': 'v5n',
    'transitive verb': 'vt',
    'intransitive verb': 'vi',
    'noun or participle which takes the aux. verb suru': 'vs',
    'adjective (keiyoushi)': 'adj-i',
    "adjective (keiyoushi) - yoi/ii class": 'adj-ix',
    'adjectival nouns or quasi-adjectives (keiyodoshi)': 'adj-na',
    'adverb (fukushi)': 'adv.',
    "adverb taking the 'to' particle": 'adv-to',
    'expressions (phrases, clauses, etc.)': 'expr.',
    'pre-noun adjectival (rentaishi)': 'adj-pn',
    'conjunction': 'conj.',
    'interjection (kandoushi)': 'interj.',
    'counter': 'ctr.',
    'suffix': 'suf.',
    'prefix': 'pref.',
    'pronoun': 'pron.',
    'auxiliary verb': 'aux-v',
    'auxiliary adjective': 'aux-adj',
    'copula': 'cop.',
    'particle': 'prt.',
    'numeric': 'num.',
    "noun or verb acting prenominally": 'adj-f',
    "nouns which may take the genitive case particle 'no'": 'adj-no',
    "'taru' adjective": 'adj-t',
    'Ichidan verb - kureru special class': 'v1-s',
    "Godan verb with 'aru' ending (special class)": 'v5aru',
    'suru verb - included': 'vs-i',
    'suru verb - special class': 'vs-s',
    'Kuru verb - special class': 'vk',
    'unclassified': '',
}


def shorten_pos(pos_text: str) -> str:
    return POS_SHORT.get(pos_text, pos_text)


# ── HTML generation ──────────────────────────────────────────

FLAG_JP = '\U0001F1EF\U0001F1F5'  # 🇯🇵
FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_JP} 日本語 → English {FLAG_EN}'

CSS = get_css(
    GLOSS, ORDERED_LIST, DOMAIN_BADGE,
    extra_light=(
        '.k{font-size:1.7em;font-weight:600;display:block}'
        '.r{font-size:1.25em;color:#6e6e73;display:block;margin-top:2px}'
        '.rm{font-size:1.15em;color:#0071e3;font-style:italic;display:block;margin-top:2px}'
        '.an{font-size:1.0em;color:#aeaeb2;margin-right:2px;font-style:normal}'
        '.ph{display:inline;border-top:2px solid #ff3b30;padding-top:1px}'
        '.phd{display:inline;border-top:2px solid #ff3b30;border-right:2px solid #ff3b30;padding-top:1px;padding-right:1px}'
        '.pl{display:inline;padding-top:3px}'
        '.xr{font-size:0.85em;color:#8e8e93;margin:4px 0 0}'
        '.xr a{color:#8e8e93;text-decoration:underline}'
        '.at{font-size:0.85em;color:#ff3b30;margin:2px 0 0}'
        '.at a{color:#ff3b30;text-decoration:underline}'
    ),
    extra_dark=(
        '.r{color:#98989d}.rm{color:#64d2ff}'
        '.an{color:#636366}'
        '.xr{color:#636366}.xr a{color:#636366}'
        '.at{color:#ff453a}.at a{color:#ff453a}'
        '.ph,.phd{border-color:#ff453a}'
    ),
)


def _parse_xref(xref_text: str) -> str:
    """Extract the headword from a JMdict xref string.

    JMdict xref format: 'word' or 'word/reading' or 'word/reading/sense'.
    We only need the first part (the headword) for entry:// linking.
    """
    return xref_text.split('/')[0].split('・')[0].strip()


def make_entry_html(entry: JMdictEntry, accents: dict,
                    entry_words: set = None) -> str:
    """Generate HTML for a single JMdict entry (one reading section)."""
    kanji = entry.kanji_forms[0] if entry.kanji_forms else ''
    reading = entry.readings[0] if entry.readings else ''

    # Look up pitch accent
    accent_data = None
    if kanji and reading:
        accent_data = accents.get((kanji, reading))
    elif reading:
        accent_data = accents.get(('', reading)) or accents.get((reading, reading))

    # Build headword block (vertical layout: kanji / kana / romaji each on own line)
    if accent_data:
        acc = accent_data[0]
        kana_html = render_pitch_kana(reading, acc)
        romaji_html = render_pitch_romaji(reading, acc)
        # Add accent number to romaji too
        num = CIRCLED_NUMS[acc] if acc < len(CIRCLED_NUMS) else str(acc)
        romaji_html = f'<span class="an">{num}</span>{romaji_html}'
    else:
        kana_html = esc(reading)
        romaji_html = esc(kana_to_romaji(reading))

    if kanji:
        hw = (f'<span class="k">{esc(kanji)}</span>'
              f'<span class="r">{kana_html}</span>'
              f'<span class="rm">{romaji_html}</span>')
    else:
        hw = (f'<span class="k">{kana_html}</span>'
              f'<span class="rm">{romaji_html}</span>')

    # Senses: each sense = one card
    senses_html = []
    last_pos = None
    for sense in entry.senses:
        pos_tags = [shorten_pos(p) for p in sense['pos']] if sense['pos'] else None

        # Update current POS (JMdict inherits POS from previous sense if omitted)
        if pos_tags is not None:
            last_pos = pos_tags

        # Build header with POS badges + field/domain badges
        header_parts = []
        if last_pos:
            for p in last_pos:
                if p:
                    header_parts.append(f'<span class="pos">{esc(p)}</span>')
        for fld in sense.get('field', []):
            if fld:
                header_parts.append(f'<span class="dm">{esc(fld)}</span>')

        card = '<div class="sn">'
        if header_parts:
            card += f'<div class="sn-hd">{"".join(header_parts)}</div>'

        glosses = sense['glosses']
        if len(glosses) == 1:
            card += f'<span class="gl">{esc(glosses[0])}</span>'
        else:
            items = ''.join(f'<li>{esc(g)}</li>' for g in glosses)
            card += f'<ol class="d">{items}</ol>'

        # Cross-references (see also)
        xrefs = sense.get('xref', [])
        if xrefs:
            xr_items = []
            for xr in xrefs[:4]:
                hw = _parse_xref(xr)
                if hw and entry_words and hw in entry_words:
                    xr_items.append(f'<a href="entry://{esc(hw)}">{esc(hw)}</a>')
                elif hw:
                    xr_items.append(esc(hw))
            if xr_items:
                card += f'<div class="xr">\u2192 {", ".join(xr_items)}</div>'

        # Antonyms
        ants = sense.get('ant', [])
        if ants:
            ant_items = []
            for a in ants[:4]:
                hw = _parse_xref(a)
                if hw and entry_words and hw in entry_words:
                    ant_items.append(f'<a href="entry://{esc(hw)}">{esc(hw)}</a>')
                elif hw:
                    ant_items.append(esc(hw))
            if ant_items:
                card += f'<div class="at">\u2194 {", ".join(ant_items)}</div>'

        card += '</div>'
        senses_html.append(card)

    return f'<div class="h">{hw}</div>{"".join(senses_html)}'


# ── Preview ───────────────────────────────────────────────────

SAMPLE_WORDS = ['食べる', '美しい', '猫', '水', '走る', '日本']


def _generate_preview(headword_sections: dict):
    """Generate a preview HTML for visual review."""
    entries_html = []
    dir_html = f'<span class="dir">{DIR_LABEL}</span>'
    for hw in SAMPLE_WORDS:
        if hw in headword_sections:
            sections = headword_sections[hw]
            if len(sections) == 1:
                body = sections[0]
            else:
                body = '<hr class="sep">'.join(sections)
            entries_html.append(f'{CSS}<div class="e">{dir_html}{body}</div>')

    preview_path = OUTPUT_DIR / "jmdict_preview.html"
    _shared_preview(entries_html, preview_path, 'JMdict — preview')


# ── Main ──────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Load pitch accent data
    print("Loading Kanjium pitch accent data...")
    accents = load_kanjium(KANJIUM_FILE)
    print(f"  {len(accents)} accent entries loaded")

    print("Parsing JMdict...")
    entries = parse_jmdict(JMDICT_FILE)
    print(f"  {len(entries)} entries parsed")

    # Group entries by primary headword
    # Primary: first kanji form, or first reading if no kanji
    headword_sections = defaultdict(list)  # headword → [html_section, ...]
    redirects = {}

    # Build headword lookup set for entry:// linking
    # First pass: collect all primary headwords
    entry_words = set()
    for entry in entries:
        primary = entry.kanji_forms[0] if entry.kanji_forms else entry.readings[0]
        entry_words.add(primary)
    print(f"  {len(entry_words)} unique primary headwords for cross-linking")

    for entry in entries:
        primary = entry.kanji_forms[0] if entry.kanji_forms else entry.readings[0]
        section_html = make_entry_html(entry, accents, entry_words)
        headword_sections[primary].append(section_html)

        # Redirects for alternate kanji forms
        for kf in entry.kanji_forms[1:]:
            if kf != primary and kf not in headword_sections:
                redirects[kf] = primary

        # Redirects for readings (only if kanji form exists)
        if entry.kanji_forms:
            for rd in entry.readings:
                if rd != primary and rd not in headword_sections:
                    redirects[rd] = primary

    # Clean up: remove redirects that conflict with real headwords
    for alt in list(redirects.keys()):
        if alt in headword_sections:
            del redirects[alt]

    print(f"  {len(headword_sections)} primary headwords, {len(redirects)} redirects")

    # Write mdict source
    txt_path = OUTPUT_DIR / "jmdict_entries.txt"
    print(f"Writing → {txt_path}...")

    count = 0
    dir_html = f'<span class="dir">{DIR_LABEL}</span>'
    with open(txt_path, 'w', encoding='utf-8') as f:
        for hw in sorted(headword_sections.keys()):
            sections = headword_sections[hw]
            if len(sections) == 1:
                body = sections[0]
            else:
                body = '<hr class="sep">'.join(sections)
            # Direction label as top bar, single CSS + single wrapper div
            html = f'{CSS}<div class="e">{dir_html}{body}</div>'
            f.write(f"{hw}\n{html}\n</>\n")
            count += 1

        for alt in sorted(redirects.keys()):
            f.write(f"{alt}\n@@@LINK={redirects[alt]}\n</>\n")
            count += 1

    print(f"  {count} total entries written")

    # Pack MDX
    mdx_path = OUTPUT_DIR / "JMdict-JA-EN.mdx"
    desc_html = (
        "<p><b>JMdict Japanese-English Dictionary</b></p>"
        "<p>The JMdict project by the Electronic Dictionary Research and Development Group (EDRDG), "
        "originally created by Jim Breen.</p>"
        "<p>Pitch accent data from Kanjium by Uros O.</p>"
        "<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/4.0/'>CC-BY-SA 4.0</a>.</p>"
        "<p>Sources: <a href='https://www.edrdg.org/jmdict/j_jmdict.html'>edrdg.org</a>, "
        "<a href='https://github.com/mifunetoshiro/kanjium'>Kanjium</a></p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "JMdict Japanese-English", desc_html, mdx_path)
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="JMdict Japanese-English",
        description="Authoritative Japanese-English dictionary with readings, pitch accent, part-of-speech, and detailed definitions from EDRDG.",
        direction={"src": "JA", "dest": ["EN"]},
        entries=count,
        license="CC-BY-SA 4.0",
        data_source="JMdict + Kanjium pitch accent",
        tier=2,
    )

    # Generate preview
    _generate_preview(headword_sections)


if __name__ == '__main__':
    main()
