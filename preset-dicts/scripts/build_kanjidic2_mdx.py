#!/usr/bin/env python3
"""
Build KANJIDIC2 MDX dictionary from kanjidic2.xml.gz.

Usage:
    python build_kanjidic2_mdx.py

Input:  ../data/kanjidic2-<database_version>/kanjidic2.xml.gz
Output: ../output/KANJIDIC2-JA/KANJIDIC2-JA.mdx

The EDRDG licence (section 4) requires apps that ship this data to update
it regularly from the most recent release. To update: fetch the current
https://www.edrdg.org/kanjidic/kanjidic2.xml.gz into a new
data/kanjidic2-<database_version>/ directory (scripts/fetch_data.sh),
set KANJIDIC2_DB_VERSION and KANJIDIC2_SHA256 below to that release,
rebuild and publish the new MDX. The build warns once the pinned release
is older than MAX_DATA_AGE_DAYS.

Every <character> is included (all have a stroke count and a radical).
Shown: grade, former JLPT level, newspaper frequency rank, strokes,
classical radical, on/kun/pinyin/Korean/Vietnamese readings, English
meanings, nanori and <variant> cross-references (code-point references,
plus reciprocal dictionary-number / query-code ones; see resolve_variants).
Not shown: non-English meanings, query codes (SKIP etc.) and dictionary
index numbers.
"""

import datetime
import gzip
import hashlib
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, CJK_READING_TAGS, TEXT_SECONDARY, TEXT_LINK
from shared.html import esc, entry_link, kana_to_romaji
from shared.build import pack_mdx, generate_preview as _shared_preview, write_catalog_metadata

# The KANJIDIC2 release this build is pinned to (its <database_version>)
# and the SHA-256 of that kanjidic2.xml.gz. EDRDG serves only the current
# file, at KANJIDIC2_URL.
KANJIDIC2_URL = "https://www.edrdg.org/kanjidic/kanjidic2.xml.gz"
KANJIDIC2_DB_VERSION = "2026-300"
KANJIDIC2_SHA256 = "3617aa8a34015d4283f9ac22e00d2b80448f882cbc5a8e588b5f7ceae6493589"
MAX_DATA_AGE_DAYS = 31
DATA_DIR = SCRIPT_DIR.parent / "data" / f"kanjidic2-{KANJIDIC2_DB_VERSION}"
OUTPUT_DIR = SCRIPT_DIR.parent / "output" / "KANJIDIC2-JA"
KANJIDIC2_FILE = DATA_DIR / "kanjidic2.xml.gz"


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

# ── HTML ───────────────────────────────────────────────────────

FLAG_JP = '\U0001F1EF\U0001F1F5'  # 🇯🇵
DIR_LABEL = f'{FLAG_JP} 漢字'

_SEC_L, _SEC_D = TEXT_SECONDARY
_LINK_L, _LINK_D = TEXT_LINK

CSS = get_css(
    CJK_READING_TAGS,
    extra_light=(
        '.k{font-size:2.5em;font-weight:400;display:block;padding:8px 0}'
        f'.info{{font-size:0.85em;color:{_SEC_L};display:block;margin-bottom:2px}}'
        '.rd{margin:6px 0;display:flex;flex-wrap:wrap;align-items:baseline;gap:2px}'
        f'.rd-label{{font-size:0.8em;color:{_SEC_L};margin-right:4px;min-width:36px}}'
        '.df{font-size:1.15em}'
        f'.nn{{font-size:0.95em;color:{_SEC_L}}}'
        '.vr{font-size:0.9em;color:#636366;margin:4px 0}'
        f'.vr a{{color:{_LINK_L};text-decoration:underline}}'
    ),
    extra_dark=(
        f'.info{{color:{_SEC_D}}}'
        f'.rd-label{{color:{_SEC_D}}}'
        f'.nn{{color:{_SEC_D}}}'
        '.vr{color:#98989d}'
        f'.vr a{{color:{_LINK_D}}}'
    ),
)


# ── Grade / JLPT labels ────────────────────────────────────────

GRADE_LABELS = {
    '1': 'Grade 1', '2': 'Grade 2', '3': 'Grade 3', '4': 'Grade 4',
    '5': 'Grade 5', '6': 'Grade 6',
    '8': 'Jōyō', '9': 'Jinmeiyō', '10': 'Jinmeiyō (variant)',
}

