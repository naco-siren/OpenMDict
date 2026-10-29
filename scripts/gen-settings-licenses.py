#!/usr/bin/env python3
"""
Generate the "Licenses" pages of the app's Settings.bundle.

The app's page in the iOS Settings app ends with an "About" group: a
"Licenses" row and a footer naming the app's license and source code. The
Licenses page lists the third-party software, the embedding model, the
preset dictionaries and the full license texts; every row opens a page
with the text. All of it comes from files kept elsewhere in the repository,
so it cannot drift:

    LICENSE                          OpenMDict's own license
    THIRD-PARTY-NOTICES.md           software, model and dictionary notices
    preset-dicts/licenses/, licenses/       full license texts (LICENSE-<id>.txt):
                                     the first holds the texts the dictionary
                                     notices quote, the second the standard
                                     SPDX texts

Output (inside Apps/iOS/OpenMDict-iOS/OpenMDict-iOS/Settings.bundle/):

    Licenses.plist                   the list (strings table "Licenses")
    Licenses/<slug>.plist            one page per row

Root.plist and the localized Root.strings / Licenses.strings are edited by
hand; this script only checks that Root.plist links the Licenses page.

Usage:
    python3 scripts/gen-settings-licenses.py           # write the plists
    python3 scripts/gen-settings-licenses.py --check   # fail if they are stale
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUNDLE = REPO / "Apps/iOS/OpenMDict-iOS/OpenMDict-iOS/Settings.bundle"
NOTICES = REPO / "THIRD-PARTY-NOTICES.md"
LICENSE = REPO / "LICENSE"
LICENSE_DIRS = (REPO / "preset-dicts/licenses", REPO / "licenses")
SOURCE_URL = "https://github.com/naco-siren/OpenMDict"
PAGES_DIR = "Licenses"


# ── Markdown → plain text (the Settings app shows plain text) ─────

_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_AUTOLINK = re.compile(r"<(https?://[^>]+)>")


def _inline(text: str) -> str:
    def link(m: re.Match) -> str:
        label, url = m.group(1), m.group(2)
        if url.startswith("#"):                       # in-page anchor
            return label
        bare = re.sub(r"^https?://", "", url).rstrip("/")
        if label in (url, bare) or label.rstrip("/") == bare:
            return url
        return f"{label} ({url})"
    text = _LINK.sub(link, text)
    text = _AUTOLINK.sub(r"\1", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])", r"\1", text)
    return text


_LIST_ITEM = re.compile(r"^\s*(?:[-*•]|\(?[0-9a-zA-Z]{1,3}[.)]|§)\s")


def reflow(text: str) -> str:
    """Join the hard-wrapped lines of prose paragraphs (license files wrap at
    ~80 columns, which leaves ragged lines on a phone). Each list item of a
    paragraph is joined on its own; headings and short lines keep their
    line breaks, and indentation is dropped."""
    def join_block(lines: list[str]) -> str:
        widths = [len(l.rstrip()) for l in lines]
        wrapped = (len(lines) > 1 and max(widths) >= 60
                   and all(w >= 0.5 * max(widths) for w in widths[:-1]))
        if wrapped:
            return " ".join(l.strip() for l in lines)
        return "\n".join(l.strip() for l in lines)

    out = []
    for para in re.split(r"\n[ \t]*\n", text.strip("\n")):
        items: list[list[str]] = []
        for line in para.split("\n"):
            if not items or _LIST_ITEM.match(line):
                items.append([line])
            else:
                items[-1].append(line)
        out.append("\n".join(join_block(item) for item in items))
    return "\n\n".join(out)


def md_to_text(md: str) -> str:
    """Paragraphs joined into single lines; code blocks, quotes and list
    items kept line by line."""
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)
    out: list[str] = []
    para: list[str] = []
    code: list[str] = []
    quote: list[str] = []
    in_code = False

    def flush() -> None:
        if para:
            out.append(_inline(" ".join(s.strip() for s in para)))
            para.clear()

    def flush_quote() -> None:
        if quote:
            out.append(reflow("\n".join(quote)))
            quote.clear()

    for line in md.split("\n"):
        if not line.strip().startswith(">") or in_code:
            flush_quote()
        if line.startswith("```"):
            flush()
            if in_code:
                out.append(reflow("\n".join(code)))
            code = []
            in_code = not in_code
            continue
        if in_code:
            code.append(line)
            continue
        stripped = line.strip()
        if not stripped:
            flush()
            out.append("")
        elif stripped.startswith(">"):
            flush()
            quote.append(_inline(stripped[1:].strip()))
            continue
        elif re.match(r"^[-*] ", stripped):
            flush()
            out.append("• " + _inline(stripped[2:].replace(" -- ", " — ")))
        elif stripped.startswith("#"):
            flush()
        else:
            para.append(stripped)
    flush()
    flush_quote()
    text = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


# ── THIRD-PARTY-NOTICES.md sections ───────────────────────────────

def sections(md: str, level: int) -> list[tuple[str, str]]:
    """(heading, body) for every heading of exactly `level` #'s."""
    pat = re.compile(rf"^{'#' * level} (.+)$", re.M)
    found = list(pat.finditer(md))
    result = []
    for i, m in enumerate(found):
        end = len(md)
        # the section ends at the next heading of the same or a higher level
        nxt = re.compile(rf"^#{{1,{level}}} ", re.M).search(md, m.end())
        if nxt:
            end = nxt.start()
        result.append((m.group(1).strip(), md[m.end():end]))
    return result


