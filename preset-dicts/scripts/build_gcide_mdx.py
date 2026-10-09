#!/usr/bin/env python3
"""
Build GCIDE (GNU Collaborative International Dictionary) MDX from CIDE.A-Z files.

Usage:
    python build_gcide_mdx.py

Input:  ../data/gcide/gcide-0.53/CIDE.A .. CIDE.Z
Output: ../output/GCIDE-EN/GCIDE-EN.mdx
"""

import re
import sys
from pathlib import Path
from collections import defaultdict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, PRONUNCIATION, ETYMOLOGY, DEFINITION, \
    EXAMPLES, SYNONYMS, CROSSREF
from shared.html import esc
from shared.build import pack_mdx, generate_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data" / "gcide" / "gcide-0.53"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "GCIDE-EN"

# ── Pronunciation entity → Unicode ────────────────────────────

PRON_ENTITIES = {
    '<adot/': 'ȧ', '<acr/': 'ă', '<asl/': 'ā', '<aum/': 'ä',
    '<add/': 'ä', '<acir/': 'â', '<ait/': 'à', '<atil/': 'ã',
    '<ecr/': 'ĕ', '<esl/': 'ē', '<edd/': 'ë', '<ecir/': 'ê', '<eit/': 'è',
    '<icr/': 'ĭ', '<isl/': 'ī', '<icir/': 'î',
    '<ocr/': 'ŏ', '<osl/': 'ō', '<oum/': 'ö', '<odd/': 'ö', '<ocir/': 'ô',
    '<ucr/': 'ŭ', '<usl/': 'ū', '<uum/': 'ü', '<udd/': 'ü', '<ucir/': 'û',
    '<ccedil/': 'ç', '<nsc/': 'ç', '<nsm/': 'ñ',
    '<th/': 'þ', '<edh/': 'ð',
    '<frac12/': '½', '<frac14/': '¼', '<frac13/': '⅓',
    '<frac23/': '⅔', '<frac34/': '¾', '<frac18/': '⅛',
    '<ldquo/': '\u201c', '<rdquo/': '\u201d',
    '<lsquo/': '\u2018', '<rsquo/': '\u2019',
    '<sect/': '§', '<para/': '¶',
    '<deg/': '°', '<prime/': '\u2032', '<dprime/': '\u2033',
    '<mdash/': '\u2014', '<ndash/': '\u2013',
    '<hand/': '☞', '<star/': '★',
    '<amac/': 'ā', '<emac/': 'ē', '<imac/': 'ī', '<omac/': 'ō', '<umac/': 'ū',
    '<abreve/': 'ă', '<ebreve/': 'ĕ', '<ibreve/': 'ĭ', '<obreve/': 'ŏ', '<ubreve/': 'ŭ',
    # Less common
    '<uring/': 'ů', '<aring/': 'å',
    '<yogh/': 'ȝ', '<thorn/': 'þ', '<eth/': 'ð',
    # Placeholder for undigitized characters (reverse-video '?' in Webster's font)
    '<?/': '',
    # Catch-all for unknown entities: will be stripped below
}

# Regex to match any <entity/ pattern
_ENTITY_RE = re.compile(r'<[a-zA-Z0-9]+/')


def resolve_entities(text: str) -> str:
    """Replace GCIDE pronunciation entities with Unicode equivalents."""
    for entity, repl in PRON_ENTITIES.items():
        text = text.replace(entity, repl)
    # Strip any remaining unrecognized entities
    text = _ENTITY_RE.sub('', text)
    # Also handle \'XX hex codes (e.g., \'d8 = Ø)
    def hex_replace(m):
        try:
            return chr(int(m.group(1), 16))
        except (ValueError, OverflowError):
            return ''
    text = re.sub(r"\\'([0-9a-fA-F]{2})", hex_replace, text)
    return text


# ── HTML ───────────────────────────────────────────────────────

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_EN} English'

