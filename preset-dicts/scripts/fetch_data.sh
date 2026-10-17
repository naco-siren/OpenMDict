#!/usr/bin/env bash
# ── fetch_data.sh ─────────────────────────────────────────────
#
# Download and normalize all source data for preset-dicts.
#
# Usage:
#   ./scripts/fetch_data.sh          Download everything
#   ./scripts/fetch_data.sh cedict   Download one source only
#   ./scripts/fetch_data.sh --list   List available sources
#
# Prerequisites: curl, gunzip, unzip, tar
# ──────────────────────────────────────────────────────────────

set -euo pipefail
cd "$(dirname "$0")/.."
DATA=data
mkdir -p "$DATA"

# ── Helpers ───────────────────────────────────────────────────

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }

dl() {
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        yellow "  skip (exists): $dest"
    else
        echo "  ↓ $url"
        curl -fSL --progress-bar -o "$dest" "$url"
        green "  ✓ $dest"
    fi
}

# ── 1. CC-CEDICT (Chinese-English) ───────────────────────────
fetch_cedict() {
    green "=== CC-CEDICT ==="
    echo "  Source: https://cc-cedict.org/"
    echo "  License: CC-BY-SA 4.0"
    dl "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz" \
       "$DATA/cedict_ts.u8.gz"
    if [[ ! -f "$DATA/cedict_ts.u8" ]]; then
        gunzip -k "$DATA/cedict_ts.u8.gz"
        green "  ✓ decompressed → cedict_ts.u8"
    fi
}

# ── 2. JMdict + Kanjium (Japanese-English) ────────────────────
fetch_jmdict() {
    green "=== JMdict + Kanjium ==="
    echo "  Source: https://www.edrdg.org/jmdict/"
    echo "  License: CC-BY-SA 4.0"
    dl "https://www.edrdg.org/pub/Nihongo/JMdict_e.gz" \
       "$DATA/JMdict_e.gz"
    if [[ ! -f "$DATA/JMdict_e" ]]; then
        gunzip -k "$DATA/JMdict_e.gz"
        green "  ✓ decompressed → JMdict_e"
    fi
    dl "https://raw.githubusercontent.com/mifunetoshiro/kanjium/master/data/source_files/kanjium_accents.txt" \
       "$DATA/kanjium_accents.txt"
}

# ── 3. Kaikki.org / Wiktextract (10 languages) ───────────────
fetch_kaikki() {
    green "=== Kaikki.org (Wiktextract) ==="
    echo "  Source: https://kaikki.org/dictionary/rawdata.html"
    echo "  License: CC-BY-SA 3.0 / GFDL"
    echo ""
    echo "  NOTE: Kaikki.org periodically reorganizes download URLs."
    echo "  If a URL below fails, visit https://kaikki.org/dictionary/"
    echo "  and navigate to each language's page for the latest link."
    echo ""
    # Per-language JSONL downloads (check kaikki.org for latest URLs)
    local langs=(Spanish French Russian Italian Portuguese Greek Turkish Latin Korean Arabic)
    for lang in "${langs[@]}"; do
        local file="kaikki-${lang}.jsonl"
        if [[ -f "$DATA/$file" ]]; then
            yellow "  skip (exists): $DATA/$file"
        else
            echo "  ↓ Downloading $lang..."
            # Try the current URL pattern; may need manual update
            local url="https://kaikki.org/dictionary/downloads/${lang}/kaikki.org-dictionary-${lang}.jsonl"
            if ! curl -fSL --progress-bar -o "$DATA/$file" "$url" 2>/dev/null; then
                red "  ✗ Auto-download failed for $lang."
                echo "    → Visit https://kaikki.org/dictionary/${lang}/"
                echo "    → Download the JSONL file and save as: $DATA/$file"
            else
                green "  ✓ $DATA/$file"
            fi
        fi
    done
}

