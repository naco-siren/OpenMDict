#!/usr/bin/env bash
# ── fetch_data.sh ─────────────────────────────────────────────
#
# Download the source data of every preset dictionary into data/.
#
# Usage:
#   ./scripts/fetch_data.sh                       Fetch every source
#   ./scripts/fetch_data.sh cedict wordnet        Fetch the named sources
#   ./scripts/fetch_data.sh --refresh jmdict kanjidic2
#                                                 Also download the current
#                                                 EDRDG releases (see below)
#   ./scripts/fetch_data.sh --list                List the sources
#
# Every input is pinned to the URL (a versioned path or a commit) and the
# SHA-256 of the file the published dictionaries were built from. Existing
# files are not downloaded again, but they are always checked:
#
#   ✗ error    a pinned file does not match its SHA-256 (delete it and
#              re-run if the download was incomplete)
#   ! warning  the upstream serves only its latest release under a fixed
#              URL (CC-CEDICT, Kaikki.org, CrossWire KorRV, eBible.org
#              grcbyz) and the local file is not the release the published
#              dictionary was built from: a rebuild will differ from it
#
# A source that fails is reported and the remaining sources still run; the
# exit status is 1 when any source failed. Warnings are repeated at the end.
#
# JMdict and KANJIDIC2 (EDRDG) are replaced upstream every day and older
# releases are not kept. A download is filed under its own release
# (data/jmdict/<JMdict created date>/, data/kanjidic2-<database_version>/)
# and never overwrites the release the build is pinned to. The EDRDG
# licence (section 4) requires regular updates: `--refresh jmdict kanjidic2`
# downloads the current releases; then move the pins (here and in
# build_jmdict_mdx.py / build_kanjidic2_mdx.py) and rebuild. See
# ../MAINTAINING.md, "Refreshing the EDRDG data".
#
# Prerequisites: bash 3.2+, curl, gzip, unzip, tar (with xz), shasum or
# sha256sum
# ──────────────────────────────────────────────────────────────

set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
DATA=data
mkdir -p "$DATA"

REFRESH=0
CURRENT=""
WARN_LOG=$(mktemp "${TMPDIR:-/tmp}/fetch_data.XXXXXX")
trap 'rm -f "$WARN_LOG"' EXIT

# ── Helpers ───────────────────────────────────────────────────

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

# dl URL DEST -- download unless DEST exists. A failed download leaves
# nothing behind (it is written to DEST.part first).
dl() {
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        yellow "  skip (exists): $dest"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    echo "  ↓ $url"
    if ! curl -fSL --retry 3 --progress-bar -o "$dest.part" "$url"; then
        rm -f "$dest.part"
        red "  ✗ download failed: $url"
        return 1
    fi
    mv "$dest.part" "$dest"
    green "  ✓ $dest"
}

# verify_sha256 FILE EXPECTED -- error when a pinned file is not the one
# the published dictionaries were built from.
verify_sha256() {
    local file="$1" want="$2" got
    got=$(sha256_of "$file")
    if [[ "$got" != "$want" ]]; then
        red "  ✗ sha256 mismatch: $file"
        red "      expected $want"
        red "      got      $got"
        red "    (delete the file and re-run if the download was incomplete)"
        return 1
    fi
    green "  ✓ sha256 ok: $file"
}

# note_warning TEXT -- print a warning and repeat it in the final summary.
note_warning() {
    yellow "  ! $*"
    printf '%s: %s\n' "$CURRENT" "$*" >> "$WARN_LOG"
}

# check_latest FILE EXPECTED WHAT -- for upstreams that serve only their
# latest release under a fixed URL: a different file is not an error, but a
# rebuild from it will not reproduce the published dictionary.
check_latest() {
    local file="$1" want="$2" what="$3" got
    got=$(sha256_of "$file")
    if [[ "$got" == "$want" ]]; then
        green "  ✓ sha256 ok: $file"
        return 0
    fi
    note_warning "$file is not the build input of the published dictionary ($what; pinned sha256 ${want:0:16}…, got ${got:0:16}…)"
}

# fetch_pinned DEST URL SHA256 -- download (unless present) and verify.
fetch_pinned() {
    dl "$2" "$1" || return 1
    verify_sha256 "$1" "$3"
}

# ── CC-CEDICT (Chinese-English) ───────────────────────────────
# MDBG publishes only the latest release under an unversioned URL. The
# build reads data/cedict_ts.u8; pinned: the release the published
# CEDICT-ZH-EN.mdx (and CC-Canto's character table) was built from.
CEDICT_RELEASE="2026-01-02T04:01:30Z"
CEDICT_SHA256="fca2b8d7912c0bb0f4ac87e47692a197bcdefb4fd33a088bd6b5c2d8747c0c86"
fetch_cedict() {
    green "=== CC-CEDICT ==="
    echo "  Source: https://cc-cedict.org/ (MDBG export; latest release only)"
    echo "  License: CC-BY-SA 4.0"
    dl "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz" \
       "$DATA/cedict_ts.u8.gz" || return 1
    if [[ ! -f "$DATA/cedict_ts.u8" ]]; then
        gunzip -c "$DATA/cedict_ts.u8.gz" > "$DATA/cedict_ts.u8.part"
        mv "$DATA/cedict_ts.u8.part" "$DATA/cedict_ts.u8"
        green "  ✓ decompressed → cedict_ts.u8"
    fi
    local date
    date=$(grep -m1 '^#! date=' "$DATA/cedict_ts.u8" | cut -d= -f2 | tr -d '\r' || true)
    check_latest "$DATA/cedict_ts.u8" "$CEDICT_SHA256" \
        "CC-CEDICT release ${date:-unknown}, pinned $CEDICT_RELEASE"
}

