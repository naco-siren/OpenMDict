#!/usr/bin/env python3
"""
Generate the "Licenses" pages of the app's Settings.bundle.

The app's page in the iOS Settings app ends with an "About" group: a
"Licenses" row and a footer naming the app's license and source code. The
Licenses page lists the third-party software, the embedding model, the
preset dictionaries and the full license texts; every row opens a page
with the text. The pages are generated from these files, so
`make -C preset-dicts notices` regenerates them and
`make -C preset-dicts check-notices` fails when they are stale:

    LICENSE                   OpenMDict's own license
    THIRD-PARTY-NOTICES.md    software, model and dictionary notices
    preset-dicts/licenses/    license texts the dictionary notices quote
    licenses/                 the standard SPDX texts (LICENSE-<id>.txt)

Output (inside Apps/iOS/OpenMDict-iOS/OpenMDict-iOS/Settings.bundle/):

    Licenses.plist            the list (strings table "Licenses")
    Licenses/<slug>.plist     one page per row

Root.plist and the localized Root.strings / Licenses.strings are edited by
hand; this script checks that Root.plist links the Licenses page, that every
language has the strings the list uses, and that the About footer names the
source code URL.

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

# Sections of THIRD-PARTY-NOTICES.md this script knows. A new section must
# be added here (and shown, or deliberately left out) before the pages can
# be generated, so nothing is dropped silently.
KNOWN_H2 = {
    "Software": "shown",
    "Machine-learning model": "shown",
    "Artwork": "not shown: original work of this project, dedicated to the public domain",
    "Preset dictionaries": "shown",
}
KNOWN_H3_PRESETS = {"License notes", "Source notices", "License texts"}

# Licenses used by components other than the dictionaries; also listed in
# EXTRA_SPDX_IDS in scripts/publish-assets.sh. Each must be named in the
# section that uses it.
EXTRA_LICENSES = (("Apache-2.0", "Apache License 2.0", "Machine-learning model"),)

# Short row titles for the license texts (a Settings row shows one line;
# the full names of the two CC BY-SA licenses are cut to the same prefix).
SHORT_LICENSE_NAMES = {
    "AGPL-3.0-or-later": "GNU AGPL v3.0 or later",
    "Apache-2.0": "Apache License 2.0",
    "CC-BY-4.0": "CC BY 4.0",
    "CC-BY-SA-3.0": "CC BY-SA 3.0",
    "CC-BY-SA-4.0": "CC BY-SA 4.0",
    "GFDL-1.3-or-later": "GNU FDL v1.3 or later",
    "GPL-3.0-or-later": "GNU GPL v3.0 or later",
    "LicenseRef-WordNet-3.0": "WordNet 3.0 License",
    "Unicode-3.0": "Unicode License v3",
}

# A Settings footer is one label; very long labels are split into several
# footers so no single label becomes taller than the device can render.
FOOTER_LIMIT = 3000


def fail(message: str) -> None:
    raise SystemExit(f"gen-settings-licenses: {message}")


# ── Markdown → plain text (the Settings app shows plain text) ─────

_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_AUTOLINK = re.compile(r"<(https?://[^>]+)>")
_HEADING = re.compile(r"^#{1,6}(?:\s|$)")
_BULLET = re.compile(r"^(?:[-*]|\d+[.)]) ")


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
    text = re.sub(r"(?<![\w*\\])\*([^*\s][^*]*)\*(?![\w*])", r"\1", text)
    text = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|])", r"\1", text)
    return text


_LIST_ITEM = re.compile(r"^\s*(?:[-*•]|\(?[0-9a-zA-Z]{1,3}[.)]|§)\s")


def _join(lines: list[str]) -> str:
    out = lines[0].strip()
    for line in lines[1:]:
        # a word hyphenated at the end of a wrapped line is joined back
        out += ("" if re.search(r"[A-Za-z]-$", out) else " ") + line.strip()
    return out


def reflow(text: str) -> str:
    """Join the hard-wrapped lines of prose paragraphs (license files wrap at
    ~80 columns, which leaves ragged lines on a phone). Each list item of a
    paragraph is joined on its own; headings and short lines keep their
    line breaks, and indentation is dropped."""
    def join_block(lines: list[str]) -> str:
        widths = [len(l.rstrip()) for l in lines]
        wrapped = (len(lines) > 1 and max(widths) >= 60
                   and all(w >= 0.5 * max(widths) for w in widths[:-1]))
        return _join(lines) if wrapped else "\n".join(l.strip() for l in lines)

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
    """Paragraphs joined into single lines; code blocks and quotes reflowed
    with reflow(); list items one per line. Fails on Markdown it does not
    support (tables, raw HTML) instead of passing it through."""
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
        stripped = line.strip()
        if not stripped.startswith(">") or in_code:
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
        if not stripped:
            flush()
            out.append("")
        elif stripped.startswith(">"):
            flush()
            quote.append(_inline(stripped[1:].strip()))
        elif _BULLET.match(stripped):
            flush()
            item = re.sub(r"^[-*] ", "", stripped)
            out.append(("• " if stripped[0] in "-*" else "") + _inline(item.replace(" -- ", ": ")))
        elif line[:1].isspace() and out and out[-1].startswith("• ") and not para:
            out[-1] += " " + _inline(stripped)                 # wrapped bullet
        elif _HEADING.match(stripped):
            flush()
        elif stripped.startswith("|") or (stripped.startswith("<") and not _AUTOLINK.match(stripped)):
            fail(f"THIRD-PARTY-NOTICES.md: unsupported Markdown for the Settings pages: {stripped[:60]!r}")
        else:
            para.append(stripped)
    flush()
    flush_quote()
    text = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


# ── THIRD-PARTY-NOTICES.md sections ───────────────────────────────

def _code_spans(md: str) -> list[tuple[int, int]]:
    fences = [m.start() for m in re.finditer(r"^```", md, re.M)]
    return list(zip(fences[0::2], fences[1::2]))


def sections(md: str, level: int) -> list[tuple[str, str]]:
    """(heading, body) for every heading of exactly `level` #'s outside
    fenced code."""
    spans = _code_spans(md)

    def outside(pos: int) -> bool:
        return not any(a <= pos <= b for a, b in spans)

    heads = [m for m in re.finditer(rf"^{'#' * level} (.+)$", md, re.M) if outside(m.start())]
    ends = [m.start() for m in re.finditer(rf"^#{{1,{level}}} ", md, re.M) if outside(m.start())]
    result = []
    for m in heads:
        end = next((e for e in ends if e > m.start()), len(md))
        result.append((m.group(1).strip(), md[m.end():end]))
    return result


def section(md: str, level: int, title: str) -> str:
    for heading, body in sections(md, level):
        if heading == title or heading.startswith(title + " "):
            return body
    fail(f"THIRD-PARTY-NOTICES.md: no {'#' * level} {title!r} section")
    return ""


def short_name(heading: str) -> str:
    """'lzokay (decoder structure for …)' → 'lzokay'."""
    return re.sub(r"\s*\(.*\)$", "", heading).strip()


def license_ids(license_list: str) -> list[tuple[str, str]]:
    """[(spdx id, full name)] from the "License texts" bullets."""
    ids = re.findall(r"^- `([^`]+)` -- ([^:\n]+?)(?::\s|\s\(text:|$)", license_list, re.M)
    if not ids:
        fail("THIRD-PARTY-NOTICES.md: no license ids under ### License texts")
    return [(spdx, name.strip()) for spdx, name in ids]


def dictionary_list(preset_md: str, ids: list[tuple[str, str]]) -> str:
    # the reader-facing introduction is the generated block's first paragraph,
    # not the maintainer note above it
    after_marker = preset_md.split("<!-- BEGIN GENERATED", 1)[-1].split("-->", 1)[-1]
    intro = after_marker.split("| Dictionary |")[0]
    table = [l for l in preset_md.splitlines() if l.startswith("| ") and "`" in l]
    rows = re.findall(r"^\| (.+?) \| `([^`]+)` \| (.+?) \| (.+?) \|$", "\n".join(table), re.M)
    if not rows or len(rows) != len(table):
        fail(f"THIRD-PARTY-NOTICES.md: parsed {len(rows)} of {len(table)} dictionary table rows")
    lines = [md_to_text(intro), ""]
    for name, file, lic, source in rows:
        lic = re.sub(r"\s*\(\[note\]\(#license-notes\)\)", " (see the license notes)", lic)
        lines += [f"{_inline(name)} ({file})", f"License: {_inline(lic)}", f"Source: {_inline(source)}", ""]
    lines += ["License texts", ""]   # the introduction refers to this heading
    lines += [f"{spdx}: {name}" for spdx, name in ids]
    notes = section(preset_md, 3, "License notes")
    lines += ["", "License notes", "", md_to_text(notes)]
    return "\n".join(lines).strip()


def license_text(spdx: str) -> Path:
    for d in LICENSE_DIRS:
        path = d / f"LICENSE-{spdx}.txt"
        if path.exists():
            return path
    fail(f"no LICENSE-{spdx}.txt in " + " or ".join(str(d.relative_to(REPO)) for d in LICENSE_DIRS)
         + f"; add the SPDX text as licenses/LICENSE-{spdx}.txt "
         f"(https://raw.githubusercontent.com/spdx/license-list-data/main/text/{spdx}.txt)")
    return Path()


# ── Plists ────────────────────────────────────────────────────────

def text_page(text: str) -> dict:
    chunks: list[str] = []
    for para in text.split("\n\n"):
        if chunks and len(chunks[-1]) + 2 + len(para) <= FOOTER_LIMIT:
            chunks[-1] += "\n\n" + para
        else:
            chunks.append(para)
    return {"PreferenceSpecifiers": [{"Type": "PSGroupSpecifier", "FooterText": c} for c in chunks]}


def slug(name: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-")
    if not s:
        fail(f"cannot derive a page file name from {name!r}; give the section an ASCII name")
    return s


def build() -> dict[str, bytes]:
    md = NOTICES.read_text(encoding="utf-8")
    for heading, _ in sections(md, 2):
        if heading not in KNOWN_H2:
            fail(f"THIRD-PARTY-NOTICES.md: ## {heading} is not handled; add it to KNOWN_H2")
    software = section(md, 2, "Software")
    model = section(md, 2, "Machine-learning model")
    presets = section(md, 2, "Preset dictionaries")
    for heading, _ in sections(presets, 3):
        if heading not in KNOWN_H3_PRESETS:
            fail(f"THIRD-PARTY-NOTICES.md: ### {heading} is not handled; add it to KNOWN_H3_PRESETS")
    notices = section(presets, 3, "Source notices")
    license_list = section(presets, 3, "License texts")
    ids = license_ids(license_list)

    pages: dict[str, dict] = {}
    owners: dict[str, str] = {}
    groups: list[tuple[str, list[tuple[str, str]], str | None]] = []

    def add(name: str, text: str, key: str | None = None) -> tuple[str, str]:
        file = f"{PAGES_DIR}/{slug(name)}"
        if file in pages:
            fail(f"{name!r} and {owners[file]!r} would both be written to {file}.plist")
        pages[file] = text_page(text)
        owners[file] = name
        return (key or name, file)

    rows = [add("OpenMDict", reflow(LICENSE.read_text(encoding="utf-8").strip()) + f"\n\nSource code: {SOURCE_URL}")]
    for heading, body in sections(software, 3):
        rows.append(add(short_name(heading), md_to_text(body)))
    groups.append(("LICENSES_SOFTWARE", rows, None))

    rows = [add(short_name(h), md_to_text(b)) for h, b in sections(model, 3)]
    groups.append(("LICENSES_MODEL", rows, None))

    rows = [add("Dictionary List", dictionary_list(presets, ids), "LICENSES_DICTIONARY_LIST")]
    for heading, body in sections(notices, 4):
        rows.append(add(heading, md_to_text(body)))
    gpl_text = "\n\n".join(p for p in license_list.split("\n\n") if "corresponding source" in p.lower())
    if not gpl_text:
        fail("THIRD-PARTY-NOTICES.md: the corresponding-source paragraph was not found")
    rows.append(add("Corresponding Source", md_to_text(gpl_text), "LICENSES_CORRESPONDING_SOURCE"))
    groups.append(("LICENSES_DICTIONARIES", rows, None))

    texts = [(spdx, name) for spdx, name in ids if spdx != "LicenseRef-Public-Domain"]
    for spdx, name, used_in in EXTRA_LICENSES:
        if name not in section(md, 2, used_in):
            fail(f"THIRD-PARTY-NOTICES.md: ## {used_in} no longer names {name}; update EXTRA_LICENSES")
        if spdx not in {s for s, _ in texts}:
            texts.append((spdx, name))
    rows = []
    for spdx, name in texts:
        title = SHORT_LICENSE_NAMES.get(spdx, spdx)
        body = f"{name} ({spdx})\n\n" + reflow(license_text(spdx).read_text(encoding="utf-8").strip())
        rows.append(add(title, body))
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


# ── Checks of the hand-edited parts ───────────────────────────────

def _strings_keys(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    return dict(re.findall(r'^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M))


def check_hand_edited(index: dict) -> list[str]:
    problems = []
    root = plistlib.loads((BUNDLE / "Root.plist").read_bytes())
    if not any(s.get("File") == PAGES_DIR for s in root["PreferenceSpecifiers"]):
        problems.append(f"Root.plist has no child pane with File = {PAGES_DIR}")
    needed = {v for s in index["PreferenceSpecifiers"] for k, v in s.items()
              if k in ("Title", "FooterText") and v.startswith("LICENSES_")}
    for lproj in sorted(BUNDLE.glob("*.lproj")):
        strings = lproj / "Licenses.strings"
        keys = _strings_keys(strings) if strings.exists() else {}
        missing = sorted(needed - set(keys))
        if missing:
            problems.append(f"{lproj.name}/Licenses.strings lacks {', '.join(missing)}")
        footer = _strings_keys(lproj / "Root.strings").get("ABOUT_FOOTER", "")
        if SOURCE_URL not in footer:
            problems.append(f"{lproj.name}/Root.strings: ABOUT_FOOTER does not contain {SOURCE_URL}")
    return problems


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--check", action="store_true", help="fail if the generated plists are stale")
    args = ap.parse_args()

    files = build()
    problems = check_hand_edited(plistlib.loads(files["Licenses.plist"]))
    pages_dir = BUNDLE / PAGES_DIR
    existing = {str(p.relative_to(BUNDLE)) for p in pages_dir.rglob("*") if p.is_file()} if pages_dir.exists() else set()
    changed = [n for n, data in files.items() if (BUNDLE / n).exists() and (BUNDLE / n).read_bytes() != data]
    missing = [n for n in files if not (BUNDLE / n).exists()]
    unexpected = sorted(existing - set(files))
    if args.check:
        if changed or missing or unexpected or problems:
            print("Settings.bundle licenses are stale (run scripts/gen-settings-licenses.py):", file=sys.stderr)
            for label, names in (("changed", changed), ("missing", missing), ("unexpected", unexpected)):
                for n in names:
                    print(f"  {label}: {n}", file=sys.stderr)
            for p in problems:
                print(f"  {p}", file=sys.stderr)
            sys.exit(1)
        print(f"Settings.bundle licenses are up to date ({len(files) - 1} pages)")
        return
    if problems:
        fail("; ".join(problems))
    pages_dir.mkdir(exist_ok=True)
    for name, data in files.items():
        (BUNDLE / name).write_bytes(data)
    for name in unexpected:
        (BUNDLE / name).unlink()
    print(f"wrote Settings.bundle/Licenses.plist and {len(files) - 1} pages"
          + (f", removed {len(unexpected)}" if unexpected else ""))


if __name__ == "__main__":
    main()
