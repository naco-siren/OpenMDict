#!/usr/bin/env python3
"""
Build bilingual MDX dictionaries from Kaikki.org (Wiktextract) JSONL data.

Uses per-language extracts from the English Wiktionary edition, which contain
foreign-language headwords with English glosses, IPA, examples, and more.

Supports: Spanish, Arabic, French, Russian, Italian, Portuguese,
          Greek, Turkish, Latin, Korean

Usage:
    python3 build_kaikki_mdx.py          # build all languages
    python3 build_kaikki_mdx.py es       # build Spanish only
    python3 build_kaikki_mdx.py fr ru    # build French and Russian

Input:  ../data/kaikki-{Language}.jsonl
Output: ../output/Kaikki-{XX}-EN/Kaikki-{XX}-EN.mdx
"""

import json
import re
import sys
import unicodedata
from pathlib import Path
from collections import defaultdict, OrderedDict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, PRONUNCIATION, ROMANIZATION, GLOSS, \
    ORDERED_LIST, DOMAIN_BADGE, TAG_BADGE, EXAMPLES_BILINGUAL
from shared.html import esc
from shared.build import pack_mdx, generate_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output"

# ── Language definitions ───────────────────────────────────────

LANGUAGES = {
    'es': {
        'code': 'es',
        'name_en': 'Spanish',
        'name_native': 'Español',
        'flag': '\U0001F1EA\U0001F1F8',  # 🇪🇸
        'file': 'kaikki-Spanish.jsonl',
        'rtl': False,
    },
    'ar': {
        'code': 'ar',
        'name_en': 'Arabic',
        'name_native': 'العربية',
        'flag': '\U0001F1F8\U0001F1E6',  # 🇸🇦
        'file': 'kaikki-Arabic.jsonl',
        'rtl': True,
    },
    'fr': {
        'code': 'fr',
        'name_en': 'French',
        'name_native': 'Français',
        'flag': '\U0001F1EB\U0001F1F7',  # 🇫🇷
        'file': 'kaikki-French.jsonl',
        'rtl': False,
    },
    'ru': {
        'code': 'ru',
        'name_en': 'Russian',
        'name_native': 'Русский',
        'flag': '\U0001F1F7\U0001F1FA',  # 🇷🇺
        'file': 'kaikki-Russian.jsonl',
        'rtl': False,
    },
    'it': {
        'code': 'it',
        'name_en': 'Italian',
        'name_native': 'Italiano',
        'flag': '\U0001F1EE\U0001F1F9',  # 🇮🇹
        'file': 'kaikki-Italian.jsonl',
        'rtl': False,
    },
    'pt': {
        'code': 'pt',
        'name_en': 'Portuguese',
        'name_native': 'Português',
        'flag': '\U0001F1F5\U0001F1F9\U0001F1E7\U0001F1F7',  # 🇵🇹🇧🇷
        'file': 'kaikki-Portuguese.jsonl',
        'rtl': False,
    },
    'el': {
        'code': 'el',
        'name_en': 'Greek',
        'name_native': 'Ελληνικά',
        'flag': '\U0001F1EC\U0001F1F7',  # 🇬🇷
        'file': 'kaikki-Greek.jsonl',
        'rtl': False,
    },
    'tr': {
        'code': 'tr',
        'name_en': 'Turkish',
        'name_native': 'Türkçe',
        'flag': '\U0001F1F9\U0001F1F7',  # 🇹🇷
        'file': 'kaikki-Turkish.jsonl',
        'rtl': False,
    },
    'la': {
        'code': 'la',
        'name_en': 'Latin',
        'name_native': 'Latina',
        'flag': '\U0001F3DB\uFE0F',  # 🏛️
        'file': 'kaikki-Latin.jsonl',
        'rtl': False,
    },
    'ko': {
        'code': 'ko',
        'name_en': 'Korean',
        'name_native': '한국어',
        'flag': '\U0001F1F0\U0001F1F7',  # 🇰🇷
        'file': 'kaikki-Korean.jsonl',
        'rtl': False,
    },
}

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸


def strip_diacritics(text: str) -> str:
    """Strip combining diacritical marks (e.g. Arabic tashkeel)."""
    return ''.join(c for c in text if unicodedata.category(c) != 'Mn')


# ── POS normalization ──────────────────────────────────────────