# ── JMdict + Kanjium (Japanese-English) ───────────────────────
# JMdict_e.gz is replaced daily and its URL carries no version, so each
# download is filed under data/jmdict/<its "JMdict created" date>/.
# JMDICT_RELEASE / JMDICT_SHA256 must match build_jmdict_mdx.py.
JMDICT_RELEASE="2026-10-18"
JMDICT_SHA256="9cb6cb9806e031f04e61ce0026ce7e7be06f53de259c3c4813375f561ee163f6"
KANJIUM_COMMIT="685d4d723d6d20bf9beb169103aeac188eb067ad"
KANJIUM_SHA256="8bd0dd127dab32ceec94cb03ab1ba6b68858ea73421dfa1731af2f373deb4f20"

# Download the current JMdict release into data/jmdict/<created>/.
fetch_jmdict_current() {
    local url="https://www.edrdg.org/pub/Nihongo/JMdict_e.gz" tmp created dest sum
    tmp=$(mktemp "$DATA/JMdict_e.XXXXXX")
    echo "  ↓ $url"
    if ! curl -fSL --retry 3 --progress-bar -o "$tmp" "$url"; then
        rm -f "$tmp"
        red "  ✗ download failed: $url"
        return 1
    fi
    created=$( (gzip -dc "$tmp" 2>/dev/null || true) | head -n 2000 \
               | sed -n 's/.*<!-- JMdict created: \([0-9-]*\) -->.*/\1/p' )
    if [[ -z "$created" ]]; then
        rm -f "$tmp"
        red "  ✗ no 'JMdict created' date found in the download"
        return 1
    fi
    dest="$DATA/jmdict/$created/JMdict_e.gz"
    if [[ -f "$dest" ]]; then
        rm -f "$tmp"
        yellow "  skip (exists): $dest"
    else
        mkdir -p "$DATA/jmdict/$created"
        mv "$tmp" "$dest"
        chmod 644 "$dest"
        green "  ✓ $dest"
    fi
    sum=$(sha256_of "$dest")
    echo "  JMdict release $created, sha256 $sum"
    if [[ "$created" == "$JMDICT_RELEASE" ]]; then
        verify_sha256 "$dest" "$JMDICT_SHA256"
    else
        note_warning "JMdict release $created downloaded; the build is pinned to $JMDICT_RELEASE. To build it, set JMDICT_RELEASE=\"$created\" and JMDICT_SHA256=\"$sum\" here and in scripts/build_jmdict_mdx.py"
    fi
}

fetch_jmdict() {
    green "=== JMdict + Kanjium ==="
    echo "  Source: https://www.edrdg.org/jmdict/ (daily release, filed by its 'JMdict created' date)"
    echo "  License: CC-BY-SA 4.0 (EDRDG licence: https://www.edrdg.org/edrdg/licence.html)"
    local pinned="$DATA/jmdict/$JMDICT_RELEASE/JMdict_e.gz"
    if [[ -f "$pinned" ]]; then
        verify_sha256 "$pinned" "$JMDICT_SHA256"
    else
        yellow "  pinned release $JMDICT_RELEASE not present (EDRDG keeps only the current one)"
    fi
    if [[ ! -f "$pinned" || $REFRESH -eq 1 ]]; then
        fetch_jmdict_current
    fi
    # Kanjium, pinned to a commit (master/data/source_files/kanjium_accents.txt
    # is gone upstream).
    fetch_pinned "$DATA/kanjium_accents.txt" \
        "https://raw.githubusercontent.com/mifunetoshiro/kanjium/$KANJIUM_COMMIT/data/source_files/raw/accents.txt" \
        "$KANJIUM_SHA256"
}

# ── Kaikki.org / Wiktextract (10 languages) ───────────────────
# kaikki.org serves only its latest extract (and marks these per-language
# files as deprecated). Pinned: the snapshot the published Kaikki-*.mdx
# were built from (downloaded 2026-02-07/08).
KAIKKI_SHA256="
Spanish d98dcdae508ede32986ad6cafd3b2a0ab16b138cacb94437a9f058713d988c06
French e327e253e76cb4fc1e70be201a0f3a01b8a33885557dd1519643cbc98b110732
Russian 654fe3c699945f730da9756aae4f710f46a8e9ba693cba77bdd03d46e9e836ee
Italian 561109368452113c7295da5bfccd777de4b6398a349e6b925360a59323e8507c
Portuguese a05da4abb2eabea1551fada4a2d11e13da8b0473e73ca6f5eb2dad0571cc79a4
Greek 60b793ededf6c26e5f5e6cfef729fd543232975555a0406898e9e0ea45507e0f
Turkish 6843eb5d95b2a08f27f881dc5086671edb7e772f51e9ac75ad636d2a6475a513
Latin 30d103f5ef0dcc586b801d451a950c922015b482e2bb6488b086814223c40aed
Korean 8c79536fa57e2be045d6ecdd55cd26fef7a571ce2c9187b6f62af1e5e53eb8f3
Arabic b0d2fcd7d61375bd93114207dd10e3dd2176ac4e05d20ad013e263885f4ee7ad
"
fetch_kaikki() {
    green "=== Kaikki.org (Wiktextract) ==="
    echo "  Source: https://kaikki.org/dictionary/<Language>/ (English Wiktionary extract; latest only)"
    echo "  License: CC BY-SA 4.0 (Wiktionary text, also GFDL); © Wiktionary contributors"
    echo "  NOTE: kaikki.org marks these per-language JSONL files DEPRECATED;"
    echo "  the raw wiktextract dump is at https://kaikki.org/dictionary/rawdata.html"
    local lang sha bad=0
    while read -r lang sha; do
        [[ -n "$lang" ]] || continue
        if ! dl "https://kaikki.org/dictionary/$lang/kaikki.org-dictionary-$lang.jsonl" \
                "$DATA/kaikki-$lang.jsonl"; then
            echo "    → Visit https://kaikki.org/dictionary/$lang/ and save the JSONL as $DATA/kaikki-$lang.jsonl"
            bad=$((bad + 1))
            continue
        fi
        check_latest "$DATA/kaikki-$lang.jsonl" "$sha" "Kaikki.org $lang snapshot of 2026-02"
    done <<< "$KAIKKI_SHA256"
    [[ $bad -eq 0 ]] || { red "  ✗ $bad Kaikki download(s) failed"; return 1; }
}

