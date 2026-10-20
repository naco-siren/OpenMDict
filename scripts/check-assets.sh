#!/usr/bin/env bash
# check-assets.sh — consistency gate between the three places that describe
# the preset dictionaries and the on-demand model:
#
#   preset-dicts/preset-dictionaries.json       catalog shown by the app
#   preset-dicts/assets.lock.json               what bootstrap-assets.sh downloads
#   Apps/iOS/OpenMDict-iOS/OpenMDict-iOS.xcodeproj/project.pbxproj
#                                               what Xcode bundles and tags
#
# Checks (errors unless noted):
#   * catalog names == lock .mdx entries == .mdx file references in the pbxproj
#   * lock dests are preset-dicts/output/<Name>/<Name>.mdx; sizes match the
#     catalog's sizeBytes; exactly one model and one vocab entry
#   * the catalog's sha256 equals the lock's; previousSha256 never lists the
#     current hash or a duplicate; every catalog name has a CreationDate pin
#     in preset-dicts/build-pins.json (a rebuild must reproduce the file)
#   * every ODR dictionary's PBXBuildFile carries ASSET_TAGS = (<odrTag>) and
#     every bundled one carries none
#   * KnownAssetTags ⊇ catalog odrTags
#   * (warning) .mdx references not of the form
#     path = "../../../preset-dicts/output/<Name>/<Name>.mdx", sourceTree = SOURCE_ROOT,
#     and any machine-specific reference (home-directory path or absolute
#     sourceTree) left anywhere in the pbxproj
#   * (warning) ASSET_TAGS values not listed in KnownAssetTags
#   * (warning) THIRD-PARTY-NOTICES.md differs from the copy recorded in the
#     lock (the Release payload is stale until publish-assets.sh runs again)
#
# Usage: scripts/check-assets.sh [--strict]     (--strict: warnings fail too)
# Exit 1 on any error. Runs in CI after bootstrap-assets.sh.

set -euo pipefail
US=$'\037'   # field separator for the internal tables (tab would collapse empty fields in `read`)

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CATALOG="$REPO_ROOT/preset-dicts/preset-dictionaries.json"
LOCK="$REPO_ROOT/preset-dicts/assets.lock.json"
PBXPROJ="$REPO_ROOT/Apps/iOS/OpenMDict-iOS/OpenMDict-iOS.xcodeproj/project.pbxproj"
PINS="$REPO_ROOT/preset-dicts/build-pins.json"
MODEL_DEST="Apps/iOS/OpenMDict-iOS/Article Embeddings/all-MiniLM-L6-v2.mlpackage"
VOCAB_DEST="Apps/iOS/OpenMDict-iOS/Article Embeddings/vocab.txt"

STRICT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --strict) STRICT=1 ;;
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check-assets: unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

errors=0
warnings=0
fail() { printf 'error: %s\n' "$*" >&2; errors=$((errors + 1)); }
warn() {
    if [ "$STRICT" -eq 1 ]; then fail "$*"; else printf 'warning: %s\n' "$*" >&2; warnings=$((warnings + 1)); fi
}
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
[ -f "$CATALOG" ] || die "missing ${CATALOG#"$REPO_ROOT"/}"
[ -f "$LOCK" ] || die "missing ${LOCK#"$REPO_ROOT"/} (generate it with scripts/publish-assets.sh)"
[ -f "$PBXPROJ" ] || die "missing ${PBXPROJ#"$REPO_ROOT"/}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-assets.XXXXXX")
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT
export LC_ALL=C

# ── Catalog ─────────────────────────────────────────────────────────────────

jq -e '.dictionaries | type == "array"' "$CATALOG" >/dev/null || die "catalog has no .dictionaries array"
# filename  sizeBytes  source  odrTag  id
jq -r '.dictionaries[] | [.filename, (.sizeBytes // ""), (.source // ""), (.odrTag // ""), (.id // "")] | map(. // "" | tostring) | join("\u001f")' \
    "$CATALOG" > "$WORK/catalog.tsv"

