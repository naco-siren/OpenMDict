#!/usr/bin/env python3
"""
Build an English monolingual MDX dictionary from Open English WordNet 2025+.

Uses the JSON release of the 2025 edition ("2025+", which adds the curated
Open English Namenet proper nouns):
  https://github.com/globalwordnet/english-wordnet/releases/tag/2025-edition
  english-wordnet-2025-plus-json.zip

The data is split into:
  - entries-{a-z,0}.json : headword -> POS -> senses (+ pronunciations, forms)
  - {noun,verb,adj,adv}.*.json : synset ID -> definition, examples, members,
                                 relations

One article per headword. Each POS group (homographs such as bass n-1 / n-2
stay separate, satellite adjectives merge into adj.) lists every sense with
its definition, all examples, all synonyms, and the WordNet relations as
entry:// links. Irregular inflected forms (upstream 'form' lists plus a short
curated supplement), accented spellings of loanwords and a few hyphen/space
variants (Wi-Fi) become @@@LINK keys.

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

from shared.theme import (get_css, PRONUNCIATION, SENSE_NUMBER_INLINE, GLOSS,
                          EXAMPLES, TEXT_SECONDARY, TEXT_LINK)
from shared.html import esc, entry_link, wrap_entry, dir_label, headword
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "WordNet-EN"

# ── POS display ────────────────────────────────────────────────
# Upstream POS keys: n v a s r, plus homograph splits n-1/n-2, v-1/v-2,
# a-1/a-2 (separate words that share a spelling, e.g. bass /beɪs/ vs /bæs/).
# Satellite adjectives ('s') join the 'a' group.
POS_BASE = {'n': 'n', 'v': 'v', 'a': 'a', 's': 'a', 'r': 'r'}
POS_DISPLAY = {'n': 'noun', 'v': 'verb', 'a': 'adj.', 'r': 'adv.'}
POS_ORDER = {'n': 0, 'v': 1, 'a': 2, 'r': 3}
SUPERSCRIPT = str.maketrans('0123456789', '⁰¹²³⁴⁵⁶⁷⁸⁹')

FLAG_EN = '\U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8'  # 🇬🇧🇺🇸
DIR_LABEL = f'{FLAG_EN} English'

# Short names for the sense-level "exemplifies" spelling labels.
SPELLING_LABEL = {
    'American spelling': 'US', 'British spelling': 'UK',
    'Canadian spelling': 'CA', 'Australian spelling': 'AU',
}

# ── CSS ────────────────────────────────────────────────────────
# Text colors reach WCAG AA (>= 4.5:1) on the .sn card (#f8f8fa / #2c2c2e).
_SEC_L, _SEC_D = TEXT_SECONDARY
_LINK_L, _LINK_D = TEXT_LINK
CSS = get_css(
    PRONUNCIATION, SENSE_NUMBER_INLINE, GLOSS, EXAMPLES,
    extra_light=(
        '.ex{font-style:italic}'
        '.syn{font-size:0.9em;color:#1e7b34;margin:4px 0 0}'
        '.syn b{color:#186b2c;font-weight:500}'
        '.syn a{color:#1e7b34;text-decoration:underline}'
        f'.rel{{font-size:0.85em;color:{_SEC_L};margin:2px 0 0}}'
        '.rel b{font-weight:500}'
        f'.rel a{{color:{_SEC_L};text-decoration:underline}}'
        f'.fo{{display:block;font-size:0.9em;color:{_SEC_L};margin:2px 0}}'
        f'.fo a{{color:{_LINK_L}}}'
        f'.pv{{font-style:normal;font-size:0.75em;color:{_SEC_L}}}'
        '.sn-hd .pr{display:inline;font-size:0.95em;margin:0}'
    ),
    extra_dark=(
        '.syn{color:#30d158}.syn b{color:#32d74b}.syn a{color:#30d158}'
        f'.rel{{color:{_SEC_D}}}.rel a{{color:{_SEC_D}}}'
        f'.fo{{color:{_SEC_D}}}.fo a{{color:{_LINK_D}}}'
        f'.pv{{color:{_SEC_D}}}'
    ),
)

# ── Inflected forms ────────────────────────────────────────────
# Upstream 'form' lists cover the WordNet exception lists (went, mice,
# criteria, ...). These common irregular forms are missing there.
CURATED_FORMS = {
    ('woman', 'n'): ['women'],
    ('do', 'v'): ['does', 'doing'],
    ('go', 'v'): ['goes'],
    ('have', 'v'): ['having'],
    ('say', 'v'): ['says'],
    ('person', 'n'): ['people'],
    ('die', 'n'): ['dice'],
    ('bacterium', 'n'): ['bacteria'],
    ('alga', 'n'): ['algae'],
    ('opus', 'n'): ['opera'],
    ('far', 'a'): ['farther', 'farthest', 'further', 'furthest'],
    ('far', 'r'): ['farthest', 'furthest'],
    ('little', 'a'): ['less', 'least'],
    ('little', 'r'): ['less', 'least'],
    ('many', 'a'): ['more', 'most'],
    ('much', 'a'): ['more', 'most'],
    ('much', 'r'): ['more', 'most'],
    ('well', 'a'): ['best'],
    ('old', 'a'): ['elder', 'eldest'],
    ('good', 'r'): ['better', 'best'],
    ('bad', 'r'): ['worse', 'worst'],
}

# "-man"/"-woman" compounds whose plural is not "-men"/"-women".
MEN_PLURAL_EXCEPTIONS = {'cayman', 'roman', 'saman', 'soman'}

# ── Accented spellings ─────────────────────────────────────────
# WordNet spells loanwords and foreign names without diacritics (cafe,
# cliche, Zurich). The native keyboard offers café, cliché, Zürich, and the
# app does no diacritic folding, so these accented spellings redirect to
# the WordNet key. Curated: accented English headwords of the GCIDE,
# WikDict EN-* and FreeDict EN-DE presets whose ASCII form is a WordNet
# key, checked against the WordNet sense (false friends such as Fårö ->
# faro or divorcé -> divorce removed), plus well-known names.
ACCENTED_ALIASES = {
    'à la carte': 'a la carte', 'à la mode': 'a la mode', 'abacá': 'abaca',
    'Adélie Land': 'Adelie Land', 'Æsir': 'Aesir',
    'aide-mémoire': 'aide-memoire', 'Åland Islands': 'Aland islands',
    'ancien régime': 'ancien regime', 'angélique': 'angelique',
    'ångström': 'angstrom', 'ångström unit': 'angstrom unit',
    'Antonín Dvořák': 'Antonin Dvorak', 'aperçu': 'apercu',
    'apéritif': 'aperitif', 'appliqué': 'applique', 'arête': 'arete',
    'Asunción': 'Asuncion', 'Athínai': 'Athinai', 'attaché': 'attache',
    'attaché case': 'attache case', 'auto-da-fé': 'auto-da-fe',
    'babaçu oil': 'babacu oil', 'Bábism': 'Babism', 'Bartók': 'Bartok',
    'béchamel sauce': 'bechamel sauce', 'Béla Bartók': 'Bela Bartok',
    'Belém': 'Belem', 'bête noire': 'bete noire', 'blasé': 'blase',
    'Bogotá': 'Bogota', 'Bokmål': 'Bokmal', 'Bolívar': 'Bolivar',
    'bolívar': 'bolivar', 'Boötes': 'Bootes', 'bouclé': 'boucle',
    'boutonnière': 'boutonniere', 'Brahmā': 'Brahma', 'Brasília': 'Brasilia',
    'Brașov': 'Brasov', 'Brontë': 'Bronte', 'café': 'cafe',
    'café au lait': 'cafe au lait', 'calèche': 'caleche', 'canapé': 'canape',
    'Cancún': 'Cancun', 'Čapek': 'Capek', 'cause célèbre': 'cause celebre',
    'Cézanne': 'Cezanne', "chargé d'affaires": "charge d'affaires",
    'chassé': 'chasse', 'château': 'chateau', 'Chișinău': 'Chisinau',
    'cinéma vérité': 'cinema verite', 'Ciudad Juárez': 'Ciudad Juarez',
    'cliché': 'cliche', 'clichéd': 'cliched', 'cloisonné': 'cloisonne',
    'colón': 'colon', 'communiqué': 'communique', 'compère': 'compere',
    'consommé': 'consomme', 'Constanța': 'Constanta', 'Córdoba': 'Cordoba',
    'cortège': 'cortege', "Côte d'Azur": "Cote d'Azur",
    "Côte d'Ivoire": "Cote d'Ivoire", "coup d'état": "coup d'etat",
    'coup de grâce': 'coup de grace', 'coupé': 'coupe', 'crèche': 'creche',
    'crème brûlée': 'creme brulee', 'crème de menthe': 'creme de menthe',
    'crêpe': 'crepe', 'crêpe de Chine': 'crepe de Chine',
    'crêpe paper': 'crepe paper', 'crudités': 'crudites',
    'cultural attaché': 'cultural attache', 'Curaçao': 'Curacao',
    'curaçao': 'curacao', 'cybercafé': 'cybercafe',
    'Częstochowa': 'Czestochowa', 'Dalí': 'Dali', 'début': 'debut',
    'débutante': 'debutante', 'décolletage': 'decolletage',
    'décolleté': 'decollete', 'décor': 'decor', 'déjà vu': 'deja vu',
    'démarche': 'demarche', 'démodé': 'demode', 'dénouement': 'denouement',
    'derrière': 'derriere', 'déshabillé': 'deshabille', 'détente': 'detente',
    'divorcée': 'divorcee', 'doppelgänger': 'doppelganger',
    'dragée': 'dragee', 'Dürer': 'Durer', 'Durrës': 'Durres',
    'Düsseldorf': 'Dusseldorf', 'Dvořák': 'Dvorak', 'écarté': 'ecarte',
    'éclair': 'eclair', 'éclat': 'eclat', 'El Niño': 'El Nino',
    'élan': 'elan', 'élan vital': 'elan vital', 'élite': 'elite',
    'emigré': 'emigre', 'émigré': 'emigre',
    'éminence grise': 'eminence grise', 'entrecôte': 'entrecote',
    'entrée': 'entree', 'entrepôt': 'entrepot', 'épée': 'epee',
    'Erwin Schrödinger': 'Erwin Schrodinger', 'exposé': 'expose',
    'Fabergé': 'Faberge', 'façade': 'facade', 'Fáfnir': 'Fafnir',
    'fête': 'fete', 'fiancé': 'fiance', 'fiancée': 'fiancee',
    'fin de siècle': 'fin de siecle', 'fin-de-siècle': 'fin-de-siecle',
    'flambé': 'flambe', 'Floréal': 'Floreal', 'fœtor': 'foetor',
    'Franche-Comté': 'Franche-Comte', 'frappé': 'frappe',
    'Fräulein': 'Fraulein', 'Gaṇeśa': 'Ganesa', 'Gaudí': 'Gaudi',
    'Gdańsk': 'Gdansk', 'glacé': 'glace', 'Gödel': 'Godel',
    'Göring': 'Goring', 'Göteborg': 'Goteborg',
    'Götterdämmerung': 'Gotterdammerung', "grévy's zebra": "grevy's zebra",
    'Gruyère': 'Gruyere', 'guácharo': 'guacharo', 'Guantánamo': 'Guantanamo',
    'Guaraní': 'Guarani', 'guaraní': 'guarani',
    'Guillain-Barré syndrome': 'Guillain-Barre syndrome',
    'habitué': 'habitue', 'háček': 'hacek', 'Hammarskjöld': 'Hammarskjold',
    'Händel': 'Handel', 'Hermann Göring': 'Hermann Goring',
    'Hīnayāna': 'Hinayana', 'Hokkaidō': 'Hokkaido', 'Honshū': 'Honshu',
    'Île-de-France': 'Ile-de-France', 'ingénue': 'ingenue', 'Isère': 'Isere',
    'jalapeño': 'jalapeno', 'jūdō': 'judo', 'jūjutsu': 'jujutsu',
    'Kahlúa': 'Kahlua', 'Kāma': 'Kama', 'Kama Sūtra': 'Kama Sutra',
    'Klaipėda': 'Klaipeda', 'Kraków': 'Krakow', 'króna': 'krona',
    'kümmel': 'kummel', 'Kurt Gödel': 'Kurt Godel', 'Kyōto': 'Kyoto',
    'Kyūshū': 'Kyushu', 'Lake Vänern': 'Lake Vanern', 'lamé': 'lame',
    'ländler': 'landler', 'Laocoön': 'Laocoon', 'León': 'Leon',
    'Lévi-Strauss': 'Levi-Strauss', 'Liège': 'Liege', 'Liepāja': 'Liepaja',
    'littérateur': 'litterateur', 'Logroño': 'Logrono', 'Lomé': 'Lome',
    'Lübeck': 'Lubeck', 'lycée': 'lycee', 'macédoine': 'macedoine',
    'macramé': 'macrame', 'Mahābhārata': 'Mahabharata',
    'Mahāyāna': 'Mahayana', 'Malé': 'Male', 'Malmö': 'Malmo',
    'mañana': 'manana', 'manqué': 'manque', 'Māori': 'Maori', 'maté': 'mate',
    'matinée': 'matinee', 'Medellín': 'Medellin', 'mêlée': 'melee',
    'ménage': 'menage', 'ménage à trois': 'menage a trois',
    "Ménière's disease": "Meniere's disease", 'Mérida': 'Merida',
    'mésalliance': 'mesalliance', 'métier': 'metier',
    'Midi-Pyrénées': 'Midi-Pyrenees', 'military attaché': 'military attache',
    'Miró': 'Miro', 'mise en scène': 'mise en scene', 'Möbius': 'Mobius',
    'Möbius strip': 'Mobius strip',
    'Mohorovičić discontinuity': 'Mohorovicic discontinuity',
    'moiré': 'moire', 'Molière': 'Moliere', 'Monégasque': 'Monegasque',
    'Montréal': 'Montreal', 'Müller': 'Muller',
    'Münchausen syndrome': 'Munchausen syndrome',
    'musique concrète': 'musique concrete', 'naïf': 'naif', 'naïve': 'naive',
    'naiveté': 'naivete', 'naïveté': 'naivete', 'naïvety': 'naivety',
    'née': 'nee', 'négligée': 'negligee', 'névé': 'neve',
    'nirvāṇa': 'nirvana', 'Nivôse': 'Nivose', 'Noël': 'Noel',
    'Noël Coward': 'Noel Coward', 'Nürnberg': 'Nurnberg', 'omertà': 'omerta',
    'Ōsaka': 'Osaka', 'outré': 'outre', 'Pāli': 'Pali',
    'papier-mâché': 'papier-mache', 'Pará': 'Para', 'Paraná': 'Parana',
    'Pārvatī': 'Parvati', 'passé': 'passe', 'pâté': 'pate',
    'pâtisserie': 'patisserie', 'Paul Cézanne': 'Paul Cezanne',
    'pavé': 'pave', "père david's deer": "pere david's deer",
    'perlèche': 'perleche', 'Phaëthon': 'Phaethon',
    'pièce de résistance': 'piece de resistance',
    'pied-à-terre': 'pied-a-terre', 'pietà': 'pieta',
    'piña colada': 'pina colada', 'piñata': 'pinata', 'piñon': 'pinon',
    'piqué': 'pique', 'Pluviôse': 'Pluviose', 'Plzeň': 'Plzen',
    'porte-cochère': 'porte-cochere', 'précis': 'precis',
    'première': 'premiere', 'Príncipe': 'Principe', 'protégé': 'protege',
    'protégée': 'protegee', 'purée': 'puree', 'Québec': 'Quebec',
    'Québécois': 'Quebecois', "raison d'être": "raison d'etre",
    'Rāma': 'Rama', 'Rāmāyaṇa': 'Ramayana',
    'René Descartes': 'Rene Descartes',
    "Republic of Côte d'Ivoire": "Republic of Cote d'Ivoire",
    'résumé': 'resume', 'retroussé': 'retrousse', 'Reykjavík': 'Reykjavik',
    'Rhône': 'Rhone', 'Rhône-Alpes': 'Rhone-Alpes', 'Riksmål': 'Riksmal',
    'Río Bravo': 'Rio Bravo', 'Río de la Plata': 'Rio de la Plata',
    'Río Grande': 'Rio Grande', 'risqué': 'risque', 'rôle': 'role',
    'Röntgen': 'Rontgen', 'rosé': 'rose', 'rosé wine': 'rose wine',
    'roué': 'roue', 'Saïda': 'Saida', 'Saint-Saëns': 'Saint-Saens',
    'saké': 'sake', 'Sámi': 'Sami', 'saṃsāra': 'samsara',
    'San José': 'San Jose', 'San Luis Potosí': 'San Luis Potosi',
    'San Sebastián': 'San Sebastian', 'São Francisco': 'Sao Francisco',
    'São Paulo': 'Sao Paulo', 'São Tomé': 'Sao Tome',
    'São Tomé and Príncipe': 'Sao Tome and Principe', 'Saône': 'Saone',
    'sauté': 'saute', 'sautéed': 'sauteed', 'sautéing': 'sauteing',
    'Schönberg': 'Schonberg', 'Schrödinger': 'Schrodinger',
    'Schrödinger equation': 'Schrodinger equation', 'séance': 'seance',
    'Shintō': 'Shinto', 'shōgun': 'shogun', 'Simón Bolívar': 'Simon Bolivar',
    'Śiva': 'Siva', 'smörgåsbord': 'smorgasbord', 'soirée': 'soiree',
    'solfège': 'solfege', 'soufflé': 'souffle', 'soupçon': 'soupcon',
    'sprachgefühl': 'sprachgefuhl', 'sūtra': 'sutra', 'takahē': 'takahe',
    'tête-à-tête': 'tete-a-tete', 'Theravāda': 'Theravada', 'Tōkyō': 'Tokyo',
    'Torreón': 'Torreon', 'Übermensch': 'Ubermensch', 'Vänern': 'Vanern',
    'Velázquez': 'Velazquez', 'velouté': 'veloute',
    'Vendémiaire': 'Vendemiaire', 'Ventôse': 'Ventose',
    'vis-à-vis': 'vis-a-vis', 'Volapük': 'Volapuk', 'Würzburg': 'Wurzburg',
    'Yaoundé': 'Yaounde', 'Yucatán': 'Yucatan', 'Zürich': 'Zurich',
}

# Common spellings that differ from the WordNet key only by a hyphen or
# space (the app does no punctuation stripping).
SPELLING_ALIASES = {
    'Wi-Fi': 'WiFi', 'COVID': 'COVID-19', 'ecommerce': 'e-commerce',
    'per cent': 'percent',
}

# Upstream pronunciation errors, replaced per (headword, upstream POS).
# 2025 data gives lowercase polish (noun: shine, refinement) the
# nationality pronunciation of Polish.
PRONUNCIATION_FIXES = {
    ('polish', 'n'): [('ˈpɒlɪʃ', 'GB'), ('ˈpɑlɪʃ', 'US')],
}


# ── Load data ──────────────────────────────────────────────────

def load_synsets() -> dict:
    """Load all synset files into a single dict: synset_id → synset_data."""
    synsets = {}
    patterns = ['noun.*.json', 'verb.*.json', 'adj.*.json', 'adv.*.json']
    for pattern in patterns:
        for filepath in sorted(glob.glob(str(DATA_DIR / pattern))):
            with open(filepath, 'r', encoding='utf-8') as f:
                synsets.update(json.load(f))
    return synsets


def load_entries() -> dict:
    """Load all entry files. Returns: word → {pos → info} (upstream order)."""
    entries = {}
    for filepath in sorted(glob.glob(str(DATA_DIR / 'entries-*.json'))):
        with open(filepath, 'r', encoding='utf-8') as f:
            for word, pos_data in json.load(f).items():
                if word in entries:
                    raise SystemExit(f"duplicate headword across entry files: {word!r}")
                entries[word] = pos_data
    return entries


def split_pos(pos: str) -> tuple[str, str]:
    """'n-2' → ('n', '2'); 's' → ('a', '')."""
    base, _, hom = pos.partition('-')
    return POS_BASE.get(base, base), hom


def pos_groups(pos_data: dict, synsets: dict,
               word: str = '') -> list[tuple[str, str, list, list]]:
    """[(base_pos, homograph_no, senses, pronunciations)] in display order.

    'a' and 's' blocks are merged into one adj. group; senses without a
    resolvable synset definition are dropped (none in the 2025 release).
    """
    groups: dict[tuple[str, str], tuple[list, list]] = {}
    for pos, info in pos_data.items():
        key = split_pos(pos)
        senses, prons = groups.setdefault(key, ([], []))
        for s in info.get('sense', []):
            syn = synsets.get(s.get('synset'))
            if syn and syn.get('definition'):
                senses.append(s)
        upstream = [((p.get('value') or '').strip(), p.get('variety'))
                    for p in info.get('pronunciation', [])]
        for val, var in PRONUNCIATION_FIXES.get((word, pos), upstream):
            if val and (val, var) not in prons:
                prons.append((val, var))
    out = [(b, h, s, p) for (b, h), (s, p) in groups.items() if s]
    out.sort(key=lambda g: (POS_ORDER.get(g[0], 9), g[1]))
    return out


# ── Relations ──────────────────────────────────────────────────

class Lexicon:
    """Upstream data plus the inverse indexes the articles need."""

    def __init__(self, entries: dict, synsets: dict):
        self.entries = entries
        self.synsets = synsets
        self.keys_lower = {w.lower() for w in entries}
        # sense id -> lemma
        self.sense_lemma = {}
        for word, pos_data in entries.items():
            for info in pos_data.values():
                for s in info.get('sense', []):
                    self.sense_lemma[s['id']] = word
        # holonyms: inverse of the synset-level meronym lists
        self.holonyms = {rel: defaultdict(list) for rel in
                         ('mero_part', 'mero_member', 'mero_substance')}
        for sid, syn in synsets.items():
            for rel, inv in self.holonyms.items():
                for target in syn.get(rel, []):
                    inv[target].append(sid)

    def rep(self, synset_id: str, word: str) -> str | None:
        """A synset's representative word: its first member that is not `word`."""
        members = self.synsets.get(synset_id, {}).get('members', [])
        for m in members:
            if m.lower() != word.lower():
                return m
        return members[0] if members else None

    def link(self, target: str) -> str:
        if target.lower() in self.keys_lower and '#' not in target:
            return entry_link(target)
        return esc(target)