# ── WikDict (26 SQLite3 bilingual dictionaries) ───────────────
# Pinned release 2_2025-11 (build_wikdict_mdx.py WIKDICT_RELEASE). Do not
# switch to .../sqlite/2/: it always serves the newest release, and another
# release changes every WikDict preset.
WIKDICT_RELEASE="2_2025-11"
WIKDICT_SHA256="
09f5c35de55e5d0add6d185521e3d31a072377f06a884104f69eefb42c5ee521 de-en
1b4e0ab4a978e91b1c9b7070b81204b6657325c7f79dbe5315655c107f1a83b4 de-ru
999cd38c419ace85fadd7d9ca960162d79cad1792843cd970854db736344c4cd el-en
e9bef4ca97ae36240c855c9f128a0c65178ce675d1ef74a227da7ef72db8c650 en-de
1a40991d4060bd749aa4036975d2ec07d8e6502b24fe60f15ea2aa6dd9dff3b6 en-el
cf2e59da306249dcc36a0e45405540876c8a0aa0abc153117e50de1c61289095 en-es
dfeb81bdbe58a232c142f5c70f7636a180845381ff83eac7132ca127743c6056 en-fr
062f72be24c65167202d9488e1e6b984f4ec76a42b74477a26c9ccb1b5a999ae en-it
a0df3c8d90edd3f6cf8d4817adc858aed5d0a31fd5374ab7ce85b53c87ecf9d3 en-la
14527b411759314834858ee1574819e2f006509c18192d9e0a9f93bc4c4dffad en-pt
cb8dc6e97c44fcddd45592d684cfcc0c8ccc0bc18af4b39bccb0f229a8a457b1 en-ru
827254ac10a37402dd22da00b59394bb3479b33670445a8ea9265275f853e5bc en-tr
0c94c861761cc50e10993092395bffd43bd342e1d727fdf85f282ebbd6eb638c es-en
c3ce54f79d350f4e7d49bcb59b2b843860cffbd4e0c2b554970be3db3af3d9b5 es-fr
6bcae277e87258185810d4e90c4cca0cc54d905ff7753bd413df989cb4c00a9f es-pt
5e2c81dc7d0f70e085f4f943b3d7bf9dddf5c901ba15285d7fc7a71d5f8c0e89 fr-en
7753b54f0d22f00a9d52dad1dd747455d9ec6223f5855c9c44db7c3af8ef3c37 fr-es
6866af40933defa6670720b88ad03e607d0da715837bc01c23ca2907c498644f fr-ru
4560ab75ffec9af3490ee0bfb1e9bbeb255d2e286c9c23b78f18f919686d3f6e it-en
6dfcb8aec8aeaf378ad58ce680ee43f50a35c1ae8b9500d9286f5f1f758185c5 la-en
7eb2d3e570093738a322a6b39f26f48da5ab0e4b624be958d49fa85af1a8a7f8 pt-en
54cb2c7fc73c4486965ca3cd1f8a14ce4f98d41e186564e3d4238ea5625732dd pt-es
a6eae4613641a83dd3c3bc615970b85af996b5aad1f0fe10c7c5d5d40b4a3f90 ru-de
ccfdc98bed1b01a34b848ac2883795c9b0f8e58998cb2ba45d015a66f860f30a ru-en
2254e705b78e8d30324d8627fcf376074a57382cdda8b6a0dccb30832277eee3 ru-fr
7420e4500785cb4ab87d3a588588f6932e99b00be0e5b599a73c53ff17b042b8 tr-en
"
fetch_wikdict() {
    green "=== WikDict ==="
    echo "  Source: https://www.wikdict.com/page/download (release $WIKDICT_RELEASE, pinned)"
    echo "  License: CC-BY-SA 4.0 (DBnary dataset: CC-BY-SA 3.0)"
    local base="https://download.wikdict.com/dictionaries/sqlite/$WIKDICT_RELEASE"
    local sha pair bad=0
    while read -r sha pair; do
        [[ -n "$sha" ]] || continue
        fetch_pinned "$DATA/wikdict/$pair.sqlite3" "$base/$pair.sqlite3" "$sha" \
            || bad=$((bad + 1))
    done <<< "$WIKDICT_SHA256"
    [[ $bad -eq 0 ]] || { red "  ✗ $bad WikDict file(s) missing or not release $WIKDICT_RELEASE"; return 1; }
    # build_wikdict_mdx.py takes English word forms and spelling pairs for
    # its redirects from Open English WordNet.
    fetch_wordnet
}

