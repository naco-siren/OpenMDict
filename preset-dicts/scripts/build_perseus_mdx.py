#!/usr/bin/env python3
"""
Build LSJ (Greek-English) and Lewis & Short (Latin-English) MDX dictionaries
from Perseus Digital Library TEI P4 XML.

Usage:
    python build_perseus_mdx.py

Input:  ../data/perseus/lsj.xml, ../data/perseus/lewis-short.xml
Output: ../output/LSJ-GRC-EN/LSJ-GRC-EN.mdx
        ../output/Lewis-Short-LA-EN/Lewis-Short-LA-EN.mdx
"""

import re
import sys
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import defaultdict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, INFLECTION, DEFINITION, SENSE_NUMBER, EXAMPLES, GREEK_TEXT, CROSSREF, NESTED_SENSES
from shared.html import esc
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

DATA_DIR = SCRIPT_DIR.parent / "data" / "perseus"
OUTPUT_BASE = SCRIPT_DIR.parent / "output"

# ── Politically-correct flag constants ────────────────────────
FLAG_EN = '🇬🇧🇺🇸'
FLAG_GRC = '🇬🇷'
FLAG_LA = '🏛️'

# ── Beta Code → Unicode Greek ─────────────────────────────────

# Basic letter mapping (lowercase beta → lowercase Greek)
_BETA_LOWER = {
    'a': 'α', 'b': 'β', 'g': 'γ', 'd': 'δ', 'e': 'ε', 'z': 'ζ',
    'h': 'η', 'q': 'θ', 'i': 'ι', 'k': 'κ', 'l': 'λ', 'm': 'μ',
    'n': 'ν', 'c': 'ξ', 'o': 'ο', 'p': 'π', 'r': 'ρ', 's': 'σ',
    't': 'τ', 'u': 'υ', 'f': 'φ', 'x': 'χ', 'y': 'ψ', 'w': 'ω',
}
_BETA_UPPER = {k: v.upper() for k, v in _BETA_LOWER.items()}

# Unicode combining diacritics for Greek
_SMOOTH = '\u0313'    # ̓  (psili / smooth breathing)
_ROUGH = '\u0314'     # ̔  (dasia / rough breathing)
_ACUTE = '\u0301'     # ́  (oxia / acute)
_GRAVE = '\u0300'     # ̀  (varia / grave)
_CIRCUMFLEX = '\u0342'  # ͂  (perispomeni / circumflex)
_DIAERESIS = '\u0308'   # ̈
_IOTA_SUB = '\u0345'    # ͅ  (ypogegrammeni / iota subscript)

_DIACRITICS = {
    ')': _SMOOTH,
    '(': _ROUGH,
    '/': _ACUTE,
    '\\': _GRAVE,
    '=': _CIRCUMFLEX,
    '+': _DIAERESIS,
    '|': _IOTA_SUB,
}


def _is_beta_code(text: str) -> bool:
    """Heuristic: does this text look like beta code (Latin letters that
    map to Greek, with diacritics)?"""
    if not text:
        return False
    # If text already contains Greek Unicode, it's not beta code
    for ch in text:
        if '\u0370' <= ch <= '\u03FF' or '\u1F00' <= ch <= '\u1FFF':
            return False
    # Check if it contains beta code letter patterns
    beta_letters = sum(1 for ch in text.lower() if ch in _BETA_LOWER)
    return beta_letters >= 1 and beta_letters / max(len(text), 1) > 0.3