CSS = get_css(PRONUNCIATION, ETYMOLOGY, DEFINITION, EXAMPLES, SYNONYMS, CROSSREF)


# ── GCIDE paragraph parser ────────────────────────────────────

def clean_hw(hw_text: str) -> str:
    """Clean display headword from <hw> content.
    Remove * (syllable break) and " (stress mark), resolve entities."""
    hw = resolve_entities(hw_text)
    hw = hw.replace('*', '').replace('"', '')
    return hw.strip()


def extract_tag_content(text: str, tag: str) -> str:
    """Extract text between <tag>...</tag>."""
    pattern = re.compile(f'<{tag}[^>]*>(.*?)</{tag}>', re.DOTALL)
    m = pattern.search(text)
    return m.group(1) if m else ''


def extract_all_tag_content(text: str, tag: str) -> list[str]:
    """Extract all occurrences of text between <tag>...</tag>."""
    pattern = re.compile(f'<{tag}[^>]*>(.*?)</{tag}>', re.DOTALL)
    return [m.group(1) for m in pattern.finditer(text)]


def strip_tags(text: str) -> str:
    """Remove all XML/SGML tags from text."""
    text = re.sub(r'<[^>]+>', '', text)
    text = resolve_entities(text)
    return text.strip()


def strip_source_tags(text: str) -> str:
    """Remove [<source>...</source>] blocks."""
    return re.sub(r'\s*\[<source>[^<]*</source>\]', '', text)


def process_cross_refs(text: str, entry_set: set) -> str:
    """Convert <er>Word</er> to entry:// links if word exists in entry set."""
    def replace_er(m):
        word = strip_tags(m.group(1)).strip()
        if word.lower() in entry_set:
            return f'<a href="entry://{esc(word)}">{esc(word)}</a>'
        return esc(word)
    return re.sub(r'<er>([^<]+)</er>', replace_er, text)


def parse_gcide_paragraph(para_text: str) -> dict:
    """Parse a single GCIDE <p>...</p> block into structured data."""
    result = {
        'ent': '',
        'hw': '',
        'pr': '',
        'pos': '',
        'ety': '',
        'sn': '',
        'def': '',
        'mark': '',
        'quote': '',
        'quote_author': '',
        'syn': '',
        'usage': '',
        'is_continuation': False,
        'raw': para_text,
    }

    # Entry headword
    ent = extract_tag_content(para_text, 'ent')
    if ent:
        result['ent'] = strip_tags(ent).strip()

    # Display headword
    hw = extract_tag_content(para_text, 'hw')
    if hw:
        result['hw'] = clean_hw(hw)

    # Pronunciation
    pr = extract_tag_content(para_text, 'pr')
    if pr:
        pr_clean = strip_tags(pr).strip()
        # Skip placeholder-only pronunciations: (?) or ()
        if pr_clean and pr_clean not in ('(?)', '()'):
            result['pr'] = pr_clean

    # Part of speech
    pos_list = extract_all_tag_content(para_text, 'pos')
    if pos_list:
        result['pos'] = strip_tags(pos_list[0]).strip()

    # Etymology
    ety = extract_tag_content(para_text, 'ety')
    if ety:
        result['ety'] = strip_tags(ety).strip()

    # Sense number
    sn = extract_tag_content(para_text, 'sn')
    if sn:
        result['sn'] = strip_tags(sn).strip()

    # Definition
    def_text = extract_tag_content(para_text, 'def')
    if def_text:
        result['def'] = strip_tags(def_text).strip()

    # Usage mark
    mark = extract_tag_content(para_text, 'mark')
    if mark:
        result['mark'] = strip_tags(mark).strip()

    # Quote
    quote = extract_tag_content(para_text, 'q')
    if quote:
        result['quote'] = strip_tags(quote).strip()

    # Quote author
    qau = extract_tag_content(para_text, 'qau')
    if not qau:
        qau = extract_tag_content(para_text, 'au')
    if qau:
        result['quote_author'] = strip_tags(qau).strip()

    # Synonyms
    syn = extract_tag_content(para_text, 'syn')
    if syn:
        result['syn'] = strip_tags(syn).strip()

    # Usage
    usage = extract_tag_content(para_text, 'usage')
    if usage:
        result['usage'] = strip_tags(usage).strip()

    # If there's no <ent> tag, this is a continuation paragraph
    if not result['ent']:
        result['is_continuation'] = True

    return result


