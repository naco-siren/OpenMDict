#!/usr/bin/env bash
# publish-assets.sh — publish the large build inputs to a GitHub Release and
# refresh preset-dicts/assets.lock.json.
#
# Assets:
#   * every <Name>.mdx listed in preset-dicts/preset-dictionaries.json, read
#     from preset-dicts/output/<Name>/<Name>.mdx (build them with `make` first)
#   * the article-embedding model, zipped with
#     `ditto -c -k --keepParent` as all-MiniLM-L6-v2.mlpackage.zip, and its
#     vocab published as all-MiniLM-L6-v2.vocab.txt
#   * the compliance payload: THIRD-PARTY-NOTICES.md (copied from the repo
#     root), LICENSE-<SPDX>.txt for every license seen in the catalog (texts
#     from preset-dicts/licenses/, then licenses/, else fetched from the SPDX
#     license list) and the corresponding-source
#     tarballs of the GPL dictionaries from preset-dicts/data/
#
# Rules:
#   * Every lock entry carries its own tag. Only assets whose content changed
#     are uploaded, to the tag given with --tag, which must be a NEW tag;
#     unchanged assets keep the tag they were first published under.
#   * Exception: the compliance payload travels with every new tag. When
#     anything is uploaded to --tag, the unchanged notices, LICENSE-*.txt texts
#     and GPL source tarballs are attached to it as well ("carried"; their lock
#     entries move to --tag). Every Release that hosts dictionary assets then
#     carries THIRD-PARTY-NOTICES.md, the license texts and the corresponding
#     source of its GPL .mdx files, as THIRD-PARTY-NOTICES.md states and GPLv3
#     section 6 requires.
#   * An asset referenced by a committed lock is never replaced: `--clobber`
#     is never used, and a --tag already present in the committed lock is
#     refused. Changed content always means a new tag.
#   * Uploads go to a DRAFT pre-release. Review it, then publish with
#       gh release edit <tag> --draft=false
#     and commit the rewritten lock.
#
# Usage:
#   scripts/publish-assets.sh --tag assets-YYYY.MM[.N] [options]
#
# Options:
#   --tag <tag>          tag for new/changed assets (required when anything changed)
#   --dry-run            print what would change and exit
#   --stage-only         assemble <staging>/<tag>/<filename> and rewrite the lock
#                        without calling gh. Serve the staging dir with
#                          python3 -m http.server 8765 --directory <staging>
#                        and run
#                          OPENMDICT_ASSETS_BASE_URL=http://127.0.0.1:8765 scripts/bootstrap-assets.sh
#                        in a fresh clone for an end-to-end dry run.
#   --staging <dir>      staging root (default: .bootstrap/publish)
#   --offline            do not fetch SPDX license texts or previously published
#                        files; missing payload files are skipped with a warning
#   --licenses-dir <dir> take LICENSE-<SPDX>.txt (or <SPDX>.txt) files from <dir>
#                        instead of fetching; defaults to preset-dicts/licenses/
#                        when that directory exists. LicenseRef-* texts (e.g. the
#                        WordNet license) can only come from here.
#   --repo <owner/name>  GitHub repository (default: derived from the lock's base URL)
#   --amend              revise an existing tag in place (alias:
#                        --amend-unpublished): the tag may already be referenced
#                        by the committed lock and its release may already be
#                        published. Every asset that points at the tag is made
#                        to match the lock: identical files (by SHA-256 digest)
#                        are skipped, changed ones are deleted and re-uploaded.
#                        Only sensible before the project is announced; clones
#                        that bootstrapped the old files pick up the new ones on
#                        their next scripts/bootstrap-assets.sh run.
#
# Requires bash 3.2+, jq, shasum, ditto, curl; gh (authenticated) unless
# --dry-run/--stage-only.