def beta_to_unicode(beta: str) -> str:
    """Convert Perseus beta code to Unicode polytonic Greek."""
    result = []
    i = 0
    n = len(beta)
    is_upper = False

    while i < n:
        ch = beta[i]

        # Uppercase marker
        if ch == '*':
            is_upper = True
            i += 1
            continue

        # Check if it's a Greek letter
        lower_ch = ch.lower()
        if lower_ch in _BETA_LOWER:
            if is_upper:
                greek_letter = _BETA_UPPER.get(lower_ch, ch)
                is_upper = False
            else:
                greek_letter = _BETA_LOWER.get(lower_ch, ch)

            # Collect diacritics that follow
            diacritics = []
            j = i + 1
            while j < n and beta[j] in _DIACRITICS:
                diacritics.append(_DIACRITICS[beta[j]])
                j += 1

            # Handle final sigma: σ → ς at end of word
            if greek_letter == 'σ' and (j >= n or not beta[j].isalpha() or beta[j] == '*'):
                greek_letter = 'ς'

            # Build the character with diacritics
            combined = greek_letter + ''.join(diacritics)
            # Normalize to NFC for proper display
            combined = unicodedata.normalize('NFC', combined)
            result.append(combined)
            i = j
        elif ch in _DIACRITICS:
            # Diacritic at start (before letter in uppercase sequences like *(a)
            # Collect diacritics, then look for letter
            diacritics = []
            j = i
            while j < n and beta[j] in _DIACRITICS:
                diacritics.append(_DIACRITICS[beta[j]])
                j += 1
            if j < n and beta[j].lower() in _BETA_LOWER:
                lower_ch = beta[j].lower()
                if is_upper:
                    greek_letter = _BETA_UPPER.get(lower_ch, beta[j])
                    is_upper = False
                else:
                    greek_letter = _BETA_LOWER.get(lower_ch, beta[j])
                j += 1
                # More diacritics may follow
                while j < n and beta[j] in _DIACRITICS:
                    diacritics.append(_DIACRITICS[beta[j]])
                    j += 1
                if greek_letter == 'σ' and (j >= n or not beta[j].isalpha() or beta[j] == '*'):
                    greek_letter = 'ς'
                combined = greek_letter + ''.join(diacritics)
                combined = unicodedata.normalize('NFC', combined)
                result.append(combined)
                i = j
            else:
                # Stray diacritic — skip
                i = j if j > i else i + 1
        else:
            # Non-Greek character — pass through (numbers, punctuation, spaces)
            result.append(ch)
            i += 1

    return ''.join(result)


# ── HTML ───────────────────────────────────────────────────────

CSS = get_css(
    INFLECTION, DEFINITION, SENSE_NUMBER,
    EXAMPLES, GREEK_TEXT, CROSSREF, NESTED_SENSES,
)


# ── TEI XML parser (smart text extraction) ────────────────────

def elem_text_content(elem, convert_greek: bool = False) -> str:
    """Recursively extract all text from an element and its children.

    When convert_greek=True, text inside <foreign lang="greek"> is
    converted from beta code to Unicode Greek.
    """
    parts = []
    if elem.text:
        parts.append(elem.text)
    for child in elem:
        if convert_greek and child.tag == 'foreign':
            lang = child.get('lang', '')
            raw = elem_text_content(child, convert_greek=False)
            if lang == 'greek' and raw.strip():
                converted = beta_to_unicode(raw.strip())
                parts.append(converted)
            else:
                parts.append(raw)
        else:
            parts.append(elem_text_content(child, convert_greek=convert_greek))
        if child.tail:
            parts.append(child.tail)
    return ''.join(parts)


