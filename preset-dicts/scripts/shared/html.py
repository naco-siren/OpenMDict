"""
OpenMDict shared HTML helpers.

Provides the common `esc()` function (replaces 15 copies of `_esc()`)
and optional convenience builders for semantic HTML elements.

These helpers are OPTIONAL — scripts can still build HTML strings
directly if they need finer control.
"""


def esc(text: str) -> str:
    """HTML-escape text. Replaces &, <, >."""
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def wrap_entry(content: str, css: str) -> str:
    """Wrap inner HTML in CSS + entry root div.

    Args:
        content: Inner HTML (already built — NOT escaped).
        css: CSS string from theme.get_css().

    Returns:
        '{css}<div class="e">{content}</div>'
    """
    return f'{css}<div class="e">{content}</div>'


# ── Semantic HTML builders (optional) ────────────────────────
#
# Functions that take raw text call esc() internally.
# Functions that take pre-built HTML do NOT escape.

def dir_label(text: str) -> str:
    """Direction/language label header bar.

    Args:
        text: Pre-built label string (e.g., '🇬🇧🇺🇸 English').
              NOT escaped — may contain emoji or HTML.
    """
    return f'<span class="dir">{text}</span>'


def headword(text: str, rtl: bool = False) -> str:
    """Headword element."""
    rtl_attr = ' dir="rtl"' if rtl else ''
    return f'<span class="hw"{rtl_attr}>{esc(text)}</span>'


def pronunciation(text: str) -> str:
    """IPA or phonetic pronunciation."""
    return f'<span class="pr">{esc(text)}</span>'


def pos_badge(text: str) -> str:
    """Part-of-speech badge."""
    return f'<span class="pos">{esc(text)}</span>'


def mark_badge(text: str) -> str:
    """Usage mark badge (obs., colloq., etc.)."""
    return f'<span class="mk">{esc(text)}</span>'


def sense_card(content: str) -> str:
    """Sense card wrapper.

    Args:
        content: Inner HTML (already built — NOT escaped).
    """
    return f'<div class="sn">{content}</div>'


def sense_header(*badges: str) -> str:
    """Sense header row with pre-built badge HTML strings."""
    return f'<div class="sn-hd">{"".join(badges)}</div>'


def definition(text: str) -> str:
    """Definition text (escaped)."""
    return f'<span class="df">{esc(text)}</span>'


def gloss(text: str) -> str:
    """Gloss/translation text (escaped)."""
    return f'<span class="gl">{esc(text)}</span>'


def example_block(quote: str, author: str = '') -> str:
    """Monolingual quotation example block."""
    parts = [f'<span class="ex-q">{esc(quote)}</span>']
    if author:
        parts.append(f'<span class="ex-a">{esc(author)}</span>')
    return f'<div class="ex">{"".join(parts)}</div>'


def example_bilingual(source: str, translation: str = '') -> str:
    """Bilingual example block (source language + translation)."""
    parts = [f'<span class="ex-src">{esc(source)}</span>']
    if translation:
        parts.append(f'<span class="ex-tr">{esc(translation)}</span>')
    return f'<div class="ex">{"".join(parts)}</div>'


def separator() -> str:
    """Horizontal separator."""
    return '<hr class="sep">'


# ── Kana → Romaji conversion (Hepburn) ──────────────────────
#
# Shared by build_jmdict_mdx.py and build_kanjidic2_mdx.py.
# JMdict also uses split_morae() and the raw tables for pitch
# accent rendering.

_KATA_TO_HIRA = str.maketrans(
    'ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾ'
    'タダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポ'
    'マミムメモャヤュユョヨラリルレロヮワヰヱヲンヴヵヶ',
    'ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞ'
    'ただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽ'
    'まみむめもゃやゅゆょよらりるれろゎわゐゑをんゔゕゖ'
)

_ROMAJI_MAP = {
    'あ': 'a', 'い': 'i', 'う': 'u', 'え': 'e', 'お': 'o',
    'か': 'ka', 'き': 'ki', 'く': 'ku', 'け': 'ke', 'こ': 'ko',
    'さ': 'sa', 'し': 'shi', 'す': 'su', 'せ': 'se', 'そ': 'so',
    'た': 'ta', 'ち': 'chi', 'つ': 'tsu', 'て': 'te', 'と': 'to',
    'な': 'na', 'に': 'ni', 'ぬ': 'nu', 'ね': 'ne', 'の': 'no',
    'は': 'ha', 'ひ': 'hi', 'ふ': 'fu', 'へ': 'he', 'ほ': 'ho',
    'ま': 'ma', 'み': 'mi', 'む': 'mu', 'め': 'me', 'も': 'mo',
    'や': 'ya', 'ゆ': 'yu', 'よ': 'yo',
    'ら': 'ra', 'り': 'ri', 'る': 'ru', 'れ': 're', 'ろ': 'ro',
    'わ': 'wa', 'ゐ': 'wi', 'ゑ': 'we', 'を': 'wo', 'ん': 'n',
    'が': 'ga', 'ぎ': 'gi', 'ぐ': 'gu', 'げ': 'ge', 'ご': 'go',
    'ざ': 'za', 'じ': 'ji', 'ず': 'zu', 'ぜ': 'ze', 'ぞ': 'zo',
    'だ': 'da', 'ぢ': 'di', 'づ': 'du', 'で': 'de', 'ど': 'do',
    'ば': 'ba', 'び': 'bi', 'ぶ': 'bu', 'べ': 'be', 'ぼ': 'bo',
    'ぱ': 'pa', 'ぴ': 'pi', 'ぷ': 'pu', 'ぺ': 'pe', 'ぽ': 'po',
    'ゔ': 'vu',
    # Small kana (used in combinations)
    'ぁ': 'a', 'ぃ': 'i', 'ぅ': 'u', 'ぇ': 'e', 'ぉ': 'o',
    'ゃ': 'ya', 'ゅ': 'yu', 'ょ': 'yo',
    'ゎ': 'wa',
}

