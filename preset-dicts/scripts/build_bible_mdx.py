#!/usr/bin/env python3
"""
Build the 14 Bible MDX dictionaries from OSIS, USFX, Zefania, SWORD, MediaWiki
and Markdown sources.

  File                 Translation                              Source (data/bible/…)
  Bible-KJV-EN         King James Version, 1769 text            open-bibles eng-kjv           kjv.osis.xml
  Bible-CUV-ZH-Hans    官话和合译本 1919 (simplified, OpenCC)   Chinese Wikisource            zhwikisource-cuv1919/*.wiki
  Bible-CUV-ZH-Hant    官話和合譯本 1919 (traditional)          Chinese Wikisource            zhwikisource-cuv1919/*.wiki
  Bible-Kougo-JA       文語訳 (明治元訳 OT 1887, 大正改訳 NT 1917) CrossWire JapBungo 2.0       crosswire/JapBungo-2.0.zip
  Bible-RV1909-ES      Reina-Valera 1909                        open-bibles spa-rv1909        spa-rv1909.usfx.xml
  Bible-Darby-FR       J. N. Darby (French)                     gratis-bible fr/frdarb        fra-darby.osis.xml
  Bible-Luther1912-DE  Luther 1912                              open-bibles deu-luther1912    deu-luther1912.osis.xml
  Bible-Almeida-PT     Almeida Revista e Corrigida (1911)       Gutenberg #62383 via          biblia-arc1911-eda2823/canon/
                                                                mazza/biblia-arc1911
  Bible-Synodal-RU     Synodal (1876)                           open-bibles rus-synodal       rus-synodal.zefania.xml
  Bible-Korean-KO      개역한글 (1952/1961)                     CrossWire KorRV 2.0.1         crosswire/KorRV-2.0.1.zip
  Bible-SVD-AR         Smith–Van Dyck (1865)                    gratis-bible ar/arasvd        ar-svd.osis.xml
  Bible-Diodati-IT     Diodati (revised text)                   gratis-bible it/itadio        it-diodati.osis.xml
  Bible-Vulgate-LA     Clementine Vulgate (73 books)            open-bibles lat-clementine    open-bibles-f257a35/lat-clementine.usfx.xml
  Bible-Byzantine-GRC  1904 Patriarchal Greek NT                eBible.org grcbyz             grc-byzantine.usfx.xml

Entry structure:
  - One entry per chapter, keyed by the English name: "Genesis 1". (The
    Vulgate's Psalms are keyed by their own, LXX number: "Psalmi 22".)
  - @@@LINK aliases → that chapter: local names ("创世记 1"), common
    alternative names and abbreviations ("Gen 1", "约3", "요 3장", "Пс 22"),
    forms users type without marks (monotonic/unaccented Greek, Latin names
    without accents, Arabic without hamza, Arabic-Indic digits), and verse
    references that open the chapter ("John 3:16", "约3:16", "Joh 3,16",
    "Jn 3:16", "ヨハネ3:16", "Пс 22:1" in the Synodal psalm numbering).

Parsing walks every source document in order (milestone and containment
verses, text inside child elements, notes, psalm superscriptions), so no text
is lost at element or read-buffer boundaries. Build gates stop the build when
a source book is not mapped, a book or chapter is missing, a chapter count
differs from the expected versification, a chapter holds far more or fewer
verses than the KJV table (a mislabelled or overlaid chapter), the parsed
verse count differs from an independent count of the source, a verse is
empty, or a local or legacy alias collides with another chapter's key.

Usage:
    python3 build_bible_mdx.py [Bible-Name ...]

Input:  ../data/bible/…   (see scripts/fetch_data.sh, fetch_bible)
Output: ../output/Bible-*/Bible-*.mdx

Bible-CUV-ZH-Hans needs the OpenCC Python package: pip install opencc==1.4.2
"""

import hashlib
import re
import struct
from collections import Counter
import sys
import unicodedata
import xml.etree.ElementTree as ET
import zipfile
import zlib
from pathlib import Path

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, SENSE_NUMBER_INLINE, TEXT_SECONDARY, TEXT_LINK
from shared.html import esc, esc_attr, dir_attr, wrap_entry, strip_bidi_controls
from shared.build import (pack_mdx as _shared_pack_mdx, generate_preview as _shared_preview,
                          write_mdict_source, write_catalog_metadata)

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data" / "bible"
OUTPUT_BASE = SCRIPT_DIR.parent / "output"


class BuildError(Exception):
    """A build gate failed: the dictionary is not written."""


# ── Canon ─────────────────────────────────────────────────────
# (OSIS code, USFX code, English name). Order = canonical Protestant order.

CANON = [
    ("Gen", "GEN", "Genesis"), ("Exod", "EXO", "Exodus"), ("Lev", "LEV", "Leviticus"),
    ("Num", "NUM", "Numbers"), ("Deut", "DEU", "Deuteronomy"), ("Josh", "JOS", "Joshua"),
    ("Judg", "JDG", "Judges"), ("Ruth", "RUT", "Ruth"), ("1Sam", "1SA", "1 Samuel"),
    ("2Sam", "2SA", "2 Samuel"), ("1Kgs", "1KI", "1 Kings"), ("2Kgs", "2KI", "2 Kings"),
    ("1Chr", "1CH", "1 Chronicles"), ("2Chr", "2CH", "2 Chronicles"), ("Ezra", "EZR", "Ezra"),
    ("Neh", "NEH", "Nehemiah"), ("Esth", "EST", "Esther"), ("Job", "JOB", "Job"),
    ("Ps", "PSA", "Psalms"), ("Prov", "PRO", "Proverbs"), ("Eccl", "ECC", "Ecclesiastes"),
    ("Song", "SNG", "Song of Solomon"), ("Isa", "ISA", "Isaiah"), ("Jer", "JER", "Jeremiah"),
    ("Lam", "LAM", "Lamentations"), ("Ezek", "EZK", "Ezekiel"), ("Dan", "DAN", "Daniel"),
    ("Hos", "HOS", "Hosea"), ("Joel", "JOL", "Joel"), ("Amos", "AMO", "Amos"),
    ("Obad", "OBA", "Obadiah"), ("Jonah", "JON", "Jonah"), ("Mic", "MIC", "Micah"),
    ("Nah", "NAM", "Nahum"), ("Hab", "HAB", "Habakkuk"), ("Zeph", "ZEP", "Zephaniah"),
    ("Hag", "HAG", "Haggai"), ("Zech", "ZEC", "Zechariah"), ("Mal", "MAL", "Malachi"),
    ("Matt", "MAT", "Matthew"), ("Mark", "MRK", "Mark"), ("Luke", "LUK", "Luke"),
    ("John", "JHN", "John"), ("Acts", "ACT", "Acts"), ("Rom", "ROM", "Romans"),
    ("1Cor", "1CO", "1 Corinthians"), ("2Cor", "2CO", "2 Corinthians"), ("Gal", "GAL", "Galatians"),
    ("Eph", "EPH", "Ephesians"), ("Phil", "PHP", "Philippians"), ("Col", "COL", "Colossians"),
    ("1Thess", "1TH", "1 Thessalonians"), ("2Thess", "2TH", "2 Thessalonians"),
    ("1Tim", "1TI", "1 Timothy"), ("2Tim", "2TI", "2 Timothy"), ("Titus", "TIT", "Titus"),
    ("Phlm", "PHM", "Philemon"), ("Heb", "HEB", "Hebrews"), ("Jas", "JAS", "James"),
    ("1Pet", "1PE", "1 Peter"), ("2Pet", "2PE", "2 Peter"), ("1John", "1JN", "1 John"),
    ("2John", "2JN", "2 John"), ("3John", "3JN", "3 John"), ("Jude", "JUD", "Jude"),
    ("Rev", "REV", "Revelation"),
]

# Deuterocanonical books of the Vulgate (kept only where a config asks for them).
DEUTERO = [
    ("Tob", "TOB", "Tobit"), ("Jdt", "JDT", "Judith"), ("Wis", "WIS", "Wisdom"),
    ("Sir", "SIR", "Sirach"), ("Bar", "BAR", "Baruch"),
    ("1Macc", "1MA", "1 Maccabees"), ("2Macc", "2MA", "2 Maccabees"),
]

OSIS_BOOK_NAMES = {o: e for o, _, e in CANON + DEUTERO}
USFX_BOOK_NAMES = {u: e for _, u, e in CANON + DEUTERO}
BOOK_ORDER = [e for _, _, e in CANON]
BOOK_ORDER_CATHOLIC = [  # Clementine order
    "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua", "Judges", "Ruth",
    "1 Samuel", "2 Samuel", "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra",
    "Nehemiah", "Tobit", "Judith", "Esther", "Job", "Psalms", "Proverbs", "Ecclesiastes",
    "Song of Solomon", "Wisdom", "Sirach", "Isaiah", "Jeremiah", "Lamentations", "Baruch",
    "Ezekiel", "Daniel", "Hosea", "Joel", "Amos", "Obadiah", "Jonah", "Micah", "Nahum",
    "Habakkuk", "Zephaniah", "Haggai", "Zechariah", "Malachi", "1 Maccabees", "2 Maccabees",
] + BOOK_ORDER[39:]
NT_BOOKS = frozenset(BOOK_ORDER[39:])
# Zefania bnumber (1-based) → English name
ZEFANIA_BOOK_ORDER = BOOK_ORDER

# KJV versification: verses per chapter for the 66 books (31,102 verses,
# 1,189 chapters). Used for the chapter-count gate and to index the SWORD
# KorRV module (NRSV versification = KJV + 3 John 1:15 and Rev 12:18).
_KJV_VERSES = """
GEN 31,25,24,26,32,22,24,22,29,32,32,20,18,24,21,16,27,33,38,18,34,24,20,67,34,35,46,22,35,43,55,32,20,31,29,43,36,30,23,23,57,38,34,34,28,34,31,22,33,26
EXO 22,25,22,31,23,30,25,32,35,29,10,51,22,31,27,36,16,27,25,26,36,31,33,18,40,37,21,43,46,38,18,35,23,35,35,38,29,31,43,38
LEV 17,16,17,35,19,30,38,36,24,20,47,8,59,57,33,34,16,30,37,27,24,33,44,23,55,46,34
NUM 54,34,51,49,31,27,89,26,23,36,35,16,33,45,41,50,13,32,22,29,35,41,30,25,18,65,23,31,40,16,54,42,56,29,34,13
DEU 46,37,29,49,33,25,26,20,29,22,32,32,18,29,23,22,20,22,21,20,23,30,25,22,19,19,26,68,29,20,30,52,29,12
JOS 18,24,17,24,15,27,26,35,27,43,23,24,33,15,63,10,18,28,51,9,45,34,16,33
JDG 36,23,31,24,31,40,25,35,57,18,40,15,25,20,20,31,13,31,30,48,25
RUT 22,23,18,22
1SA 28,36,21,22,12,21,17,22,27,27,15,25,23,52,35,23,58,30,24,42,15,23,29,22,44,25,12,25,11,31,13
2SA 27,32,39,12,25,23,29,18,13,19,27,31,39,33,37,23,29,33,43,26,22,51,39,25
1KI 53,46,28,34,18,38,51,66,28,29,43,33,34,31,34,34,24,46,21,43,29,53
2KI 18,25,27,44,27,33,20,29,37,36,21,21,25,29,38,20,41,37,37,21,26,20,37,20,30
1CH 54,55,24,43,26,81,40,40,44,14,47,40,14,17,29,43,27,17,19,8,30,19,32,31,31,32,34,21,30
2CH 17,18,17,22,14,42,22,18,31,19,23,16,22,15,19,14,19,34,11,37,20,12,21,27,28,23,9,27,36,27,21,33,25,33,27,23
EZR 11,70,13,24,17,22,28,36,15,44
NEH 11,20,32,23,19,19,73,18,38,39,36,47,31
EST 22,23,15,17,14,14,10,17,32,3
JOB 22,13,26,21,27,30,21,22,35,22,20,25,28,22,35,22,16,21,29,29,34,30,17,25,6,14,23,28,25,31,40,22,33,37,16,33,24,41,30,24,34,17
PSA 6,12,8,8,12,10,17,9,20,18,7,8,6,7,5,11,15,50,14,9,13,31,6,10,22,12,14,9,11,12,24,11,22,22,28,12,40,22,13,17,13,11,5,26,17,11,9,14,20,23,19,9,6,7,23,13,11,11,17,12,8,12,11,10,13,20,7,35,36,5,24,20,28,23,10,12,20,72,13,19,16,8,18,12,13,17,7,18,52,17,16,15,5,23,11,13,12,9,9,5,8,28,22,35,45,48,43,13,31,7,10,10,9,8,18,19,2,29,176,7,8,9,4,8,5,6,5,6,8,8,3,18,3,3,21,26,9,8,24,13,10,7,12,15,21,10,20,14,9,6
PRO 33,22,35,27,23,35,27,36,18,32,31,28,25,35,33,33,28,24,29,30,31,29,35,34,28,28,27,28,27,33,31
ECC 18,26,22,16,20,12,29,17,18,20,10,14
SNG 17,17,11,16,16,13,13,14
ISA 31,22,26,6,30,13,25,22,21,34,16,6,22,32,9,14,14,7,25,6,17,25,18,23,12,21,13,29,24,33,9,20,24,17,10,22,38,22,8,31,29,25,28,28,25,13,15,22,26,11,23,15,12,17,13,12,21,14,21,22,11,12,19,12,25,24
JER 19,37,25,31,31,30,34,22,26,25,23,17,27,22,21,21,27,23,15,18,14,30,40,10,38,24,22,17,32,24,40,44,26,22,19,32,21,28,18,16,18,22,13,30,5,28,7,47,39,46,64,34
LAM 22,22,66,22,22
EZK 28,10,27,17,17,14,27,18,11,22,25,28,23,23,8,63,24,32,14,49,32,31,49,27,17,21,36,26,21,26,18,32,33,31,15,38,28,23,29,49,26,20,27,31,25,24,23,35
DAN 21,49,30,37,31,28,28,27,27,21,45,13
HOS 11,23,5,19,15,11,16,14,17,15,12,14,16,9
JOL 20,32,21
AMO 15,16,15,13,27,14,17,14,15
OBA 21
JON 17,10,10,11
MIC 16,13,12,13,15,16,20
NAM 15,13,19
HAB 17,20,19
ZEP 18,15,20
HAG 15,23
ZEC 21,13,10,14,11,15,14,23,17,12,17,14,9,21
MAL 14,17,18,6
MAT 25,23,17,25,48,34,29,34,38,42,30,50,58,36,39,28,27,35,30,34,46,46,39,51,46,75,66,20
MRK 45,28,35,41,43,56,37,38,50,52,33,44,37,72,47,20
LUK 80,52,38,44,39,49,50,56,62,42,54,59,35,35,32,31,37,43,48,47,38,71,56,53
JHN 51,25,36,54,47,71,53,59,41,42,57,50,38,31,27,33,26,40,42,31,25
ACT 26,47,26,37,42,15,60,40,43,48,30,25,52,28,41,40,34,28,41,38,40,30,35,27,27,32,44,31
ROM 32,29,31,25,21,23,25,39,33,21,36,21,14,23,33,27
1CO 31,16,23,21,13,20,40,13,27,33,34,31,13,40,58,24
2CO 24,17,18,18,21,18,16,24,15,18,33,21,14
GAL 24,21,29,31,26,18
EPH 23,22,21,32,33,24
PHP 30,30,21,23
COL 29,23,25,18
1TH 10,20,13,18,28
2TH 12,17,18
1TI 20,15,16,16,25,21
2TI 18,26,17,22
TIT 16,15,15
PHM 25
HEB 14,18,19,16,14,20,28,13,28,39,40,29,25
JAS 27,26,18,17,20
1PE 25,25,22,19,14
2PE 21,22,18
1JN 10,29,24,21,21
2JN 13
3JN 14
JUD 25
REV 20,29,22,11,14,17,17,13,21,11,19,17,18,20,8,21,18,24,21,15,27,21
"""
KJV_VERSES = {}   # English name → [verses in chapter 1, 2, …]
for _line in _KJV_VERSES.strip().splitlines():
    _code, _counts = _line.split()
    KJV_VERSES[USFX_BOOK_NAMES[_code]] = [int(n) for n in _counts.split(',')]
assert sum(map(sum, KJV_VERSES.values())) == 31102 and len(KJV_VERSES) == 66
# Chapters per deuterocanonical book (Vulgate)
DEUTERO_CHAPTERS = {"Tobit": 14, "Judith": 16, "Wisdom": 19, "Sirach": 51,
                    "Baruch": 6, "1 Maccabees": 16, "2 Maccabees": 15}

# ── Local book name maps (display names) ──────────────────────

ZH_HANS_BOOK_NAMES = {
    "Genesis": "创世记", "Exodus": "出埃及记", "Leviticus": "利未记",
    "Numbers": "民数记", "Deuteronomy": "申命记", "Joshua": "约书亚记",
    "Judges": "士师记", "Ruth": "路得记", "1 Samuel": "撒母耳记上",
    "2 Samuel": "撒母耳记下", "1 Kings": "列王纪上", "2 Kings": "列王纪下",
    "1 Chronicles": "历代志上", "2 Chronicles": "历代志下", "Ezra": "以斯拉记",
    "Nehemiah": "尼希米记", "Esther": "以斯帖记", "Job": "约伯记",
    "Psalms": "诗篇", "Proverbs": "箴言", "Ecclesiastes": "传道书",
    "Song of Solomon": "雅歌", "Isaiah": "以赛亚书", "Jeremiah": "耶利米书",
    "Lamentations": "耶利米哀歌", "Ezekiel": "以西结书", "Daniel": "但以理书",
    "Hosea": "何西阿书", "Joel": "约珥书", "Amos": "阿摩司书",
    "Obadiah": "俄巴底亚书", "Jonah": "约拿书", "Micah": "弥迦书",
    "Nahum": "那鸿书", "Habakkuk": "哈巴谷书", "Zephaniah": "西番雅书",
    "Haggai": "哈该书", "Zechariah": "撒迦利亚书", "Malachi": "玛拉基书",
    "Matthew": "马太福音", "Mark": "马可福音", "Luke": "路加福音",
    "John": "约翰福音", "Acts": "使徒行传", "Romans": "罗马书",
    "1 Corinthians": "哥林多前书", "2 Corinthians": "哥林多后书",
    "Galatians": "加拉太书", "Ephesians": "以弗所书", "Philippians": "腓立比书",
    "Colossians": "歌罗西书", "1 Thessalonians": "帖撒罗尼迦前书",
    "2 Thessalonians": "帖撒罗尼迦后书", "1 Timothy": "提摩太前书",
    "2 Timothy": "提摩太后书", "Titus": "提多书", "Philemon": "腓利门书",
    "Hebrews": "希伯来书", "James": "雅各书", "1 Peter": "彼得前书",
    "2 Peter": "彼得后书", "1 John": "约翰一书", "2 John": "约翰二书",
    "3 John": "约翰三书", "Jude": "犹大书", "Revelation": "启示录",
}

ZH_HANT_BOOK_NAMES = {
    "Genesis": "創世記", "Exodus": "出埃及記", "Leviticus": "利未記",
    "Numbers": "民數記", "Deuteronomy": "申命記", "Joshua": "約書亞記",
    "Judges": "士師記", "Ruth": "路得記", "1 Samuel": "撒母耳記上",
    "2 Samuel": "撒母耳記下", "1 Kings": "列王紀上", "2 Kings": "列王紀下",
    "1 Chronicles": "歷代志上", "2 Chronicles": "歷代志下", "Ezra": "以斯拉記",
    "Nehemiah": "尼希米記", "Esther": "以斯帖記", "Job": "約伯記",
    "Psalms": "詩篇", "Proverbs": "箴言", "Ecclesiastes": "傳道書",
    "Song of Solomon": "雅歌", "Isaiah": "以賽亞書", "Jeremiah": "耶利米書",
    "Lamentations": "耶利米哀歌", "Ezekiel": "以西結書", "Daniel": "但以理書",
    "Hosea": "何西阿書", "Joel": "約珥書", "Amos": "阿摩司書",
    "Obadiah": "俄巴底亞書", "Jonah": "約拿書", "Micah": "彌迦書",
    "Nahum": "那鴻書", "Habakkuk": "哈巴谷書", "Zephaniah": "西番雅書",
    "Haggai": "哈該書", "Zechariah": "撒迦利亞書", "Malachi": "瑪拉基書",
    "Matthew": "馬太福音", "Mark": "馬可福音", "Luke": "路加福音",
    "John": "約翰福音", "Acts": "使徒行傳", "Romans": "羅馬書",
    "1 Corinthians": "哥林多前書", "2 Corinthians": "哥林多後書",
    "Galatians": "加拉太書", "Ephesians": "以弗所書", "Philippians": "腓立比書",
    "Colossians": "歌羅西書", "1 Thessalonians": "帖撒羅尼迦前書",
    "2 Thessalonians": "帖撒羅尼迦後書", "1 Timothy": "提摩太前書",
    "2 Timothy": "提摩太後書", "Titus": "提多書", "Philemon": "腓利門書",
    "Hebrews": "希伯來書", "James": "雅各書", "1 Peter": "彼得前書",
    "2 Peter": "彼得後書", "1 John": "約翰一書", "2 John": "約翰二書",
    "3 John": "約翰三書", "Jude": "猶大書", "Revelation": "啟示錄",
}

JA_BOOK_NAMES = {
    "Genesis": "創世記", "Exodus": "出エジプト記", "Leviticus": "レビ記",
    "Numbers": "民数記", "Deuteronomy": "申命記", "Joshua": "ヨシュア記",
    "Judges": "士師記", "Ruth": "ルツ記", "1 Samuel": "サムエル記上",
    "2 Samuel": "サムエル記下", "1 Kings": "列王紀上", "2 Kings": "列王紀下",
    "1 Chronicles": "歴代志上", "2 Chronicles": "歴代志下", "Ezra": "エズラ記",
    "Nehemiah": "ネヘミヤ記", "Esther": "エステル記", "Job": "ヨブ記",
    "Psalms": "詩篇", "Proverbs": "箴言", "Ecclesiastes": "伝道の書",
    "Song of Solomon": "雅歌", "Isaiah": "イザヤ書", "Jeremiah": "エレミヤ書",
    "Lamentations": "哀歌", "Ezekiel": "エゼキエル書", "Daniel": "ダニエル書",
    "Hosea": "ホセア書", "Joel": "ヨエル書", "Amos": "アモス書",
    "Obadiah": "オバデヤ書", "Jonah": "ヨナ書", "Micah": "ミカ書",
    "Nahum": "ナホム書", "Habakkuk": "ハバクク書", "Zephaniah": "ゼパニヤ書",
    "Haggai": "ハガイ書", "Zechariah": "ゼカリヤ書", "Malachi": "マラキ書",
    "Matthew": "マタイによる福音書", "Mark": "マルコによる福音書",
    "Luke": "ルカによる福音書", "John": "ヨハネによる福音書",
    "Acts": "使徒行伝", "Romans": "ローマ人への手紙",
    "1 Corinthians": "コリント人への第一の手紙", "2 Corinthians": "コリント人への第二の手紙",
    "Galatians": "ガラテヤ人への手紙", "Ephesians": "エペソ人への手紙",
    "Philippians": "ピリピ人への手紙", "Colossians": "コロサイ人への手紙",
    "1 Thessalonians": "テサロニケ人への第一の手紙", "2 Thessalonians": "テサロニケ人への第二の手紙",
    "1 Timothy": "テモテへの第一の手紙", "2 Timothy": "テモテへの第二の手紙",
    "Titus": "テトスへの手紙", "Philemon": "ピレモンへの手紙",
    "Hebrews": "ヘブル人への手紙", "James": "ヤコブの手紙",
    "1 Peter": "ペテロの第一の手紙", "2 Peter": "ペテロの第二の手紙",
    "1 John": "ヨハネの第一の手紙", "2 John": "ヨハネの第二の手紙",
    "3 John": "ヨハネの第三の手紙", "Jude": "ユダの手紙", "Revelation": "ヨハネの黙示録",
}

ES_BOOK_NAMES = {
    "Genesis": "Génesis", "Exodus": "Éxodo", "Leviticus": "Levítico",
    "Numbers": "Números", "Deuteronomy": "Deuteronomio", "Joshua": "Josué",
    "Judges": "Jueces", "Ruth": "Rut", "1 Samuel": "1 Samuel",
    "2 Samuel": "2 Samuel", "1 Kings": "1 Reyes", "2 Kings": "2 Reyes",
    "1 Chronicles": "1 Crónicas", "2 Chronicles": "2 Crónicas", "Ezra": "Esdras",
    "Nehemiah": "Nehemías", "Esther": "Ester", "Job": "Job",
    "Psalms": "Salmos", "Proverbs": "Proverbios", "Ecclesiastes": "Eclesiastés",
    "Song of Solomon": "Cantares", "Isaiah": "Isaías", "Jeremiah": "Jeremías",
    "Lamentations": "Lamentaciones", "Ezekiel": "Ezequiel", "Daniel": "Daniel",
    "Hosea": "Oseas", "Joel": "Joel", "Amos": "Amós",
    "Obadiah": "Abdías", "Jonah": "Jonás", "Micah": "Miqueas",
    "Nahum": "Nahúm", "Habakkuk": "Habacuc", "Zephaniah": "Sofonías",
    "Haggai": "Hageo", "Zechariah": "Zacarías", "Malachi": "Malaquías",
    "Matthew": "Mateo", "Mark": "Marcos", "Luke": "Lucas",
    "John": "Juan", "Acts": "Hechos", "Romans": "Romanos",
    "1 Corinthians": "1 Corintios", "2 Corinthians": "2 Corintios",
    "Galatians": "Gálatas", "Ephesians": "Efesios", "Philippians": "Filipenses",
    "Colossians": "Colosenses", "1 Thessalonians": "1 Tesalonicenses",
    "2 Thessalonians": "2 Tesalonicenses", "1 Timothy": "1 Timoteo",
    "2 Timothy": "2 Timoteo", "Titus": "Tito", "Philemon": "Filemón",
    "Hebrews": "Hebreos", "James": "Santiago", "1 Peter": "1 Pedro",
    "2 Peter": "2 Pedro", "1 John": "1 Juan", "2 John": "2 Juan",
    "3 John": "3 Juan", "Jude": "Judas", "Revelation": "Apocalipsis",
}