def _dedupe(items) -> list:
    seen, out = set(), []
    for x in items:
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out


def sense_relations(word: str, sense: dict, synset: dict, lex: Lexicon) -> list[str]:
    """Relation lines of one sense card, as HTML."""
    sid = sense['synset']
    lines = []

    def rel_line(label: str, words: list, cls: str = 'rel'):
        words = [w for w in _dedupe(words) if w.lower() != word.lower()]
        if words:
            items = ', '.join(lex.link(w) for w in words)
            lines.append(f'<div class="{cls}"><b>{label}</b> {items}</div>')

    def syn_words(rel: str) -> list:
        return [lex.rep(t, word) for t in synset.get(rel, [])]

    def sense_words(rel: str) -> list:
        return [lex.sense_lemma.get(t) for t in sense.get(rel, [])]

    rel_line('Syn:', synset.get('members', []), cls='syn')
    rel_line('Ant:', sense_words('antonym'))
    rel_line('Similar:', syn_words('similar') + sense_words('similar'))
    rel_line('See also:', syn_words('also') + sense_words('also'))
    rel_line('Attribute:', syn_words('attribute'))
    rel_line('Pertains to:', sense_words('pertainym'))
    rel_line('Related:', sense_words('derivation'))
    rel_line('Participle of:', sense_words('participle'))
    rel_line('Entails:', syn_words('entails'))
    rel_line('Causes:', syn_words('causes'))
    rel_line('Has part:', syn_words('mero_part'))
    rel_line('Part of:', [lex.rep(t, word) for t in lex.holonyms['mero_part'].get(sid, [])])
    rel_line('Has member:', syn_words('mero_member'))
    rel_line('Member of:', [lex.rep(t, word) for t in lex.holonyms['mero_member'].get(sid, [])])
    rel_line('Made of:', syn_words('mero_substance'))
    rel_line('Substance of:', [lex.rep(t, word) for t in lex.holonyms['mero_substance'].get(sid, [])])
    hyper = syn_words('hypernym') + syn_words('instance_hypernym')
    hyper = [h for h in _dedupe(hyper) if h.lower() != word.lower()]
    if hyper:
        lines.append(f'<div class="rel">→ {", ".join(lex.link(h) for h in hyper)}</div>')
    return lines