# <jlpt> is the FORMER (pre-2010) four-level test, 1 (most advanced) to 4
# (most elementary). The DTD notes the N levels are similar except that old
# level 2 is split between N2 and N3; there is no official N-level list.
JLPT_LABELS = {
    '1': 'old JLPT 1 (≈N1)',
    '2': 'old JLPT 2 (≈N2/N3)',
    '3': 'old JLPT 3 (≈N4)',
    '4': 'old JLPT 4 (≈N5)',
}


def _kun_to_romaji(kun: str) -> str:
    """Convert kun reading to romaji, preserving '.' and '-' markers."""
    # Split on markers, convert each kana segment, rejoin
    parts = re.split(r'([.\-])', kun)
    return ''.join(kana_to_romaji(p) if p not in ('.', '-') else p for p in parts)


def kangxi_radical_char(num: str) -> str:
    """Unified ideograph of classical (Kangxi) radical `num` ('72' → 日)."""
    try:
        n = int(num)
    except ValueError:
        return ''
    if not 1 <= n <= 214:
        return ''
    return unicodedata.normalize('NFKC', chr(0x2F00 + n - 1))


# <variant var_type> → where the referenced code lives in the other
# character's entry: ('cp', cp_type) / ('dr', dr_type) / ('qc', qc_type).
# The DTD: a <variant> is "either a cross-reference code to another kanji,
# usually regarded as a variant, or an alternative indexing code for the
# current kanji". Code-point references (jis208/212/213, ucs) name another
# character. Dictionary-number and query-code references are often the
# second kind: 看 nelson_c 3127 is where Nelson also indexes 看, under 目
# (3127 is 目's own number), not a variant of 目. resolve_variants() keeps
# those only when the target refers back to the source.
_CODEPOINT_VARIANT_TYPES = frozenset({'jis208', 'jis212', 'jis213', 'ucs'})
_VARIANT_INDEX = {
    'jis208': ('cp', 'jis208'), 'jis212': ('cp', 'jis212'),
    'jis213': ('cp', 'jis213'), 'ucs': ('cp', 'ucs'),
    'nelson_c': ('dr', 'nelson_c'), 'njecd': ('dr', 'halpern_njecd'),
    'oneill': ('dr', 'oneill_names'), 'deroo': ('qc', 'deroo'),
    's_h': ('qc', 'sh_desc'),
}


# ── Parser ─────────────────────────────────────────────────────

def read_header(filepath: Path) -> dict:
    """<header> fields: file_version, database_version, date_of_creation."""
    with gzip.open(filepath) as f:
        for _, elem in ET.iterparse(f, events=('end',)):
            if elem.tag == 'header':
                return {c.tag: (c.text or '').strip() for c in elem}
    return {}


