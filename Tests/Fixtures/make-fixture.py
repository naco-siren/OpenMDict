#!/usr/bin/env python3
"""Regenerate the tiny test dictionary (tiny.mdx + tiny.mdd).

The fixture is a ~60-entry synthetic English dictionary written for this
test suite — no third-party dictionary content.  It exists so that
`swift test` works out of the box; set MDICT_TEST_FILE to run the same
suites against a real dictionary.

Requires the `mdict` CLI from mdict-utils (pip install mdict-utils).

    python3 Tests/Fixtures/make-fixture.py
"""

import os
import shutil
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent

WORDS = [
    "aardvark", "abacus", "abbey", "able", "about", "above", "acorn", "across",
    "banana", "basket", "beacon", "beam", "bear", "bell", "berry", "bird",
    "cabin", "cable", "camel", "candle", "cat", "cedar", "chair", "cloud",
    "hello", "helmet", "help", "helpful",
    "unable", "uncle", "under", "unite",
    "prefix", "prelude", "press", "pretty",
    "dog", "eagle", "falcon", "garden", "harbor", "island", "jungle",
    "kettle", "lantern", "meadow", "north", "ocean", "pebble", "quiet",
    "river", "stone", "thunder", "umbrella", "valley", "willow", "yellow", "zebra",
]

CSS = "body { font-family: serif; }\n.hw { font-weight: bold; }\n.pos { font-style: italic; }\n"

# 1x1 transparent PNG, built by hand so no binary blob is checked in as source.
def tiny_png() -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        c = tag + data
        return len(data).to_bytes(4, "big") + c + zlib.crc32(c).to_bytes(4, "big")
    ihdr = (1).to_bytes(4, "big") + (1).to_bytes(4, "big") + bytes([8, 6, 0, 0, 0])
    idat = zlib.compress(b"\x00\x00\x00\x00\x00")
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def entry_html(i: int, word: str) -> str:
    html = (f'<link rel="stylesheet" href="tiny.css">'
            f'<div class="entry"><span class="hw">{word}</span> '
            f'<span class="pos">noun</span> '
            f'<span class="def">Synthetic definition #{i} for <i>{word}</i>.</span>')
    if i % 7 == 0:
        html += ' <img src="tiny.png" alt="">'
    if i % 5 == 0:
        nxt = WORDS[(i + 1) % len(WORDS)]
        html += f' See also <a href="entry://{nxt}">{nxt}</a>.'
    return html + "</div>"


def main() -> None:
    if shutil.which("mdict") is None:
        raise SystemExit("mdict CLI not found — pip install mdict-utils")
    # Name the fixtures to regenerate (tiny, homographs, fallbacks,
    # casesensitive); with none named, all of them are.
    targets = set(sys.argv[1:]) or {"tiny", "homographs", "fallbacks", "casesensitive"}

    if "tiny" in targets:
        make_tiny()
    if "homographs" in targets:
        make_homographs()
    if "fallbacks" in targets:
        make_fallbacks()
    if "casesensitive" in targets:
        make_case_sensitive()

    for f in ("tiny.mdx", "tiny.mdd", "homographs.mdx", "fallbacks.mdx", "casesensitive.mdx"):
        print(f"{f}: {os.path.getsize(HERE / f)} bytes")