# ── 4. WikDict (26 SQLite3 bilingual dictionaries) ───────────
fetch_wikdict() {
    green "=== WikDict ==="
    echo "  Source: https://www.wikdict.com/page/download"
    echo "  License: CC-BY-SA 3.0"
    mkdir -p "$DATA/wikdict"
    local base="https://download.wikdict.com/dictionaries/sqlite/2_2022-01"
    local pairs=(
        en-fr fr-en en-de de-en en-es es-en en-ru ru-en
        en-pt pt-en en-it it-en en-tr tr-en en-la la-en
        en-el el-en de-ru ru-de es-fr fr-es es-pt pt-es
        fr-ru ru-fr
    )
    for pair in "${pairs[@]}"; do
        dl "$base/${pair}.sqlite3" "$DATA/wikdict/${pair}.sqlite3"
    done
}

# ── 5. FreeDict (German ↔ English TEI XML) ────────────────────
fetch_freedict() {
    green "=== FreeDict ==="
    echo "  Source: https://freedict.org/"
    echo "  License: GPL-3.0+"
    mkdir -p "$DATA/freedict/deu-eng" "$DATA/freedict/eng-deu"
    # FreeDict releases as .tar.xz; extract the .tei file
    for pair in deu-eng eng-deu; do
        if [[ -f "$DATA/freedict/$pair/$pair.tei" ]]; then
            yellow "  skip (exists): $DATA/freedict/$pair/$pair.tei"
        else
            local url="https://download.freedict.org/dictionaries/$pair/$pair-2024.1.2.src.tar.xz"
            echo "  ↓ $url"
            local tmp
            tmp=$(mktemp)
            if curl -fSL --progress-bar -o "$tmp" "$url" 2>/dev/null; then
                tar -xJf "$tmp" --strip-components=1 -C "$DATA/freedict/$pair/" \
                    --include="*/$pair.tei" 2>/dev/null || \
                tar -xJf "$tmp" -C "$DATA/freedict/$pair/" 2>/dev/null
                green "  ✓ $DATA/freedict/$pair/$pair.tei"
            else
                red "  ✗ Auto-download failed. Visit https://freedict.org/ for latest release."
                echo "    → Download $pair source archive"
                echo "    → Extract $pair.tei to $DATA/freedict/$pair/"
            fi
            rm -f "$tmp"
        fi
    done
}

# ── 6. Wiktionary TSV (Korean, Arabic legacy) ────────────────
fetch_wiktionary() {
    green "=== Wiktionary TSV ==="
    echo "  Source: https://github.com/Vuizur/Wiktionary-Dictionaries"
    echo "  License: CC-BY-SA 3.0 / GFDL"
    local base="https://raw.githubusercontent.com/Vuizur/Wiktionary-Dictionaries/master"
    dl "$base/Korean-English/wiktionary-Korean-English.tsv" \
       "$DATA/wiktionary-Korean-English.tsv"
    dl "$base/Arabic-English/wiktionary-Arabic-English.tsv" \
       "$DATA/wiktionary-Arabic-English.tsv"
}

# ── 7. Open English WordNet 2025 ──────────────────────────────
fetch_wordnet() {
    green "=== Open English WordNet 2025 ==="
    echo "  Source: https://en-word.net/"
    echo "  License: CC-BY 4.0 + Princeton WordNet License"
    local zip="$DATA/english-wordnet-2025-plus-json.zip"
    dl "https://github.com/globalwordnet/english-wordnet/releases/download/2025/english-wordnet-2025-plus-json.zip" \
       "$zip"
    # Extract JSON files into data/ (flat)
    if [[ ! -f "$DATA/entries-a.json" ]]; then
        unzip -o -j "$zip" -d "$DATA/" '*.json'
        green "  ✓ extracted WordNet JSON files"
    else
        yellow "  skip (already extracted): entries-*.json"
    fi
}

# ── 8. Moby Thesaurus II ─────────────────────────────────────
fetch_moby() {
    green "=== Moby Thesaurus II ==="
    echo "  Source: https://www.gutenberg.org/ebooks/3202"
    echo "  License: Public Domain"
    dl "https://www.gutenberg.org/files/3202/files/mthesaur.txt" \
       "$DATA/mthesaur.txt"
}