POS_MAP = {
    'noun': 'n.', 'verb': 'v.', 'adj': 'adj.', 'adv': 'adv.',
    'prep': 'prep.', 'conj': 'conj.', 'intj': 'interj.',
    'pron': 'pron.', 'name': 'proper n.', 'suffix': 'suffix',
    'prefix': 'prefix', 'particle': 'part.', 'phrase': 'phrase',
    'num': 'num.', 'det': 'det.', 'article': 'art.',
    'character': 'char.', 'symbol': 'sym.', 'proverb': 'proverb',
    'affix': 'affix', 'infix': 'infix', 'interfix': 'interfix',
    'circumfix': 'circumfix', 'contraction': 'contr.',
    'prep_phrase': 'prep. phr.', 'adv_phrase': 'adv. phr.',
    'participle': 'part.', 'postposition': 'postp.',
    'punct': 'punct.',
}


# ── HTML generation ────────────────────────────────────────────

CSS = get_css(PRONUNCIATION, ROMANIZATION, GLOSS, ORDERED_LIST,
              DOMAIN_BADGE, TAG_BADGE, EXAMPLES_BILINGUAL)


# ── Kaikki JSONL parser ────────────────────────────────────────

def extract_romanization(entry: dict) -> str:
    """Extract romanization from forms."""
    for f in entry.get('forms', []):
        tags = f.get('tags', [])
        if 'romanization' in tags:
            return f.get('form', '')
    return ''


def extract_ipa(entry: dict) -> list:
    """Extract IPA pronunciations."""
    ipas = []
    for s in entry.get('sounds', []):
        ipa = s.get('ipa', '')
        if ipa:
            ipas.append(ipa)
    return ipas[:3]  # limit to 3


def is_form_of(entry: dict) -> tuple:
    """
    Check if entry is a form-of (inflection) and return base form.
    Returns: (is_form, base_word)
    """
    for sense in entry.get('senses', []):
        form_of = sense.get('form_of', [])
        if form_of:
            # Get the first base form
            for base in form_of:
                word = base.get('word', '')
                if word:
                    return True, word
        tags = sense.get('tags', [])
        if 'form-of' in tags:
            return True, ''
    return False, ''


def extract_display_tags(sense: dict) -> list:
    """Extract useful display tags (register, region, etc.) from a sense."""
    tags = sense.get('tags', [])
    display = []
    # Register/usage tags worth showing
    show_tags = {
        'colloquial', 'informal', 'formal', 'literary', 'archaic',
        'dated', 'obsolete', 'rare', 'poetic', 'vulgar', 'slang',
        'derogatory', 'euphemistic', 'humorous', 'figurative',
        'transitive', 'intransitive', 'reflexive', 'pronominal',
        'countable', 'uncountable', 'masculine', 'feminine', 'neuter',
    }
    # Region tags
    region_tags = {
        'Spain', 'Latin-America', 'Mexico', 'Argentina', 'Chile',
        'Colombia', 'Venezuela', 'Peru', 'Caribbean', 'Central-America',
        'US', 'UK', 'British', 'American',
    }
    for t in tags:
        if t in show_tags or t in region_tags:
            display.append(t)
    return display[:4]  # limit


def extract_topics(sense: dict) -> list:
    """Extract topic/domain labels from a sense."""
    topics = sense.get('topics', [])
    return [t.replace('-', ' ').replace('_', ' ') for t in topics][:3]


def build_sense_html(sense: dict) -> str:
    """Build HTML for a single sense."""
    glosses = sense.get('glosses', [])
    if not glosses:
        return ''

    parts = []
    parts.append('<div class="sn">')

    # Header: POS is handled at entry level; here we show topics + tags
    header_parts = []
    topics = extract_topics(sense)
    for topic in topics:
        header_parts.append(f'<span class="dm">{esc(topic)}</span>')
    display_tags = extract_display_tags(sense)
    for tag in display_tags:
        header_parts.append(f'<span class="tg">{esc(tag)}</span>')
    if header_parts:
        parts.append(f'<div class="sn-hd">{"".join(header_parts)}</div>')

    # Glosses
    if len(glosses) == 1:
        parts.append(f'<span class="gl">{esc(glosses[0])}</span>')
    else:
        items = ''.join(f'<li>{esc(g)}</li>' for g in glosses)
        parts.append(f'<ol class="d">{items}</ol>')

    # Example sentences (up to 2)
    examples = sense.get('examples', [])
    for ex in examples[:2]:
        text = ex.get('text', '')
        translation = ex.get('english', ex.get('translation', ''))
        if text:
            parts.append('<div class="ex">')
            parts.append(f'<span class="ex-src">{esc(text)}</span>')
            if translation:
                parts.append(f'<span class="ex-tr">{esc(translation)}</span>')
            parts.append('</div>')

    parts.append('</div>')
    return ''.join(parts)


