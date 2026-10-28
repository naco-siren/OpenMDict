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
  build-pins.json             # MDX header CreationDate per dictionary (reproducible hashes)
  assets.lock.json            # Published assets (written by ../scripts/publish-assets.sh)
  licenses/                   # License texts quoted in the notices and attached to the Release
  Makefile                    # Build orchestration
  FORMATTING_STANDARD.md      # HTML/CSS rendering spec

  scripts/                    # Build scripts (Python 3)
    shared/                     # Shared CSS/HTML/build infrastructure
      theme.py                    CSS composition (get_css, extensions, presets)
      html.py                     HTML helpers (esc, wrap_entry)
      build.py                    MDX packing, preview generation, reproducible headers
    fetch_data.sh               # Download all source data (pinned URLs + SHA-256)
    build_cedict_mdx.py         Chinese-English        (CC-CEDICT)
    build_jmdict_mdx.py         Japanese-English       (JMdict + Kanjium)
    build_kaikki_mdx.py         10 languages            (Kaikki.org / Wiktextract)
    build_wikdict_mdx.py        26 language pairs       (WikDict / SQLite3)
    build_freedict_mdx.py       German ↔ English        (FreeDict TEI P5)
    build_wiktionary_mdx.py     Korean, Arabic          (Wiktionary TSV)
    build_wordnet_mdx.py        English monolingual     (Open English WordNet 2025+)
    build_moby_thesaurus_mdx.py English thesaurus       (Moby Thesaurus II)
    build_gcide_mdx.py          English dictionary      (GNU CIDE / Webster's 1913)
    build_bible_mdx.py          14 Bible translations   (OSIS/USFX/Zefania XML, SWORD, wikitext, Markdown)
    build_perseus_mdx.py        Ancient Greek, Latin    (Perseus TEI P4)
    build_kanjidic2_mdx.py      Kanji reference         (KANJIDIC2)
    build_unihan_mdx.py         CJK characters          (Unicode Unihan)
    build_cccanto_mdx.py        Cantonese-English       (CC-Canto)
    generate_preset_catalog.py  Regenerate the catalog from the sidecars and the .mdx files (--check: drift check)
    sync_catalog_with_output.py Make catalog sha256/sizes/entries match the .mdx on disk
    gen_third_party_notices.py  Regenerate the preset-dictionary part of ../THIRD-PARTY-NOTICES.md

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
- [OpenCC](https://github.com/BYVoid/OpenCC) 1.4.2 for the Simplified
  Chinese Bible (`Bible-CUV-ZH-Hans`): `pip install opencc==1.4.2`
- Source data files in `data/` (see [Data Acquisition](#data-acquisition))

If you only want the compiled dictionaries, run
`../scripts/bootstrap-assets.sh` instead; none of the above is needed.

### Data Acquisition

```bash
# Download ALL source data (~6.5 GB)
./scripts/fetch_data.sh

# Download some sources
./scripts/fetch_data.sh cedict wordnet

# Also download the current EDRDG releases (JMdict, KANJIDIC2)
./scripts/fetch_data.sh --refresh jmdict kanjidic2

# List available sources
./scripts/fetch_data.sh --list
```

The script downloads and unpacks the data of 14 open sources. Every input
is pinned to the URL (a versioned release path or a git commit) and the
SHA-256 of the file the published dictionaries were built from:

- Existing files are not downloaded again, but they are always checked. A
  file that does not match its SHA-256 is an **error** (delete it and
  re-run if a download was cut short).
- Some upstreams serve only their latest release under a fixed URL:
  CC-CEDICT (MDBG), Kaikki.org, CrossWire's KorRV and JapBungo modules and
  eBible.org's `grcbyz`. For those a different file only gives a **warning**: a rebuild
  from it will not reproduce the published `.mdx`.
- **JMdict** and **KANJIDIC2** are replaced by EDRDG every day and older
  releases are not kept. Each download is filed under its release
  (`data/jmdict/<JMdict created date>/`, `data/kanjidic2-<database_version>/`)
  and never overwrites the release the build is pinned to; see
  `../MAINTAINING.md`, "Refreshing the EDRDG data".
- The **Bibles** come from commit-pinned
  [open-bibles](https://github.com/seven1m/open-bibles),
  [gratis-bible](https://github.com/gratis-bible/bible) and
  [biblia-arc1911](https://github.com/mazza/biblia-arc1911) URLs, Chinese
  Wikisource pages pinned by revision id (`scripts/cuv1919_wikisource.pins`),
  the [CrossWire](https://crosswire.org/sword/modules/) KorRV and JapBungo
  modules and eBible.org's `grcbyz` (the build gates still check every book,
  chapter and verse of the latter three).
- The Moby and WikDict builds also need the Open English WordNet data;
  fetching either source fetches it too.
- A source that fails is reported and the others still run; the script
  exits 1 if any source failed and repeats all warnings at the end.

To move a source to a newer release, change its URL and SHA-256 in
`fetch_data.sh` (and the matching pin in its build script, where it has
one), rebuild, and review the catalog diff (`make catalog`).

### Build Commands

```bash
# Build a single dictionary
make cedict

# Build all dictionaries, then check the catalog (fails on drift)
make all

# Regenerate the catalog from the sidecars and the .mdx files; prints the
# field-by-field diff (review it!)
make catalog

# Fail if the catalog or THIRD-PARTY-NOTICES.md is out of date
make check-catalog

# Regenerate the preset-dictionary part of ../THIRD-PARTY-NOTICES.md
make notices

# List all targets
make list
```

### Available Make Targets

| Target | Description |
|--------|-------------|
| `wordnet` | Open English WordNet 2025+ |
| `moby` | Moby Thesaurus II |
| `gcide` | GCIDE (Webster's 1913) |
| `cedict` | CC-CEDICT Chinese-English |
| `jmdict` | JMdict Japanese-English |
| `cccanto` | CC-Canto Cantonese-English |
| `kanjidic2` | KANJIDIC2 Kanji reference |
| `unihan` | Unicode Unihan CJK |
| `kaikki` | Kaikki.org (10 languages) |
| `wikdict` | WikDict (26 language pairs, `--all`) |
| `freedict` | FreeDict German ↔ English |
| `wiktionary` | Wiktionary Korean/Arabic |
| `perseus` | LSJ Greek + Lewis & Short Latin |
| `bible` | 14 Bible translations |
| `all` | Build everything, then `check-catalog` (never rewrites the catalog) |
| `catalog` | Regenerate `preset-dictionaries.json` and print the diff |
| `check-catalog` | Fail if the catalog does not describe `output/` or the notices are stale |
| `notices` | Regenerate the generated part of `../THIRD-PARTY-NOTICES.md` |
| `descriptions` | Write every dictionary's MDX header description to `output/_descriptions/` without building (review the text first) |

### Reproducible builds

The app identifies a preset by the SHA-256 of the whole `.mdx` file, so a
rebuild of unchanged content must produce the same bytes, or every
installed copy is offered a pointless update. mdict-utils writes today's
date into the MDX header (`CreationDate`); `scripts/shared/build.py`
rewrites it after packing (and fixes the header checksum) with the date
pinned for that file in `build-pins.json`, verbatim (the published files
use mdict-utils' unpadded form, e.g. `2026-2-21`). A dictionary without a
pin gets the newest mtime of its inputs, and that date is recorded as its
pin. `SOURCE_DATE_EPOCH` overrides the pins, so do not set it for builds
you publish.

## Dictionary Catalog

`preset-dictionaries.json` (schema v3) lists every dictionary with its
display name, description, language direction, entry count, size, SPDX
license id, data source and delivery mode (`bundle` = copied into the app,
`odr` = On-Demand Resource with an `odrTag`), plus `sha256` (the whole-file
hash, which is the dictionary ID the app derives) and `previousSha256`
(every build that shipped before; the app offers an update only for an
installed build listed there). `make catalog` takes the descriptive fields
from the `.meta.json` sidecars and measures `sha256`, `sizeBytes`,
`entries` (lookup keys) and `headwords` (articles, which the preset picker
shows) from the `.mdx` files; it keeps the hand-maintained `licenseNote`
and the `previousSha256` history, and appends the hash a rebuild replaces.
The iOS app reads the catalog from the bundle; `../scripts/check-assets.sh`
verifies it against the Xcode project and the asset lock.

### Data Sources & Licenses

| Source | License (SPDX) | Dictionaries |
|--------|----------------|--------------|
| CC-CEDICT | CC-BY-SA-4.0 | 1 (ZH) |
| JMdict + Kanjium / KANJIDIC2 | CC-BY-SA-4.0 | 2 (JA) |
| Kaikki.org (Wiktextract) | CC-BY-SA-4.0 | 10 (ES, FR, IT, PT, RU, AR, EL, TR, LA, KO) |
| WikDict 2025-11 (Wiktionary via DBnary) | CC-BY-SA-4.0 | 26 language pairs |
| Wiktionary TSV (2022-11 snapshot) | CC-BY-SA-3.0 OR GFDL-1.3-or-later | 2 (KO, AR) |
| FreeDict 1.9-fd1 | GPL-3.0-or-later AND AGPL-3.0-or-later | 2 (DE ↔ EN) |
| Open English WordNet 2025+ | CC-BY-4.0 AND LicenseRef-WordNet-3.0 | 1 (EN) |
| Moby Thesaurus II | Public domain (redirect keys from OEWN: CC-BY-4.0 AND LicenseRef-WordNet-3.0) | 1 (EN) |
| GCIDE | GPL-3.0-or-later | 1 (EN) |
| CC-Canto | CC-BY-SA-3.0 | 1 (YUE) |
| Perseus Digital Library | CC-BY-SA-4.0 | 2 (GRC, LA) |
| Unicode Unihan 17.0.0 | Unicode-3.0 | 1 (CJK) |
| Public-domain Bibles | Public domain | 14 translations |

Full per-dictionary attribution, the credit lines and copyright notices the
upstream licenses ask for, and the license list: `../THIRD-PARTY-NOTICES.md`
(generated by `make notices`). GPL-licensed sources are redistributed with
their corresponding source archives: `scripts/publish-assets.sh` attaches
them, the notices and the license texts to every asset Release it creates.

## Adding a New Dictionary

1. Add the source to `scripts/fetch_data.sh` with a versioned URL and its
   SHA-256 (`fetch_pinned`), and add it to `ALL_SOURCES`. Only openly
   licensed or public-domain data can ship.
2. Create `scripts/build_{name}_mdx.py` following an existing script.
   - Read `FORMATTING_STANDARD.md` for HTML/CSS conventions.
   - Output to `output/{DictName}/{DictName}.mdx` and call
     `write_catalog_metadata(...)` with an SPDX license id.
3. Add a target to `Makefile` (and to `all`) and run `make {target}`.
4. Add the entry to `preset-dictionaries.json` (`make catalog`, review the
   diff; add the file to `catalog-policy.json` only if it must be bundled).
   It fails until `scripts/gen_third_party_notices.py` has an attribution
   row for the new `dataSource` and knows its license ids.
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
