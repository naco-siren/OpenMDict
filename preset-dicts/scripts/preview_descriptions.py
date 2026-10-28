#!/usr/bin/env python3
"""
Write every preset's header description without building anything.

Each build script exposes ``descriptions() -> dict[str, str]`` mapping
``<Name>.mdx`` to the HTML its build stamps into the MDX header. This
tool imports the scripts, collects those descriptions and writes

    <out>/<Name>.html      one file per dictionary (the raw HTML)
    <out>/index.html       all of them on one page, styled roughly like
                           the app's dictionary info screen
    <out>/index.json       {"<Name>.mdx": {"script": …, "length": …}}

Usage:
    python3 scripts/preview_descriptions.py --out /tmp/descriptions
    python3 scripts/preview_descriptions.py --out … --only bible wikdict
"""

from __future__ import annotations

import argparse
import html
import importlib
import json
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

MODULES = [
    "build_wordnet_mdx", "build_moby_thesaurus_mdx", "build_cedict_mdx",
    "build_jmdict_mdx", "build_gcide_mdx", "build_kanjidic2_mdx",
    "build_unihan_mdx", "build_perseus_mdx", "build_cccanto_mdx",
    "build_bible_mdx", "build_freedict_mdx", "build_kaikki_mdx",
    "build_wikdict_mdx", "build_wiktionary_mdx",
]

PAGE_CSS = """
body { font-family: -apple-system, 'Helvetica Neue', sans-serif; margin: 0;
       background: #f2f2f7; color: #1c1c1e; }
header { padding: 20px 24px 8px; }
nav { padding: 0 24px 16px; font-size: 13px; line-height: 1.8; }
nav a { margin-right: 10px; white-space: nowrap; }
.card { background: #fff; border-radius: 12px; margin: 0 16px 16px;
        padding: 14px 16px; max-width: 760px; }
.card h2 { font-size: 15px; margin: 0 0 6px; }
.card .file { font-size: 12px; color: #8e8e93; font-family: ui-monospace, monospace; }
.desc { font-size: 15px; color: #8e8e93; line-height: 1.4; }
.desc p { margin: 0 0 10px; }
.desc small { font-size: 12px; }
.desc a { color: #8e8e93; text-decoration: underline; }
"""


def collect(only: set[str] | None) -> tuple[dict[str, str], dict[str, dict]]:
    descriptions: dict[str, str] = {}
    index: dict[str, dict] = {}
    failed: list[str] = []
    for module_name in MODULES:
        short = module_name.removeprefix("build_").removesuffix("_mdx")
        if only and short not in only and module_name not in only:
            continue
        try:
            module = importlib.import_module(module_name)
            if not hasattr(module, "descriptions"):
                raise AttributeError("no descriptions()")
            found = module.descriptions()
        except Exception as exc:  # a missing data file must not hide the other scripts
            print(f"  ! {module_name}: {type(exc).__name__}: {exc}", file=sys.stderr)
            failed.append(module_name)
            continue
        for filename, desc in sorted(found.items()):
            if filename in descriptions:
                raise SystemExit(f"{filename} described by two scripts")
            descriptions[filename] = desc
            index[filename] = {"script": f"{module_name}.py", "length": len(desc)}
        print(f"  {module_name}: {len(found)}")
    if failed:
        print(f"  {len(failed)} script(s) failed: {', '.join(failed)}", file=sys.stderr)
    return descriptions, index


def write(out: Path, descriptions: dict[str, str], index: dict[str, dict]) -> None:
    out.mkdir(parents=True, exist_ok=True)
    cards = []
    links = []
    for filename in sorted(descriptions):
        name = filename.removesuffix(".mdx")
        (out / f"{name}.html").write_text(descriptions[filename], encoding="utf-8")
        links.append(f'<a href="#{name}">{html.escape(name)}</a>')
        cards.append(
            f'<section class="card" id="{name}"><h2>{html.escape(name)}</h2>'
            f'<div class="file">{html.escape(filename)} · {len(descriptions[filename])} chars</div>'
            f'<div class="desc">{descriptions[filename]}</div></section>'
        )
    page = (
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        f"<title>Preset descriptions</title><style>{PAGE_CSS}</style></head><body>"
        f"<header><h1>Preset dictionary descriptions</h1>"
        f"<p>{len(descriptions)} dictionaries, as the build stamps them into the MDX header.</p></header>"
        f"<nav>{''.join(links)}</nav>{''.join(cards)}</body></html>"
    )
    (out / "index.html").write_text(page, encoding="utf-8")
    (out / "index.json").write_text(json.dumps(index, indent=1, ensure_ascii=False) + "\n",
                                    encoding="utf-8")
    print(f"{len(descriptions)} descriptions written to {out}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--only", nargs="*", help="script short names, e.g. bible wikdict")
    args = parser.parse_args()
    descriptions, index = collect(set(args.only) if args.only else None)
    write(args.out, descriptions, index)


if __name__ == "__main__":
    main()