def parse_kanjidic2(filepath: Path):
    """Parse kanjidic2.xml(.gz), yield character dicts (document order)."""
    with gzip.open(filepath) as f:
        for _, elem in ET.iterparse(f, events=('end',)):
            if elem.tag != 'character':
                continue

            literal = elem.findtext('literal', '')
            if not literal:
                elem.clear()
                continue

            # Code points and index numbers (for resolving <variant> refs)
            codes = []
            cp_elem = elem.find('codepoint')
            if cp_elem is not None:
                codes += [('cp', cv.get('cp_type'), (cv.text or '').strip())
                          for cv in cp_elem.findall('cp_value')]
            dn = elem.find('dic_number')
            if dn is not None:
                codes += [('dr', d.get('dr_type'), (d.text or '').strip())
                          for d in dn.findall('dic_ref')]
            qc = elem.find('query_code')
            if qc is not None:
                codes += [('qc', q.get('qc_type'), (q.text or '').strip())
                          for q in qc.findall('q_code')]

            # Misc
            misc = elem.find('misc')
            grade = misc.findtext('grade', '') if misc is not None else ''
            stroke_count = misc.findtext('stroke_count', '') if misc is not None else ''
            freq = misc.findtext('freq', '') if misc is not None else ''
            jlpt = misc.findtext('jlpt', '') if misc is not None else ''
            variants = []
            if misc is not None:
                variants = [(v.get('var_type', ''), (v.text or '').strip())
                            for v in misc.findall('variant')]

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

            yield {
                'literal': literal,
                'codes': codes,
                'variants': variants,
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


def resolve_variants(entries: dict) -> tuple[int, int, int]:
    """Turn each character's <variant> references into literals.

    A reference is resolved through the other characters' code points,
    dictionary numbers or query codes; it is kept only when exactly one
    other character carries that code. A dictionary-number or query-code
    reference (nelson_c, deroo, njecd, oneill, s_h) is kept only when it is
    reciprocal, i.e. one of the target's own <variant> references resolves
    back to this character: these codes are mostly alternative indexing
    codes (間/開/聞 deroo and nelson_c point at 門, 看/眼 at 目, 速 at 早),
    while real variant pairs refer to each other (鯵 ↔ 鰺, 讃 ↔ 讚).
    A target canonically equivalent to the character itself (a CJK
    compatibility ideograph and its unified form) is dropped: the app
    compares keys as Swift Strings, so a lookup of either shows both
    records and the link would only reload the page.
    Sets ch['variant_chars']; returns (unresolved references, dropped
    non-reciprocal index-code references, dropped canonical-equivalent
    targets).
    """
    index: dict[tuple, set] = {}
    for lit, ch in entries.items():
        for kind, typ, val in ch['codes']:
            index.setdefault((kind, typ, val), set()).add(lit)

    def resolve(lit: str, var_type: str, val: str) -> set:
        if var_type == 'ucs':
            try:
                c = chr(int(val, 16))
            except (ValueError, OverflowError):
                return set()
            return {c} - {lit} if c in entries else set()
        where = _VARIANT_INDEX.get(var_type)
        if not where:
            return set()
        return index.get((where[0], where[1], val), set()) - {lit}

    # Pass 1: every reference that names exactly one other character.
    resolved: dict[str, list[tuple[str, str]]] = {}
    unresolved = 0
    for lit, ch in entries.items():
        refs = []
        for var_type, val in ch['variants']:
            targets = resolve(lit, var_type, val)
            if len(targets) == 1:
                refs.append((var_type, next(iter(targets))))
            else:
                unresolved += 1
        resolved[lit] = refs
    refers_to = {lit: {t for _, t in refs} for lit, refs in resolved.items()}

    # Pass 2: index-code references must be reciprocal.
    nonreciprocal = 0
    equivalent = 0
    for lit, ch in entries.items():
        out = []
        nfc = unicodedata.normalize('NFC', lit)
        for var_type, t in resolved[lit]:
            if var_type not in _CODEPOINT_VARIANT_TYPES and lit not in refers_to[t]:
                nonreciprocal += 1
            elif unicodedata.normalize('NFC', t) == nfc:
                equivalent += 1
            elif t not in out:
                out.append(t)
        ch['variant_chars'] = out
    return unresolved, nonreciprocal, equivalent


# ── HTML generation ────────────────────────────────────────────

def make_html(ch: dict) -> str:
    """Generate HTML for a single kanji entry."""
    lit = ch['literal']
    parts = [f'<span class="dir">{DIR_LABEL}</span>']
    parts.append(f'<span class="k">{esc(lit)}</span>')

    # Info line 1: grade, former JLPT, newspaper frequency rank
    line1_items = []
    if ch['grade']:
        line1_items.append(GRADE_LABELS.get(ch['grade'], f'Grade {ch["grade"]}'))
    if ch['jlpt']:
        line1_items.append(JLPT_LABELS.get(ch['jlpt'], f'old JLPT {ch["jlpt"]}'))
    if ch['freq']:
        line1_items.append(f'frequency #{ch["freq"]}')
    if line1_items:
        parts.append(f'<span class="info">{esc(" · ".join(line1_items))}</span>')

    # Info line 2: strokes, radical  (e.g. "4 strokes · radical 72 日")
    line2_items = []
    if ch['stroke_count']:
        n = ch['stroke_count']
        line2_items.append(f'{n} stroke' + ('' if n == '1' else 's'))
    if ch['radical']:
        rc = kangxi_radical_char(ch['radical'])
        line2_items.append(f'radical {ch["radical"]} {rc}' if rc else f'radical {ch["radical"]}')
    if line2_items:
        parts.append(f'<span class="info">{esc(" · ".join(line2_items))}</span>')

    # CJK compatibility ideograph: say what it is equivalent to
    nfc = unicodedata.normalize('NFC', lit)
    if nfc != lit:
        parts.append(f'<span class="info">{esc(f"U+{ord(lit):04X}")} compatibility '
                     f'ideograph, canonically equivalent to {esc(nfc)} '
                     f'{esc(f"U+{ord(nfc):04X}")}</span>')

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

    # Korean (korean_h and korean_r are parallel lists upstream)
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
                     f'<span class="nn">{nanori_html}</span></div>')

    # Variant kanji (resolved from <variant>; every target is a key)
    if ch.get('variant_chars'):
        links = ', '.join(entry_link(v) for v in ch['variant_chars'])
        parts.append(f'<div class="vr">Variants: {links}</div>')

    return f'{CSS}<div class="e">{"".join(parts)}</div>'


