#!/usr/bin/env python3
"""
Build bilingual MDX dictionaries from WikDict SQLite data.

Supports:
  - EN↔XX: fr, de, es, ru, pt, it, tr, la, el (9 languages)
  - Cross-language: de-ru, es-pt, fr-es, fr-ru (4 pairs)

Each (headword, direction) pair produces a separate entry with a
flag-emoji suffix on the lookup key, e.g. "comer 🇬🇧" and "comer 🇪🇸".

Usage:
    python build_wikdict_mdx.py               # build all EN↔XX
    python build_wikdict_mdx.py fr             # build French EN↔FR only
    python build_wikdict_mdx.py de-ru fr-es    # build cross-language pairs
    python build_wikdict_mdx.py --cross        # build all cross-language pairs
    python build_wikdict_mdx.py --all          # build everything

Input:  ../data/wikdict/{xx-yy}.sqlite3
Output: ../output/WikDict-{XX}-{YY}/WikDict-{XX}-{YY}.mdx
"""

import re
import sys
import sqlite3
from pathlib import Path
from collections import defaultdict, OrderedDict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, GLOSS, ORDERED_LIST, DOMAIN_BADGE
from shared.html import esc
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data" / "wikdict"
OUTPUT_DIR = SCRIPT_DIR.parent / "output"

# ── Language definitions ───────────────────────────────────────

LANGUAGES = {
    'en': {
        'code': 'en',
        'name_en': 'English',
        'name_native': 'English',
        'flag': '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8',  # 🇬🇧🇺🇸
    },
    'fr': {
        'code': 'fr',
        'name_en': 'French',
        'name_native': 'Français',
        'flag': '\U0001F1EB\U0001F1F7',  # 🇫🇷
    },
    'de': {
        'code': 'de',
        'name_en': 'German',
        'name_native': 'Deutsch',
        'flag': '\U0001F1E9\U0001F1EA',  # 🇩🇪
    },
    'es': {
        'code': 'es',
        'name_en': 'Spanish',
        'name_native': 'Español',
        'flag': '\U0001F1EA\U0001F1F8',  # 🇪🇸
    },
    'ru': {
        'code': 'ru',
        'name_en': 'Russian',
        'name_native': 'Русский',
        'flag': '\U0001F1F7\U0001F1FA',  # 🇷🇺
    },
    'pt': {
        'code': 'pt',
        'name_en': 'Portuguese',
        'name_native': 'Português',
        'flag': '\U0001F1F5\U0001F1F9\U0001F1E7\U0001F1F7',  # 🇵🇹🇧🇷
    },
    'it': {
        'code': 'it',
        'name_en': 'Italian',
        'name_native': 'Italiano',
        'flag': '\U0001F1EE\U0001F1F9',  # 🇮🇹
    },
    'tr': {
        'code': 'tr',
        'name_en': 'Turkish',
        'name_native': 'Türkçe',
        'flag': '\U0001F1F9\U0001F1F7',  # 🇹🇷
    },
    'la': {
        'code': 'la',
        'name_en': 'Latin',
        'name_native': 'Latina',
        'flag': '\U0001F3DB\uFE0F',  # 🏛️
    },
    'el': {
        'code': 'el',
        'name_en': 'Greek',
        'name_native': 'Ελληνικά',
        'flag': '\U0001F1EC\U0001F1F7',  # 🇬🇷
    },
}

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸

# ── Cross-language pairs ──────────────────────────────────────
# Each tuple (a, b) builds a bidirectional WikDict-{A}-{B}.mdx
# from {a}-{b}.sqlite3 and {b}-{a}.sqlite3

CROSS_PAIRS = [
    ('de', 'ru'),   # German ↔ Russian
    ('es', 'pt'),   # Spanish ↔ Portuguese
    ('fr', 'es'),   # French ↔ Spanish
    ('fr', 'ru'),   # French ↔ Russian
]

# ── POS normalization ──────────────────────────────────────────
# Maps raw POS strings (lowercased, from lexentry field) to display tags