def sense_usage_labels(sense: dict, lex: Lexicon) -> tuple[str, list[str]]:
    """(spelling label such as 'UK, CA, AU spelling', other usage labels)."""
    spell, other = [], []
    for t in sense.get('exemplifies', []):
        lemma = lex.sense_lemma.get(t)
        if not lemma:
            continue
        if lemma in SPELLING_LABEL:
            spell.append(SPELLING_LABEL[lemma])
        else:
            other.append(lemma)
    spell = _dedupe(spell)
    return (f'{", ".join(spell)} spelling' if spell else ''), _dedupe(other)


# ── Pronunciation ──────────────────────────────────────────────

def pron_html(prons: list) -> str:
    """'GB /ɡəʊ/ · US /ɡoʊ/' (labels dropped when one value covers every variety)."""
    order, labels = [], {}
    for val, var in prons:
        if val not in labels:
            labels[val] = []
            order.append(val)
        if var and var not in labels[val]:
            labels[val].append(var)
    if not order:
        return ''
    if len(order) == 1 and len(labels[order[0]]) > 1:
        return f'/{esc(order[0])}/'
    parts = []
    for val in order:
        lab = ', '.join(labels[val])
        parts.append((f'<span class="pv">{esc(lab)}</span> ' if lab else '') + f'/{esc(val)}/')
    return ' · '.join(parts)