while IFS=$US read -r filename size source odr_tag id; do
    case "$filename" in
        *.mdx) ;;
        *) fail "catalog entry $id: filename '$filename' does not end in .mdx" ;;
    esac
    case "$source" in
        odr) [ -n "$odr_tag" ] || fail "catalog entry $id: source=odr but no odrTag" ;;
        bundle) [ -z "$odr_tag" ] || warn "catalog entry $id: source=bundle but has odrTag '$odr_tag'" ;;
        *) fail "catalog entry $id: unknown source '$source'" ;;
    esac
    [ -n "$size" ] || fail "catalog entry $id: no sizeBytes"
done < "$WORK/catalog.tsv"

cut -d "$US" -f1 "$WORK/catalog.tsv" | sed 's/\.mdx$//' | sort > "$WORK/catalog.names"
sort -u "$WORK/catalog.names" > "$WORK/catalog.names.u"
if [ "$(wc -l < "$WORK/catalog.names")" -ne "$(wc -l < "$WORK/catalog.names.u")" ]; then
    fail "catalog has duplicate filenames: $(uniq -d "$WORK/catalog.names" | tr '\n' ' ')"
fi
awk -F "$US" '{ sub(/\.mdx$/, "", $1); print $1 "\037" $2 }' "$WORK/catalog.tsv" | sort > "$WORK/catalog.sizes"
awk -F "$US" '$4 != "" { print $4 }' "$WORK/catalog.tsv" | sort -u > "$WORK/catalog.tags"
n_catalog=$(wc -l < "$WORK/catalog.names.u" | tr -d ' ')

# ── Lock ────────────────────────────────────────────────────────────────────

jq -e '.assets | type == "array"' "$LOCK" >/dev/null || die "lock has no .assets array"
[ "$(jq -r '.tag_base_url_default // ""' "$LOCK")" != "" ] || fail "lock has no tag_base_url_default"

# kind  filename  dest  size  sha256  tag  tree_sha256
jq -r '.assets[] | [(.kind // ""), (.filename // ""), (.dest // ""), (.size // ""), (.sha256 // ""), (.tag // ""), (.tree_sha256 // "")] | map(. // "" | tostring) | join("\u001f")' \
    "$LOCK" > "$WORK/lock.tsv"

cut -d "$US" -f2 "$WORK/lock.tsv" | sort > "$WORK/lock.filenames"
dups=$(uniq -d "$WORK/lock.filenames" | tr '\n' ' ')
[ -z "$dups" ] || fail "lock has duplicate filenames: $dups"

: > "$WORK/lock.names"
: > "$WORK/lock.sizes"
n_model=0; n_vocab=0
while IFS=$US read -r kind filename dest size sha tag tree; do
    [ -n "$filename" ] || { fail "lock entry without filename"; continue; }
    [ -n "$tag" ] || fail "lock entry $filename: no tag"
    printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' || fail "lock entry $filename: sha256 is not 64 hex chars"
    printf '%s' "$size" | grep -Eq '^[0-9]+$' || fail "lock entry $filename: size is not an integer"
    case "$kind" in
        mdx)
            name=${filename%.mdx}
            [ "$name" != "$filename" ] || fail "lock entry $filename: kind mdx but filename lacks .mdx"
            [ "$dest" = "preset-dicts/output/$name/$name.mdx" ] \
                || fail "lock entry $filename: dest is '$dest', expected preset-dicts/output/$name/$name.mdx"
            printf '%s\n' "$name" >> "$WORK/lock.names"
            printf '%s\037%s\n' "$name" "$size" >> "$WORK/lock.sizes"
            ;;
        model)
            n_model=$((n_model + 1))
            [ "$dest" = "$MODEL_DEST" ] || fail "lock entry $filename: model dest is '$dest', expected $MODEL_DEST"
            printf '%s' "$tree" | grep -Eq '^[0-9a-f]{64}$' || fail "lock entry $filename: model entry needs tree_sha256"
            ;;
        vocab)
            n_vocab=$((n_vocab + 1))
            [ "$dest" = "$VOCAB_DEST" ] || fail "lock entry $filename: vocab dest is '$dest', expected $VOCAB_DEST"
            ;;
        notice)
            [ -z "$dest" ] || warn "lock entry $filename: notice entries should not have a dest (bootstrap ignores them)"
            ;;
        *) fail "lock entry $filename: unknown kind '$kind'" ;;
    esac