POS_MAP = {
    # English (en-xx databases)
    'noun': 'n.', 'verb': 'v.', 'adjective': 'adj.', 'adverb': 'adv.',
    'preposition': 'prep.', 'conjunction': 'conj.', 'interjection': 'interj.',
    'pronoun': 'pron.', 'proper_noun': 'proper n.', 'suffix': 'suffix',
    'prefix': 'prefix', 'particle': 'part.', 'phrase': 'phrase',
    'prepositional_phrase': 'prep. phr.', 'proverb': 'proverb',
    'symbol': 'sym.', 'article': 'art.', 'determiner': 'det.',
    'numeral': 'num.', 'postposition': 'postp.', 'interfix': 'interfix',

    # German (de-en)
    'substantiv': 'n.', 'adjektiv': 'adj.', 'interjektion': 'interj.',
    'eigenname': 'proper n.', 'redewendung': 'phrase', 'sprichwort': 'proverb',
    'abkürzung': 'abbr.', 'wortverbindung': 'phrase',
    'possessivpronomen': 'pron.', 'grußformel': 'interj.',
    'nachname': 'proper n.', 'toponym': 'proper n.',
    'gebundenes_lexem': 'affix', 'merkspruch': 'phrase',
    'formel': 'phrase', 'präfix': 'prefix', 'suffixoid': 'suffix',
    'präfixoid': 'prefix',

    # French (fr-en)
    'nom': 'n.', 'adj': 'adj.', 'verb': 'v.', 'adv': 'adv.',
    'adjectif': 'adj.', 'verbe': 'v.', 'adverbe': 'adv.',
    'conjonction': 'conj.', 'préposition': 'prep.', 'pronom': 'pron.',
    'interjection': 'interj.', 'nompr': 'proper n.', 'prénom': 'proper n.',
    'nom_de_famille': 'proper n.', 'patronyme': 'proper n.',
    'locutionphrase': 'phrase', 'locution_phrase': 'phrase',
    'onomatopée': 'interj.', 'article_indéfini': 'art.',
    'article_défini': 'art.', 'article_partitif': 'art.',
    'pronom_personnel': 'pron.', 'pronom_indéfini': 'pron.',
    'pronom_relatif': 'pron.', 'pronom_démonstratif': 'pron.',
    'pronom_interrogatif': 'pron.', 'pronom_possessif': 'pron.',
    'adjectif_indéfini': 'adj.', 'adjectif_numéral': 'num.',
    'adjectif_interrogatif': 'adj.', 'adjectif_possessif': 'adj.',
    'adverbe_interrogatif': 'adv.', 'adverbe_relatif': 'adv.',
    'conjonction_de_coordination': 'conj.',
    'variante_typographique': '',
    'proverbe': 'proverb',

    # Spanish (es-en)
    'sustantivo': 'n.', 'sustantivo_masculino': 'n.m.',
    'sustantivo_femenino': 'n.f.',
    'sustantivo_masculino_y_femenino': 'n.m/f.',
    'sustantivo_femenino_y_masculino': 'n.f/m.',
    'sustantivo_propio': 'proper n.',
    'adjetivo': 'adj.', 'verbo': 'v.', 'verbo_transitivo': 'v.t.',
    'verbo_intransitivo': 'v.i.', 'verbo_pronominal': 'v.pron.',
    'verbo_auxiliar': 'v.aux.',
    'adverbio_de_modo': 'adv.', 'adverbio_de_tiempo': 'adv.',
    'adverbio_de_cantidad': 'adv.',
    'interjección': 'interj.',
    'locución': 'phrase', 'locución_adjetiva': 'adj. phr.',
    'locución_adverbial': 'adv. phr.', 'locución_conjuntiva': 'conj. phr.',
    'locución_prepositiva': 'prep. phr.', 'locución_sustantiva': 'n. phr.',
    'prefijo': 'prefix', 'sufijo': 'suffix', 'sufijo_flexivo': 'suffix',
    'refrán': 'proverb',

    # Russian (ru-en)
    'сущ': 'n.', 'гл': 'v.', 'прил': 'adj.', 'мест': 'pron.',
    'числ': 'num.', 'деепр': 'v.', 'прич': 'adj.',
    'predic': 'pred.', 'intro': 'interj.', 'onomatop': 'interj.',
    'part': 'part.', 'prep': 'prep.', 'conj': 'conj.',
    'interj': 'interj.', 'adv': 'adv.',
    'фам': 'proper n.',

    # Portuguese (pt-en)
    'substantivo': 'n.', 'adjetivo': 'adj.', 'verbo': 'v.',
    'advérbio': 'adv.',

    # Italian (it-en)
    'nome': 'n.', 'sost': 'n.', 'agg': 'adj.', 'verb': 'v.',
    'avv': 'adv.', 'cong': 'conj.', 'inter': 'interj.',
    'pronome': 'pron.', 'pron_dim': 'pron.', 'pron_poss': 'pron.',
    'art': 'art.', 'espr': 'phrase', 'acron': 'abbr.',
    'agg_num': 'num.', 'agg_poss': 'adj.',
    'loc_agg': 'adj. phr.', 'loc_avv': 'adv. phr.',
    'loc_cong': 'conj. phr.', 'loc_inter': 'interj.',
    'loc_nom': 'n. phr.', 'loc_verb': 'v. phr.',
    'pref': 'prefix', 'suff': 'suffix',

    # Turkish (tr-en)
    'ad': 'n.', 'eylem': 'v.', 'belirteç': 'adv.',
    'bağlaç': 'conj.', 'edat': 'prep.', 'ünlem': 'interj.',
    'adıl': 'pron.', 'ön_ad': 'adj.', 'ön_ek': 'prefix',
    'son_ek': 'suffix', 'özel_ad': 'proper n.', 'özel_isim': 'proper n.',
    'deyim': 'phrase', 'atasözü': 'proverb', 'ifade': 'phrase',
    'isim': 'n.',

    # Latin (la-en)
    'nomen': 'n.', 'nomensubst': 'n.', 'substantivum': 'n.',
    'nomenadj': 'adj.', 'adiectivum': 'adj.',
    'verbum': 'v.', 'verbumtr': 'v.t.', 'verbumintr': 'v.i.',
    'intransitivum': 'v.i.',
    'adverbium': 'adv.', 'praepositio': 'prep.', 'praep': 'prep.',
    'coniunctio': 'conj.', 'interiectio': 'interj.',
    'pronomen': 'pron.', 'participium': 'part.',
    'nomenprop': 'proper n.', 'proprium': 'proper n.',
    'numerus': 'num.', 'cardinalis': 'num.', 'ordinalis': 'num.',
    'proverbium': 'proverb',

    # Greek (el-en)
    'ουσιαστικό': 'n.', 'επίθετο': 'adj.', 'ρήμα': 'v.',
    'επίρρημα': 'adv.', 'πρόθεση': 'prep.', 'σύνδεσμος': 'conj.',
    'επιφώνημα': 'interj.', 'αντωνυμία': 'pron.', 'μετοχή': 'part.',
    'άρθρο': 'art.', 'μόριο': 'part.', 'αριθμητικό': 'num.',
    'κύριο_όνομα': 'proper n.', 'πρόθημα': 'prefix', 'επίθημα': 'suffix',
    'έκφραση': 'phrase', 'παροιμία': 'proverb', 'σύμβολο': 'sym.',
    'πολυλεκτικός_όρος': 'phrase', 'πρόσφυμα': 'affix',
    'συντομομορφή': 'abbr.', 'ένθημα': 'infix',
    'μεταγραφή': '',
    'μορφή_ουσιαστικού': 'n.', 'μορφή_ρήματος': 'v.',
    'μορφή_επιθέτου': 'adj.', 'μορφή_αντωνυμίας': 'pron.',
    'μορφή_μετοχής': 'part.', 'μορφή_κυρίου_ονόματος': 'proper n.',
    'μορφή_πολυλεκτικού_όρου': 'phrase',
}


