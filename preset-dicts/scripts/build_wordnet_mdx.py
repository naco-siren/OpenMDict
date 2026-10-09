#!/usr/bin/env python3
"""
Build an English monolingual MDX dictionary from Open English WordNet 2025.

Uses the JSON release files from:
  https://github.com/globalwordnet/english-wordnet/releases

The data is split into:
  - entries-{a-z,0}.json : headwords → POS → synset IDs
  - {noun,verb,adj,adv}.*.json : synset ID → definition, examples, members, relations

Usage:
    python3 build_wordnet_mdx.py

Input:  ../data/entries-*.json, ../data/noun.*.json, ../data/verb.*.json, etc.
Output: ../output/WordNet-EN/WordNet-EN.mdx
"""

import json
import glob
import sys
from pathlib import Path
from collections import defaultdict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, PRONUNCIATION, SENSE_NUMBER_INLINE, GLOSS, EXAMPLES
from shared.html import esc
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "WordNet-EN"

# ── POS display ────────────────────────────────────────────────
POS_DISPLAY = {
    'n': 'noun',
    'v': 'verb',
    's': 'adj.',   # satellite adjective
    'a': 'adj.',
    'r': 'adv.',
}

POS_ORDER = {'n': 0, 'v': 1, 'a': 2, 's': 2, 'r': 3}

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_EN} English'

# ── CSS ────────────────────────────────────────────────────────
CSS = get_css(
    PRONUNCIATION, SENSE_NUMBER_INLINE, GLOSS, EXAMPLES,
    extra_light=(
        '.ex{font-style:italic}'
        '.syn{font-size:0.9em;color:#34c759;margin:4px 0 0}'
        '.syn b{color:#30a14e;font-weight:500}'
        '.syn a{color:#34c759;text-decoration:underline}'
        '.rel{font-size:0.85em;color:#8e8e93;margin:2px 0 0}'
        '.rel a{color:#8e8e93;text-decoration:underline}'
    ),
    extra_dark=(
        '.syn{color:#30d158}.syn b{color:#32d74b}.syn a{color:#30d158}'
        '.rel{color:#636366}.rel a{color:#636366}'
    ),
)


# ── Load data ──────────────────────────────────────────────────

def load_synsets() -> dict:
    """Load all synset files into a single dict: synset_id → synset_data."""
    synsets = {}
    patterns = ['noun.*.json', 'verb.*.json', 'adj.*.json', 'adv.*.json']
    for pattern in patterns:
        for filepath in glob.glob(str(DATA_DIR / pattern)):
            with open(filepath, 'r', encoding='utf-8') as f:
                data = json.load(f)
                synsets.update(data)
    return synsets


def load_entries() -> dict:
    """Load all entry files. Returns: word → {pos → [sense_dicts]}."""
    entries = defaultdict(lambda: defaultdict(list))
    for filepath in sorted(glob.glob(str(DATA_DIR / 'entries-*.json'))):
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
            for word, pos_data in data.items():
                for pos, info in pos_data.items():
                    pronunciation = None
                    for p in info.get('pronunciation', []):
                        val = p.get('value', '')
                        if val:
                            pronunciation = val
                            break
                    for sense in info.get('sense', []):
                        sense['_pronunciation'] = pronunciation
                        entries[word][pos].append(sense)
    return dict(entries)


# ── HTML generation ────────────────────────────────────────────

def build_entry_html(word: str, pos_groups: list, synsets: dict,
                     entry_words: set = None) -> str:
    """
    Build HTML for one headword.
    pos_groups: list of (pos, senses) sorted by POS order.
    entry_words: set of all headwords (lowercased) for entry:// linking.
    """
    parts = [f'<span class="dir">{DIR_LABEL}</span>',
             f'<span class="hw">{esc(word)}</span>']

    # Pronunciation from first sense that has one
    pronunciation = None
    for pos, senses in pos_groups:
        for s in senses:
            p = s.get('_pronunciation')
            if p:
                pronunciation = p
                break
        if pronunciation:
            break
    if pronunciation:
        parts.append(f'<span class="pr">/{esc(pronunciation)}/</span>')

    for pos, senses in pos_groups:
        pos_label = POS_DISPLAY.get(pos, pos)

        for i, sense in enumerate(senses):
            synset_id = sense.get('synset', '')
            synset = synsets.get(synset_id, {})

            definitions = synset.get('definition', [])
            if not definitions:
                continue

            examples = synset.get('example', [])
            members = synset.get('members', [])
            hypernyms = synset.get('hypernym', []) + synset.get('instance_hypernym', [])

            parts.append('<div class="sn">')

            # Header: POS + sense number
            header = f'<span class="pos">{esc(pos_label)}</span>'
            if len(senses) > 1:
                header += f'<span class="sn-n">{i+1}.</span>'
            parts.append(f'<div class="sn-hd">{header}</div>')

            # Definition
            for d in definitions:
                parts.append(f'<span class="gl">{esc(d)}</span>')

            # Examples (up to 3)
            for ex in examples[:3]:
                if isinstance(ex, dict):
                    ex_text = ex.get('text', '')
                else:
                    ex_text = ex
                if ex_text:
                    parts.append(f'<div class="ex">{esc(ex_text)}</div>')

            # Synonyms (other members of this synset, excluding the headword itself)
            synonyms = [m for m in members if m.lower() != word.lower()]
            if synonyms:
                syn_items = []
                for s in synonyms[:8]:
                    if entry_words and s.lower() in entry_words:
                        syn_items.append(f'<a href="entry://{esc(s)}">{esc(s)}</a>')
                    else:
                        syn_items.append(esc(s))
                parts.append(f'<div class="syn"><b>Syn:</b> {", ".join(syn_items)}</div>')

            # Hypernym (show as "→ ...")
            if hypernyms:
                hyp_words = []
                for hid in hypernyms[:2]:
                    hs = synsets.get(hid, {})
                    hm = hs.get('members', [])
                    if hm:
                        hyp_words.append(hm[0])
                if hyp_words:
                    hyp_items = []
                    for h in hyp_words:
                        if entry_words and h.lower() in entry_words:
                            hyp_items.append(f'<a href="entry://{esc(h)}">{esc(h)}</a>')
                        else:
                            hyp_items.append(esc(h))
                    parts.append(f'<div class="rel">\u2192 {", ".join(hyp_items)}</div>')

            parts.append('</div>')

    return f'{CSS}<div class="e">{"".join(parts)}</div>'