def parse_all_files():
    """Parse all CIDE.A-Z files, return dict of entry_name → [paragraphs]."""
    entries = defaultdict(list)  # entry_name_lower → [para_dicts]

    for letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ':
        filepath = DATA_DIR / f"CIDE.{letter}"
        if not filepath.exists():
            print(f"  Warning: {filepath} not found")
            continue

        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()

        content = strip_source_tags(content)

        # Split on <p> tags — GCIDE uses <p>...</p> for each block
        paragraphs = re.split(r'<p>', content)
        current_entry = None

        for para_raw in paragraphs:
            para_raw = para_raw.strip()
            if not para_raw:
                continue
            # Remove trailing </p>
            para_raw = re.sub(r'</p>\s*$', '', para_raw)

            parsed = parse_gcide_paragraph(para_raw)

            if parsed['ent']:
                current_entry = parsed['ent']
                entries[current_entry.lower()].append(parsed)
            elif current_entry:
                # Continuation paragraph — attach to current entry
                parsed['ent'] = current_entry
                entries[current_entry.lower()].append(parsed)

        print(f"  CIDE.{letter}: done")

    return entries


# ── HTML generation ────────────────────────────────────────────

def build_entry_html(entry_name: str, paragraphs: list[dict], entry_set: set) -> str:
    """Build HTML for a complete GCIDE entry from its paragraphs."""
    parts = [f'<span class="dir">{DIR_LABEL}</span>']

    # Find headword and pronunciation from first paragraph with them
    hw_display = entry_name
    pronunciation = ''
    pos = ''
    etymology = ''

    for p in paragraphs:
        if p['hw'] and not hw_display:
            hw_display = p['hw']
        if p['hw']:
            hw_display = p['hw']
        if p['pr'] and not pronunciation:
            pronunciation = p['pr']
        if p['pos'] and not pos:
            pos = p['pos']
        if p['ety'] and not etymology:
            etymology = p['ety']
        if hw_display and pronunciation:
            break

    parts.append(f'<span class="hw">{esc(hw_display)}</span>')

    if pronunciation:
        parts.append(f'<span class="pr">{esc(pronunciation)}</span>')

    if etymology:
        # Truncate very long etymologies
        ety_display = etymology if len(etymology) <= 300 else etymology[:297] + '...'
        parts.append(f'<span class="et">{esc(ety_display)}</span>')

    # Collect senses, quotations
    senses = []
    quotes = []

    for p in paragraphs:
        if p['def']:
            sense_parts = []

            # Header with POS and mark
            header = []
            if p['pos']:
                header.append(f'<span class="pos">{esc(p["pos"])}</span>')
            if p['mark']:
                header.append(f'<span class="mk">{esc(p["mark"])}</span>')
            if p['sn']:
                header.append(f'<span class="mk">{esc(p["sn"])}</span>')

            if header:
                sense_parts.append(f'<div class="sn-hd">{"".join(header)}</div>')

            sense_parts.append(f'<span class="df">{esc(p["def"])}</span>')
            senses.append('<div class="sn">' + ''.join(sense_parts) + '</div>')

        if p['quote']:
            author = p['quote_author']
            q_html = f'<div class="ex"><span class="ex-q">{esc(p["quote"])}</span>'
            if author:
                q_html += f'<span class="ex-a">— {esc(author)}</span>'
            q_html += '</div>'
            quotes.append(q_html)

        if p['syn']:
            syn_text = p['syn']
            # Try to linkify synonym words
            words = re.split(r'[;,]\s*', syn_text.replace('Syn. -- ', '').replace('Syn.', ''))
            linked = []
            for w in words:
                w = w.strip().rstrip('.')
                if w and w.lower() in entry_set:
                    linked.append(f'<a href="entry://{esc(w)}">{esc(w)}</a>')
                elif w:
                    linked.append(esc(w))
            if linked:
                senses.append(f'<div class="syn"><b>Syn.</b> {"; ".join(linked)}</div>')

        if p['usage']:
            usage_text = p['usage']
            if len(usage_text) <= 500:
                senses.append(f'<div class="syn"><em>{esc(usage_text)}</em></div>')

    # If no senses extracted, try raw text extraction as fallback
    if not senses:
        for p in paragraphs:
            raw_text = strip_tags(p['raw']).strip()
            if raw_text and len(raw_text) > 20:
                senses.append(f'<div class="sn"><span class="df">{esc(raw_text[:500])}</span></div>')
                break

    parts.extend(senses)

    # Add up to 3 quotations
    for q in quotes[:3]:
        parts.append(q)

    return f'{CSS}<div class="e">{"".join(parts)}</div>'