# ── 9. GCIDE (GNU CIDE / Webster's 1913) ─────────────────────
fetch_gcide() {
    green "=== GCIDE (Webster's 1913) ==="
    echo "  Source: https://ftp.gnu.org/gnu/gcide/"
    echo "  License: GPL-3.0+"
    mkdir -p "$DATA/gcide"
    local tar="$DATA/gcide/gcide-0.53.tar.xz"
    dl "https://ftp.gnu.org/gnu/gcide/gcide-0.53.tar.xz" "$tar"
    if [[ ! -d "$DATA/gcide/gcide-0.53" ]]; then
        tar -xJf "$tar" -C "$DATA/gcide/"
        green "  ✓ extracted → gcide/gcide-0.53/"
    else
        yellow "  skip (already extracted): gcide/gcide-0.53/"
    fi
}

# ── 10. Bible (15 translations, OSIS/USFX/Zefania XML) ───────
fetch_bible() {
    green "=== Bible Translations ==="
    echo "  License: Public Domain"
    echo ""
    echo "  Bible XMLs are sourced from multiple open-Bible projects."
    echo "  Canonical sources:"
    echo "    - https://github.com/seven1m/open-bibles (curated)"
    echo "    - https://ebible.org/download.php"
    echo "    - https://github.com/gratis-bible"
    echo ""
    mkdir -p "$DATA/bible"
    local files=(
        kjv.osis.xml
        cuv-simp.usfx.xml cuv-trad.usfx.xml
        kougo.osis.xml spa-rv1909.usfx.xml
        fra-darby.osis.xml deu-luther1912.osis.xml
        por-almeida.usfx.xml rus-synodal.zefania.xml
        kor-korean.osis.xml ar-svd.osis.xml
        it-diodati.osis.xml
        la-vulgate.osis.xml grc-byzantine.usfx.xml
    )
    local missing=0
    for f in "${files[@]}"; do
        if [[ ! -f "$DATA/bible/$f" ]]; then
            red "  ✗ missing: $DATA/bible/$f"
            missing=$((missing + 1))
        fi
    done
    if [[ $missing -eq 0 ]]; then
        green "  ✓ all 14 Bible XMLs present"
    else
        echo ""
        echo "  $missing file(s) missing. Download from the sources above"
        echo "  and place in $DATA/bible/"
    fi
}

# ── 11. Perseus (LSJ Greek + Lewis & Short Latin) ────────────
fetch_perseus() {
    green "=== Perseus Digital Library ==="
    echo "  Source: https://github.com/PerseusDL"
    echo "  License: CC BY-SA 4.0 (credit line in scripts/build_perseus_mdx.py)"
    mkdir -p "$DATA/perseus"
    # LSJ (Liddell-Scott-Jones Greek-English Lexicon). Upstream splits LSJ into
    # grc.lsj.perseus-eng1..27.xml; the preset is currently built from part 1.
    dl "https://raw.githubusercontent.com/PerseusDL/lexica/master/CTS_XML_TEI/perseus/pdllex/grc/lsj/grc.lsj.perseus-eng1.xml" \
       "$DATA/perseus/lsj.xml"
    # Lewis & Short (Latin-English Dictionary)
    dl "https://raw.githubusercontent.com/PerseusDL/lexica/master/CTS_XML_TEI/perseus/pdllex/lat/ls/lat.ls.perseus-eng1.xml" \
       "$DATA/perseus/lewis-short.xml"
}

# ── 12. KANJIDIC2 (Kanji reference) ──────────────────────────
fetch_kanjidic2() {
    green "=== KANJIDIC2 ==="
    echo "  Source: https://www.edrdg.org/wiki/index.php/KANJIDIC_Project"
    echo "  License: CC-BY-SA 4.0"
    mkdir -p "$DATA/kanjidic2"
    dl "https://www.edrdg.org/kanjidic/kanjidic2.xml.gz" \
       "$DATA/kanjidic2/kanjidic2.xml.gz"
    if [[ ! -f "$DATA/kanjidic2/kanjidic2.xml" ]]; then
        gunzip -k "$DATA/kanjidic2/kanjidic2.xml.gz"
        green "  ✓ decompressed → kanjidic2/kanjidic2.xml"
    fi
}