# ── FreeDict (German ↔ English TEI XML) ───────────────────────
# Release 1.9-fd1 (2022-04-15) is the newest. The archives are kept next to
# the extracted trees: they are the GPL Corresponding Source that
# scripts/publish-assets.sh attaches to the asset Release.
FREEDICT_VERSION="1.9-fd1"
fetch_freedict() {
    green "=== FreeDict ==="
    echo "  Source: https://freedict.org/ (deu-eng, eng-deu $FREEDICT_VERSION)"
    echo "  License: GPL-3.0-or-later AND AGPL-3.0-or-later"
    local pair want archive
    for pair in deu-eng eng-deu; do
        case "$pair" in
            deu-eng) want=8ea17f210e15f2f999792d9560c686a3d7df43c5b1506db2e0a1a6eac01ac6cf ;;
            eng-deu) want=83a02d8eace3fbb460fa96c32c2d964a9bc1e1a63ea754021ac33042ee2d1d5f ;;
        esac
        archive="$DATA/freedict/freedict-$pair.src.tar.xz"
        fetch_pinned "$archive" \
            "https://download.freedict.org/dictionaries/$pair/$FREEDICT_VERSION/freedict-$pair-$FREEDICT_VERSION.src.tar.xz" \
            "$want"
        if [[ -f "$DATA/freedict/$pair/$pair.tei" ]]; then
            yellow "  skip (already extracted): $DATA/freedict/$pair/"
        else
            # whole tree: COPYING, Makefile, $pair.tei, schema files
            tar -xJf "$archive" -C "$DATA/freedict/"
            green "  ✓ extracted → $DATA/freedict/$pair/"
        fi
    done
}

# ── Wiktionary TSV (Korean, Arabic) ───────────────────────────
# Pinned to the commit the published dictionaries were built from (data of
# 2022-11-09). The upstream file names contain spaces.
WIKTIONARY_COMMIT="296bb74c5bd1b51dcdfa59cd38d092edc741a50f"
fetch_wiktionary() {
    green "=== Wiktionary TSV ==="
    echo "  Source: https://github.com/Vuizur/Wiktionary-Dictionaries (commit ${WIKTIONARY_COMMIT:0:10})"
    echo "  License: CC-BY-SA 3.0 / GFDL"
    local base="https://raw.githubusercontent.com/Vuizur/Wiktionary-Dictionaries/$WIKTIONARY_COMMIT"
    fetch_pinned "$DATA/wiktionary-Korean-English.tsv" \
        "$base/Korean-English%20Wiktionary%20dictionary.tsv" \
        28b3bdfc9c4c0b48fc447b04386a210223d1ea4fd33a9f97e249b495236d157a
    fetch_pinned "$DATA/wiktionary-Arabic-English.tsv" \
        "$base/Arabic-English%20Wiktionary%20dictionary.tsv" \
        d7ff6872ed5648a7dc1d9cd0ec3aff50f40b5d1529cff31cc32a13bc73c94557
}

# ── Open English WordNet 2025+ ────────────────────────────────
# The release tag is "2025-edition" (".../download/2025/..." is a 404). The
# sha256 is the GitHub release digest: a different zip would silently change
# the bundled WordNet-EN.mdx. Also used by the Moby and WikDict builds.
fetch_wordnet() {
    green "=== Open English WordNet 2025+ ==="
    echo "  Source: https://en-word.net/ (release 2025-edition)"
    echo "  License: CC-BY 4.0 + Princeton WordNet License"
    local zip="$DATA/english-wordnet-2025-plus-json.zip"
    fetch_pinned "$zip" \
        "https://github.com/globalwordnet/english-wordnet/releases/download/2025-edition/english-wordnet-2025-plus-json.zip" \
        8832b8fa26a14c0ba8c99bb1ef8db6f9e122a6d9193b65ca9e0ef572580fee7e
    # Extract the JSON files into data/ (flat)
    if [[ ! -f "$DATA/entries-a.json" ]]; then
        unzip -o -j "$zip" -d "$DATA/" '*.json'
        green "  ✓ extracted WordNet JSON files"
    else
        yellow "  skip (already extracted): entries-*.json"
    fi
}

# ── Moby Thesaurus II ─────────────────────────────────────────
fetch_moby() {
    green "=== Moby Thesaurus II ==="
    echo "  Source: https://www.gutenberg.org/ebooks/3202"
    echo "  License: Public Domain"
    # Pinned to the file the published preset was built from (PG revision of
    # 2025-08-23, 24,853,275 bytes). A mismatch means Gutenberg revised the
    # file: review the change, then update the hash.
    fetch_pinned "$DATA/mthesaur.txt" \
        "https://www.gutenberg.org/files/3202/files/mthesaur.txt" \
        7c9742b1ed94435a893c0719b426725edb8a5242f8c526a75461bd6cee2dfd32
    # build_moby_thesaurus_mdx.py takes inflected forms and British/compound
    # spellings for its redirects from Open English WordNet.
    fetch_wordnet
}

