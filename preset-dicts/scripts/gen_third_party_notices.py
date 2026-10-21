#!/usr/bin/env python3
"""Generate the preset-dictionary part of THIRD-PARTY-NOTICES.md.

Reads preset-dictionaries.json and rewrites the block between

    <!-- BEGIN GENERATED: preset dictionaries -->
    <!-- END GENERATED: preset dictionaries -->

in ../THIRD-PARTY-NOTICES.md (repository root): the attribution table, the
catalog's licenseNotes, the per-source notices (SOURCE_NOTICES below, each
printed when a catalog dictionary uses that source) and the license list.
Everything outside the markers is hand-maintained and left untouched. If
the markers are missing, the block is appended to the end of the file.

Usage:
    python3 scripts/gen_third_party_notices.py            # rewrite in place
    python3 scripts/gen_third_party_notices.py --check    # exit 1 if stale
    python3 scripts/gen_third_party_notices.py --stdout   # print the block

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent          # preset-dicts/
REPO_ROOT = ROOT.parent                                # repository root
CATALOG_PATH = ROOT / "preset-dictionaries.json"
NOTICES_PATH = REPO_ROOT / "THIRD-PARTY-NOTICES.md"
LICENSES_DIR = ROOT / "licenses"

BEGIN = "<!-- BEGIN GENERATED: preset dictionaries -->"
END = "<!-- END GENERATED: preset dictionaries -->"

# ── Attribution for each catalog `dataSource` ────────────────────
#
# Keyed by a case-insensitive prefix of the catalog's `dataSource`
# string. Add a row here when a new data source is introduced; the
# script fails loudly on an unknown source so the table can never
# silently lose an attribution.

SOURCES: list[tuple[str, str, str]] = [
    # (dataSource prefix, project / holder, URL)
    ("WikDict", "WikDict (Karl Bartel); data from Wiktionary (Wiktionary contributors) via DBnary (Gilles Sérasset, CC BY-SA 3.0)", "https://www.wikdict.com/"),
    ("Kaikki.org", "English Wiktionary contributors, via Kaikki.org / Wiktextract (modified by OpenMDict)", "https://kaikki.org/dictionary/"),
    ("Open Bibles", "Public-domain Bible texts (open-bibles collection, eBible.org)", "https://github.com/seven1m/open-bibles"),
    ("eBible.org", "eBible.org", "https://ebible.org/"),
    ("gratis-bible", "gratis-bible OSIS Bibles (public-domain texts from The Unbound Bible / Free Bible Software Group)", "https://github.com/gratis-bible/bible"),
    ("CrossWire", "CrossWire Bible Society, SWORD module KorRV (Korean Revised Version 1961, Wikisource text)", "https://crosswire.org/sword/modules/ModInfo.jsp?modName=KorRV"),
    ("Perseus Digital Library", "Perseus Digital Library, Tufts University", "https://github.com/PerseusDL/lexica"),
    ("Open English WordNet", "Open English WordNet (Global WordNet Association); derived from Princeton WordNet", "https://en-word.net/"),
    ("GCIDE", "GNU Collaborative International Dictionary of English, (C) 1992-2021 Patrick J. Cassidy; includes WordNet 1.5, (C) 1995 Princeton University", "https://www.gnu.org/software/gcide/"),
    ("CC-CEDICT", "CC-CEDICT (MDBG)", "https://cc-cedict.org/"),
    ("CC-Canto", "CC-Canto © 2015–2017 Pleco Inc.; includes entries adapted from CC-CEDICT (MDBG)", "https://cantonese.org/"),
    ("JMdict", "JMdict (EDRDG, used in conformance with the EDRDG licence); pitch accents from Kanjium by Uros O.", "https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project"),
    ("KANJIDIC2", "KANJIDIC2 (EDRDG, used in conformance with the EDRDG licence)", "https://www.edrdg.org/wiki/index.php/KANJIDIC_Project"),
    ("FreeDict", "FreeDict, from the Ding dictionary (Frank Richter, TU Chemnitz, and contributors)", "https://freedict.org/"),
    ("Moby Thesaurus", "Moby Thesaurus II (Grady Ward), via Project Gutenberg #3202; redirect keys (word forms, spelling variants) from Open English WordNet, derived from Princeton WordNet", "https://www.gutenberg.org/ebooks/3202"),
    ("Unicode Unihan", "Unicode Unihan Database (Unicode, Inc.)", "https://www.unicode.org/charts/unihan.html"),
    ("English Wiktionary", "English Wiktionary contributors, via Kaikki.org / Wiktextract, packaged by Vuizur/Wiktionary-Dictionaries (modified by OpenMDict)", "https://github.com/Vuizur/Wiktionary-Dictionaries"),
]

# ── License id → (display name, URL) ─────────────────────────────

LICENSES: dict[str, tuple[str, str]] = {
    "CC-BY-SA-3.0": ("Creative Commons Attribution-ShareAlike 3.0 Unported", "https://creativecommons.org/licenses/by-sa/3.0/"),
    "CC-BY-SA-4.0": ("Creative Commons Attribution-ShareAlike 4.0 International", "https://creativecommons.org/licenses/by-sa/4.0/"),
    "CC-BY-4.0": ("Creative Commons Attribution 4.0 International", "https://creativecommons.org/licenses/by/4.0/"),
    "GPL-3.0-or-later": ("GNU General Public License v3.0 or later", "https://www.gnu.org/licenses/gpl-3.0.html"),
    "AGPL-3.0-or-later": ("GNU Affero General Public License v3.0 or later", "https://www.gnu.org/licenses/agpl-3.0.html"),
    "GFDL-1.3-or-later": ("GNU Free Documentation License v1.3 or later", "https://www.gnu.org/licenses/fdl-1.3.html"),
    "Unicode-3.0": ("Unicode License v3", "https://www.unicode.org/license.txt"),
    "LicenseRef-WordNet-3.0": ("Princeton WordNet 3.0 License", "https://wordnet.princeton.edu/license-and-commercial-use"),
    "LicenseRef-Public-Domain": ("Public domain (no license required)", ""),
}

_EXPR_SPLIT = re.compile(r"\s+(?:AND|OR|WITH)\s+")


def license_ids(expression: str) -> list[str]:
    """Split an SPDX expression into its bare license ids."""
    return [tok.strip("() ") for tok in _EXPR_SPLIT.split(expression) if tok.strip("() ")]


def attribution(data_source: str) -> tuple[str, str]:
    low = data_source.lower()
    for prefix, holder, url in SOURCES:
        if low.startswith(prefix.lower()):
            return holder, url
    raise SystemExit(f"ERROR: no attribution row for dataSource {data_source!r} "
                     f"-- add it to SOURCES in {Path(__file__).name}")


def md_escape(text: str) -> str:
    return text.replace("|", "\\|")


def license_text(name: str) -> str:
    """A license file from preset-dicts/licenses/, for quoting in a notice."""
    path = LICENSES_DIR / name
    if not path.is_file():
        raise SystemExit(f"ERROR: {path} is missing (quoted in THIRD-PARTY-NOTICES.md)")
    return path.read_text(encoding="utf-8").strip("\n")


def blockquote(text: str) -> str:
    return "\n".join(("> " + line) if line.strip() else ">" for line in text.strip("\n").split("\n"))


# ── Per-source notices ───────────────────────────────────────────
#
# Credit lines, copyright notices and modification statements that the
# upstream licenses ask for and that do not fit in the table. Each notice
# is printed when at least one catalog dictionary matches `applies`, with
# the matching file names. `{name}` fields are filled from the catalog by
# `fields` (a regex on the matching dictionaries' dataSource), so release
# numbers follow the catalog.

def _starts(*prefixes: str) -> Callable[[dict], bool]:
    low = tuple(p.lower() for p in prefixes)
    return lambda d: d["dataSource"].lower().startswith(low)


def _uses_oewn(d: dict) -> bool:
    return (d["dataSource"].lower().startswith("open english wordnet")
            or "LicenseRef-WordNet-3.0" in license_ids(d["license"])
            or d["filename"].startswith("WikDict-EN-"))


SOURCE_NOTICES: list[dict] = [
    {
        "title": "CC-CEDICT",
        "applies": _starts("CC-CEDICT"),
        "text": """\