FR_BOOK_NAMES = {
    "Genesis": "Genèse", "Exodus": "Exode", "Leviticus": "Lévitique",
    "Numbers": "Nombres", "Deuteronomy": "Deutéronome", "Joshua": "Josué",
    "Judges": "Juges", "Ruth": "Ruth", "1 Samuel": "1 Samuel",
    "2 Samuel": "2 Samuel", "1 Kings": "1 Rois", "2 Kings": "2 Rois",
    "1 Chronicles": "1 Chroniques", "2 Chronicles": "2 Chroniques", "Ezra": "Esdras",
    "Nehemiah": "Néhémie", "Esther": "Esther", "Job": "Job",
    "Psalms": "Psaumes", "Proverbs": "Proverbes", "Ecclesiastes": "Ecclésiaste",
    "Song of Solomon": "Cantique des Cantiques", "Isaiah": "Ésaïe", "Jeremiah": "Jérémie",
    "Lamentations": "Lamentations", "Ezekiel": "Ézéchiel", "Daniel": "Daniel",
    "Hosea": "Osée", "Joel": "Joël", "Amos": "Amos",
    "Obadiah": "Abdias", "Jonah": "Jonas", "Micah": "Michée",
    "Nahum": "Nahum", "Habakkuk": "Habakuk", "Zephaniah": "Sophonie",
    "Haggai": "Aggée", "Zechariah": "Zacharie", "Malachi": "Malachie",
    "Matthew": "Matthieu", "Mark": "Marc", "Luke": "Luc",
    "John": "Jean", "Acts": "Actes", "Romans": "Romains",
    "1 Corinthians": "1 Corinthiens", "2 Corinthians": "2 Corinthiens",
    "Galatians": "Galates", "Ephesians": "Éphésiens", "Philippians": "Philippiens",
    "Colossians": "Colossiens", "1 Thessalonians": "1 Thessaloniciens",
    "2 Thessalonians": "2 Thessaloniciens", "1 Timothy": "1 Timothée",
    "2 Timothy": "2 Timothée", "Titus": "Tite", "Philemon": "Philémon",
    "Hebrews": "Hébreux", "James": "Jacques", "1 Peter": "1 Pierre",
    "2 Peter": "2 Pierre", "1 John": "1 Jean", "2 John": "2 Jean",
    "3 John": "3 Jean", "Jude": "Jude", "Revelation": "Apocalypse",
}

DE_BOOK_NAMES = {
    "Genesis": "1. Mose", "Exodus": "2. Mose", "Leviticus": "3. Mose",
    "Numbers": "4. Mose", "Deuteronomy": "5. Mose", "Joshua": "Josua",
    "Judges": "Richter", "Ruth": "Ruth", "1 Samuel": "1. Samuel",
    "2 Samuel": "2. Samuel", "1 Kings": "1. Könige", "2 Kings": "2. Könige",
    "1 Chronicles": "1. Chronik", "2 Chronicles": "2. Chronik", "Ezra": "Esra",
    "Nehemiah": "Nehemia", "Esther": "Esther", "Job": "Hiob",
    "Psalms": "Psalmen", "Proverbs": "Sprüche", "Ecclesiastes": "Prediger",
    "Song of Solomon": "Hohelied", "Isaiah": "Jesaja", "Jeremiah": "Jeremia",
    "Lamentations": "Klagelieder", "Ezekiel": "Hesekiel", "Daniel": "Daniel",
    "Hosea": "Hosea", "Joel": "Joel", "Amos": "Amos",
    "Obadiah": "Obadja", "Jonah": "Jona", "Micah": "Micha",
    "Nahum": "Nahum", "Habakkuk": "Habakuk", "Zephaniah": "Zephanja",
    "Haggai": "Haggai", "Zechariah": "Sacharja", "Malachi": "Maleachi",
    "Matthew": "Matthäus", "Mark": "Markus", "Luke": "Lukas",
    "John": "Johannes", "Acts": "Apostelgeschichte", "Romans": "Römer",
    "1 Corinthians": "1. Korinther", "2 Corinthians": "2. Korinther",
    "Galatians": "Galater", "Ephesians": "Epheser", "Philippians": "Philipper",
    "Colossians": "Kolosser", "1 Thessalonians": "1. Thessalonicher",
    "2 Thessalonians": "2. Thessalonicher", "1 Timothy": "1. Timotheus",
    "2 Timothy": "2. Timotheus", "Titus": "Titus", "Philemon": "Philemon",
    "Hebrews": "Hebräer", "James": "Jakobus", "1 Peter": "1. Petrus",
    "2 Peter": "2. Petrus", "1 John": "1. Johannes", "2 John": "2. Johannes",
    "3 John": "3. Johannes", "Jude": "Judas", "Revelation": "Offenbarung",
}

PT_BOOK_NAMES = {
    "Genesis": "Gênesis", "Exodus": "Êxodo", "Leviticus": "Levítico",
    "Numbers": "Números", "Deuteronomy": "Deuteronômio", "Joshua": "Josué",
    "Judges": "Juízes", "Ruth": "Rute", "1 Samuel": "1 Samuel",
    "2 Samuel": "2 Samuel", "1 Kings": "1 Reis", "2 Kings": "2 Reis",
    "1 Chronicles": "1 Crônicas", "2 Chronicles": "2 Crônicas", "Ezra": "Esdras",
    "Nehemiah": "Neemias", "Esther": "Ester", "Job": "Jó",
    "Psalms": "Salmos", "Proverbs": "Provérbios", "Ecclesiastes": "Eclesiastes",
    "Song of Solomon": "Cânticos", "Isaiah": "Isaías", "Jeremiah": "Jeremias",
    "Lamentations": "Lamentações", "Ezekiel": "Ezequiel", "Daniel": "Daniel",
    "Hosea": "Oséias", "Joel": "Joel", "Amos": "Amós",
    "Obadiah": "Obadias", "Jonah": "Jonas", "Micah": "Miquéias",
    "Nahum": "Naum", "Habakkuk": "Habacuque", "Zephaniah": "Sofonias",
    "Haggai": "Ageu", "Zechariah": "Zacarias", "Malachi": "Malaquias",
    "Matthew": "Mateus", "Mark": "Marcos", "Luke": "Lucas",
    "John": "João", "Acts": "Atos", "Romans": "Romanos",
    "1 Corinthians": "1 Coríntios", "2 Corinthians": "2 Coríntios",
    "Galatians": "Gálatas", "Ephesians": "Efésios", "Philippians": "Filipenses",
    "Colossians": "Colossenses", "1 Thessalonians": "1 Tessalonicenses",
    "2 Thessalonians": "2 Tessalonicenses", "1 Timothy": "1 Timóteo",
    "2 Timothy": "2 Timóteo", "Titus": "Tito", "Philemon": "Filemom",
    "Hebrews": "Hebreus", "James": "Tiago", "1 Peter": "1 Pedro",
    "2 Peter": "2 Pedro", "1 John": "1 João", "2 John": "2 João",
    "3 John": "3 João", "Jude": "Judas", "Revelation": "Apocalipse",
}

RU_BOOK_NAMES = {
    "Genesis": "Бытие", "Exodus": "Исход", "Leviticus": "Левит",
    "Numbers": "Числа", "Deuteronomy": "Второзаконие", "Joshua": "Иисус Навин",
    "Judges": "Судей", "Ruth": "Руфь", "1 Samuel": "1 Царств",
    "2 Samuel": "2 Царств", "1 Kings": "3 Царств", "2 Kings": "4 Царств",
    "1 Chronicles": "1 Паралипоменон", "2 Chronicles": "2 Паралипоменон", "Ezra": "Ездра",
    "Nehemiah": "Неемия", "Esther": "Есфирь", "Job": "Иов",
    "Psalms": "Псалтирь", "Proverbs": "Притчи", "Ecclesiastes": "Екклесиаст",
    "Song of Solomon": "Песнь Песней", "Isaiah": "Исаия", "Jeremiah": "Иеремия",
    "Lamentations": "Плач Иеремии", "Ezekiel": "Иезекииль", "Daniel": "Даниил",
    "Hosea": "Осия", "Joel": "Иоиль", "Amos": "Амос",
    "Obadiah": "Авдий", "Jonah": "Иона", "Micah": "Михей",
    "Nahum": "Наум", "Habakkuk": "Аввакум", "Zephaniah": "Софония",
    "Haggai": "Аггей", "Zechariah": "Захария", "Malachi": "Малахия",
    "Matthew": "Матфей", "Mark": "Марк", "Luke": "Лука",
    "John": "Иоанн", "Acts": "Деяния", "Romans": "Римлянам",
    "1 Corinthians": "1 Коринфянам", "2 Corinthians": "2 Коринфянам",
    "Galatians": "Галатам", "Ephesians": "Ефесянам", "Philippians": "Филиппийцам",
    "Colossians": "Колоссянам", "1 Thessalonians": "1 Фессалоникийцам",
    "2 Thessalonians": "2 Фессалоникийцам", "1 Timothy": "1 Тимофею",
    "2 Timothy": "2 Тимофею", "Titus": "Титу", "Philemon": "Филимону",
    "Hebrews": "Евреям", "James": "Иакова", "1 Peter": "1 Петра",
    "2 Peter": "2 Петра", "1 John": "1 Иоанна", "2 John": "2 Иоанна",
    "3 John": "3 Иоанна", "Jude": "Иуды", "Revelation": "Откровение",
}

# 개역한글 book names (1 John = 요한일서; 개역개정's 요한1서 is an alias)
KO_BOOK_NAMES = {
    "Genesis": "창세기", "Exodus": "출애굽기", "Leviticus": "레위기",
    "Numbers": "민수기", "Deuteronomy": "신명기", "Joshua": "여호수아",
    "Judges": "사사기", "Ruth": "룻기", "1 Samuel": "사무엘상",
    "2 Samuel": "사무엘하", "1 Kings": "열왕기상", "2 Kings": "열왕기하",
    "1 Chronicles": "역대상", "2 Chronicles": "역대하", "Ezra": "에스라",
    "Nehemiah": "느헤미야", "Esther": "에스더", "Job": "욥기",
    "Psalms": "시편", "Proverbs": "잠언", "Ecclesiastes": "전도서",
    "Song of Solomon": "아가", "Isaiah": "이사야", "Jeremiah": "예레미야",
    "Lamentations": "예레미야애가", "Ezekiel": "에스겔", "Daniel": "다니엘",
    "Hosea": "호세아", "Joel": "요엘", "Amos": "아모스",
    "Obadiah": "오바댜", "Jonah": "요나", "Micah": "미가",
    "Nahum": "나훔", "Habakkuk": "하박국", "Zephaniah": "스바냐",
    "Haggai": "학개", "Zechariah": "스가랴", "Malachi": "말라기",
    "Matthew": "마태복음", "Mark": "마가복음", "Luke": "누가복음",
    "John": "요한복음", "Acts": "사도행전", "Romans": "로마서",
    "1 Corinthians": "고린도전서", "2 Corinthians": "고린도후서",
    "Galatians": "갈라디아서", "Ephesians": "에베소서", "Philippians": "빌립보서",
    "Colossians": "골로새서", "1 Thessalonians": "데살로니가전서",
    "2 Thessalonians": "데살로니가후서", "1 Timothy": "디모데전서",
    "2 Timothy": "디모데후서", "Titus": "디도서", "Philemon": "빌레몬서",
    "Hebrews": "히브리서", "James": "야고보서", "1 Peter": "베드로전서",
    "2 Peter": "베드로후서", "1 John": "요한일서", "2 John": "요한이서",
    "3 John": "요한삼서", "Jude": "유다서", "Revelation": "요한계시록",
}

AR_BOOK_NAMES = {
    "Genesis": "التكوين", "Exodus": "الخروج", "Leviticus": "اللاويين",
    "Numbers": "العدد", "Deuteronomy": "التثنية", "Joshua": "يشوع",
    "Judges": "القضاة", "Ruth": "راعوث", "1 Samuel": "صموئيل الأول",
    "2 Samuel": "صموئيل الثاني", "1 Kings": "الملوك الأول", "2 Kings": "الملوك الثاني",
    "1 Chronicles": "أخبار الأيام الأول", "2 Chronicles": "أخبار الأيام الثاني", "Ezra": "عزرا",
    "Nehemiah": "نحميا", "Esther": "أستير", "Job": "أيوب",
    "Psalms": "المزامير", "Proverbs": "الأمثال", "Ecclesiastes": "الجامعة",
    "Song of Solomon": "نشيد الأنشاد", "Isaiah": "إشعياء", "Jeremiah": "إرميا",
    "Lamentations": "مراثي إرميا", "Ezekiel": "حزقيال", "Daniel": "دانيال",
    "Hosea": "هوشع", "Joel": "يوئيل", "Amos": "عاموس",
    "Obadiah": "عوبديا", "Jonah": "يونان", "Micah": "ميخا",
    "Nahum": "ناحوم", "Habakkuk": "حبقوق", "Zephaniah": "صفنيا",
    "Haggai": "حجي", "Zechariah": "زكريا", "Malachi": "ملاخي",
    "Matthew": "متى", "Mark": "مرقس", "Luke": "لوقا",
    "John": "يوحنا", "Acts": "أعمال الرسل", "Romans": "رومية",
    "1 Corinthians": "كورنثوس الأولى", "2 Corinthians": "كورنثوس الثانية",
    "Galatians": "غلاطية", "Ephesians": "أفسس", "Philippians": "فيلبي",
    "Colossians": "كولوسي", "1 Thessalonians": "تسالونيكي الأولى",
    "2 Thessalonians": "تسالونيكي الثانية", "1 Timothy": "تيموثاوس الأولى",
    "2 Timothy": "تيموثاوس الثانية", "Titus": "تيطس", "Philemon": "فليمون",
    "Hebrews": "العبرانيين", "James": "يعقوب", "1 Peter": "بطرس الأولى",
    "2 Peter": "بطرس الثانية", "1 John": "يوحنا الأولى", "2 John": "يوحنا الثانية",
    "3 John": "يوحنا الثالثة", "Jude": "يهوذا", "Revelation": "رؤيا يوحنا",
}

IT_BOOK_NAMES = {
    "Genesis": "Genesi", "Exodus": "Esodo", "Leviticus": "Levitico",
    "Numbers": "Numeri", "Deuteronomy": "Deuteronomio", "Joshua": "Giosuè",
    "Judges": "Giudici", "Ruth": "Rut", "1 Samuel": "1 Samuele",
    "2 Samuel": "2 Samuele", "1 Kings": "1 Re", "2 Kings": "2 Re",
    "1 Chronicles": "1 Cronache", "2 Chronicles": "2 Cronache", "Ezra": "Esdra",
    "Nehemiah": "Neemia", "Esther": "Ester", "Job": "Giobbe",
    "Psalms": "Salmi", "Proverbs": "Proverbi", "Ecclesiastes": "Ecclesiaste",
    "Song of Solomon": "Cantico dei Cantici", "Isaiah": "Isaia", "Jeremiah": "Geremia",
    "Lamentations": "Lamentazioni", "Ezekiel": "Ezechiele", "Daniel": "Daniele",
    "Hosea": "Osea", "Joel": "Gioele", "Amos": "Amos",
    "Obadiah": "Abdia", "Jonah": "Giona", "Micah": "Michea",
    "Nahum": "Nahum", "Habakkuk": "Abacuc", "Zephaniah": "Sofonia",
    "Haggai": "Aggeo", "Zechariah": "Zaccaria", "Malachi": "Malachia",
    "Matthew": "Matteo", "Mark": "Marco", "Luke": "Luca",
    "John": "Giovanni", "Acts": "Atti", "Romans": "Romani",
    "1 Corinthians": "1 Corinzi", "2 Corinthians": "2 Corinzi",
    "Galatians": "Galati", "Ephesians": "Efesini", "Philippians": "Filippesi",
    "Colossians": "Colossesi", "1 Thessalonians": "1 Tessalonicesi",
    "2 Thessalonians": "2 Tessalonicesi", "1 Timothy": "1 Timoteo",
    "2 Timothy": "2 Timoteo", "Titus": "Tito", "Philemon": "Filemone",
    "Hebrews": "Ebrei", "James": "Giacomo", "1 Peter": "1 Pietro",
    "2 Peter": "2 Pietro", "1 John": "1 Giovanni", "2 John": "2 Giovanni",
    "3 John": "3 Giovanni", "Jude": "Giuda", "Revelation": "Apocalisse",
}

# Clementine Vulgate book names (as in the edition: I–IV Regum = 1–2 Samuel,
# 1–2 Kings). Nova Vulgata spellings (I Samuelis, Iosue, …) are aliases.
LA_BOOK_NAMES = {
    "Genesis": "Genesis", "Exodus": "Exodus", "Leviticus": "Leviticus",
    "Numbers": "Numeri", "Deuteronomy": "Deuteronomium", "Joshua": "Josue",
    "Judges": "Judicum", "Ruth": "Ruth", "1 Samuel": "I Regum",
    "2 Samuel": "II Regum", "1 Kings": "III Regum", "2 Kings": "IV Regum",
    "1 Chronicles": "I Paralipomenon", "2 Chronicles": "II Paralipomenon", "Ezra": "Esdræ",
    "Nehemiah": "Nehemiæ", "Tobit": "Tobiæ", "Judith": "Judith", "Esther": "Esther",
    "Job": "Job", "Psalms": "Psalmi", "Proverbs": "Proverbia", "Ecclesiastes": "Ecclesiastes",
    "Song of Solomon": "Canticum Canticorum", "Wisdom": "Sapientia",
    "Sirach": "Ecclesiasticus", "Isaiah": "Isaias", "Jeremiah": "Jeremias",
    "Lamentations": "Lamentationes", "Baruch": "Baruch", "Ezekiel": "Ezechiel",
    "Daniel": "Daniel", "Hosea": "Osee", "Joel": "Joël", "Amos": "Amos",
    "Obadiah": "Abdias", "Jonah": "Jonas", "Micah": "Michæa",
    "Nahum": "Nahum", "Habakkuk": "Habacuc", "Zephaniah": "Sophonias",
    "Haggai": "Aggæus", "Zechariah": "Zacharias", "Malachi": "Malachias",
    "1 Maccabees": "I Machabæorum", "2 Maccabees": "II Machabæorum",
    "Matthew": "Matthæus", "Mark": "Marcus", "Luke": "Lucas",
    "John": "Joannes", "Acts": "Actus Apostolorum", "Romans": "Romanos",
    "1 Corinthians": "I Corinthios", "2 Corinthians": "II Corinthios",
    "Galatians": "Galatas", "Ephesians": "Ephesios", "Philippians": "Philippenses",
    "Colossians": "Colossenses", "1 Thessalonians": "I Thessalonicenses",
    "2 Thessalonians": "II Thessalonicenses", "1 Timothy": "I Timotheum",
    "2 Timothy": "II Timotheum", "Titus": "Titum", "Philemon": "Philemonem",
    "Hebrews": "Hebræos", "James": "Jacobi", "1 Peter": "I Petri",
    "2 Peter": "II Petri", "1 John": "I Joannis", "2 John": "II Joannis",
    "3 John": "III Joannis", "Jude": "Judæ", "Revelation": "Apocalypsis",
}

# ── Original-language book names (subtitle of Latin-script Bibles) ───
# OT: Hebrew (Masoretic) with vowel points; NT and deuterocanon: Greek.

HEBREW_BOOK_NAMES = {
    "Genesis": "בְּרֵאשִׁית", "Exodus": "שְׁמוֹת", "Leviticus": "וַיִּקְרָא",
    "Numbers": "בְּמִדְבַּר", "Deuteronomy": "דְּבָרִים", "Joshua": "יְהוֹשֻׁעַ",
    "Judges": "שׁוֹפְטִים", "Ruth": "רוּת", "1 Samuel": "שְׁמוּאֵל א׳",
    "2 Samuel": "שְׁמוּאֵל ב׳", "1 Kings": "מְלָכִים א׳", "2 Kings": "מְלָכִים ב׳",
    "1 Chronicles": "דִּבְרֵי הַיָּמִים א׳", "2 Chronicles": "דִּבְרֵי הַיָּמִים ב׳",
    "Ezra": "עֶזְרָא", "Nehemiah": "נְחֶמְיָה", "Esther": "אֶסְתֵּר", "Job": "אִיּוֹב",
    "Psalms": "תְּהִלִּים", "Proverbs": "מִשְׁלֵי", "Ecclesiastes": "קֹהֶלֶת",
    "Song of Solomon": "שִׁיר הַשִּׁירִים", "Isaiah": "יְשַׁעְיָהוּ",
    "Jeremiah": "יִרְמְיָהוּ", "Lamentations": "אֵיכָה", "Ezekiel": "יְחֶזְקֵאל",
    "Daniel": "דָּנִיֵּאל", "Hosea": "הוֹשֵׁעַ", "Joel": "יוֹאֵל", "Amos": "עָמוֹס",
    "Obadiah": "עֹבַדְיָה", "Jonah": "יוֹנָה", "Micah": "מִיכָה", "Nahum": "נַחוּם",
    "Habakkuk": "חֲבַקּוּק", "Zephaniah": "צְפַנְיָה", "Haggai": "חַגַּי",
    "Zechariah": "זְכַרְיָה", "Malachi": "מַלְאָכִי",
}

GREEK_BOOK_NAMES = {
    "Matthew": "Κατὰ Ματθαῖον", "Mark": "Κατὰ Μᾶρκον",
    "Luke": "Κατὰ Λουκᾶν", "John": "Κατὰ Ἰωάννην",
    "Acts": "Πράξεις Ἀποστόλων", "Romans": "Πρὸς Ῥωμαίους",
    "1 Corinthians": "Πρὸς Κορινθίους Αʹ", "2 Corinthians": "Πρὸς Κορινθίους Βʹ",
    "Galatians": "Πρὸς Γαλάτας", "Ephesians": "Πρὸς Ἐφεσίους",
    "Philippians": "Πρὸς Φιλιππησίους", "Colossians": "Πρὸς Κολοσσαεῖς",
    "1 Thessalonians": "Πρὸς Θεσσαλονικεῖς Αʹ", "2 Thessalonians": "Πρὸς Θεσσαλονικεῖς Βʹ",
    "1 Timothy": "Πρὸς Τιμόθεον Αʹ", "2 Timothy": "Πρὸς Τιμόθεον Βʹ",
    "Titus": "Πρὸς Τίτον", "Philemon": "Πρὸς Φιλήμονα",
    "Hebrews": "Πρὸς Ἑβραίους", "James": "Ἰακώβου",
    "1 Peter": "Πέτρου Αʹ", "2 Peter": "Πέτρου Βʹ",
    "1 John": "Ἰωάννου Αʹ", "2 John": "Ἰωάννου Βʹ", "3 John": "Ἰωάννου Γʹ",
    "Jude": "Ἰούδα", "Revelation": "Ἀποκάλυψις Ἰωάννου",
}

# Septuagint names for the deuterocanon and the Greek chapters of Esther and Daniel
GREEK_DEUTERO_NAMES = {
    "Tobit": "Τωβίτ", "Judith": "Ἰουδίθ", "Wisdom": "Σοφία Σαλωμῶνος",
    "Sirach": "Σοφία Σειράχ", "Baruch": "Βαρούχ",
    "1 Maccabees": "Μακκαβαίων Αʹ", "2 Maccabees": "Μακκαβαίων Βʹ",
    "Esther": "Ἐσθήρ", "Daniel": "Δανιήλ",
}


def original_name(book: str, chap: int) -> tuple[str, str]:
    """(Hebrew or Greek name, lang) of a book for the subtitle line."""
    if book == "Esther" and chap > 10 or book == "Daniel" and chap > 12:
        return GREEK_DEUTERO_NAMES[book], 'grc'
    if book in HEBREW_BOOK_NAMES:
        return HEBREW_BOOK_NAMES[book], 'he'
    if book in GREEK_BOOK_NAMES:
        return GREEK_BOOK_NAMES[book], 'grc'
    if book in GREEK_DEUTERO_NAMES:
        return GREEK_DEUTERO_NAMES[book], 'grc'
    return '', ''


# ── Psalm numbering: Hebrew (KJV) ↔ Vulgate/Septuagint ─────────

def lxx_to_hebrew(n: int) -> list[int]:
    """Hebrew psalm number(s) whose text Vulgate psalm n contains."""
    if n <= 8 or n >= 148:
        return [n]
    if n == 9:
        return [9, 10]
    if n <= 112:
        return [n + 1]
    if n == 113:
        return [114, 115]
    if n in (114, 115):
        return [116]
    if n <= 145:
        return [n + 1]
    return [147]            # 146, 147


def hebrew_to_lxx(h: int) -> list[int]:
    return [n for n in range(1, 151) if h in lxx_to_hebrew(n)]