# ── Form-of notes ──────────────────────────────────────────────

def form_label(form: str, lemma: str, pos: str) -> str:
    if pos == 'n':
        return 'plural of'
    if pos == 'v':
        if lemma == 'be':
            return {'am': 'present tense of', 'is': 'present tense of',
                    'are': 'present tense of', 'was': 'past tense of',
                    'were': 'past tense of', 'been': 'past participle of',
                    'being': 'present participle of'}.get(form, 'a form of')
        if form.endswith('ing'):
            return 'present participle of'
        if form in (lemma + 's', lemma + 'es') or (
                lemma.endswith('y') and form == lemma[:-1] + 'ies'):
            return 'third-person singular of'
        return 'a form of'
    if form.endswith('st'):
        return 'superlative of'
    if form.endswith('er') or form in ('worse', 'more', 'less'):
        return 'comparative of'
    return 'a form of'


def form_note_html(notes: list[tuple[str, str, str]], lex: Lexicon) -> str:
    """notes: [(label, lemma, pos)] → '<span class="fo">also plural of man</span>'."""
    by_label: dict[str, list] = {}
    for label, lemma, pos in notes:
        lst = by_label.setdefault(label, [])
        if lemma not in lst:
            lst.append(lemma)
    parts = [f'{esc(label)} {", ".join(lex.link(l) for l in lemmas)}'
             for label, lemmas in by_label.items()]
    return f'<span class="fo">also {"; ".join(parts)}</span>'