def elem_to_html(elem, is_latin_dict: bool = False, is_greek_dict: bool = False) -> str:
    """Convert an element tree to HTML with proper Greek conversion and
    inline citations.  Produces richer output than plain-text extraction.

    - <foreign lang="greek"> → beta code converted to Unicode, wrapped in
      <span class="grk"> (NO italic — Greek script is visually distinct).
    - <hi rend="ital"> → rendered as normal text (the print edition used
      italic for translations/Latin words, but our digital format uses
      structural cues like bold and sense cards instead).
    - <cit>/<quote> → quotation marks, normal weight (cited examples).
    - <tr> → bold (translation keywords).
    """
    convert_greek = is_latin_dict or is_greek_dict
    parts = []
    if elem.text:
        parts.append(esc(elem.text))
    for child in elem:
        tag = child.tag
        if tag == 'sense':
            # Skip nested senses — they are iterated separately
            pass
        elif tag == 'tr':
            content = elem_text_content(child, convert_greek=convert_greek).strip()
            if content:
                parts.append(f'<b>{esc(content)}</b>')
        elif tag == 'foreign':
            lang = child.get('lang', '')
            raw = elem_text_content(child, convert_greek=False).strip()
            if lang == 'greek' and raw:
                converted = beta_to_unicode(raw)
                parts.append(f'<span class="grk">{esc(converted)}</span>')
            elif raw:
                parts.append(f'<i>{esc(raw)}</i>')
        elif tag == 'cit':
            # Inline the citation: "quote" (Author)
            quote_elem = child.find('quote')
            if quote_elem is not None:
                q_text = elem_text_content(quote_elem, convert_greek=convert_greek).strip()
                # For Greek dict, also convert any remaining beta code in quotes
                if is_greek_dict and q_text and _is_beta_code(q_text):
                    q_text = beta_to_unicode(q_text)
                if q_text:
                    # Get author
                    bibl = child.find('bibl')
                    author = ''
                    if bibl is not None:
                        auth_elem = bibl.find('author')
                        if auth_elem is not None:
                            author = elem_text_content(auth_elem).strip()
                    if author:
                        parts.append(f'"{esc(q_text)}" ({esc(author)})')
                    else:
                        parts.append(f'"{esc(q_text)}"')
        elif tag == 'bibl':
            # Standalone bibl (not inside cit) — show author only
            auth_elem = child.find('author')
            if auth_elem is not None:
                author = elem_text_content(auth_elem).strip()
                if author:
                    parts.append(esc(author))
        elif tag == 'hi':
            # Print dictionaries use italic for translations/Latin words.
            # In our digital format, we render these as normal text —
            # structural cues (bold <tr>, sense cards) provide distinction.
            content = elem_text_content(child, convert_greek=convert_greek).strip()
            if content:
                parts.append(esc(content))
        elif tag == 'orth':
            content = elem_text_content(child, convert_greek=convert_greek).strip()
            if content:
                parts.append(f'<b>{esc(content)}</b>')
        elif tag in ('ref', 'xr', 'lbl', 'usg', 'pos', 'gen', 'itype',
                      'number', 'case', 'mood', 'tns', 'per', 'etym'):
            content = elem_text_content(child, convert_greek=convert_greek).strip()
            if content:
                parts.append(esc(content))
        else:
            content = elem_text_content(child, convert_greek=convert_greek).strip()
            if content:
                parts.append(esc(content))
        if child.tail:
            parts.append(esc(child.tail))
    return ''.join(parts)


def parse_senses(entry_elem, is_latin_dict: bool = False,
                  is_greek_dict: bool = False) -> list[dict]:
    """Extract sense hierarchy from entry. Returns flat list of senses
    with level information for hierarchical indentation."""
    senses = []

    for sense_elem in entry_elem.iter('sense'):
        sense_num = sense_elem.get('n', '')
        sense_level = sense_elem.get('level', '')

        # Render the sense body to HTML (with inline citations, Greek conversion)
        body_html = elem_to_html(sense_elem, is_latin_dict=is_latin_dict,
                                 is_greek_dict=is_greek_dict)
        # Clean up whitespace
        body_html = re.sub(r'\s+', ' ', body_html).strip()
        # Clean up orphaned punctuation: repeated colons, leading colons, etc.
        body_html = re.sub(r'(:\s*){2,}', ': ', body_html)
        body_html = re.sub(r'^\s*:\s*', '', body_html)
        body_html = re.sub(r'\s*:\s*$', '', body_html)
        body_html = re.sub(r';\s*\.—', '.—', body_html)
        # Remove stray dash-only entries
        body_html = re.sub(r'^\s*[.—\-]+\s*$', '', body_html)

        # Extract translations for structured display
        translations = []
        for tr in sense_elem.findall('tr'):
            text = elem_text_content(tr, convert_greek=(is_latin_dict or is_greek_dict)).strip()
            if text:
                translations.append(text)

        if body_html or translations:
            senses.append({
                'num': sense_num,
                'level': sense_level,
                'html': body_html,
                'translations': translations,
            })

    return senses


