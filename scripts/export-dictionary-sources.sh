#!/usr/bin/env bash
# Export the public source repository of the GPL/AGPL preset dictionaries
# (FreeDict EN-DE, FreeDict DE-EN, GCIDE) into a checkout of
# https://github.com/naco-siren/OpenMDict-dictionary-sources:
#
#   scripts/export-dictionary-sources.sh <checkout>
#
# The checkout gets the files in preset-dicts/dictionary-sources/, the
# conversion scripts and shared modules as committed here, LICENSE, and the
# build pins and SHA256SUMS of the three dictionaries from build-pins.json
# and preset-dictionaries.json. Then run `make` in the checkout: it must
# rebuild every file byte for byte. See MAINTAINING.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PD="$ROOT/preset-dicts"
DEST="${1:?usage: scripts/export-dictionary-sources.sh <checkout>}"
[[ -d "$DEST/.git" ]] || { echo "not a git checkout: $DEST" >&2; exit 1; }

# fetch_sources.sh pins the same archives as fetch_data.sh
for sum in $(grep -oE '[0-9a-f]{64}' "$PD/dictionary-sources/scripts/fetch_sources.sh"); do
    grep -q "$sum" "$PD/scripts/fetch_data.sh" \
        || { echo "fetch_sources.sh pins $sum, which fetch_data.sh does not" >&2; exit 1; }
done

rsync -a --delete --exclude .git --exclude data --exclude output \
    "$PD/dictionary-sources/" "$DEST/"
mkdir -p "$DEST/scripts/shared"
cp "$PD/scripts/build_freedict_mdx.py" "$PD/scripts/build_gcide_mdx.py" "$DEST/scripts/"
cp "$PD/scripts/shared/__init__.py" "$PD/scripts/shared/build.py" \
   "$PD/scripts/shared/html.py" "$PD/scripts/shared/theme.py" "$DEST/scripts/shared/"
cp "$ROOT/LICENSE" "$DEST/LICENSE"

python3 - "$PD" "$DEST" <<'PY'
import json, sys
from pathlib import Path
pd, dest = Path(sys.argv[1]), Path(sys.argv[2])
names = ["FreeDict-DE-EN", "FreeDict-EN-DE", "GCIDE-EN"]
pins = json.loads((pd / "build-pins.json").read_text())
(dest / "build-pins.json").write_text(
    json.dumps({f"{n}.mdx": pins[f"{n}.mdx"] for n in names}, indent=2) + "\n")
catalog = {d["filename"]: d for d in json.loads((pd / "preset-dictionaries.json").read_text())["dictionaries"]}
(dest / "SHA256SUMS").write_text("".join(
    f"{catalog[n + '.mdx']['sha256']}  output/{n}/{n}.mdx\n" for n in names))
PY
echo "Exported to $DEST. Next: (cd \"$DEST\" && make), then commit, tag and release (MAINTAINING.md)."
