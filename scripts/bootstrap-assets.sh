#!/usr/bin/env bash
# bootstrap-assets.sh — fetch the large build inputs that are not kept in git.
#
# Reads preset-dicts/assets.lock.json and makes sure every listed asset is
# present at its destination with the expected SHA-256:
#   * preset dictionaries        -> preset-dicts/output/<Name>/<Name>.mdx
#   * article-embedding model    -> Apps/iOS/OpenMDict-iOS/Article Embeddings/
#     (zip, extracted) + vocab      all-MiniLM-L6-v2.mlpackage, vocab.txt
# and then pre-compiles the CoreML model (.mlpackage -> .mlmodelc) when the
# compiled copy is missing or stale (see precompile-article-embed-model.sh).
#
# Usage: scripts/bootstrap-assets.sh [--check | --force] [--skip-precompile] [--quiet]
#   (default)         download whatever is missing or outdated. A file this
#                     script downloaded (or verified) earlier and that the lock
#                     has since moved on from is simply replaced. A file that
#                     differs from the lock and was never published is treated
#                     as a local build and is NOT replaced; the script reports
#                     it and exits 2.
#   --check           report drift and exit 1; never downloads or writes
#                     (CI gate, and the Xcode "Check bootstrapped assets" phase).
#   --force           also replace files whose content differs from the lock.
#   --skip-precompile do not compile / check the .mlmodelc (no Xcode needed).
#
# Environment:
#   OPENMDICT_ASSETS_BASE_URL  override the download base. Each asset URL is
#                              <base>/<tag>/<filename>; the default base is
#                              `tag_base_url_default` from the lock (GitHub
#                              Releases). A local mirror laid out the same way
#                              and served by `python3 -m http.server` works
#                              for dry runs.
#
# Private repositories: GitHub answers 404 to unauthenticated Release
# downloads. When the default GitHub base is in use and a download returns
# 404, the script switches to `gh release download` (GitHub CLI, logged in
# with access to the repository) for the rest of the run.
#
# Up-to-date files are skipped without touching their mtime, so Xcode does not
# re-copy 400 MB of dictionaries after every bootstrap. SHA-256 results are
# cached in .bootstrap/<dest>.sha256 keyed by size+mtime (or, for the model
# directory, by its file listing), so a no-op run does not re-hash anything.
#
# Requires bash 3.2+, curl, shasum, jq (macOS 15+ ships jq); ditto or unzip.

set -euo pipefail
US=$'\037'   # field separator for the internal tables (tab would collapse empty fields in `read`)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LOCK="$REPO_ROOT/preset-dicts/assets.lock.json"
CACHE_ROOT="$REPO_ROOT/.bootstrap"
OUTPUT_DIR="$REPO_ROOT/preset-dicts/output"
PRECOMPILE="$SCRIPT_DIR/precompile-article-embed-model.sh"

MODE=fetch
FORCE=0
SKIP_PRECOMPILE=0
QUIET=0

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --force) FORCE=1 ;;
        --skip-precompile) SKIP_PRECOMPILE=1 ;;
        -q|--quiet) QUIET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "bootstrap-assets: unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

log()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in curl shasum jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required (brew install $tool)"
done
[ -f "$LOCK" ] || die "lock file not found: ${LOCK#"$REPO_ROOT"/}"

# ── Hashing helpers ─────────────────────────────────────────────────────────

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# "size mtime" of a file; used as the cache key.
if stat -f '%z %m' / >/dev/null 2>&1; then
    file_key() { stat -f '%z %m' "$1"; }
else
    file_key() { stat -c '%s %Y' "$1"; }
fi
file_size() { file_key "$1" | awk '{print $1}'; }

# Content hash of a directory: sha256 over the sorted "sha256  ./path" lines of
# every regular file inside it (.DS_Store ignored). Identical to the function
# in precompile-article-embed-model.sh and publish-assets.sh.
tree_sha256() {
    (cd "$1" && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 -r shasum -a 256) \
        | shasum -a 256 | awk '{print $1}'
}

# Cheap identity of a directory (paths + sizes + mtimes); the cache key for
# tree_sha256.
tree_key() {
    (cd "$1" && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z \
        | while IFS= read -r -d '' f; do printf '%s %s\n' "$f" "$(file_key "$f")"; done) \
        | shasum -a 256 | awk '{print $1}'
}

cache_path() { printf '%s/%s.sha256\n' "$CACHE_ROOT" "${1#"$REPO_ROOT"/}"; }