def extract_pos(lexentry: str) -> str:
    """Extract POS from lexentry like 'eng/hello__Interjection__1' or 'fra/maison__adj__1'."""
    if not lexentry or '__' not in lexentry:
        return ''
    # Split on __ and get the POS part (second segment)
    parts = lexentry.split('__')
    if len(parts) >= 2:
        raw_pos = parts[-2] if len(parts) == 3 else parts[1]
        raw_pos = raw_pos.strip().lower()
        # Handle the case where first segment contains '/'
        if '/' in raw_pos:
            raw_pos = raw_pos.split('/')[-1]
        return POS_MAP.get(raw_pos, '')
    return ''


def parse_sense_definition(sense_text: str) -> tuple:
    """
    Parse domain/context tags from sense definition.

    Spanish-style: "Juegos| En los juegos de mesa..."
    English-style: "(chemistry, medicine) A compound..."

    Returns: (domain_tags: list[str], clean_definition: str)
    """
    if not sense_text:
        return [], ''

    # Pattern 1: Pipe-delimited domains (common in non-English Wiktionary)
    # "Dominio1, dominio2| Definition text"
    pipe_match = re.match(r'^([A-ZÁ-Úa-zá-ú][^|]{0,80})\|\s*(.+)$', sense_text, re.DOTALL)
    if pipe_match:
        domain_str, definition = pipe_match.groups()
        # Skip if it looks like template markup (contains = or \n or {)
        if '=' not in domain_str and '\n' not in domain_str and '{' not in domain_str:
            domains = [d.strip() for d in domain_str.split(',') if d.strip()]
            if domains and all(len(d) < 40 for d in domains):
                return domains, definition.strip()

    # Pattern 2: Parenthetical domains (common in English definitions)
    # "(chemistry, medicine) Definition text"
    paren_match = re.match(r'^\(([^)]{1,80})\)\s+(.+)$', sense_text, re.DOTALL)
    if paren_match:
        domain_str, definition = paren_match.groups()
        if '=' not in domain_str and '\n' not in domain_str:
            domains = [d.strip() for d in domain_str.split(',') if d.strip()]
            if domains and all(len(d) < 40 for d in domains):
                return domains, definition.strip()

    return [], sense_text