# ═════════════════════════════════════════════════════════════
# Text model
# ═════════════════════════════════════════════════════════════
#
# A verse is a list of [kind, text] runs: 't' plain text, 'i' italic (KJV /
# RV1909 / Almeida supplied words, Byzantine OT quotations), 's' letter-spaced
# emphasis (Byzantine), 'n' editorial note (Luther, the 1919 Union Version's
# alternative readings), 'u' supplied words the 1919 Union Version marks with
# dots beside the characters, 'm' small type, 'L' large type, 'x' a
# cross-reference mark (superscript; the references follow the chapter). BRK
# marks an element boundary (line, paragraph, quotation): it becomes a space,
# or nothing between two CJK characters or before closing punctuation.
#
# Two inline marks live inside the run text as private-use characters, so
# that normalize() keeps them intact and html() resolves them:
# RUBY_OPEN base RUBY_SEP reading RUBY_CLOSE is a ruby annotation (the
# furigana of the 文語訳), and IDEO_SPACE is the full-width space the 1919
# Union Version prints before 神 ("　神"), which is text, not layout.

BRK = '\x00'
RUBY_OPEN, RUBY_SEP, RUBY_CLOSE, IDEO_SPACE = '\ue000', '\ue001', '\ue002', '\ue003'
_RUBY_RE = re.compile(f'{RUBY_OPEN}([^{RUBY_SEP}{RUBY_CLOSE}]*){RUBY_SEP}([^{RUBY_CLOSE}]*){RUBY_CLOSE}')
_WIDE = re.compile(r'[⺀-⿿　-ヿ㄀-鿿豈-﫿︰-﹏＀-￯\u2014\u2015\u2026]')   # CJK, plus dashes and ellipsis inside CJK text
_CLOSE_PUNCT = frozenset('.,;:!?)]”’،؛؟')


def ruby(base: str, reading: str) -> str:
    return f'{RUBY_OPEN}{base}{RUBY_SEP}{reading}{RUBY_CLOSE}'


class Text:
    __slots__ = ('parts',)

    def __init__(self):
        self.parts: list[list[str]] = []

    def add(self, kind: str, s: str):
        if not s:
            return
        if self.parts and self.parts[-1][0] == kind:
            self.parts[-1][1] += s
        else:
            self.parts.append([kind, s])

    def plain(self, notes: bool = False) -> str:
        return ''.join(s for k, s in self.parts if notes or k != 'n')

    def empty(self) -> bool:
        return not self.plain(notes=True).replace(BRK, '').strip()

    def normalize(self):
        """Collapse whitespace across runs, resolve BRK, trim, keep spaces at
        the edges of italic/note runs outside them."""
        chars = [(k, ch) for k, s in self.parts for ch in s]
        out: list[tuple[str, str]] = []
        i, n = 0, len(chars)
        while i < n:
            k, ch = chars[i]
            if ch == BRK or ch.isspace():
                j, real, newline = i, False, False
                while j < n and (chars[j][1] == BRK or chars[j][1].isspace()):
                    if chars[j][1] != BRK:
                        real = True
                        newline |= chars[j][1] in '\n\r'
                    j += 1
                if out and j < n:
                    prev, nxt = out[-1], chars[j]
                    # Layout whitespace between two CJK characters is not text,
                    # and a bare element boundary before "." is not a space
                    if (not real or newline) and _WIDE.match(prev[1]) and _WIDE.match(nxt[1]):
                        pass
                    elif not real and nxt[1] in _CLOSE_PUNCT:
                        pass
                    else:
                        out.append((prev[0] if prev[0] == nxt[0] else 't', ' '))
                i = j
            else:
                out.append((k, ch))
                i += 1
        self.parts = []
        for k, ch in out:
            self.add(k, ch)

    def map_text(self, fn):
        """Apply fn to each run's text (e.g. clean-ups)."""
        for p in self.parts:
            p[1] = fn(p[1])
        self.parts = [p for p in self.parts if p[1]]

    def html(self, note: tuple[str, str] = ('[', ']')) -> str:
        out = []
        for k, s in self.parts:
            e = esc(s)
            if k == 'i':
                out.append(f'<i>{e}</i>')
            elif k == 's':
                out.append(f'<span class="sp">{e}</span>')
            elif k == 'n':
                out.append(f'<span class="nt">{note[0]}{e}{note[1]}</span>')
            elif k == 'u':
                out.append(f'<span class="ud">{e}</span>')
            elif k == 'm':
                out.append(f'<small>{e}</small>')
            elif k == 'L':
                out.append(f'<span class="lg">{e}</span>')
            elif k == 'x':
                out.append(f'<sup class="xr">{e}</sup>')
            else:
                out.append(e)
        h = ''.join(out)
        if RUBY_OPEN in h or IDEO_SPACE in h:
            h = _RUBY_RE.sub(r'<ruby>\1<rt>\2</rt></ruby>', h).replace(IDEO_SPACE, '\u3000')
        return h


class Verse:
    __slots__ = ('text', 'title', 'label', 'covers')

    def __init__(self):
        self.text = Text()
        self.title: Text | None = None    # psalm superscription shown before the verse
        self.label: str | None = None     # e.g. "9–10" for a merged verse
        self.covers: list[int] = []       # other verse numbers merged into this one


class Bible:
    """{book: {chapter: {verse: Verse}}} plus parse statistics."""

    def __init__(self):
        self.books: dict[str, dict[int, dict[int, Verse]]] = {}
        self.skipped_books: dict[str, int] = {}
        # (book, chapter) → [(mark, [(text, target key or None), …])]: the
        # cross-references printed after a chapter (1919 Union Version NT)
        self.chapter_notes: dict[tuple[str, int], list[tuple[str, list[tuple[str, str | None]]]]] = {}

    def verse(self, book: str, chap: int, vnum: int) -> tuple[Verse, bool]:
        chs = self.books.setdefault(book, {})
        vs = chs.setdefault(chap, {})
        if vnum in vs:
            return vs[vnum], False
        v = Verse()
        vs[vnum] = v
        return v, True

    def refs(self) -> set[tuple[str, int, int]]:
        out = set()
        for b, chs in self.books.items():
            for c, vs in chs.items():
                for n, v in vs.items():
                    out.add((b, c, n))
                    out.update((b, c, m) for m in v.covers)
        return out

    def all_verses(self):
        for b, chs in self.books.items():
            for c, vs in chs.items():
                for n, v in vs.items():
                    yield b, c, n, v


def _local(tag) -> str:
    return tag.rsplit('}', 1)[-1] if isinstance(tag, str) else ''


def _vnum(s: str) -> int | None:
    m = re.match(r'\d+', s or '')
    return int(m.group()) if m else None


# ═════════════════════════════════════════════════════════════
# OSIS
# ═════════════════════════════════════════════════════════════

OSIS_NS = 'http://www.bibletechnologies.net/2003/OSIS/namespace'
OSIS_BLOCKS = frozenset({'p', 'l', 'lg', 'lb', 'list', 'item', 'q', 'speech', 'speaker'})
OSIS_SKIP = frozenset({'header', 'figure', 'index', 'rdg'})


class OsisWalker:
    """Document-order OSIS reader. Handles containment verses
    (<verse osisID>…</verse>), milestone verses (<verse sID/> … <verse eID/>,
    text in tails and in later siblings), multi-reference IDs
    ("Rom.1.9 Rom.1.10"), sub-verses ("3!a"), canonical psalm titles,
    <transChange type="added"> (italic) and <note> (skipped or inline)."""

    def __init__(self, cfg: dict, bible: Bible, log: list):
        self.cfg, self.bible, self.log = cfg, bible, log
        self.books = allowed_books(cfg)
        self.override = cfg.get('div_book_override', {})
        self.notes = cfg.get('notes', 'skip')
        self.ruby = cfg.get('ruby', False)
        self.div_ordinal = 0
        self.div_book: str | None = None     # book of the current <div type="book">
        self.target: Text | None = None      # where character data goes
        self.verse: Verse | None = None
        self.pending_title: Text | None = None
        self.kind = ['t']
        self.title_in_verse = 0

    # character data
    def add(self, s):
        if s and self.target is not None:
            self.target.add(self.kind[-1], s)

    def brk(self):
        if self.target is not None:
            self.target.add('t', BRK)

    def children(self, e):
        self.add(e.text)
        for ch in e:
            self.walk(ch)
            self.add(ch.tail)

    # verses
    def open_verse(self, refs: list[str]):
        self.close_verse()
        parsed = []
        for r in refs:
            parts = r.split('.')
            if len(parts) < 3:
                self.log.append(f'unparsed osisID {r!r}')
                continue
            parsed.append((parts[0], int(parts[1]), parts[2]))
        if not parsed:
            return
        code, chap, vstr = parsed[0]
        book = self.div_book if self.override else OSIS_BOOK_NAMES.get(code)
        if book is None or book not in self.books:
            self.bible.skipped_books[code] = self.bible.skipped_books.get(code, 0) + len(parsed)
            return
        vnum = _vnum(vstr)
        if vnum is None:
            self.log.append(f'unparsed verse number {refs!r}')
            return
        v, new = self.bible.verse(book, chap, vnum)
        if not new:
            v.text.add('t', BRK)               # sub-verse ("3!b") continues the verse
        others = [_vnum(p[2]) for p in parsed[1:] if p[1] == chap and p[0] == code]
        if len(others) != len(parsed) - 1:
            raise BuildError(f'merged verse across chapters/books: {refs}')
        if others:
            v.covers = sorted(set(others) - {vnum})
            nums = sorted([vnum] + v.covers)
            if nums != list(range(nums[0], nums[-1] + 1)):
                raise BuildError(f'non-contiguous merged verse {refs}')
            v.label = f'{nums[0]}–{nums[-1]}'
        if new and self.pending_title is not None:
            v.title, self.pending_title = self.pending_title, None
        self.verse, self.target = v, v.text

    def close_verse(self):
        self.verse = None
        self.target = None

    def walk(self, e):
        tag = _local(e.tag)
        if tag in OSIS_SKIP:
            return
        if tag == 'div' and e.get('type') == 'book' and not (e.get('sID') or e.get('eID')):
            self.close_verse()
            self.div_ordinal += 1
            code = e.get('osisID', '')
            if self.override:
                want = self.override.get(self.div_ordinal)
                if want is None:
                    want = code
                elif want[0] != code:
                    raise BuildError(f'div #{self.div_ordinal} is {code!r}, expected {want[0]!r} '
                                     '(upstream changed: review div_book_override)')
                else:
                    want = want[1]
                self.div_book = OSIS_BOOK_NAMES.get(want)
            else:
                self.div_book = OSIS_BOOK_NAMES.get(code)
            if self.div_book is None or self.div_book not in self.books:
                n = sum(1 for v in e.iter(f'{{{OSIS_NS}}}verse') if not v.get('eID'))
                self.bible.skipped_books[code] = self.bible.skipped_books.get(code, 0) + n
                self.div_book = None
                return
            self.children(e)
            self.close_verse()
            self.div_book = None
            return
        if tag == 'chapter':
            if e.get('sID') or e.get('eID'):
                self.pending_title = None
                return
            self.pending_title = None
            self.children(e)
            self.close_verse()
            return
        if tag == 'verse':
            if e.get('eID'):
                self.close_verse()
                return
            refs = (e.get('osisID') or '').split()
            if not refs:
                self.children(e)
                return
            self.open_verse(refs)
            if e.get('sID'):
                return                      # milestone: text follows in tails
            self.children(e)                # containment
            self.close_verse()
            return
        if tag == 'note':
            if self.notes == 'inline' and self.target is not None:
                self.kind.append('n')
                self.add(''.join(e.itertext()))
                self.kind.pop()
            return
        if tag == 'title':
            if e.get('type') == 'psalm' or (e.get('canonical') == 'true' and e.get('type') not in ('main', 'chapter', 'sub')):
                buf = Text()
                saved = self.target
                self.target = buf
                self.children(e)
                self.target = saved
                if self.verse is not None and self.verse.text.empty() and self.verse.title is None:
                    self.verse.title = buf          # title inside verse 1 (SWORD)
                elif self.verse is not None:
                    self.title_in_verse += 1
                    self.verse.text.add('t', BRK)   # keep it as verse text
                    for k, s in buf.parts:
                        self.verse.text.add(k, s)
                elif self.pending_title is None:
                    self.pending_title = buf
                else:
                    self.pending_title.add('t', BRK)
                    for k, s in buf.parts:
                        self.pending_title.add(k, s)
            return
        if tag == 'transChange' and e.get('type', 'added') == 'added':
            self.kind.append('i')
            self.children(e)
            self.kind.pop()
            return
        if tag == 'w' and self.ruby and e.get('gloss'):
            # <w gloss="はじめ">元始</w>: the reading of the word, shown as ruby
            self.add(ruby(''.join(e.itertext()), e.get('gloss')))
            return
        if tag in OSIS_BLOCKS:
            self.brk()
            self.children(e)
            self.brk()
            return
        self.children(e)                    # w, seg, divineName, hi, foreign, …


def parse_osis(xml_path: Path, cfg: dict, log: list) -> Bible:
    bible = Bible()
    w = OsisWalker(cfg, bible, log)
    w.walk(ET.parse(xml_path).getroot())
    if w.title_in_verse:
        log.append(f'{w.title_in_verse} psalm titles inside verse text kept in place')
    return bible


def count_osis_source(xml_path: Path, cfg: dict) -> int:
    """Independent count: distinct verse references in <verse> start tags of
    the included books (regex over the raw file, not the parser)."""
    raw = xml_path.read_text(encoding='utf-8')
    books = allowed_books(cfg)
    codes = {o for o, e in OSIS_BOOK_NAMES.items() if e in books}
    if cfg.get('div_book_override'):
        codes |= {old for old, _ in cfg['div_book_override'].values()}
    seen = set()
    for m in re.finditer(r'<verse\b([^>]*)>', raw):
        attrs = m.group(1)
        if re.search(r'\beID\s*=', attrs):
            continue
        idm = re.search(r'\bosisID\s*=\s*["\']([^"\']+)', attrs)
        if not idm:
            continue
        for ref in idm.group(1).split():
            b, c, v = (ref.split('.') + ['', ''])[:3]
            if b in codes and _vnum(v) is not None:
                seen.add((b, int(c), _vnum(v), m.start() if cfg.get('div_book_override') else 0))
    if cfg.get('div_book_override'):
        # duplicate osisIDs live in different (relabelled) divs: count tags
        return len({(b, c, v, pos) for b, c, v, pos in seen})
    return len(seen)


# ═════════════════════════════════════════════════════════════
# USFX
# ═════════════════════════════════════════════════════════════

USFX_SKIP = frozenset({'f', 'fe', 'x', 'h', 'toc', 'id', 'rem', 's', 'cl', 'fig', 'languageCode',
                       'ndx', 'rq', 'ef', 'ex', 'periph', 'restore', 'cp', 'ca', 'va', 'vp'})
USFX_ITALIC = frozenset({'add'})
USFX_BLOCKS = frozenset({'p', 'q', 'b', 'li', 'qc', 'qr', 'qm', 'pi', 'm', 'nb', 'mi', 'lh', 'lf'})
_USFX_HEADING_STYLE = re.compile(r'^(?:mt|ms|mr|mte|s\d*$|sr|sp|r$|d$|cl|i[a-z]+|rem|toc)')


class UsfxWalker:
    """Document-order USFX reader: a verse runs from <v> to <ve/> (or the next
    <v>, <c> or <book>); all character data in between counts, except
    footnotes, cross-references, headings and other non-text markup."""

    def __init__(self, cfg: dict, bible: Bible, log: list):
        self.cfg, self.bible, self.log = cfg, bible, log
        self.books = allowed_books(cfg)
        self.italic = USFX_ITALIC | frozenset(cfg.get('usfx_italic', ()))
        self.spaced = frozenset(cfg.get('usfx_spaced', ()))
        self.book: str | None = None
        self.chap: int | None = None
        self.target: Text | None = None
        self.verse: Verse | None = None
        self.pending_title: Text | None = None
        self.kind = ['t']
        self.unknown: dict[str, int] = {}

    add = OsisWalker.add
    brk = OsisWalker.brk
    children = OsisWalker.children

    def close_verse(self):
        self.verse = None
        self.target = None

    def open_verse(self, vid: str):
        self.close_verse()
        if self.book is None or self.chap is None:
            return
        nums = [int(x) for x in re.findall(r'\d+', vid or '')]
        if not nums:
            self.log.append(f'unparsed <v id={vid!r}>')
            return
        v, new = self.bible.verse(self.book, self.chap, nums[0])
        if not new:
            v.text.add('t', BRK)
        if len(nums) > 1 and nums[-1] > nums[0]:
            v.covers = list(range(nums[0] + 1, nums[-1] + 1))
            v.label = f'{nums[0]}–{nums[-1]}'
        if new and self.pending_title is not None:
            v.title, self.pending_title = self.pending_title, None
        self.verse, self.target = v, v.text

    def title(self, e):
        buf = Text()
        saved, self.target = self.target, buf
        self.children(e)
        self.target = saved
        if self.verse is not None and self.verse.text.empty() and self.verse.title is None:
            self.verse.title = buf
        elif self.verse is None:
            self.pending_title = buf

    def walk(self, e):
        tag = _local(e.tag)
        if tag == 'book':
            self.close_verse()
            code = (e.get('id') or '').upper()
            book = USFX_BOOK_NAMES.get(code)
            if book is None or book not in self.books:
                n = sum(1 for _ in e.iter('v'))
                if n:
                    self.bible.skipped_books[code] = self.bible.skipped_books.get(code, 0) + n
                return
            self.book, self.chap = book, None
            self.children(e)
            self.close_verse()
            self.book = None
            return
        if tag == 'c':
            self.close_verse()
            self.chap = _vnum(e.get('id'))
            self.pending_title = None
            return
        if tag == 'v':
            self.open_verse(e.get('id'))
            return
        if tag == 've':
            self.close_verse()
            return
        if tag in USFX_SKIP:
            return
        if tag == 'd':
            self.title(e)
            return
        if tag == 'p':
            style = e.get('sfm') or e.get('style') or ''
            if style == 'd':
                self.title(e)
                return
            if style and _USFX_HEADING_STYLE.match(style):
                return
        if tag in self.italic or tag in self.spaced:
            self.kind.append('i' if tag in self.italic else 's')
            self.children(e)
            self.kind.pop()
            return
        if tag in USFX_BLOCKS:
            self.brk()
            self.children(e)
            self.brk()
            return
        if tag not in ('usfx', 'w', 'wj', 'nd', 'bd', 'it', 'bdit', 'em', 'sc', 'k', 'qt', 'tl',
                       'sup', 'sig', 'pn', 'ord', 'no', 'qs', 'qac'):
            self.unknown[tag] = self.unknown.get(tag, 0) + 1
        self.children(e)


def parse_usfx(xml_path: Path, cfg: dict, log: list) -> Bible:
    bible = Bible()
    w = UsfxWalker(cfg, bible, log)
    w.walk(ET.parse(xml_path).getroot())
    if w.unknown:
        log.append(f'USFX tags read as plain text: {w.unknown}')
    return bible


def count_usfx_source(xml_path: Path, cfg: dict) -> int:
    """Independent count of distinct (book, chapter, verse) <v> markers."""
    raw = xml_path.read_text(encoding='utf-8')
    books = allowed_books(cfg)
    seen, book, chap = set(), None, None
    for m in re.finditer(r'<(book|c|v)\b[^>]*?\bid\s*=\s*"([^"]*)"', raw):
        tag, val = m.groups()
        if tag == 'book':
            book, chap = USFX_BOOK_NAMES.get(val.upper()), None
            if book not in books:
                book = None
        elif tag == 'c':
            chap = _vnum(val)
        elif book and chap is not None:
            nums = [int(x) for x in re.findall(r'\d+', val)]
            for n in range(nums[0], nums[-1] + 1):
                seen.add((book, chap, n))
    return len(seen)


# ═════════════════════════════════════════════════════════════
# Zefania
# ═════════════════════════════════════════════════════════════

def parse_zefania(xml_path: Path, cfg: dict, log: list) -> Bible:
    """<XMLBIBLE><BIBLEBOOK bnumber><CHAPTER cnumber><VERS vnumber>text</VERS>"""
    bible = Bible()
    books = allowed_books(cfg)
    for book_elem in ET.parse(xml_path).getroot().iter('BIBLEBOOK'):
        bnum = int(book_elem.get('bnumber', '0'))
        if not 1 <= bnum <= len(ZEFANIA_BOOK_ORDER) or ZEFANIA_BOOK_ORDER[bnum - 1] not in books:
            bible.skipped_books[str(bnum)] = sum(1 for _ in book_elem.iter('VERS'))
            continue
        book = ZEFANIA_BOOK_ORDER[bnum - 1]
        for chap_elem in book_elem.iter('CHAPTER'):
            chap = int(chap_elem.get('cnumber'))
            for vers in chap_elem.iter('VERS'):
                v, new = bible.verse(book, chap, int(vers.get('vnumber')))
                if not new:
                    v.text.add('t', BRK)
                for frag in vers.itertext():
                    v.text.add('t', frag)
    return bible


def count_zefania_source(xml_path: Path, cfg: dict) -> int:
    raw = xml_path.read_text(encoding='utf-8')
    books = allowed_books(cfg)
    seen, book, chap = set(), None, None
    for m in re.finditer(r'<(BIBLEBOOK|CHAPTER|VERS)\b[^>]*?\b(bnumber|cnumber|vnumber)="(\d+)"', raw):
        tag, _, val = m.groups()
        if tag == 'BIBLEBOOK':
            n = int(val)
            book = ZEFANIA_BOOK_ORDER[n - 1] if 1 <= n <= 66 else None
            book = book if book in books else None
        elif tag == 'CHAPTER':
            chap = int(val)
        elif book:
            seen.add((book, chap, int(val)))
    return len(seen)


# ═════════════════════════════════════════════════════════════
# SWORD zText module (CrossWire), e.g. KorRV
# ═════════════════════════════════════════════════════════════
#
# Per testament: <t>.bzs = block index (u32 offset, u32 compressed size,
# u32 size), <t>.bzz = zlib blocks, <t>.bzv = one 10-byte entry per
# versification slot (u32 block, u32 offset, u16 size). Slot 0 is the module
# heading, 1 the testament heading, then per book a book-heading slot and per
# chapter a chapter-heading slot followed by its verses.

def sword_versification(name: str) -> list[tuple[str, list[int]]]:
    v11n = [(b, list(KJV_VERSES[b])) for b in BOOK_ORDER]
    if name == 'NRSV':
        d = dict(v11n)
        d['3 John'][0] = 15
        d['Revelation'][11] = 18
    elif name != 'KJV':
        raise BuildError(f'unsupported SWORD versification {name}')
    return v11n


def read_sword_ztext(zip_path: Path, cfg: dict):
    """Yield (book, chapter, verse, OSIS fragment) for every non-empty slot,
    checking that the book headings match the versification table."""
    z = zipfile.ZipFile(zip_path)
    conf_name = next(n for n in z.namelist() if n.startswith('mods.d/') and n.endswith('.conf'))
    conf = dict(line.split('=', 1) for line in z.read(conf_name).decode('utf-8').splitlines() if '=' in line)
    if conf.get('ModDrv') != 'zText' or conf.get('CompressType') != 'ZIP':
        raise BuildError(f'{zip_path.name}: unsupported module driver {conf.get("ModDrv")}')
    data_path = conf['DataPath'].lstrip('./')
    v11n = sword_versification(conf.get('Versification', 'KJV'))
    testaments = [('ot', v11n[:39]), ('nt', v11n[39:])]
    for t, books in testaments:
        bzs = z.read(data_path + t + '.bzs')
        bzv = z.read(data_path + t + '.bzv')
        bzz = z.read(data_path + t + '.bzz')
        blocks = [struct.unpack('<III', bzs[i:i + 12]) for i in range(0, len(bzs), 12)]
        cache: dict[int, bytes] = {}

        def slot(i):
            b, o, s = struct.unpack('<IIH', bzv[i * 10:i * 10 + 10])
            if not s:
                return ''
            if b not in cache:
                off, csize, _ = blocks[b]
                cache[b] = zlib.decompress(bzz[off:off + csize])
            return cache[b][o:o + s].decode('utf-8')

        expected = 2 + sum(1 + len(vs) + sum(vs) for _, vs in books)
        if expected != len(bzv) // 10:
            raise BuildError(f'{zip_path.name} {t}: {len(bzv) // 10} slots, versification expects {expected}')
        i = 2
        for book, vs in books:
            head = slot(i)
            osis = next(o for o, e in OSIS_BOOK_NAMES.items() if e == book)
            if f'osisID="{osis}"' not in head:
                raise BuildError(f'{zip_path.name}: slot {i} is {head[:60]!r}, expected book {osis}')
            i += 1
            for c, n in enumerate(vs, 1):
                i += 1                        # chapter heading
                for v in range(1, n + 1):
                    txt = slot(i)
                    i += 1
                    yield book, c, v, txt


def parse_sword(zip_path: Path, cfg: dict, log: list) -> Bible:
    bible = Bible()
    w = OsisWalker(cfg, bible, log)
    empty = []
    for book, c, vnum, frag in read_sword_ztext(zip_path, cfg):
        root = ET.fromstring(f'<r xmlns="{OSIS_NS}">{frag}</r>')
        v, _ = bible.verse(book, c, vnum)
        w.verse, w.target = v, v.text
        w.children(root)
        w.close_verse()
        if v.text.empty():
            empty.append((book, c, vnum))
    bible.sword_empty = empty
    return bible


def count_sword_source(zip_path: Path, cfg: dict) -> int:
    return sum(1 for _ in read_sword_ztext(zip_path, cfg))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ═════════════════════════════════════════════════════════════