set -euo pipefail
US=$'\037'   # field separator for the internal tables (tab would collapse empty fields in `read`)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CATALOG="$REPO_ROOT/preset-dicts/preset-dictionaries.json"
LOCK="$REPO_ROOT/preset-dicts/assets.lock.json"
OUTPUT_DIR="$REPO_ROOT/preset-dicts/output"
DATA_DIR="$REPO_ROOT/preset-dicts/data"
NOTICES="$REPO_ROOT/THIRD-PARTY-NOTICES.md"
MODEL_DIR_REL="Apps/iOS/OpenMDict-iOS/Article Embeddings"
MODEL_DIR="$REPO_ROOT/$MODEL_DIR_REL"
MODEL_NAME="all-MiniLM-L6-v2"
DEFAULT_BASE_URL="https://github.com/naco-siren/OpenMDict/releases/download"
SPDX_TEXT_URL="https://raw.githubusercontent.com/spdx/license-list-data/main/text"
# Licenses that are not in the catalog but apply to published assets
# (the embedding model is Apache-2.0).
EXTRA_SPDX_IDS="Apache-2.0"

# GPLv3 §6: the Release must carry the corresponding source of every GPL
# dictionary. Catalog id -> tarball under preset-dicts/data/.
gpl_source_for() {
    case "$1" in
        gcide-en)       echo "gcide/gcide-0.53.tar.xz" ;;
        freedict-en-de) echo "freedict/freedict-eng-deu.src.tar.xz" ;;
        freedict-de-en) echo "freedict/freedict-deu-eng.src.tar.xz" ;;
        *)              echo "" ;;
    esac
}

TAG=""
MODE=publish
STAGING="$REPO_ROOT/.bootstrap/publish"
OFFLINE=0
AMEND=0
RELEASE_STATE=""
LICENSES_DIR=""
GH_REPO=""

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG=${2:-}; shift ;;
        --dry-run) MODE=dry-run ;;
        --stage-only) MODE=stage-only ;;
        --staging) STAGING=${2:-}; shift ;;
        --offline) OFFLINE=1 ;;
        --amend|--amend-unpublished) AMEND=1 ;;
        --licenses-dir) LICENSES_DIR=${2:-}; shift ;;
        --repo) GH_REPO=${2:-}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "publish-assets: unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done
if [ -z "$LICENSES_DIR" ] && [ -d "$REPO_ROOT/preset-dicts/licenses" ]; then
    LICENSES_DIR="$REPO_ROOT/preset-dicts/licenses"
fi

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in jq shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required (brew install $tool)"
done
if [ "$MODE" = publish ]; then
    command -v gh >/dev/null 2>&1 || die "gh is required to upload (brew install gh && gh auth login); use --stage-only for a local dry run"
fi
[ -f "$CATALOG" ] || die "missing ${CATALOG#"$REPO_ROOT"/}"
[ -f "$NOTICES" ] || die "missing ${NOTICES#"$REPO_ROOT"/}"
[ -d "$MODEL_DIR/$MODEL_NAME.mlpackage" ] || die "missing $MODEL_DIR_REL/$MODEL_NAME.mlpackage"
[ -f "$MODEL_DIR/vocab.txt" ] || die "missing $MODEL_DIR_REL/vocab.txt"
if [ -n "$TAG" ]; then
    printf '%s' "$TAG" | grep -Eq '^assets-[0-9]{4}\.[0-9]{2}(\.[0-9]+)?$' \
        || die "tag '$TAG' does not match assets-YYYY.MM[.N]"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/publish-assets.XXXXXX")
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT
export LC_ALL=C

# ── Helpers ─────────────────────────────────────────────────────────────────

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
if stat -f '%z' / >/dev/null 2>&1; then
    file_size() { stat -f '%z' "$1"; }
else
    file_size() { stat -c '%s' "$1"; }
fi

# Content hash of a directory: sha256 over the sorted "sha256  ./path" lines of
# every regular file inside it (.DS_Store ignored). Identical to the function
# in bootstrap-assets.sh and precompile-article-embed-model.sh.
tree_sha256() {
    (cd "$1" && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 -r shasum -a 256) \
        | shasum -a 256 | awk '{print $1}'
}

human_size() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB", u, " "); i = 1
        while (b >= 1024 && i < 4) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}