def parse_perseus_xml(filepath: Path, is_greek: bool):
    """Parse a Perseus TEI P4 XML dictionary file.

    Yields: (headword, pos, gen, itype, senses) tuples.
    """
    is_latin_dict = not is_greek
    print(f"  Parsing {filepath.name}...")

    tree = ET.iterparse(str(filepath), events=('end',))
    count = 0

    for event, elem in tree:
        if elem.tag != 'entryFree':
            continue

        key = elem.get('key', '')

        # Get headword from <orth>
        orth_elem = elem.find('orth')
        if orth_elem is not None:
            orth_text = elem_text_content(orth_elem).strip()
        else:
            orth_text = key

        # For Greek: convert beta code to Unicode
        if is_greek:
            headword = beta_to_unicode(orth_text) if orth_text else beta_to_unicode(key)
            # Clean up: remove trailing commas, whitespace
            headword = headword.strip().rstrip(',').strip()
        else:
            # Latin: use orth text, strip trailing numbers from key
            headword = orth_text.strip() if orth_text else re.sub(r'\d+$', '', key).strip()

        if not headword:
            elem.clear()
            continue

        # Grammatical info
        pos_text = ''
        gen_text = ''
        itype_text = ''

        pos_elem = elem.find('pos')
        if pos_elem is not None:
            pos_text = elem_text_content(pos_elem).strip()
        gen_elem = elem.find('gen')
        if gen_elem is not None:
            gen_text = elem_text_content(gen_elem).strip()
        itype_elem = elem.find('itype')
        if itype_elem is not None:
            itype_text = elem_text_content(itype_elem).strip()

        # For Greek dict, convert beta code in grammar fields
        if is_greek:
            if gen_text and _is_beta_code(gen_text):
                gen_text = beta_to_unicode(gen_text)
            if itype_text and _is_beta_code(itype_text):
                itype_text = beta_to_unicode(itype_text)

        # Parse senses
        is_greek_dict = is_greek
        senses = parse_senses(elem, is_latin_dict=is_latin_dict,
                              is_greek_dict=is_greek_dict)

        # If no senses, try to get the full text content as a single entry
        if not senses:
            full_html = elem_to_html(elem, is_latin_dict=is_latin_dict,
                                     is_greek_dict=is_greek_dict)
            full_html = re.sub(r'\s+', ' ', full_html).strip()
            if full_html and len(full_html) > 10:
                senses = [{'num': '', 'html': full_html[:800],
                           'translations': []}]

        if not senses:
            elem.clear()
            continue

        yield headword, pos_text, gen_text, itype_text, senses
        count += 1

        if count % 10000 == 0:
            print(f"    {count} entries processed...")

        elem.clear()

    print(f"    Total: {count} entries")


# ── Sense tree builder ────────────────────────────────────────

def _build_sense_tree(senses: list[dict]) -> list[dict]:
    """Convert flat list of senses (with 'level' attr) into a nested tree.

    Each node: {'sense': dict, 'children': [node, ...]}
    The hierarchy is reconstructed from the 'level' attribute:
    a sense with level N is a child of the most recent sense with level < N.
    """
    root_children: list[dict] = []
    # Stack of (children_list, level) — we append new nodes to children_list
    stack: list[tuple[list, int]] = [(root_children, 0)]

    for s in senses:
        level = int(s.get('level') or '1')
        node = {'sense': s, 'children': []}

        # Pop back to the nearest ancestor whose level < current
        while len(stack) > 1 and stack[-1][1] >= level:
            stack.pop()

        stack[-1][0].append(node)
        stack.append((node['children'], level))

    return root_children


def _truncate_body(body: str) -> str:
    """Truncate sense body HTML and close any unclosed tags."""
    if len(body) > 600:
        cut = body[:597].rfind(' ')
        if cut < 400:
            cut = 597
        body = body[:cut] + '…'
        for t in ('b', 'i', 'span'):
            opens = body.count(f'<{t}>') + body.count(f'<{t} ')
            closes = body.count(f'</{t}>')
            if opens > closes:
                body += f'</{t}>' * (opens - closes)
    return body