# Chinese Wikisource wikitext (官話和合譯本 1919)
# ═════════════════════════════════════════════════════════════
#
# One page per book, pinned by revision id in scripts/cuv1919_wikisource.pins.
# A page is a header template, a table of contents, and per chapter a
# heading ({{Chapter|1|第一章}}), one paragraph per verse
# ({{verse|1|1}}起初　神創造天地。) and, in the New Testament, the chapter's
# Old Testament references (:{{Anchor|1a}}<sup>〡</sup>[[../以賽亞書#7:14|賽七　〡〤]]),
# whose marks stand in the verse as <sup>[[#1a|〡]]</sup>. Inline markup:
# {{udots|…}} words supplied by the translators (dots beside the characters),
# {{*|…}} alternative readings and explanations (small type), {{-|…}} small
# type (細拉, psalm titles), {{+|…}} large type, {{!|字|description}} a rare
# character, -{…}- protected text.

CUV1919_PINS = SCRIPT_DIR / 'cuv1919_wikisource.pins'
_WS_KIND = {'udots': 'u', '*': 'n', '-': 'm', '+': 'L'}
_WS_TOKEN = re.compile(r'\{\{|\}\}|\[\[|\]\]|\||<sup>|</sup>|-\{|\}-')


def read_pins(path: Path) -> list[list[str]]:
    return [line.rstrip('\n').split('\t') for line in path.read_text(encoding='utf-8').splitlines()
            if line.strip() and not line.startswith('#')]


def wikisource_pages(src_dir: Path) -> list[tuple[str, Path]]:
    """[(English book, file)] in canonical order; every file must exist and
    have its pinned SHA-256."""
    out = []
    for code, revid, sha, _page in read_pins(CUV1919_PINS):
        path = src_dir / f'{code}-{revid}.wiki'
        if not path.exists():
            raise BuildError(f'{path.name} missing (see fetch_data.sh fetch_bible)')
        if _sha256(path) != sha:
            raise BuildError(f'{path.name}: sha256 differs from {CUV1919_PINS.name}')
        out.append((USFX_BOOK_NAMES[code], path))
    if [b for b, _ in out] != BOOK_ORDER:
        raise BuildError(f'{CUV1919_PINS.name}: books are not the 66 books in canonical order')
    return out


def _ws_tree(s: str):
    """Wikitext → nested nodes: str, ('tpl', [arg, …]), ('link', [arg, …]),
    ('sup', children), ('raw', children); each arg is a list of nodes."""
    stack = [('root', [[]])]
    pos = 0
    for m in _WS_TOKEN.finditer(s):
        if m.start() > pos:
            stack[-1][1][-1].append(s[pos:m.start()])
        tok, pos = m.group(), m.end()
        top = stack[-1][0]
        if tok in ('{{', '[[', '<sup>', '-{'):
            stack.append(({'{{': 'tpl', '[[': 'link', '<sup>': 'sup', '-{': 'raw'}[tok], [[]]))
        elif tok == '|' and top in ('tpl', 'link'):
            stack[-1][1].append([])
        elif tok == '|':
            stack[-1][1][-1].append(tok)
        elif (tok, top) in (('}}', 'tpl'), (']]', 'link'), ('</sup>', 'sup'), ('}-', 'raw')):
            kind, args = stack.pop()
            stack[-1][1][-1].append((kind, args) if kind in ('tpl', 'link') else (kind, args[0]))
        else:
            raise BuildError(f'unbalanced wikitext {tok!r} near {s[max(0, m.start() - 30):m.end() + 30]!r}')
    if len(stack) != 1:
        raise BuildError(f'unclosed wikitext {stack[-1][0]} in {s[:80]!r}')
    if pos < len(s):
        stack[0][1][-1].append(s[pos:])
    return stack[0][1][0]


def _ws_plain(nodes) -> str:
    out = []
    for n in nodes:
        if isinstance(n, str):
            out.append(n)
        elif n[0] in ('tpl', 'link'):
            out.append(_ws_plain(n[1][-1]))
        else:
            out.append(_ws_plain(n[1]))
    return ''.join(out)


class WikisourceReader:
    def __init__(self, cfg: dict, bible: Bible, log: list):
        self.cfg, self.bible, self.log = cfg, bible, log
        self.local_to_en = {v: k for k, v in ZH_HANT_BOOK_NAMES.items()}
        self.stats = Counter()

    def page(self, book: str, path: Path):
        text = path.read_text(encoding='utf-8')
        # header template and the table of contents
        text = re.sub(r'\A\{\{header2\b.*?^\}\}', '', text, count=1, flags=re.S | re.M)
        text = re.sub(r'<div[^>]*id="toc"[^>]*>.*?</div>', '', text, count=1, flags=re.S)
        self.book, self.chap, self.verse, self.target = book, None, None, None
        self.marks: dict[str, tuple[int, str]] = {}      # mark id → (chapter, label)
        self.notes: dict[str, tuple[int, str]] = {}
        headings = []
        for line in text.split('\n'):
            s = line.strip()
            if not s:
                self.brk()
                continue
            m = re.fullmatch(r'==.*\{\{Chapter\|(\d+)\|[^}]*\}\}.*==', s)
            if m:
                self.verse = self.target = None
                headings.append(int(m.group(1)))
                continue
            if re.fullmatch(r'==.*==', s):              # 詩篇卷一 … (book divisions)
                continue
            if s.startswith(':{{'):
                self.note(s[1:])
                continue
            if (s in ('{{gototop}}', '__NOTOC__', '</div>') or re.fullmatch(r'<div[^>]*>', s)
                    or re.fullmatch(r'\{\{(footer|Pd/1923)\b.*\}\}', s) or re.fullmatch(r'\[\[en:[^\]]*\]\]', s)):
                continue
            self.inline(_ws_tree(s))
            self.brk()
        chs = sorted(self.bible.books.get(book, {}))
        if headings != chs:
            raise BuildError(f'{path.name}: chapter headings {headings[:5]}… differ from the verse chapters')
        for mid, (c, label) in self.marks.items():
            if self.notes.get(mid, (None, None))[0] != c:
                raise BuildError(f'{path.name}: reference mark {mid!r} ({book} {c}) has no note in its chapter')
        if set(self.notes) != set(self.marks):
            raise BuildError(f'{path.name}: notes without a mark: {sorted(set(self.notes) - set(self.marks))}')

    # verse text
    def brk(self):
        if self.target is not None:
            self.target.add('t', BRK)

    def inline(self, nodes, kind='t'):
        for n in nodes:
            if isinstance(n, str):
                self.text(n, kind)
                continue
            typ, args = n
            if typ == 'tpl':
                name = _ws_plain(args[0]).strip()
                if name == 'verse':
                    c, v = (int(_ws_plain(a)) for a in args[1:3])
                    self.open_verse(c, v)
                elif name in _WS_KIND:
                    if (name == '-' and self.book == 'Psalms' and self.vnum == 1
                            and self.target is not None and self.target is self.verse.text
                            and self.target.empty() and self.verse.title is None):
                        self.verse.title = self.target = Text()      # psalm title
                        self.inline(args[1], 't')
                        self.target = self.verse.text
                        self.stats['psalm titles'] += 1
                    else:
                        self.inline(args[1], _WS_KIND[name])
                        self.stats[name] += 1
                elif name == '!':                          # {{!|𤘘|牛口}}: the character
                    self.inline(args[1], kind)
                    self.stats['rare characters'] += 1
                else:
                    raise BuildError(f'{self.book}: unknown template {{{{{name}|…}}}}')
            elif typ == 'sup':
                link = [x for x in args if not isinstance(x, str) or x.strip()]
                if len(link) != 1 or isinstance(link[0], str) or link[0][0] != 'link':
                    raise BuildError(f'{self.book}: unexpected <sup> {_ws_plain(args)!r}')
                target, label = _ws_plain(link[0][1][0]), _ws_plain(link[0][1][-1])
                if not target.startswith('#') or self.verse is None:
                    raise BuildError(f'{self.book}: unexpected reference mark {target!r}')
                mid = target[1:]
                if mid in self.marks:
                    raise BuildError(f'{self.book}: reference mark {mid!r} used twice')
                self.marks[mid] = (self.chap, label)
                self.target.add('x', label)
            elif typ == 'raw':
                self.text(_ws_plain(args), kind)
            else:
                raise BuildError(f'{self.book}: unexpected link in verse text {_ws_plain(args[-1])!r}')

    def text(self, s: str, kind: str):
        if self.target is None:
            if s.strip():
                raise BuildError(f'{self.book}: text outside a verse: {s[:40]!r}')
            return
        if self.target.empty():
            s = s.lstrip(' \u3000')                         # verse-initial "　神"
        self.stats['honorific spaces'] += s.count('\u3000')
        self.target.add(kind, s.replace('\u3000', IDEO_SPACE))

    def open_verse(self, c: int, v: int):
        if self.chap is not None and c < self.chap:
            raise BuildError(f'{self.book} {c}:{v} after chapter {self.chap}')
        cur = self.verse
        if cur is not None and c == self.chap and cur.text.empty() and v == self.vnum + 1:
            # "{{verse|24|29}} {{verse|24|30}}…": verses printed as one
            first = int(cur.label.split('–')[0]) if cur.label else self.vnum
            cur.covers.append(v)
            cur.label = f'{first}–{v}'
            self.vnum = v
            self.stats['verses printed together'] += 1
            return
        self.chap, self.vnum = c, v
        verse, new = self.bible.verse(self.book, c, v)
        if not new:
            raise BuildError(f'{self.book} {c}:{v} appears twice')
        self.verse, self.target = verse, verse.text

    # chapter references
    def note(self, s: str):
        nodes = _ws_tree(s)
        if not (nodes and isinstance(nodes[0], tuple) and nodes[0][0] == 'tpl'
                and _ws_plain(nodes[0][1][0]).lower() == 'anchor'):
            raise BuildError(f'{self.book}: unexpected indented line {s[:60]!r}')
        mid = _ws_plain(nodes[0][1][1]).strip()
        rest = [n for n in nodes[1:] if not (isinstance(n, str) and not n.strip())]
        if not rest or rest[0][0] != 'sup':
            raise BuildError(f'{self.book}: note {mid!r} has no mark')
        label = _ws_plain(rest[0][1])
        content: list[tuple[str, str | None]] = []
        for n in nodes[nodes.index(rest[0]) + 1:]:
            if isinstance(n, str):
                content.append((n, None))
            elif n[0] == 'link':
                target, text = _ws_plain(n[1][0]), _ws_plain(n[1][-1])
                m = re.fullmatch(r'\.\./([^#]+)#(\d+):\d+', target)
                book = self.local_to_en.get(m.group(1)) if m else None
                if book is None or not 1 <= int(m.group(2)) <= len(KJV_VERSES[book]):
                    raise BuildError(f'{self.book}: note {mid!r} links to {target!r}')
                content.append((text, f'{book} {int(m.group(2))}'))
            else:
                raise BuildError(f'{self.book}: unexpected markup in note {mid!r}')
        if mid in self.notes:
            raise BuildError(f'{self.book}: note {mid!r} appears twice')
        self.notes[mid] = (self.chap, label)
        mark = self.marks.get(mid)
        if mark is not None and mark[1] != label:
            raise BuildError(f'{self.book}: note {mid!r} is labelled {label!r}, its mark {mark[1]!r}')
        self.bible.chapter_notes.setdefault((self.book, self.chap), []).append((label, content))
        self.stats['references'] += 1


def parse_wikisource(src_dir: Path, cfg: dict, log: list) -> Bible:
    bible = Bible()
    r = WikisourceReader(cfg, bible, log)
    for book, path in wikisource_pages(src_dir):
        r.page(book, path)
    log.append('Wikisource: ' + ', '.join(f'{n} {k}' for k, n in sorted(r.stats.items())))
    return bible


def count_wikisource_source(src_dir: Path, cfg: dict) -> int:
    """Independent count: distinct {{verse|c|v}} templates per page."""
    seen = set()
    for book, path in wikisource_pages(src_dir):
        for c, v in re.findall(r'\{\{verse\|(\d+)\|(\d+)\}\}', path.read_text(encoding='utf-8')):
            seen.add((book, int(c), int(v)))
    return len(seen)


# ═════════════════════════════════════════════════════════════
# edition-canon Markdown (mazza/biblia-arc1911: Almeida 1911)
# ═════════════════════════════════════════════════════════════
#
# canon/NN-BBB/CC.md, one chapter per file, built from Project Gutenberg
# #62383 (archive/pg62383.txt): "**N** text" verse paragraphs with *italic*
# supplied words and [^ID] footnote calls, "[^ID]: …" footnotes (references
# and alternative readings, left out here), "## Name N", "### section title",
# "#### psalm superscription" (or "#### (parallel passage)"), date lines
# ("[Antes de Christo 4004]") and acrostic letters ("ALEPH."). The section
# titles, dates and parallels are left out, as in the other Bibles; psalm
# superscriptions and acrostic letters are shown before their verse.

# SHA-256 of the canon/ tree: the "<sha256>  <path>" line of every
# canon/*/*.md file, sorted by path (C locale), hashed together; and of the
# Gutenberg transcription the canon was built from.
ARC1911_CANON_SHA256 = '2137289fa9d4cdabb6550391448783812033eb22ed7787c333a2206a109e0df5'
PG62383_SHA256 = 'bf9c6053bfb441d117a2a128d4edec9fbe935f415bc8f7bf4e1f3f9121790215'
_EC_CUE = re.compile(r'\[\^[A-Za-z0-9_]+\]')
# Hebrew letters of the acrostics (Psalm 119, Lamentations 1–4): "ALEPH."
# lines, and "### Beth." headings in Psalm 119
_EC_ACROSTIC = re.compile(r'(?:#{3,4} )?(?:ALEPH|BETH|GIMEL|DALETH|HE|VAU|ZAIN|HETH|TETH|JOD|CAPH|LAMED|'
                          r'MEM|NUN|SAMECH|AIN|PE|TSADE|KOPH|COPH|RESCH|RES|SCHIN|SIN|TAU)\.', re.I)
_EC_SUPERSCRIPTION = re.compile(r'^(?:Para o cantor-m[oó]r|Psalmo|Maschil|Mictam|Michtham|Michtam|'
                                r'Schiggaion|Cantico|Cântico|Oração)\b', re.I)


def canon_files(src_dir: Path) -> list[tuple[str, int, Path]]:
    files = sorted((src_dir / 'canon').glob('*/*.md'))
    listing = ''.join(f'{_sha256(f)}  {f.relative_to(src_dir).as_posix()}\n'
                      for f in sorted(files, key=lambda f: f.relative_to(src_dir).as_posix().encode()))
    if hashlib.sha256(listing.encode()).hexdigest() != ARC1911_CANON_SHA256:
        raise BuildError(f'{src_dir.name}/canon differs from the pinned tree (ARC1911_CANON_SHA256)')
    pg = src_dir / 'archive' / 'pg62383.txt'
    if not pg.exists() or _sha256(pg) != PG62383_SHA256:
        raise BuildError(f'{src_dir.name}/archive/pg62383.txt is not Project Gutenberg #62383 as pinned')
    out = []
    for f in files:
        code = f.parent.name.split('-', 1)[1]
        out.append((USFX_BOOK_NAMES[code], int(f.stem), f))
    return out


def _ec_text(s: str) -> str:
    """Drop the footnote calls and the spaces they leave."""
    s = _EC_CUE.sub(' ', s)
    s = re.sub(r' {2,}', ' ', s)
    return re.sub(r'\( ', '(', re.sub(r' (?=[,.;:!?)])', '', s)).strip()


def _ec_add(t: Text, s: str):
    for i, part in enumerate(re.split(r'\*([^*]+)\*', _ec_text(s))):
        t.add('i' if i % 2 else 't', part)


def parse_edition_canon(src_dir: Path, cfg: dict, log: list) -> Bible:
    bible = Bible()
    stats = Counter()
    for book, chap, path in canon_files(src_dir):
        pending: Text | None = None
        for line in path.read_text(encoding='utf-8').split('\n'):
            m = re.match(r'^\*\*(\d+)\*\* (.*)$', line)
            if m:
                v, new = bible.verse(book, chap, int(m.group(1)))
                if not new:
                    raise BuildError(f'{book} {chap}:{m.group(1)} appears twice')
                _ec_add(v.text, m.group(2))
                if pending is not None:
                    v.title, pending = pending, None
                continue
            title = None
            if _EC_ACROSTIC.fullmatch(line):                         # ALEPH.
                title = line
                stats['acrostic letters'] += 1
            elif book == 'Psalms' and not bible.books.get(book, {}).get(chap):
                body = _ec_text(re.sub(r'^#{3,4} ', '', line))
                if (line.startswith('#### ') and not line.startswith('#### (')) or (
                        not re.match(r'#|<|\[\^[A-Za-z0-9_]+\]:|\[Ant|\[Anno', line)
                        and _EC_SUPERSCRIPTION.match(body)):
                    title = line
                    stats['psalm superscriptions'] += 1
            if title is not None:
                t = Text() if pending is None else pending
                if pending is not None:
                    t.add('t', BRK)
                _ec_add(t, re.sub(r'^#{3,4} ', '', title))
                pending = t
        if pending is not None:
            raise BuildError(f'{book} {chap}: title after the last verse')
    log.append('edition-canon: ' + ', '.join(f'{n} {k}' for k, n in sorted(stats.items())))
    return bible


def count_edition_canon_source(src_dir: Path, cfg: dict) -> int:
    return sum(len(re.findall(r'^\*\*\d+\*\* ', f.read_text(encoding='utf-8'), re.M))
               for _, _, f in canon_files(src_dir))


# ═════════════════════════════════════════════════════════════
# Per-source repairs
# ═════════════════════════════════════════════════════════════

def _letter_end(s: str) -> bool:
    s = s.rstrip()
    return bool(s) and unicodedata.category(s[-1])[0] in 'LM'


def append_final_period(bible: Bible, log: list, what: str):
    """Chapter-final verses of some ZefToOsis conversions lost their final
    full stop (Diodati 96 %, SVD 99 % of chapters, against ~0 % elsewhere)."""
    n = 0
    for book, chs in bible.books.items():
        for c, vs in chs.items():
            last = vs[max(vs)]
            if _letter_end(last.text.plain()) and last.text.parts:
                last.text.parts[-1][1] = last.text.parts[-1][1].rstrip() + '.'
                n += 1
    log.append(f'{what}: restored the final full stop of {n} chapters')


def fix_svd(bible: Bible, log: list):
    # The upstream file labels 1 Chronicles as '2Chr' and 2 Chronicles as
    # 'Ezra' (handled by div_book_override); the rest is text clean-up.
    n_bidi = n_star = 0
    junk = re.compile(r'\(\s*\[\s*\((?:I|II|III) [A-Za-z]+ \d+:\d+\)\s*\)\s*(.*?)\s*\]\s*$')
    for b, c, n, v in bible.all_verses():
        before = v.text.plain(notes=True)

        def clean(s):
            # A mark between two letters stands for a lost space (e.g. 1 Cor 12:15)
            s = re.sub(r'(?<=\w)[\u200e\u200f](?=\w)', ' ', s)
            s = strip_bidi_controls(s)
            s = re.sub(r'\s*\*{3,}\s*', ' … ', s)
            # "كثيرا ‎." → "كثيرا." once the mark between space and stop is gone;
            # a lone tanween after a space ("خيمته ً.") is a stray mark upstream
            s = re.sub(r'\s+[\u064b-\u0652]+(?=[.،؛]|$)', '', s)
            return re.sub(r'(?<=\S) +(?=\.)', '', s)
        v.text.map_text(clean)
        after = v.text.plain(notes=True)
        n_bidi += before.count('\u200e') + before.count('\u200f')
        n_star += len(re.findall(r'\*{3,}', before))
        # "… ( [ (III John 1:15) ) سلام لك … ]" → the KJV-numbered verse text
        if v.text.parts and junk.search(after):
            v.text.parts = [['t', junk.sub(r'\1', after)]]
    # 3 John 1:1 is ':' upstream; the verse text of the same Van Dyck
    # translation, without vowel marks (eBible.org arb-vd 3JN 1:1).
    v = bible.books['3 John'][1][1]
    if v.text.plain().strip() in (':', ''):
        v.text = Text()
        v.text.add('t', 'الشيخ الى غايس الحبيب الذي انا احبه بالحق.')
        log.append('SVD: restored 3 John 1:1 (":" upstream)')
    log.append(f'SVD: removed {n_bidi} bidi marks, {n_star} asterisk runs → ellipsis')
    append_final_period(bible, log, 'SVD')


def fix_diodati(bible: Bible, log: list):
    append_final_period(bible, log, 'Diodati')


def fix_darby(bible: Bible, log: list):
    n = 0
    for b, c, vn, v in bible.all_verses():
        for p in v.text.parts:
            if 'à>' in p[1]:
                p[1] = p[1].replace('à>', 'à')
                n += 1
    log.append(f'Darby: removed {n} stray ">"')


# KorRV slots that are empty (or hold the placeholder 상동 "ditto"/(없음)):
# verses the 개역한글 prints as "(없음)" (omitted in its Greek text), verses
# printed together with the previous one, and slots that exist only in the
# module's NRSV versification.
KO_OMITTED = {("Matthew", 17, 21), ("Matthew", 18, 11), ("Matthew", 23, 14), ("Mark", 9, 44),
              ("Mark", 9, 46), ("Mark", 11, 26), ("Mark", 15, 28), ("Luke", 17, 36),
              ("Luke", 23, 17), ("Acts", 8, 37), ("Acts", 15, 34), ("Acts", 28, 29),
              ("Romans", 16, 24)}
KO_MERGED = {("1 Samuel", 30, 31), ("1 Chronicles", 16, 13), ("Job", 31, 34), ("Job", 35, 11),
             ("Psalms", 72, 20), ("Isaiah", 30, 2), ("Isaiah", 48, 2), ("Jeremiah", 21, 2),
             ("Ezekiel", 24, 5), ("Acts", 15, 26), ("Romans", 9, 2)}
KO_NOT_IN_EDITION = {("2 Corinthians", 13, 14), ("Revelation", 12, 18)}


def fix_korrv(bible: Bible, log: list):
    seen = set()
    for b, c, n, v in list(bible.all_verses()):
        t = v.text.plain().strip()
        if t and t not in ('상동', '(없음)'):
            continue
        key = (b, c, n)
        seen.add(key)
        if key in KO_OMITTED:
            v.text = Text()
            v.text.add('t', '(없음)')
        elif key in KO_MERGED:
            prev = bible.books[b][c][n - 1]
            prev.covers.append(n)
            prev.label = f'{n - 1}–{n}'
            del bible.books[b][c][n]
        elif key in KO_NOT_IN_EDITION:
            del bible.books[b][c][n]
        else:
            raise BuildError(f'KorRV: unexpected empty verse {key}')
    missing = (KO_OMITTED | KO_MERGED | KO_NOT_IN_EDITION) - seen
    if missing:
        raise BuildError(f'KorRV: expected placeholder verses not found: {sorted(missing)}')
    log.append(f'KorRV: {len(KO_OMITTED)} verses shown as (없음), {len(KO_MERGED)} merged, '
               f'{len(KO_NOT_IN_EDITION)} NRSV-only slots dropped')


# JapBungo (文語訳): New Testament verses whose text in the module is "[なし]"
# (none in this edition; shown as in the module), and the empty slots of
# verses printed together with a neighbour (empty slot → the slot that holds
# both, labelled e.g. "24–25").
JA_NASHI = {("Matthew", 17, 21), ("Matthew", 18, 11), ("Matthew", 23, 14), ("Mark", 7, 16),
            ("Mark", 9, 44), ("Mark", 9, 46), ("Mark", 11, 26), ("Mark", 15, 28), ("Luke", 17, 36),
            ("Luke", 23, 17), ("Acts", 8, 37), ("Acts", 15, 34), ("Acts", 24, 7), ("Acts", 28, 29),
            ("Romans", 16, 24)}
JA_MERGED = {("Exodus", 7, 25): 24, ("2 Samuel", 19, 25): 26, ("2 Chronicles", 2, 13): 12}
# Transcription slips in the module text: (book, chapter, verse) → [(old, new)].
JA_REPAIRS = {
    ("Genesis", 26, 8): [('\\牖', '牖')],                           # stray backslash
    ("Amos", 9, 11): [('傾\\圯', '傾圯')],
    ("Exodus", 32, 11): [('モ\u2212セ', 'モーセ')],                      # minus sign for the long-vowel mark
    ("Exodus", 32, 19): [('モ\u2212セ', 'モーセ')],
    ("2 Samuel", 6, 13): [('行](ゆき)}', ruby('行', 'ゆき'))],           # unconverted ruby markup
    ("2 Chronicles", 11, 7): [('ベテズル\uff40', 'ベテズル、')],         # ｀ for 、 between names
    ("Jeremiah", 8, 13): [('つかはす.', 'つかはす')],                   # stray full stop
    ("Mark", 16, 20): [('へり〕', 'へり］')],                             # ［…〕 → ［…］ (Mark 16:9–20)
}
# Readings with a typing slip: a stray backquote, and がえｈん for がへん (肯).
_JA_GLOSS_FIX = [(re.compile(f'{RUBY_SEP}([^{RUBY_CLOSE}`]*)`([^{RUBY_CLOSE}]*){RUBY_CLOSE}'),
                  f'{RUBY_SEP}\\1\\2{RUBY_CLOSE}', 5),
                 (re.compile(f'{RUBY_SEP}がえｈん{RUBY_CLOSE}'), f'{RUBY_SEP}がへん{RUBY_CLOSE}', 1)]