done < "$WORK/lock.tsv"
[ "$n_model" -eq 1 ] || fail "lock must have exactly one model entry (found $n_model)"
[ "$n_vocab" -eq 1 ] || fail "lock must have exactly one vocab entry (found $n_vocab)"
sort -o "$WORK/lock.names" "$WORK/lock.names"
sort -o "$WORK/lock.sizes" "$WORK/lock.sizes"
n_lock=$(wc -l < "$WORK/lock.names" | tr -d ' ')

# The Release carries a copy of THIRD-PARTY-NOTICES.md and the lock records its
# hash; an edit after the last publish leaves the published copy stale.
notices_sha=$(awk -F "$US" '$1 == "notice" && $2 == "THIRD-PARTY-NOTICES.md" { print $5; exit }' "$WORK/lock.tsv")
if [ -n "$notices_sha" ] && [ -f "$REPO_ROOT/THIRD-PARTY-NOTICES.md" ]; then
    have=$(shasum -a 256 "$REPO_ROOT/THIRD-PARTY-NOTICES.md" | awk '{print $1}')
    [ "$have" = "$notices_sha" ] || warn "THIRD-PARTY-NOTICES.md differs from the copy recorded in the lock (re-run scripts/publish-assets.sh so the Release payload is refreshed)"
fi

# ── Catalog vs lock ─────────────────────────────────────────────────────────

comm -23 "$WORK/catalog.names.u" "$WORK/lock.names" | while read -r n; do fail "in catalog but not in lock: $n.mdx"; done
comm -13 "$WORK/catalog.names.u" "$WORK/lock.names" | while read -r n; do fail "in lock but not in catalog: $n.mdx"; done
# (the while loops above run in subshells; recount below)
errors=$((errors + $(comm -3 "$WORK/catalog.names.u" "$WORK/lock.names" | wc -l)))

join -t "$US" "$WORK/catalog.sizes" "$WORK/lock.sizes" | awk -F "$US" '$2 != $3 { print $1 "\037" $2 "\037" $3 }' > "$WORK/size.diff"
while IFS=$US read -r n a b; do
    fail "$n.mdx: catalog sizeBytes $a != lock size $b (regenerate the catalog sizes or the lock)"
done < "$WORK/size.diff"

# The catalog's sha256 is what the app compares with an installed preset's
# dictionary ID to offer an update, so it must be the published file's hash.
jq -r '.dictionaries[] | [(.filename | sub("\\.mdx$"; "")), (.sha256 // "")] | join("\u001f")' "$CATALOG" | sort > "$WORK/catalog.sha"
jq -r '.assets[] | select(.kind == "mdx") | [(.filename | sub("\\.mdx$"; "")), .sha256] | join("\u001f")' "$LOCK" | sort > "$WORK/lock.sha"
join -t "$US" "$WORK/catalog.sha" "$WORK/lock.sha" | awk -F "$US" '$2 != $3 { print $1 "\037" $2 "\037" $3 }' > "$WORK/sha.diff"
while IFS=$US read -r n a b; do
    if [ -z "$a" ]; then
        fail "$n.mdx: catalog has no sha256 (run preset-dicts/scripts/sync_catalog_with_output.py)"
    else
        fail "$n.mdx: catalog sha256 ${a:0:12}… != lock ${b:0:12}… (installed copies would be offered the wrong update)"
    fi
done < "$WORK/sha.diff"