# Two-char combinations (yōon)
_ROMAJI_DIGRAPH = {
    'きゃ': 'kya', 'きゅ': 'kyu', 'きょ': 'kyo',
    'しゃ': 'sha', 'しゅ': 'shu', 'しょ': 'sho',
    'ちゃ': 'cha', 'ちゅ': 'chu', 'ちょ': 'cho',
    'にゃ': 'nya', 'にゅ': 'nyu', 'にょ': 'nyo',
    'ひゃ': 'hya', 'ひゅ': 'hyu', 'ひょ': 'hyo',
    'みゃ': 'mya', 'みゅ': 'myu', 'みょ': 'myo',
    'りゃ': 'rya', 'りゅ': 'ryu', 'りょ': 'ryo',
    'ぎゃ': 'gya', 'ぎゅ': 'gyu', 'ぎょ': 'gyo',
    'じゃ': 'ja', 'じゅ': 'ju', 'じょ': 'jo',
    'びゃ': 'bya', 'びゅ': 'byu', 'びょ': 'byo',
    'ぴゃ': 'pya', 'ぴゅ': 'pyu', 'ぴょ': 'pyo',
    # Extended
    'てぃ': 'ti', 'でぃ': 'di', 'ふぁ': 'fa', 'ふぃ': 'fi',
    'ふぇ': 'fe', 'ふぉ': 'fo', 'ゔぁ': 'va', 'ゔぃ': 'vi',
    'ゔぇ': 've', 'ゔぉ': 'vo',
    'にぃ': 'nyi', 'にぇ': 'nye',
    'しぇ': 'she', 'ちぇ': 'che', 'じぇ': 'je',
    'つぁ': 'tsa', 'つぃ': 'tsi', 'つぇ': 'tse', 'つぉ': 'tso',
    'きぇ': 'kye', 'ひぇ': 'hye', 'みぇ': 'mye', 'りぇ': 'rye',
    'ぎぇ': 'gye', 'びぇ': 'bye', 'ぴぇ': 'pye',
    'うぃ': 'wi', 'うぇ': 'we', 'うぉ': 'wo',
    'くぁ': 'kwa', 'ぐぁ': 'gwa',
    'すぃ': 'si', 'ずぃ': 'zi',
    'とぅ': 'tu', 'どぅ': 'du',
    'ゔゅ': 'vyu',
}


def split_morae(kana: str) -> list[str]:
    """Split kana into morae (accounting for small kana combinations)."""
    small_kana = set('ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ')
    morae: list[str] = []
    i = 0
    while i < len(kana):
        ch = kana[i]
        if i + 1 < len(kana) and kana[i + 1] in small_kana:
            morae.append(kana[i:i+2])
            i += 2
        else:
            morae.append(ch)
            i += 1
    return morae


def kana_to_romaji_morae(kana: str) -> list[str]:
    """Convert kana to Hepburn romaji, returning one string per mora.

    Keeps segments aligned 1:1 with split_morae(), so pitch accent
    contour can be applied to romaji as well (used by JMdict).
    """
    morae = split_morae(kana.translate(_KATA_TO_HIRA))
    result: list[str] = []
    for idx, mora in enumerate(morae):
        if mora == 'っ':
            if idx + 1 < len(morae):
                next_mora = morae[idx + 1]
                next_rom = _ROMAJI_DIGRAPH.get(next_mora) or _ROMAJI_MAP.get(next_mora, '')
                if next_rom and next_rom[0].isalpha():
                    result.append('t' if next_rom.startswith('ch') else next_rom[0])
                else:
                    result.append('t')
            else:
                result.append('t')
            continue
        if mora == 'ー':
            if result and result[-1] and result[-1][-1] in 'aeiou':
                result.append(result[-1][-1])
            else:
                result.append('-')
            continue
        rom = _ROMAJI_DIGRAPH.get(mora)
        if rom:
            result.append(rom)
            continue
        if len(mora) == 1 and mora in _ROMAJI_MAP:
            rom = _ROMAJI_MAP[mora]
            if rom == 'n' and idx + 1 < len(morae):
                next_mora = morae[idx + 1]
                next_rom = _ROMAJI_DIGRAPH.get(next_mora) or _ROMAJI_MAP.get(next_mora, '')
                if next_rom and next_rom[0] in 'aiueoy':
                    rom = "n'"
            result.append(rom)
        else:
            result.append(mora)
    return result


def kana_to_romaji(kana: str) -> str:
    """Convert kana string to Hepburn romaji."""
    return ''.join(kana_to_romaji_morae(kana))