def fix_bungo(bible: Bible, log: list):
    seen = set()
    for b, c, n, v in list(bible.all_verses()):
        t = v.text.plain().strip()
        key = (b, c, n)
        if t == '[なし]':
            if key not in JA_NASHI:
                raise BuildError(f'JapBungo: unexpected [なし] at {key}')
            seen.add(key)
        elif not t:
            if key not in JA_MERGED:
                raise BuildError(f'JapBungo: unexpected empty verse {key}')
            seen.add(key)
            host = bible.books[b][c][JA_MERGED[key]]
            host.covers.append(n)
            nums = sorted([JA_MERGED[key], n])
            host.label = f'{nums[0]}–{nums[1]}'
            del bible.books[b][c][n]
    missing = (JA_NASHI | set(JA_MERGED)) - seen
    if missing:
        raise BuildError(f'JapBungo: expected placeholder verses not found: {sorted(missing)}')
    for (b, c, n), reps in JA_REPAIRS.items():
        parts = bible.books[b][c][n].text.parts
        for old, new in reps:
            hits = [p for p in parts if old in p[1]]
            if len(hits) != 1 or hits[0][1].count(old) != 1:
                raise BuildError(f'JapBungo {b} {c}:{n}: {old!r} not found once (review JA_REPAIRS)')
            hits[0][1] = hits[0][1].replace(old, new)
    for rx, rep, want in _JA_GLOSS_FIX:
        got = 0
        for b, c, n, v in bible.all_verses():
            for p in v.text.parts:
                p[1], k = rx.subn(rep, p[1])
                got += k
        if got != want:
            raise BuildError(f'JapBungo: {got} readings match {rx.pattern!r}, expected {want}')
    # Spaces: in the Old Testament (no punctuation) a space marks a pause and
    # stays, except next to 、。. In the New Testament (punctuated) the module
    # puts a space between two words with readings of their own (聖 靈, 二 歳),
    # which the printed text runs together, and after 、。 twice.
    spaces = 0
    for b, c, n, v in bible.all_verses():
        for p in v.text.parts:
            new = p[1].replace(' ', '') if b in NT_BOOKS else re.sub(r' *([、。]) *', r'\1', p[1])
            spaces += len(p[1]) - len(new)
            p[1] = new
    log.append(f'JapBungo: {len(JA_NASHI)} verses [なし], {len(JA_MERGED)} verses merged with a neighbour, '
               f'{sum(map(len, JA_REPAIRS.values()))} text and 6 reading slips repaired, {spaces} spaces '
               'between words removed')


# Almeida 1911 (Gutenberg #62383): a transcriber's query left in Num 5:3
# ("Desde o[_o_?] homem").
def fix_almeida1911(bible: Bible, log: list):
    v = bible.books['Numbers'][5][3]
    parts = v.text.parts
    if not (len(parts) >= 3 and parts[0] == ['t', 'Desde o['] and parts[1] == ['i', 'o']
            and parts[2][0] == 't' and parts[2][1].startswith('?] ')):
        raise BuildError(f'Almeida 1911 Numbers 5:3: unexpected text {v.text.plain()[:30]!r} (review fix_almeida1911)')
    v.text.parts = [['t', 'Desde o' + parts[2][1][2:]]] + parts[3:]
    log.append('Almeida 1911: removed the transcriber\'s "[o?]" in Numbers 5:3')


# Union Version 1919 (Wikisource): two verse-number slips, renumbered as in
# the KJV versification and the 1988 新標點和合本. The Wikisource text numbers
# 1 Chronicles 22:1 as 21:31 (and 22:2–19 as 22:1–18), and gives John 7:53 as
# the first sentence of 8:1. Only the numbers change.
def fix_cuv1919(bible: Bible, log: list):
    ch21, ch22 = bible.books['1 Chronicles'][21], bible.books['1 Chronicles'][22]
    if not (max(ch21) == 31 and max(ch22) == 18 and ch21[31].text.plain().startswith('大衞說、這就是')):
        raise BuildError('CUV 1919 1 Chronicles 21–22: unexpected numbering (review fix_cuv1919)')
    moved = ch21.pop(31)
    for n in sorted(ch22, reverse=True):
        ch22[n + 1] = ch22.pop(n)
    ch22[1] = moved
    john7, v81 = bible.books['John'][7], bible.books['John'][8][1]
    head = '於是各人都回家去了．'
    if not (max(john7) == 52 and v81.text.parts and v81.text.parts[0][0] == 't'
            and v81.text.parts[0][1].startswith(head)):
        raise BuildError('CUV 1919 John 7:53: unexpected text of 8:1 (review fix_cuv1919)')
    v753 = Verse()
    v753.text.add('t', head)
    v81.text.parts[0][1] = v81.text.parts[0][1][len(head):]
    john7[53] = v753
    log.append('CUV 1919: renumbered 1 Chronicles 21:31–22:18 as 22:1–19; John 7:53 split from 8:1')


# Simplified Chinese from the 1919 traditional text. OpenCC's t2s maps 爲,
# 衆, 眞, 喫, 纔 … itself; the variant forms below it leaves as they are (or
# maps to a character outside the common fonts), so they are first mapped to
# the traditional form it converts to the standard simplified character
# (衞 → 衛 → 卫, 徧 → 遍, 餧 → 餵 → 喂). Rare characters without a standard
# form (𤘘, 𧼮, 𤏲) stay.
OPENCC_VERSION = '1.4.2'
ZH_T2S_VARIANTS = dict(zip(
    '衞汚塲徧毘輭寃躱愼畧痲朶燄窰醡疎躭撚繙稭鬬犂槪顚餂倂蹧蔯効摀餽粃姪尅甎煖儹跥籐顋麅啣羢銲鉋堦韮諠騌鑪賸箒缾杴蝱覩勅荳餧櫺罣咷搆',
    '衛污場遍毗軟冤躲慎略麻朵焰窯榨疏耽捻翻秸鬥犁概顛舔併糟陳效捂饋秕侄剋磚暖攢跺藤腮狍銜絨焊刨階韭喧鬃爐剩帚瓶鍁虻睹敕豆餵欞掛啕夠'))


def fix_t2s(bible: Bible, log: list):
    try:
        import opencc
        from importlib.metadata import version
        got = version('opencc')
    except ImportError:
        raise BuildError(f'the OpenCC Python package is missing: pip install opencc=={OPENCC_VERSION}')
    if got != OPENCC_VERSION:
        raise BuildError(f'OpenCC {got} installed, the build is pinned to {OPENCC_VERSION}: '
                         f'pip install opencc=={OPENCC_VERSION}')
    conv = opencc.OpenCC('t2s')
    pre = str.maketrans(ZH_T2S_VARIANTS)
    changed = Counter()

    def convert(s: str) -> str:
        out = conv.convert(s.translate(pre))
        if len(out) == len(s):
            changed.update(a for a, b in zip(s, out) if a != b)
        return out

    def text(t: Text | None):
        if t is None:
            return
        joined = ''.join(p[1] for p in t.parts)
        out = convert(joined)
        if len(out) == len(joined):          # convert whole phrases across runs
            i = 0
            for p in t.parts:
                p[1], i = out[i:i + len(p[1])], i + len(p[1])
        else:
            for p in t.parts:
                p[1] = convert(p[1])

    for b, c, n, v in bible.all_verses():
        text(v.text)
        text(v.title)
    for key, notes in bible.chapter_notes.items():
        bible.chapter_notes[key] = [(mark, [(convert(t), k) for t, k in content]) for mark, content in notes]
    log.append(f'OpenCC {OPENCC_VERSION} t2s: {sum(changed.values())} characters converted '
               f'({len(changed)} distinct)')


FIXUPS = {'svd': fix_svd, 'diodati': fix_diodati, 'darby': fix_darby, 'korrv': fix_korrv,
          'bungo': fix_bungo, 'almeida1911': fix_almeida1911, 'cuv1919': fix_cuv1919, 't2s': fix_t2s}


# ═════════════════════════════════════════════════════════════
# Books, expected shape and build gates
# ═════════════════════════════════════════════════════════════

def allowed_books(cfg: dict) -> set[str]:
    if cfg.get('testament') == 'nt':
        return set(NT_BOOKS)
    books = set(BOOK_ORDER)
    if cfg.get('deutero'):
        books |= set(DEUTERO_CHAPTERS)
    return books


def book_order(cfg: dict) -> list[str]:
    order = BOOK_ORDER_CATHOLIC if cfg.get('deutero') else BOOK_ORDER
    books = allowed_books(cfg)
    return [b for b in order if b in books]


def expected_chapters(cfg: dict) -> dict[str, int]:
    exp = {b: len(KJV_VERSES[b]) if b in KJV_VERSES else DEUTERO_CHAPTERS[b]
           for b in book_order(cfg)}
    exp.update(cfg.get('chapters', {}))
    return exp


def check_parse(bible: Bible, cfg: dict, source_count: int):
    """Gates that run on the raw parse, before any per-source repair."""
    errors = []
    omit = set(cfg.get('omit_codes', ()))
    for code, n in sorted(bible.skipped_books.items()):
        if code not in omit and n:
            errors.append(f'source book {code!r} ({n} verses) is not mapped to any book')
    parsed = len(bible.refs())
    if parsed != source_count:
        errors.append(f'parsed {parsed} verses, the source has {source_count}')
    if errors:
        raise BuildError('; '.join(errors))


def check_shape(bible: Bible, cfg: dict, log: list):
    """Gates on the final text: books, chapters, verse counts, empty verses."""
    errors = []
    exp = expected_chapters(cfg)
    got = set(bible.books)
    if got != set(exp):
        errors.append(f'books missing {sorted(set(exp) - got)}, unexpected {sorted(got - set(exp))}')
    for b, n in exp.items():
        chs = sorted(bible.books.get(b, {}))
        if chs != list(range(1, n + 1)):
            missing = sorted(set(range(1, n + 1)) - set(chs))
            extra = sorted(set(chs) - set(range(1, n + 1)))
            errors.append(f'{b}: chapters missing {missing}, extra {extra}')
    # Verse count per chapter against the KJV table: a chapter that holds far
    # more or fewer verses than expected is mislabelled or overlaid upstream.
    skip = set(cfg.get('shape_skip', ()))
    odd, one_short = 0, []
    for b, chs in bible.books.items():
        if b not in KJV_VERSES or b in skip:
            continue
        for c, vs in chs.items():
            if (b, c) in skip or c > len(KJV_VERSES[b]):
                continue
            k = KJV_VERSES[b][c - 1]
            n = len({x for v, verse in vs.items() for x in [v] + verse.covers})
            if n != k:
                odd += 1
            if n == k - 1:
                one_short.append(f'{b} {c}')
            if n > k * 1.5 + 2 or n < k * 0.5 - 2:
                errors.append(f'{b} {c}: {n} verses, KJV versification has {k}')
    # Words that only exist when an upstream conversion deleted non-ASCII
    # letters ('clum' for 'cælum', 'qu' for 'quæ'): the old Vulgate source
    # had 7,640 of them.
    garbled = cfg.get('garbled_words')
    if garbled:
        hits = Counter(m for _, _, _, v in bible.all_verses() for m in garbled.findall(v.text.plain()))
        if hits:
            errors.append(f'stripped-letter words in the text: {dict(hits.most_common(8))}')
    allow_empty = set(cfg.get('allow_empty', ()))
    for b, c, n, v in bible.all_verses():
        if v.text.empty() and (b, c, n) not in allow_empty:
            errors.append(f'empty verse {b} {c}:{n}')
    if errors:
        raise BuildError('; '.join(errors[:20]) + (f' (+{len(errors) - 20} more)' if len(errors) > 20 else ''))
    log.append(f'{odd} chapters differ from the KJV verse count (versification)'
               + (f'; one verse short: {", ".join(one_short[:12])}' if one_short else ''))


# ═════════════════════════════════════════════════════════════
# Lookup keys: main keys, aliases and verse references
# ═════════════════════════════════════════════════════════════
#
# The app matches keys ignoring case. Aliases are @@@LINK redirects; when two
# aliases with different targets normalize to the same key, the one with the
# lower rank wins (a local name beats a local abbreviation, which beats an
# accent-free spelling, which beats an English name or abbreviation) and the
# loser is counted in the build log. Losing a rank-0..3 alias is a build error.

R_MAIN, R_LOCAL, R_NAME, R_LEGACY, R_ABBR, R_FOLD, R_EN, R_EN_ABBR, R_VERSE, R_VERSE_FOLD = range(10)

_APOS = str.maketrans({'’': "'", 'ʼ': "'", '‘': "'"})


def key_norm(s: str) -> str:
    return re.sub(r'\s+', ' ', unicodedata.normalize('NFC', s).translate(_APOS)).strip().lower()


class KeySet:
    def __init__(self, name: str):
        self.name = name
        self.main: dict[str, str] = {}               # norm → main key
        self.alias: dict[str, tuple[int, set]] = {}  # norm → (rank, targets)
        self.out: list[tuple[str, str]] = []         # alias entries
        self.dropped: dict[int, int] = {}
        self.examples: list[str] = []

    def add_main(self, key: str):
        n = key_norm(key)
        if n in self.main:
            raise BuildError(f'{self.name}: duplicate main key {key!r}')
        self.main[n] = key

    def add(self, alias: str, target: str, rank: int, multi: bool = False):
        alias = re.sub(r'\s+', ' ', alias).strip()
        n = key_norm(alias)
        if n in self.main:
            if self.main[n] == target:
                return
            self._drop(alias, target, rank, f'main key {self.main[n]!r}')
            return
        if n in self.alias:
            r, targets = self.alias[n]
            if target in targets:
                return
            if multi and r == rank:
                targets.add(target)
                self.out.append((alias, f'@@@LINK={target}'))
                return
            if r <= rank:
                self._drop(alias, target, rank, f'{sorted(targets)} (rank {r})')
                return
            raise BuildError(f'{self.name}: alias {alias!r} → {target!r} (rank {rank}) added '
                             f'after a weaker alias → {sorted(targets)} (rank {r}); reorder')
        self.alias[n] = (rank, {target})
        self.out.append((alias, f'@@@LINK={target}'))

    def _drop(self, alias, target, rank, other):
        if rank <= R_LEGACY:
            raise BuildError(f'{self.name}: alias {alias!r} → {target!r} collides with {other}')
        self.dropped[rank] = self.dropped.get(rank, 0) + 1
        if len(self.examples) < 8:
            self.examples.append(f'{alias!r}→{target!r} (vs {other})')


def _table(text: str) -> dict[str, list[str]]:
    """'English name = alt | alt …' lines → {English name: [alt, …]}"""
    out = {}
    for line in text.strip().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        book, _, alts = line.partition('=')
        book = book.strip()
        if book not in KJV_VERSES and book not in DEUTERO_CHAPTERS:
            raise ValueError(f'unknown book {book!r} in alias table')
        out[book] = [a.strip() for a in alts.split('|') if a.strip()]
    return out


# English alternative names and abbreviations (every Bible: the English
# chapter keys are shared by all of them).
EN_NAMES = _table("""
Psalms = Psalm
Song of Solomon = Song of Songs | Canticles | Canticle of Canticles
Ecclesiastes = Qoheleth
Revelation = Revelations | Apocalypse | Revelation of John
Acts = Acts of the Apostles
Tobit = Tobias
Wisdom = Wisdom of Solomon
Sirach = Ecclesiasticus | Ben Sira
""")
EN_ABBR = _table("""
Genesis = Gen | Gn
Exodus = Exod | Ex | Exo
Leviticus = Lev | Lv
Numbers = Num | Nm | Nb
Deuteronomy = Deut | Dt | Deu
Joshua = Josh | Jos
Judges = Judg | Jdg
Ruth = Rth
1 Samuel = 1 Sam | 1 Sa
2 Samuel = 2 Sam | 2 Sa
1 Kings = 1 Kgs | 1 Ki
2 Kings = 2 Kgs | 2 Ki
1 Chronicles = 1 Chr | 1 Chron | 1 Ch
2 Chronicles = 2 Chr | 2 Chron | 2 Ch
Ezra = Ezr
Nehemiah = Neh
Esther = Esth | Est
Job = Jb
Psalms = Ps | Psa | Pss
Proverbs = Prov | Prv | Pro
Ecclesiastes = Eccl | Eccles | Ecc | Qoh
Song of Solomon = Song | Cant | Sg
Isaiah = Isa | Is
Jeremiah = Jer
Lamentations = Lam
Ezekiel = Ezek | Ezk
Daniel = Dan | Dn
Hosea = Hos
Joel = Jl
Amos = Am
Obadiah = Obad | Ob
Jonah = Jon
Micah = Mic
Nahum = Nah
Habakkuk = Hab
Zephaniah = Zeph | Zep
Haggai = Hag
Zechariah = Zech | Zec
Malachi = Mal
Matthew = Matt | Mt
Mark = Mk | Mrk
Luke = Lk | Luk
John = Jn | Jhn
Acts = Act
Romans = Rom | Ro
1 Corinthians = 1 Cor | 1 Co
2 Corinthians = 2 Cor | 2 Co
Galatians = Gal
Ephesians = Eph
Philippians = Phil | Php
Colossians = Col
1 Thessalonians = 1 Thess | 1 Th
2 Thessalonians = 2 Thess | 2 Th
1 Timothy = 1 Tim | 1 Ti
2 Timothy = 2 Tim | 2 Ti
Titus = Tit
Philemon = Phlm | Philem | Phm
Hebrews = Heb
James = Jas
1 Peter = 1 Pet | 1 Pe | 1 Pt
2 Peter = 2 Pet | 2 Pe | 2 Pt
1 John = 1 Jn | 1 Jo
2 John = 2 Jn | 2 Jo
3 John = 3 Jn | 3 Jo
Jude = Jud
Revelation = Rev | Rv
Tobit = Tob
Judith = Jdt
Wisdom = Wis
Sirach = Sir
Baruch = Bar
1 Maccabees = 1 Macc | 1 Mac
2 Maccabees = 2 Macc | 2 Mac
""")

_ROMAN = {'1': 'I', '2': 'II', '3': 'III', '4': 'IV'}
_ORDINAL_EN = {'1': 'First', '2': 'Second', '3': 'Third'}


def numbered_variants(name: str, style: str = 'latin') -> list[str]:
    """'1 Kings' → ['1Kings', 'I Kings']; German '1. Mose' → ['1 Mose',
    '1.Mose', '1Mose']; Russian '1 Царств' → ['1Царств']."""
    m = re.match(r'^([1-4])(\.?) (.+)$', name)
    if not m:
        return []
    n, dot, rest = m.groups()
    if style == 'de':
        return [f'{n} {rest}', f'{n}.{rest}', f'{n}{rest}']
    if style in ('ru', 'el'):
        return [f'{n}{rest}']
    return [f'{n}{rest}', f'{_ROMAN[n]} {rest}']


def fold_latin(s: str) -> str:
    """Accent-free form: 'Ésaïe' → 'Esaie', 'Matthæus' → 'Matthaeus'."""
    s = s.replace('æ', 'ae').replace('Æ', 'Ae').replace('œ', 'oe').replace('Œ', 'Oe')
    return ''.join(ch for ch in unicodedata.normalize('NFD', s)
                   if not unicodedata.combining(ch)).replace('ß', 'ss')


def german_umlaut(s: str) -> str:
    return (s.replace('ä', 'ae').replace('ö', 'oe').replace('ü', 'ue')
             .replace('Ä', 'Ae').replace('Ö', 'Oe').replace('Ü', 'Ue'))


_GREEK_MARKS = {'̓', '̔', 'ͅ', '̆', '̄'}   # breathings, iota subscript, breve, macron
_GREEK_ACCENTS = {'̀': '́', '͂': '́', '́': '́'}


def greek_monotonic(s: str) -> str:
    """Polytonic → monotonic: grave/circumflex → tonos, breathings and iota
    subscript dropped; U+02B9 numeral sign → U+0384 tonos (as typed)."""
    out = []
    for ch in unicodedata.normalize('NFD', s):
        if ch in _GREEK_MARKS:
            continue
        out.append(_GREEK_ACCENTS.get(ch, ch))
    return unicodedata.normalize('NFC', ''.join(out)).replace('ʹ', '΄')


def greek_plain(s: str) -> str:
    """No accents at all (what most people type): 'Κατα Ιωαννην'."""
    s = ''.join(ch for ch in unicodedata.normalize('NFD', s) if not unicodedata.combining(ch))
    return unicodedata.normalize('NFC', s).replace('ʹ', '').replace('΄', '').strip()


_HAMZA = str.maketrans({'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا'})
_ARABIC_DIGITS = str.maketrans('0123456789', '٠١٢٣٤٥٦٧٨٩')


def arabic_digits(s) -> str:
    return str(s).translate(_ARABIC_DIGITS)


# ── Per-language alternative names and abbreviations ─────────

ZH_HANS_NAMES = _table("""
Genesis = 创世纪
1 Kings = 列王记上
2 Kings = 列王记下
Philippians = 腓利比书
1 John = 约翰壹书
2 John = 约翰贰书
3 John = 约翰叁书 | 约翰参书
""")
ZH_HANT_NAMES = _table("""
Genesis = 創世紀
1 Kings = 列王記上
2 Kings = 列王記下
Philippians = 腓利比書
1 John = 約翰壹書
2 John = 約翰貳書
3 John = 約翰參書 | 約翰叁書
Revelation = 啓示錄
""")
_ZH_HANS_ABBR = ('创 出 利 民 申 书 士 得 撒上 撒下 王上 王下 代上 代下 拉 尼 斯 伯 诗 箴 传 歌 赛 耶 '
                 '哀 结 但 何 珥 摩 俄 拿 弥 鸿 哈 番 该 亚 玛 太 可 路 约 徒 罗 林前 林后 加 弗 腓 西 '
                 '帖前 帖后 提前 提后 多 门 来 雅 彼前 彼后 约一 约二 约三 犹 启').split()
_ZH_HANT_ABBR = ('創 出 利 民 申 書 士 得 撒上 撒下 王上 王下 代上 代下 拉 尼 斯 伯 詩 箴 傳 歌 賽 耶 '
                 '哀 結 但 何 珥 摩 俄 拿 彌 鴻 哈 番 該 亞 瑪 太 可 路 約 徒 羅 林前 林後 加 弗 腓 西 '
                 '帖前 帖後 提前 提後 多 門 來 雅 彼前 彼後 約壹 約貳 約參 猶 啟').split()
ZH_HANS_ABBR = {b: [a] for b, a in zip(BOOK_ORDER, _ZH_HANS_ABBR)}
ZH_HANT_ABBR = {b: [a] for b, a in zip(BOOK_ORDER, _ZH_HANT_ABBR)}
ZH_HANT_ABBR['1 John'].append('約一')
ZH_HANT_ABBR['2 John'].append('約二')
ZH_HANT_ABBR['3 John'].append('約三')
ZH_HANT_ABBR['Revelation'].append('啓')

# 新共同訳 / 新改訳 names and the Kougo source's own spellings
JA_NAMES = _table("""
1 Kings = 列王記上 | 列王記第一
2 Kings = 列王記下 | 列王記第二
1 Chronicles = 歴代誌上 | 歴代誌第一
2 Chronicles = 歴代誌下 | 歴代誌第二
1 Samuel = サムエル記第一
2 Samuel = サムエル記第二
Nehemiah = ネヘミヤ書
Psalms = 詩編
Ecclesiastes = コヘレトの言葉 | 伝道者の書
Song of Solomon = 雅歌
Zephaniah = ゼファニヤ書
Matthew = マタイ福音書 | マタイの福音書 | マタイ
Mark = マルコ福音書 | マルコの福音書 | マルコ
Luke = ルカ福音書 | ルカの福音書 | ルカ
John = ヨハネ福音書 | ヨハネの福音書 | ヨハネ
Acts = 使徒言行録 | 使徒の働き
Romans = ローマの信徒への手紙 | ローマ人への手紙 | ローマ書 | ローマ
1 Corinthians = コリントの信徒への手紙一 | コリント人への手紙第一 | 第一コリント | 1コリント
2 Corinthians = コリントの信徒への手紙二 | コリント人への手紙第二 | 第二コリント | 2コリント
Galatians = ガラテヤの信徒への手紙 | ガラテヤ書
Ephesians = エフェソの信徒への手紙 | エペソ書
Philippians = フィリピの信徒への手紙 | ピリピ書
Colossians = コロサイの信徒への手紙 | コロサイ書
1 Thessalonians = テサロニケの信徒への手紙一 | テサロニケ人への手紙第一
2 Thessalonians = テサロニケの信徒への手紙二 | テサロニケ人への手紙第二
1 Timothy = テモテへの手紙一 | テモテへの手紙第一 | テモテヘの第一の手紙
2 Timothy = テモテへの手紙二 | テモテへの手紙第二 | テモテヘの第二の手紙
Titus = テトスヘの手紙
Philemon = フィレモンへの手紙 | ピレモンヘの手紙
Hebrews = ヘブライ人への手紙 | ヘブル書
1 Peter = ペトロの手紙一 | ペテロの手紙第一
2 Peter = ペトロの手紙二 | ペテロの手紙第二
1 John = ヨハネの手紙一 | ヨハネの手紙第一
2 John = ヨハネの手紙二 | ヨハネの手紙第二
3 John = ヨハネの手紙三 | ヨハネの手紙第三
Revelation = 黙示録
""")
_JA_ABBR = ('創 出 レビ 民 申 ヨシュ 士 ルツ サム上 サム下 王上 王下 代上 代下 エズ ネヘ エス ヨブ 詩 箴 '
            '伝 雅 イザ エレ 哀 エゼ ダニ ホセ ヨエ アモ オバ ヨナ ミカ ナホ ハバ ゼパ ハガ ゼカ マラ '
            'マタ マコ ルカ ヨハ 使 ロマ 1コリ 2コリ ガラ エペ ピリ コロ 1テサ 2テサ 1テモ 2テモ テト '
            'ピレ ヘブ ヤコ 1ペテ 2ペテ 1ヨハ 2ヨハ 3ヨハ ユダ 黙').split()