# ── HTML generation ────────────────────────────────────────────

CSS = get_css(
    GLOSS, ORDERED_LIST, DOMAIN_BADGE,
    extra_light=(
        '.df{font-size:0.85em;color:#6e6e73;margin:6px 0 2px;padding:4px 0 4px 10px;'
        'border-left:3px solid #d1d1d6;font-style:italic;line-height:1.4}'
    ),
    extra_dark='.df{color:#98989d;border-color:#48484a}',
)


def clean_translation(trans: str) -> str:
    """Clean WikDict translation markup like [[d']]eau → d'eau."""
    trans = re.sub(r'\[\[([^\]]*)\]\]', r'\1', trans)
    return trans.strip()


def build_section_html(pos_groups: list) -> str:
    """
    Build HTML for one direction (e.g., English → French).

    pos_groups: list of (pos, glosses, definition, domain_tags)
    """
    parts = []

    for pos, glosses, defn, domains in pos_groups:
        parts.append('<div class="sn">')

        # Header row: POS badge + domain badges
        header_parts = []
        if pos:
            header_parts.append(f'<span class="pos">{esc(pos)}</span>')
        for dm in domains:
            header_parts.append(f'<span class="dm">{esc(dm)}</span>')
        if header_parts:
            parts.append(f'<div class="sn-hd">{"".join(header_parts)}</div>')

        # Glosses
        if len(glosses) == 1:
            parts.append(f'<span class="gl">{esc(glosses[0])}</span>')
        else:
            gl_html = ''.join(f'<li>{esc(g)}</li>' for g in glosses)
            parts.append(f'<ol class="d">{gl_html}</ol>')

        # Definition hint as blockquote
        if defn:
            parts.append(f'<div class="df">{esc(defn)}</div>')

        parts.append('</div>')

    return ''.join(parts)


def make_entry_html(headword: str, dir_label: str, pos_groups: list) -> str:
    """
    Build complete entry HTML for a single direction.

    headword: bare word (no flag emoji)
    dir_label: e.g. "🇬🇧 English → Español 🇪🇸"
    pos_groups: list of (pos, glosses, definition, domain_tags)
    """
    inner = f'<span class="dir">{esc(dir_label)}</span>'
    inner += f'<span class="hw">{esc(headword)}</span>'
    inner += build_section_html(pos_groups)
    return f'{CSS}<div class="e">{inner}</div>'


# ── Data loading ───────────────────────────────────────────────

def load_translations(db_path: Path) -> dict:
    """
    Load translations from WikDict SQLite.

    Returns: dict[headword] → list of (pos, glosses, definition, score)
    """
    if not db_path.exists():
        print(f"  WARNING: {db_path} not found, skipping")
        return {}

    db = sqlite3.connect(str(db_path))
    c = db.cursor()

    entries = defaultdict(list)

    c.execute('''
        SELECT lexentry, sense_num, sense, written_rep, trans_list, score
        FROM translation
        WHERE is_good = 1
        ORDER BY written_rep, score DESC
    ''')

    for lexentry, sense_num, sense_def, headword, trans_list, score in c.fetchall():
        if not headword or not trans_list:
            continue

        pos = extract_pos(lexentry)

        # Parse translations (pipe-separated)
        glosses = [clean_translation(t) for t in trans_list.split(' | ') if t.strip()]
        if not glosses:
            continue

        entries[headword].append((pos, glosses, sense_def, score))

    db.close()
    return dict(entries)