# ── GCIDE (GNU CIDE / Webster's 1913) ─────────────────────────
# The tarball is also the GPL Corresponding Source asset recorded in
# assets.lock.json.
GCIDE_VERSION="0.53"
fetch_gcide() {
    green "=== GCIDE (Webster's 1913) ==="
    echo "  Source: https://ftp.gnu.org/gnu/gcide/ (gcide-$GCIDE_VERSION)"
    echo "  License: GPL-3.0+"
    local tar="$DATA/gcide/gcide-$GCIDE_VERSION.tar.xz"
    fetch_pinned "$tar" "https://ftp.gnu.org/gnu/gcide/gcide-$GCIDE_VERSION.tar.xz" \
        d3acbd984de1ce022d5d139903887b36232e436e30eca2cb0fb1c058dd7f319f
    if [[ ! -d "$DATA/gcide/gcide-$GCIDE_VERSION" ]]; then
        tar -xJf "$tar" -C "$DATA/gcide/"
        green "  ✓ extracted → gcide/gcide-$GCIDE_VERSION/"
    else
        yellow "  skip (already extracted): gcide/gcide-$GCIDE_VERSION/"
    fi
}

# ── Bible (14 translations: OSIS / USFX / Zefania XML, SWORD) ──
# Every input is pinned to the SHA-256 that build_bible_mdx.py was last
# built from. GitHub sources use commit-pinned URLs, so a mismatch is an
# error. CrossWire (KorRV) and eBible.org (grcbyz) serve only their latest
# release under a fixed URL, so a newer file there only warns: the build
# gates still check every book, chapter and verse of it.
OPEN_BIBLES="https://raw.githubusercontent.com/seven1m/open-bibles/f257a3559025c3f873b48a75019f53a9354ed7de"
GRATIS_BIBLE="https://raw.githubusercontent.com/gratis-bible/bible/252c53a7e51916f6f2bf329b477f1ca6f2016b15"
fetch_bible() {
    green "=== Bible translations ==="
    echo "  License: Public Domain (see each MDX description)"
    # local name | URL | sha256
    local pins="
kjv.osis.xml|$OPEN_BIBLES/eng-kjv.osis.xml|eeeae647fc28360ce47f9c0d5cc3b397b7fdd9913fe53dc9f44eb6deee50e253
cuv-simp.usfx.xml|$OPEN_BIBLES/chi-cuv-simp.usfx.xml|bea9f6e4fd35b70a67e3978ce8b9dc0ad853078e67472653cf1b34f357ae3abf
cuv-trad.usfx.xml|$OPEN_BIBLES/chi-cuv.usfx.xml|049e36ec3ee1b5c9bc2c8bfd2ca07f9f1f30398838f692d12ea38a092d41fe4b
kougo.osis.xml|$OPEN_BIBLES/jpn-kougo.osis.xml|6930015f5d0faf49f3038a7e2f482aeb45939510b6acb8a8fb1945640c1d91b6
spa-rv1909.usfx.xml|$OPEN_BIBLES/spa-rv1909.usfx.xml|233b4d6a87f833ac809d0e68dcf9ba83c709d612e914a357a4f5473782b703a3
deu-luther1912.osis.xml|$OPEN_BIBLES/deu-luther1912.osis.xml|5df33f4bf3e086b6490b467cf8ddbf4cf95126b2826efaddf17b223ddd07f92b
rus-synodal.zefania.xml|$OPEN_BIBLES/rus-synodal.zefania.xml|5ccd097980d85790d36525859cc9092ba7a31671dcdd46e4fa659f1d7fa57769
open-bibles-f257a35/por-almeida.usfx.xml|$OPEN_BIBLES/por-almeida.usfx.xml|4990d0d1909e2bd57aa6ecc2a2ce9a565b154aac8575b0242dc943ad796e643e
open-bibles-f257a35/lat-clementine.usfx.xml|$OPEN_BIBLES/lat-clementine.usfx.xml|5da5f3c07fa6896d4a2b45f5f309c3ece43e554fd059b31b8ae3688bbd182baf
fra-darby.osis.xml|$GRATIS_BIBLE/fr/frdarb.xml|6b9efd7c67b461adb3dece213d50be48139873a518428062ffec97062a9f4fad
it-diodati.osis.xml|$GRATIS_BIBLE/it/itadio.xml|cf0d7b5a2d428766019b8503f2ecce8d0715810d50232f83fb537f813307303f
ar-svd.osis.xml|$GRATIS_BIBLE/ar/arasvd.xml|c0ec084bba88874c0a6da8c5fced4d73b100791eb04afd85739e6d5c1ae7de76
"
    # Latest-release downloads: local name | URL | sha256 | zip member to extract
    local latest="
crosswire/KorRV-2.0.1.zip|https://www.crosswire.org/ftpmirror/pub/sword/packages/rawzip/KorRV.zip|194dd52ceabdefb97a60f6627de22e97990e0a43b1b388caf4013d010884ecd7|
grc-byzantine.usfx.xml|https://ebible.org/Scriptures/grcbyz_usfx.zip|7de60b43e142438822ed656ce17e19bb227503259bc677bc4693dda6533986a9|grcbyz_usfx.xml
"
    local bad=0 name url sum member tmp
    while IFS='|' read -r name url sum; do
        [[ -n "$name" ]] || continue
        fetch_pinned "$DATA/bible/$name" "$url" "$sum" || bad=$((bad + 1))
    done <<< "$pins"
    while IFS='|' read -r name url sum member; do
        [[ -n "$name" ]] || continue
        if [[ -n "$member" && ! -f "$DATA/bible/$name" ]]; then
            tmp=$(mktemp -d "${TMPDIR:-/tmp}/fetch_bible.XXXXXX")
            if dl "$url" "$tmp/src.zip" && unzip -p "$tmp/src.zip" "$member" > "$DATA/bible/$name.part"; then
                mv "$DATA/bible/$name.part" "$DATA/bible/$name"
                green "  ✓ extracted $member → $DATA/bible/$name"
            else
                rm -f "$DATA/bible/$name.part"
                bad=$((bad + 1))
            fi
            rm -rf "$tmp"
        elif [[ -z "$member" ]]; then
            dl "$url" "$DATA/bible/$name" || bad=$((bad + 1))
        fi
        [[ -f "$DATA/bible/$name" ]] || continue
        check_latest "$DATA/bible/$name" "$sum" "$url serves only its latest release; the build gates still check every book, chapter and verse"
    done <<< "$latest"
    if [[ $bad -ne 0 ]]; then
        red "  ✗ $bad Bible source(s) missing or not matching their pinned SHA-256"
        return 1
    fi
    green "  ✓ all 14 Bible sources present"
}