# Copy with an APFS clone when possible (zero-cost on the same volume).
clone_file() { cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"; }

# Zip the model package the way bootstrap-assets.sh expects to unzip it:
# one top-level <name>.mlpackage directory, no AppleDouble/xattr side files,
# no .DS_Store.
make_model_zip() { # <mlpackage-dir> <out-zip>
    local src=$1 out=$2 tmp
    command -v ditto >/dev/null 2>&1 || die "ditto is required to zip the model package"
    tmp="$WORK/zip-src"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    cp -R "$src" "$tmp/"
    find "$tmp" -name .DS_Store -delete
    rm -f "$out"
    ditto -c -k --keepParent --norsrc "$tmp/$(basename "$src")" "$out"
}

# Map one license token from the catalog to an SPDX identifier (one per line).
# SPDX identifiers (including LicenseRef-*) pass through unchanged; public
# domain markers have no license text and print nothing; legacy free-form
# strings ("CC BY-SA 3.0", "GPL 3.0+") are normalized.
spdx_for_token() {
    local raw t
    raw=$(printf '%s' "$1" | sed -E 's/^[[:space:]()]+|[[:space:]()]+$//g')
    case "$raw" in
        "") return 0 ;;
        LicenseRef-[Pp]ublic-[Dd]omain|LicenseRef-PD|CC0-1.0|CC-PDDC) return 0 ;;
        LicenseRef-*NC*|*-NC-*) warn "non-commercial license '$raw' seen in the catalog; verify it may be redistributed" ;;
    esac
    case "$raw" in
        LicenseRef-*) printf '%s\n' "$raw"; return 0 ;;
    esac
    if printf '%s' "$raw" | grep -Eq '^(CC-BY(-SA|-NC|-NC-SA|-ND|-NC-ND)?-[0-9]\.[0-9]|A?GPL-[23]\.0(-only|-or-later)?|LGPL-[23]\.[01](-only|-or-later)?|GFDL-1\.[123](-no-invariants|-invariants)?(-only|-or-later)?|Apache-2\.0|MIT|BSD-[23]-Clause|Unicode-3\.0|Unicode-DFS-20[0-9]{2})$'; then
        printf '%s\n' "$raw"
        return 0
    fi
    t=$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')
    case "$t" in
        "PUBLIC DOMAIN"|PD|CC0*) ;;
        AGPL*3*) echo "AGPL-3.0-or-later" ;;
        GPL*3*) echo "GPL-3.0-or-later" ;;
        GPL*2*) echo "GPL-2.0-or-later" ;;
        LGPL*) echo "LGPL-3.0-or-later" ;;
        CC*BY*NC*) warn "non-commercial license '$1' seen in the catalog; verify it may be redistributed"; echo "LicenseRef-$(printf '%s' "$t" | tr -c 'A-Z0-9\n' '-')" ;;
        CC*BY*SA*4*) echo "CC-BY-SA-4.0" ;;
        CC*BY*SA*3*) echo "CC-BY-SA-3.0" ;;
        CC*BY*4*) echo "CC-BY-4.0" ;;
        CC*BY*3*) echo "CC-BY-3.0" ;;
        GFDL*) echo "GFDL-1.3-or-later" ;;
        UNICODE*) echo "Unicode-3.0" ;;
        APACHE*2*) echo "Apache-2.0" ;;
        MIT) echo "MIT" ;;
        *)
            # Not a known SPDX license (e.g. the WordNet license): keep a
            # LicenseRef- id; its text must be supplied via --licenses-dir.
            echo "LicenseRef-$(printf '%s' "$t" | tr -c 'A-Z0-9\n' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
            ;;
    esac
}

# Split a catalog license string ("CC-BY-SA 3.0 / GFDL", "GPL 3.0+",
# "A AND B", "X + Y") into tokens.
license_tokens() {
    printf '%s\n' "$1" | awk '{
        s = $0
        gsub(/ AND | OR | and | or /, "\n", s)
        gsub(/[+,\/]/, "\n", s)
        n = split(s, parts, "\n")
        for (i = 1; i <= n; i++) { p = parts[i]; gsub(/^[ \t()]+|[ \t()]+$/, "", p); if (p != "") print p }
    }'
}