# ── Preview ────────────────────────────────────────────────────

SAMPLE_WORDS = ['abandon', 'beauty', 'cat', 'dictionary', 'elegant', 'freedom']


def _generate_preview(entries: dict, entry_set: set):
    preview_path = OUTPUT_DIR / "gcide_preview.html"
    entries_html = []
    for hw in SAMPLE_WORDS:
        if hw.lower() in entries:
            html = build_entry_html(hw, entries[hw.lower()], entry_set)
            entries_html.append(html)

    generate_preview(entries_html, preview_path, 'GCIDE — preview')


# ── Main ───────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Parsing GCIDE (A-Z)...")

    entries = parse_all_files()
    print(f"  {len(entries)} unique headwords")

    # Build entry set for cross-linking
    entry_set = set(entries.keys())

    # Determine canonical display name for each entry
    # Use the first paragraph's ent field (original case)
    canonical_names = {}
    for key, paras in entries.items():
        for p in paras:
            if p['ent']:
                canonical_names[key] = p['ent']
                break
        if key not in canonical_names:
            canonical_names[key] = key

    # Write MDict source
    txt_path = OUTPUT_DIR / "gcide_entries.txt"
    print(f"Writing → {txt_path}...")

    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for key in sorted(entries.keys()):
            paras = entries[key]
            display_name = canonical_names[key]
            html = build_entry_html(display_name, paras, entry_set)
            f.write(f"{display_name}\n{html}\n</>\n")
            count += 1

    print(f"  {count} entries written")

    # Pack MDX
    mdx_path = OUTPUT_DIR / "GCIDE-EN.mdx"
    success, size_mb, _ = pack_mdx(
        txt_path,
        "GCIDE — GNU Collaborative International Dictionary",
        "<p><b>GCIDE — GNU Collaborative International Dictionary</b></p>"
        "<p>Based on Webster's Revised Unabridged Dictionary (1913) with modern additions "
        "by the GCIDE project. Includes etymologies, pronunciation, definitions, "
        "usage examples, and literary quotations.</p>"
        "<p>Licensed under <a href='https://www.gnu.org/licenses/gpl-3.0.html'>GPL 3.0+</a>.</p>"
        "<p>Source: <a href='https://gcide.gnu.org.ua/'>gnu.org/software/gcide</a></p>",
        mdx_path,
    )
    if not success:
        return
    print(f"✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="GCIDE — English Dictionary",
        description="GNU Collaborative International Dictionary — enhanced Webster's 1913 with etymologies, pronunciation, and usage examples.",
        direction={"src": "EN", "dest": ["EN"]},
        entries=count,
        license="GPL 3.0+",
        data_source="GCIDE 0.53 (GNU Project)",
        tier=1,
    )

    _generate_preview(entries, entry_set)


if __name__ == '__main__':
    main()