def _render_sense_tree(nodes: list[dict]) -> str:
    """Recursively render sense tree nodes to nested HTML cards."""
    parts = []
    for node in nodes:
        sense = node['sense']
        card_parts = []

        # Sense number header
        if sense['num']:
            card_parts.append(
                f'<div class="sn-hd"><span class="sn-num">'
                f'{esc(sense["num"])}</span></div>'
            )

        # Body text
        body = sense.get('html', '')
        if body:
            body = _truncate_body(body)
            card_parts.append(f'<span class="df">{body}</span>')

        # Nested children
        if node['children']:
            card_parts.append(_render_sense_tree(node['children']))

        if card_parts:
            parts.append(f'<div class="sn">{"".join(card_parts)}</div>')

    return ''.join(parts)


# ── HTML builder ───────────────────────────────────────────────

def build_html(headword: str, pos: str, gen: str, itype: str,
               senses: list[dict], dir_label: str) -> str:
    """Build HTML for a single dictionary entry."""
    parts = [f'<span class="dir">{dir_label}</span>']
    parts.append(f'<span class="hw">{esc(headword)}</span>')

    # POS badge (if available)
    if pos:
        parts.append(f'<span class="pos">{esc(pos)}</span>')

    # Inflection / grammatical info
    inf_parts = []
    if gen:
        inf_parts.append(gen)
    if itype:
        inf_parts.append(itype)
    if inf_parts:
        parts.append(f'<span class="inf">{esc(", ".join(inf_parts))}</span>')

    # Build nested sense tree and render (limit to 20 senses)
    sense_tree = _build_sense_tree(senses[:20])
    parts.append(_render_sense_tree(sense_tree))

    return f'{CSS}<div class="e">{"".join(parts)}</div>'


# ── Build one dictionary ──────────────────────────────────────

def build_dictionary(config: dict):
    """Build a single MDX dictionary."""
    name = config['name']
    xml_path = config['xml']
    is_greek = config['is_greek']
    dir_label = config['dir_label']
    output_dir = OUTPUT_BASE / name
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"Building {name}")
    print(f"{'='*60}")

    # Parse XML
    entries = defaultdict(list)  # headword → [(pos, gen, itype, senses)]
    for headword, pos, gen, itype, senses in parse_perseus_xml(xml_path, is_greek):
        entries[headword].append((pos, gen, itype, senses))

    print(f"  {len(entries)} unique headwords")

    # Write MDict source
    prefix = name.lower().replace('-', '_')
    txt_path = output_dir / f"{prefix}_entries.txt"
    print(f"Writing → {txt_path}...")

    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for hw in sorted(entries.keys()):
            readings = entries[hw]
            # Merge all readings into one article
            if len(readings) == 1:
                pos, gen, itype, senses = readings[0]
                html = build_html(hw, pos, gen, itype, senses, dir_label)
            else:
                # Multiple entries for same headword — combine senses
                all_senses = []
                first_pos, first_gen, first_itype = '', '', ''
                for pos, gen, itype, senses in readings:
                    if pos and not first_pos:
                        first_pos = pos
                    if gen and not first_gen:
                        first_gen = gen
                    if itype and not first_itype:
                        first_itype = itype
                    all_senses.extend(senses)
                html = build_html(hw, first_pos, first_gen, first_itype,
                                  all_senses, dir_label)
            f.write(f"{hw}\n{html}\n</>\n")
            count += 1

    print(f"  {count} entries written")

    # Pack MDX
    mdx_path = output_dir / f"{name}.mdx"
    success, size_mb, _ = pack_mdx(txt_path, config['title'], config['desc'], mdx_path)
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name=config['catalog_display_name'],
        description=config['catalog_description'],
        direction=config['catalog_direction'],
        entries=count,
        license=config['catalog_license'],
        data_source=config['catalog_data_source'],
        tier=3,
        flag=config.get('catalog_flag'),
    )

    # Generate preview
    _generate_preview(output_dir, prefix, name, entries, dir_label,
                      config['samples'])