# ── Previous lock ───────────────────────────────────────────────────────────
# old.tsv: filename  kind  sha256  tree_sha256  tag  size  dest

BASE_URL=$DEFAULT_BASE_URL
if [ -f "$LOCK" ]; then
    jq -r '.assets[] | [.filename, .kind, .sha256, (.tree_sha256 // ""), .tag, .size, (.dest // "")] | map(. // "" | tostring) | join("\u001f")' "$LOCK" > "$WORK/old.tsv"
    b=$(jq -r '.tag_base_url_default // ""' "$LOCK")
    [ -z "$b" ] || BASE_URL=$b
else
    : > "$WORK/old.tsv"
fi
BASE_URL=${BASE_URL%/}
old_field() { # <filename> <column>
    awk -F "$US" -v f="$1" -v c="$2" '$1 == f { print $c; exit }' "$WORK/old.tsv"
}

# Tags referenced by the lock as committed (never add to those).
if git -C "$REPO_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1 \
   && git -C "$REPO_ROOT" cat-file -e "HEAD:preset-dicts/assets.lock.json" 2>/dev/null; then
    git -C "$REPO_ROOT" show "HEAD:preset-dicts/assets.lock.json" | jq -r '.assets[].tag' | sort -u > "$WORK/committed.tags"
else
    : > "$WORK/committed.tags"
fi

# ── Inventory ───────────────────────────────────────────────────────────────
# inv.tsv: kind  filename  dest  size  sha256  tree_sha256  src
# (model: size/sha filled in after zipping; src is the .mlpackage directory;
#  notice: dest empty)

: > "$WORK/inv.tsv"
add_inv() { printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$WORK/inv.tsv"; }

log "→ Hashing preset dictionaries…"
jq -r '.dictionaries[] | [.filename, .id, .license] | map(. // "" | tostring) | join("\u001f")' "$CATALOG" | sort > "$WORK/catalog.tsv"
n_mdx=0
while IFS=$US read -r filename id license; do
    name=${filename%.mdx}
    src="$OUTPUT_DIR/$name/$name.mdx"
    [ -f "$src" ] || die "missing $name.mdx at preset-dicts/output/$name/ — build it first (cd preset-dicts && make $name)"
    add_inv mdx "$filename" "preset-dicts/output/$name/$name.mdx" "$(file_size "$src")" "$(sha256_of "$src")" "" "$src"
    n_mdx=$((n_mdx + 1))
done < "$WORK/catalog.tsv"

log "→ Hashing model package…"
model_tree=$(tree_sha256 "$MODEL_DIR/$MODEL_NAME.mlpackage")
add_inv model "$MODEL_NAME.mlpackage.zip" "$MODEL_DIR_REL/$MODEL_NAME.mlpackage" "" "" "$model_tree" "$MODEL_DIR/$MODEL_NAME.mlpackage"
add_inv vocab "$MODEL_NAME.vocab.txt" "$MODEL_DIR_REL/vocab.txt" "$(file_size "$MODEL_DIR/vocab.txt")" "$(sha256_of "$MODEL_DIR/vocab.txt")" "" "$MODEL_DIR/vocab.txt"

# Compliance payload.
add_inv notice "THIRD-PARTY-NOTICES.md" "" "$(file_size "$NOTICES")" "$(sha256_of "$NOTICES")" "" "$NOTICES"

while IFS=$US read -r filename id license; do
    case "$(printf '%s' "$license" | tr '[:lower:]' '[:upper:]')" in
        *GPL*) ;;
        *) continue ;;
    esac
    rel=$(gpl_source_for "$id")
    [ -n "$rel" ] || die "no corresponding-source tarball is mapped for GPL dictionary '$id' (edit gpl_source_for in this script)"
    src="$DATA_DIR/$rel"
    base=$(basename "$rel")
    if [ -f "$src" ]; then
        add_inv notice "$base" "" "$(file_size "$src")" "$(sha256_of "$src")" "" "$src"
    elif [ -n "$(old_field "$base" 2)" ]; then
        warn "$base is not in preset-dicts/data; keeping the previously published copy"
        add_inv notice "$base" "" "$(old_field "$base" 6)" "$(old_field "$base" 3)" "" ""
    else
        die "corresponding source for GPL dictionary '$id' not found: preset-dicts/data/$rel"
    fi