JA_ABBR = {b: [a] for b, a in zip(BOOK_ORDER, _JA_ABBR)}
_JA_ORD = {'第一': '1', '第二': '2', '第三': '3'}
_KATAKANA = re.compile(r'[ァ-ヺ]')


def _ja_short(local: str) -> str | None:
    """Short name Japanese readers write before a reference: 'イザヤ書' →
    'イザヤ', 'ローマ人への手紙' → 'ローマ', 'コリント人への第一の手紙' →
    '1コリント', 'マタイによる福音書' → 'マタイ'."""
    m = re.match(r'^(.+?)人?への(第[一二三])の手紙$', local) or re.match(r'^(.+?)の(第[一二三])の手紙$', local)
    if m:
        return _JA_ORD[m.group(2)] + m.group(1)
    for suf in ('による福音書', '人への手紙', 'への手紙', 'の手紙', '書', '記'):
        if local.endswith(suf):
            stem = local[:-len(suf)]
            return stem if _KATAKANA.search(stem) and not stem.endswith('の') else None
    return None


JA_SHORT = {b: [n] for b, n in ((b, _ja_short(l)) for b, l in JA_BOOK_NAMES.items()) if n}
JA_SHORT.update({'Acts': ['使徒'], 'Revelation': ['黙示録']})
for _b, _a in (('Ecclesiastes', 'コヘ'), ('Zephaniah', 'ゼファ'), ('Ephesians', 'エフェ'),
               ('Philippians', 'フィリ'), ('Philemon', 'フィレ'), ('1 Peter', '1ペト'),
               ('2 Peter', '2ペト'), ('Romans', 'ロー')):
    JA_ABBR[_b].append(_a)

# 文語訳 book titles (明治元訳 OT, 大正改訳 NT; as in the 1950s printings) and
# their new-style-kanji spellings
JA_BUNGO_NAMES = _table("""
Numbers = 民數紀略 | 民数紀略
1 Samuel = サムエル前書
2 Samuel = サムエル後書
1 Kings = 列王紀略上
2 Kings = 列王紀略下
1 Chronicles = 歴代志略上 | 歷代志略上
2 Chronicles = 歴代志略下 | 歷代志略下
Ezra = エズラ書
Esther = エステル書
Ecclesiastes = 傳道之書 | 伝道之書
Jeremiah = ヱレミヤ記 | エレミヤ記
Lamentations = エレミヤの哀歌 | ヱレミヤ哀歌
Matthew = マタイ傳福音書 | マタイ伝福音書
Mark = マルコ傳福音書 | マルコ伝福音書
Luke = ルカ傳福音書 | ルカ伝福音書
John = ヨハネ傳福音書 | ヨハネ伝福音書
Acts = 使徒行傳
Romans = ロマ人への書
1 Corinthians = コリント人への前の書
2 Corinthians = コリント人への後の書
Galatians = ガラテヤ人への書
Ephesians = エペソ人への書
Philippians = ピリピ人への書
Colossians = コロサイ人への書
1 Thessalonians = テサロニケ人への前の書
2 Thessalonians = テサロニケ人への後の書
1 Timothy = テモテへの前の書
2 Timothy = テモテへの後の書
Titus = テトスへの書
Philemon = ピレモンへの書
Hebrews = ヘブル人への書
James = ヤコブの書
1 Peter = ペテロの前の書
2 Peter = ペテロの後の書
1 John = ヨハネの第一の書
2 John = ヨハネの第二の書
3 John = ヨハネの第三の書
Jude = ユダの書
Revelation = ヨハネの默示録 | 默示録
""")

KO_NAMES = _table("""
1 John = 요한1서
2 John = 요한2서
3 John = 요한3서
""")
_KO_ABBR = ('창 출 레 민 신 수 삿 룻 삼상 삼하 왕상 왕하 대상 대하 스 느 에 욥 시 잠 전 아 사 렘 '
            '애 겔 단 호 욜 암 옵 욘 미 나 합 습 학 슥 말 마 막 눅 요 행 롬 고전 고후 갈 엡 빌 골 '
            '살전 살후 딤전 딤후 딛 몬 히 약 벧전 벧후 요일 요이 요삼 유 계').split()
KO_ABBR = {b: [a] for b, a in zip(BOOK_ORDER, _KO_ABBR)}

AR_NAMES = _table("""
Genesis = تكوين | سفر التكوين
Exodus = خروج | سفر الخروج
Leviticus = لاويين | سفر اللاويين
Numbers = عدد | سفر العدد
Deuteronomy = تثنية | سفر التثنية | تثنية الاشتراع
Judges = قضاة | سفر القضاة
Psalms = مزامير | مزمور | المزمور
Proverbs = أمثال
Ecclesiastes = جامعة
Song of Solomon = نشيد الانشاد
Lamentations = المراثي
Matthew = إنجيل متى
Mark = إنجيل مرقس
Luke = إنجيل لوقا
John = إنجيل يوحنا
Acts = أعمال
Hebrews = عبرانيين
Revelation = رؤيا | سفر الرؤيا
""")

RU_NAMES = _table("""
Judges = Судьи
1 Samuel = 1-я Царств
2 Samuel = 2-я Царств
1 Kings = 3-я Царств
2 Kings = 4-я Царств
1 Chronicles = 1-я Паралипоменон
2 Chronicles = 2-я Паралипоменон
Song of Solomon = Песня Песней | Песнь песней Соломона
Matthew = От Матфея | Евангелие от Матфея | Матфея
Mark = От Марка | Евангелие от Марка | Марка
Luke = От Луки | Евангелие от Луки | Луки
John = От Иоанна | Евангелие от Иоанна | Иоанна
Acts = Деяния апостолов | Деяния святых апостолов
Romans = К Римлянам
1 Corinthians = 1-е Коринфянам
2 Corinthians = 2-е Коринфянам
Galatians = К Галатам
Ephesians = К Ефесянам
Philippians = К Филиппийцам
Colossians = К Колоссянам
1 Thessalonians = 1-е Фессалоникийцам
2 Thessalonians = 2-е Фессалоникийцам
1 Timothy = 1-е Тимофею
2 Timothy = 2-е Тимофею
Titus = К Титу
Philemon = К Филимону
Hebrews = К Евреям
1 Peter = 1-е Петра
2 Peter = 2-е Петра
1 John = 1-е Иоанна
2 John = 2-е Иоанна
3 John = 3-е Иоанна
Revelation = Апокалипсис | Откровение Иоанна Богослова
""")
_RU_ABBR = ('Быт Исх Лев Чис Втор Нав Суд Руф 1Цар 2Цар 3Цар 4Цар 1Пар 2Пар Езд Неем Есф Иов Пс Притч '
            'Еккл Песн Ис Иер Плач Иез Дан Ос Иоил Ам Авд Ион Мих Наум Авв Соф Агг Зах Мал Мф Мк Лк '
            'Ин Деян Рим 1Кор 2Кор Гал Еф Флп Кол 1Фес 2Фес 1Тим 2Тим Тит Флм Евр Иак 1Пет 2Пет 1Ин '
            '2Ин 3Ин Иуд Откр').split()
RU_ABBR = {b: [a] + ([re.sub(r'^(\d)', r'\1 ', a)] if a[0].isdigit() else []) for b, a in zip(BOOK_ORDER, _RU_ABBR)}

DE_NAMES = _table("""
Genesis = Genesis | Erstes Buch Mose
Exodus = Exodus | Zweites Buch Mose
Leviticus = Levitikus | Drittes Buch Mose
Numbers = Numeri | Viertes Buch Mose
Deuteronomy = Deuteronomium | Fünftes Buch Mose
Job = Ijob | Hiob
Psalms = Psalm
Ecclesiastes = Kohelet | Prediger Salomo
Song of Solomon = Hoheslied | Lied der Lieder
Ezekiel = Ezechiel
Zephaniah = Zefanja
Acts = Apostelgeschichte des Lukas
Revelation = Offenbarung des Johannes | Apokalypse
""")
DE_ABBR = _table("""
Genesis = 1Mo | 1Mose | Gen
Exodus = 2Mo | 2Mose | Ex
Leviticus = 3Mo | 3Mose | Lev
Numbers = 4Mo | 4Mose | Num
Deuteronomy = 5Mo | 5Mose | Dtn
Joshua = Jos
Judges = Ri
Ruth = Rut
1 Samuel = 1Sam
2 Samuel = 2Sam
1 Kings = 1Kön | 1Kön
2 Kings = 2Kön
1 Chronicles = 1Chr
2 Chronicles = 2Chr
Ezra = Esr
Nehemiah = Neh
Esther = Est
Job = Hi | Ijob
Psalms = Ps
Proverbs = Spr
Ecclesiastes = Pred | Koh
Song of Solomon = Hld
Isaiah = Jes
Jeremiah = Jer
Lamentations = Klgl
Ezekiel = Hes | Ez
Daniel = Dan
Hosea = Hos
Joel = Joel
Amos = Am
Obadiah = Obd | Ob
Jonah = Jona
Micah = Mi
Nahum = Nah
Habakkuk = Hab
Zephaniah = Zef
Haggai = Hag
Zechariah = Sach
Malachi = Mal
Matthew = Mt
Mark = Mk
Luke = Lk
John = Joh
Acts = Apg
Romans = Röm
1 Corinthians = 1Kor
2 Corinthians = 2Kor
Galatians = Gal
Ephesians = Eph
Philippians = Phil
Colossians = Kol
1 Thessalonians = 1Thess
2 Thessalonians = 2Thess
1 Timothy = 1Tim
2 Timothy = 2Tim
Titus = Tit
Philemon = Phlm
Hebrews = Hebr
James = Jak
1 Peter = 1Petr
2 Peter = 2Petr
1 John = 1Joh
2 John = 2Joh
3 John = 3Joh
Jude = Jud
Revelation = Offb
""")

ES_NAMES = _table("""
Psalms = Salmo
Song of Solomon = Cantar de los Cantares | Cantar de los cantares | Cantares de Salomón
Matthew = San Mateo
Mark = San Marcos
Luke = San Lucas
John = San Juan
Acts = Hechos de los Apóstoles
James = Jacobo
Revelation = Revelación
""")
ES_ABBR = _table("""
Genesis = Gn | Gén
Exodus = Éx | Ex
Leviticus = Lv | Lev
Numbers = Nm | Núm
Deuteronomy = Dt
Joshua = Jos
Judges = Jue | Jc
Ruth = Rt
1 Samuel = 1 S | 1 Sam
2 Samuel = 2 S | 2 Sam
1 Kings = 1 R | 1 Re
2 Kings = 2 R | 2 Re
1 Chronicles = 1 Cr | 1 Cró
2 Chronicles = 2 Cr | 2 Cró
Ezra = Esd
Nehemiah = Neh
Esther = Est
Job = Jb
Psalms = Sal | Sl
Proverbs = Pr | Prov
Ecclesiastes = Ec | Ecl
Song of Solomon = Cnt | Cant
Isaiah = Is
Jeremiah = Jer
Lamentations = Lm
Ezekiel = Ez
Daniel = Dn
Hosea = Os
Joel = Jl
Amos = Am
Obadiah = Abd
Jonah = Jon
Micah = Mi
Nahum = Nah
Habakkuk = Hab
Zephaniah = Sof
Haggai = Hag
Zechariah = Zac
Malachi = Mal
Matthew = Mt
Mark = Mr | Mc
Luke = Lc
John = Jn
Acts = Hch
Romans = Ro | Rom
1 Corinthians = 1 Co
2 Corinthians = 2 Co
Galatians = Gá | Gal
Ephesians = Ef
Philippians = Fil | Flp
Colossians = Col
1 Thessalonians = 1 Ts
2 Thessalonians = 2 Ts
1 Timothy = 1 Ti | 1 Tm
2 Timothy = 2 Ti | 2 Tm
Titus = Tit
Philemon = Flm
Hebrews = He | Heb
James = Stg | Sant
1 Peter = 1 P | 1 Pe
2 Peter = 2 P | 2 Pe
1 John = 1 Jn
2 John = 2 Jn
3 John = 3 Jn
Jude = Jud
Revelation = Ap | Apoc
""")

FR_NAMES = _table("""
Psalms = Psaume
Isaiah = Isaïe
Ecclesiastes = Qohélet | L'Ecclésiaste
Song of Solomon = Cantique des cantiques | Cantique
Habakkuk = Habacuc
Acts = Actes des Apôtres
Revelation = Révélation
""")
FR_ABBR = _table("""
Genesis = Gn | Gen
Exodus = Ex
Leviticus = Lv
Numbers = Nb
Deuteronomy = Dt
Joshua = Jos
Judges = Jg
Ruth = Rt
1 Samuel = 1 S | 1 Sam
2 Samuel = 2 S | 2 Sam
1 Kings = 1 R
2 Kings = 2 R
1 Chronicles = 1 Ch
2 Chronicles = 2 Ch
Ezra = Esd
Nehemiah = Né | Ne
Esther = Est
Job = Jb
Psalms = Ps
Proverbs = Pr
Ecclesiastes = Ec | Qo
Song of Solomon = Ct
Isaiah = És | Es | Is
Jeremiah = Jr
Lamentations = Lm
Ezekiel = Éz | Ez
Daniel = Dn
Hosea = Os
Joel = Jl
Amos = Am
Obadiah = Ab
Jonah = Jon
Micah = Mi
Nahum = Na
Habakkuk = Ha
Zephaniah = So
Haggai = Ag
Zechariah = Za
Malachi = Ml
Matthew = Mt
Mark = Mc
Luke = Lc
John = Jn
Acts = Ac
Romans = Rm
1 Corinthians = 1 Co
2 Corinthians = 2 Co
Galatians = Ga
Ephesians = Ép | Ep
Philippians = Ph
Colossians = Col
1 Thessalonians = 1 Th
2 Thessalonians = 2 Th
1 Timothy = 1 Tm
2 Timothy = 2 Tm
Titus = Tt
Philemon = Phm
Hebrews = Hé | He
James = Jc
1 Peter = 1 P
2 Peter = 2 P
1 John = 1 Jn
2 John = 2 Jn
3 John = 3 Jn
Jude = Jud
Revelation = Ap
""")

PT_NAMES = _table("""
Genesis = Génesis
Deuteronomy = Deuteronómio
1 Chronicles = 1 Crónicas
2 Chronicles = 2 Crónicas
Psalms = Salmo
Song of Solomon = Cântico dos Cânticos | Cantares
Hosea = Oseias
Micah = Miqueias
Acts = Atos dos Apóstolos | Actos
""")
PT_ABBR = _table("""
Genesis = Gn
Exodus = Êx | Ex
Leviticus = Lv
Numbers = Nm
Deuteronomy = Dt
Joshua = Js
Judges = Jz
Ruth = Rt
1 Samuel = 1 Sm
2 Samuel = 2 Sm
1 Kings = 1 Rs
2 Kings = 2 Rs
1 Chronicles = 1 Cr
2 Chronicles = 2 Cr
Ezra = Ed | Esd
Nehemiah = Ne
Esther = Et
Job = Jó
Psalms = Sl
Proverbs = Pv | Pr
Ecclesiastes = Ec
Song of Solomon = Ct
Isaiah = Is
Jeremiah = Jr
Lamentations = Lm
Ezekiel = Ez
Daniel = Dn
Hosea = Os
Joel = Jl
Amos = Am
Obadiah = Ob
Jonah = Jn
Micah = Mq
Nahum = Na
Habakkuk = Hc
Zephaniah = Sf
Haggai = Ag
Zechariah = Zc
Malachi = Ml
Matthew = Mt
Mark = Mc
Luke = Lc
John = Jo
Acts = At
Romans = Rm
1 Corinthians = 1 Co
2 Corinthians = 2 Co
Galatians = Gl
Ephesians = Ef
Philippians = Fp
Colossians = Cl
1 Thessalonians = 1 Ts
2 Thessalonians = 2 Ts
1 Timothy = 1 Tm
2 Timothy = 2 Tm
Titus = Tt
Philemon = Fm
Hebrews = Hb
James = Tg
1 Peter = 1 Pe
2 Peter = 2 Pe
1 John = 1 Jo
2 John = 2 Jo
3 John = 3 Jo
Jude = Jd
Revelation = Ap
""")

# Almeida 1911: the edition's own spellings (running heads, index, titles)
PT_ARC1911_NAMES = _table("""
Exodus = Exodo
Leviticus = Levitico
Numbers = Numeros
Deuteronomy = Deuteronomio
Judges = Juizes
Ruth = Ruth
1 Samuel = I Samuel
2 Samuel = II Samuel
1 Kings = I Reis
2 Kings = II Reis
1 Chronicles = I Chronicas
2 Chronicles = II Chronicas
Nehemiah = Nehemias
Esther = Esther
Psalms = Psalmos | Psalmo
Proverbs = Proverbios
Song of Solomon = Cantico dos Canticos | Cantares de Salomão
Isaiah = Isaias
Lamentations = Lamentações de Jeremias
Hosea = Oseas
Habakkuk = Habacuc
Haggai = Aggeo
Zechariah = Zacharias
Malachi = Malachias
Matthew = S. Mattheus | Mattheus | Evangelho segundo S. Mattheus | Evangelho de S. Mattheus
Mark = S. Marcos | Evangelho segundo S. Marcos | Evangelho de S. Marcos
Luke = S. Lucas | Evangelho segundo S. Lucas | Evangelho de S. Lucas
John = S. João | Evangelho segundo S. João | Evangelho de S. João
Acts = Actos | Actos dos Apostolos
1 Corinthians = I Corinthios
2 Corinthians = II Corinthios
Galatians = Galatas
Ephesians = Ephesios
Philippians = Philippenses
1 Thessalonians = I Thessalonicenses
2 Thessalonians = II Thessalonicenses
1 Timothy = I Timotheo
2 Timothy = II Timotheo
Philemon = Philemon
Hebrews = Hebreos
James = S. Thiago | Thiago
1 Peter = I S. Pedro
2 Peter = II S. Pedro
1 John = I S. João
2 John = II S. João
3 John = III S. João
Jude = S. Judas
Revelation = Apocalypse
""")

IT_NAMES = _table("""
Psalms = Salmo
Ecclesiastes = Qoèlet | Qoelet
Song of Solomon = Cantico
Nahum = Naum
Acts = Atti degli Apostoli
""")
IT_ABBR = _table("""
Genesis = Gn | Gen
Exodus = Es
Leviticus = Lv
Numbers = Nm
Deuteronomy = Dt
Joshua = Gs
Judges = Gdc
Ruth = Rt
1 Samuel = 1 Sam
2 Samuel = 2 Sam
1 Kings = 1 Re
2 Kings = 2 Re
1 Chronicles = 1 Cr
2 Chronicles = 2 Cr
Ezra = Esd
Nehemiah = Ne
Esther = Est
Job = Gb
Psalms = Sal
Proverbs = Pr
Ecclesiastes = Qo | Ec
Song of Solomon = Ct
Isaiah = Is
Jeremiah = Ger
Lamentations = Lam
Ezekiel = Ez
Daniel = Dn
Hosea = Os
Joel = Gl
Amos = Am
Obadiah = Abd
Jonah = Gio
Micah = Mi
Nahum = Na
Habakkuk = Ab
Zephaniah = Sof
Haggai = Ag
Zechariah = Zc
Malachi = Ml
Matthew = Mt
Mark = Mc
Luke = Lc
John = Gv
Acts = At
Romans = Rm
1 Corinthians = 1 Cor
2 Corinthians = 2 Cor
Galatians = Gal
Ephesians = Ef
Philippians = Fil
Colossians = Col
1 Thessalonians = 1 Ts
2 Thessalonians = 2 Ts
1 Timothy = 1 Tm
2 Timothy = 2 Tm
Titus = Tt
Philemon = Fm
Hebrews = Eb
James = Gc
1 Peter = 1 Pt
2 Peter = 2 Pt
1 John = 1 Gv
2 John = 2 Gv
3 John = 3 Gv
Jude = Gd
Revelation = Ap
""")

# Vulgate: the edition's own running titles, Nova Vulgata spellings, and the
# names the earlier builds used (kept so old lookups still resolve).
LA_NAMES = _table("""
1 Samuel = Regum I | I Samuelis | 1 Samuelis | Samuelis I
2 Samuel = Regum II | II Samuelis | 2 Samuelis | Samuelis II
1 Kings = Regum III | III Regum
2 Kings = Regum IV | IV Regum
1 Chronicles = Paralipomenon I | I Chronicorum | 1 Paralipomenon
2 Chronicles = Paralipomenon II | II Chronicorum | 2 Paralipomenon
Ezra = Esdras | I Esdræ
Nehemiah = II Esdræ | Nehemias
Psalms = Psalmus | Liber Psalmorum
Ecclesiastes = Qoheleth
Song of Solomon = Canticum
Wisdom = Liber Sapientiæ
Sirach = Siracides | Sirach
1 Maccabees = Machabæorum I | I Maccabæorum
2 Maccabees = Machabæorum II | II Maccabæorum
Matthew = Matthæum
Mark = Marcum
Luke = Lucam
John = Joannem
Acts = Actus
Romans = ad Romanos
1 Corinthians = ad Corinthios I
2 Corinthians = ad Corinthios II
Galatians = ad Galatas
Ephesians = ad Ephesios
Philippians = ad Philippenses
Colossians = ad Colossenses
1 Thessalonians = ad Thessalonicenses I
2 Thessalonians = ad Thessalonicenses II
1 Timothy = ad Timotheum I
2 Timothy = ad Timotheum II
Titus = ad Titum
Philemon = ad Philemonem
Hebrews = ad Hebræos
1 Peter = Petri I
2 Peter = Petri II
1 John = Joannis I
2 John = Joannis II
3 John = Joannis III
Revelation = Apocalypsis Joannis
""")
LA_LEGACY = _table("""
Joshua = Iosue
Judges = Iudicum
1 Samuel = I Samuelis
2 Samuel = II Samuelis
Ezra = Esdrae
Nehemiah = Nehemiae
Job = Iob
Jeremiah = Ieremias
Joel = Ioel
Jonah = Ionas
Micah = Michaeas
Haggai = Aggaeus
Matthew = Matthaeus
John = Ioannes
Hebrews = Hebraeos
James = Iacobi
1 John = I Ioannis
2 John = II Ioannis
3 John = III Ioannis
Jude = Iudae
""")
LA_ABBR = _table("""
Genesis = Gn | Gen
Exodus = Ex
Leviticus = Lv
Numbers = Nm
Deuteronomy = Dt
Joshua = Jos
Judges = Jdc
Ruth = Rt
1 Samuel = 1 Rg | 1 Reg
2 Samuel = 2 Rg | 2 Reg
1 Kings = 3 Rg | 3 Reg
2 Kings = 4 Rg | 4 Reg
1 Chronicles = 1 Par
2 Chronicles = 2 Par
Ezra = Esd
Nehemiah = Neh
Tobit = Tob
Judith = Jdt
Esther = Est
Job = Jb
Psalms = Ps
Proverbs = Prv | Prov
Ecclesiastes = Eccl | Qo
Song of Solomon = Ct | Cant
Wisdom = Sap
Sirach = Eccli | Sir
Isaiah = Is
Jeremiah = Jer
Lamentations = Lam
Baruch = Bar
Ezekiel = Ez
Daniel = Dn
Hosea = Os
Joel = Jl
Amos = Am
Obadiah = Abd
Jonah = Jon
Micah = Mich
Nahum = Nah
Habakkuk = Hab
Zephaniah = Soph
Haggai = Agg
Zechariah = Zach
Malachi = Mal
1 Maccabees = 1 Mach
2 Maccabees = 2 Mach
Matthew = Mt
Mark = Mc
Luke = Lc
John = Jo | Io
Acts = Act
Romans = Rom
1 Corinthians = 1 Cor
2 Corinthians = 2 Cor
Galatians = Gal
Ephesians = Eph
Philippians = Phil
Colossians = Col
1 Thessalonians = 1 Thess
2 Thessalonians = 2 Thess
1 Timothy = 1 Tim
2 Timothy = 2 Tim
Titus = Tit
Philemon = Philem
Hebrews = Hebr
James = Jac
1 Peter = 1 Petr
2 Peter = 2 Petr
1 John = 1 Jo
2 John = 2 Jo
3 John = 3 Jo
Jude = Jud
Revelation = Apoc
""")

