# OpenMDict Preset Dictionaries

Open-source MDict (`.mdx`) dictionary compilation pipeline for the
[OpenMDict](https://github.com/naco-siren/OpenMDict) iOS app.

**64 dictionaries** across **30+ language pairs** — all openly licensed or
public domain. The compiled files are **not** committed; they are published
as GitHub Release assets and downloaded by `scripts/bootstrap-assets.sh`
(repository root). This directory holds everything needed to rebuild them.
See `../MAINTAINING.md` for the publishing workflow.

## Directory Structure

```
preset-dicts/
  preset-dictionaries.json    # Catalog consumed by the iOS app (v3 schema)
  catalog-policy.json         # Which dictionaries are bundled vs. on-demand
  Makefile                    # Build orchestration
  FORMATTING_STANDARD.md      # HTML/CSS rendering spec

  scripts/                    # Build scripts (Python 3)
    shared/                     # Shared CSS/HTML/build infrastructure
      theme.py                    CSS composition (get_css, extensions, presets)
      html.py                     HTML helpers (esc, wrap_entry)
      build.py                    MDX packing, preview generation, reproducible headers
    fetch_data.sh               # Download all source data
    build_cedict_mdx.py         Chinese-English        (CC-CEDICT)
    build_jmdict_mdx.py         Japanese-English       (JMdict + Kanjium)
    build_kaikki_mdx.py         10 languages            (Kaikki.org / Wiktextract)
    build_wikdict_mdx.py        26 language pairs       (WikDict / SQLite3)
    build_freedict_mdx.py       German ↔ English        (FreeDict TEI P5)
    build_wiktionary_mdx.py     Korean, Arabic          (Wiktionary TSV)
    build_wordnet_mdx.py        English monolingual     (Open English WordNet 2025)
    build_moby_thesaurus_mdx.py English thesaurus       (Moby Thesaurus II)
    build_gcide_mdx.py          English dictionary      (GNU CIDE / Webster's 1913)
    build_bible_mdx.py          14 Bible translations   (OSIS/USFX/Zefania XML)
    build_perseus_mdx.py        Ancient Greek, Latin    (Perseus TEI P4)
    build_kanjidic2_mdx.py      Kanji reference         (KANJIDIC2)
    build_unihan_mdx.py         CJK characters          (Unicode Unihan)
    build_cccanto_mdx.py        Cantonese-English       (CC-Canto)
    generate_preset_catalog.py  Regenerate the catalog from .meta.json sidecars
    sync_catalog_with_output.py Make catalog sizes/entries match the .mdx on disk
    gen_third_party_notices.py  Regenerate the dictionary table in ../THIRD-PARTY-NOTICES.md

  data/                       # Source data (~6.5 GB, gitignored, see fetch_data.sh)
  output/                     # Build output (gitignored; bootstrap downloads it)
    CEDICT-ZH-EN/               Per-dict working directory
      CEDICT-ZH-EN.mdx            Compiled dictionary  ← referenced by Xcode
      CEDICT-ZH-EN.meta.json      Catalog sidecar
      cedict_entries.txt          MDict source text
      cedict_preview.html         Visual preview
      ...
```

`data/` and `output/` are gitignored and may be symlinks to a directory
outside the checkout. **`git clean -x` deletes them** (see
`../MAINTAINING.md`).

## Quick Start

### Prerequisites

- Python 3.10+
- [`mdict-utils`](https://github.com/liuyug/mdict-utils) 1.3.14, which
  provides the `mdict` CLI: `pip install mdict-utils==1.3.14`
- Source data files in `data/` (see [Data Acquisition](#data-acquisition))

If you only want the compiled dictionaries, run
`../scripts/bootstrap-assets.sh` instead; none of the above is needed.

### Data Acquisition

```bash
# Download ALL source data (~6.5 GB)
./scripts/fetch_data.sh

# Download a single source
./scripts/fetch_data.sh cedict

# List available sources
./scripts/fetch_data.sh --list
```

The script downloads, decompresses and normalizes data from 14 open
sources. Notes:

- **Kaikki.org** URLs change from time to time — if a download fails, visit
  the language page on [kaikki.org](https://kaikki.org/dictionary/).
- **Bible XMLs** are manual downloads from
  [open-bibles](https://github.com/seven1m/open-bibles),
  [eBible.org](https://ebible.org/download.php) or
  [gratis-bible](https://github.com/gratis-bible); the script lists the
  expected file names.
- **FreeDict** release versions change — update the URL in the script if
  needed.
- All downloads are idempotent (existing files are skipped).

### Build Commands

```bash
# Build a single dictionary
make cedict

# Build all dictionaries and regenerate the catalog
make all

# Regenerate the catalog from .meta.json sidecars (review the diff!)
make catalog

# Regenerate the dictionary table in ../THIRD-PARTY-NOTICES.md
make notices

# List all targets
make list
```

### Available Make Targets

| Target | Description |
|--------|-------------|
| `wordnet` | Open English WordNet 2025 |
| `moby` | Moby Thesaurus II |
| `gcide` | GCIDE (Webster's 1913) |
| `cedict` | CC-CEDICT Chinese-English |
| `jmdict` | JMdict Japanese-English |
| `cccanto` | CC-Canto Cantonese-English |
| `kanjidic2` | KANJIDIC2 Kanji reference |
| `unihan` | Unicode Unihan CJK |
| `kaikki` | Kaikki.org (10 languages) |
| `wikdict` | WikDict (26 language pairs) |
| `freedict` | FreeDict German ↔ English |
| `wiktionary` | Wiktionary Korean/Arabic |
| `perseus` | LSJ Greek + Lewis & Short Latin |
| `bible` | 14 Bible translations |
| `all` | Build everything + regenerate the catalog |
| `catalog` | Regenerate `preset-dictionaries.json` only |
| `notices` | Regenerate the third-party notices table |

### Reproducible builds

mdict-utils writes today's date into the MDX header (`CreationDate`), which
would make every rebuild a different file. `scripts/shared/build.py` pins
that date after packing (and fixes the header checksum), so rebuilding
unchanged input produces a byte-identical `.mdx`. The date comes from
`SOURCE_DATE_EPOCH` when set, otherwise from the newest source file mtime:

```bash
SOURCE_DATE_EPOCH=1771632000 make cedict
```

## Dictionary Catalog

`preset-dictionaries.json` (schema v3) lists every dictionary with its
display name, description, language direction, entry count, size, SPDX
license id, data source and delivery mode (`bundle` = copied into the app,
`odr` = On-Demand Resource with an `odrTag`). The iOS app reads it from the
bundle; `../scripts/check-assets.sh` verifies it against the Xcode project
and the asset lock.

### Data Sources & Licenses

| Source | License (SPDX) | Dictionaries |
|--------|----------------|--------------|
| CC-CEDICT | CC-BY-SA-4.0 | 1 (ZH) |
| JMdict + Kanjium / KANJIDIC2 | CC-BY-SA-4.0 | 2 (JA) |
| Kaikki.org (Wiktextract) | CC-BY-SA-4.0 | 10 (ES, FR, IT, PT, RU, AR, EL, TR, LA, KO) |
| WikDict | CC-BY-SA-3.0 | 26 language pairs |
| Wiktionary TSV | CC-BY-SA-3.0 / 4.0 (+ GFDL) | 2 (KO, AR) |
| FreeDict | GPL-3.0-or-later | 2 (DE ↔ EN) |
| Open English WordNet 2025 | CC-BY-4.0 (+ Princeton WordNet license) | 1 (EN) |
| Moby Thesaurus II | Public domain | 1 (EN) |
| GCIDE | GPL-3.0-or-later | 1 (EN) |
| CC-Canto | CC-BY-SA-3.0 | 1 (YUE) |
| Perseus Digital Library | CC-BY-SA-3.0 | 2 (GRC, LA) |
| Unicode Unihan | Unicode-3.0 | 1 (CJK) |
| Public-domain Bibles | Public domain | 14 translations |

Full per-dictionary attribution: `../THIRD-PARTY-NOTICES.md` (generated).
GPL-licensed sources are redistributed with their corresponding source
archives on the asset Release.

## Adding a New Dictionary

1. Add the source to `scripts/fetch_data.sh` and place the data in `data/`.
   Only openly licensed or public-domain data can ship.
2. Create `scripts/build_{name}_mdx.py` following an existing script.
   - Read `FORMATTING_STANDARD.md` for HTML/CSS conventions.
   - Output to `output/{DictName}/{DictName}.mdx` and call
     `write_catalog_metadata(...)` with an SPDX license id.
3. Add a target to `Makefile` and run `make {target}`.
4. Add the entry to `preset-dictionaries.json` (`make catalog`, review the
   diff; add the file to `catalog-policy.json` only if it must be bundled).
5. From the repository root: `ruby scripts/relink-project-assets.rb --sync`
   to add the Xcode reference and ODR tag, then `make -C preset-dicts notices`,
   `scripts/publish-assets.sh --tag assets-YYYY.MM[.N]` (uploads to a draft
   pre-release that you review and publish), and `scripts/check-assets.sh`.

## Xcode Integration

The Xcode project references each compiled dictionary **in place**, relative
to the project (`SOURCE_ROOT`):

```
preset-dicts/output/<Name>/<Name>.mdx     ← one PBXFileReference per dictionary
preset-dicts/preset-dictionaries.json     ← copied into the app bundle
```

Two dictionaries (`catalog-policy.json` → `bundle_assets`) are copied into
the app; the rest carry `ASSET_TAGS = preset-dict-<id>` and ship as
On-Demand Resources. A fresh clone gets the `.mdx` files by running
`scripts/bootstrap-assets.sh`, which downloads them from the GitHub Release
listed in `assets.lock.json` and verifies their SHA-256; building one
locally with `make` puts it in exactly the same place. Never add `.mdx`
files through Xcode's file dialog — use `scripts/relink-project-assets.rb
--sync`, which keeps the references relative and the ODR tags in sync with
the catalog.