# Content hash of the published asset last placed at <dest> (downloaded, or
# found already matching the lock). Lets a later lock update replace it
# without mistaking it for a local build.
published_path() { printf '%s/published/%s.sha256\n' "$CACHE_ROOT" "${1#"$REPO_ROOT"/}"; }
mark_published() { # <dest-abs> <hash>
    mkdir -p "$(dirname "$(published_path "$1")")"
    printf '%s\n' "$2" > "$(published_path "$1")"
}
published_hash() { local f; f=$(published_path "$1"); [ -f "$f" ] && cat "$f"; return 0; }

# Print the cached hash if its key still matches; print nothing on a miss.
cached_hash() { # <cache-file> <current-key>
    local csha='' ckey=''
    [ -f "$1" ] || return 0
    IFS=$US read -r csha ckey < "$1" || true
    [ "$ckey" = "$2" ] && printf '%s\n' "$csha"
    return 0
}

write_cache() { # <cache-file> <sha> <key>
    mkdir -p "$(dirname "$1")"
    printf '%s\037%s\n' "$2" "$3" > "$1"
}

# sha256 of a regular file, via the cache. --check never writes the cache.
file_sha_cached() {
    local path=$1 cache key sha
    cache=$(cache_path "$path")
    key=$(file_key "$path")
    sha=$(cached_hash "$cache" "$key")
    if [ -z "$sha" ]; then
        sha=$(sha256_of "$path")
        [ "$MODE" = check ] || write_cache "$cache" "$sha" "$key"
    fi
    printf '%s\n' "$sha"
}

# tree_sha256 of a directory, via the cache.
dir_sha_cached() {
    local path=$1 cache key sha
    cache=$(cache_path "$path")
    key=$(tree_key "$path")
    sha=$(cached_hash "$cache" "$key")
    if [ -z "$sha" ]; then
        sha=$(tree_sha256 "$path")
        [ "$MODE" = check ] || write_cache "$cache" "$sha" "$key"
    fi
    printf '%s\n' "$sha"
}

human_size() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB", u, " "); i = 1
        while (b >= 1024 && i < 4) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}

# ── Download helpers ────────────────────────────────────────────────────────

# Set once a 404 from GitHub has switched this run to the GitHub CLI.
USE_GH=0
GH_REPO=""