done < "$WORK/catalog.tsv"

# License texts: one LICENSE-<SPDX>.txt per identifier seen in the catalog.
{
    cut -d "$US" -f3 "$WORK/catalog.tsv" | sort -u | while IFS= read -r lic; do
        license_tokens "$lic" | while IFS= read -r tok; do spdx_for_token "$tok"; done
    done
    for extra in $EXTRA_SPDX_IDS; do printf '%s\n' "$extra"; done
} | grep -v '^$' | sort -u > "$WORK/spdx.ids"

mkdir -p "$WORK/licenses"
while IFS= read -r spdx; do
    base="LICENSE-$spdx.txt"
    src=""
    if [ -n "$LICENSES_DIR" ] && [ -f "$LICENSES_DIR/$base" ]; then
        src="$LICENSES_DIR/$base"
    elif [ -n "$LICENSES_DIR" ] && [ -f "$LICENSES_DIR/$spdx.txt" ]; then
        src="$LICENSES_DIR/$spdx.txt"
    elif [ -f "$REPO_ROOT/licenses/$base" ]; then
        # the standard SPDX texts kept in the repository (the app's Settings
        # licenses pages show the same files)
        src="$REPO_ROOT/licenses/$base"
    else
        case "$spdx" in
            LicenseRef-*) ;;
            *)
                if [ "$OFFLINE" -eq 0 ]; then
                    if curl -fsSL --retry 3 -o "$WORK/licenses/$base" "$SPDX_TEXT_URL/$spdx.txt"; then
                        src="$WORK/licenses/$base"
                    else
                        warn "could not fetch the SPDX text for $spdx"
                    fi
                fi
                ;;
        esac
    fi
    if [ -n "$src" ]; then
        add_inv notice "$base" "" "$(file_size "$src")" "$(sha256_of "$src")" "" "$src"
    elif [ -n "$(old_field "$base" 2)" ]; then
        warn "$base: keeping the previously published copy"
        add_inv notice "$base" "" "$(old_field "$base" 6)" "$(old_field "$base" 3)" "" ""
    else
        warn "$base: no license text available (supply it with --licenses-dir); skipped"
    fi
done < "$WORK/spdx.ids"

# ── Plan ────────────────────────────────────────────────────────────────────
# plan.tsv: status  kind  filename  dest  size  sha256  tree_sha256  tag  src  from_tag
#   status: new | changed | unchanged | carried (unchanged payload re-attached
#           to --tag, see Rules)
#   from_tag: the Release a previously published copy can be downloaded from
#           when src is not available locally (unchanged and carried rows)

: > "$WORK/plan.tsv"
n_new=0; n_changed=0; n_unchanged=0; n_carried=0
while IFS=$US read -r kind filename dest size sha tree src; do
    old_kind=$(old_field "$filename" 2)
    from_tag=""
    status=new
    if [ -n "$old_kind" ]; then
        if [ "$kind" = model ]; then
            [ "$(old_field "$filename" 4)" = "$tree" ] && status=unchanged || status=changed
        else
            [ "$(old_field "$filename" 3)" = "$sha" ] && status=unchanged || status=changed
        fi
    fi
    case "$status" in
        unchanged)
            n_unchanged=$((n_unchanged + 1))
            tag=$(old_field "$filename" 5)
            from_tag=$tag
            [ "$kind" = model ] && { size=$(old_field "$filename" 6); sha=$(old_field "$filename" 3); }
            ;;
        new) n_new=$((n_new + 1)); tag=$TAG ;;
        changed) n_changed=$((n_changed + 1)); tag=$TAG ;;
    esac
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$status" "$kind" "$filename" "$dest" "$size" "$sha" "$tree" "$tag" "$src" "$from_tag" >> "$WORK/plan.tsv"
done < "$WORK/inv.tsv"