# ── Main ──────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Loading Open English WordNet 2025...")
    print("  Loading synsets...")
    synsets = load_synsets()
    print(f"  {len(synsets)} synsets loaded")

    print("  Loading entries...")
    entries = load_entries()
    print(f"  {len(entries)} headwords loaded")

    # ── Build headword lookup for entry:// linking ──
    entry_words = {w.lower() for w in entries.keys()}
    print(f"  {len(entry_words)} unique headwords (lowercased) for cross-linking")

    # ── Generate MDict source ──
    txt_path = OUTPUT_DIR / "wordnet_en_entries.txt"
    print(f"  Writing → {txt_path}...")

    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for word in sorted(entries.keys(), key=str.lower):
            pos_data = entries[word]

            # Sort POS groups by canonical order
            pos_groups = sorted(pos_data.items(), key=lambda x: POS_ORDER.get(x[0], 9))

            # Filter out POS groups with no resolvable synsets
            valid_groups = []
            for pos, senses in pos_groups:
                valid_senses = [s for s in senses
                                if s.get('synset') in synsets
                                and synsets[s['synset']].get('definition')]
                if valid_senses:
                    valid_groups.append((pos, valid_senses))

            if not valid_groups:
                continue

            html = build_entry_html(word, valid_groups, synsets, entry_words)
            f.write(f"{word}\n{html}\n</>\n")
            count += 1

    print(f"  {count} entries written")

    # ── Pack MDX ──
    mdx_path = OUTPUT_DIR / "WordNet-EN.mdx"
    desc_html = (
        "<p><b>Open English WordNet 2025</b></p>"
        "<p>A lexical database of English grouping words into synsets "
        "with definitions, examples, and semantic relations.</p>"
        "<p>Based on Princeton WordNet, developed by the "
        "<a href='https://en-word.net/'>Open English WordNet</a> project.</p>"
        "<p>Licensed under <a href='https://creativecommons.org/licenses/by/4.0/'>CC-BY 4.0</a> "
        "and the <a href='https://wordnet.princeton.edu/license-and-commercial-use'>WordNet License</a>.</p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "Open English WordNet", desc_html, mdx_path)
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="Open English WordNet",
        description="Comprehensive English dictionary with definitions, examples, synonyms, and semantic relations from Princeton WordNet synsets.",
        direction={"src": "EN", "dest": ["EN"]},
        entries=count,
        license="CC-BY 4.0 + WordNet License",
        data_source="Open English WordNet 2025",
        tier=0,
    )

    # ── Preview ──
    _generate_preview(entries, synsets, entry_words)


def _generate_preview(entries: dict, synsets: dict, entry_words: set = None):
    """Generate preview HTML for visual review."""
    if entry_words is None:
        entry_words = {w.lower() for w in entries.keys()}
    samples = ['bank', 'run', 'set', 'light', 'mind', 'happy', 'dog', 'water']
    entries_html = []

    for word in samples:
        if word not in entries:
            continue
        pos_data = entries[word]
        pos_groups = sorted(pos_data.items(), key=lambda x: POS_ORDER.get(x[0], 9))
        valid_groups = []
        for pos, senses in pos_groups:
            valid_senses = [s for s in senses
                            if s.get('synset') in synsets
                            and synsets[s['synset']].get('definition')]
            if valid_senses:
                valid_groups.append((pos, valid_senses))
        if valid_groups:
            html = build_entry_html(word, valid_groups, synsets, entry_words)
            entries_html.append(html)

    preview_path = OUTPUT_DIR / "wordnet_en_preview.html"
    _shared_preview(entries_html, preview_path, 'Open English WordNet 2025 — preview')


if __name__ == '__main__':
    main()