# Modern Greek names of the NT books (monotonic) and standard abbreviations
EL_NAMES = _table("""
Matthew = Ματθαίος | Ευαγγέλιο κατά Ματθαίον
Mark = Μάρκος | Ευαγγέλιο κατά Μάρκον
Luke = Λουκάς | Ευαγγέλιο κατά Λουκάν
John = Ιωάννης | Ευαγγέλιο κατά Ιωάννην
Acts = Πράξεις | Πράξεις των Αποστόλων
Romans = Ρωμαίους | Προς Ρωμαίους
1 Corinthians = Α΄ Κορινθίους | Α' Κορινθίους | Α Κορινθίους
2 Corinthians = Β΄ Κορινθίους | Β' Κορινθίους | Β Κορινθίους
Galatians = Γαλάτες | Γαλάτας
Ephesians = Εφεσίους
Philippians = Φιλιππησίους
Colossians = Κολοσσαείς
1 Thessalonians = Α΄ Θεσσαλονικείς | Α' Θεσσαλονικείς | Α Θεσσαλονικείς
2 Thessalonians = Β΄ Θεσσαλονικείς | Β' Θεσσαλονικείς | Β Θεσσαλονικείς
1 Timothy = Α΄ Τιμόθεον | Α' Τιμόθεον | Α Τιμόθεον
2 Timothy = Β΄ Τιμόθεον | Β' Τιμόθεον | Β Τιμόθεον
Titus = Τίτον | Τίτος
Philemon = Φιλήμονα | Φιλήμων
Hebrews = Εβραίους
James = Ιακώβου | Ιάκωβος
1 Peter = Α΄ Πέτρου | Α' Πέτρου | Α Πέτρου
2 Peter = Β΄ Πέτρου | Β' Πέτρου | Β Πέτρου
1 John = Α΄ Ιωάννου | Α' Ιωάννου | Α Ιωάννου
2 John = Β΄ Ιωάννου | Β' Ιωάννου | Β Ιωάννου
3 John = Γ΄ Ιωάννου | Γ' Ιωάννου | Γ Ιωάννου
Jude = Ιούδα | Ιούδας
Revelation = Αποκάλυψη | Αποκάλυψις
""")
EL_ABBR = _table("""
Matthew = Μτ | Ματθ
Mark = Μκ | Μαρκ
Luke = Λκ | Λουκ
John = Ιω | Ιωαν
Acts = Πρξ | Πραξ
Romans = Ρωμ
1 Corinthians = Α΄ Κορ | Α' Κορ | Α Κορ | Κορ Α΄
2 Corinthians = Β΄ Κορ | Β' Κορ | Β Κορ | Κορ Β΄
Galatians = Γαλ
Ephesians = Εφ
Philippians = Φιλ
Colossians = Κολ
1 Thessalonians = Α΄ Θεσ | Α' Θεσ | Α Θεσ
2 Thessalonians = Β΄ Θεσ | Β' Θεσ | Β Θεσ
1 Timothy = Α΄ Τιμ | Α' Τιμ | Α Τιμ
2 Timothy = Β΄ Τιμ | Β' Τιμ | Β Τιμ
Titus = Τιτ
Philemon = Φλμ | Φιλημ
Hebrews = Εβρ
James = Ιακ
1 Peter = Α΄ Πετ | Α' Πετ | Α Πετ
2 Peter = Β΄ Πετ | Β' Πετ | Β Πετ
1 John = Α΄ Ιω | Α' Ιω | Α Ιω
2 John = Β΄ Ιω | Β' Ιω | Β Ιω
3 John = Γ΄ Ιω | Γ' Ιω | Γ Ιω
Jude = Ιουδ
Revelation = Απ | Αποκ
""")


# ── Alias generation ─────────────────────────────────────────

def _forms(name: str, style: str) -> list[str]:
    """Spelling variants of one book name that users type (no marks, …)."""
    out = []
    if style in ('latin', 'de'):
        out.append(fold_latin(name))
        if style == 'de':
            out.append(german_umlaut(name))
    elif style == 'el':
        mono = greek_monotonic(name)
        out += [mono, mono.replace('΄', "'"), name.replace('ʹ', "'"), greek_plain(name)]
    elif style == 'ar':
        out.append(name.translate(_HAMZA))
    for n in list(out) + [name]:
        out += numbered_variants(n, style)
    return [o for o in dict.fromkeys(out) if o != name]


def _chapter_patterns(style: str, psalm: bool):
    if style == 'zh':
        pats = ['{n} {c}', '{n}{c}', '{n}{c}章', '{n}第{c}章']
        return pats + (['{n}{c}篇', '{n}第{c}篇', '{n} {c}篇'] if psalm else [])
    if style == 'ja':
        pats = ['{n} {c}', '{n}{c}', '{n}{c}章', '{n} {c}章', '{n}第{c}章']
        return pats + (['{n}{c}篇', '{n}第{c}篇', '{n}{c}編', '{n}第{c}編'] if psalm else [])
    if style == 'ko':
        pats = ['{n} {c}', '{n}{c}', '{n} {c}장', '{n}{c}장']
        return pats + (['{n} {c}편', '{n}{c}편'] if psalm else [])
    if style == 'ar':
        return ['{n} {c}', '{n} {ac}']
    return ['{n} {c}']


def _chapter_aliases(name: str, c: int, style: str, psalm: bool) -> list[str]:
    return [p.format(n=name, c=c, ac=arabic_digits(c)) for p in _chapter_patterns(style, psalm)]


class Book:
    """Per-book naming for one Bible: display name, main-key name, aliases."""

    def __init__(self, cfg: dict, book: str):
        self.book = book
        self.local = cfg['local'].get(book, book)
        self.lxx = cfg.get('psalms') == 'lxx' and book == 'Psalms'
        # Main keys use the English name, except LXX-numbered psalms, which are
        # keyed by their own number under the local name ("Psalmi 22").
        self.key_name = self.local if self.lxx else book

    def key(self, c: int) -> str:
        return f'{self.key_name} {c}'

    def title(self, c: int) -> str:
        return f'{self.local} {c}'


def make_keys(cfg: dict, bible: Bible, books: dict[str, Book]) -> KeySet:
    ks = KeySet(cfg['name'])
    style = cfg['style']
    cand: list[tuple[int, str, str, bool]] = []      # (rank, alias, target, multi)

    def add(rank, alias, target, multi=False):
        cand.append((rank, alias, target, multi))

    for b, B in books.items():
        chs = sorted(bible.books[b])
        psalm = b == 'Psalms'
        local_names = [(R_NAME, n) for n in cfg.get('names', {}).get(b, [])]
        local_names += [(R_LEGACY, n) for n in cfg.get('legacy', {}).get(b, [])]
        abbrs = cfg.get('abbr', {}).get(b, []) + cfg.get('short', {}).get(b, [])
        for c in chs:
            ks.add_main(B.key(c))
        # Local names and their variants: same numbering as the main keys
        groups = [(R_LOCAL, B.local)] + local_names
        for rank, name in groups:
            for c in chs:
                for a in _chapter_aliases(name, c, style, psalm):
                    add(rank, a, B.key(c))
                for f in _forms(name, style):
                    for a in _chapter_aliases(f, c, style, psalm):
                        add(R_FOLD, a, B.key(c))
        for name in abbrs:
            for rank, f in [(R_ABBR, name)] + [(R_FOLD, f) for f in _forms(name, style)]:
                for c in chs:
                    for a in _chapter_aliases(f, c, style, psalm):
                        add(rank, a, B.key(c))
        # English names (Hebrew psalm numbering everywhere)
        en_names = [(R_EN, n) for n in EN_NAMES.get(b, [])]
        en_names += [(R_EN, v) for v in numbered_variants(b)]
        m = re.match(r'^([123]) (.+)$', b)
        if m:
            en_names.append((R_EN, f'{_ORDINAL_EN[m.group(1)]} {m.group(2)}'))
        en_names += [(R_EN_ABBR, n) for a in EN_ABBR.get(b, []) for n in [a] + numbered_variants(a)]
        if B.lxx:
            en_names.insert(0, (R_NAME, b))
        for rank, name in en_names:
            if B.lxx:
                for h in range(1, 151):
                    for n in hebrew_to_lxx(h):
                        add(rank, f'{name} {h}', B.key(n), multi=True)
            else:
                for c in chs:
                    add(rank, f'{name} {c}', B.key(c))
        for alias, target in cfg.get('extra_aliases', {}).get(b, ()):
            add(R_NAME, alias, target)
        # Synodal: "Псалом 22" / "Пс 22" use the Synodal (Greek) numbering
        if psalm and cfg.get('psalms') == 'synodal':
            for name in ('Псалом', 'Пс', 'Пс.'):
                for n in range(1, 151):
                    for h in lxx_to_hebrew(n):
                        add(R_NAME, f'{name} {n}', B.key(h), multi=True)
            # "Пс 22:1": the source marks each verse whose Synodal number
            # differs, e.g. Psalms 23:1 "(22:1) Псалом Давида…"
            for c in chs:
                for n, verse in bible.books[b][c].items():
                    m = re.match(r'\((\d+):(\d+)\)', verse.text.plain())
                    sn, sv = (int(m.group(1)), int(m.group(2))) if m else (c, n)
                    for name in ('Пс', 'Псалом'):
                        add(R_VERSE, f'{name} {sn}:{sv}', B.key(c))
        # Verse references → the chapter
        for c in chs:
            vs = sorted({x for n, v in bible.books[b][c].items() for x in [n] + v.covers})
            for v in vs:
                for a in verse_refs(cfg, B, c, v):
                    add(R_VERSE, a, B.key(c))
                for a in verse_refs_folded(cfg, B, c, v):
                    add(R_VERSE_FOLD, a, B.key(c))
        if B.lxx:
            for h in range(1, 151):
                for v in range(1, KJV_VERSES['Psalms'][h - 1] + 1):
                    for n in hebrew_to_lxx(h):
                        add(R_VERSE, f'Psalms {h}:{v}', B.key(n), multi=True)
    for rank, alias, target, multi in sorted(cand, key=lambda t: t[0]):
        ks.add(alias, target, rank, multi)
    return ks


def verse_refs(cfg: dict, B: Book, c: int, v: int) -> list[str]:
    """Verse-reference keys ("John 3:16") for one verse: the English name, the
    local name and the forms native readers write."""
    style = cfg['style']
    out = []
    if not B.lxx:
        out.append(f'{B.book} {c}:{v}')
        if B.book == 'Psalms':
            out.append(f'Psalm {c}:{v}')
    if B.local != B.book or B.lxx:
        out.append(f'{B.local} {c}:{v}')
    abbr = (cfg.get('abbr', {}).get(B.book) or [None])[0]
    if style in ('zh', 'ja', 'ko'):
        out.append(f'{B.local}{c}:{v}')
    sep = cfg.get('verse_abbr')         # "Joh 3,16", "Jn 3:16", "1Cor 13:4"
    if sep and abbr:
        for a in _numbered_twins(abbr):
            out.append(f'{a} {c}{sep}{v}')
    short = (cfg.get('short', {}).get(B.book) or [None])[0]
    if short:                           # "ヨハネ3:16", "マタイ 5:3"
        out += [f'{short}{c}:{v}', f'{short} {c}:{v}']
    if style == 'zh' and abbr:
        out.append(f'{abbr}{c}:{v}')
    if style == 'ko' and abbr:
        out.append(f'{abbr} {c}:{v}')
    for a in cfg.get('en_verse_abbr', {}).get(B.book, ()):
        out += [f'{t} {c}:{v}' for t in _numbered_twins(a)]     # "1 Cor 13:4", "1Cor 13:4"
    if style == 'ar':
        out.append(f'{B.local} {arabic_digits(c)}:{arabic_digits(v)}')
    if style == 'ru' and abbr and not (B.book == 'Psalms' and cfg.get('psalms') == 'synodal'):
        out.append(f'{abbr} {c}:{v}')     # "Пс N" uses the Synodal numbering
    if style == 'de':
        out.append(f'{B.local} {c},{v}')
    if style == 'el':
        modern = (cfg.get('names', {}).get(B.book) or [None])[0]
        if modern:
            out.append(f'{modern} {c}:{v}')
        if abbr:                        # "Ιω 3:16", "Α' Κορ 13:4"
            for a in dict.fromkeys([abbr] + _forms(abbr, 'el')):
                out.append(f'{a} {c}:{v}')
    return out


def verse_refs_folded(cfg: dict, B: Book, c: int, v: int) -> list[str]:
    """Accent-free twins of the abbreviated verse references ("Ex 20:3" for
    "Éx 20:3"); weaker than every exact form, so "Jo 3:16" stays John even
    where Job's "Jó" folds to "Jo"."""
    sep = cfg.get('verse_abbr')
    abbr = (cfg.get('abbr', {}).get(B.book) or [None])[0]
    if not (sep and abbr) or fold_latin(abbr) == abbr:
        return []
    return [f'{a} {c}{sep}{v}' for a in _numbered_twins(fold_latin(abbr))]


def _numbered_twins(abbr: str) -> list[str]:
    """'1 Cor' → ['1 Cor', '1Cor']; '1Kor' → ['1Kor', '1 Kor']."""
    m = re.match(r'^([1-4])(\.?) ?(\D.*)$', abbr)
    if not m:
        return [abbr]
    n, dot, rest = m.groups()
    return list(dict.fromkeys([abbr, f'{n}{dot}{rest}', f'{n}{dot} {rest}']))


# ═════════════════════════════════════════════════════════════
# HTML
# ═════════════════════════════════════════════════════════════

_CSS_LIGHT = (
    f'.sub{{font-size:1.15em;color:{TEXT_SECONDARY[0]};display:block;margin-top:2px}}'
    f'.sub2{{font-size:1.15em;color:{TEXT_LINK[0]};font-style:italic;display:block;margin-top:1px}}'
    '.sub2 [lang=he]{font-style:normal}'
    '.gl{font-size:1.05em}'
    '.sp{letter-spacing:.12em}'
    f'.pt{{font-style:italic;color:{TEXT_SECONDARY[0]};margin:10px 2px 2px}}'
    f'.nt{{font-size:0.85em;color:{TEXT_SECONDARY[0]}}}'
    '.nav{display:flex;justify-content:space-between;margin-top:12px;padding-top:8px;'
    'border-top:1px solid #e5e5ea;font-size:0.9em;color:#636366}'
    f'.nav a{{color:{TEXT_LINK[0]};text-decoration:none}}'
)
_CSS_DARK = (
    f'.sub{{color:{TEXT_SECONDARY[1]}}}'
    f'.sub2{{color:{TEXT_LINK[1]}}}'
    f'.pt,.nt{{color:{TEXT_SECONDARY[1]}}}'
    '.nav{border-color:#38383a;color:#98989d}'
    f'.nav a{{color:{TEXT_LINK[1]}}}'
)
CSS = get_css(SENSE_NUMBER_INLINE, extra_light=_CSS_LIGHT, extra_dark=_CSS_DARK)

# Extra rules a Bible config can ask for ('css': [name, …])
CSS_EXTRA = {
    # 1919 Union Version: supplied words (dots beside the characters, here
    # beneath them), large type, cross-reference marks and the reference list
    'cuv1919': (
        '.ud{text-decoration:underline dotted;text-underline-offset:.25em}'
        '.lg{font-size:1.2em}'
        f'.xr{{font-size:.7em;color:{TEXT_LINK[0]}}}'
        f'.xrl{{margin-top:10px;padding-top:6px;border-top:1px dashed #d1d1d6;font-size:.9em;color:{TEXT_SECONDARY[0]}}}'
        f'.xrl a{{color:{TEXT_LINK[0]};text-decoration:none}}',
        f'.xr,.xrl a{{color:{TEXT_LINK[1]}}}'
        f'.xrl{{border-color:#48484a;color:{TEXT_SECONDARY[1]}}}',
    ),
    # 文語訳: furigana
    'ruby': ('rt{font-size:.55em}', ''),
}
_CSS_BY_CFG: dict[str, str] = {}


def bible_css(cfg: dict) -> str:
    names = tuple(cfg.get('css', ()))
    if not names:
        return CSS
    if names not in _CSS_BY_CFG:
        _CSS_BY_CFG[names] = get_css(SENSE_NUMBER_INLINE,
                                     extra_light=_CSS_LIGHT + ''.join(CSS_EXTRA[n][0] for n in names),
                                     extra_dark=_CSS_DARK + ''.join(CSS_EXTRA[n][1] for n in names))
    return _CSS_BY_CFG[names]


def _subtitle(cfg: dict, B: Book, c: int) -> str:
    rtl = cfg.get('rtl', False)
    if cfg['script'] == 'latin':
        if B.lxx:
            heb = lxx_to_hebrew(c)
            name, lang = HEBREW_BOOK_NAMES['Psalms'], 'he'
            num = f'{heb[0]}–{heb[-1]}' if len(heb) > 1 else str(heb[0])
            text = f'{name} {num}'
        else:
            name, lang = original_name(B.book, c)
            if not name:
                return ''
            text = f'{name} {c}'
        inner = (f'<span{dir_attr("rtl", "he")}>{esc(text)}</span>' if lang == 'he'
                 else f'<span lang="{lang}">{esc(text)}</span>')
        return f'<span class="sub2">{inner}</span>'
    text = f'{B.book} {c}'
    if B.book == 'Psalms' and cfg.get('psalms') == 'synodal':
        text += f' · Псалом {"/".join(map(str, hebrew_to_lxx(c)))} (синод.)'
    if rtl:   # LTR island, aligned with the right-aligned headword
        return f'<span class="sub"><span{dir_attr("ltr", "en")}>{esc(text)}</span></span>'
    return f'<span class="sub" lang="en">{esc(text)}</span>'


def chapter_html(cfg: dict, B: Book, c: int, verses: dict, prev, nxt, notes=None) -> str:
    rtl = cfg.get('rtl', False)
    note = cfg.get('note_brackets', ('[', ']'))
    parts = []
    if cfg.get('dir_label'):
        parts.append(f'<span class="dir">{cfg["dir_label"]}</span>')
    parts.append(f'<span class="hw">{esc(B.title(c))}</span>')
    parts.append(_subtitle(cfg, B, c))
    for n in sorted(verses):
        v = verses[n]
        if v.title is not None and not v.title.empty():
            parts.append(f'<div class="pt">{v.title.html(note)}</div>')
        parts.append(f'<div class="sn"><span class="sn-n">{esc(v.label or str(n))}</span> '
                     f'<span class="gl">{v.text.html(note)}</span></div>')
    if notes:
        rows = []
        for mark, content in notes:
            body = ''.join(f'<a href="entry://{esc_attr(key)}">{esc(t)}</a>' if key else esc(t)
                           for t, key in content)
            rows.append(f'<div><sup>{esc(mark)}</sup> {body}</div>')
        parts.append(f'<div class="xrl">{"".join(rows)}</div>')
    if prev or nxt:
        back, fwd = ('▶', '◀') if rtl else ('◀', '▶')
        a = (f'<a href="entry://{esc_attr(prev[0])}">{back} {esc(prev[1])}</a>' if prev else '<span></span>')
        b = (f'<a href="entry://{esc_attr(nxt[0])}">{esc(nxt[1])} {fwd}</a>' if nxt else '<span></span>')
        parts.append(f'<div class="nav">{a}{b}</div>')
    return wrap_entry(''.join(parts), bible_css(cfg), rtl=rtl, lang=cfg['lang'])


def build_entries(cfg: dict, bible: Bible) -> tuple[list, KeySet, dict]:
    books = {b: Book(cfg, b) for b in book_order(cfg)}
    seq = [(b, c) for b in books for c in sorted(bible.books[b])]
    entries, html_by_key = [], {}
    for i, (b, c) in enumerate(seq):
        prev = seq[i - 1] if i else None
        nxt = seq[i + 1] if i + 1 < len(seq) else None
        p = (books[prev[0]].key(prev[1]), books[prev[0]].title(prev[1])) if prev else None
        n = (books[nxt[0]].key(nxt[1]), books[nxt[0]].title(nxt[1])) if nxt else None
        html = chapter_html(cfg, books[b], c, bible.books[b][c], p, n, bible.chapter_notes.get((b, c)))
        key = books[b].key(c)
        entries.append((key, html))
        html_by_key[key] = html
    main_keys = set(html_by_key)
    for (b, c), notes in bible.chapter_notes.items():
        bad = [key for _, content in notes for _, key in content if key and key not in main_keys]
        if bad:
            raise BuildError(f'{b} {c}: references link to missing chapters {bad}')
    ks = make_keys(cfg, bible, books)
    return entries + ks.out, ks, html_by_key


# ═════════════════════════════════════════════════════════════
# Bible configurations
# ═════════════════════════════════════════════════════════════

OPEN_BIBLES = '<a href="https://github.com/seven1m/open-bibles">Open Bibles</a>'
GRATIS = '<a href="https://github.com/gratis-bible/bible">gratis-bible</a>'
KJV_APOCRYPHA = frozenset({'Tob', 'Jdt', 'EsthGr', 'AddEsth', 'Wis', 'Sir', 'Bar', 'EpJer', 'PrAzar',
                           'Sus', 'Bel', '1Macc', '2Macc', '1Esd', '2Esd', 'PrMan'})