# Carry the compliance payload: if anything ends up on --tag (new or changed
# assets, or, with --amend, assets already pointing at it), every unchanged
# payload file (kind notice) that lives on another tag is attached to --tag
# too, so the new Release is self-contained (see Rules).
if [ -n "$TAG" ] && awk -F "$US" -v t="$TAG" '$8 == t { found = 1 } END { exit !found }' "$WORK/plan.tsv"; then
    awk -F "$US" -v OFS="$US" -v t="$TAG" \
        '$1 == "unchanged" && $2 == "notice" && $8 != t { $1 = "carried"; $8 = t } { print }' \
        "$WORK/plan.tsv" > "$WORK/plan.carry"
    mv "$WORK/plan.carry" "$WORK/plan.tsv"
    n_carried=$(awk -F "$US" '$1 == "carried"' "$WORK/plan.tsv" | wc -l | tr -d ' ')
    n_unchanged=$((n_unchanged - n_carried))
fi

cut -d "$US" -f1 "$WORK/old.tsv" | sort > "$WORK/old.names"
cut -d "$US" -f3 "$WORK/plan.tsv" | sort > "$WORK/new.names"
comm -23 "$WORK/old.names" "$WORK/new.names" > "$WORK/removed.names"
n_removed=$(wc -l < "$WORK/removed.names" | tr -d ' ')

n_upload=$((n_new + n_changed + n_carried))
if [ "$AMEND" -eq 1 ] && [ -n "$TAG" ]; then
    # Unpublished tag: everything pointing at it still has to be uploaded.
    n_upload=$(awk -F "$US" -v t="$TAG" '$8 == t' "$WORK/plan.tsv" | wc -l | tr -d ' ')
fi
if [ "$n_upload" -gt 0 ]; then
    [ -n "$TAG" ] || die "$n_upload asset(s) are new or changed; pass --tag assets-YYYY.MM[.N] (a tag not yet referenced by the committed lock)"
    if grep -qx "$TAG" "$WORK/committed.tags" && [ "$AMEND" -eq 0 ]; then
        die "tag $TAG is already referenced by the committed lock; pick a new tag, or pass --amend to revise it in place"
    fi
fi

log ""
log "Plan ($n_mdx dictionaries + model + vocab + payload):"
awk -F "$US" '{ printf "  %-9s %-6s %s\n", $1, $2, $3 }' "$WORK/plan.tsv" | grep -v '^  unchanged' || true
log "  unchanged $n_unchanged, new $n_new, changed $n_changed, carried $n_carried (unchanged payload re-attached to ${TAG:-the new tag}), removed from lock $n_removed"
while IFS= read -r n; do log "  removed   $n (its Release stays as is)"; done < "$WORK/removed.names"
log ""

if [ "$MODE" = dry-run ]; then
    [ "$n_upload" -gt 0 ] && log "Would upload $n_upload asset(s) to $TAG and rewrite ${LOCK#"$REPO_ROOT"/}."
    [ "$n_upload" -gt 0 ] || log "Nothing to upload; the lock is up to date."
    exit 0
fi

# ── Staging ─────────────────────────────────────────────────────────────────
# <staging>/<tag>/<filename> for every asset (an exact mirror of the Releases
# layout, so a local http.server can stand in for GitHub).