# ── Perseus (LSJ Greek + Lewis & Short Latin) ─────────────────
# Both lexica are fetched at a pinned PerseusDL/lexica commit and checked,
# so a fresh clone rebuilds the published files.
LEXICA="https://raw.githubusercontent.com/PerseusDL/lexica"
# Commit a6d6f11 (2025-09-24) is the latest that touches grc/lsj.
LSJ_COMMIT="a6d6f116c72691c190e78ce1c146b313a18f673c"
LSJ_SHA256="
15b1b7ca0a6c88e5a14e97f2339a0c7a7dfae71c028bdfb45fcee04c79a754f7 1
0b2d922d0d3a5cc194b6765911b5ff2b1c803f90f5fa0fff0ce96110019808d4 2
647e544d803afd1354efa9183c350db3c108009ba252ae3e63333e5b0f5944a8 3
abad8d625fd91a196a259c1242a9523715593f88f5c8a945ecdaa069b3c95d17 4
2e0ef90281c62e320f5386364b875f1000d1bcb22718369a5dbe0b6c68d5ad95 5
b5d4a0d47b75f69d8d32407475d65b655ed7ed1882187d8ac80175341cd56477 6
68cde966483878a3731c0bc04f317c414efe48048e4ec10d33f42dd51e91af0c 7
c3199971f9f5e8dbb5125a0961379e2d4526f9c1da64695daae1e63902b8da02 8
97b6f429d0a9564d350c63de5d4c115f9276419486300d8758fac0edb7b7a443 9
a754c36f74bd4d5c42bdb477fa339611c099fff801d65be3febe2d3e01efc89c 10
d4d49ef5bb84a4e0bbd6f3f7a097a5b5acba4f8bc60f6fc0ad5bc6f5c61cbed5 11
e835c276ede9318e5f6cf26692f1ecff848e4881ea506f9fc76acc1edfcaa826 12
4502e400086bfe41443cac913a2b88b2d66a5254d83c5b93d14c2d159dbefe9f 13
1e8a931c8cadc9ed5d9d0b52e9ca0ede46fb78581bb0ce9523af616d0809ebb3 14
2ef7bc1ae86fbc6a16ea19b0c5b1c7bc454f9da31d120ba1224797b51b831112 15
ade343b53f0d695551f786c0caeda9f25e1819a33339cddd68cf50c730bc1c38 16
237bf71d5e293c8cd5bc6c22e125e180cb11f28597b17c2efe0f9018c03e1fcc 17
dc9f99f5fad76cca0933f2010c7f4b8b8824951c8957fc084e19127b78c43d4d 18
82513a44c78b7a7a97fb9d95812406720e544cda1a9a2859993e2aeb682d0e15 19
af4b701108111db79fe8d54cb8c8977b0844a611ab046d1a9fd30166e8002505 20
c377dcf36490493b05a0543112b77bdc286855448b0903381eb4869d0806805c 21
cfe1f489fe78bfc61939d438f7f50712d8f4ce63968705d714377e09b44395f9 22
48e9b676136870c04bea9d18fc7aafae9cc651511c49b70e2b8421d838940eb0 23
6fdc01fede2d034371cdfa27d7549efcd9fb992d0007763422f553a9194aede6 24
51676aafd7a4ebca33b023d5252ed07cb9918262b1d64523512a98f6a1fdc644 25
aa9e60d7ff9e7a536690cd1b1a1540dac80597f7c6b3f444c35109b935885301 26
89b1606e526a20f948adf6976ecb0e7276d8c07013e266b57688d874fd30efdc 27
"
# Lewis & Short: eng2 is the maintained edition (Greek already in Unicode,
# the 2026 key and entry fixes); eng1 is the archival beta-code copy.
LS_COMMIT="edd73d89ce159e72a285829f849fb32ac250a4ea"   # 2026-08-26
LS_SHA256="a21c3799f42d33931b463c19a036b0e5c4a6504ccbd81ee55a262421a9e1836c"
fetch_perseus() {
    green "=== Perseus Digital Library ==="
    echo "  Source: https://github.com/PerseusDL/lexica (LSJ @${LSJ_COMMIT:0:7}, Lewis & Short eng2 @${LS_COMMIT:0:7})"
    echo "  License: CC BY-SA 4.0 (credit line in scripts/build_perseus_mdx.py)"
    # LSJ (Liddell-Scott-Jones Greek-English Lexicon). Upstream splits the
    # lexicon by initial letter into grc.lsj.perseus-eng1..27.xml (1 = α,
    # 2 = β, …); all 27 parts are needed.
    local sha i bad=0
    while read -r sha i; do
        [[ -n "$sha" ]] || continue
        fetch_pinned "$DATA/perseus/lsj/grc.lsj.perseus-eng$i.xml" \
            "$LEXICA/$LSJ_COMMIT/CTS_XML_TEI/perseus/pdllex/grc/lsj/grc.lsj.perseus-eng$i.xml" \
            "$sha" || bad=$((bad + 1))
    done <<< "$LSJ_SHA256"
    fetch_pinned "$DATA/perseus/ls-eng2/lat.ls.perseus-eng2.xml" \
        "$LEXICA/$LS_COMMIT/CTS_XML_TEI/perseus/pdllex/lat/ls/lat.ls.perseus-eng2.xml" \
        "$LS_SHA256" || bad=$((bad + 1))
    [[ $bad -eq 0 ]] || { red "  ✗ $bad Perseus file(s) missing or not matching their pinned SHA-256"; return 1; }
}

