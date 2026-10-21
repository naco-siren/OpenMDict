#!/usr/bin/env python3
"""
Build an English thesaurus MDX dictionary from Moby Thesaurus II.

Upstream: Grady Ward's Moby Thesaurus II, public domain by grant from the
author (January 2001), distributed by Project Gutenberg as eBook #3202:
  https://www.gutenberg.org/ebooks/3202

Format: each line is "root,item,item,...", the items "synonyms and related
words ... in ASCII alphabetical order". 30,260 lines, 30,259 distinct root
words (one root, 'cackle', is on two lines), ~2.5 million list items.

What the build makes of it
  * One main entry per root word. Items are sorted case-insensitively, the
    root itself is dropped from its own list, and lists of GROUP_MIN_ITEMS
    or more are split into letter groups. Items that are entries are links;
    spelling differences in hyphen/space are bridged ('helter-skelter' ->
    'helter skelter'), and a link to a root that only matches in a different
    case is kept only when the two lists are related; otherwise the item
    links to its own "listed under" entry ('CAT' in 'aerospace' opens
    'CAT', listed under aerospace, air pocket..., not the feline 'cat').
  * Known slurs are labelled "offensive", moved to a separate trailing
    group and left unlinked. Ambiguous words (coon, fag, spade, queen...)
    are flagged only in lists whose context makes the slur sense clear
    (see OFFENSIVE_*). The same holds for the root words a "listed under"
    entry shows: 'American Indian' does not link to the slur roots that
    list it.
  * A "listed under" entry for every term that occurs only inside lists
    ('okay', 'creative', 'wish', and case homographs such as 'Here' the
    goddess next to the root 'here'): links back to the root words listing
    it. The app shows every record whose key matches a query ignoring case,
    so 'here' shows the root first and 'Here' after it.
  * @@@LINK redirects so that what users type finds an entry: hyphenated,
    spaced and solid spellings (and between two roots that differ only in
    hyphen/space, 'cold blooded' / 'cold-blooded', so both lists show),
    British spellings, accented loanword spellings, and inflected forms
    (walked, cities, happier, went, mice; of list-only terms, 'wished';
    of phrases, 'gave up', 'X-rays', 'by-products'). The word facts behind
    them (part of speech, irregular forms, British spelling variants,
    compound spellings) come from Open English WordNet 2025, which data/ already
    holds for the WordNet preset. That makes OEWN (CC BY 4.0, based on
    Princeton WordNet) a second upstream: see USE_OEWN and the description.

Usage:
    python3 build_moby_thesaurus_mdx.py

Input:  ../data/mthesaur.txt
        ../data/entries-*.json, ../data/{noun,verb,adj,adv}.*.json (OEWN 2025)
Output: ../output/Moby-Thesaurus-EN/Moby-Thesaurus-EN.mdx
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, TEXT_SECONDARY, TEXT_LINK
from shared.html import esc, entry_link, wrap_entry
from shared.build import pack_mdx, generate_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "Moby-Thesaurus-EN"
DATA_FILE = DATA_DIR / "mthesaur.txt"
OEWN_ENTRY_GLOB = "entries-*.json"
OEWN_SYNSET_GLOBS = ("noun.*.json", "verb.*.json", "adj.*.json", "adv.*.json")

# Open English WordNet supplies the word facts behind the inflection,
# British-spelling and compound-spelling redirects. Its licence (CC BY 4.0,
# plus the Princeton WordNet License for the underlying data) then applies
# to those redirect keys, so the description carries both notices and the
# catalog licence becomes a compound expression. Set to False for a purely
# public-domain build: it keeps the root, "listed under", list-attested
# hyphen/solid, hand-listed British and accented redirects, and drops the
# OEWN-derived ones (inflections, rule-based British spellings).
USE_OEWN = True

# Attribution both OEWN licences require (OEWN LICENSE.md: credit both
# Princeton WordNet and the Open English WordNet team; the Princeton
# notice and disclaimer must appear on all copies, including modifications).
OEWN_NOTICE = (
    "<p>The redirects from inflected forms and from British and compound "
    "spellings use word forms, parts of speech and spelling variants from "
    "<a href='https://en-word.net/'>Open English WordNet</a> 2025, "
    "<a href='https://github.com/globalwordnet/english-wordnet'>"
    "github.com/globalwordnet/english-wordnet</a>. "
    "Copyright © 2019–present, The Open English WordNet Team. "
    "Licensed under <a href='https://creativecommons.org/licenses/by/4.0/'>"
    "Creative Commons Attribution 4.0 International (CC BY 4.0)</a>, "
    "provided as is, without warranties; selected and adapted by OpenMDict.</p>"
    "<p>Open English WordNet is based on Princeton WordNet, used under the "
    "<a href='https://wordnet.princeton.edu/license-and-commercial-use'>"
    "WordNet License</a>. WordNet 3.1 Copyright 2011 by Princeton "
    "University. All rights reserved. THIS SOFTWARE AND DATABASE IS "
    "PROVIDED \"AS IS\" AND PRINCETON UNIVERSITY MAKES NO REPRESENTATIONS "
    "OR WARRANTIES, EXPRESS OR IMPLIED. BY WAY OF EXAMPLE, BUT NOT "
    "LIMITATION, PRINCETON UNIVERSITY MAKES NO REPRESENTATIONS OR "
    "WARRANTIES OF MERCHANTABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE "
    "OR THAT THE USE OF THE LICENSED SOFTWARE, DATABASE OR DOCUMENTATION "
    "WILL NOT INFRINGE ANY THIRD PARTY PATENTS, COPYRIGHTS, TRADEMARKS OR "
    "OTHER RIGHTS. The name of Princeton University or Princeton may not "
    "be used in advertising or publicity pertaining to distribution of "
    "the software and/or database. Title to copyright in this software, "
    "database and any associated documentation shall at all times remain "
    "with Princeton University and LICENSEE agrees to preserve same.</p>"
)

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_EN} English'

# ── CSS ────────────────────────────────────────────────────────
# Classes: .ct count line, .sg list box, .sl list, .lg letter group,
# .of offensive box; .mk (core) is the "offensive" badge.
_CSS_FULL = get_css(
    extra_light=(
        '.e{line-height:1.6}'
        f'.ct{{font-size:0.8em;color:{TEXT_SECONDARY[0]};display:block;margin:2px 0 6px}}'
        '.sg{margin:8px 0;padding:8px 10px;background:#f8f8fa;border-radius:6px;'
        'border:1px solid #e5e5ea}'
        '.sl{font-size:1.05em;line-height:1.7;color:#1d1d1f}'
        f'.sl a{{color:{TEXT_LINK[0]};text-decoration:none}}'
        '.sl a:hover{text-decoration:underline}'
        '.lg{margin:0 0 4px}'
        f'.lg b{{font-weight:600;color:{TEXT_SECONDARY[0]};margin-right:6px}}'
        '.of .mk{margin-right:6px}'
        f'.of .sl{{color:{TEXT_SECONDARY[0]}}}'
    ),
    extra_dark=(
        f'.ct{{color:{TEXT_SECONDARY[1]}}}'
        '.sg{background:#2c2c2e;border-color:#38383a}'
        '.sl{color:#f5f5f7}'
        f'.sl a{{color:{TEXT_LINK[1]}}}'
        f'.lg b{{color:{TEXT_SECONDARY[1]}}}'
        f'.of .sl{{color:{TEXT_SECONDARY[1]}}}'
    ),
)

# Classes this dictionary emits. The style block is repeated in every
# article, so core rules for classes Moby never uses (.sn, .pos, .sep...)
# are dropped from it.
_USED_CLASSES = frozenset({'e', 'dir', 'hw', 'mk', 'ct', 'sg', 'sl', 'lg', 'of'})
_RULE_RE = re.compile(r'([^{}]+)\{([^{}]*)\}')


def _prune_css(style_block: str, used: frozenset) -> str:
    """Keep only the rules whose class selectors are all in `used`."""
    m = re.fullmatch(r'<style>(.*)@media\(prefers-color-scheme:dark\)\{(.*)\}</style>',
                     style_block, re.S)
    if not m:
        raise ValueError('unexpected get_css() layout')

    def keep(rules: str) -> str:
        out = []
        for sel, decl in _RULE_RE.findall(rules):
            classes = set(re.findall(r'\.([A-Za-z][\w-]*)', sel))
            if classes <= used:
                out.append(f'{sel}{{{decl}}}')
        return ''.join(out)

    return (f'<style>{keep(m.group(1))}'
            f'@media(prefers-color-scheme:dark){{{keep(m.group(2))}}}</style>')


CSS = _prune_css(_CSS_FULL, _USED_CLASSES)

# Lists with at least this many items are split into letter groups.
GROUP_MIN_ITEMS = 150

# A link whose target only matches the item in a different letter case
# ('Here' -> 'here', 'CAT' -> 'cat') is kept only if the two lists are
# related: the source root is in the target's list, or this share of the
# smaller list is common to both.
CASE_LINK_MIN_OVERLAP = 0.10
# Case-mismatched (item, root) pairs that pass that test through another
# sense of a large list but name something else: the Barb horse ('horse')
# vs barb (barbiturate), the Dart and Lark rockets ('rocket'), the card game
# Pit ('bridge'), the Mark currency ('colon'). Such items link to their own
# "listed under" entry instead.
CASE_LINK_DENY = frozenset({
    ('Barb', 'barb'), ('Dart', 'dart'), ('Lark', 'lark'), ('Pit', 'pit'),
    ('Mark', 'mark'),
})

# ── Offensive terms ───────────────────────────────────────────
# The upstream lists carry no usage labels. Terms in OFFENSIVE_ALWAYS are
# slurs in every sense the lists use; they are flagged wherever they occur.
# Terms in *_CONTEXT have an ordinary sense too (coon = raccoon, fag =
# cigarette or drudge, spade = shovel, queen = monarch, dike = ditch, queer =
# odd or counterfeit, flit = move) and are flagged only in a list that is
# about the slur sense of the SAME kind: one that also holds a person-slur
# trigger of that kind, or two identity anchors of that kind. (A verb such
# as 'jew down' or 'gyp' in the list of 'cut' or 'cheat' says nothing about
# the 'spade' and 'dike' next to it.)
_RACE_TRIGGERS = frozenset({
    'nigger', 'niggra', 'darky', 'jigaboo', 'jungle bunny', 'burrhead',
    'slant-eye', 'yellow man', 'honky', 'ofay', 'whitey', 'paleface',
    'redskin', 'squaw', 'coolie', 'half-breed', 'half breed', 'half-caste',
    'high yellow', 'sambo', 'Chink', 'dago', 'spic', 'wetback', 'greaseball',
    'Krauthead', 'Boche', 'Hunkie',
})
_HOMO_TRIGGERS = frozenset({'faggot', 'bull dyke', 'nance'})
OFFENSIVE_ALWAYS = _RACE_TRIGGERS | _HOMO_TRIGGERS | frozenset({
    # slurs that do not name a person (objects, a verb, a language name)
    'nigger heaven', 'nigger toe', 'niggerhead', 'jew down', 'gyp',
    'Hottentot',
    # disability
    'mongoloid', 'mongoloid idiot', 'mongoloid idiocy', 'mongolism',
    'mongolianism',
    # 'dyke' (with a y) is the slur in all 22 lists that hold it, including
    # the 'tomboy', 'hoyden', 'virago', 'amazon' and 'romp' lists, which have
    # none of the anchors below ('dike', the embankment, stays in context).
    'dyke',
})
_RACE_CONTEXT = frozenset({
    'coon', 'spade', 'gook', 'pygmy', 'Bushman', 'Negro', 'colored person',
    'Oriental', 'red man', 'Red Indian', 'brown man', 'blackfellow',
    'Mister Charley', 'Negrillo', 'Negrito', 'mulatto', 'octoroon',
    'quadroon', 'quintroon', 'griffe', 'mestee', 'mustee', 'half-bred',
    'half blood', 'zambo', 'Kraut', 'Mick', 'Mickey', 'Paddy', 'Guinea',
    'Hunk', 'Hun', 'Jerry', 'frog', 'limey', 'greaser', 'Canuck',
})
_HOMO_CONTEXT = frozenset({
    'fag', 'fairy', 'fruit', 'fruity', 'homo', 'nancy', 'pansy', 'queer',
    'queen', 'dyke', 'dike', 'butch', 'flit', 'gunsel', 'invert', 'swish',
    'sodomite', 'ginger beer',
})
OFFENSIVE_IN_CONTEXT = _RACE_CONTEXT | _HOMO_CONTEXT
_RACE_ANCHORS = frozenset({
    'Caucasian', 'Negro', 'black man', 'white man', 'colored person',
    'Amerind', 'American Indian', 'Australian aborigine',
    'Eurasian', 'mestizo', 'mestiza', 'metis', 'metisse', 'Cape Colored',
})
_HOMO_ANCHORS = frozenset({
    'homosexual', 'lesbian', 'bisexual', 'homophile', 'gay', 'sapphic',
    'sapphist', 'homoerotic', 'homosexualist',
})
_OFFENSIVE_KINDS = (
    (_RACE_TRIGGERS, _RACE_CONTEXT, _RACE_ANCHORS),
    (_HOMO_TRIGGERS, _HOMO_CONTEXT, _HOMO_ANCHORS),
    # 'butch' next to 'dyke' in the lists of mannish women ('tomboy',
    # 'virago'...). Not a homosexual trigger: 'gunsel' in 'virago' is the
    # gunman sense.
    (frozenset({'dyke'}), frozenset({'butch'}), frozenset()),
)
OFFENSIVE_BADGE = '<span class="mk">offensive</span>'


def offensive_items(items: list[str]) -> set[str]:
    """The items of one list that are shown in its 'offensive' group."""
    present = set(items)
    flagged = present & OFFENSIVE_ALWAYS
    for triggers, context, anchors in _OFFENSIVE_KINDS:
        ctx = present & context
        if ctx and (present & triggers or len(present & anchors) >= 2):
            flagged |= ctx
    return flagged


# ── Normalisation ─────────────────────────────────────────────
_SEP_RE = re.compile(r'[\s\-]+')


def norm(s: str) -> str:
    """Case-, hyphen- and space-insensitive form: 'X-ray' -> 'x ray'."""
    return _SEP_RE.sub(' ', s.casefold()).strip()


def norm_cs(s: str) -> str:
    """Hyphen/space-insensitive, case kept: 'X-ray' -> 'X ray'."""
    return _SEP_RE.sub(' ', s).strip()


def solid(s: str) -> str:
    """Closed-up form: 'counter culture' -> 'counterculture'."""
    return _SEP_RE.sub('', s.casefold())


def sort_key(s: str) -> tuple[str, str]:
    return (s.casefold(), s)


def ascii_fold(s: str) -> str:
    return ''.join(c for c in unicodedata.normalize('NFKD', s)
                   if not unicodedata.combining(c))


# ── Parsing ───────────────────────────────────────────────────

def parse_moby(path: Path) -> dict[str, list[str]]:
    """Root word -> its items, upstream order. A root on several lines gets
    the order-preserving union of its lists (with a warning)."""
    entries: dict[str, list[str]] = {}
    duplicates: list[str] = []
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split(',')
            if len(parts) < 2:
                continue
            root = parts[0].strip()
            items = [s.strip() for s in parts[1:] if s.strip()]
            if not root or not items:
                continue
            if root in entries:
                duplicates.append(root)
                seen = set(entries[root])
                entries[root].extend(s for s in items if s not in seen)
            else:
                entries[root] = items
    for root in duplicates:
        print(f"  WARNING: root '{root}' occurs on more than one line; lists merged")
    return entries


def load_oewn() -> tuple[dict, dict[str, set[str]]]:
    """OEWN lemma index (lemma -> pos -> {sense, form, ...}) and, per
    lemma, the synsets it belongs to."""
    lemmas: dict = {}
    for fp in sorted(glob.glob(str(DATA_DIR / OEWN_ENTRY_GLOB))):
        with open(fp, encoding='utf-8') as f:
            lemmas.update(json.load(f))
    synsets_of: dict[str, set[str]] = defaultdict(set)
    for pattern in OEWN_SYNSET_GLOBS:
        for fp in sorted(glob.glob(str(DATA_DIR / pattern))):
            with open(fp, encoding='utf-8') as f:
                for sid, syn in json.load(f).items():
                    for member in syn.get('members', ()):
                        synsets_of[member].add(sid)
    if not lemmas:
        raise SystemExit(f"ERROR: no OEWN {OEWN_ENTRY_GLOB} in {DATA_DIR} "
                         "(scripts/fetch_data.sh wordnet)")
    return lemmas, synsets_of


# ── Cross-links ───────────────────────────────────────────────

class Linker:
    """Decides which list item links to which root-word entry."""

    def __init__(self, entries: dict[str, list[str]]):
        self.keys = entries
        self.by_norm: dict[str, list[str]] = defaultdict(list)
        for k in entries:
            self.by_norm[norm(k)].append(k)
        self.sets = {k: frozenset(norm(s) for s in v) for k, v in entries.items()}
        self.stats: Counter = Counter()

    def related(self, root: str, target: str) -> bool:
        a, b = self.sets[root], self.sets[target]
        if norm(root) in b:
            return True
        return len(a & b) >= CASE_LINK_MIN_OVERLAP * min(len(a), len(b))

    def resolve(self, item: str, root: str, count: bool = True) -> str | None:
        """Root entry that `item` (in the list of `root`) should link to.

        None when there is none, or when the only match differs in letter
        case and its list is unrelated ('Here' the goddess vs 'here'); the
        caller then links such an item to its own "listed under" entry.
        """
        if item in self.keys:
            return item if item != root else None
        cands = [k for k in self.by_norm.get(norm(item), ()) if k != root]
        if not cands:
            return None
        for k in cands:
            if norm_cs(k) == norm_cs(item):        # hyphen/space only
                if count:
                    self.stats['hyphen-space'] += 1
                return k
        for k in cands:
            if (item, k) not in CASE_LINK_DENY and self.related(root, k):
                if count:
                    self.stats['case-related'] += 1
                return k
        if count:
            self.stats['case-unrelated (own entry)'] += 1
        return None

    def matches_entry(self, term: str) -> bool:
        return norm(term) in self.by_norm

    def case_homograph(self, item: str, root: str) -> bool:
        """`item` matches other roots only in a different letter case, and
        none of them is related to `root` ('Here' in 'Aphrodite')."""
        if item in self.keys:
            return False
        if not any(k != root for k in self.by_norm.get(norm(item), ())):
            return False
        return self.resolve(item, root, count=False) is None


# ── Rendering ─────────────────────────────────────────────────

def _initial(s: str) -> str:
    c = s[:1].upper()
    return c if c.isalpha() else '#'


def items_html(items: list[str], link_for) -> str:
    """Comma list of items (already sorted); letter groups when long."""
    def one(s: str) -> str:
        t = link_for(s) if link_for else None
        return entry_link(t, s) if t else esc(s)

    if len(items) < GROUP_MIN_ITEMS:
        return '<span class="sl">' + ', '.join(one(s) for s in items) + '</span>'
    groups: dict[str, list[str]] = {}
    for s in items:
        groups.setdefault(_initial(s), []).append(one(s))
    return ('<div class="sl">'
            + ''.join(f'<p class="lg"><b>{esc(letter)}</b>{", ".join(parts)}</p>'
                      for letter, parts in groups.items())
            + '</div>')


def count_label(n: int) -> str:
    return (f'<span class="ct">{n:,} synonym{"" if n == 1 else "s"} '
            f'and related word{"" if n == 1 else "s"}</span>')


def _groups_html(main: list[str], off: list[str], link_for) -> str:
    """The linked list box, then the unlinked 'offensive' box."""
    out = ''
    if main:
        out += '<div class="sg">' + items_html(main, link_for) + '</div>'
    if off:
        out += ('<div class="sg of">' + OFFENSIVE_BADGE
                + items_html(off, None) + '</div>')
    return out


def root_article(root: str, items: list[str], link_for) -> tuple[str, set[str], bool]:
    """HTML of a root-word entry, the items shown as offensive, and whether
    the root itself carries the 'offensive' badge."""
    flagged = offensive_items(items)
    main = [s for s in items if s not in flagged]
    off = [s for s in items if s in flagged]
    badge = root in OFFENSIVE_ALWAYS or (
        root in OFFENSIVE_IN_CONTEXT and len(off) * 2 >= len(items))
    parts = [f'<span class="dir">{DIR_LABEL}</span>',
             f'<span class="hw">{esc(root)}</span>']
    if badge:
        parts.append(OFFENSIVE_BADGE)
    parts.append(count_label(len(items)))
    parts.append(_groups_html(main, off, link_for))
    return wrap_entry(''.join(parts), CSS), flagged, badge


def listed_under_article(term: str, roots: list[str], badge: bool,
                         offensive_roots: frozenset[str]) -> str:
    """Entry for a term that is not a root word: the roots listing it.
    Roots that are slurs (badged root entries: 'nigger', 'squaw', 'gyp'...)
    go to the unlinked 'offensive' box, and so do context terms the roots
    themselves make clear, by the same rule as a root entry's own list
    ('spade' and 'gook' under 'American Indian', not under 'shovel')."""
    n = len(roots)
    parts = [f'<span class="dir">{DIR_LABEL}</span>',
             f'<span class="hw">{esc(term)}</span>']
    if badge:
        parts.append(OFFENSIVE_BADGE)
    parts.append(f'<span class="ct">Not a main entry · listed under {n:,} '
                 f'entr{"y" if n == 1 else "ies"}</span>')
    flagged = offensive_items(roots) | (offensive_roots & set(roots))
    main = [r for r in roots if r not in flagged]
    off = [r for r in roots if r in flagged]
    parts.append(_groups_html(main, off, lambda r: r))
    return wrap_entry(''.join(parts), CSS)


# ── Redirects: spelling variants ──────────────────────────────

# Closed-up OEWN/list words that are not the spaced root they spell
# ('ragout' is not 'rag out', 'godown' is a warehouse, ...).
SOLID_DENY = frozenset({
    'ragout', 'pinon', 'hemin', 'cutin', 'godown', 'sofar', 'recreate',
    'layby', 'takeaway',
    # a different word from the spaced root: 'inharmony' is discord, not
    # 'in harmony'; 'onto' is not 'on to' (aware of); 'putout' (baseball),
    # 'lowdown' (the facts) are not 'put out', 'low down' (base)
    'inharmony', 'onto', 'putout', 'lowdown',
})

# British spelling rules: (US ending, UK ending), applied to whole keys.
_UK_SUFFIXES = (
    ('ize', 'ise'), ('izes', 'ises'), ('ized', 'ised'), ('izing', 'ising'),
    ('izer', 'iser'), ('izers', 'isers'), ('ization', 'isation'),
    ('izations', 'isations'), ('izable', 'isable'), ('izational', 'isational'),
    ('yze', 'yse'), ('yzed', 'ysed'), ('yzes', 'yses'), ('yzing', 'ysing'),
    ('yzer', 'yser'),
    ('er', 're'), ('ers', 'res'), ('ered', 'red'), ('ering', 'ring'),
    ('ense', 'ence'), ('og', 'ogue'), ('ogs', 'ogues'),
    ('eled', 'elled'), ('eling', 'elling'), ('eler', 'eller'),
    ('elers', 'ellers'), ('aled', 'alled'), ('aling', 'alling'),
    ('elry', 'ellery'), ('elous', 'ellous'),
)
_UK_OR_RE = re.compile(r'or(?=(s|ed|ing|ful|fully|less|able|ably|ite|ites|er|ers)?(\b|$))')
# Rule output that OEWN pairs with the US word but that is another word.
UK_DENY = frozenset({'eagre'})
# British/variant spellings no rule produces: variant -> American key.
UK_PAIRS = {
    'tyre': 'tire', 'tyres': 'tires', 'plough': 'plow', 'mould': 'mold',
    'mouldy': 'moldy', 'smoulder': 'smolder', 'sceptic': 'skeptic',
    'sceptical': 'skeptical', 'scepticism': 'skepticism',
    'aluminium': 'aluminum', 'aeroplane': 'airplane', 'cheque': 'check',
    'kerb': 'curb', 'draught': 'draft', 'draughty': 'drafty',
    'pyjamas': 'pajamas', 'moustache': 'mustache', 'sulphur': 'sulfur',
    'axe': 'ax', 'whisky': 'whiskey', 'cosy': 'cozy', 'artefact': 'artifact',
    'judgement': 'judgment', 'acknowledgement': 'acknowledgment',
    'ageing': 'aging', 'enrol': 'enroll', 'fulfil': 'fulfill',
    'instil': 'instill', 'skilful': 'skillful', 'wilful': 'willful',
    'instalment': 'installment', 'gaol': 'jail', 'practise': 'practice',
    'pretence': 'pretense', 'nought': 'naught', 'jewellery': 'jewelry',
    'grey': 'gray', 'programme': 'program', 'manoeuvre': 'maneuver',
    'storey': 'story', 'speciality': 'specialty', 'doughnut': 'donut',
    'okay': 'OK',
}

# Accented spellings of English loanwords (iOS autocorrect produces them);
# each is emitted only when its unaccented form is an entry. Left out where
# the unaccented key is another word: cañon (canon), lamé (lame), piqué
# (pique), rosé (rose), divorcé/divorcée (divorce, the act).
ACCENTED = (
    'à la carte', 'à la mode', 'appliqué', 'après-ski', 'attaché', 'béchamel',
    'belle époque', 'bête noire', 'blasé', 'bon appétit', 'café', 'café au lait',
    'cause célèbre', 'château', 'châteaux', 'cliché', 'clichéd',
    'communiqué', 'consommé', 'cortège', 'coup d\'état', 'coupé', 'crèche',
    'crème', 'crème de la crème', 'crêpe', 'crêpe de Chine', 'crudités',
    'début', 'débutante', 'déclassé', 'décolletage', 'décolleté', 'décor',
    'dégagé', 'déjà vu', 'démodé', 'dénouement', 'déshabillé', 'détente',
    'distingué', 'doppelgänger', 'éclair', 'éclat',
    'élan', 'élan vital', 'élite', 'émigré', 'entrée', 'entrepôt', 'épée',
    'étude', 'exposé', 'façade', 'fête', 'fiancé', 'fiancée', 'flambé',
    'frappé', 'Fräulein', 'Führer', 'garçon', 'gâteau', 'glacé', 'habitué',
    'idée fixe', 'jalapeño', 'lycée', 'macramé', 'maître d\'',
    'maître d\'hôtel', 'mañana', 'manqué', 'matinée', 'mélange', 'mêlée',
    'ménage', 'ménage à trois', 'métier', 'moiré', 'naïf', 'naïve', 'naïvely',
    'naïveté', 'naïvety', 'née', 'négligé', 'négligée', 'objet d\'art',
    'outré', 'papier-mâché', 'passé', 'pâté', 'pâtisserie', 'pièce de résistance',
    'pied-à-terre', 'piñata', 'plié', 'précis', 'première', 'protégé',
    'protégée', 'purée', 'raison d\'être', 'recherché', 'résumé', 'risqué',
    'rôle', 'roué', 'sauté', 'séance', 'señor', 'señora', 'señorita',
    'smörgåsbord', 'soigné', 'soirée', 'soufflé', 'soupçon', 'tête-à-tête',
    'touché', 'über', 'Übermensch', 'vérité', 'vis-à-vis', 'voilà',
)


def uk_candidates(word: str) -> set[str]:
    out = {word[:-len(us)] + uk for us, uk in _UK_SUFFIXES if word.endswith(us)}
    if 'or' in word:
        out.add(_UK_OR_RE.sub('our', word))
    for i, c in enumerate(word):                 # anemia -> anaemia, fetus -> foetus
        if c == 'e' and i < len(word) - 1:
            out.add(word[:i] + 'ae' + word[i + 1:])
            out.add(word[:i] + 'oe' + word[i + 1:])
    out.discard(word)
    return out


# ── Redirects: inflections ────────────────────────────────────

_O_ES_NOUNS = frozenset({
    'hero', 'potato', 'tomato', 'echo', 'veto', 'torpedo', 'embargo',
    'mosquito', 'domino', 'buffalo', 'volcano', 'tornado', 'cargo', 'motto',
    'grotto', 'mango', 'halo', 'innuendo', 'desperado', 'fresco',
})
_NO_COMPARE = frozenset({
    'only', 'daily', 'weekly', 'monthly', 'yearly', 'hourly', 'nightly',
    'quarterly', 'main', 'chief', 'mere', 'own', 'same', 'sole', 'whole',
    'dead', 'due', 'male', 'female', 'left', 'right', 'top', 'past', 'next',
    'last', 'first', 'prime', 'such', 'very', 'ill', 'more', 'most', 'less',
    'least', 'much', 'many', 'few', 'all', 'both', 'each', 'every', 'some',
    'any', 'no', 'other', 'else', 'former', 'latter', 'inner', 'outer',
    'upper', 'lower', 'utter',
    # not gradable, or the rule form is not a word: compass points, numbers,
    # participles ('born', 'kept'), particles, colours used as nouns...
    'north', 'south', 'east', 'west', 'aft', 'fore', 'in', 'out', 'up',
    'down', 'midway', 'nearby', 'prior', 'undue', 'untrue', 'single',
    'double', 'dual', 'treble', 'null', 'plus', 'real', 'live', 'lone',
    'sundry', 'surd', 'striate', 'skew', 'quits', 'tops', 'nuts', 'bats',
    'worth', 'hearsay', 'hex', 'hick', 'spic', 'fab', 'chic', 'pat', 'trig',
    'brag', 'boon', 'gilt', 'flint', 'bronze', 'brindle', 'beige', 'mauve',
    'taupe', 'cleft', 'clad', 'shod', 'shorn', 'sworn', 'worn', 'blown',
    'born', 'bound', 'broke', 'built', 'drawn', 'gone', 'grown', 'held',
    'kept', 'lit', 'lost', 'paid', 'said', 'spent', 'stuck', 'sunk',
    'highbrow', 'lowbrow', 'cockney', 'churchly', 'knightly', 'deathly',
    'poorly', 'boyish', 'prone', 'wroth', 'fallow', 'fluid', 'seeable',
    # two syllables the vowel count takes for one ('pi-ous', 'loy-al')
    'pious', 'joyous', 'fluent', 'buoyant', 'loyal', 'royal', 'stoic',
    'deist', 'theist', 'naif', 'pliant', 'liable', 'pliable',
    'viable', 'friable', 'manque', 'outre', 'passe', 'triune',
    'i', 'twelve', 'eleven', 'teen', 'twenty', 'thirty', 'forty', 'fifty',
    'sixty', 'seventy', 'eighty', 'ninety', 'yon', 'nee', 'faux', 'het',
    'cyan', 'laic', 'zoic', 'tref', 'duple', 'okay', 'doable', 'payable',
    'milch', 'riant', 'swart', 'blate', 'blear', 'drear', 'holey',
})
# Comparatives are made only for words that are adjectives first of all
# (OEWN adjective senses >= those of any other part of speech), so that
# 'ace', 'boss', 'cut' or 'key' get no 'acest', 'bosser', 'cuttest',
# 'keyest'. These adjectives have more noun or verb senses but compare.
_COMPARE_ANYWAY = frozenset({
    'base', 'blind', 'blond', 'bluff', 'blunt', 'calm', 'choice', 'clear',
    'close', 'cross', 'damp', 'empty', 'fancy', 'fit', 'fleet', 'free',
    'gray', 'hale', 'hip', 'jolly', 'lean', 'pink', 'plump', 'prim', 'round',
    'sage', 'scant', 'scarce', 'slack', 'spruce', 'square', 'squat', 'swift',
    'tame', 'tart', 'tense', 'trim', 'weary', 'drunk',
})
# Verbs stressed on the final -l syllable double the l in American
# spelling too: controlled, compelled (not 'controled', 'compeled').
_STRESS_FINAL_L = frozenset({
    'annul', 'appal', 'cabal', 'compel', 'control', 'corral', 'decontrol',
    'dispel', 'distil', 'enrol', 'enthral', 'excel', 'expel', 'extol',
    'fulfil', 'impel', 'instil', 'patrol', 'propel', 'rebel', 'repel',
})
# Verbs whose British -t past (burnt, dreamt, spelt) is an alternative to
# the regular -ed form, not a replacement for it.
_T_PAST_ALT = frozenset({
    'burn', 'learn', 'dream', 'lean', 'leap', 'spoil', 'spell', 'spill',
    'smell', 'dwell', 'kneel', 'bless', 'gild', 'gird', 'dress', 'mix',
    'misspell', 'unlearn', 'relearn',
})
# Core verbs whose forms OEWN lists only in part.
_EXTRA_FORMS = {
    'be': ('being',), 'have': ('has', 'had', 'having'),
    'do': ('does', 'did', 'done', 'doing'),
}
# OEWN irregular forms that are, first of all, another everyday word: a
# redirect would append e.g. 'diva' to every lookup of 'dive'.
IRREGULAR_DENY = frozenset({
    'dive', 'cola', 'gan', 'reis', 'litai', 'bani', 'dui', 'rove', 'stove',
    'rent', 'gelt', 'stamina', 'bypast',
    # misspelt forms in the OEWN data
    'diaerses', 'diathses', 'carides', 'andtheridia', 'glochidcia', 'araglis',
    'gemboks', 'gembucks', 'madornos', 'bicennaries', 'startsy', 'stotkini',
    'cercariiae', 'filariiae', 'cryings',
    # 'trivia' (trifles) is a root of its own, not the trivium
    'trivia',
})
# An OEWN irregular plural usually stands beside the regular one (cacti /
# cactuses, formulae / formulas, indices / indexes, brethren / brothers,
# pence / pennies), so the regular plural is made as well, except where the
# irregular one replaces it: men, mice, feet, teeth, geese, children, oxen,
# knives, phenomena, and these Latin plurals.
_F_VES = ('alf', 'elf', 'olf', 'eaf', 'oaf', 'ief', 'ife')
_LATIN_PLURAL_ONLY = frozenset({
    'datum', 'erratum', 'ovum', 'addendum', 'corrigendum', 'desideratum',
    'quantum', 'stratum', 'agendum', 'phylum', 'genus', 'stimulus', 'nucleus',
    'locus', 'bacillus', 'alga', 'larva', 'vertebra', 'alumna',
})


def _plural_replaced(lemma: str, listed: list[str]) -> bool:
    for f in listed:
        if ((lemma.endswith('man') and f == lemma[:-3] + 'men')
                or lemma.endswith(('mouse', 'louse', 'foot', 'tooth', 'goose',
                                   'child'))
                or lemma == 'ox'
                or (f.endswith('ves') and lemma.endswith(_F_VES))
                or (lemma.endswith('on') and f.endswith('a'))
                or lemma in _LATIN_PLURAL_ONLY):
            return True
    return False


# -man nouns OEWN gives no plural for take -men (policemen, charwomen),
# except these.
_MAN_S = frozenset({
    'human', 'shaman', 'talisman', 'caiman', 'cayman', 'dolman', 'liman',
    'soman', 'brahman', 'ceriman', 'hanuman', 'hooman', 'roman', 'saman',
    'zaman', 'dragoman', 'ottoman', 'desman', 'doberman', 'leman', 'hetman',
    'ataman', 'walkman',
})
# Nouns with no plural of their own: uncountable ones, and those whose
# plural is the same word (sheep, aircraft).
_NO_PLURAL = frozenset({
    'vermin', 'hoar', 'iodine', 'mud', 'stainless', 'thus', 'overmuch',
    'absurd', 'raw', 'unconscious', 'malnutrition', 'sunlight', 'firewood',
    'dishwater', 'quicksilver', 'kerosene', 'petroleum', 'radium', 'arsenic',
    'niacin', 'riboflavin', 'smallpox', 'diphtheria', 'indigestion',
    'insomnia', 'valor', 'valour', 'might',
    'cattle', 'music', 'information', 'advice', 'furniture', 'equipment',
    'luggage', 'baggage', 'homework', 'housework', 'knowledge', 'traffic',
    'machinery', 'jewelry', 'jewellery', 'clothing', 'poultry', 'livestock',
    'garbage', 'rubbish', 'software', 'scenery', 'wildlife', 'mankind',
    'humankind', 'sheep', 'deer', 'moose', 'swine', 'bison', 'aircraft',
    'spacecraft', 'hovercraft', 'watercraft', 'offspring', 'trout', 'salmon',
    'cod', 'grouse',
})
# -ch said /k/ takes a plain -s (stomachs, monarchs, epochs).
_CH_K = frozenset({
    'stomach', 'monarch', 'epoch', 'eunuch', 'patriarch', 'matriarch',
    'oligarch', 'hierarch', 'heresiarch', 'tetrarch', 'exarch', 'ethnarch',
    'triptych', 'diptych', 'loch', 'tech', 'pentateuch', 'psych', 'synch',
})
# Irregular forms OEWN 2025 does not list (any part of speech).
_EXTRA_IRREGULAR = {
    'woman': ('women',), 'person': ('people', 'persons'), 'alumnus': ('alumni',),
    'oasis': ('oases',), 'bacterium': ('bacteria',),
    'far': ('farther', 'farthest', 'further', 'furthest'),
}
_WORD_RE = re.compile(r'[a-z]+')


def _vowel_groups(w: str) -> int:
    return len(re.findall(r'[aeiouy]+', w))


def _syllables(w: str) -> int:
    n = _vowel_groups(w)
    if w.endswith('e') and not w.endswith(('le', 'ee', 'ye')) and n > 1:
        n -= 1
    return n


def _doubles(w: str) -> bool:
    """One-syllable consonant-vowel-consonant word: stop -> stopped."""
    s = 'q' + w[2:] if w.startswith('qu') else w
    return (_vowel_groups(s) == 1
            and re.search(r'[^aeiou][aeiou][^aeiouwxy]$', s) is not None)


def _s_form(w: str, verb: bool) -> str | None:
    if w in _CH_K:
        return w + 's'
    if w.endswith(('ss', 'us', 'as', 'x', 'z', 'ch', 'sh')):
        if re.search(r'[^aeiou][aeiou]z$', w):
            return w + 'zes'                      # quiz -> quizzes
        return w + 'es'
    if w.endswith('s'):
        return None                               # news, physics, means
    if re.search(r'[^aeiou]y$', w):
        return w[:-1] + 'ies'
    if re.search(r'[^aeiou]o$', w) and (verb or w in _O_ES_NOUNS):
        return w + 'es'
    return w + 's'


def _ed_form(w: str) -> str:
    if w.endswith('e'):
        return w + 'd'
    if re.search(r'[^aeiou]y$', w):
        return w[:-1] + 'ied'
    if _doubles(w):
        return w + w[-1] + 'ed'
    return w + 'ed'


def _ing_form(w: str) -> str:
    if w.endswith('ie'):
        return w[:-2] + 'ying'
    if w.endswith('e') and not w.endswith(('ee', 'ye', 'oe')) and w != 'be':
        return w[:-1] + 'ing'
    if _doubles(w):
        return w + w[-1] + 'ing'
    return w + 'ing'


def _compare_forms(w: str) -> list[str]:
    if w.endswith('ey') and _vowel_groups(w) > 1:  # hokey -> hokier, not grey
        return [w[:-2] + 'ier', w[:-2] + 'iest']
    if w.endswith('e'):
        return [w + 'r', w + 'st']
    if re.search(r'[^aeiou]y$', w):
        return [w[:-1] + 'ier', w[:-1] + 'iest']
    if _doubles(w):
        return [w + w[-1] + 'er', w + w[-1] + 'est']
    return [w + 'er', w + 'est']


def _regular_forms(w: str) -> set[str]:
    """Every form a regular rule could give (to tell irregular forms apart)."""
    out = {_ed_form(w), _ing_form(w), w + 's', w + 'es', w + 'ed', w + 'ing',
           w + w[-1:] + 'ed', w + w[-1:] + 'ing', w + w[-1:] + 'er',
           w + w[-1:] + 'est', w + 'er', w + 'est'}
    s = _s_form(w, True)
    if s:
        out.add(s)
    out.update(_compare_forms(w))
    return out


# A rule-made comparative that OEWN has as a noun or verb of its own is
# usually that other word ('plumber' is not 'more plumb', nor 'stapler',
# 'trigger', 'setter', 'tenner'), so it is skipped, except for these real
# comparatives that happen to be nouns as well.
_NOUN_TOO_COMPARATIVES = frozenset({
    'blinder', 'blither', 'bluffer', 'dearest', 'fresher', 'fuller', 'graver',
    'haler', 'leaner', 'lighter', 'limper', 'loather', 'sparer', 'steeper',
    'warmer',
})


_VERB_FORMS: dict[int, frozenset[str]] = {}


def _verb_forms(lemma_index: dict | None) -> frozenset[str]:
    """Every irregular verb form OEWN lists (known, struck, born...)."""
    if not lemma_index:
        return frozenset()
    key = id(lemma_index)
    if key not in _VERB_FORMS:
        _VERB_FORMS[key] = frozenset(
            f for e in lemma_index.values() for f in e.get('v', {}).get('form', ()))
    return _VERB_FORMS[key]


def _other_word(form: str, lemma_index: dict | None) -> bool:
    """True when `form` is an OEWN noun/verb with no adjective/adverb sense."""
    if not lemma_index or form not in lemma_index or form in _NOUN_TOO_COMPARATIVES:
        return False
    return not set(lemma_index[form]) & {'a', 's', 'r'}


def inflections(lemma: str, oewn_entry: dict,
                lemma_index: dict | None = None) -> list[tuple[str, bool]]:
    """(form, irregular) pairs for a single-word lowercase lemma.

    `lemma_index` (the whole OEWN lemma index) lets the comparative rule
    skip forms that are another word ('plumber', 'stapler').
    """
    forms: dict[str, bool] = {}
    regular = _regular_forms(lemma)

    def add(f: str | None, irregular: bool = False) -> None:
        if (f and f != lemma and _WORD_RE.fullmatch(f)
                and not (irregular and f in IRREGULAR_DENY)):
            forms[f] = forms.get(f, False) or irregular

    # British single-l spellings of -ll verbs double the l: fulfil ->
    # fulfilled (not 'fulfiled'), as do instil, enrol, distil; so do verbs
    # stressed on the final syllable (control, compel, patrol).
    double_l = lemma in _STRESS_FINAL_L or (
        lemma.endswith('l') and not lemma.endswith('ll')
        and bool(lemma_index) and lemma + 'l' in lemma_index)

    n_senses = {pos: len(data.get('sense', ())) for pos, data in oewn_entry.items()}
    adj_senses = n_senses.get('a', 0) + n_senses.get('s', 0)
    adjective_first = adj_senses >= max(
        (n for pos, n in n_senses.items() if pos not in ('a', 's')), default=0)

    extra = _EXTRA_IRREGULAR.get(lemma, ())
    for f in extra:
        add(f, f not in regular)
    for pos, data in oewn_entry.items():
        listed = [f for f in data.get('form', ()) if _WORD_RE.fullmatch(f)]
        for f in listed:
            add(f, f not in regular)
        if pos == 'n':
            # no plural for -ness nouns ('drowsinesses') or mass nouns
            if extra or lemma.endswith('ness') or lemma in _NO_PLURAL:
                pass
            elif listed:
                if not _plural_replaced(lemma, listed):
                    add(_s_form(lemma, verb=False))
            elif lemma.endswith('man') and lemma not in _MAN_S:
                add(lemma[:-3] + 'men', True)
            else:
                add(_s_form(lemma, verb=False))
        elif pos == 'v':
            if lemma in _EXTRA_FORMS:
                for f in _EXTRA_FORMS[lemma]:
                    add(f, f not in regular)
                continue
            add(_s_form(lemma, verb=True))
            # A listed past form replaces the regular one, except the
            # British alternatives: -ll- (travelled) and -t (dreamt).
            alt_only = all(
                (lemma.endswith('l') and f in (lemma + 'led', lemma + 'ling'))
                or (lemma in _T_PAST_ALT and f.endswith('t'))
                for f in listed)
            if not listed or alt_only:
                add(lemma + 'led' if double_l else _ed_form(lemma))
            if not any(f.endswith('ing') for f in listed) or alt_only:
                add(lemma + 'ling' if double_l else _ing_form(lemma))
        elif pos in ('a', 's'):
            # participles ('known', 'struck', 'born') do not compare
            if (listed or extra or lemma in _NO_COMPARE
                    or lemma.endswith(('ed', 'ing'))
                    or (lemma in _verb_forms(lemma_index)
                        and lemma not in _COMPARE_ANYWAY)
                    or not (adjective_first or lemma in _COMPARE_ANYWAY)):
                continue
            syl = _syllables(lemma)
            if syl == 1 or (syl == 2 and lemma.endswith(('y', 'le', 'ow'))):
                for f in _compare_forms(lemma):
                    if not _other_word(f, lemma_index):
                        add(f)
    return sorted(forms.items())


# Phrases: a spaced verb phrase is inflected on its first word when the
# second is one of these ('give up' -> 'gave up', 'kick the bucket' ->
# 'kicked the bucket'); 'dry clean' or 'sweet talk' are left alone.
_PARTICLES = frozenset({
    'up', 'down', 'out', 'off', 'in', 'on', 'over', 'away', 'back',
    'through', 'around', 'round', 'about', 'along', 'aside', 'apart', 'by',
    'forth', 'forward', 'under', 'together', 'after', 'at', 'for', 'from',
    'into', 'onto', 'to', 'with', 'without', 'against', 'across', 'upon',
    'behind', 'ahead', 'past', 'home', 'a', 'an', 'the', 'it', 'one',
    'oneself', 'someone', 'something', 'all',
})
# Noun phrases holding one of these after the first word are not inflected
# ('man-of-war', 'mother-in-law', 'give and take', 'coup de grace').
_FUNCTION_WORDS = frozenset({
    'of', 'in', 'on', 'at', 'to', 'for', 'by', 'with', 'from', 'and', 'or',
    'nor', 'but', 'a', 'an', 'the', 'as', 'into', 'upon', 'over', 'under',
    'de', 'la', 'le', 'les', 'du', 'des', 'en', 'au', 'aux', 'di', 'da',
    'del', 'della', 'el', 'von', 'van', 'der', 'per', 'et', 'y', 'e',
})
_PHRASE_RE = re.compile(r'[A-Za-z]+(?:[ \-][A-Za-z]+)+')


def phrase_inflections(phrase: str, lemma_index: dict) -> list[tuple[str, bool]]:
    """(form, irregular) pairs for a spaced or hyphenated phrase that OEWN
    has as a verb or noun, made by inflecting its head word: 'give up' ->
    'gave up', 'double-check' -> 'double-checked', 'by-product' ->
    'by-products', 'straw man' -> 'straw men', 'tie-up' -> 'tie-ups'."""
    if not _PHRASE_RE.fullmatch(phrase):
        return []
    entry = {**lemma_index.get(phrase.lower(), {}), **lemma_index.get(phrase, {})}
    if not entry:
        return []
    parts = re.split(r'([ \-])', phrase)        # words at even indices
    words = parts[0::2]
    out: dict[str, bool] = {}


    def put(i: int, pos: str) -> None:
        w = words[i]
        e = lemma_index.get(w)
        if not _WORD_RE.fullmatch(w) or not e or pos not in e:
            return
        for f, irregular in inflections(w, {pos: e[pos]}, lemma_index):
            form = ''.join(parts[:2 * i] + [f] + parts[2 * i + 1:])
            out[form] = out.get(form, False) or irregular

    if 'v' in entry:
        if ' ' not in phrase:
            put(len(words) - 1, 'v')             # double-check, x-ray
        elif words[1].lower() in _PARTICLES:
            put(0, 'v')                          # give up, put up with
    proper = any(w != w.lower() and len(w) > 1 for w in words)
    # A hyphenated leading function word is a prefix (by-products,
    # in-migrations); 'the boot', 'in time' are left alone.
    skip = 1 if parts[1] == '-' else 0
    if 'n' in entry and not proper and not any(
            w in _FUNCTION_WORDS for w in words[skip:]):
        listed = [f for f in entry['n'].get('form', ()) if _PHRASE_RE.fullmatch(f)]
        for f in listed:
            out[f] = True
        if not listed:
            if words[-1] in _PARTICLES:
                # tie-ups, put-ons; not passers-by, runners-up, and not
                # 'carrying out' (the act) -> 'carrying outs'
                if ' ' not in phrase and not words[0].endswith('er'):
                    out.setdefault(phrase + 's', False)
            else:
                put(len(words) - 1, 'n')
    out.pop(phrase, None)
    return sorted(out.items())


# ── Assembly ──────────────────────────────────────────────────

class Redirects:
    """@@@LINK records: variant key -> article keys."""

    VARIANT_CATS = ('hyphen', 'twin', 'solid', 'uk', 'accent')
    # Categories added even when the variant is itself a root: the app then
    # shows the variant's own entry first and the target after it
    # ('found' -> found, find; 'cold-blooded' -> cold-blooded, cold blooded).
    HOMOGRAPH_CATS = ('irregular', 'twin')

    def __init__(self, article_keys: set[str], roots: set[str]):
        self.article_keys = article_keys
        self.roots = roots
        self.root_lower = {k.casefold() for k in roots}
        self.display: dict[str, str] = {}
        self.targets: dict[str, dict[str, str]] = defaultdict(dict)

    def add(self, variant: str, target: str, cat: str) -> bool:
        if target not in self.article_keys or variant == target:
            return False
        low = variant.casefold()
        if low == target.casefold():
            return False                          # app already matches it
        if low in self.root_lower and cat not in self.HOMOGRAPH_CATS:
            return False
        self.display.setdefault(low, variant)
        self.targets[low].setdefault(target, cat)
        return True

    def records(self) -> list[tuple[str, str, str]]:
        out = []
        for low, tmap in self.targets.items():
            # A spelling variant of a root beats an inflection ('colours' ->
            # 'colors', not also 'color'); a variant that only reaches a
            # "listed under" entry does not ('travelled' -> 'traveled' and
            # 'travel').
            if any(c in self.VARIANT_CATS and t in self.roots
                   for t, c in tmap.items()):
                tmap = {t: c for t, c in tmap.items() if c in self.VARIANT_CATS}
            for target in sorted(tmap, key=sort_key):
                out.append((self.display[low], target, tmap[target]))
        return out


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if not DATA_FILE.exists():
        print(f"ERROR: {DATA_FILE} not found.")
        print("Download from: https://www.gutenberg.org/files/3202/files/mthesaur.txt")
        sys.exit(1)

    print("Building Moby Thesaurus...")
    print(f"  Source: {DATA_FILE}")

    # ── Phase 1: Parse ──
    entries = parse_moby(DATA_FILE)
    slots = sum(len(v) for v in entries.values())
    print(f"  {len(entries)} root words parsed, {slots} list items")
    if USE_OEWN:
        lemmas, synsets_of = load_oewn()
        print(f"  OEWN: {len(lemmas)} lemmas")
    else:
        lemmas, synsets_of = {}, {}
        print("  OEWN: not used (USE_OEWN = False)")

    linker = Linker(entries)

    # Items per root: no self-reference, no repeats, alphabetical.
    lists: dict[str, list[str]] = {}
    for root, items in entries.items():
        seen: set[str] = set()
        clean = []
        for s in items:
            if s != root and s not in seen:
                seen.add(s)
                clean.append(s)
        lists[root] = sorted(clean, key=sort_key)
    self_refs = sum(1 for r, v in entries.items() if r in v)

    # Terms that occur only inside lists (not a root even ignoring case,
    # hyphens and spaces) get a "listed under" entry. So do case homographs
    # of a root that some list uses in an unrelated sense ('Here', 'CAT',
    # 'China', 'bo'): their own key sits next to the root's, and the app
    # shows the exact-case record first.
    homographs = {s for root, items in lists.items() for s in items
                  if linker.case_homograph(s, root)}
    listed_under: dict[str, list[str]] = defaultdict(list)
    for root, items in lists.items():
        for s in items:
            if s in homographs or not linker.matches_entry(s):
                listed_under[s].append(root)
    for roots in listed_under.values():
        roots.sort(key=sort_key)
    article_keys = set(entries) | set(listed_under)

    # ── Phase 2: Articles ──
    flagged_count: Counter = Counter()

    def link_for(root):
        def f(item):
            t = linker.resolve(item, root)
            if t is None and item in listed_under:
                t = item
            return t
        return f

    records: list[tuple[str, str]] = []
    total_items = 0
    badged_roots: set[str] = set()
    for root in sorted(entries, key=sort_key):
        html, flagged, badge = root_article(root, lists[root], link_for(root))
        flagged_count.update(flagged)
        total_items += len(lists[root])
        records.append((root, html))
        if badge:
            badged_roots.add(root)
    n_roots = len(records)
    badged_roots = frozenset(badged_roots)

    for term in sorted(listed_under, key=sort_key):
        roots = listed_under[term]
        badge = term in OFFENSIVE_ALWAYS or (
            term in OFFENSIVE_IN_CONTEXT and flagged_count[term] * 2 >= len(roots))
        records.append((term, listed_under_article(term, roots, badge, badged_roots)))
    n_listed = len(records) - n_roots

    # ── Phase 3: Redirects ──
    red = Redirects(article_keys, set(entries))
    added: Counter = Counter()
    by_norm = linker.by_norm
    terms = {s for v in entries.values() for s in v}

    # Hyphen/space spellings attested in the lists or in OEWN.
    for t in sorted(terms | set(lemmas), key=sort_key):
        for k in by_norm.get(norm(t), ()):
            if red.add(t, k, 'hyphen'):
                added['hyphen'] += 1
    # Roots that differ only in hyphen/space ('cold blooded', 'cold-blooded';
    # 17 pairs) point at each other, so either spelling shows both lists.
    for k in sorted(entries, key=sort_key):
        for other in by_norm[norm(k)]:
            if other != k and red.add(k, other, 'twin'):
                added['twin'] += 1
    # Closed-up spellings ('counterculture' -> 'counter culture').
    by_solid: dict[str, list[str]] = defaultdict(list)
    for k in entries:
        if ' ' in k or '-' in k:
            by_solid[solid(k)].append(k)
    for t in sorted(terms | set(lemmas)):
        if (_WORD_RE.fullmatch(t) and t not in SOLID_DENY and t in by_solid):
            for k in by_solid[t]:
                if red.add(t, k, 'solid'):
                    added['solid'] += 1
    # British spellings: a rule variant of an American key that OEWN puts
    # in a synset with it, plus the hand list.
    for k in sorted(article_keys):
        if not re.fullmatch(r"[a-z][a-z \-]*", k):
            continue
        for c in sorted(uk_candidates(k)):
            if (c not in UK_DENY and c in lemmas
                    and synsets_of.get(c, set()) & synsets_of.get(k, set())):
                if red.add(c, k, 'uk'):
                    added['uk'] += 1
    for variant, us in UK_PAIRS.items():
        if red.add(variant, us, 'uk'):
            added['uk'] += 1
    # Accented loanword spellings.
    article_by_lower: dict[str, list[str]] = defaultdict(list)
    for k in article_keys:
        article_by_lower[k.casefold()].append(k)
    for word in ACCENTED:
        for k in article_by_lower.get(ascii_fold(word).casefold(), ()):
            if red.add(word, k, 'accent'):
                added['accent'] += 1
    # Inflected forms of every entry (root words and "listed under" terms:
    # 'wished' -> 'wish'), of the British and closed-up spellings above, and
    # of spaced or hyphenated phrases ('gave up', 'X-rays', 'by-products').
    sources = {(k, k) for k in article_keys}
    for low, tmap in red.targets.items():
        for target, cat in tmap.items():
            if cat in ('hyphen', 'twin', 'solid', 'uk'):
                sources.add((red.display[low], target))
    for lemma, target in sorted(sources):
        if _WORD_RE.fullmatch(lemma):
            entry = lemmas.get(lemma)
            forms = inflections(lemma, entry, lemmas) if entry else []
        else:
            forms = phrase_inflections(lemma, lemmas)
        for form, irregular in forms:
            if irregular:
                ok = red.add(form, target, 'irregular')
            else:
                ok = form.casefold() not in article_by_lower or form in listed_under
                ok = ok and red.add(form, target, 'inflection')
            if ok:
                added['irregular' if irregular else 'inflection'] += 1

    redirect_rows = red.records()
    report = os.environ.get('MOBY_REDIRECT_REPORT')   # maintainer aid
    if report:
        with open(report, 'w', encoding='utf-8') as f:
            f.writelines(f'{k}\t{t}\t{c}\n' for k, t, c in redirect_rows)
    for key, target, _cat in redirect_rows:
        records.append((key, f'@@@LINK={target}'))
    n_redirects = len(redirect_rows)
    cat_counts = Counter(c for _k, _t, c in redirect_rows)

    print(f"  {n_roots} root-word entries ({total_items} items; "
          f"{self_refs} self-references dropped)")
    print(f"  {n_listed} 'listed under' entries for list-only terms")
    print(f"  {n_redirects} redirects: "
          + ', '.join(f'{c} {n}' for c, n in sorted(cat_counts.items())))
    print(f"  links: {dict(linker.stats)}")
    print(f"  offensive items: {sum(flagged_count.values())} in "
          f"{len(flagged_count)} distinct terms")

    # ── Phase 4: Write MDict source ──
    # Articles first, then redirects, so that for a key that is both
    # ('tried': listed-under entry + inflection of 'try') the entry comes first.
    txt_path = OUTPUT_DIR / "moby_thesaurus_entries.txt"
    print(f"  Writing → {txt_path}...")
    records = [r for _i, r in sorted(enumerate(records),
                                     key=lambda x: (sort_key(x[1][0]), x[0]))]
    with open(txt_path, 'w', encoding='utf-8') as f:
        for key, body in records:
            f.write(f"{key}\n{body}\n</>\n")
    count = len(records)
    print(f"  {count} records")

    # ── Phase 5: Pack MDX ──
    distinct_terms = len({s for v in entries.values() for s in v})
    mdx_path = OUTPUT_DIR / "Moby-Thesaurus-EN.mdx"
    added_by = (f"an entry for each of the {n_listed:,} terms that appear only "
                "inside the lists, showing the root words that list them, and "
                "redirects from "
                + ("inflected forms and from British, hyphenated and accented "
                   if USE_OEWN else "hyphenated, British and accented ")
                + "spellings")
    description = (
        "<p><b>Moby Thesaurus II</b></p>"
        f"<p>Grady Ward's English thesaurus (American spelling): {n_roots:,} root "
        f"words, each with a list of synonyms and related words; {slots:,} list "
        f"items in all ({distinct_terms:,} distinct terms).</p>"
        f"<p>Added by OpenMDict: {added_by}. Lists are sorted alphabetically. "
        "Known slurs are labelled <i>offensive</i>, listed separately and not "
        "linked; this older source has no usage labels and may contain other "
        "dated or offensive terms.</p>"
        "<p><b>Public Domain</b> by grant from the author, January 2001. Source: "
        "<a href='https://www.gutenberg.org/ebooks/3202'>Project Gutenberg "
        "eBook #3202</a>. Converted to MDict and reformatted by OpenMDict.</p>"
        + (OEWN_NOTICE if USE_OEWN else "")
    )
    inputs = [DATA_FILE]
    if USE_OEWN:
        inputs += [Path(p) for p in sorted(glob.glob(str(DATA_DIR / OEWN_ENTRY_GLOB)))]
    success, size_mb, _ = pack_mdx(txt_path, "Moby Thesaurus II", description,
                                   mdx_path, inputs=inputs)
    if not success:
        sys.exit(1)
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="Moby Thesaurus II",
        description=(f"English thesaurus (American spelling): {n_roots:,} root words "
                     "with about 2.5 million synonyms and related words, plus an "
                     "entry for every listed term. Public domain"
                     + ("; word-form redirects from Open English WordNet (CC BY 4.0)."
                        if USE_OEWN else ".")),
        direction={"src": "EN", "dest": ["EN"]},
        entries=count,
        license=("LicenseRef-Public-Domain AND CC-BY-4.0 AND LicenseRef-WordNet-3.0"
                 if USE_OEWN else "LicenseRef-Public-Domain"),
        data_source="Moby Thesaurus II (Grady Ward)",
        tier=3,
    )

    # ── Preview ──
    by_key: dict[str, list[str]] = defaultdict(list)
    for key, body in records:
        by_key[key].append(body)
    samples = ['happy', 'walk', 'cut', 'aerospace', 'CAT', 'helter skelter',
               'okay', 'boy', 'lesbian', 'fast']
    previews = [b for w in samples for b in by_key.get(w, ()) if not b.startswith('@@@')]
    preview_path = OUTPUT_DIR / "moby_thesaurus_preview.html"
    generate_preview(previews, preview_path, 'Moby Thesaurus II — preview')


if __name__ == '__main__':
    main()