def organize_senses(raw_senses: list) -> list:
    """
    Organize and deduplicate senses into POS-grouped display blocks.

    Input: list of (pos, glosses, definition, score) sorted by score DESC
    Output: list of (pos, merged_glosses, clean_definition, domain_tags) — one per POS
    """
    # Group by POS, preserving order of first appearance
    by_pos = OrderedDict()
    for pos, glosses, defn, score in raw_senses:
        key = pos or ''
        if key not in by_pos:
            by_pos[key] = {'senses': [], 'best_def': None, 'best_score': 0}
        by_pos[key]['senses'].append((glosses, defn, score))

        # Keep best definition (highest score, non-None)
        if defn and score > by_pos[key]['best_score']:
            by_pos[key]['best_def'] = defn
            by_pos[key]['best_score'] = score

    result = []
    seen_all = set()

    for pos, data in by_pos.items():
        # Score each unique translation by frequency and max score
        gloss_scores = defaultdict(float)
        for glosses, defn, score in data['senses']:
            for g in glosses:
                gl = g.lower()
                # Boost by score; each additional appearance adds base score
                gloss_scores[gl] = max(gloss_scores[gl], score) + 1

        # Collect unique glosses, keeping original case from first appearance
        gloss_canonical = {}
        for glosses, defn, score in data['senses']:
            for g in glosses:
                gl = g.lower()
                if gl not in gloss_canonical:
                    gloss_canonical[gl] = g

        # Sort by combined score descending, filter already-seen
        ranked = sorted(gloss_canonical.keys(), key=lambda gl: -gloss_scores[gl])
        final_glosses = []
        for gl in ranked:
            if gl not in seen_all:
                seen_all.add(gl)
                final_glosses.append(gloss_canonical[gl])
            if len(final_glosses) >= 6:
                break

        if not final_glosses:
            continue

        # Parse domain tags from definition
        defn = data['best_def']
        domains, clean_defn = parse_sense_definition(defn) if defn else ([], '')
        if clean_defn and len(clean_defn) > 200:
            clean_defn = clean_defn[:197] + '…'
        result.append((pos, final_glosses, clean_defn, domains))

    return result[:6]  # Max 6 POS groups


# ── Main build logic ───────────────────────────────────────────

def build_language(lang_code: str):
    """
    Build TWO separate unidirectional MDX files for a language pair:
      - WikDict-{XX}-EN.mdx  (XX headwords → English definitions)
      - WikDict-EN-{XX}.mdx  (English headwords → XX definitions)
    """
    lang = LANGUAGES[lang_code]
    code = lang['code']
    CODE = code.upper()
    name_en = lang['name_en']
    name_native = lang['name_native']
    flag = lang['flag']

    print(f"\n{'='*60}")
    print(f"Building WikDict {name_en}↔English (split into 2 MDX files)")
    print(f"{'='*60}")

    # Load both directions from SQLite
    en_xx_path = DATA_DIR / f"en-{code}.sqlite3"
    xx_en_path = DATA_DIR / f"{code}-en.sqlite3"

    print(f"Loading EN→{CODE} from {en_xx_path.name}...")
    en_to_xx = load_translations(en_xx_path)
    print(f"  {len(en_to_xx)} English headwords")

    print(f"Loading {CODE}→EN from {xx_en_path.name}...")
    xx_to_en = load_translations(xx_en_path)
    print(f"  {len(xx_to_en)} {name_en} headwords")

    results = []

    # ── File 1: WikDict-{XX}-EN.mdx (XX → English) ──
    dict_dir_1 = OUTPUT_DIR / f"WikDict-{CODE}-EN"
    dict_dir_1.mkdir(parents=True, exist_ok=True)
    txt_1 = dict_dir_1 / f"wikdict_{code}_en_entries.txt"

    print(f"\n--- {CODE}→EN direction ---")
    count_1 = 0
    with open(txt_1, 'w', encoding='utf-8') as f:
        for hw in sorted(xx_to_en.keys(), key=str.lower):
            groups = organize_senses(xx_to_en[hw])
            if groups:
                dir_label = f'{flag} {name_native} → English {FLAG_EN}'
                html = make_entry_html(hw, dir_label, groups)
                f.write(f"{hw}\n{html}\n</>\n")
                count_1 += 1
    print(f"  {count_1} entries written")

    mdx_path_1 = dict_dir_1 / f"WikDict-{CODE}-EN.mdx"
    desc_1 = (
        f"<p><b>WikDict {name_en}-English</b></p>"
        f"<p>{name_en} → English dictionary extracted from Wiktionary.</p>"
        f"<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/3.0/'>CC-BY-SA 3.0</a>.</p>"
        f"<p>Source: <a href='https://www.wikdict.com/'>WikDict</a></p>"
    )
    success_1, size_1, _ = pack_mdx(txt_1, f"WikDict {name_en}-English", desc_1, mdx_path_1)
    if success_1:
        print(f"  ✓ {mdx_path_1.name}: {size_1:.1f} MB ({count_1} entries)")
        results.append((mdx_path_1, count_1))
        write_catalog_metadata(
            mdx_path=mdx_path_1,
            display_name=f"WikDict {name_en}-English",
            description=f"{name_en}-English dictionary extracted from Wiktionary via WikDict.",
            direction={"src": CODE, "dest": ["EN"]},
            entries=count_1,
            license="CC-BY-SA 3.0",
            data_source="WikDict",
            tier=3,
        )

    # ── File 2: WikDict-EN-{XX}.mdx (English → XX) ──
    dict_dir_2 = OUTPUT_DIR / f"WikDict-EN-{CODE}"
    dict_dir_2.mkdir(parents=True, exist_ok=True)
    txt_2 = dict_dir_2 / f"wikdict_en_{code}_entries.txt"

    print(f"\n--- EN→{CODE} direction ---")
    count_2 = 0
    with open(txt_2, 'w', encoding='utf-8') as f:
        for hw in sorted(en_to_xx.keys(), key=str.lower):
            groups = organize_senses(en_to_xx[hw])
            if groups:
                dir_label = f'{FLAG_EN} English → {name_native} {flag}'
                html = make_entry_html(hw, dir_label, groups)
                f.write(f"{hw}\n{html}\n</>\n")
                count_2 += 1
    print(f"  {count_2} entries written")

    mdx_path_2 = dict_dir_2 / f"WikDict-EN-{CODE}.mdx"
    desc_2 = (
        f"<p><b>WikDict English-{name_en}</b></p>"
        f"<p>English → {name_en} dictionary extracted from Wiktionary.</p>"
        f"<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/3.0/'>CC-BY-SA 3.0</a>.</p>"
        f"<p>Source: <a href='https://www.wikdict.com/'>WikDict</a></p>"
    )
    success_2, size_2, _ = pack_mdx(txt_2, f"WikDict English-{name_en}", desc_2, mdx_path_2)
    if success_2:
        print(f"  ✓ {mdx_path_2.name}: {size_2:.1f} MB ({count_2} entries)")
        results.append((mdx_path_2, count_2))
        write_catalog_metadata(
            mdx_path=mdx_path_2,
            display_name=f"WikDict English-{name_en}",
            description=f"English-{name_en} dictionary extracted from Wiktionary via WikDict.",
            direction={"src": "EN", "dest": [CODE]},
            entries=count_2,
            license="CC-BY-SA 3.0",
            data_source="WikDict",
            tier=3,
        )

    return results


