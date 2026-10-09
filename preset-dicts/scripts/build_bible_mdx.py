#!/usr/bin/env python3
"""
Build Bible MDX dictionaries from OSIS XML, USFX XML, and Zefania XML source files.

Supports 14 public-domain Bible translations in 11 languages:
  EN, ZH-Hans, ZH-Hant, JA, ES, FR, DE, PT, RU, KO, AR, IT, TR, LA

Entry structure:
  - Chapter-level entries: "Genesis 1" → all verses in the chapter
  - Local-name aliases:    "创世记 1"   → @@@LINK=Genesis 1

Display layout:
  - Latin-script Bibles: headword = "Exodus 10", subtitle = Hebrew/Greek original
  - CJK/non-Latin Bibles: headword = "出埃及记 10", subtitle = "Exodus 10"

Usage:
    python3 build_bible_mdx.py

Input:  ../data/bible/*.xml
Output: ../output/Bible-*/Bible-*.mdx
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import OrderedDict

# ── Shared infrastructure ─────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, SENSE_NUMBER_INLINE
from shared.html import esc
from shared.build import pack_mdx as _shared_pack_mdx, generate_preview as _shared_preview, write_mdict_source, write_catalog_metadata

# ── Paths ──────────────────────────────────────────────────────
DATA_DIR = SCRIPT_DIR.parent / "data" / "bible"
OUTPUT_BASE = SCRIPT_DIR.parent / "output"

# ── OSIS book ID → canonical English name ────────────────────
OSIS_BOOK_NAMES = {
    # Old Testament
    "Gen": "Genesis", "Exod": "Exodus", "Lev": "Leviticus", "Num": "Numbers",
    "Deut": "Deuteronomy", "Josh": "Joshua", "Judg": "Judges", "Ruth": "Ruth",
    "1Sam": "1 Samuel", "2Sam": "2 Samuel", "1Kgs": "1 Kings", "2Kgs": "2 Kings",
    "1Chr": "1 Chronicles", "2Chr": "2 Chronicles", "Ezra": "Ezra", "Neh": "Nehemiah",
    "Esth": "Esther", "Job": "Job", "Ps": "Psalms", "Prov": "Proverbs",
    "Eccl": "Ecclesiastes", "Song": "Song of Solomon", "Isa": "Isaiah", "Jer": "Jeremiah",
    "Lam": "Lamentations", "Ezek": "Ezekiel", "Dan": "Daniel", "Hos": "Hosea",
    "Joel": "Joel", "Amos": "Amos", "Obad": "Obadiah", "Jonah": "Jonah",
    "Mic": "Micah", "Nah": "Nahum", "Hab": "Habakkuk", "Zeph": "Zephaniah",
    "Hag": "Haggai", "Zech": "Zechariah", "Mal": "Malachi",
    # New Testament
    "Matt": "Matthew", "Mark": "Mark", "Luke": "Luke", "John": "John",
    "Acts": "Acts", "Rom": "Romans", "1Cor": "1 Corinthians", "2Cor": "2 Corinthians",
    "Gal": "Galatians", "Eph": "Ephesians", "Phil": "Philippians", "Col": "Colossians",
    "1Thess": "1 Thessalonians", "2Thess": "2 Thessalonians",
    "1Tim": "1 Timothy", "2Tim": "2 Timothy", "Titus": "Titus", "Phlm": "Philemon",
    "Heb": "Hebrews", "Jas": "James", "1Pet": "1 Peter", "2Pet": "2 Peter",
    "1John": "1 John", "2John": "2 John", "3John": "3 John",
    "Jude": "Jude", "Rev": "Revelation",
}

# USFX uses 3-letter codes
USFX_BOOK_NAMES = {
    "GEN": "Genesis", "EXO": "Exodus", "LEV": "Leviticus", "NUM": "Numbers",
    "DEU": "Deuteronomy", "JOS": "Joshua", "JDG": "Judges", "RUT": "Ruth",
    "1SA": "1 Samuel", "2SA": "2 Samuel", "1KI": "1 Kings", "2KI": "2 Kings",
    "1CH": "1 Chronicles", "2CH": "2 Chronicles", "EZR": "Ezra", "NEH": "Nehemiah",
    "EST": "Esther", "JOB": "Job", "PSA": "Psalms", "PRO": "Proverbs",
    "ECC": "Ecclesiastes", "SNG": "Song of Solomon", "ISA": "Isaiah", "JER": "Jeremiah",
    "LAM": "Lamentations", "EZK": "Ezekiel", "DAN": "Daniel", "HOS": "Hosea",
    "JOL": "Joel", "AMO": "Amos", "OBA": "Obadiah", "JON": "Jonah",
    "MIC": "Micah", "NAM": "Nahum", "HAB": "Habakkuk", "ZEP": "Zephaniah",
    "HAG": "Haggai", "ZEC": "Zechariah", "MAL": "Malachi",
    "MAT": "Matthew", "MRK": "Mark", "LUK": "Luke", "JHN": "John",
    "ACT": "Acts", "ROM": "Romans", "1CO": "1 Corinthians", "2CO": "2 Corinthians",
    "GAL": "Galatians", "EPH": "Ephesians", "PHP": "Philippians", "COL": "Colossians",
    "1TH": "1 Thessalonians", "2TH": "2 Thessalonians",
    "1TI": "1 Timothy", "2TI": "2 Timothy", "TIT": "Titus", "PHM": "Philemon",
    "HEB": "Hebrews", "JAS": "James", "1PE": "1 Peter", "2PE": "2 Peter",
    "1JN": "1 John", "2JN": "2 John", "3JN": "3 John",
    "JUD": "Jude", "REV": "Revelation",
}

# Zefania bnumber → canonical English name (1-based)
ZEFANIA_BOOK_ORDER = [
    "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy",
    "Joshua", "Judges", "Ruth", "1 Samuel", "2 Samuel",
    "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles",
    "Ezra", "Nehemiah", "Esther", "Job", "Psalms", "Proverbs",
    "Ecclesiastes", "Song of Solomon", "Isaiah", "Jeremiah",
    "Lamentations", "Ezekiel", "Daniel", "Hosea", "Joel", "Amos",
    "Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk", "Zephaniah",
    "Haggai", "Zechariah", "Malachi",
    "Matthew", "Mark", "Luke", "John", "Acts",
    "Romans", "1 Corinthians", "2 Corinthians", "Galatians",
    "Ephesians", "Philippians", "Colossians",
    "1 Thessalonians", "2 Thessalonians",
    "1 Timothy", "2 Timothy", "Titus", "Philemon",
    "Hebrews", "James", "1 Peter", "2 Peter",
    "1 John", "2 John", "3 John", "Jude", "Revelation",
]

# ── Local book name maps ─────────────────────────────────────

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
    "Song of Solomon": "Песня Песней", "Isaiah": "Исаия", "Jeremiah": "Иеремия",
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
    "2 Peter": "베드로후서", "1 John": "요한1서", "2 John": "요한2서",
    "3 John": "요한3서", "Jude": "유다서", "Revelation": "요한계시록",
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

LA_BOOK_NAMES = {
    "Genesis": "Genesis", "Exodus": "Exodus", "Leviticus": "Leviticus",
    "Numbers": "Numeri", "Deuteronomy": "Deuteronomium", "Joshua": "Iosue",
    "Judges": "Iudicum", "Ruth": "Ruth", "1 Samuel": "I Samuelis",
    "2 Samuel": "II Samuelis", "1 Kings": "I Regum", "2 Kings": "II Regum",
    "1 Chronicles": "I Paralipomenon", "2 Chronicles": "II Paralipomenon", "Ezra": "Esdrae",
    "Nehemiah": "Nehemiae", "Esther": "Esther", "Job": "Iob",
    "Psalms": "Psalmi", "Proverbs": "Proverbia", "Ecclesiastes": "Ecclesiastes",
    "Song of Solomon": "Canticum Canticorum", "Isaiah": "Isaias", "Jeremiah": "Ieremias",
    "Lamentations": "Lamentationes", "Ezekiel": "Ezechiel", "Daniel": "Daniel",
    "Hosea": "Osee", "Joel": "Ioel", "Amos": "Amos",
    "Obadiah": "Abdias", "Jonah": "Ionas", "Micah": "Michaeas",
    "Nahum": "Nahum", "Habakkuk": "Habacuc", "Zephaniah": "Sophonias",
    "Haggai": "Aggaeus", "Zechariah": "Zacharias", "Malachi": "Malachias",
    "Matthew": "Matthaeus", "Mark": "Marcus", "Luke": "Lucas",
    "John": "Ioannes", "Acts": "Actus Apostolorum", "Romans": "Romanos",
    "1 Corinthians": "I Corinthios", "2 Corinthians": "II Corinthios",
    "Galatians": "Galatas", "Ephesians": "Ephesios", "Philippians": "Philippenses",
    "Colossians": "Colossenses", "1 Thessalonians": "I Thessalonicenses",
    "2 Thessalonians": "II Thessalonicenses", "1 Timothy": "I Timotheum",
    "2 Timothy": "II Timotheum", "Titus": "Titum", "Philemon": "Philemonem",
    "Hebrews": "Hebraeos", "James": "Iacobi", "1 Peter": "I Petri",
    "2 Peter": "II Petri", "1 John": "I Ioannis", "2 John": "II Ioannis",
    "3 John": "III Ioannis", "Jude": "Iudae", "Revelation": "Apocalypsis",
}

# Canonical OT/NT book order (same as ZEFANIA_BOOK_ORDER)
BOOK_ORDER = ZEFANIA_BOOK_ORDER

# ── Original-language book names ─────────────────────────────
# OT: Hebrew (Masoretic) with vowel points
# NT: Greek (Koine) — Gospels use "Κατὰ X" form, Epistles use traditional titles

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


def get_original_name(book_name: str) -> str:
    """Get the Hebrew (OT) or Greek (NT) original name for a Bible book."""
    return HEBREW_BOOK_NAMES.get(book_name) or GREEK_BOOK_NAMES.get(book_name, '')

# ── CSS ────────────────────────────────────────────────────────
CSS = get_css(
    SENSE_NUMBER_INLINE,
    extra_light=(
        '.sub{font-size:1.15em;color:#6e6e73;display:block;margin-top:2px}'
        '.sub2{font-size:1.15em;color:#0071e3;font-style:italic;display:block;margin-top:1px}'
        '.gl{font-size:1.05em}'
        '.nav{display:flex;justify-content:space-between;margin-top:12px;padding-top:8px;'
        'border-top:1px solid #e5e5ea;font-size:0.9em;color:#636366}'
        '.nav a{color:#0071e3;text-decoration:none}'
    ),
    extra_dark=(
        '.sub{color:#98989d}'
        '.sub2{color:#64d2ff}'
        '.nav{border-color:#38383a;color:#98989d}'
        '.nav a{color:#64d2ff}'
    ),
)


# ── Parsers ────────────────────────────────────────────────────

def parse_osis(xml_path: Path) -> dict:
    """Parse OSIS XML into {book_name: {chapter_num: {verse_num: text}}}."""
    tree = ET.parse(xml_path)
    root = tree.getroot()
    ns = 'http://www.bibletechnologies.net/2003/OSIS/namespace'

    bible = OrderedDict()

    for verse_elem in root.iter(f'{{{ns}}}verse'):
        osis_id = verse_elem.get('osisID')
        if not osis_id:
            continue

        # Parse "Book.Chapter.Verse"
        parts = osis_id.split('.')
        if len(parts) != 3:
            continue
        book_code, chap_str, verse_str = parts
        book_name = OSIS_BOOK_NAMES.get(book_code)
        if not book_name:
            continue

        chap = int(chap_str)

        # Handle sub-verse markers like "3!a" → 3
        verse_num_str = re.split(r'[^0-9]', verse_str)[0]
        if not verse_num_str:
            continue
        verse = int(verse_num_str)

        # Extract text: either in tail (sID/eID pairs) or inside element
        text = ''
        s_id = verse_elem.get('sID')
        if s_id:
            # Text is in the tail after the opening <verse> tag
            text = (verse_elem.tail or '').strip()
        else:
            # Text is inside the <verse> element
            text = ''.join(verse_elem.itertext()).strip()

        if not text:
            continue

        if book_name not in bible:
            bible[book_name] = OrderedDict()
        if chap not in bible[book_name]:
            bible[book_name][chap] = OrderedDict()

        # Sub-verse (e.g. "3!b") appends to existing verse text
        if verse in bible[book_name][chap] and verse_str != str(verse):
            bible[book_name][chap][verse] += ' ' + text
        else:
            bible[book_name][chap][verse] = text

    return bible


def parse_usfx(xml_path: Path) -> dict:
    """Parse USFX XML into {book_name: {chapter_num: {verse_num: text}}}.

    Handles two USFX variants:
      1. Simple: text in <v> tail (CUV)
      2. Strong's: text in <w> text/tail between <v> tags (RVR1909, etc.)
    """
    tree = ET.parse(xml_path)
    root = tree.getroot()

    bible = OrderedDict()
    current_book = None
    current_chap = None
    current_verse = None
    verse_text_parts = []

    def _flush_verse():
        nonlocal current_verse, verse_text_parts
        if current_book and current_chap is not None and current_verse is not None:
            text = ' '.join(verse_text_parts).strip()
            # Normalize multiple spaces
            text = re.sub(r'\s+', ' ', text)
            if text:
                if current_book not in bible:
                    bible[current_book] = OrderedDict()
                if current_chap not in bible[current_book]:
                    bible[current_book][current_chap] = OrderedDict()
                bible[current_book][current_chap][current_verse] = text
        current_verse = None
        verse_text_parts = []

    for event, elem in ET.iterparse(xml_path, events=('start', 'end')):
        tag = elem.tag.split('}')[-1] if '}' in elem.tag else elem.tag

        if event == 'start':
            if tag == 'book':
                _flush_verse()
                book_code = elem.get('id', '').upper()
                current_book = USFX_BOOK_NAMES.get(book_code)

            elif tag == 'c':
                _flush_verse()
                chap_id = elem.get('id')
                if chap_id and current_book:
                    current_chap = int(chap_id)

            elif tag == 'v':
                _flush_verse()
                verse_id = elem.get('id')
                if verse_id and current_book and current_chap is not None:
                    current_verse = int(verse_id)
                # Collect tail text after <v> tag
                tail = (elem.tail or '').strip()
                if tail and current_verse is not None:
                    verse_text_parts.append(tail)

            elif tag in ('w', 'add', 'wj') and current_verse is not None:
                # <w> (Strong's word), <add> (added text), <wj> (words of Jesus)
                t = (elem.text or '').strip()
                if t:
                    verse_text_parts.append(t)

        elif event == 'end':
            if tag in ('w', 'add', 'wj') and current_verse is not None:
                tail = (elem.tail or '').strip()
                if tail:
                    verse_text_parts.append(tail)
            elif tag == 've' and current_verse is not None:
                # <ve/> = verse end marker; collect any tail
                tail = (elem.tail or '').strip()
                if tail:
                    verse_text_parts.append(tail)
            elif tag == 'p' and current_verse is not None:
                # Paragraph boundaries: collect tail
                tail = (elem.tail or '').strip()
                if tail:
                    verse_text_parts.append(tail)

        # Free memory for completed elements
        if event == 'end':
            elem.clear()

    _flush_verse()
    return bible


def parse_zefania(xml_path: Path) -> dict:
    """Parse Zefania XML into {book_name: {chapter_num: {verse_num: text}}}.

    Structure: <XMLBIBLE><BIBLEBOOK bnumber="N" bname="..."><CHAPTER cnumber="N"><VERS vnumber="N">text</VERS>
    """
    tree = ET.parse(xml_path)
    root = tree.getroot()

    bible = OrderedDict()

    for book_elem in root.iter('BIBLEBOOK'):
        bnumber = book_elem.get('bnumber')
        if not bnumber:
            continue
        bnum = int(bnumber)
        if bnum < 1 or bnum > len(ZEFANIA_BOOK_ORDER):
            continue
        book_name = ZEFANIA_BOOK_ORDER[bnum - 1]

        if book_name not in bible:
            bible[book_name] = OrderedDict()

        for chap_elem in book_elem.iter('CHAPTER'):
            cnumber = chap_elem.get('cnumber')
            if not cnumber:
                continue
            chap = int(cnumber)
            if chap not in bible[book_name]:
                bible[book_name][chap] = OrderedDict()

            for vers_elem in chap_elem.iter('VERS'):
                vnumber = vers_elem.get('vnumber')
                if not vnumber:
                    continue
                verse = int(vnumber)
                text = ''.join(vers_elem.itertext()).strip()
                if text:
                    bible[book_name][chap][verse] = text

    return bible


# ── HTML Builder ──────────────────────────────────────────────

def build_chapter_html(book_name: str, chap: int, verses: dict,
                       local_book_names: dict, total_chapters: int,
                       is_latin_script: bool = True,
                       dir_label: str = '') -> str:
    """Build HTML for a chapter entry.

    Layout for Latin-script Bibles (EN, ES, FR, DE, PT, IT, TR, LA):
        .hw  = "Exodus 10"         (local name + chapter number)
        .sub2 = "שְׁמוֹת 10"        (Hebrew/Greek original + chapter number)

    Layout for CJK / non-Latin Bibles (ZH, JA, KO, AR, RU):
        .hw  = "出埃及记 10"         (local name + chapter number)
        .sub = "Exodus 10"          (English canonical name + chapter number)
    """
    local_name = local_book_names.get(book_name, book_name)
    html_parts = [CSS, '<div class="e">']

    # Direction label (header row)
    if dir_label:
        html_parts.append(f'<span class="dir">{dir_label}</span>')

    # Headword: local name + chapter number
    html_parts.append(f'<span class="hw">{esc(local_name)} {chap}</span>')

    # Subtitle line(s)
    if is_latin_script:
        # Latin-script Bible: show original Hebrew/Greek name + chapter number
        orig = get_original_name(book_name)
        if orig:
            html_parts.append(f'<span class="sub2">{esc(orig)} {chap}</span>')
    else:
        # CJK/non-Latin Bible: show English name as subtitle
        html_parts.append(f'<span class="sub">{esc(book_name)} {chap}</span>')

    for vnum in sorted(verses.keys()):
        text = verses[vnum]
        html_parts.append(
            f'<div class="sn"><span class="sn-n">{vnum}</span> <span class="gl">{esc(text)}</span></div>'
        )

    # Navigation: prev (left) / next (right) via flexbox space-between
    if chap > 1 or chap < total_chapters:
        html_parts.append('<div class="nav">')
        if chap > 1:
            prev_key = f'{book_name} {chap - 1}'
            local_prev = local_book_names.get(book_name, book_name)
            html_parts.append(f'<a href="entry://{prev_key}">\u25C0 {esc(local_prev)} {chap - 1}</a>')
        else:
            html_parts.append('<span></span>')
        if chap < total_chapters:
            next_key = f'{book_name} {chap + 1}'
            local_next = local_book_names.get(book_name, book_name)
            html_parts.append(f'<a href="entry://{next_key}">{esc(local_next)} {chap + 1} \u25B6</a>')
        else:
            html_parts.append('<span></span>')
        html_parts.append('</div>')

    html_parts.append('</div>')
    return ''.join(html_parts)


# ── MDict Entry Builder ──────────────────────────────────────

def build_entries(bible: dict, local_book_names: dict,
                  is_latin_script: bool = True,
                  dir_label: str = '') -> list:
    """Build MDict entry pairs: [(headword, html_or_redirect), ...].

    Only chapter-level entries are generated (no verse-level redirects).
    """
    entries = []

    # Sort books in canonical order
    ordered_books = sorted(
        bible.keys(),
        key=lambda b: BOOK_ORDER.index(b) if b in BOOK_ORDER else 999
    )

    for book_name in ordered_books:
        chapters = bible[book_name]
        total_chapters = max(chapters.keys()) if chapters else 0
        local_name = local_book_names.get(book_name, book_name)

        for chap in sorted(chapters.keys()):
            verses = chapters[chap]
            if not verses:
                continue

            # Chapter entry (primary)
            chap_key = f'{book_name} {chap}'
            html = build_chapter_html(book_name, chap, verses,
                                       local_book_names, total_chapters,
                                       is_latin_script, dir_label)
            entries.append((chap_key, html))

            # Local-name chapter alias: "创世记 1" → @@@LINK=Genesis 1
            if local_name != book_name:
                local_chap_key = f'{local_name} {chap}'
                entries.append((local_chap_key, f'@@@LINK={chap_key}'))

    return entries


# ── MDX Packing ───────────────────────────────────────────────

def pack_mdx(dict_dir: Path, name: str, entries: list,
             title_str: str, desc_str: str) -> Path | None:
    """Write entries and pack MDX for a Bible translation.
    Returns the MDX path on success, None on failure."""
    dict_dir.mkdir(parents=True, exist_ok=True)

    slug = name.lower().replace("-", "_")
    txt_path = dict_dir / f'{slug}_entries.txt'
    mdx_path = dict_dir / f'{name}.mdx'

    write_mdict_source(entries, txt_path)

    success, size_mb, _ = _shared_pack_mdx(
        txt_path, title_str, f'<p>{desc_str}</p>', mdx_path
    )
    if not success:
        return None

    chapter_entries = sum(1 for _, body in entries if not body.startswith('@@@LINK='))
    total_entries = len(entries)
    print(f'  \u2713 {mdx_path.name}: {size_mb:.1f} MB, {chapter_entries} chapters + {total_entries - chapter_entries} redirects')
    return mdx_path


# ── Bible Configurations ──────────────────────────────────────

BIBLES = [
    {
        'name': 'Bible-KJV-EN',
        'xml': DATA_DIR / 'kjv.osis.xml',
        'format': 'osis',
        'local_names': {},
        'is_latin_script': True,
        'dir_label': '✝️ → \U0001F1EC\U0001F1E7\U0001F1FA\U0001F1F8',  # ✝️ → 🇬🇧🇺🇸
        'title': 'King James Version (KJV)',
        'desc': 'The King James Version of the Holy Bible (1611). Public Domain.',
        'catalog_display_name': 'Bible — King James Version',
        'catalog_description': 'The King James Version (1611) of the Holy Bible, 66 books with chapter-level entries. Public Domain.',
        'catalog_direction': {'src': 'EN', 'dest': ['EN']},
        'catalog_data_source': 'Open Bibles (OSIS XML)',
    },
    {
        'name': 'Bible-CUV-ZH-Hans',
        'xml': DATA_DIR / 'cuv-simp.usfx.xml',
        'format': 'usfx',
        'local_names': ZH_HANS_BOOK_NAMES,
        'is_latin_script': False,
        'dir_label': '✝️ → \U0001F1E8\U0001F1F3',  # ✝️ → 🇨🇳
        'title': '和合本圣经（简体）',
        'desc': '中文和合本圣经（1919年），简体中文。公有领域。',
        'catalog_display_name': '和合本圣经（简体）',
        'catalog_description': '中文和合本圣经（1919年），简体中文。66卷，章级条目。公有领域。',
        'catalog_direction': {'src': 'ZH', 'dest': ['ZH']},
        'catalog_data_source': 'Open Bibles (USFX XML)',
    },
    {
        'name': 'Bible-CUV-ZH-Hant',
        'xml': DATA_DIR / 'cuv-trad.usfx.xml',
        'format': 'usfx',
        'local_names': ZH_HANT_BOOK_NAMES,
        'is_latin_script': False,
        'dir_label': '✝️ → \U0001F1F9\U0001F1FC\U0001F1ED\U0001F1F0',  # ✝️ → 🇹🇼🇭🇰
        'title': '和合本聖經（繁體）',
        'desc': '中文和合本聖經（1919年），繁體中文。公有領域。',
        'catalog_display_name': '和合本聖經（繁體）',
        'catalog_description': '中文和合本聖經（1919年），繁體中文。66卷，章級條目。公有領域。',
        'catalog_direction': {'src': 'ZH', 'dest': ['ZH']},
        'catalog_data_source': 'Open Bibles (USFX XML)',
    },
    {
        'name': 'Bible-Kougo-JA',
        'xml': DATA_DIR / 'kougo.osis.xml',
        'format': 'osis',
        'local_names': JA_BOOK_NAMES,
        'is_latin_script': False,
        'dir_label': '✝️ → \U0001F1EF\U0001F1F5',  # ✝️ → 🇯🇵
        'title': '口語訳聖書',
        'desc': '口語訳聖書（1954-1955年）。パブリックドメイン。',
        'catalog_display_name': '口語訳聖書',
        'catalog_description': '口語訳聖書（1954-1955年）。66巻、章レベルのエントリ。パブリックドメイン。',
        'catalog_direction': {'src': 'JA', 'dest': ['JA']},
        'catalog_data_source': 'Open Bibles (OSIS XML)',
    },
    {
        'name': 'Bible-RV1909-ES',
        'xml': DATA_DIR / 'spa-rv1909.usfx.xml',
        'format': 'usfx',
        'local_names': ES_BOOK_NAMES,
        'is_latin_script': True,
        'dir_label': '✝️ → \U0001F1EA\U0001F1F8',  # ✝️ → 🇪🇸
        'title': 'Santa Biblia — Reina-Valera 1909',
        'desc': 'La Santa Biblia, versión Reina-Valera (1909). Dominio público.',
        'catalog_display_name': 'Santa Biblia — Reina-Valera 1909',
        'catalog_description': 'La Santa Biblia, versión Reina-Valera (1909). 66 libros. Dominio público.',
        'catalog_direction': {'src': 'ES', 'dest': ['ES']},
        'catalog_data_source': 'Open Bibles (USFX XML)',
    },
    {
        'name': 'Bible-Darby-FR',
        'xml': DATA_DIR / 'fra-darby.osis.xml',
        'format': 'osis',
        'local_names': FR_BOOK_NAMES,
        'is_latin_script': True,
        'dir_label': '✝️ → \U0001F1EB\U0001F1F7',  # ✝️ → 🇫🇷
        'title': 'Bible Darby (français)',
        'desc': 'La Bible, traduction J.N. Darby (1859-1880). Domaine public.',
        'catalog_display_name': 'Bible Darby (français)',
        'catalog_description': 'La Bible, traduction J.N. Darby (1859-1880). 66 livres. Domaine public.',
        'catalog_direction': {'src': 'FR', 'dest': ['FR']},
        'catalog_data_source': 'Open Bibles (OSIS XML)',
    },
    {
        'name': 'Bible-Luther1912-DE',
        'xml': DATA_DIR / 'deu-luther1912.osis.xml',
        'format': 'osis',
        'local_names': DE_BOOK_NAMES,
        'is_latin_script': True,
        'dir_label': '✝️ → \U0001F1E9\U0001F1EA',  # ✝️ → 🇩🇪
        'title': 'Lutherbibel 1912',
        'desc': 'Die Bibel, Lutherübersetzung (1912). Gemeinfrei.',
        'catalog_display_name': 'Lutherbibel 1912',
        'catalog_description': 'Die Bibel, Lutherübersetzung (1912). 66 Bücher. Gemeinfrei.',
        'catalog_direction': {'src': 'DE', 'dest': ['DE']},
        'catalog_data_source': 'Open Bibles (OSIS XML)',
    },
    {
        'name': 'Bible-Almeida-PT',
        'xml': DATA_DIR / 'por-almeida.usfx.xml',
        'format': 'usfx',
        'local_names': PT_BOOK_NAMES,
        'is_latin_script': True,
        'dir_label': '✝️ → \U0001F1F5\U0001F1F9\U0001F1E7\U0001F1F7',  # ✝️ → 🇵🇹🇧🇷
        'title': 'Bíblia Sagrada — Almeida',
        'desc': 'Bíblia Sagrada, tradução de João Ferreira de Almeida. Domínio público.',
        'catalog_display_name': 'Bíblia Sagrada — Almeida',
        'catalog_description': 'Bíblia Sagrada, tradução de João Ferreira de Almeida. 66 livros. Domínio público.',
        'catalog_direction': {'src': 'PT', 'dest': ['PT']},
        'catalog_data_source': 'Open Bibles (USFX XML)',
    },
    {
        'name': 'Bible-Synodal-RU',
        'xml': DATA_DIR / 'rus-synodal.zefania.xml',
        'format': 'zefania',
        'local_names': RU_BOOK_NAMES,
        'is_latin_script': False,
        'dir_label': '✝️ → \U0001F1F7\U0001F1FA',  # ✝️ → 🇷🇺
        'title': 'Синодальный перевод',
        'desc': 'Библия, Синодальный перевод (1876). Общественное достояние.',
        'catalog_display_name': 'Синодальный перевод',
        'catalog_description': 'Библия, Синодальный перевод (1876). 66 книг. Общественное достояние.',
        'catalog_direction': {'src': 'RU', 'dest': ['RU']},
        'catalog_data_source': 'Open Bibles (Zefania XML)',
    },
    {
        'name': 'Bible-Korean-KO',
        'xml': DATA_DIR / 'kor-korean.osis.xml',
        'format': 'osis',
        'local_names': KO_BOOK_NAMES,
        'is_latin_script': False,
        'dir_label': '✝️ → \U0001F1F0\U0001F1F7',  # ✝️ → 🇰🇷
        'title': '성경 (개역한글)',
        'desc': '한국어 성경 (1910). 퍼블릭 도메인.',
        'catalog_display_name': '성경 (개역한글)',
        'catalog_description': '한국어 성경 (1910). 66권. 퍼블릭 도메인.',
        'catalog_direction': {'src': 'KO', 'dest': ['KO']},
        'catalog_data_source': 'Open Bibles (OSIS XML)',
    },
    {
        'name': 'Bible-SVD-AR',
        'xml': DATA_DIR / 'ar-svd.osis.xml',
        'format': 'osis',
        'local_names': AR_BOOK_NAMES,
        'is_latin_script': False,
        'dir_label': '✝️ → \U0001F1F8\U0001F1E6',  # ✝️ → 🇸🇦
        'title': 'الكتاب المقدس — ترجمة فان دايك',
        'desc': 'الكتاب المقدس، ترجمة سميث-فان دايك (1865). ملكية عامة.',
        'catalog_display_name': 'الكتاب المقدس — ترجمة فان دايك',
        'catalog_description': 'الكتاب المقدس، ترجمة سميث-فان دايك (1865). ملكية عامة.',
        'catalog_direction': {'src': 'AR', 'dest': ['AR']},
        'catalog_data_source': 'Open Bibles (OSIS XML)',
    },
    {
        'name': 'Bible-Diodati-IT',
        'xml': DATA_DIR / 'it-diodati.osis.xml',
        'format': 'osis',
        'local_names': IT_BOOK_NAMES,
        'is_latin_script': True,
        'dir_label': '✝️ → \U0001F1EE\U0001F1F9',  # ✝️ → 🇮🇹
        'title': 'La Bibbia — Diodati',
        'desc': 'La Sacra Bibbia, traduzione di Giovanni Diodati. Dominio pubblico.',
        'catalog_display_name': 'La Bibbia — Diodati',
        'catalog_description': 'La Sacra Bibbia, traduzione di Giovanni Diodati. 66 libri. Dominio pubblico.',
        'catalog_direction': {'src': 'IT', 'dest': ['IT']},
        'catalog_data_source': 'Open Bibles (OSIS XML)',
    },
    {
        'name': 'Bible-Vulgate-LA',
        'xml': DATA_DIR / 'la-vulgate.osis.xml',
        'format': 'osis',
        'local_names': LA_BOOK_NAMES,
        'is_latin_script': True,
        'dir_label': '✝️ → \U0001F3DB\uFE0F',  # ✝️ → 🏛️
        'title': 'Biblia Sacra Vulgata',
        'desc': 'Biblia Sacra Vulgata (Clementina). In publico dominio.',
        'catalog_display_name': 'Biblia Sacra Vulgata',
        'catalog_description': 'Biblia Sacra Vulgata (Clementina). In publico dominio.',
        'catalog_direction': {'src': 'LA', 'dest': ['LA']},
        'catalog_data_source': 'Open Bibles (OSIS XML)',
    },
    {
        'name': 'Bible-Byzantine-GRC',
        'xml': DATA_DIR / 'grc-byzantine.usfx.xml',
        'format': 'usfx',
        'local_names': GREEK_BOOK_NAMES,
        'is_latin_script': False,
        'dir_label': '✝️ → \U0001F1EC\U0001F1F7',  # ✝️ → 🇬🇷
        'title': 'Ἡ Καινὴ Διαθήκη (1904)',
        'desc': 'Πατριαρχικὸν Κείμενον τῆς Καινῆς Διαθήκης (1904). Δημόσιος τομέας.',
        'catalog_display_name': 'Ἡ Καινὴ Διαθήκη (1904)',
        'catalog_description': 'Πατριαρχικὸν Κείμενον τῆς Καινῆς Διαθήκης (1904). New Testament only (27 books). Public Domain.',
        'catalog_direction': {'src': 'EL', 'dest': ['EL']},
        'catalog_data_source': 'eBible.org (USFX XML)',
    },
]


# ── Preview ──────────────────────────────────────────────────

SAMPLE_CHAPTERS = [('Genesis', 1), ('Psalms', 23), ('John', 3)]


def _generate_preview(bible: dict, local_book_names: dict,
                      is_latin_script: bool, dict_dir: Path, name: str,
                      dir_label: str = ''):
    """Generate a preview HTML for a Bible translation."""
    slug = name.lower().replace("-", "_")
    entries_html = []

    for book_name, chap in SAMPLE_CHAPTERS:
        if book_name in bible and chap in bible[book_name]:
            total_chapters = max(bible[book_name].keys())
            html = build_chapter_html(book_name, chap, bible[book_name][chap],
                                       local_book_names, total_chapters,
                                       is_latin_script, dir_label)
            entries_html.append(html)

    if not entries_html:
        return

    preview_path = dict_dir / f"{slug}_preview.html"
    _shared_preview(entries_html, preview_path, f'{name} — preview')


# ── Main ──────────────────────────────────────────────────────

def main():
    mdx_paths = []

    for config in BIBLES:
        name = config['name']
        xml_path = config['xml']

        if not xml_path.exists():
            print(f'\u26A0 Skipping {name}: {xml_path} not found')
            continue

        print(f'\n{"="*60}')
        print(f'Building {name}...')
        print(f'  Source: {xml_path.name}')

        fmt = config['format']
        if fmt == 'osis':
            bible = parse_osis(xml_path)
        elif fmt == 'usfx':
            bible = parse_usfx(xml_path)
        elif fmt == 'zefania':
            bible = parse_zefania(xml_path)
        else:
            print(f'  ERROR: Unknown format {fmt}')
            continue

        total_books = len(bible)
        total_chapters = sum(len(chs) for chs in bible.values())
        total_verses = sum(
            len(vs) for chs in bible.values() for vs in chs.values()
        )
        print(f'  Parsed: {total_books} books, {total_chapters} chapters, {total_verses} verses')

        is_latin_script = config.get('is_latin_script', True)
        dir_label = config.get('dir_label', '')
        entries = build_entries(bible, config['local_names'],
                                is_latin_script, dir_label)
        print(f'  Entries: {len(entries)} total')

        dict_dir = OUTPUT_BASE / name
        mdx_path = pack_mdx(dict_dir, name, entries,
                            config['title'], config['desc'])
        if mdx_path:
            mdx_paths.append(mdx_path)
            write_catalog_metadata(
                mdx_path=mdx_path,
                display_name=config['catalog_display_name'],
                description=config['catalog_description'],
                direction=config['catalog_direction'],
                entries=len(entries),
                license='Public Domain',
                data_source=config['catalog_data_source'],
                tier=2,
                flag='✝️',
            )
            _generate_preview(bible, config['local_names'],
                              is_latin_script, dict_dir, name, dir_label)

    print(f'\n{"="*60}')
    print('Done!')


if __name__ == '__main__':
    main()