BIBLES = [
    {
        'name': 'Bible-KJV-EN',
        'src': DATA_DIR / 'kjv.osis.xml', 'format': 'osis',
        'lang': 'en', 'style': 'latin', 'script': 'latin', 'local': {},
        'omit_codes': KJV_APOCRYPHA,
        # "Rom 8:28", "Mt 6:9": the usual English abbreviation at verse level
        'en_verse_abbr': {b: EN_ABBR[b][:1] + (['Mt'] if b == 'Matthew' else []) for b in BOOK_ORDER},
        'dir_label': '✝️ → \U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8',  # ✝️ → 🇬🇧🇺🇸
        'title': 'King James Version (KJV)',
        'desc': ('The Holy Bible, King James Version (Authorized Version, 1611) in the standardized '
                 'text of 1769: the 66 books of the Old and New Testaments, one entry per chapter '
                 '(the Apocrypha is not included); look up “John 3” or “John 3:16”. Words supplied by '
                 'the translators are in italics. Source: <a href="https://ebible.org/details.php?id=eng-kjv">'
                 'eBible.org eng-kjv</a> via ' + OPEN_BIBLES + '. Public domain; in the United Kingdom the '
                 'King James Version is under perpetual Crown copyright (letters patent). Converted by OpenMDict.'),
        'catalog_display_name': 'Bible — King James Version',
        'catalog_description': ('The King James Version of the Holy Bible (1769 standard text): 66 books, '
                                'one entry per chapter, verse references such as “John 3:16”. Public domain '
                                '(Crown copyright in the UK).'),
        'direction': {'src': 'EN', 'dest': ['EN']},
        'data_source': 'Open Bibles (eBible.org eng-kjv, OSIS XML)',
    },
    {
        'name': 'Bible-CUV-ZH-Hans',
        'src': DATA_DIR / 'zhwikisource-cuv1919', 'format': 'wikisource',
        'lang': 'zh-Hans', 'style': 'zh', 'script': 'cjk', 'local': ZH_HANS_BOOK_NAMES,
        'names': {b: ZH_HANS_NAMES.get(b, []) + [ZH_HANT_BOOK_NAMES[b]] for b in BOOK_ORDER},
        'abbr': ZH_HANS_ABBR, 'fixups': ['cuv1919', 't2s'],
        'css': ['cuv1919'], 'note_brackets': ('〈', '〉'),
        'dir_label': '✝️ → \U0001F1E8\U0001F1F3',  # ✝️ → 🇨🇳
        'title': '官话和合译本圣经（1919，简体）',
        'desc': ('圣经·官话和合译本（1919 年初版，“神”版），简体中文。66 卷，每章一个词条，可查“约翰福音 3”'
                 '“约3:16”。标点为当时的旧式标点（『』、．）。字旁加点的补充字（原文所无、译者加上的字）以点线标示，'
                 '小字注释置于〈〉内，诗篇标题置于第 1 节前，新约所引旧约的出处列于各章之末。底本为'
                 '<a href="https://zh.wikisource.org/wiki/聖經_(和合本)">维基文库《圣经 (和合本)》</a>'
                 '（繁体，依 1919 年版用字；各卷固定于一个修订版本），简体字由 OpenCC 1.4.2 转换。'
                 '维基文库标注为公有领域。由 OpenMDict 转换。'),
        'catalog_display_name': '官话和合译本圣经（简体）',
        'catalog_description': ('圣经官话和合译本（1919，“神”版），简体中文（由繁体转换），66 卷，'
                                '按章收录，可查“约3:16”。公有领域（据维基文库）。'),
        'direction': {'src': 'ZH', 'dest': ['ZH']},
        'data_source': 'Chinese Wikisource (聖經 (和合本), 66 pinned revisions; OpenCC 1.4.2 t2s)',
    },
    {
        'name': 'Bible-CUV-ZH-Hant',
        'src': DATA_DIR / 'zhwikisource-cuv1919', 'format': 'wikisource',
        'lang': 'zh-Hant', 'style': 'zh', 'script': 'cjk', 'local': ZH_HANT_BOOK_NAMES,
        'names': {b: ZH_HANT_NAMES.get(b, []) + [ZH_HANS_BOOK_NAMES[b]] for b in BOOK_ORDER},
        'abbr': ZH_HANT_ABBR, 'fixups': ['cuv1919'],
        'css': ['cuv1919'], 'note_brackets': ('〈', '〉'),
        'dir_label': '✝️ → \U0001F1F9\U0001F1FC\U0001F1ED\U0001F1F0',  # ✝️ → 🇹🇼🇭🇰
        'title': '官話和合譯本聖經（1919，繁體）',
        'desc': ('聖經·官話和合譯本（1919 年初版，「神」版），繁體中文。66 卷，每章一個詞條，可查「約翰福音 3」'
                 '「約3:16」。用字與標點依維基文庫本，該本依 1919 年版用字（他、喫、纔，『』、．）。'
                 '字旁加點的補充字（原文所無、譯者加上的字）以點線標示，小字註釋置於〈〉內，詩篇標題置於第 1 節前，'
                 '新約所引舊約的出處列於各章之末。來源：'
                 '<a href="https://zh.wikisource.org/wiki/聖經_(和合本)">維基文庫《聖經 (和合本)》</a>'
                 '（各卷固定於一個修訂版本）。維基文庫標示為公有領域。由 OpenMDict 轉換。'),
        'catalog_display_name': '官話和合譯本聖經（繁體）',
        'catalog_description': ('聖經官話和合譯本（1919，「神」版），繁體中文，66 卷，按章收錄，'
                                '可查「約3:16」。公有領域（據維基文庫）。'),
        'direction': {'src': 'ZH', 'dest': ['ZH']},
        'data_source': 'Chinese Wikisource (聖經 (和合本), 66 pinned revisions)',
    },
    {
        'name': 'Bible-Kougo-JA',
        'src': DATA_DIR / 'crosswire' / 'JapBungo-2.0.zip', 'format': 'sword',
        'lang': 'ja', 'style': 'ja', 'script': 'cjk', 'local': JA_BOOK_NAMES,
        'names': {b: JA_NAMES.get(b, []) + JA_BUNGO_NAMES.get(b, []) for b in BOOK_ORDER},
        'abbr': JA_ABBR, 'short': JA_SHORT, 'fixups': ['bungo'],
        'ruby': True, 'css': ['ruby'],
        'dir_label': '✝️ → \U0001F1EF\U0001F1F5',  # ✝️ → 🇯🇵
        'title': '文語訳聖書',
        'desc': ('文語訳聖書。旧約は明治元訳（初版 1887 年、底本は 1953 年版）、新約は大正改訳（初版 1917 年、'
                 '底本は 1950 年版）。66 巻、各章 1 項目。「ヨハネによる福音書 3」「ヨハネ傳福音書 3」「ヨハネ 3」'
                 '「ヨハネ3:16」などで引けます。振り仮名はルビで表示します。新約の「[なし]」は本文のない節、'
                 '「24–25」は 2 節を 1 つにまとめた箇所です。出典：'
                 '<a href="https://crosswire.org/sword/modules/ModInfo.jsp?modName=JapBungo">CrossWire SWORD '
                 'JapBungo 2.0</a>（本文は bible.salterrae.net）。CrossWire の表示は Public Domain。'
                 'OpenMDict が変換。'),
        'catalog_display_name': '文語訳聖書',
        'catalog_description': ('文語訳聖書（明治元訳 旧約 1887 年・大正改訳 新約 1917 年）。66 巻、章ごとの項目、'
                                'ルビ付き、「ヨハネ 3」「ヨハネ3:16」形式の検索に対応。パブリックドメイン'
                                '（CrossWire の表示）。'),
        'direction': {'src': 'JA', 'dest': ['JA']},
        'data_source': 'CrossWire SWORD JapBungo 2.0 (bible.salterrae.net)',
    },
    {
        'name': 'Bible-RV1909-ES',
        'src': DATA_DIR / 'spa-rv1909.usfx.xml', 'format': 'usfx',
        'lang': 'es', 'style': 'latin', 'script': 'latin', 'local': ES_BOOK_NAMES,
        'names': ES_NAMES, 'abbr': ES_ABBR, 'verse_abbr': ':',
        # Verse slots the source leaves empty: their text is numbered as part of
        # the next chapter (Hebrew versification), e.g. Jonah 1:17 → 2:1.
        'allow_empty': {('Numbers', 12, 16), ('Numbers', 29, 40), ('1 Samuel', 23, 29),
                        ('2 Samuel', 20, 26), ('2 Chronicles', 33, 25), ('Job', 35, 16),
                        ('Job', 38, 39), ('Job', 38, 40), ('Job', 38, 41), ('Job', 40, 20),
                        ('Job', 40, 21), ('Job', 40, 22), ('Job', 40, 23), ('Job', 40, 24),
                        ('Hosea', 11, 12), ('Jonah', 1, 17), ('Acts', 19, 41),
                        ('2 Corinthians', 13, 14)},
        'dir_label': '✝️ → \U0001F1EA\U0001F1F8',  # ✝️ → 🇪🇸
        'title': 'Santa Biblia — Reina-Valera 1909',
        'desc': ('La Santa Biblia, versión Reina-Valera revisada en 1909: 66 libros, una entrada por '
                 'capítulo; busque «Juan 3», «Juan 3:16» o «Jn 3:16». Las palabras en cursiva son añadidas por los '
                 'traductores. Fuente: <a href="https://ebible.org/details.php?id=spaRV1909">eBible.org '
                 'spaRV1909</a> vía ' + OPEN_BIBLES + '. Dominio público. Convertido por OpenMDict.'),
        'catalog_display_name': 'Santa Biblia — Reina-Valera 1909',
        'catalog_description': ('La Santa Biblia, versión Reina-Valera (1909). 66 libros, una entrada por '
                                'capítulo, búsqueda por «Juan 3:16». Dominio público.'),
        'direction': {'src': 'ES', 'dest': ['ES']},
        'data_source': 'Open Bibles (eBible.org spaRV1909, USFX XML)',
    },
    {
        'name': 'Bible-Darby-FR',
        'src': DATA_DIR / 'fra-darby.osis.xml', 'format': 'osis',
        'lang': 'fr', 'style': 'latin', 'script': 'latin', 'local': FR_BOOK_NAMES,
        'names': FR_NAMES, 'abbr': FR_ABBR, 'verse_abbr': ':', 'fixups': ['darby'],
        'dir_label': '✝️ → \U0001F1EB\U0001F1F7',  # ✝️ → 🇫🇷
        'title': 'Bible Darby (français)',
        'desc': ('La Sainte Bible, traduction de J. N. Darby (Nouveau Testament 1859, Bible complète '
                 '1885) : 66 livres, une entrée par chapitre ; cherchez « Jean 3 », « Jean 3:16 » ou « Jn 3:16 ». '
                 'Les astérisques (*Dieu, *Seigneur) sont ceux du texte de Darby ; les références entre '
                 'parenthèses, p. ex. (5:20), donnent la numérotation hébraïque. Source : ' + GRATIS +
                 ' (fr/frdarb.xml, d’après The Unbound Bible). Domaine public. Converti par OpenMDict.'),
        'catalog_display_name': 'Bible Darby (français)',
        'catalog_description': ('La Bible, traduction J. N. Darby (1859/1885). 66 livres, une entrée par '
                                'chapitre, recherche « Jean 3:16 ». Domaine public.'),
        'direction': {'src': 'FR', 'dest': ['FR']},
        'data_source': 'gratis-bible (frdarb, OSIS XML)',
    },
    {
        'name': 'Bible-Luther1912-DE',
        'src': DATA_DIR / 'deu-luther1912.osis.xml', 'format': 'osis',
        'lang': 'de', 'style': 'de', 'script': 'latin', 'local': DE_BOOK_NAMES,
        'names': DE_NAMES, 'abbr': DE_ABBR, 'verse_abbr': ',', 'notes': 'inline',
        # KJV Malachi 4 is Malachi 3:19–24 in the Hebrew chapter division
        'extra_aliases': {'Malachi': [('Malachi 4', 'Malachi 3'), ('Maleachi 4', 'Malachi 3'),
                                      ('Mal 4', 'Malachi 3')]},
        'chapters': {'Joel': 4, 'Malachi': 3},
        # Hebrew chapter division (Num 17 = KJV 16:36–17:13, 1 Kgs 5 = KJV 4:21–5:18, Joel 3–4)
        'shape_skip': {('Numbers', 17), ('1 Kings', 5), ('Joel', 2), ('Joel', 3), ('Malachi', 3)},
        'dir_label': '✝️ → \U0001F1E9\U0001F1EA',  # ✝️ → 🇩🇪
        'title': 'Lutherbibel 1912',
        'desc': ('Die Bibel nach der Übersetzung Martin Luthers, revidierter Text von 1912: 66 Bücher, '
                 'ein Eintrag pro Kapitel; suchen Sie „Johannes 3“, „Joh 3“, „Johannes 3,16“ oder „Joh 3,16“. '
                 'Kapitelzählung nach der hebräischen Bibel (Joel 4, Maleachi 3). Worterklärungen der '
                 'Vorlage stehen in eckigen Klammern. Quelle: ' + OPEN_BIBLES + ' (deu-luther1912.osis.xml, '
                 'Free Bible Software Group). Gemeinfrei. Konvertiert von OpenMDict.'),
        'catalog_display_name': 'Lutherbibel 1912',
        'catalog_description': ('Die Bibel, Lutherübersetzung (1912). 66 Bücher, ein Eintrag pro Kapitel, '
                                'Suche nach „Joh 3“ oder „Joh 3,16“. Gemeinfrei.'),
        'direction': {'src': 'DE', 'dest': ['DE']},
        'data_source': 'Open Bibles (deu-luther1912, OSIS XML)',
    },
    {
        'name': 'Bible-Almeida-PT',
        'src': DATA_DIR / 'biblia-arc1911-eda2823', 'format': 'edition-canon',
        'lang': 'pt', 'style': 'latin', 'script': 'latin', 'local': PT_BOOK_NAMES,
        'names': {b: PT_NAMES.get(b, []) + PT_ARC1911_NAMES.get(b, []) for b in BOOK_ORDER},
        'abbr': PT_ABBR, 'verse_abbr': ':', 'fixups': ['almeida1911'],
        'dir_label': '✝️ → \U0001F1F5\U0001F1F9\U0001F1E7\U0001F1F7',  # ✝️ → 🇵🇹🇧🇷
        'title': 'Bíblia Sagrada — Almeida Revista e Corrigida (1911)',
        'desc': ('A Biblia Sagrada, tradução de João Ferreira d’Almeida, edição revista e corrigida '
                 '(Lisboa, Deposito das Escripturas Sagradas, 1911; reimpressão da edição de 1900), na grafia '
                 'da edição: 66 livros, uma entrada por capítulo; pesquise «João 3», «S. João 3», «João 3:16» '
                 'ou «Jo 3:16». As palavras em itálico são as que a edição marca como acrescentadas; os títulos '
                 'dos salmos e as letras do acróstico vêm antes do versículo. As referências, as leituras '
                 'alternativas da margem, os títulos de secção e as datas não estão incluídos. Fonte: '
                 '<a href="https://www.gutenberg.org/ebooks/62383">Project Gutenberg #62383</a>, na '
                 'estruturação de <a href="https://github.com/mazza/biblia-arc1911">mazza/biblia-arc1911</a> '
                 '(commit eda2823, CC0 1.0), que acerta a numeração de seis passagens da transcrição '
                 '(Juízes 5, 1 Samuel 20, 1 Reis 22, Marcos 4, 2 Coríntios 13, Apocalipse 12:18). '
                 'Domínio público nos EUA, segundo o Project Gutenberg. Convertido por OpenMDict.'),
        'catalog_display_name': 'Bíblia Sagrada — Almeida 1911',
        'catalog_description': ('Bíblia Sagrada, tradução de João Ferreira de Almeida, Revista e Corrigida '
                                '(Lisboa, 1911), na grafia da edição. 66 livros, uma entrada por capítulo, '
                                'pesquisa por «João 3:16». Domínio público nos EUA (Project Gutenberg).'),
        'direction': {'src': 'PT', 'dest': ['PT']},
        'data_source': 'Project Gutenberg #62383 via mazza/biblia-arc1911 @eda2823 (Markdown)',
    },
    {
        'name': 'Bible-Synodal-RU',
        'src': DATA_DIR / 'rus-synodal.zefania.xml', 'format': 'zefania',
        'lang': 'ru', 'style': 'ru', 'script': 'cyrillic', 'local': RU_BOOK_NAMES,
        'names': RU_NAMES, 'abbr': RU_ABBR, 'psalms': 'synodal',
        'chapters': {'Daniel': 14, 'Joel': 4, 'Malachi': 4},
        # Hebrew chapter division; Daniel 3 includes the Prayer of Azariah (3:24–90)
        'shape_skip': {('Numbers', 17), ('1 Kings', 5), ('Daniel', 3), ('Joel', 3)},
        'dir_label': '✝️ → \U0001F1F7\U0001F1FA',  # ✝️ → 🇷🇺
        'title': 'Синодальный перевод',
        'desc': ('Библия, Синодальный перевод (1876; текст издания 1956 г.): 66 книг, по одной статье на '
                 'главу; ищите «Иоанн 3», «От Иоанна 3», «Ин 3:16». Главы Псалтири пронумерованы по '
                 'еврейскому тексту, синодальный номер стиха стоит в скобках, например (22:1); '
                 '«Псалом 22» и «Пс 22» открывают псалом по синодальной нумерации. Источник: ' + OPEN_BIBLES +
                 ' (rus-synodal.zefania.xml; текст предоставлен «Light in East Germany»). Общественное '
                 'достояние. Преобразовано OpenMDict.'),
        'catalog_display_name': 'Синодальный перевод',
        'catalog_description': ('Библия, Синодальный перевод (1876). 66 книг, по одной статье на главу, '
                                'поиск «Ин 3:16» и «Псалом 22». Общественное достояние.'),
        'direction': {'src': 'RU', 'dest': ['RU']},
        'data_source': 'Open Bibles (rus-synodal, Zefania XML)',
    },
    {
        'name': 'Bible-Korean-KO',
        'src': DATA_DIR / 'crosswire' / 'KorRV-2.0.1.zip', 'format': 'sword',
        'lang': 'ko', 'style': 'ko', 'script': 'hangul', 'local': KO_BOOK_NAMES,
        'legacy': KO_NAMES, 'abbr': KO_ABBR, 'fixups': ['korrv'],
        'dir_label': '✝️ → \U0001F1F0\U0001F1F7',  # ✝️ → 🇰🇷
        'title': '성경 (개역한글)',
        'desc': ('성경전서 개역한글판(대한성서공회, 1961): 66권, 장마다 한 항목. “요한복음 3”, “요 3장”, '
                 '“요한복음 3:16”으로 찾을 수 있습니다. 개역한글판에 없는 절은 “(없음)”으로 표시합니다. 출처: '
                 '<a href="https://crosswire.org/sword/modules/ModInfo.jsp?modName=KorRV">CrossWire SWORD '
                 'KorRV 2.0.1</a>(위키문헌 텍스트). 한국에서 저작권 보호기간이 끝난 퍼블릭 도메인. '
                 'OpenMDict 변환.'),
        'catalog_display_name': '성경 (개역한글)',
        'catalog_description': ('성경전서 개역한글판 (1961). 66권, 장별 항목, “요 3:16” 형식 검색. '
                                '퍼블릭 도메인 (한국).'),
        'direction': {'src': 'KO', 'dest': ['KO']},
        'data_source': 'CrossWire SWORD KorRV 2.0.1 (Wikisource)',
    },
    {
        'name': 'Bible-SVD-AR',
        'src': DATA_DIR / 'ar-svd.osis.xml', 'format': 'osis',
        'lang': 'ar', 'style': 'ar', 'script': 'arabic', 'rtl': True, 'local': AR_BOOK_NAMES,
        'names': AR_NAMES, 'fixups': ['svd'],
        # The upstream file labels 1 Chronicles '2Chr' and 2 Chronicles 'Ezra'
        'div_book_override': {13: ('2Chr', '1Chr'), 14: ('Ezra', '2Chr'), 15: ('Ezra', 'Ezra')},
        'dir_label': '✝️ ← \U0001F1F8\U0001F1E6',  # ✝️ ← 🇸🇦 (reads right to left)
        'title': 'الكتاب المقدس — ترجمة فان دايك',
        'desc': ('الكتاب المقدس، ترجمة سميث وفان دايك (1865): 66 سفرًا، مدخل لكل أصحاح؛ ابحث عن «يوحنا 3» '
                 'أو «يوحنا ٣:١٦». المصدر: ' + GRATIS + ' (ar/arasvd.xml)، مع تصحيح تسمية سفري أخبار الأيام '
                 'الأول والثاني، وإكمال رسالة يوحنا الثالثة 1:1 من '
                 '<a href="https://ebible.org/details.php?id=arb-vd">eBible.org arb-vd</a>. ملكية عامة. '
                 'حوّله OpenMDict.'),
        'catalog_display_name': 'الكتاب المقدس — ترجمة فان دايك',
        'catalog_description': ('الكتاب المقدس، ترجمة سميث-فان دايك (1865). 66 سفرًا، مدخل لكل أصحاح، '
                                'والبحث بصيغة «يوحنا 3:16». ملكية عامة.'),
        'direction': {'src': 'AR', 'dest': ['AR']},
        'data_source': 'gratis-bible (arasvd, OSIS XML)',
    },
    {
        'name': 'Bible-Diodati-IT',
        'src': DATA_DIR / 'it-diodati.osis.xml', 'format': 'osis',
        'lang': 'it', 'style': 'latin', 'script': 'latin', 'local': IT_BOOK_NAMES,
        'names': IT_NAMES, 'abbr': IT_ABBR, 'verse_abbr': ':', 'fixups': ['diodati'],
        'dir_label': '✝️ → \U0001F1EE\U0001F1F9',  # ✝️ → 🇮🇹
        'title': 'La Bibbia — Diodati',
        'desc': ('La Sacra Bibbia, traduzione di Giovanni Diodati: 66 libri, una voce per capitolo; '
                 'cercate «Giovanni 3», «Giovanni 3:16» o «Gv 3:16». Fonte: ' + GRATIS + ' (it/itadio.xml). '
                 'Pubblico dominio. Convertito da OpenMDict.'),
        'catalog_display_name': 'La Bibbia — Diodati',
        'catalog_description': ('La Sacra Bibbia, traduzione di Giovanni Diodati. 66 libri, una voce per '
                                'capitolo, ricerca «Giovanni 3:16». Pubblico dominio.'),
        'direction': {'src': 'IT', 'dest': ['IT']},
        'data_source': 'gratis-bible (itadio, OSIS XML)',
    },
    {
        'name': 'Bible-Vulgate-LA',
        'src': DATA_DIR / 'open-bibles-f257a35' / 'lat-clementine.usfx.xml', 'format': 'usfx',
        'lang': 'la', 'style': 'latin', 'script': 'latin', 'local': LA_BOOK_NAMES,
        'names': LA_NAMES, 'legacy': LA_LEGACY, 'abbr': LA_ABBR,
        'deutero': True, 'psalms': 'lxx',
        'garbled_words': re.compile(r'\b(?:qu|Qu|clum|tenebr|Isral|Hc|hc|prcepit|gypti|terr|dificavit)\b'),
        'chapters': {'Esther': 16, 'Daniel': 14},
        # LXX psalm numbering; Greek additions in Esther 10 and Daniel 3
        'shape_skip': {'Psalms', ('Esther', 10), ('Daniel', 3)},
        'dir_label': '✝️ → \U0001F3DB️',  # ✝️ → 🏛️
        'title': 'Biblia Sacra Vulgata',
        'desc': ('Biblia Sacra juxta Vulgatam Clementinam (1592): 73 libri, inter quos Tobiæ, Judith, '
                 'Sapientia, Ecclesiasticus, Baruch et Machabæorum I–II; singula capita singulis articulis. '
                 'Psalmi secundum numerationem Vulgatæ numerantur (Psalmi 22 = Hebr. 23); Anglice “Psalms 23” '
                 'numerationem Hebraicam sequitur. Regum I–IV = 1–2 Samuel et 1–2 Kings. Fons: ' + OPEN_BIBLES +
                 ' (lat-clementine.usfx.xml, commit f257a35). In publico dominio. OpenMDict convertit.'),
        'catalog_display_name': 'Biblia Sacra Vulgata',
        'catalog_description': ('Biblia Sacra Vulgata (Clementina, 1592): 73 libri cum deuterocanonicis, '
                                'singula capita; Psalmi secundum Vulgatam. In publico dominio.'),
        'direction': {'src': 'LA', 'dest': ['LA']},
        'data_source': 'Open Bibles @f257a35 (lat-clementine, USFX XML)',
    },
    {
        'name': 'Bible-Byzantine-GRC',
        'src': DATA_DIR / 'grc-byzantine.usfx.xml', 'format': 'usfx',
        'lang': 'grc', 'style': 'el', 'script': 'greek', 'local': GREEK_BOOK_NAMES,
        'names': EL_NAMES, 'abbr': EL_ABBR, 'testament': 'nt',
        # bdit: Old Testament quotations; it: the 1904 edition's letter-spaced emphasis
        'usfx_italic': ('bdit',), 'usfx_spaced': ('it',),
        'dir_label': '✝️ → \U0001F1EC\U0001F1F7',  # ✝️ → 🇬🇷
        'title': 'Ἡ Καινὴ Διαθήκη (1904)',
        'desc': ('Ἡ Καινὴ Διαθήκη, Πατριαρχικὸν κείμενον (1904): 27 βιβλία, ἓν λῆμμα ἀνὰ κεφάλαιον· '
                 'αναζήτηση «Ιωάννης 3», «Κατά Ιωάννην 3», «Ιω 3:16» ή «John 3:16». Οι παραθέσεις από την '
                 'Παλαιά Διαθήκη σε πλάγια· οι λέξεις που η έκδοση του 1904 τονίζει με αραιά στοιχεία '
                 'εμφανίζονται αραιωμένες. Πηγή: <a href="https://ebible.org/details.php?id=grcbyz">'
                 'eBible.org grcbyz</a>. Δημόσιος τομέας. Μετατροπή: OpenMDict.'),
        'catalog_display_name': 'Ἡ Καινὴ Διαθήκη (1904)',
        'catalog_description': ('Πατριαρχικὸν Κείμενον τῆς Καινῆς Διαθήκης (1904): the Greek New Testament '
                                '(27 books), one entry per chapter, searchable as «Ιωάννης 3» or “John 3:16”. '
                                'Public domain.'),
        'direction': {'src': 'EL', 'dest': ['EL']},
        'data_source': 'eBible.org grcbyz (USFX XML)',
    },
]


# ═════════════════════════════════════════════════════════════
# Build
# ═════════════════════════════════════════════════════════════

PARSERS = {'osis': (parse_osis, count_osis_source), 'usfx': (parse_usfx, count_usfx_source),
           'zefania': (parse_zefania, count_zefania_source), 'sword': (parse_sword, count_sword_source),
           'wikisource': (parse_wikisource, count_wikisource_source),
           'edition-canon': (parse_edition_canon, count_edition_canon_source)}
SAMPLE_CHAPTERS = [('Genesis', 1), ('Psalms', 23), ('John', 3)]


def load_bible(cfg: dict, log: list) -> Bible:
    parse, count = PARSERS[cfg['format']]
    source_count = count(cfg['src'], cfg)
    bible = parse(cfg['src'], cfg, log)
    check_parse(bible, cfg, source_count)
    for b, c, n, v in bible.all_verses():
        v.text.normalize()
        if v.title is not None:
            v.title.normalize()
    for fx in cfg.get('fixups', ()):
        FIXUPS[fx](bible, log)
    for b, c, n, v in bible.all_verses():
        v.text.normalize()
    check_shape(bible, cfg, log)
    dropped = 0
    for b, c, n in sorted(cfg.get('allow_empty', ())):
        v = bible.books.get(b, {}).get(c, {}).get(n)
        if v is not None and v.text.empty():
            del bible.books[b][c][n]
            dropped += 1
    if dropped:
        log.append(f'{dropped} verse numbers that are empty in the source (versification) left out')
    return bible


def build_one(cfg: dict) -> Path:
    name = cfg['name']
    log: list[str] = []
    print(f'\n{"=" * 60}\nBuilding {name}…\n  Source: {cfg["src"].relative_to(DATA_DIR)}')
    bible = load_bible(cfg, log)
    n_verses = len(bible.refs())
    n_ch = sum(len(chs) for chs in bible.books.values())
    print(f'  Parsed: {len(bible.books)} books, {n_ch} chapters, {n_verses} verses')
    entries, ks, html_by_key = build_entries(cfg, bible)
    for line in log:
        print(f'  · {line}')
    if ks.dropped:
        print(f'  · aliases dropped on collision (rank: count) {dict(sorted(ks.dropped.items()))}; '
              f'e.g. {"; ".join(ks.examples[:4])}')

    dict_dir = OUTPUT_BASE / name
    dict_dir.mkdir(parents=True, exist_ok=True)
    slug = name.lower().replace('-', '_')
    txt_path = dict_dir / f'{slug}_entries.txt'
    mdx_path = dict_dir / f'{name}.mdx'
    write_mdict_source(entries, txt_path)
    ok, size_mb, _ = _shared_pack_mdx(txt_path, cfg['title'], f'<p>{cfg["desc"]}</p>', mdx_path)
    if not ok:
        raise BuildError(f'{name}: packing failed')
    n_links = sum(1 for _, body in entries if body.startswith('@@@LINK='))
    print(f'  ✓ {mdx_path.name}: {size_mb:.1f} MB, {len(entries) - n_links} chapters + {n_links} redirects')
    write_catalog_metadata(
        mdx_path=mdx_path,
        display_name=cfg['catalog_display_name'],
        description=cfg['catalog_description'],
        direction=cfg['direction'],
        entries=len(entries),
        license='LicenseRef-Public-Domain',
        data_source=cfg['data_source'],
        tier=2,
        flag='✝️',
    )
    books = {b: Book(cfg, b) for b in book_order(cfg)}
    samples = []
    for b, c in SAMPLE_CHAPTERS:
        if b in books:
            if books[b].lxx:
                c = hebrew_to_lxx(c)[0]
            samples.append(html_by_key[books[b].key(c)])
    _shared_preview(samples, dict_dir / f'{slug}_preview.html', f'{name} — preview')
    return mdx_path


def main(argv: list[str]) -> int:
    wanted = set(argv)
    unknown = wanted - {c['name'] for c in BIBLES}
    if unknown:
        print(f'Unknown Bible(s): {sorted(unknown)}')
        return 2
    failed = []
    for cfg in BIBLES:
        if wanted and cfg['name'] not in wanted:
            continue
        if not cfg['src'].exists():
            print(f'⚠ {cfg["name"]}: {cfg["src"]} not found (see fetch_data.sh fetch_bible)')
            failed.append(cfg['name'])
            continue
        try:
            build_one(cfg)
        except BuildError as e:
            print(f'  ✗ {cfg["name"]}: BUILD GATE FAILED: {e}')
            failed.append(cfg['name'])
    print(f'\n{"=" * 60}')
    if failed:
        print(f'FAILED: {", ".join(failed)}')
        return 1
    print('Done!')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