# ── HTML generation ────────────────────────────────────────────

def build_entry_html(word: str, groups: list, lex: Lexicon,
                     form_notes: list | None = None) -> str:
    """
    Build HTML for one headword.
    groups: output of pos_groups() (POS groups in display order).
    form_notes: [(label, lemma, pos)] when this headword is also an
                inflected form of another word (saw → see).
    """
    parts = [dir_label(DIR_LABEL), headword(word)]

    # One pronunciation line when every POS group agrees, else one per group.
    group_prons = [pron_html(g[3]) for g in groups]
    distinct = _dedupe(p for p in group_prons if p)
    per_group = len(distinct) > 1
    if distinct and not per_group:
        parts.append(f'<span class="pr">{distinct[0]}</span>')

    # Spelling labels: once under the headword when every sense agrees.
    usage = {id(s): sense_usage_labels(s, lex) for g in groups for s in g[2]}
    spellings = {u[0] for u in usage.values()}
    hoisted = len(spellings) == 1 and '' not in spellings
    if hoisted:
        parts.append(f'<span class="fo"><span class="mk">{esc(next(iter(spellings)))}</span></span>')

    if form_notes:
        parts.append(form_note_html(form_notes, lex))

    for (base, hom, senses, _), prons in zip(groups, group_prons):
        pos_label = POS_DISPLAY.get(base, base) + hom.translate(SUPERSCRIPT)

        for i, sense in enumerate(senses):
            synset = lex.synsets[sense['synset']]
            parts.append('<div class="sn">')

            header = [f'<span class="pos">{esc(pos_label)}</span>']
            if len(senses) > 1:
                header.append(f'<span class="sn-n">{i + 1}.</span>')
            if per_group and i == 0 and prons:
                header.append(f'<span class="pr">{prons}</span>')
            # Sense-level usage labels (UK spelling, trademark, ...). The
            # synset-level topic/region/usage pointers are not shown: many
            # are noisy upstream (restlessness -> 'sexual activity') and most
            # definitions already start with the domain ('(law) ...').
            spelling, other = usage[id(sense)]
            badges = list(other)
            if spelling and not hoisted:
                badges.append(spelling)
            header += [f'<span class="mk">{esc(b)}</span>' for b in _dedupe(badges)]
            parts.append(f'<div class="sn-hd">{"".join(header)}</div>')

            # Definition(s): a few synsets carry more than one
            parts.append(f'<span class="gl">{"; ".join(esc(d) for d in synset["definition"])}</span>')

            # Examples: every synset example, then this sense's own sentences
            examples = []
            for ex in synset.get('example', []):
                examples.append(ex.get('text', '') if isinstance(ex, dict) else ex)
            examples += sense.get('sent', [])
            for ex_text in _dedupe(e.strip() for e in examples):
                parts.append(f'<div class="ex">{esc(ex_text)}</div>')

            parts.extend(sense_relations(word, sense, synset, lex))
            parts.append('</div>')

    return wrap_entry(''.join(parts), CSS)