mkdir -p "$STAGING"
: > "$WORK/plan2.tsv"
bytes_total=0
while IFS=$US read -r status kind filename dest size sha tree tag src from_tag; do
    dir="$STAGING/$tag"
    out="$dir/$filename"
    mkdir -p "$dir"
    if [ "$kind" = model ] && { [ "$status" != unchanged ] || { [ "$AMEND" -eq 1 ] && [ "$tag" = "$TAG" ] && [ ! -f "$out" ]; }; }; then
        # (Amending an unpublished tag whose staged zip is gone: zips are not
        # byte-reproducible, so re-zip and record the new hash.)
        log "→ Zipping $MODEL_NAME.mlpackage…"
        make_model_zip "$src" "$out"
        size=$(file_size "$out")
        sha=$(sha256_of "$out")
    elif [ -n "$src" ] && [ -f "$src" ]; then
        if [ ! -f "$out" ] || [ "$(file_size "$out")" != "$size" ] || [ "$(sha256_of "$out")" != "$sha" ]; then
            rm -f "$out"
            clone_file "$src" "$out"
        fi
    fi
    if [ ! -f "$out" ] || [ "$(sha256_of "$out")" != "$sha" ]; then
        # Previously published content that is not available locally: take
        # it from the staged copy of its earlier tag, else from that Release.
        rm -f "$out"
        prev=${from_tag:-$tag}
        if [ "$prev" != "$tag" ] && [ -f "$STAGING/$prev/$filename" ] \
           && [ "$(sha256_of "$STAGING/$prev/$filename")" = "$sha" ]; then
            clone_file "$STAGING/$prev/$filename" "$out"
        elif [ "$OFFLINE" -eq 0 ] && curl -fsSL --retry 3 -o "$out" "$BASE_URL/$prev/$filename" \
           && [ "$(sha256_of "$out")" = "$sha" ]; then
            :
        else
            rm -f "$out"
            warn "staging mirror lacks $tag/$filename (not available locally; download it from the Release if you need a complete mirror)"
        fi
    fi
    bytes_total=$((bytes_total + size))
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$status" "$kind" "$filename" "$dest" "$size" "$sha" "$tree" "$tag" "$out" >> "$WORK/plan2.tsv"
done < "$WORK/plan.tsv"

# ── Lock ────────────────────────────────────────────────────────────────────

: > "$WORK/entries.jsonl"
while IFS=$US read -r status kind filename dest size sha tree tag out; do
    jq -nc --arg f "$filename" --arg d "$dest" --argjson s "$size" --arg sha "$sha" --arg tag "$tag" --arg k "$kind" --arg tree "$tree" \
        '{filename: $f, dest: (if $d == "" then null else $d end), size: $s, sha256: $sha, tag: $tag, kind: $k}
         + (if $tree == "" then {} else {tree_sha256: $tree} end)' >> "$WORK/entries.jsonl"
done < "$WORK/plan2.tsv"
jq -n --arg base "$BASE_URL" --slurpfile a "$WORK/entries.jsonl" '{tag_base_url_default: $base, assets: $a}' > "$WORK/lock.json"

# Release notes for the draft (also kept next to the staged files).
if [ "$n_upload" -gt 0 ]; then
    {
        printf '# Build assets %s\n\n' "$TAG"
        printf 'Large build inputs for OpenMDict, fetched by `scripts/bootstrap-assets.sh` according to `preset-dicts/assets.lock.json`. '
        printf 'Dictionaries are built by the pipeline in `preset-dicts/`; see THIRD-PARTY-NOTICES.md and the LICENSE-*.txt files for their terms. '
        printf 'Every Release of this kind carries the complete compliance payload (THIRD-PARTY-NOTICES.md, the license texts and the corresponding source archives of the GPL dictionaries), including files unchanged since an earlier tag. '
        printf 'Pre-release: not an app release.\n\n'
        printf '| Asset | Size | SHA-256 |\n|---|---|---|\n'
        awk -F "$US" -v tag="$TAG" '$8 == tag { printf "| %s | %s | `%s` |\n", $3, $5, $6 }' "$WORK/plan2.tsv"
    } > "$STAGING/$TAG/RELEASE-NOTES.md"
fi

if [ "$MODE" = stage-only ]; then
    cp "$WORK/lock.json" "$LOCK"
    log "✓ Staged $(wc -l < "$WORK/plan2.tsv" | tr -d ' ') asset(s), $(human_size "$bytes_total") total, under $STAGING/<tag>/"
    log "✓ Wrote ${LOCK#"$REPO_ROOT"/} ($n_upload entries point at $TAG)"
    log "  Nothing was uploaded (--stage-only)."
    exit 0
fi

# ── Upload ──────────────────────────────────────────────────────────────────

if [ "$n_upload" -eq 0 ]; then
    cp "$WORK/lock.json" "$LOCK"
    log "Nothing to upload; ${LOCK#"$REPO_ROOT"/} rewritten (no content change)."
    exit 0