def _generate_preview(output_dir: Path, prefix: str, name: str, entries: dict,
                     dir_label: str, sample_words: list):
    entries_html = []
    for hw in sample_words:
        if hw in entries:
            readings = entries[hw]
            all_senses = []
            first_pos, first_gen, first_itype = '', '', ''
            for pos, gen, itype, senses in readings:
                if pos and not first_pos:
                    first_pos = pos
                if gen and not first_gen:
                    first_gen = gen
                if itype and not first_itype:
                    first_itype = itype
                all_senses.extend(senses)
            html = build_html(hw, first_pos, first_gen, first_itype,
                              all_senses, dir_label)
            entries_html.append(html)
        else:
            print(f"  ⚠ Sample word '{hw}' not found in entries")

    preview_path = output_dir / f"{prefix}_preview.html"
    _shared_preview(entries_html, preview_path, f'{name} — preview')


# ── Attribution required by PerseusDL/lexica (CC BY-SA 4.0) ──────
# The lexica README asks for this exact credit, the access date, an intact
# availability statement, and that modifications be offered back to Perseus
# (our only modifications are the beta-code → Unicode conversion and the
# HTML rendering in this script, which is public).
PERSEUS_ACCESS_DATE = "2026-02-20"
PERSEUS_CREDIT_HTML = (
    "<p>Text provided under a "
    "<a href='https://creativecommons.org/licenses/by-sa/4.0/'>CC BY-SA</a> license "
    "by Perseus Digital Library, "
    "<a href='http://www.perseus.tufts.edu'>http://www.perseus.tufts.edu</a>, "
    "with funding from The National Endowment for the Humanities. "
    "Data accessed from "
    "<a href='https://github.com/PerseusDL/lexica/'>https://github.com/PerseusDL/lexica/</a> "
    f"[{PERSEUS_ACCESS_DATE}].</p>"
)


# ── Main ───────────────────────────────────────────────────────

DICTS = [
    {
        'name': 'LSJ-GRC-EN',
        'xml': DATA_DIR / 'lsj.xml',
        'title': 'LSJ — Greek-English Lexicon',
        'desc': (
            "<p><b>A Greek-English Lexicon (Liddell-Scott-Jones)</b></p>"
            "<p>The standard comprehensive Ancient Greek-English lexicon. "
            "9th edition (1940), revised by Henry Stuart Jones and Roderick McKenzie.</p>"
            + PERSEUS_CREDIT_HTML
        ),
        'dir_label': f'{FLAG_GRC} Ἑλληνικά → English {FLAG_EN}',
        'is_greek': True,
        'samples': ['ἀνήρ', 'ἀρχή', 'ἄνθρωπος', 'ἀρετή', 'ἀγορά', 'ἁρμονία'],
        'catalog_display_name': 'LSJ Greek-English Lexicon',
        'catalog_description': 'Liddell-Scott-Jones: the standard comprehensive Ancient Greek-English lexicon (9th ed., 1940).',
        'catalog_direction': {'src': 'EL', 'dest': ['EN']},
        'catalog_license': 'CC-BY-SA-4.0',
        'catalog_data_source': 'Perseus Digital Library',
        'catalog_flag': '🏺',
    },
    {
        'name': 'Lewis-Short-LA-EN',
        'xml': DATA_DIR / 'lewis-short.xml',
        'title': 'Lewis & Short — Latin Dictionary',
        'desc': (
            "<p><b>A Latin Dictionary (Lewis & Short)</b></p>"
            "<p>The standard Latin-English dictionary. Founded on Andrews' edition "
            "of Freund's Latin dictionary. Oxford: Clarendon Press, 1879.</p>"
            + PERSEUS_CREDIT_HTML
        ),
        'dir_label': f'{FLAG_LA} Latina → English {FLAG_EN}',
        'is_greek': False,
        'samples': ['ămo', 'ăqua', 'bellum', 'dĕus', 'rex', 'vĭr'],
        'catalog_display_name': 'Lewis & Short Latin Dictionary',
        'catalog_description': 'The standard Latin-English dictionary (Lewis & Short, 1879). 50K entries with etymologies, citations, and cross-references.',
        'catalog_direction': {'src': 'LA', 'dest': ['EN']},
        'catalog_license': 'CC-BY-SA-4.0',
        'catalog_data_source': 'Perseus Digital Library',
    },
]


def main():
    for config in DICTS:
        if config['xml'].exists():
            build_dictionary(config)
        else:
            print(f"Warning: {config['xml']} not found, skipping {config['name']}")


if __name__ == '__main__':
    main()