CC-CEDICT, the community-maintained free Chinese-English dictionary, is
published by MDBG (<https://www.mdbg.net/chinese/dictionary?page=cc-cedict>,
<https://cc-cedict.org/wiki/>) under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The upstream
file supplies this notice for its referenced work:

> CEDICT - Copyright (C) 1997, 1998 Paul Andrew Denisowski

OpenMDict modified it: readings are grouped and reordered by headword, pinyin
is shown with tone marks, cross-references are linked, and lookup redirects
are added for Traditional, variant and punctuation-free spellings
(`preset-dicts/scripts/build_cedict_mdx.py`). The release used is named in the
dictionary's description. The modified data is shared under the same license.
""",
    },
    {
        "title": "JMdict and KANJIDIC2 (EDRDG)",
        "applies": _starts("JMdict", "KANJIDIC2"),
        "fields": {
            "jmdict_release": ("JMdict", r"release (\d{4}-\d{2}-\d{2})"),
            "kanjidic2_version": ("KANJIDIC2", r"database version (\S+)"),
        },
        "text": """\
Acknowledgement as section 3 of the
[EDRDG licence](https://www.edrdg.org/edrdg/licence.html) asks:

> This publication has included material from the
> [JMdict](https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project)
> and [KANJIDIC2](https://www.edrdg.org/wiki/index.php/KANJIDIC_Project)
> dictionary files in accordance with the licence provisions of the
> [Electronic Dictionary Research and Development Group](https://www.edrdg.org/).
> The files are the property of the Electronic Dictionary Research and
> Development Group (copyright James William Breen and the EDRDG) and are
> used in conformance with the Group's licence (CC BY-SA 4.0).
> Documentation: <https://www.edrdg.org/jmdict/j_jmdict.html>,
> <https://www.edrdg.org/wiki/index.php/KANJIDIC_Project>.

**JMdict** (release {jmdict_release}): the pitch accent notation was
provided by Uros O. through his free database
[Kanjium](https://github.com/mifunetoshiro/kanjium) (CC BY-SA 4.0).
OpenMDict converted and modified both (lookup keys for every written form and
reading, romaji, pitch-accent rendering, HTML layout) with
`preset-dicts/scripts/build_jmdict_mdx.py`.

**KANJIDIC2** (database version {kanjidic2_version}): the pinyin readings
are © Christian Wittern and Koichi Yasuoka and the Korean readings © Charles
Muller, included in KANJIDIC2 with their permission.
`preset-dicts/scripts/build_kanjidic2_mdx.py` converts, abridges and
reformats it: it keeps the readings, English meanings, nanori, stroke
counts, classical radicals, grade, frequency, former JLPT level and
`<variant>` links (code-point references, and dictionary-number or
query-code references only when the two kanji refer to each other), adds
romaji, and leaves out non-English meanings, query codes and dictionary
index numbers.

Both adaptations are shared under CC BY-SA 4.0. The EDRDG licence
(section 4) requires the data to be updated regularly from the current
releases: `preset-dicts/scripts/fetch_data.sh --refresh jmdict kanjidic2`
fetches them, each build pins its release by date or version and SHA-256 and
warns once that release is more than a month old (`MAINTAINING.md`,
"Refreshing the EDRDG data").
""",
    },
    {
        "title": "GCIDE",
        "applies": _starts("GCIDE"),
        "fields": {"gcide_version": ("GCIDE", r"GCIDE (\d+\.\d+)")},
        "text": """\
GNU Collaborative International Dictionary of English, version
{gcide_version}, Copyright (C) 1992-2021 Patrick J. Cassidy, based on
Webster's Revised Unabridged Dictionary (G. & C. Merriam Co., 1913) with
additions from WordNet 1.5. GCIDE is free; you can redistribute it and/or
modify it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
Source: <https://www.gnu.org/software/gcide/>. The `.mdx` is a converted and
modified form (HTML rendering, Greek transliteration converted to Greek
script, stress marks re-placed, cross-references linked, added lookup keys)
produced by `preset-dicts/scripts/build_gcide_mdx.py`; the date of the
modification is stated in the dictionary's description.

GCIDE includes definitions taken from WordNet 1.5, for which Princeton
University asks that this notice appear on all copies:

> WordNet 1.5 Copyright 1995 by Princeton University. All rights reserved.
>
> Permission to use, copy, modify and distribute this software and database
> and its documentation for any purpose and without fee or royalty is hereby
> granted, provided that you agree to comply with the following copyright
> notice and statements, including the disclaimer, and that the same appear
> on ALL copies of the software, database and documentation, including
> modifications that you make for internal use or for distribution.
>
> THIS SOFTWARE AND DATABASE IS PROVIDED "AS IS" AND PRINCETON UNIVERSITY
> MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR IMPLIED. BY WAY OF
> EXAMPLE, BUT NOT LIMITATION, PRINCETON UNIVERSITY MAKES NO REPRESENTATIONS
> OR WARRANTIES OF MERCHANTABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR
> THAT THE USE OF THE LICENSED SOFTWARE, DATABASE OR DOCUMENTATION WILL NOT
> INFRINGE ANY THIRD PARTY PATENTS, COPYRIGHTS, TRADEMARKS OR OTHER RIGHTS.
>
> The name of Princeton University or Princeton may not be used in
> advertising or publicity pertaining to distribution of the software and/or
> database. Title to copyright in this software, database and any associated
> documentation shall at all times remain with Princeton University and
> LICENSEE agrees to preserve same.
""",
    },
    {
        "title": "FreeDict",
        "applies": _starts("FreeDict"),
        "fields": {"freedict_edition": ("FreeDict", r"(\d+\.\d+(?:\.\d+)?-fd\d+)")},
        "text": """\
FreeDict edition {freedict_edition}, generated by FreeDict from the
[Ding](https://dict.tu-chemnitz.de/) dictionary (TU Chemnitz) with
ding2tei-haskell. Copyright (C) Frank Richter 1995-2020, Einhard Leichtfuß
2020-2022, Sebastian Humenda 2021. Upstream licenses the combined work under
both the [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.html) and the
[GNU AGPL v3](https://www.gnu.org/licenses/agpl-3.0.html), each applying to
different parts of it; its source form is the Ding dictionary (GPLv2+) and
the ding2tei-haskell program (AGPLv3+), hence the catalog's
`GPL-3.0-or-later AND AGPL-3.0-or-later`. It is distributed WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. OpenMDict converted and modified it (new layout, lookup
keys for phrase, inflected and abbreviated forms, example sentences merged
from linked entries) with `preset-dicts/scripts/build_freedict_mdx.py`.
""",
    },
    {
        "title": "Open English WordNet",
        "applies": _uses_oewn,
        "license_file": "LICENSE-LicenseRef-WordNet-3.0.txt",
        "text": """\
[Open English WordNet](https://en-word.net/)
(<https://github.com/globalwordnet/english-wordnet>), Copyright © 2019–present,
The Open English WordNet Team, licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) and provided as is,
without warranties. `WordNet-EN.mdx` is converted and reformatted from it;
Moby Thesaurus II and the WikDict English→XX dictionaries take English word
forms and spelling variants from it for their redirect keys. Open English
WordNet is based on Princeton WordNet, whose license asks that this notice
appear on all copies (also in
`preset-dicts/licenses/LICENSE-LicenseRef-WordNet-3.0.txt`):

{license_file}
""",
    },
    {
        "title": "Perseus Digital Library",
        "applies": _starts("Perseus Digital Library"),
        "text": """\
Required credit, reproduced as the upstream
[PerseusDL/lexica](https://github.com/PerseusDL/lexica) README asks:

> Text provided under a CC BY-SA license by Perseus Digital Library,
> http://www.perseus.tufts.edu, with funding from The National Endowment for
> the Humanities. Data accessed from https://github.com/PerseusDL/lexica/
> [LSJ: 2026-10-17; Lewis & Short: 2026-10-20].

Sources: LSJ `grc.lsj.perseus-eng1..27.xml` (PerseusDL/lexica commit
a6d6f11) and Lewis & Short `lat.ls.perseus-eng2.xml` (commit edd73d8). Both
`.mdx` files are adaptations under CC BY-SA 4.0 and say so in their
descriptions. OpenMDict modified the text as follows: LSJ Greek converted
from beta code to Unicode; entries rendered as HTML with cross-references
linked and homograph numbers shown as labels; page and column breaks
omitted and, where the source marks a correction, the corrected reading
shown; a few damaged upstream headword keys repaired (listed in
`preset-dicts/scripts/build_perseus_mdx.py`); and redirect keys added for
the spellings readers type (for LSJ also the forms of the article, and
variant endings written out as whole words). The text is otherwise
complete. The conversion script is
`preset-dicts/scripts/build_perseus_mdx.py`; as the lexica README asks, these
modifications are to be offered to Perseus (for example as issues or pull
requests on PerseusDL/lexica for the repaired keys).
""",
    },
    {
        "title": "Unicode Han Database (Unihan)",
        "applies": _starts("Unicode Unihan"),
        "fields": {"unihan_version": ("Unicode Unihan", r"(\d+\.\d+\.\d+)")},
        "license_file": "LICENSE-Unicode-3.0.txt",
        "text": """\
Derived from the Unihan data files of Unicode {unihan_version}
(<https://www.unicode.org/Public/{unihan_version}/ucd/Unihan.zip>, documented
in [UAX #38](https://www.unicode.org/reports/tr38/)) by
`preset-dicts/scripts/build_unihan_mdx.py`. Its kJapanese readings come from
the Moji Jōhō Kiban database, owned by CITPC (文字情報技術促進協議会) and used
by Unicode under license. The data files are used under the Unicode License
v3 (also in `preset-dicts/licenses/LICENSE-Unicode-3.0.txt`):

{license_file}
""",
    },
    {
        "title": "Wiktionary-derived dictionaries",
        "applies": _starts("Kaikki.org", "WikDict", "English Wiktionary"),
        "text": """\
The Kaikki, WikDict and Wiktionary dictionaries are built from Wiktionary
text written by the Wiktionary contributors (<https://www.wiktionary.org/>)
and were modified by OpenMDict (filtered, restructured, lookup keys and
redirects added; see each description). Wiktionary text published since June
2023 is licensed under CC BY-SA 4.0 (and the GFDL), so the Kaikki.org
extracts of February 2026 and WikDict release 2025-11 are distributed under
CC BY-SA 4.0 (WikDict's DBnary dataset states CC BY-SA 3.0, whose section
4(b) allows adaptations under a later version). The two Wiktionary TSV
dictionaries come from a November 2022 snapshot
(Vuizur/Wiktionary-Dictionaries, built from Kaikki.org / Wiktextract data),
when Wiktionary text was dual-licensed under CC BY-SA 3.0 and the GFDL, and
keep that licensing.
""",
    },
]


def _fill(notice: dict, dicts: list[dict]) -> str:
    values: dict[str, str] = {}
    for name, (prefix, pattern) in notice.get("fields", {}).items():
        found = None
        for d in dicts:
            if d["dataSource"].lower().startswith(prefix.lower()):
                m = re.search(pattern, d["dataSource"])
                if m:
                    found = m.group(1)
                    break
        if found is None:
            raise SystemExit(f"ERROR: notice {notice['title']!r}: no {prefix!r} dataSource matches "
                             f"{pattern!r} -- update SOURCE_NOTICES in {Path(__file__).name}")
        values[name] = found
    if "license_file" in notice:
        values["license_file"] = "```\n" + license_text(notice["license_file"]) + "\n```"
    return notice["text"].format(**values).strip("\n")


def render_source_notices(dicts: list[dict]) -> list[str]:
    lines: list[str] = []
    for notice in SOURCE_NOTICES:
        matching = [d for d in dicts if notice["applies"](d)]
        if not matching:
            continue
        files = ", ".join(f"`{d['filename']}`" for d in sorted(matching, key=lambda d: d["filename"]))
        lines += ["", f"#### {notice['title']}", "", f"Applies to {files}.", "",
                  _fill(notice, matching)]
    return (["", "### Source notices"] + lines) if lines else []


def render(catalog: dict) -> str:
    dicts = sorted(catalog["dictionaries"], key=lambda d: d["displayName"].lower())
    lines: list[str] = [BEGIN, "",
                        "<!-- Generated by preset-dicts/scripts/gen_third_party_notices.py "
                        "from preset-dicts/preset-dictionaries.json. Do not edit by hand. -->",
                        ""]

    lines.append(f"{len(dicts)} preset dictionaries are compiled from the open data "
                 "sources below. OpenMDict converted each of them to MDict and modified "
                 "it (reformatted as HTML, lookup keys and redirects added); each `.mdx` "
                 "names its source, copyright holders, license and modifications in its "
                 "description, which the app shows in the dictionary's info screen. "
                 "License ids are SPDX identifiers; `LicenseRef-*` ids are explained "
                 "under *License texts*.")
    lines.append("")
    lines.append("| Dictionary | File | License (SPDX) | Source / attribution |")
    lines.append("|---|---|---|---|")
    used_ids: set[str] = set()
    for d in dicts:
        holder, url = attribution(d["dataSource"])
        src = f"[{md_escape(holder)}]({url})" if url else md_escape(holder)
        lic = md_escape(d["license"])
        if d.get("licenseNote"):
            lic += " ([note](#license-notes))"
        used_ids.update(license_ids(d["license"]))
        lines.append(f"| {md_escape(d['displayName'])} | `{d['filename']}` | {lic} | {src} |")

    notes = [(d["displayName"], d["licenseNote"]) for d in dicts if d.get("licenseNote")]
    if notes:
        lines += ["", "### License notes", ""]
        for name, note in notes:
            lines.append(f"- **{md_escape(name)}** -- {md_escape(note)}")

    lines += render_source_notices(dicts)

    lines += ["", "### License texts", ""]
    unknown = sorted(i for i in used_ids if i not in LICENSES)
    if unknown:
        raise SystemExit(f"ERROR: no LICENSES row for {unknown} -- add it to "
                         f"{Path(__file__).name}")
    for lid in sorted(used_ids):
        name, url = LICENSES[lid]
        line = f"- `{lid}` -- {name}" + (f": <{url}>" if url else "")
        if (LICENSES_DIR / f"LICENSE-{lid}.txt").is_file():
            line += f" (text: `preset-dicts/licenses/LICENSE-{lid}.txt`)"
        lines.append(line)

    lines += ["",
              "Every GitHub Release that hosts dictionary assets also carries this "
              "file and a `LICENSE-<id>.txt` with the full text of each license above "
              "(public domain has none): `scripts/publish-assets.sh` attaches the "
              "whole compliance payload to each new Release, including files that "
              "did not change since an earlier one. `preset-dicts/assets.lock.json` "
              "records the Release (tag) each asset was last published under.",
              "",
              "Dictionaries under `GPL-3.0-or-later` (FreeDict, GCIDE; FreeDict "
              "also under `AGPL-3.0-or-later`, which upstream applies to the "
              "ding2tei-haskell part of its combined work) are distributed as "
              "compiled `.mdx` files. Their corresponding source consists of the "
              "upstream source archives — `freedict-eng-deu.src.tar.xz`, "
              "`freedict-deu-eng.src.tar.xz` and `gcide-0.53.tar.xz`, attached to "
              "the GitHub Release that carries the `.mdx` files; FreeDict's own "
              "source form is in turn the Ding dictionary (GPLv2+) and "
              "ding2tei-haskell (AGPLv3+), which its TEI header names — together "
              "with OpenMDict's conversion scripts (`preset-dicts/scripts/`, "
              "`preset-dicts/Makefile`) at the commit that built the files.",
              "", END]
    return "\n".join(lines) + "\n"


def splice(existing: str, block: str) -> str:
    """Replace the marker block in `existing` (or append it)."""
    b, e = existing.find(BEGIN), existing.find(END)
    if b == -1 or e == -1 or e < b:
        sep = "" if existing.endswith("\n\n") else ("\n" if existing.endswith("\n") else "\n\n")
        return existing + sep + block
    e_end = e + len(END)
    # swallow the newline that followed END so the block stays tidy
    if existing[e_end:e_end + 1] == "\n":
        e_end += 1
    return existing[:b] + block + existing[e_end:]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", type=Path, default=CATALOG_PATH)
    ap.add_argument("--notices", type=Path, default=NOTICES_PATH)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the notices file is out of date instead of writing")
    ap.add_argument("--stdout", action="store_true",
                    help="print the generated block and exit")
    args = ap.parse_args()

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    block = render(catalog)

    if args.stdout:
        sys.stdout.write(block)
        return 0

    existing = args.notices.read_text(encoding="utf-8") if args.notices.exists() else ""
    updated = splice(existing, block)
    if args.check:
        if updated != existing:
            print(f"{args.notices.name} is out of date; run "
                  f"python3 preset-dicts/scripts/{Path(__file__).name}", file=sys.stderr)
            return 1
        print(f"{args.notices.name} is up to date")
        return 0

    if updated == existing:
        print(f"{args.notices.name}: no change ({len(catalog['dictionaries'])} dictionaries)")
    else:
        args.notices.write_text(updated, encoding="utf-8")
        print(f"wrote {args.notices} ({len(catalog['dictionaries'])} dictionaries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