fi

if [ -z "$GH_REPO" ]; then
    GH_REPO=$(printf '%s' "$BASE_URL" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/releases/download$#\1#')
    [ "$GH_REPO" != "$BASE_URL" ] || die "cannot derive owner/name from $BASE_URL; pass --repo"
fi
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"

if gh release view "$TAG" --repo "$GH_REPO" --json isDraft,assets > "$WORK/release.json" 2>/dev/null; then
    if [ "$(jq -r '.isDraft' "$WORK/release.json")" != true ] && [ "$AMEND" -eq 0 ]; then
        die "release $TAG already exists and is published — pick a new --tag, or pass --amend to revise it in place"
    fi
    RELEASE_STATE=$(jq -r 'if .isDraft then "draft" else "published" end' "$WORK/release.json")
    log "→ Reusing existing release $TAG ($RELEASE_STATE)"
    jq -r '.assets[] | [.name, .size, (.digest // "")] | map(. // "" | tostring) | join("\u001f")' "$WORK/release.json" > "$WORK/existing.tsv"
    if [ "$AMEND" -eq 1 ] && [ -f "$STAGING/$TAG/RELEASE-NOTES.md" ]; then
        gh release edit "$TAG" --repo "$GH_REPO" --notes-file "$STAGING/$TAG/RELEASE-NOTES.md" >/dev/null
    fi
else
    RELEASE_STATE=new
    log "→ Creating draft pre-release $TAG on $GH_REPO"
    gh release create "$TAG" --repo "$GH_REPO" --prerelease --draft \
        --title "Build assets $TAG" --notes-file "$STAGING/$TAG/RELEASE-NOTES.md" >/dev/null
    : > "$WORK/existing.tsv"
fi

upload_files=()
while IFS=$US read -r status kind filename dest size sha tree tag out; do
    [ "$tag" = "$TAG" ] || continue
    [ "$status" != unchanged ] || [ "$AMEND" -eq 1 ] || continue
    [ -f "$out" ] || die "staged file missing: $out"
    existing_size=$(awk -F "$US" -v n="$filename" '$1 == n { print $2; exit }' "$WORK/existing.tsv")
    existing_digest=$(awk -F "$US" -v n="$filename" '$1 == n { print $3; exit }' "$WORK/existing.tsv")
    if [ -n "$existing_size" ]; then
        if [ "$existing_digest" = "sha256:$sha" ] || { [ -z "$existing_digest" ] && [ "$existing_size" = "$size" ]; }; then
            log "  already on release: $filename"
            continue
        fi
        [ "$AMEND" -eq 1 ] || die "$filename already exists on $TAG with different content; pass --amend to replace it"
        log "  replacing on release: $filename"
        gh release delete-asset "$TAG" "$filename" --repo "$GH_REPO" --yes >/dev/null
    fi
    upload_files+=("$out")
done < "$WORK/plan2.tsv"

if [ "${#upload_files[@]}" -gt 0 ]; then
    log "→ Uploading ${#upload_files[@]} asset(s) to $TAG…"
    gh release upload "$TAG" --repo "$GH_REPO" --clobber=false ${upload_files[@]+"${upload_files[@]}"}
fi

cp "$WORK/lock.json" "$LOCK"
log ""
if [ "$RELEASE_STATE" = published ]; then
    log "✓ Published release $TAG revised: ${#upload_files[@]} asset(s) replaced or added; ${LOCK#"$REPO_ROOT"/} rewritten."
    log "Next: scripts/check-assets.sh && git add preset-dicts/assets.lock.json && git commit"
else
    log "✓ Draft pre-release $TAG holds ${#upload_files[@]} uploaded asset(s); ${LOCK#"$REPO_ROOT"/} rewritten."
    log "Next:"
    log "  1. gh release view $TAG --repo $GH_REPO --web      # review the draft"
    log "  2. gh release edit $TAG --repo $GH_REPO --draft=false"
    log "  3. scripts/check-assets.sh && git add preset-dicts/assets.lock.json && git commit"
fi