# ── Redirect keys ──────────────────────────────────────────────

def _men_plural(word: str, keys_lower: set) -> str | None:
    """policeman → policemen, best man → best men (None when not a safe guess)."""
    if word != word.lower() or word in MEN_PLURAL_EXCEPTIONS:
        return None
    if ' of ' in word or '-of-' in word:
        return None
    for sg, pl in (('woman', 'women'), ('man', 'men')):
        if not word.endswith(sg):
            continue
        head = word[:-len(sg)]
        if not head:
            return None
        if head.endswith((' ', '-')):
            return head + pl            # 'con man', 'he-man'
        if head.lower() in keys_lower or (head.endswith('s') and head[:-1].lower() in keys_lower):
            return head + pl            # 'policeman', 'craftsman'
        return None
    return None


def collect_forms(lex: Lexicon) -> dict[str, list[tuple[str, str, bool]]]:
    """inflected form → [(lemma, base_pos, from_data)] in upstream order.

    from_data is False for the rule-made "-men" plurals, which are only
    used where the spelling is not already a headword.
    """
    forms: dict[str, list] = defaultdict(list)

    def add(form, lemma, pos, from_data=True):
        if form and form != lemma and all((l, p) != (lemma, pos) for l, p, _ in forms[form]):
            forms[form].append((lemma, pos, from_data))

    for lemma, pos_data in lex.entries.items():
        for pos, info in pos_data.items():
            base, _ = split_pos(pos)
            for form in info.get('form', []):
                add(form, lemma, base)
    for (lemma, pos), fs in CURATED_FORMS.items():
        if lemma not in lex.entries or not any(split_pos(p)[0] == pos for p in lex.entries[lemma]):
            raise SystemExit(f"CURATED_FORMS: {lemma!r} ({pos}) is not a WordNet headword")
        for form in fs:
            add(form, lemma, pos)
    for lemma, pos_data in lex.entries.items():
        if not any(split_pos(p)[0] == 'n' for p in pos_data):
            continue
        if any(f.endswith('men') for p, i in pos_data.items()
               if p.startswith('n') for f in i.get('form', [])):
            continue
        pl = _men_plural(lemma, lex.keys_lower)
        if pl and pl.lower() not in lex.keys_lower:
            add(pl, lemma, 'n', from_data=False)
    return forms