def make_entry_html(headword: str, dir_label: str, pos: str,
                    ipas: list, roman: str, senses_html: str,
                    rtl: bool = False) -> str:
    """Build complete entry HTML."""
    inner = f'<span class="dir">{esc(dir_label)}</span>'

    # Headword with optional RTL
    if rtl:
        inner += f'<span class="hw" dir="rtl">{esc(headword)}</span>'
    else:
        inner += f'<span class="hw">{esc(headword)}</span>'

    # IPA pronunciation
    if ipas:
        inner += f'<span class="pr">{esc(", ".join(ipas))}</span>'

    # Romanization (for Arabic, etc.)
    if roman:
        inner += f'<span class="rm">{esc(roman)}</span>'

    inner += senses_html
    return f'{CSS}<div class="e">{inner}</div>'


def make_combined_html(headword: str, dir_label: str,
                       readings: list, rtl: bool = False) -> str:
    """
    Build HTML for a headword with multiple POS entries.

    readings: list of (pos, ipas, roman, senses_html)
    """
    if len(readings) == 1:
        pos, ipas, roman, senses_html = readings[0]
        return make_entry_html(headword, dir_label, pos, ipas, roman,
                               senses_html, rtl)

    # Multiple readings (e.g., noun + verb for same word)
    sections = []
    for i, (pos, ipas, roman, senses_html) in enumerate(readings):
        section = ''
        if i == 0:
            section += f'<span class="dir">{esc(dir_label)}</span>'
        if rtl:
            section += f'<span class="hw" dir="rtl">{esc(headword)}</span>'
        else:
            section += f'<span class="hw">{esc(headword)}</span>'
        if ipas:
            section += f'<span class="pr">{esc(", ".join(ipas))}</span>'
        if roman:
            section += f'<span class="rm">{esc(roman)}</span>'
        section += senses_html
        sections.append(section)

    body = '<hr class="sep">'.join(sections)
    return f'{CSS}<div class="e">{body}</div>'


# ── Main build logic ──────────────────────────────────────────

def parse_kaikki_file(filepath: Path, lang_code: str):
    """
    Parse Kaikki JSONL file.

    Yields: (word, pos, ipas, roman, senses, is_form, base_word)
    where senses is a list of sense dicts with glosses.
    """
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            entry = json.loads(line)

            # Skip thesaurus entries
            if entry.get('source') == 'thesaurus':
                continue

            word = entry.get('word', '').strip()
            if not word:
                continue

            # Only include entries for the target language
            if entry.get('lang_code') != lang_code:
                continue

            pos_raw = entry.get('pos', '')
            pos = POS_MAP.get(pos_raw, pos_raw)

            senses = entry.get('senses', [])
            # Filter senses with actual glosses
            good_senses = [s for s in senses if s.get('glosses')]
            if not good_senses:
                continue

            ipas = extract_ipa(entry)
            roman = extract_romanization(entry)

            # Check form-of
            form, base = is_form_of(entry)

            yield word, pos, ipas, roman, good_senses, form, base


