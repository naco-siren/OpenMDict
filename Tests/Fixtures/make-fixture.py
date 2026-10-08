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

    for f in ("tiny.mdx", "tiny.mdd"):
        print(f"{f}: {os.path.getsize(HERE / f)} bytes")


if __name__ == "__main__":
    main()