# ── KANJIDIC2 (Kanji reference) ───────────────────────────────
# EDRDG serves only the current kanjidic2.xml.gz (rebuilt about daily) and
# keeps no older releases, so each download is filed under
# data/kanjidic2-<its database_version>/ and never overwrites the release
# the build is pinned to. KANJIDIC2_DB_VERSION / KANJIDIC2_SHA256 must match
# scripts/build_kanjidic2_mdx.py, which checks both.
KANJIDIC2_DB_VERSION="2026-291"
KANJIDIC2_SHA256="6182a700e08a8f6a6646529b77f84f0d963ed33cd5c7516ff19e4ee642345446"

# Download the current KANJIDIC2 release into data/kanjidic2-<version>/.
fetch_kanjidic2_current() {
    local url="https://www.edrdg.org/kanjidic/kanjidic2.xml.gz" tmp ver dest sum
    tmp=$(mktemp "$DATA/kanjidic2.XXXXXX")
    echo "  ↓ $url"
    if ! curl -fSL --retry 3 --progress-bar -o "$tmp" "$url"; then
        rm -f "$tmp"
        red "  ✗ download failed: $url"
        return 1
    fi
    ver=$( (gunzip -c "$tmp" 2>/dev/null || true) \
           | sed -n -e 's:.*<database_version>\(.*\)</database_version>.*:\1:p' -e '/<\/header>/q' )
    if [[ -z "$ver" ]]; then
        rm -f "$tmp"
        red "  ✗ no <database_version> in the downloaded kanjidic2.xml.gz"
        return 1
    fi
    dest="$DATA/kanjidic2-$ver/kanjidic2.xml.gz"
    if [[ -f "$dest" ]]; then
        rm -f "$tmp"
        yellow "  skip (exists): $dest"
    else
        mkdir -p "$DATA/kanjidic2-$ver"
        mv "$tmp" "$dest"
        chmod 644 "$dest"
        green "  ✓ $dest"
    fi
    sum=$(sha256_of "$dest")
    echo "  KANJIDIC2 database_version $ver, sha256 $sum"
    if [[ "$ver" == "$KANJIDIC2_DB_VERSION" ]]; then
        verify_sha256 "$dest" "$KANJIDIC2_SHA256"
    else
        note_warning "KANJIDIC2 $ver downloaded; the build is pinned to $KANJIDIC2_DB_VERSION. To build it, set KANJIDIC2_DB_VERSION=\"$ver\" and KANJIDIC2_SHA256=\"$sum\" here and in scripts/build_kanjidic2_mdx.py"
    fi
}

fetch_kanjidic2() {
    green "=== KANJIDIC2 ==="
    echo "  Source: https://www.edrdg.org/wiki/index.php/KANJIDIC_Project (filed by database_version)"
    echo "  License: CC-BY-SA 4.0 (EDRDG licence: https://www.edrdg.org/edrdg/licence.html)"
    local pinned="$DATA/kanjidic2-$KANJIDIC2_DB_VERSION/kanjidic2.xml.gz"
    if [[ -f "$pinned" ]]; then
        verify_sha256 "$pinned" "$KANJIDIC2_SHA256"
    else
        yellow "  pinned release $KANJIDIC2_DB_VERSION not present (EDRDG keeps only the current one)"
    fi
    if [[ ! -f "$pinned" || $REFRESH -eq 1 ]]; then
        fetch_kanjidic2_current
    fi
}

# ── Unihan (Unicode CJK character database) ───────────────────
# Pinned release; UNIHAN_VERSION and UNIHAN_SHA256 must match UNIHAN_VERSION /
# UNIHAN_ZIP_SHA256 in scripts/build_unihan_mdx.py (it also checks every
# Unihan_*.txt header).
UNIHAN_VERSION="17.0.0"
UNIHAN_SHA256="f7a48b2b545acfaa77b2d607ae28747404ce02baefee16396c5d2d7a8ef34b5e"
fetch_unihan() {
    green "=== Unicode Unihan ==="
    echo "  Source: https://www.unicode.org/Public/$UNIHAN_VERSION/ucd/Unihan.zip"
    echo "  License: Unicode License v3 (https://www.unicode.org/license.txt)"
    fetch_pinned "$DATA/unihan/Unihan.zip" \
        "https://www.unicode.org/Public/$UNIHAN_VERSION/ucd/Unihan.zip" "$UNIHAN_SHA256"
    if [[ ! -f "$DATA/unihan/Unihan_Readings.txt" ]]; then
        unzip -o "$DATA/unihan/Unihan.zip" -d "$DATA/unihan/"
        green "  ✓ extracted Unihan_*.txt files"
    else
        yellow "  skip (already extracted): Unihan_*.txt"
    fi
}