def section(md: str, level: int, title_prefix: str) -> str:
    for title, body in sections(md, level):
        if title.startswith(title_prefix):
            return body
    raise SystemExit(f"THIRD-PARTY-NOTICES.md: no {'#' * level} heading starting with {title_prefix!r}")


def short_name(heading: str) -> str:
    """'lzokay (decoder structure for …)' → 'lzokay'."""
    return re.sub(r"\s*\(.*\)$", "", heading).strip()


def dictionary_list(preset_md: str) -> str:
    # the reader-facing introduction is the generated block's first paragraph,
    # not the maintainer note above it
    after_marker = preset_md.split("<!-- BEGIN GENERATED", 1)[-1].split("-->", 1)[-1]
    intro = after_marker.split("| Dictionary |")[0]
    rows = re.findall(r"^\| (.+?) \| `([^`]+)` \| (.+?) \| (.+?) \|$", preset_md, re.M)
    lines = [md_to_text(intro), ""]
    for name, file, lic, source in rows:
        lic = re.sub(r"\s*\(\[note\]\(#license-notes\)\)", " (see the notes below)", lic)
        lines += [f"{_inline(name)} — {file}", f"License: {_inline(lic)}", f"Source: {_inline(source)}", ""]
    notes = section(preset_md, 3, "License notes")
    lines += ["License notes", "", md_to_text(notes)]
    return "\n".join(lines).strip()


def license_text(spdx: str) -> Path:
    for d in LICENSE_DIRS:
        path = d / f"LICENSE-{spdx}.txt"
        if path.exists():
            return path
    raise SystemExit(f"no LICENSE-{spdx}.txt in " + " or ".join(str(d.relative_to(REPO)) for d in LICENSE_DIRS))


# ── Plists ────────────────────────────────────────────────────────

def text_page(text: str) -> dict:
    return {"PreferenceSpecifiers": [{"Type": "PSGroupSpecifier", "FooterText": text}]}