def _generate_preview(lang_code: str, sample_words: list):
    """Generate a preview HTML for visual review."""
    lang = LANGUAGES[lang_code]
    code = lang['code']
    name_en = lang['name_en']
    name_native = lang['name_native']
    flag = lang['flag']

    en_xx_path = DATA_DIR / f"en-{code}.sqlite3"
    xx_en_path = DATA_DIR / f"{code}-en.sqlite3"

    en_to_xx = load_translations(en_xx_path)
    xx_to_en = load_translations(xx_en_path)

    entries_html = []
    for hw in sample_words:
        if hw in en_to_xx:
            groups = organize_senses(en_to_xx[hw])
            if groups:
                dir_label = f'{FLAG_EN} English → {name_native} {flag}'
                entries_html.append(make_entry_html(hw, dir_label, groups))
        if hw in xx_to_en:
            groups = organize_senses(xx_to_en[hw])
            if groups:
                dir_label = f'{flag} {name_native} → English {FLAG_EN}'
                entries_html.append(make_entry_html(hw, dir_label, groups))

    title = f'WikDict {name_en}↔English — preview'
    for dirname in (f"WikDict-{code.upper()}-EN", f"WikDict-EN-{code.upper()}"):
        d = OUTPUT_DIR / dirname
        d.mkdir(parents=True, exist_ok=True)
        _shared_preview(entries_html, d / f"wikdict_{dirname.lower().replace('-', '_')}_preview.html", title)


def _generate_cross_preview(code_a: str, code_b: str, a_to_b: dict, b_to_a: dict):
    """Generate preview HTMLs for a cross-language pair (both directions)."""
    lang_a = LANGUAGES[code_a]
    lang_b = LANGUAGES[code_b]
    A, B = code_a.upper(), code_b.upper()
    name_a = lang_a['name_native']
    name_b = lang_b['name_native']
    flag_a = lang_a['flag']
    flag_b = lang_b['flag']

    samples_a = SAMPLE_WORDS.get(code_a, ['hello', 'computer', 'house', 'water', 'cat'])
    samples_b = SAMPLE_WORDS.get(code_b, ['hello', 'computer', 'house', 'water', 'cat'])

    entries_html = []
    for hw in samples_a[:4]:
        if hw in a_to_b:
            groups = organize_senses(a_to_b[hw])
            if groups:
                dir_label = f'{flag_a} {name_a} → {name_b} {flag_b}'
                entries_html.append(make_entry_html(hw, dir_label, groups))
    for hw in samples_b[:4]:
        if hw in b_to_a:
            groups = organize_senses(b_to_a[hw])
            if groups:
                dir_label = f'{flag_b} {name_b} → {name_a} {flag_a}'
                entries_html.append(make_entry_html(hw, dir_label, groups))

    title = f'WikDict {lang_a["name_en"]}↔{lang_b["name_en"]} — preview'
    for dirname in (f"WikDict-{A}-{B}", f"WikDict-{B}-{A}"):
        d = OUTPUT_DIR / dirname
        d.mkdir(parents=True, exist_ok=True)
        _shared_preview(entries_html, d / f"wikdict_{dirname.lower().replace('-', '_')}_preview.html", title)