# ── CC-Canto (Cantonese-English) ──────────────────────────────
# CC-Canto 2017-02-02 and the CC-CEDICT Cantonese Readings 2015-09-23 are
# the latest releases; cantonese.org offers them only as zip files (the old
# .../download/*.txt links return 404). Each zip holds one .txt; the
# SHA-256 values are those of the files the published MDX was built from.
fetch_cccanto() {
    green "=== CC-Canto ==="
    echo "  Source: https://cantonese.org/download.html"
    echo "  License: CC-BY-SA 3.0"
    local dir="$DATA/cc-canto" zip txt sum
    mkdir -p "$dir"
    while read -r zip txt sum; do
        [[ -n "$zip" ]] || continue
        if [[ -f "$dir/$txt" ]]; then
            yellow "  skip (exists): $dir/$txt"
        else
            dl "https://cantonese.org/$zip" "$dir/$zip" || return 1
            unzip -o -j "$dir/$zip" "$txt" -d "$dir/"
        fi
        verify_sha256 "$dir/$txt" "$sum"
    done <<'SUMS'
cccanto-170202.zip cccanto-webdist.txt 95392fbfe3c1690dc5b1460ad29ee451d17cad75935c00d5af2d18913f9bd940
cccedict-canto-readings-150923.zip cccedict-canto-readings-150923.txt 93ecbd7b7d58741bb8205107c736632438bf42dc07042b4090a66ce765432b0b
SUMS
    # build_cccanto_mdx.py also reads CC-CEDICT (cedict_ts.u8) as a character
    # table; it prints the release it read and warns when that is not the
    # release the published MDX was built with.
    [[ -f "$DATA/cedict_ts.u8" ]] || fetch_cedict
}

# ── Dispatcher ────────────────────────────────────────────────

ALL_SOURCES="wordnet cedict jmdict kaikki wikdict freedict wiktionary moby gcide bible perseus kanjidic2 unihan cccanto"

usage() { sed -n '2,/^# ──────/p' "$SELF" | sed 's/^# \{0,1\}//'; }

list_sources() {
    echo "Available data sources:"
    echo ""
    printf "  %-12s %s\n" "wordnet"    "Open English WordNet 2025+ (2025-edition)"
    printf "  %-12s %s\n" "cedict"     "CC-CEDICT (Chinese-English; latest only, pinned release checked)"
    printf "  %-12s %s\n" "jmdict"     "JMdict + Kanjium (Japanese-English; --refresh fetches the current release)"
    printf "  %-12s %s\n" "kaikki"     "Kaikki.org / Wiktextract (10 languages; latest only)"
    printf "  %-12s %s\n" "wikdict"    "WikDict SQLite3 $WIKDICT_RELEASE (26 language pairs)"
    printf "  %-12s %s\n" "freedict"   "FreeDict TEI $FREEDICT_VERSION (German ↔ English)"
    printf "  %-12s %s\n" "wiktionary" "Wiktionary TSV (Korean, Arabic)"
    printf "  %-12s %s\n" "moby"       "Moby Thesaurus II"
    printf "  %-12s %s\n" "gcide"      "GCIDE $GCIDE_VERSION / Webster's 1913"
    printf "  %-12s %s\n" "bible"      "14 Bible translations (pinned, SHA-256 checked)"
    printf "  %-12s %s\n" "perseus"    "Perseus LSJ + Lewis & Short (commit-pinned)"
    printf "  %-12s %s\n" "kanjidic2"  "KANJIDIC2 (Kanji reference; --refresh fetches the current release)"
    printf "  %-12s %s\n" "unihan"     "Unicode Unihan $UNIHAN_VERSION (CJK characters)"
    printf "  %-12s %s\n" "cccanto"    "CC-Canto (Cantonese-English)"
}

main() {
    local sources="" src
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list|-l) list_sources; return 0 ;;
            --refresh) REFRESH=1 ;;
            -h|--help) usage; return 0 ;;
            -*) red "Unknown option: $1"; usage; return 64 ;;
            *)
                if [[ " $ALL_SOURCES " == *" $1 "* ]]; then
                    sources="$sources $1"
                else
                    red "Unknown source: $1"
                    echo ""
                    list_sources
                    return 1
                fi
                ;;
        esac
        shift
    done
    if [[ -z "$sources" ]]; then
        sources=$ALL_SOURCES
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║   OpenMDict preset-dicts — Data Acquisition          ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo ""
    fi

    local failed="" rc
    for src in $sources; do
        CURRENT=$src
        # Each source runs in its own subshell with `set -e`, so one failure
        # is reported and the remaining sources still run.
        set +e
        ( set -e; "fetch_$src" )
        rc=$?
        set -e
        if [[ $rc -ne 0 ]]; then
            red "  ✗ $src failed (exit $rc); continuing with the remaining sources"
            failed="$failed $src"
        fi
        echo ""
    done

    if [[ -s "$WARN_LOG" ]]; then
        yellow "Warnings (rebuilds from these inputs will differ from the published dictionaries):"
        while IFS= read -r line; do yellow "  ! $line"; done < "$WARN_LOG"
        echo ""
    fi
    if [[ -n "$failed" ]]; then
        red "Failed:$failed"
        return 1
    fi
    green "Done. Run 'make all' to build all dictionaries."
}

main "$@"
