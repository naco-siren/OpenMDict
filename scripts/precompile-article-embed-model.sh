#!/usr/bin/env bash
# precompile-article-embed-model.sh
#
# Pre-compile the article-embedding CoreML model (.mlpackage -> .mlmodelc) so
# the compiled bundle can be added to the Xcode project as a plain resource
# that carries an On-Demand Resources tag (ASSET_TAGS).
#
# Why (Xcode quirk): Xcode treats `.mlpackage` as a SOURCE file and compiles
# it during the Sources build phase, but only pre-compiled resources can carry
# ASSET_TAGS, so an auto-compiled model ends up in the base app bundle instead
# of the on-demand asset pack. Pre-compiling here and referencing the
# `.mlmodelc` directory as a resource keeps the 43 MB model out of the initial
# download.
#
# The compile is skipped when the .mlmodelc is already up to date: a stamp
# file next to it (`<model>.mlmodelc.sha256`) records the content hash of the
# .mlpackage it was built from. Xcode picks up a regenerated .mlmodelc on the
# next build because the project references the directory by path.
#
# Usage: scripts/precompile-article-embed-model.sh [--check | --force]
#   (default)  compile if the .mlmodelc is missing or its stamp differs
#   --check    exit 1 if a compile is needed, without compiling
#   --force    compile even if the stamp matches
#
# The .mlpackage itself is placed by scripts/bootstrap-assets.sh (downloaded
# from the assets Release) or rebuilt from PyTorch with
# scripts/model/build-st-coreml.py. Compiling needs the full Xcode toolchain
# (`xcrun --find coremlcompiler`); the Command Line Tools alone are not enough.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR="$REPO_ROOT/Apps/iOS/OpenMDict-iOS/Article Embeddings"
MODEL_NAME="all-MiniLM-L6-v2"
PACKAGE="$ASSETS_DIR/$MODEL_NAME.mlpackage"
COMPILED="$ASSETS_DIR/$MODEL_NAME.mlmodelc"
STAMP="$COMPILED.sha256"

MODE=build
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "precompile-article-embed-model: unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Content hash of a directory: sha256 over the sorted "sha256  ./path" lines of
# every regular file inside it (.DS_Store ignored). Identical to the function
# in bootstrap-assets.sh and publish-assets.sh.
tree_sha256() {
    (cd "$1" && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 -r shasum -a 256) \
        | shasum -a 256 | awk '{print $1}'
}

if [ ! -d "$PACKAGE" ]; then
    die "missing ${PACKAGE#"$REPO_ROOT"/}
  Run scripts/bootstrap-assets.sh to download it, or rebuild it with
  scripts/model/build-st-coreml.py."
fi

want=$(tree_sha256 "$PACKAGE")
have=""
if [ -d "$COMPILED" ] && [ -f "$STAMP" ]; then
    have=$(awk 'NR == 1 {print $1}' "$STAMP")
fi

if [ "$have" = "$want" ] && [ "$FORCE" -eq 0 ]; then
    echo "✓ $MODEL_NAME.mlmodelc is up to date (stamp $want)"
    exit 0
fi

if [ "$MODE" = check ]; then
    if [ -z "$have" ]; then
        echo "✗ $MODEL_NAME.mlmodelc is missing or has no stamp — run scripts/precompile-article-embed-model.sh"
    else
        echo "✗ $MODEL_NAME.mlmodelc was built from a different .mlpackage — run scripts/precompile-article-embed-model.sh"
    fi
    exit 1
fi

COMPILER=$(xcrun --find coremlcompiler 2>/dev/null) \
    || die "coremlcompiler not found. Install Xcode (not only the Command Line Tools) and select it:
  sudo xcode-select -s /Applications/Xcode.app"

TMP=$(mktemp -d "$ASSETS_DIR/.precompile.XXXXXX")
# shellcheck disable=SC2064
trap "rm -rf '$TMP'" EXIT

echo "→ Compiling $MODEL_NAME.mlpackage → $MODEL_NAME.mlmodelc…"
"$COMPILER" compile "$PACKAGE" "$TMP"
[ -d "$TMP/$MODEL_NAME.mlmodelc" ] || die "coremlcompiler reported success but produced no $MODEL_NAME.mlmodelc"

# Swap the finished bundle into place and stamp it with the package hash so
# the next run (and bootstrap-assets.sh --check) can tell it is current.
rm -rf "$COMPILED"
mv "$TMP/$MODEL_NAME.mlmodelc" "$COMPILED"
printf '%s\n' "$want" > "$STAMP"

SIZE_HUMAN=$(du -sh "$COMPILED" | awk '{print $1}')
echo "✓ Generated $MODEL_NAME.mlmodelc ($SIZE_HUMAN); stamp $want"