def make_tiny() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        lines = []
        for i, w in enumerate(sorted(set(WORDS))):
            lines += [w, entry_html(i, w), "</>"]
        # A couple of redirect entries (uppercase variants → canonical).
        lines += ["Hello", "@@@LINK=hello", "</>", "ZEBRA", "@@@LINK=zebra", "</>"]
        (tmp / "tiny.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        (tmp / "title.html").write_text("OpenMDict Test Fixture", encoding="utf-8")
        (tmp / "desc.html").write_text(
            "Tiny synthetic dictionary used by the OpenMDict test suite.", encoding="utf-8")

        res = tmp / "res"
        res.mkdir()
        (res / "tiny.css").write_text(CSS, encoding="utf-8")
        (res / "tiny.png").write_bytes(tiny_png())

        for old in ("tiny.mdx", "tiny.mdd"):
            (HERE / old).unlink(missing_ok=True)
        subprocess.run(["mdict", "--title", str(tmp / "title.html"),
                        "--description", str(tmp / "desc.html"),
                        "-a", str(tmp / "tiny.txt"), str(HERE / "tiny.mdx")], check=True)
        subprocess.run(["mdict", "-a", str(res), str(HERE / "tiny.mdd")], check=True)


# Records sharing a key, keys differing only in case, an article plus a
# redirect under one key, and apostrophe keys — for the lookup that returns
# every matching record (MDXParser.lookupAllWithIndex).
HOMOGRAPHS = [
    ("bank", "<p>bank (1): the side of a river</p>"),
    ("bank", "<p>bank (2): an institution that keeps money</p>"),
    ("turkey", "<p>turkey: a large bird</p>"),
    ("Turkey", "<p>Turkey: a country</p>"),
    ("essere", "<p>essere: to be</p>"),
    ("sono", "<p>sono: alternative form of suono</p>"),
    ("sono", "@@@LINK=essere"),
    ("am", "@@@LINK=be"),
    ("Am", "@@@LINK=be"),
    ("be", "<p>be: to exist</p>"),
    ("o'clock", "<p>o'clock: of the clock</p>"),
    ("rock \u2019n\u2019 roll", "<p>rock \u2019n\u2019 roll: a genre</p>"),
    ("single", "<p>single: one only</p>"),
    # Keys that use different apostrophes in one dictionary.
    ("rapport d'activité", "<p>rapport d'activité: activity report</p>"),
    ("rapport d\u2019étape", "<p>rapport d\u2019étape: progress report</p>"),
    # Records that repeat the same script and stylesheet.
    ("toggle", '<link rel="stylesheet" href="t.css"><script src="t.js"></script><p>toggle (1)</p>'),
    ("toggle", '<link rel="stylesheet" href="t.css"><script src="t.js"></script><p>toggle (2)</p>'),
] + [("many", f"<p>many #{i}</p>") for i in range(60)]


def make_homographs() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        lines = []
        for key, body in HOMOGRAPHS:
            lines += [key, body, "</>"]
        (tmp / "h.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        (tmp / "title.html").write_text("OpenMDict Homograph Fixture", encoding="utf-8")
        (tmp / "desc.html").write_text(
            "Synthetic records with shared keys, used by the OpenMDict test suite.", encoding="utf-8")
        (HERE / "homographs.mdx").unlink(missing_ok=True)
        subprocess.run(["mdict", "--title", str(tmp / "title.html"),
                        "--description", str(tmp / "desc.html"),
                        "-a", str(tmp / "h.txt"), str(HERE / "homographs.mdx")], check=True)


# Keys for the lookup fallbacks (MDXParser.lookupAllWithFallbacks): verse
# references typed with full-width digits, keys with diacritics, letters that
# must not fold, and base forms of English and German inflections.
FALLBACKS = [
    # Width folding
    ("John 3:16", "<p>John 3:16 (en)</p>"),
    ("ヨハネ3:16", "<p>ヨハネ3:16 (ja)</p>"),
    ("ヨハネ 3:16", "@@@LINK=ヨハネ3:16"),
    ("约翰福音3:16", "<p>约翰福音3:16 (zh)</p>"),
    # Diacritics: Greek, Latin, Arabic
    ("Ἀθῆναι", "<p>Ἀθῆναι: Athens</p>"),
    ("ὁδός", "<p>ὁδός: way</p>"),
    ("ᾄδω", "<p>ᾄδω: sing</p>"),
    ("amō", "<p>amō: I love</p>"),
    ("café", "<p>café: coffee house</p>"),
    ("resume", "<p>resume: to begin again</p>"),
    ("résumé", "<p>résumé: a summary</p>"),
    ("كِتَاب", "<p>كِتَاب: book</p>"),
    ("أحمد", "<p>أحمد: Ahmad</p>"),
    # Letters that are not marks: must not fold to other keys
    ("Straße", "<p>Straße: street</p>"),
    ("øre", "<p>øre: coin</p>"),
    ("łódź", "<p>łódź: boat</p>"),
    # Marks the user typed must be on the key: keys that differ from
    # common accented words only by a mark ("è", "está", "tenía", "χωριά",
    # "çök", "dönmüş", "uñas" must not find them)
    ("e", "<p>e: and (it)</p>"),
    ("esta", "<p>esta: this (es)</p>"),
    ("tenia", "<p>tenia: tapeworm (es)</p>"),
    ("χώρια", "<p>χώρια: apart (el)</p>"),
    ("çok", "<p>çok: very (tr)</p>"),
    ("donmuş", "<p>donmuş: frozen (tr)</p>"),
    ("unas", "<p>unas: some (es)</p>"),
    # Cyrillic: й is a letter of its own; stress accents and ё fold
    ("зайка", "<p>зайка: bunny (ru)</p>"),
    ("заика", "<p>заика: stammerer (ru)</p>"),
    ("индий", "<p>индий: indium (ru)</p>"),
    ("ещё", "<p>ещё: still (ru)</p>"),
    # Arabic: hamza on waw and yeh is a letter; harakat are reading aids
    ("فئة", "<p>فئة: group (ar)</p>"),
    ("محمد", "<p>محمد: Muhammad (ar)</p>"),
    ("هٰذَا", "<p>هٰذَا: this (ar, with superscript alef)</p>"),
    # Hangul syllables and kana: composed keys that decomposed queries must find
    ("한국", "<p>한국: Korea (ko)</p>"),
    ("がっこう", "<p>がっこう: school (ja)</p>"),
    # Compatibility forms: ligatures and half-width katakana
    ("find", "<p>find: to discover</p>"),
    ("office", "<p>office: a workplace</p>"),
    ("コーヒー", "<p>コーヒー: coffee (ja)</p>"),
    # An apostrophe key with a mark
    ("l'école", "<p>l'école: the school (fr)</p>"),
    # Fallback order: "machte" is an inflection of "machen" and folds to
    # "Mächte" (inflection wins); "Muller" folds to "Müller", which wins over
    # the loose noun stem "Mull"; "blorpier" only has a loose stem, "blorpy"
    ("Mächte", "<p>Mächte: powers</p>"),
    ("Müller", "<p>Müller: miller</p>"),
    ("Mull", "<p>Mull: gauze</p>"),
    ("blorpy", "<p>blorpy: made up</p>"),
    ("blorpen", "<p>blorpen: made up (de verb)</p>"),
    # English base forms
    ("hue", "<p>hue: a colour</p>"),
    ("olive", "<p>olive: a fruit</p>"),
    ("walk", "<p>walk: to go on foot</p>"),
    ("study", "<p>study: to learn</p>"),
    ("make", "<p>make: to create</p>"),
    ("stop", "<p>stop: to halt</p>"),
    ("big", "<p>big: large</p>"),
    ("happy", "<p>happy: glad</p>"),
    ("watch", "<p>watch: to look at</p>"),
    ("go", "<p>go: to move</p>"),
    # German base forms
    ("gehen", "<p>gehen: to go</p>"),
    ("machen", "<p>machen: to make</p>"),
    ("spielen", "<p>spielen: to play</p>"),
    ("wandern", "<p>wandern: to hike</p>"),
    ("aufmachen", "<p>aufmachen: to open</p>"),
    ("Haus", "<p>Haus: house</p>"),
    # German forms the rules must read right: Waren, Seiten, Gerichten are
    # nouns; wartete, kostet, gräbt are verbs; dachte and kann have irregular
    # bases the lemma model gets wrong or writes without umlauts
    ("Ware", "<p>Ware: goods</p>"),
    ("sein", "<p>sein: to be</p>"),
    ("Seite", "<p>Seite: page</p>"),
    ("seit", "<p>seit: since</p>"),
    ("Gericht", "<p>Gericht: court</p>"),
    ("richten", "<p>richten: to judge</p>"),
    ("warten", "<p>warten: to wait</p>"),
    ("kosten", "<p>kosten: to cost</p>"),
    ("kosen", "<p>kosen: to caress</p>"),
    ("graben", "<p>graben: to dig</p>"),
    ("denken", "<p>denken: to think</p>"),
    ("können", "<p>können: to be able</p>"),
]


def make_fallbacks() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        lines = []
        for key, body in FALLBACKS:
            lines += [key, body, "</>"]
        (tmp / "f.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        (tmp / "title.html").write_text("OpenMDict Fallback Fixture", encoding="utf-8")
        (tmp / "desc.html").write_text(
            "Synthetic keys for the lookup fallbacks, used by the OpenMDict test suite.", encoding="utf-8")
        (HERE / "fallbacks.mdx").unlink(missing_ok=True)
        subprocess.run(["mdict", "--title", str(tmp / "title.html"),
                        "--description", str(tmp / "desc.html"),
                        "-a", str(tmp / "f.txt"), str(HERE / "fallbacks.mdx")], check=True)


# A case-sensitive dictionary (KeyCaseSensitive="Yes"): the lookup's
# case-sensitive branches, e.g. the capitalized base form of a German noun
# for a lowercase rule candidate (Kindern → kind → Kind).
CASE_SENSITIVE = [
    ("Kind", "<p>Kind: child</p>"),
    ("Haus", "<p>Haus: house</p>"),
    ("Müller", "<p>Müller: miller</p>"),
    ("machen", "<p>machen: to make</p>"),
    ("Weg", "<p>Weg: way</p>"),
    ("weg", "<p>weg: away</p>"),
    ("Blorp", "<p>Blorp: made up (de noun)</p>"),
]


def make_case_sensitive() -> None:
    out = HERE / "casesensitive.mdx"
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        lines = []
        for key, body in CASE_SENSITIVE:
            lines += [key, body, "</>"]
        (tmp / "c.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        (tmp / "title.html").write_text("OpenMDict Case-Sensitive Fixture", encoding="utf-8")
        (tmp / "desc.html").write_text(
            "Synthetic case-sensitive keys, used by the OpenMDict test suite.", encoding="utf-8")
        out.unlink(missing_ok=True)
        subprocess.run(["mdict", "--title", str(tmp / "title.html"),
                        "--description", str(tmp / "desc.html"),
                        "-a", str(tmp / "c.txt"), str(out)], check=True)
    # mdict-utils always writes KeyCaseSensitive="No": patch the header
    # (length-prefixed, UTF-16LE or UTF-8, followed by its adler32; the rest
    # of the file is parsed sequentially, so its offsets do not move).
    data = out.read_bytes()
    length = int.from_bytes(data[:4], "big")
    header, rest = data[4:4 + length], data[8 + length:]
    if header[:2] == b"\xff\xfe" or header.endswith(b"\x00\x00"):
        text = header.decode("utf-16-le")
        patched = text.replace('KeyCaseSensitive="No"', 'KeyCaseSensitive="Yes"').encode("utf-16-le")
    else:
        text = header.decode("utf-8")
        patched = text.replace('KeyCaseSensitive="No"', 'KeyCaseSensitive="Yes"').encode("utf-8")
    if patched == header:
        raise SystemExit("KeyCaseSensitive attribute not found in the mdict header")
    out.write_bytes(len(patched).to_bytes(4, "big") + patched
                    + zlib.adler32(patched).to_bytes(4, "little") + rest)


if __name__ == "__main__":
    main()