# ── Preview ────────────────────────────────────────────────────

SAMPLE_WORDS = ['日', '本', '人', '国', '國', '芋', '侮', '侮', '𠆢']


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
    if not KANJIDIC2_FILE.exists():
        raise SystemExit(f"{KANJIDIC2_FILE} not found (source: {KANJIDIC2_URL}) -- run "
                         "scripts/fetch_data.sh kanjidic2, which stores the current release "
                         "under data/kanjidic2-<database_version>/, then set "
                         "KANJIDIC2_DB_VERSION and KANJIDIC2_SHA256 here to that release")
    got = _sha256(KANJIDIC2_FILE)
    if got != KANJIDIC2_SHA256:
        raise SystemExit(f"{KANJIDIC2_FILE}: sha256 {got} != pinned {KANJIDIC2_SHA256}. "
                         "Update the pin here when refreshing the data.")

    header = read_header(KANJIDIC2_FILE)
    db_version = header.get('database_version', '')
    db_date = header.get('date_of_creation', '')
    if db_version != KANJIDIC2_DB_VERSION:
        raise SystemExit(f"{KANJIDIC2_FILE}: database_version {db_version!r}, "
                         f"expected {KANJIDIC2_DB_VERSION}")
    print(f"Parsing KANJIDIC2 {db_version} ({db_date})...")
    try:
        age = (datetime.date.today() - datetime.date.fromisoformat(db_date)).days
    except ValueError:
        age = None
    if age is not None and age > MAX_DATA_AGE_DAYS:
        print(f"  WARNING: KANJIDIC2 {db_version} ({db_date}) is {age} days old. The EDRDG "
              "licence (section 4) requires regular updates: refresh the data.")

    entries = {}  # literal → char dict
    for ch in parse_kanjidic2(KANJIDIC2_FILE):
        entries[ch['literal']] = ch

    print(f"  {len(entries)} kanji parsed")
    unresolved, nonreciprocal, equivalent = resolve_variants(entries)
    n_var = sum(len(ch['variant_chars']) for ch in entries.values())
    print(f"  {n_var} variant links ({unresolved} references not resolvable to a kanji, "
          f"{nonreciprocal} non-reciprocal index-code references and {equivalent} to a "
          "canonically equivalent character dropped)")

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
        f"<p>{count:,} kanji of JIS X 0208, 0212 and 0213 with stroke counts, "
        "classical radicals, on/kun readings with romaji, Chinese (pinyin), Korean "
        "and Vietnamese readings, English meanings, name readings (nanori), school "
        "grade, newspaper frequency rank, former (pre-2010) JLPT level and "
        "variant-kanji links. Non-English meanings, query codes and dictionary "
        "index numbers are not included.</p>"
        f"<p>KANJIDIC2 database version {db_version} ({db_date}). Copyright James "
        "William Breen and the Electronic Dictionary Research and Development Group "
        "(EDRDG), used in conformance with the Group's "
        "<a href='https://www.edrdg.org/edrdg/licence.html'>licence</a>, under "
        "<a href='https://creativecommons.org/licenses/by-sa/4.0/'>CC BY-SA 4.0</a>. "
        "Pinyin readings © Christian Wittern and Koichi Yasuoka; Korean readings © "
        "Charles Muller (included in KANJIDIC2 with their permission).</p>"
        "<p>Source: <a href='https://www.edrdg.org/wiki/index.php/KANJIDIC_Project'>"
        "KANJIDIC Project</a>. Converted to MDict, abridged and reformatted by "
        "OpenMDict; this adaptation is shared under CC BY-SA 4.0.</p>"
    )
    success, size_mb, _ = pack_mdx(txt_path, "KANJIDIC2 — Kanji Dictionary", desc_html,
                                   mdx_path, inputs=[DATA_DIR])
    if not success:
        return
    print(f"  ✓ {mdx_path.name}: {size_mb:.1f} MB, {count} entries")

    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name="KANJIDIC2 漢字",
        description=(f"{count:,} kanji with stroke counts, radicals, on/kun/pinyin/Korean/"
                     "Vietnamese readings, English meanings, school grade, former JLPT "
                     f"level and variant links. KANJIDIC2 {db_version}."),
        direction={"src": "JA", "dest": ["EN"]},
        entries=count,
        license="CC-BY-SA-4.0",
        data_source=f"KANJIDIC2 (EDRDG), database version {db_version}",
        tier=2,
    )

    _generate_preview(entries)


if __name__ == '__main__':
    main()
