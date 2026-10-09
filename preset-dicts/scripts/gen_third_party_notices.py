#!/usr/bin/env python3
"""Generate the preset-dictionary table in THIRD-PARTY-NOTICES.md.

Reads preset-dictionaries.json and rewrites the block between

    <!-- BEGIN GENERATED: preset dictionaries -->
    <!-- END GENERATED: preset dictionaries -->

in ../THIRD-PARTY-NOTICES.md (repository root). Everything outside the
markers is hand-maintained and left untouched. If the markers are
missing, the block is appended to the end of the file.

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

ROOT = Path(__file__).resolve().parent.parent          # preset-dicts/
REPO_ROOT = ROOT.parent                                # repository root
CATALOG_PATH = ROOT / "preset-dictionaries.json"
NOTICES_PATH = REPO_ROOT / "THIRD-PARTY-NOTICES.md"

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
    ("WikDict", "WikDict (data derived from Wiktionary)", "https://www.wikdict.com/"),
    ("Kaikki.org", "Kaikki.org / Wiktextract (English Wiktionary extract)", "https://kaikki.org/dictionary/"),
    ("Open Bibles", "Public-domain Bible texts (open-bibles collection, eBible.org)", "https://github.com/seven1m/open-bibles"),
    ("eBible.org", "eBible.org", "https://ebible.org/"),
    ("Perseus Digital Library", "Perseus Digital Library, Tufts University", "https://github.com/PerseusDL/lexica"),
    ("Open English WordNet", "Open English WordNet (Global WordNet Association); derived from Princeton WordNet", "https://en-word.net/"),
    ("GCIDE", "GNU Collaborative International Dictionary of English", "https://gcide.gnu.org.ua/"),
    ("CC-CEDICT", "CC-CEDICT (MDBG)", "https://cc-cedict.org/"),
    ("CC-Canto", "CC-Canto (Pleco Inc.)", "https://cantonese.org/"),
    ("JMdict", "JMdict (EDRDG); pitch accents from Kanjium", "https://www.edrdg.org/jmdict/"),
    ("KANJIDIC2", "KANJIDIC2 (EDRDG)", "https://www.edrdg.org/wiki/index.php/KANJIDIC_Project"),
    ("FreeDict", "FreeDict", "https://freedict.org/"),
    ("Moby Thesaurus", "Moby Thesaurus II (Grady Ward), via Project Gutenberg #3202", "https://www.gutenberg.org/ebooks/3202"),
    ("Unicode Unihan", "Unicode Unihan Database (Unicode, Inc.)", "https://www.unicode.org/charts/unihan.html"),
    ("Wiktionary (English edition)", "English Wiktionary (Wikimedia Foundation), via Wiktionary-Dictionaries TSV", "https://github.com/Vuizur/Wiktionary-Dictionaries"),
    ("English Wiktionary", "English Wiktionary (Wikimedia Foundation), via Wiktionary-Dictionaries TSV", "https://github.com/Vuizur/Wiktionary-Dictionaries"),
]

# ── License id → (display name, URL) ─────────────────────────────

LICENSES: dict[str, tuple[str, str]] = {
    "CC-BY-SA-3.0": ("Creative Commons Attribution-ShareAlike 3.0 Unported", "https://creativecommons.org/licenses/by-sa/3.0/"),
    "CC-BY-SA-4.0": ("Creative Commons Attribution-ShareAlike 4.0 International", "https://creativecommons.org/licenses/by-sa/4.0/"),
    "CC-BY-4.0": ("Creative Commons Attribution 4.0 International", "https://creativecommons.org/licenses/by/4.0/"),
    "GPL-3.0-or-later": ("GNU General Public License v3.0 or later", "https://www.gnu.org/licenses/gpl-3.0.html"),
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


def render(catalog: dict) -> str:
    dicts = sorted(catalog["dictionaries"], key=lambda d: d["displayName"].lower())
    lines: list[str] = [BEGIN, "",
                        "<!-- Generated by preset-dicts/scripts/gen_third_party_notices.py "
                        "from preset-dicts/preset-dictionaries.json. Do not edit by hand. -->",
                        ""]

    lines.append(f"{len(dicts)} preset dictionaries are compiled from the open data "
                 "sources below. Each `.mdx` embeds the same attribution in its "
                 "description. License ids are SPDX identifiers; `LicenseRef-*` "
                 "ids are explained under *License texts*.")
    lines.append("")
    lines.append("| Dictionary | File | License (SPDX) | Source / attribution |")
    lines.append("|---|---|---|---|")
    used_ids: set[str] = set()
    for d in dicts:
        holder, url = attribution(d["dataSource"])
        src = f"[{md_escape(holder)}]({url})" if url else md_escape(holder)
        lic = md_escape(d["license"])
        note = d.get("licenseNote")
        if note:
            lic += f" ([note](#license-notes))"
        used_ids.update(license_ids(d["license"]))
        lines.append(f"| {md_escape(d['displayName'])} | `{d['filename']}` | {lic} | {src} |")

    notes = [(d["displayName"], d["licenseNote"]) for d in dicts if d.get("licenseNote")]
    if notes:
        lines += ["", "### License notes", ""]
        for name, note in notes:
            lines.append(f"- **{md_escape(name)}** -- {md_escape(note)}")

    lines += ["", "### License texts", ""]
    unknown = sorted(i for i in used_ids if i not in LICENSES)
    if unknown:
        raise SystemExit(f"ERROR: no LICENSES row for {unknown} -- add it to "
                         f"{Path(__file__).name}")
    for lid in sorted(used_ids):
        name, url = LICENSES[lid]
        lines.append(f"- `{lid}` -- {name}" + (f": <{url}>" if url else ""))

    lines += ["",
              "Dictionaries under `GPL-3.0-or-later` (FreeDict, GCIDE) are "
              "distributed as compiled `.mdx` files; the corresponding source "
              "archives (`freedict-eng-deu.src.tar.xz`, "
              "`freedict-deu-eng.src.tar.xz`, `gcide-0.53.tar.xz`) are attached "
              "to the same GitHub Release that hosts the dictionary assets, "
              "as required by GPLv3 section 6.",
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