# ── Cross-language pair builder ────────────────────────────────

def build_cross_pair(code_a: str, code_b: str):
    """
    Build TWO separate unidirectional MDX files for a cross-language pair:
      - WikDict-{A}-{B}.mdx  (A headwords → B definitions)
      - WikDict-{B}-{A}.mdx  (B headwords → A definitions)
    """
    lang_a = LANGUAGES[code_a]
    lang_b = LANGUAGES[code_b]
    A, B = code_a.upper(), code_b.upper()
    name_a = lang_a['name_native']
    name_b = lang_b['name_native']
    flag_a = lang_a['flag']
    flag_b = lang_b['flag']

    print(f"\n{'='*60}")
    print(f"Building WikDict {lang_a['name_en']}↔{lang_b['name_en']} (split into 2 MDX files)")
    print(f"{'='*60}")

    # Load both directions from SQLite
    a_to_b_path = DATA_DIR / f"{code_a}-{code_b}.sqlite3"
    b_to_a_path = DATA_DIR / f"{code_b}-{code_a}.sqlite3"

    print(f"Loading {A}→{B} from {a_to_b_path.name}...")
    a_to_b = load_translations(a_to_b_path)
    print(f"  {len(a_to_b)} {lang_a['name_en']} headwords")

    print(f"Loading {B}→{A} from {b_to_a_path.name}...")
    b_to_a = load_translations(b_to_a_path)
    print(f"  {len(b_to_a)} {lang_b['name_en']} headwords")

    results = []

    # ── File 1: WikDict-{A}-{B}.mdx (A → B) ──
    dict_dir_1 = OUTPUT_DIR / f"WikDict-{A}-{B}"
    dict_dir_1.mkdir(parents=True, exist_ok=True)
    txt_1 = dict_dir_1 / f"wikdict_{code_a}_{code_b}_entries.txt"

    print(f"\n--- {A}→{B} direction ---")
    count_1 = 0
    with open(txt_1, 'w', encoding='utf-8') as f:
        for hw in sorted(a_to_b.keys(), key=str.lower):
            groups = organize_senses(a_to_b[hw])
            if groups:
                dir_label = f'{flag_a} {name_a} → {name_b} {flag_b}'
                html = make_entry_html(hw, dir_label, groups)
                f.write(f"{hw}\n{html}\n</>\n")
                count_1 += 1
    print(f"  {count_1} entries written")

    mdx_path_1 = dict_dir_1 / f"WikDict-{A}-{B}.mdx"
    desc_1 = (
        f"<p><b>WikDict {lang_a['name_en']}-{lang_b['name_en']}</b></p>"
        f"<p>{lang_a['name_en']} → {lang_b['name_en']} dictionary extracted from Wiktionary.</p>"
        f"<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/3.0/'>CC-BY-SA 3.0</a>.</p>"
        f"<p>Source: <a href='https://www.wikdict.com/'>WikDict</a></p>"
    )
    success_1, size_1, _ = pack_mdx(txt_1, f"WikDict {lang_a['name_en']}-{lang_b['name_en']}", desc_1, mdx_path_1)
    if success_1:
        print(f"  ✓ {mdx_path_1.name}: {size_1:.1f} MB ({count_1} entries)")
        results.append((mdx_path_1, count_1))
        write_catalog_metadata(
            mdx_path=mdx_path_1,
            display_name=f"WikDict {lang_a['name_en']}-{lang_b['name_en']}",
            description=f"{lang_a['name_en']}-{lang_b['name_en']} dictionary extracted from Wiktionary via WikDict.",
            direction={"src": A, "dest": [B]},
            entries=count_1,
            license="CC-BY-SA 3.0",
            data_source="WikDict",
            tier=3,
        )

    # ── File 2: WikDict-{B}-{A}.mdx (B → A) ──
    dict_dir_2 = OUTPUT_DIR / f"WikDict-{B}-{A}"
    dict_dir_2.mkdir(parents=True, exist_ok=True)
    txt_2 = dict_dir_2 / f"wikdict_{code_b}_{code_a}_entries.txt"

    print(f"\n--- {B}→{A} direction ---")
    count_2 = 0
    with open(txt_2, 'w', encoding='utf-8') as f:
        for hw in sorted(b_to_a.keys(), key=str.lower):
            groups = organize_senses(b_to_a[hw])
            if groups:
                dir_label = f'{flag_b} {name_b} → {name_a} {flag_a}'
                html = make_entry_html(hw, dir_label, groups)
                f.write(f"{hw}\n{html}\n</>\n")
                count_2 += 1
    print(f"  {count_2} entries written")

    mdx_path_2 = dict_dir_2 / f"WikDict-{B}-{A}.mdx"
    desc_2 = (
        f"<p><b>WikDict {lang_b['name_en']}-{lang_a['name_en']}</b></p>"
        f"<p>{lang_b['name_en']} → {lang_a['name_en']} dictionary extracted from Wiktionary.</p>"
        f"<p>Licensed under <a href='https://creativecommons.org/licenses/by-sa/3.0/'>CC-BY-SA 3.0</a>.</p>"
        f"<p>Source: <a href='https://www.wikdict.com/'>WikDict</a></p>"
    )
    success_2, size_2, _ = pack_mdx(txt_2, f"WikDict {lang_b['name_en']}-{lang_a['name_en']}", desc_2, mdx_path_2)
    if success_2:
        print(f"  ✓ {mdx_path_2.name}: {size_2:.1f} MB ({count_2} entries)")
        results.append((mdx_path_2, count_2))
        write_catalog_metadata(
            mdx_path=mdx_path_2,
            display_name=f"WikDict {lang_b['name_en']}-{lang_a['name_en']}",
            description=f"{lang_b['name_en']}-{lang_a['name_en']} dictionary extracted from Wiktionary via WikDict.",
            direction={"src": B, "dest": [A]},
            entries=count_2,
            license="CC-BY-SA 3.0",
            data_source="WikDict",
            tier=3,
        )

    return results, a_to_b, b_to_a