gh_download() { # <url> <out-file>
    local url=$1 out=$2 tag filename
    filename=${url##*/}
    tag=${url%/*}; tag=${tag##*/}
    rm -f "$out"
    gh release download "$tag" --repo "$GH_REPO" --pattern "$filename" --output "$out" \
        || { rm -f "$out"; die "gh release download failed: $tag/$filename ($GH_REPO)"; }
}

download() { # <url> <out-file>
    local url=$1 out=$2 rc=0
    if [ "$USE_GH" -eq 1 ]; then gh_download "$url" "$out"; return; fi
    local opts="-fL --retry 5 --retry-delay 2"
    if [ -t 1 ] && [ "$QUIET" -eq 0 ]; then opts="$opts --progress-bar"; else opts="$opts -sS"; fi
    mkdir -p "$(dirname "$out")"
    # shellcheck disable=SC2086
    curl $opts -C - -o "$out" "$url" || rc=$?
    if [ "$rc" -eq 33 ] && [ -f "$out" ]; then
        # The server cannot resume a partial download: start over.
        rm -f "$out"
        rc=0
        # shellcheck disable=SC2086
        curl $opts -o "$out" "$url" || rc=$?
    fi
    if [ "$rc" -ne 0 ] && [ -n "$GH_REPO" ] && command -v gh >/dev/null 2>&1 \
       && gh auth status >/dev/null 2>&1; then
        # The default GitHub base refused the download (a private repository
        # answers 404; with -C curl reports that as exit 56, not 22). Use the
        # logged-in GitHub CLI for the rest of the run.
        rm -f "$out"
        log "  (unauthenticated download refused — private repository? switching to gh release download)"
        USE_GH=1
        gh_download "$url" "$out"
        return
    fi
    [ "$rc" -eq 0 ] || { rm -f "$out"; die "download failed (curl exit $rc): $url"; }
}

extract_zip() { # <zip> <into-dir>
    mkdir -p "$2"
    if command -v ditto >/dev/null 2>&1; then
        ditto -x -k "$1" "$2"
    elif command -v unzip >/dev/null 2>&1; then
        unzip -q "$1" -d "$2"
    else
        die "neither ditto nor unzip is available to extract $(basename "$1")"
    fi
}

fetch_file() { # <url> <dest> <sha> <size>
    local url=$1 dest=$2 sha=$3 size=$4 part actual
    part="$dest.part"
    download "$url" "$part"
    actual=$(sha256_of "$part")
    if [ "$actual" != "$sha" ]; then
        rm -f "$part"
        die "checksum mismatch for $(basename "$dest"): expected $sha, got $actual ($url)"
    fi
    mv -f "$part" "$dest"
    write_cache "$(cache_path "$dest")" "$sha" "$(file_key "$dest")"
    mark_published "$dest" "$sha"
    [ "$(file_size "$dest")" = "$size" ] || warn "$(basename "$dest"): size differs from lock (lock says $size)"
}

fetch_model() { # <url> <dest-dir> <zip-sha> <tree-sha>
    local url=$1 dest=$2 sha=$3 tree=$4 parent tmp zip extracted actual
    parent=$(dirname "$dest")
    mkdir -p "$parent"
    tmp=$(mktemp -d "$parent/.bootstrap-tmp.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    zip="$tmp/$(basename "$url")"
    download "$url" "$zip"
    actual=$(sha256_of "$zip")
    [ "$actual" = "$sha" ] || die "checksum mismatch for $(basename "$zip"): expected $sha, got $actual ($url)"
    extract_zip "$zip" "$tmp/extract"
    rm -rf "$tmp/extract/__MACOSX"
    extracted="$tmp/extract/$(basename "$dest")"
    if [ ! -d "$extracted" ]; then
        # Fall back to the single top-level directory of the archive.
        extracted=$(find "$tmp/extract" -mindepth 1 -maxdepth 1 -type d | sed -n '1p')
        [ -n "$extracted" ] || die "$(basename "$zip") does not contain a $(basename "$dest") directory"
    fi
    actual=$(tree_sha256 "$extracted")
    [ "$actual" = "$tree" ] || die "extracted $(basename "$dest") has content hash $actual, lock expects $tree"
    rm -rf "$dest"
    mv "$extracted" "$dest"
    write_cache "$(cache_path "$dest")" "$tree" "$(tree_key "$dest")"
    mark_published "$dest" "$tree"
    rm -rf "$tmp"
    trap - EXIT
}

# ── Main ────────────────────────────────────────────────────────────────────

BASE_URL=${OPENMDICT_ASSETS_BASE_URL:-$(jq -r '.tag_base_url_default // empty' "$LOCK")}
BASE_URL=${BASE_URL%/}
[ -n "$BASE_URL" ] || die "no download base URL (lock has no tag_base_url_default)"
# owner/name when the base is GitHub Releases (enables the gh fallback).
case "$BASE_URL" in
    https://github.com/*/*/releases/download)
        GH_REPO=$(printf '%s' "$BASE_URL" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/releases/download$#\1#') ;;
esac

# In a fresh checkout preset-dicts/output does not exist (it is gitignored). A
# dangling symlink left over from a workspace that keeps the pipeline output
# elsewhere is replaced by a real directory.
if [ -L "$OUTPUT_DIR" ] && [ ! -e "$OUTPUT_DIR" ]; then
    if [ "$MODE" = check ]; then
        warn "preset-dicts/output is a dangling symlink"
    else
        rm "$OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
        log "replaced dangling symlink preset-dicts/output with a directory"
    fi
fi

n_ok=0; n_fetched=0; n_missing=0; n_outdated=0; n_differs=0; n_refused=0; bytes_fetched=0
model_dest_abs=""; model_tree=""; model_drift=0

while IFS=$US read -r filename dest size sha tag kind tree; do
    [ "$kind" = notice ] && continue   # Release-only compliance payload; not a build input
    [ -n "$dest" ] && [ "$dest" != null ] || die "lock entry $filename has no dest"
    dest_abs="$REPO_ROOT/$dest"
    url="$BASE_URL/$tag/$filename"

    have=""
    if [ "$kind" = model ]; then
        want=$tree
        [ -n "$want" ] || die "lock entry $filename (kind model) has no tree_sha256"
        model_dest_abs=$dest_abs
        model_tree=$tree
        [ -d "$dest_abs" ] && have=$(dir_sha_cached "$dest_abs")
    else
        want=$sha
        if [ -f "$dest_abs" ]; then
            if [ "$(file_size "$dest_abs")" = "$size" ]; then
                have=$(file_sha_cached "$dest_abs")
            else
                have=size-mismatch
            fi
        fi
    fi

    if [ "$have" = "$want" ]; then
        n_ok=$((n_ok + 1))
        log "  ok        $dest"
        if [ "$MODE" != check ] && [ "$(published_hash "$dest_abs")" != "$want" ]; then
            mark_published "$dest_abs" "$want"
        fi
        continue
    fi

    if [ -z "$have" ]; then
        state=missing; n_missing=$((n_missing + 1))
    else
        state=differs
        prev=$(published_hash "$dest_abs")
        if [ -n "$prev" ]; then
            cur=$have
            [ "$cur" = size-mismatch ] && cur=$(file_sha_cached "$dest_abs")
            # Unchanged since we placed it: an outdated download, not a local build.
            [ "$cur" = "$prev" ] && state=outdated
        fi
        if [ "$state" = outdated ]; then n_outdated=$((n_outdated + 1)); else n_differs=$((n_differs + 1)); fi
    fi

    if [ "$MODE" = check ]; then
        printf '  %-9s %s\n' "$state" "$dest"
        [ "$kind" = model ] && model_drift=1
        continue
    fi

    if [ "$state" = differs ] && [ "$FORCE" -eq 0 ]; then
        printf 'refusing to overwrite %s: local build differs from lock (use --force to replace it)\n' "$dest" >&2
        n_refused=$((n_refused + 1))
        continue
    fi

    log "  get       $dest  ($(human_size "$size"))"
    if [ "$kind" = model ]; then
        fetch_model "$url" "$dest_abs" "$sha" "$tree"
    else
        fetch_file "$url" "$dest_abs" "$sha" "$size"
    fi
    n_fetched=$((n_fetched + 1))
    bytes_fetched=$((bytes_fetched + size))
done < <(jq -r '.assets[] | [.filename, .dest, .size, .sha256, .tag, .kind, (.tree_sha256 // "")] | map(. // "" | tostring) | join("\u001f")' "$LOCK")

# ── CoreML pre-compile ──────────────────────────────────────────────────────
# precompile-article-embed-model.sh records the content hash of the .mlpackage
# it compiled in <model>.mlmodelc.sha256; --check only compares that stamp
# with the lock, so it never hashes the model.

precompile_drift=0
if [ "$SKIP_PRECOMPILE" -eq 0 ] && [ -n "$model_dest_abs" ]; then
    stamp="${model_dest_abs%.mlpackage}.mlmodelc.sha256"
    if [ "$MODE" = check ]; then
        if [ "$model_drift" -eq 0 ]; then
            if [ ! -d "${stamp%.sha256}" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$model_tree" ]; then
                precompile_drift=1
                mlmodelc=${stamp%.sha256}
                printf '  %-9s %s\n' stale "${mlmodelc#"$REPO_ROOT"/}"
            fi
        fi
    elif [ "$n_refused" -eq 0 ]; then
        [ -x "$PRECOMPILE" ] || die "missing helper: ${PRECOMPILE#"$REPO_ROOT"/}"
        if [ "$QUIET" -eq 1 ]; then "$PRECOMPILE" >/dev/null; else "$PRECOMPILE"; fi
    fi
fi

# ── Signing config for a fresh clone ────────────────────────────────────────
# Every build configuration uses Apps/iOS/OpenMDict-iOS/Local.xcconfig (not
# committed) as its base configuration; make sure one exists.

XCCONFIG="$REPO_ROOT/Apps/iOS/OpenMDict-iOS/Local.xcconfig"
if [ ! -f "$XCCONFIG" ] && [ -f "$XCCONFIG.template" ]; then
    if [ "$MODE" = check ]; then
        warn "Apps/iOS/OpenMDict-iOS/Local.xcconfig is missing — copy Local.xcconfig.template and set DEVELOPMENT_TEAM for device builds"
    else
        cp "$XCCONFIG.template" "$XCCONFIG"
        log "created Apps/iOS/OpenMDict-iOS/Local.xcconfig from the template (set DEVELOPMENT_TEAM for device builds)"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────

if [ "$MODE" = check ]; then
    drift=$((n_missing + n_outdated + n_differs + precompile_drift))
    if [ "$drift" -gt 0 ]; then
        hint="run scripts/bootstrap-assets.sh"
        [ "$n_differs" -gt 0 ] && hint="$hint (add --force to replace local builds that differ from the lock)"
        printf 'error: %d asset(s) missing or stale (%d ok) — %s\n' "$drift" "$n_ok" "$hint" >&2
        exit 1
    fi
    log "assets up to date: $n_ok verified"
    exit 0
fi

log "assets: $n_ok up to date, $n_fetched downloaded ($(human_size "$bytes_fetched"))"
if [ "$n_refused" -gt 0 ]; then
    printf 'error: %d asset(s) left untouched because they differ from the lock; rerun with --force to replace them, or publish them with scripts/publish-assets.sh\n' "$n_refused" >&2
    exit 2
fi