# previousSha256 is the list of builds the app may replace; listing the
# current build would make it "update" to itself.
jq -r '.dictionaries[] | . as $d | ($d.previousSha256 // []) as $p
      | select(($p | index($d.sha256)) != null or ($p | length) != ($p | unique | length))
      | $d.filename' "$CATALOG" > "$WORK/prev.bad"
while IFS= read -r n; do
    fail "$n: previousSha256 lists the current sha256 or a duplicate"
done < "$WORK/prev.bad"

# CreationDate is part of the file hash; without a pin a rebuild of
# unchanged content gets a new hash and every install is offered an update.
if [ -f "$PINS" ]; then
    jq -r '.dictionaries[].filename' "$CATALOG" | sort > "$WORK/catalog.names"
    jq -r 'keys[]' "$PINS" | sort > "$WORK/pins.names"
    comm -23 "$WORK/catalog.names" "$WORK/pins.names" > "$WORK/pins.missing"
    while IFS= read -r n; do
        fail "$n: no CreationDate pin in preset-dicts/build-pins.json (a rebuild would change its hash)"
    done < "$WORK/pins.missing"
else
    fail "missing preset-dicts/build-pins.json (CreationDate pins)"
fi

# ── pbxproj: file references ────────────────────────────────────────────────

grep -E 'isa = PBXFileReference;.*\.mdx' "$PBXPROJ" > "$WORK/pbx.refs" || true
: > "$WORK/pbx.names"
while IFS= read -r line; do
    path=$(printf '%s\n' "$line" | sed -E 's/.*[[:space:]]path = ("([^"]*)"|([^;]*));.*/\2\3/')
    tree=$(printf '%s\n' "$line" | sed -E 's/.*sourceTree = ("([^"]*)"|([^;]*));.*/\2\3/')
    name=$(basename "$path")
    name=${name%.mdx}
    printf '%s\n' "$name" >> "$WORK/pbx.names"
    if [ "$path" != "../../../preset-dicts/output/$name/$name.mdx" ] || [ "$tree" != SOURCE_ROOT ]; then
        warn "pbxproj: $name.mdx is not referenced as path = \"../../../preset-dicts/output/$name/$name.mdx\" with sourceTree = SOURCE_ROOT (path = '$path', sourceTree = '$tree')"
    fi
done < "$WORK/pbx.refs"
sort -o "$WORK/pbx.names" "$WORK/pbx.names"
dups=$(uniq -d "$WORK/pbx.names" | tr '\n' ' ')
[ -z "$dups" ] || fail "pbxproj references these dictionaries more than once: $dups"
sort -u -o "$WORK/pbx.names" "$WORK/pbx.names"
n_pbx=$(wc -l < "$WORK/pbx.names" | tr -d ' ')

errors=$((errors + $(comm -3 "$WORK/catalog.names.u" "$WORK/pbx.names" | wc -l)))
comm -23 "$WORK/catalog.names.u" "$WORK/pbx.names" | while read -r n; do
    printf 'error: in catalog but not referenced by the pbxproj: %s.mdx\n' "$n" >&2
done
comm -13 "$WORK/catalog.names.u" "$WORK/pbx.names" | while read -r n; do
    printf 'error: referenced by the pbxproj but not in catalog: %s.mdx\n' "$n" >&2
done

# The pattern is split with parentheses on purpose so that this script itself
# does not match a repository-wide search for those two strings.
n_abs=$(grep -c -E '/(U)sers/|<(a)bsolute>' "$PBXPROJ" || true)
[ "$n_abs" -eq 0 ] || warn "pbxproj still contains $n_abs machine-specific reference(s) (home-directory path or absolute sourceTree; run ruby scripts/relink-project-assets.rb)"

# ── pbxproj: build files and ASSET_TAGS ─────────────────────────────────────