# ── Entry point ────────────────────────────────────────────────

SAMPLE_WORDS = {
    'fr': ['hello', 'bonjour', 'computer', 'maison', 'beautiful', 'eau', 'run'],
    'de': ['hello', 'Haus', 'computer', 'Wasser', 'beautiful', 'schön', 'laufen'],
    'es': ['hello', 'casa', 'computer', 'agua', 'beautiful', 'comer', 'run'],
    'ru': ['hello', 'дом', 'computer', 'вода', 'beautiful', 'кошка', 'бежать'],
    'pt': ['hello', 'casa', 'computer', 'água', 'beautiful', 'comer', 'run'],
    'it': ['hello', 'casa', 'computer', 'acqua', 'beautiful', 'mangiare', 'run'],
    'tr': ['hello', 'ev', 'computer', 'su', 'beautiful', 'güzel', 'run'],
    'la': ['hello', 'aqua', 'computer', 'domus', 'rex', 'amor', 'magnus'],
    'el': ['hello', 'σπίτι', 'computer', 'νερό', 'beautiful', 'γάτα', 'run'],
}

CROSS_PAIR_SET = {f"{a}-{b}" for a, b in CROSS_PAIRS}


def main():
    args = sys.argv[1:] if len(sys.argv) > 1 else []

    # Separate EN↔XX language codes from cross-language pair args
    en_langs = []
    cross_pairs = []

    for arg in args:
        if '-' in arg and arg in CROSS_PAIR_SET:
            a, b = arg.split('-', 1)
            cross_pairs.append((a, b))
        elif arg in LANGUAGES and arg != 'en':
            en_langs.append(arg)
        elif arg == '--all':
            en_langs = [k for k in LANGUAGES if k != 'en']
            cross_pairs = list(CROSS_PAIRS)
        elif arg == '--cross':
            cross_pairs = list(CROSS_PAIRS)
        else:
            print(f"Unknown argument: {arg}")
            print(f"  EN↔XX languages: {', '.join(k for k in LANGUAGES if k != 'en')}")
            print(f"  Cross-pairs: {', '.join(CROSS_PAIR_SET)}")
            print(f"  Flags: --all (everything), --cross (all cross-pairs)")
            continue

    # Default: build all EN↔XX if no args
    if not args:
        en_langs = [k for k in LANGUAGES if k != 'en']

    # Build EN↔XX
    for code in en_langs:
        mdx = build_language(code)
        if mdx:
            samples = SAMPLE_WORDS.get(code, ['hello', 'computer', 'house', 'water', 'cat'])
            _generate_preview(code, samples)

    # Build cross-language pairs
    for code_a, code_b in cross_pairs:
        results, a_to_b, b_to_a = build_cross_pair(code_a, code_b)
        if results:
            _generate_cross_preview(code_a, code_b, a_to_b, b_to_a)


if __name__ == '__main__':
    main()