def plan_redirects(lex: Lexicon):
    """Return (redirects [(key, target)], notes {headword: [(label, lemma, pos)]})."""
    forms = collect_forms(lex)
    redirects, notes = [], defaultdict(list)
    for form in sorted(forms, key=str.lower):
        for lemma, pos, from_data in forms[form]:
            if form in lex.entries:
                # The spelling is a headword of its own (saw, data, left):
                # note the inflection there instead of shadowing it.
                if from_data:
                    notes[form].append((form_label(form, lemma, pos), lemma, pos))
            else:
                redirects.append((form, lemma))
    form_keys = {k.lower() for k, _ in redirects}
    for alias, target in {**ACCENTED_ALIASES, **SPELLING_ALIASES}.items():
        if target not in lex.entries:
            raise SystemExit(f"alias target {target!r} is not a headword")
        if alias.lower() in lex.keys_lower or alias.lower() in form_keys:
            continue
        redirects.append((alias, target))
    return redirects, notes


# ── Main ──────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Loading Open English WordNet 2025+...")
    synsets = load_synsets()
    print(f"  {len(synsets)} synsets loaded")
    entries = load_entries()
    print(f"  {len(entries)} headwords loaded")
    for word, pos in PRONUNCIATION_FIXES:
        if pos not in entries.get(word, {}):
            raise SystemExit(f"PRONUNCIATION_FIXES: {word!r} ({pos}) is not in the data")
    lex = Lexicon(entries, synsets)

    redirects, notes = plan_redirects(lex)
    print(f"  {len(redirects)} redirect keys (inflected forms, accented spellings), "
          f"{len(notes)} articles with an inflected-form note")

    # ── Generate MDict source ──
    txt_path = OUTPUT_DIR / "wordnet_en_entries.txt"
    print(f"  Writing → {txt_path}...")
    count = 0
    with open(txt_path, 'w', encoding='utf-8') as f:
        for word in sorted(entries, key=str.lower):
            groups = pos_groups(entries[word], synsets, word)
            if not groups:
                continue
            html = build_entry_html(word, groups, lex, notes.get(word))
            f.write(f"{word}\n{html}\n</>\n")
            count += 1
        for key, target in redirects:
            f.write(f"{key}\n@@@LINK={target}\n</>\n")
    total = count + len(redirects)
    print(f"  {count} articles + {len(redirects)} redirects = {total} entries written")

    # ── Pack MDX ──
    mdx_path = OUTPUT_DIR / "WordNet-EN.mdx"
    desc_html = (
        "<p><b>Open English WordNet 2025+</b> (release 2025-edition)</p>"
        "<p>A lexical database of English content words (nouns, verbs, "
        "adjectives and adverbs) grouped into sets of synonyms, with "
        "definitions, examples, antonyms and related words. It has no "
        "function words such as <i>the</i>, <i>of</i> or <i>and</i>.</p>"
        "<p>Source: <a href='https://en-word.net/'>Open English WordNet</a>, "
        "<a href='https://github.com/globalwordnet/english-wordnet'>"
        "github.com/globalwordnet/english-wordnet</a>. "
        "Copyright © 2019–present, The Open English WordNet Team. "
        "Licensed under <a href='https://creativecommons.org/licenses/by/4.0/'>"
        "Creative Commons Attribution 4.0 International (CC BY 4.0)</a>, "
        "provided as is, without warranties.</p>"
        "<p>This work is based on Princeton WordNet, used under the "
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
        "<p>Converted to MDict and reformatted by OpenMDict: senses grouped "
        "per headword, relations shown as links, inflected forms and "
        "alternative spellings (café, Wi-Fi) added as cross-references.</p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "Open English WordNet", desc_html, mdx_path)
    if not success:
        sys.exit(1)
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {total} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="Open English WordNet",
        description=("Open English WordNet 2025+: English nouns, verbs, adjectives "
                     "and adverbs with definitions, examples, synonyms, antonyms "
                     "and related words. Derived from Princeton WordNet."),
        direction={"src": "EN", "dest": ["EN"]},
        entries=total,
        license="CC-BY-4.0 AND LicenseRef-WordNet-3.0",
        data_source="Open English WordNet 2025+ (2025-edition release)",
        tier=0,
    )

    # ── Preview ──
    _generate_preview(lex, notes)


def _generate_preview(lex: Lexicon, notes: dict):
    """Generate preview HTML for visual review."""
    samples = ['bank', 'run', 'set', 'light', 'mind', 'happy', 'dog', 'water',
               'bass', 'hot', 'colour', 'saw', 'suddenly', 'green', 'refuse']
    entries_html = []
    for word in samples:
        if word not in lex.entries:
            continue
        groups = pos_groups(lex.entries[word], lex.synsets, word)
        if groups:
            entries_html.append(build_entry_html(word, groups, lex, notes.get(word)))
    preview_path = OUTPUT_DIR / "wordnet_en_preview.html"
    _shared_preview(entries_html, preview_path, 'Open English WordNet 2025+ — preview')


if __name__ == '__main__':
    main()