def build_language(lang_key: str):
    """Build MDX for one language."""
    lang = LANGUAGES[lang_key]
    code = lang['code']
    name_en = lang['name_en']
    name_native = lang['name_native']
    flag = lang['flag']
    rtl = lang.get('rtl', False)
    data_file = DATA_DIR / lang['file']

    if not data_file.exists():
        print(f"ERROR: {data_file} not found. Download from kaikki.org first.")
        return

    dict_name = f"Kaikki-{code.upper()}-EN"
    dict_dir = OUTPUT_DIR / dict_name
    dict_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"Building {name_en}-English from Kaikki.org...")
    print(f"  Source: {data_file}")

    dir_label = f'{flag} {name_native} \u2192 English {FLAG_EN}'

    # ── Phase 1: Parse and group entries ──
    # Group by (word, pos) to combine senses, keeping form-of entries separate
    entries = defaultdict(list)       # word → [(pos, ipas, roman, senses)]
    form_of_map = {}                  # form_word → base_word

    entry_count = 0
    form_count = 0

    for word, pos, ipas, roman, senses, is_form, base_word in parse_kaikki_file(data_file, code):
        if is_form and base_word:
            form_count += 1
            # Only store redirect if base word exists and is different
            if base_word != word and base_word not in form_of_map:
                form_of_map[word] = base_word
            continue

        entry_count += 1
        entries[word].append((pos, ipas, roman, senses))

    print(f"  Real headwords: {len(entries)}")
    print(f"  Form-of entries: {form_count}")
    print(f"  Redirect candidates: {len(form_of_map)}")

    # ── Phase 2: Generate HTML and write MDict source ──
    txt_path = dict_dir / f"kaikki_{code}_entries.txt"
    print(f"  Writing \u2192 {txt_path}...")

    count = 0
    redirect_count = 0

    with open(txt_path, 'w', encoding='utf-8') as f:
        # Main entries
        for word in sorted(entries.keys(), key=str.lower):
            word_entries = entries[word]

            # Group by POS, merge senses
            readings = []
            for pos, ipas, roman, senses in word_entries:
                # Build senses HTML
                senses_html_parts = []

                # Add POS as first sense header if available
                for sense in senses:
                    html = build_sense_html(sense)
                    if html:
                        senses_html_parts.append(html)

                if not senses_html_parts:
                    continue

                senses_html = ''.join(senses_html_parts)

                # Inject POS badge into first sense card if present
                if pos:
                    pos_badge_html = f'<span class="pos">{esc(pos)}</span>'
                    # Check if first card has a header
                    if '<div class="sn-hd">' in senses_html_parts[0]:
                        # Prepend POS to existing header
                        senses_html = senses_html.replace(
                            '<div class="sn-hd">',
                            f'<div class="sn-hd">{pos_badge_html}',
                            1
                        )
                    else:
                        # Insert header after first <div class="sn">
                        senses_html = senses_html.replace(
                            '<div class="sn">',
                            f'<div class="sn"><div class="sn-hd">{pos_badge_html}</div>',
                            1
                        )

                readings.append((pos, ipas, roman, senses_html))

            if not readings:
                continue

            html = make_combined_html(word, dir_label, readings, rtl)
            lookup_key = word
            f.write(f"{lookup_key}\n{html}\n</>\n")
            count += 1

        # Form-of redirects (only if base word exists in entries)
        # For Arabic etc., base words may have diacritics — try bare form too
        for form_word in sorted(form_of_map.keys(), key=str.lower):
            base_word = form_of_map[form_word]
            # Try exact match first, then stripped diacritics
            target = None
            if base_word in entries:
                target = base_word
            else:
                bare = strip_diacritics(base_word)
                if bare in entries:
                    target = bare
            if target and target != form_word:
                lookup_key = form_word
                target_key = target
                f.write(f"{lookup_key}\n@@@LINK={target_key}\n</>\n")
                redirect_count += 1

    print(f"  {count} main entries")
    print(f"  {redirect_count} form-of redirects")
    print(f"  {count + redirect_count} total entries")

    # ── Phase 3: Pack MDX ──
    mdx_path = dict_dir / f"Kaikki-{code.upper()}-EN.mdx"
    success, size_mb, _ = pack_mdx(
        txt_path,
        f"Kaikki {name_en}-English",
        f"<p><b>{name_en}-English Dictionary (Kaikki.org / Wiktextract)</b></p>"
        f"<p>Extracted from the English Wiktionary by Wiktextract.</p>"
        f"<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/3.0/'>CC-BY-SA 3.0</a>.</p>"
        f"<p>Source: <a href='https://kaikki.org/'>kaikki.org</a></p>",
        mdx_path,
    )
    if not success:
        return
    print(f"  \u2713 {mdx_path.name}: {size_mb:.1f} MB")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name=f"Kaikki {name_en}-English",
        description=f"{name_en}-English dictionary with IPA pronunciation, usage examples, and inflection redirects from Wiktionary.",
        direction={"src": code.upper(), "dest": ["EN"]},
        entries=count + redirect_count,
        license="CC-BY-SA 3.0",
        data_source="Kaikki.org (English Wiktionary extract)",
        tier=3,
    )

    # ── Phase 4: Generate preview ──
    _generate_preview(lang_key, entries, dict_dir)