def slug(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-")


def build() -> dict[str, bytes]:
    md = NOTICES.read_text(encoding="utf-8")
    software = section(md, 2, "Software")
    model = section(md, 2, "Machine-learning model")
    presets = section(md, 2, "Preset dictionaries")
    notices = section(presets, 3, "Source notices")
    license_list = section(presets, 3, "License texts")

    pages: dict[str, dict] = {}
    groups: list[tuple[str, list[tuple[str, str]], str | None]] = []

    def add(name: str, text: str, key: str | None = None) -> tuple[str, str]:
        file = f"{PAGES_DIR}/{slug(name)}"
        if file in pages:
            raise SystemExit(f"duplicate page {file}")
        pages[file] = text_page(text)
        return (key or name, file)

    rows = [add("OpenMDict", reflow(LICENSE.read_text(encoding="utf-8").strip()) + f"\n\nSource code: {SOURCE_URL}")]
    for heading, body in sections(software, 3):
        rows.append(add(short_name(heading), md_to_text(body)))
    groups.append(("LICENSES_SOFTWARE", rows, None))

    rows = [add(short_name(h), md_to_text(b)) for h, b in sections(model, 3)]
    groups.append(("LICENSES_MODEL", rows, None))

    rows = [add("Dictionary List", dictionary_list(presets), "LICENSES_DICTIONARY_LIST")]
    for heading, body in sections(notices, 4):
        rows.append(add(heading, md_to_text(body)))
    gpl_text = "\n\n".join(p for p in license_list.split("\n\n") if "corresponding source" in p.lower())
    if not gpl_text:
        raise SystemExit("THIRD-PARTY-NOTICES.md: the corresponding-source paragraph was not found")
    rows.append(add("Corresponding Source", md_to_text(gpl_text), "LICENSES_CORRESPONDING_SOURCE"))
    groups.append(("LICENSES_DICTIONARIES", rows, None))

    rows = []
    for spdx, title in re.findall(r"^- `([^`]+)` -- ([^:\n(]+?)(?::| \(|$)", license_list, re.M):
        if spdx == "LicenseRef-Public-Domain":
            continue
        path = license_text(spdx)
        rows.append(add(title.strip(), f"{spdx}\n\n" + reflow(path.read_text(encoding="utf-8").strip())))
    # The embedding model's license is not among the dictionaries' licenses.
    if not any(title.startswith("Apache") for title, _ in rows):
        rows.append(add("Apache License 2.0", "Apache-2.0\n\n" + reflow(license_text("Apache-2.0").read_text(encoding="utf-8").strip())))
    rows.sort(key=lambda r: r[0].lower())
    groups.append(("LICENSES_TEXTS", rows, "LICENSES_TEXTS_FOOTER"))

    specifiers = []
    for title, items, footer in groups:
        group = {"Type": "PSGroupSpecifier", "Title": title}
        if footer:
            group["FooterText"] = footer
        specifiers.append(group)
        for row_title, file in items:
            specifiers.append({"Type": "PSChildPaneSpecifier", "Title": row_title, "File": file})
    index = {"StringsTable": "Licenses", "PreferenceSpecifiers": specifiers}

    files = {"Licenses.plist": plistlib.dumps(index, sort_keys=False)}
    for file, page in pages.items():
        files[f"{file}.plist"] = plistlib.dumps(page, sort_keys=False)
    return files


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--check", action="store_true", help="fail if the generated plists are stale")
    args = ap.parse_args()

    root = plistlib.loads((BUNDLE / "Root.plist").read_bytes())
    if not any(s.get("File") == "Licenses" for s in root["PreferenceSpecifiers"]):
        raise SystemExit("Settings.bundle/Root.plist has no child pane with File = Licenses")

    files = build()
    existing = {str(p.relative_to(BUNDLE)) for p in (BUNDLE / PAGES_DIR).glob("*.plist")} if (BUNDLE / PAGES_DIR).exists() else set()
    stale = [name for name, data in files.items()
             if not (BUNDLE / name).exists() or (BUNDLE / name).read_bytes() != data]
    extra = sorted(existing - set(files))
    if args.check:
        if stale or extra:
            print("Settings.bundle licenses are stale (run scripts/gen-settings-licenses.py):", file=sys.stderr)
            for n in stale + extra:
                print(f"  {n}", file=sys.stderr)
            sys.exit(1)
        print(f"Settings.bundle licenses are up to date ({len(files) - 1} pages)")
        return
    (BUNDLE / PAGES_DIR).mkdir(exist_ok=True)
    for name, data in files.items():
        (BUNDLE / name).write_bytes(data)
    for name in extra:
        (BUNDLE / name).unlink()
    print(f"wrote Settings.bundle/Licenses.plist and {len(files) - 1} pages"
          + (f", removed {len(extra)}" if extra else ""))


if __name__ == "__main__":
    main()
