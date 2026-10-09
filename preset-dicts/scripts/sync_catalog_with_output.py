#!/usr/bin/env python3
"""Sync preset-dictionaries.json with the .mdx files actually present in output/.

The catalog is normally regenerated from .meta.json sidecars by
generate_preset_catalog.py, but the sidecars describe whichever build last
ran — not necessarily the .mdx that is checked in / shipped.  This script
makes the catalog describe the files on disk:

  * sizeBytes  <- os.path.getsize(output/<Name>/<Name>.mdx)
  * entries    <- key count reported by the `openmdict` CLI (optional,
                  pass --openmdict /path/to/openmdict)

It fails if any catalog entry has no .mdx on disk, and it refreshes
output/manifest.json (a copy kept next to the built dictionaries).

Usage:
    python3 scripts/sync_catalog_with_output.py [--openmdict PATH] [--check]
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / "preset-dictionaries.json"
OUTPUT_DIR = ROOT / "output"
MANIFEST_COPY = OUTPUT_DIR / "manifest.json"

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def mdx_path(filename: str) -> Path:
    return OUTPUT_DIR / Path(filename).stem / filename


def count_entries(openmdict: Path, mdx: Path) -> int:
    out = subprocess.run([str(openmdict), str(mdx)], capture_output=True,
                         text=True, check=True).stdout
    for line in ANSI_RE.sub("", out).splitlines():
        if line.strip().startswith("Entries:"):
            return int(line.split(":", 1)[1].strip())
    raise RuntimeError(f"no 'Entries:' line in openmdict output for {mdx}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--openmdict", type=Path,
                    help="path to the openmdict CLI; when given, `entries` is refreshed too")
    ap.add_argument("--check", action="store_true",
                    help="report drift and exit 1 instead of writing")
    args = ap.parse_args()

    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    dicts = catalog["dictionaries"]

    missing = [d["filename"] for d in dicts if not mdx_path(d["filename"]).is_file()]
    if missing:
        print("ERROR: catalog entries without an .mdx in output/:", file=sys.stderr)
        for f in missing:
            print(f"  {f}", file=sys.stderr)
        return 1

    changes = []
    for d in dicts:
        mdx = mdx_path(d["filename"])
        size = mdx.stat().st_size
        if d.get("sizeBytes") != size:
            changes.append((d["filename"], "sizeBytes", d.get("sizeBytes"), size))
            d["sizeBytes"] = size
        if args.openmdict:
            n = count_entries(args.openmdict, mdx)
            if d.get("entries") != n:
                changes.append((d["filename"], "entries", d.get("entries"), n))
                d["entries"] = n

    for filename, field, old, new in changes:
        print(f"  {filename:28s} {field:9s} {old} -> {new}")
    print(f"{len(changes)} field(s) differ across {len(dicts)} dictionaries")

    if args.check:
        return 1 if changes else 0

    text = json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"
    CATALOG_PATH.write_text(text, encoding="utf-8")
    MANIFEST_COPY.write_text(text, encoding="utf-8")
    print(f"wrote {CATALOG_PATH.name} and output/{MANIFEST_COPY.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