# ── Preview ────────────────────────────────────────────────────

SAMPLE_WORDS = {
    'es': ['agua', 'casa', 'hola', 'comer', 'bonito', 'libro'],
    'ar': ['\u0645\u0627\u0621', '\u0643\u062a\u0627\u0628', '\u062c\u0645\u064a\u0644',
           '\u0623\u0643\u0644', '\u0645\u062f\u0631\u0633\u0629', '\u0628\u064a\u062a'],
    'fr': ['maison', 'être', 'manger', 'eau', 'bonjour', 'livre'],
    'ru': ['\u0434\u043e\u043c', '\u043a\u043d\u0438\u0433\u0430', '\u0432\u043e\u0434\u0430',
           '\u0435\u0441\u0442\u044c', '\u0445\u043e\u0440\u043e\u0448\u043e', '\u0447\u0435\u043b\u043e\u0432\u0435\u043a'],
    'it': ['casa', 'essere', 'mangiare', 'acqua', 'libro', 'buono'],
    'pt': ['casa', 'ser', 'comer', 'água', 'livro', 'bom'],
    'el': ['\u03c3\u03c0\u03af\u03c4\u03b9', '\u03bd\u03b5\u03c1\u03cc', '\u03b2\u03b9\u03b2\u03bb\u03af\u03bf',
           '\u03ba\u03b1\u03bb\u03cc\u03c2', '\u03ac\u03bd\u03b8\u03c1\u03c9\u03c0\u03bf\u03c2'],
    'tr': ['ev', 'su', 'kitap', 'güzel', 'gitmek', 'insan'],
    'la': ['domus', 'aqua', 'liber', 'bonus', 'homo', 'esse'],
    'ko': ['\uc9d1', '\ubb3c', '\uc0ac\ub78c', '\ud558\ub2e4', '\ucc45', '\uc88b\ub2e4'],
}


def _generate_preview(lang_key: str, entries: dict, dict_dir: Path = None):
    """Generate preview HTML for visual review."""
    lang = LANGUAGES[lang_key]
    code = lang['code']
    name_en = lang['name_en']
    name_native = lang['name_native']
    flag = lang['flag']
    rtl = lang.get('rtl', False)

    dir_label = f'{flag} {name_native} \u2192 English {FLAG_EN}'

    if dict_dir is None:
        dict_dir = OUTPUT_DIR / f"Kaikki-{code.upper()}-EN"
    preview_path = dict_dir / f"kaikki_{code}_preview.html"
    entries_html = []

    samples = SAMPLE_WORDS.get(code, [])
    for word in samples:
        if word not in entries:
            continue
        word_entries = entries[word]
        readings = []
        for pos, ipas, roman, senses in word_entries:
            senses_html_parts = []
            for sense in senses:
                html = build_sense_html(sense)
                if html:
                    senses_html_parts.append(html)
            if not senses_html_parts:
                continue
            senses_html = ''.join(senses_html_parts)
            if pos:
                pos_badge_html = f'<span class="pos">{esc(pos)}</span>'
                if '<div class="sn-hd">' in senses_html_parts[0]:
                    senses_html = senses_html.replace(
                        '<div class="sn-hd">',
                        f'<div class="sn-hd">{pos_badge_html}',
                        1
                    )
                else:
                    senses_html = senses_html.replace(
                        '<div class="sn">',
                        f'<div class="sn"><div class="sn-hd">{pos_badge_html}</div>',
                        1
                    )
            readings.append((pos, ipas, roman, senses_html))

        if readings:
            html = make_combined_html(word, dir_label, readings, rtl)
            entries_html.append(html)

    generate_preview(entries_html, preview_path,
                     f'Kaikki {name_en}-English \u2014 preview')


# ── Main ──────────────────────────────────────────────────────

def main():
    if len(sys.argv) > 1:
        langs = sys.argv[1:]
    else:
        langs = list(LANGUAGES.keys())

    for lang_key in langs:
        if lang_key not in LANGUAGES:
            print(f"Unknown language: {lang_key}")
            print(f"Available: {', '.join(LANGUAGES.keys())}")
            continue
        build_language(lang_key)

    print("\nDone!")


if __name__ == '__main__':
    main()