grep -E '\.mdx in Resources \*/ = \{isa = PBXBuildFile;' "$PBXPROJ" > "$WORK/pbx.builds" || true
: > "$WORK/pbx.tags"
while IFS= read -r line; do
    name=$(printf '%s\n' "$line" | sed -E 's#.*/\* ([^*]*\.mdx) in Resources \*/.*#\1#')
    tag=""
    case "$line" in
        *ASSET_TAGS*) tag=$(printf '%s\n' "$line" | sed -E 's/.*ASSET_TAGS = \([[:space:]]*"?([^",)]*)"?.*/\1/') ;;
    esac
    printf '%s\037%s\n' "${name%.mdx}" "$tag" >> "$WORK/pbx.tags"
done < "$WORK/pbx.builds"
sort -o "$WORK/pbx.tags" "$WORK/pbx.tags"

while IFS=$US read -r filename size source odr_tag id; do
    name=${filename%.mdx}
    have=$(awk -F "$US" -v n="$name" '$1 == n { print $2; found = 1 } END { if (!found) print "<none>" }' "$WORK/pbx.tags")
    case "$source" in
        odr)
            if [ "$have" = "<none>" ]; then
                fail "pbxproj: $filename has no PBXBuildFile in the Resources phase"
            elif [ "$have" != "$odr_tag" ]; then
                fail "pbxproj: $filename has ASSET_TAGS '${have:-<none>}', catalog odrTag is '$odr_tag' (run ruby scripts/relink-project-assets.rb --sync)"
            fi
            ;;
        bundle)
            [ "$have" = "<none>" ] && fail "pbxproj: $filename has no PBXBuildFile in the Resources phase"
            [ -z "$have" ] || [ "$have" = "<none>" ] || fail "pbxproj: bundled $filename must not carry ASSET_TAGS (has '$have')"
            ;;
    esac
done < "$WORK/catalog.tsv"

# ── pbxproj: KnownAssetTags ─────────────────────────────────────────────────

sed -n '/KnownAssetTags = (/,/);/p' "$PBXPROJ" \
    | grep -v 'KnownAssetTags = (' | grep -v '^[[:space:]]*);' \
    | sed -E 's/^[[:space:]]*"?([^",]*)"?,?[[:space:]]*$/\1/' | grep -v '^$' | sort -u > "$WORK/known.tags" || true
n_known=$(wc -l < "$WORK/known.tags" | tr -d ' ')
[ "$n_known" -gt 0 ] || fail "pbxproj has no KnownAssetTags"

errors=$((errors + $(comm -23 "$WORK/catalog.tags" "$WORK/known.tags" | wc -l)))
comm -23 "$WORK/catalog.tags" "$WORK/known.tags" | while read -r t; do
    printf 'error: catalog odrTag %s is missing from KnownAssetTags\n' "$t" >&2
done

grep -oE 'ASSET_TAGS = \([^)]*\)' "$PBXPROJ" | grep -oE '"[^"]+"' | tr -d '"' | sort -u > "$WORK/used.tags" || true
comm -23 "$WORK/used.tags" "$WORK/known.tags" | while read -r t; do
    printf 'warning: ASSET_TAGS value %s is not listed in KnownAssetTags\n' "$t" >&2
done
n_unknown_used=$(comm -23 "$WORK/used.tags" "$WORK/known.tags" | wc -l | tr -d ' ')
if [ "$n_unknown_used" -gt 0 ]; then
    if [ "$STRICT" -eq 1 ]; then errors=$((errors + n_unknown_used)); else warnings=$((warnings + n_unknown_used)); fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────

printf 'check-assets: catalog %s, lock %s mdx (+ model + vocab), pbxproj %s mdx refs, %s catalog odrTags, %s KnownAssetTags\n' \
    "$n_catalog" "$n_lock" "$n_pbx" "$(wc -l < "$WORK/catalog.tags" | tr -d ' ')" "$n_known"
if [ "$errors" -gt 0 ]; then
    printf 'check-assets: FAILED with %d error(s), %d warning(s)\n' "$errors" "$warnings" >&2
    exit 1
fi
printf 'check-assets: OK (%d warning(s))\n' "$warnings"