# ── 13. Unihan (Unicode CJK character database) ──────────────
fetch_unihan() {
    green "=== Unicode Unihan ==="
    echo "  Source: https://www.unicode.org/charts/unihan.html"
    echo "  License: Unicode License"
    mkdir -p "$DATA/unihan"
    dl "https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip" \
       "$DATA/unihan/Unihan.zip"
    if [[ ! -f "$DATA/unihan/Unihan_Readings.txt" ]]; then
        unzip -o "$DATA/unihan/Unihan.zip" -d "$DATA/unihan/"
        green "  ✓ extracted Unihan_*.txt files"
    else
        yellow "  skip (already extracted): Unihan_*.txt"
    fi
}

# ── 14. CC-Canto (Cantonese-English) ─────────────────────────
fetch_cccanto() {
    green "=== CC-Canto ==="
    echo "  Source: https://cantonese.org/download.html"
    echo "  License: CC-BY-SA 3.0"
    mkdir -p "$DATA/cc-canto"
    dl "https://cantonese.org/download/cccanto-webdist-160115.txt" \
       "$DATA/cc-canto/cccanto-webdist.txt"
    dl "https://cantonese.org/download/cccedict-canto-readings-150923.txt" \
       "$DATA/cc-canto/cccedict-canto-readings-150923.txt"
}

# ── Dispatcher ────────────────────────────────────────────────

ALL_SOURCES=(
    cedict jmdict kaikki wikdict freedict wiktionary
    wordnet moby gcide bible perseus kanjidic2 unihan cccanto
)

list_sources() {
    echo "Available data sources:"
    echo ""
    printf "  %-12s %s\n" "cedict"     "CC-CEDICT (Chinese-English)"
    printf "  %-12s %s\n" "jmdict"     "JMdict + Kanjium (Japanese-English)"
    printf "  %-12s %s\n" "kaikki"     "Kaikki.org / Wiktextract (10 languages)"
    printf "  %-12s %s\n" "wikdict"    "WikDict SQLite3 (26 language pairs)"
    printf "  %-12s %s\n" "freedict"   "FreeDict TEI XML (German ↔ English)"
    printf "  %-12s %s\n" "wiktionary" "Wiktionary TSV (Korean, Arabic)"
    printf "  %-12s %s\n" "wordnet"    "Open English WordNet 2025"
    printf "  %-12s %s\n" "moby"       "Moby Thesaurus II"
    printf "  %-12s %s\n" "gcide"      "GCIDE / Webster's 1913"
    printf "  %-12s %s\n" "bible"      "14 Bible translations"
    printf "  %-12s %s\n" "perseus"    "Perseus LSJ + Lewis & Short"
    printf "  %-12s %s\n" "kanjidic2"  "KANJIDIC2 (Kanji reference)"
    printf "  %-12s %s\n" "unihan"     "Unicode Unihan (CJK characters)"
    printf "  %-12s %s\n" "cccanto"    "CC-Canto (Cantonese-English)"
}

main() {
    if [[ $# -eq 0 ]]; then
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║   OpenMDict preset-dicts — Data Acquisition        ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo ""
        for src in "${ALL_SOURCES[@]}"; do
            "fetch_$src"
            echo ""
        done
        green "Done. Run 'make all' to build all dictionaries."
    elif [[ "$1" == "--list" || "$1" == "-l" ]]; then
        list_sources
    elif declare -f "fetch_$1" >/dev/null 2>&1; then
        "fetch_$1"
    else
        red "Unknown source: $1"
        echo ""
        list_sources
        exit 1
    fi
}

main "$@"
