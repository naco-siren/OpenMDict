# Maintaining OpenMDict

This page is for people who change the **assets** the iOS app depends on:
the preset dictionaries, the article-embedding model and the app icons.
For building the code and running the tests, see
[`docs/development.md`](docs/development.md); for the dictionary pipeline
itself, see [`preset-dicts/README.md`](preset-dicts/README.md).

## Four sources of truth

The app's assets are described in four places that must agree:

| Where | What it says |
|---|---|
| `preset-dicts/preset-dictionaries.json` (the **catalog**) | Which dictionaries exist, their metadata, `bundle` vs `odr`, `odrTag`, size, entry count, SPDX license |
| `Apps/iOS/OpenMDict-iOS/OpenMDict-iOS.xcodeproj/project.pbxproj` | Which `.mdx` files Xcode copies / tags (`ASSET_TAGS`, `KnownAssetTags`), relative to `SOURCE_ROOT` |
| `preset-dicts/assets.lock.json` (the **lock**) | File name, size, SHA-256 and Release tag of every downloadable asset |
| GitHub Releases (`assets-YYYY.MM.DD[.N]`, pre-release) | The actual bytes: 64 `.mdx`, the zipped `.mlpackage` + `vocab.txt`, the notices and GPL source archives |

Large files are **not** in git and not in LFS. A fresh clone runs
`scripts/bootstrap-assets.sh`, which downloads everything the lock lists,
verifies the hashes and compiles the model. `scripts/check-assets.sh`
verifies that catalog == pbxproj == lock; run it before every push, so
drift is caught before it reaches `main`.

## Prerequisites

| Tool | Needed for |
|---|---|
| Python 3.10+ and `pip install mdict-utils==1.3.14` (provides the `mdict` CLI) | Building dictionaries |
| `pip install opencc==1.4.2` | Building `Bible-CUV-ZH-Hans` (Traditional → Simplified) |
| Ruby with the `xcodeproj` gem (`gem install xcodeproj`) | `scripts/relink-project-assets.rb` |
| `jq`, `curl`, `shasum` (all on macOS 15+) | `scripts/bootstrap-assets.sh` |
| Xcode (for `xcrun coremlcompiler`) | Compiling the model after bootstrap |
| `gh` (GitHub CLI), authenticated | `scripts/publish-assets.sh` |
| Docker (only to **rebuild** the model) | `scripts/model/build-minilm.Dockerfile` |

## The scripts

| Script | Purpose |
|---|---|
| `scripts/bootstrap-assets.sh [--check\|--force]` | Download every asset in the lock into place (`preset-dicts/output/<Name>/<Name>.mdx`, `Apps/iOS/OpenMDict-iOS/Article Embeddings/`), verify SHA-256, unzip the model and run the precompile step when the model changed. Files that already match the lock are skipped without touching their mtime. `--check` only reports drift (non-zero exit) and never downloads or writes. Files it downloaded (or verified) earlier are replaced automatically when the lock moves on. `--force` also overwrites local files whose hash differs from the lock and that were never published (for example a dictionary you rebuilt locally); without it the script refuses and tells you which files differ. `OPENMDICT_ASSETS_BASE_URL` overrides the download base (default: this repository's Releases) so a staging directory served with `python3 -m http.server` can be used for dry runs. When the Releases are in a private repository, unauthenticated downloads return 404 and the script switches to `gh release download` (requires `gh auth login`). |
| `scripts/publish-assets.sh --tag assets-YYYY.MM.DD[.N]` | Hash the local assets, upload only the ones whose hash is not yet in the lock to a **draft** pre-release under the given (new) tag, rewrite the lock, and stage the compliance payload: the committed `THIRD-PARTY-NOTICES.md` (regenerate it first — the script copies, it does not generate), `LICENSE-<SPDX>.txt` texts (taken from `preset-dicts/licenses/`, then `licenses/`, and fetched from the SPDX list only when neither has them; `LicenseRef-*` texts such as the WordNet license must be in `preset-dicts/licenses/`) and the GPL source archives, all of which are attached to every new tag even when unchanged. Review the draft, then `gh release edit <tag> --draft=false` and commit the lock. `--dry-run` / `--stage-only` need no `gh`. |
| `scripts/check-assets.sh` | Consistency gate: every catalog entry has a pbxproj reference with the right `ASSET_TAGS`, every `odrTag` is in `KnownAssetTags`, every file is in the lock, and nothing in the lock is orphaned. Exit non-zero on drift. |
| `scripts/relink-project-assets.rb [--sync] [--dry-run] [--project PATH]` | Rewrite the pbxproj (defaults to the iOS app project) so every asset reference is relative (`SOURCE_ROOT`), never absolute. `--sync` additionally adds/removes `.mdx` references and `ASSET_TAGS` to match the catalog and merges `KnownAssetTags`. `--dry-run` prints what would change. Idempotent. |
| `scripts/precompile-article-embed-model.sh` | `.mlpackage → .mlmodelc` with `xcrun coremlcompiler` (invoked by bootstrap when needed). |
| `preset-dicts/scripts/fetch_data.sh [--refresh] [source…]` | Download the source data into `preset-dicts/data/`. Every input is pinned to a versioned URL or commit and its SHA-256; a mismatch is an error, except for the upstreams that only serve their latest release (warning). One failing source does not stop the others. `--refresh` also downloads the current JMdict / KANJIDIC2 releases. |
| `preset-dicts/scripts/generate_preset_catalog.py [--check]` (`make catalog` / `make check-catalog`) | Regenerate the catalog: descriptive fields from the `.meta.json` sidecars, `sha256` / `sizeBytes` / `entries` / `headwords` measured from the `.mdx` files, `licenseNote` and the `previousSha256` history kept. Prints the diff field by field; `--check` exits 1 on any drift instead of writing. |
| `preset-dicts/scripts/gen_third_party_notices.py [--check]` (`make notices`) | Regenerate the preset-dictionary part of `THIRD-PARTY-NOTICES.md` (table, license notes, per-source notices, license list) from the catalog. |
| `scripts/gen-settings-licenses.py [--check]` (`make notices` / `make check-notices`) | Regenerate the Licenses pages of the app's Settings.bundle from `LICENSE`, `THIRD-PARTY-NOTICES.md` and the license texts; `--check` also verifies that every language has the strings the pages use and that the About footer names the source code URL. |
| `preset-dicts/scripts/sync_catalog_with_output.py [--check] [--openmdict PATH]` | Make the catalog's `sha256` (recording the replaced hash in `previousSha256`), `sizeBytes` and, with `--openmdict`, `entries` match the `.mdx` files on disk without the sidecars (for example after `bootstrap-assets.sh`); also refreshes `output/manifest.json`. |

Read each script's header comment for the full option list.

## Change matrix

| You changed… | Then run… | Commit |
|---|---|---|
| **Dictionary content** (a build script, source data, `FORMATTING_STANDARD.md`) | `make -C preset-dicts <target>` → check the output → `make -C preset-dicts catalog notices` (review the printed diff) → `scripts/publish-assets.sh --tag assets-YYYY.MM.DD[.N]` → `scripts/check-assets.sh --strict` → publish the draft | catalog, notices, lock, `Settings.bundle/Licenses*` |
| **Added or removed a dictionary** | add/remove the build script + Makefile target + catalog entry (+ `bundle_assets` in `catalog-policy.json` if bundled) → `make -C preset-dicts <target>` → `ruby scripts/relink-project-assets.rb --sync` → `make -C preset-dicts notices` → `scripts/publish-assets.sh --tag assets-YYYY.MM.DD[.N]` → `scripts/check-assets.sh` | catalog, pbxproj, lock, `THIRD-PARTY-NOTICES.md`, `Settings.bundle/Licenses*` |
| **Catalog metadata only** (description, display name, tier, license) | change the `write_catalog_metadata(...)` call in the build script and rebuild (hand edits of these fields are overwritten by `make catalog`; only `licenseNote` is maintained by hand in `preset-dictionaries.json`) → `make -C preset-dicts catalog notices` → `scripts/check-assets.sh` | catalog, notices (+ lock if the `.mdx` changed), `Settings.bundle/Licenses*` |
| **Header description** (the `Description` HTML in the MDX header, shown on the dictionary info screen) | every build script composes it with `shared.build.description_html(...)` (one layout for all presets: title, about, Source, License, Conversion with the converter credit, verbatim notices) and exposes `descriptions()`; edit the arguments in the build script → `make -C preset-dicts descriptions` and read `output/_descriptions/index.html` → rebuild the dictionary (the header is part of the file, so the `sha256` changes) → as for dictionary content | catalog, notices, lock |
| **Source data refresh** (new upstream release) | update the URL / SHA-256 in `fetch_data.sh` and the pin in the build script → `fetch_data.sh <source>` → rebuild → as for dictionary content. JMdict and KANJIDIC2: see "Refreshing the EDRDG data" | `fetch_data.sh`, build script, catalog, notices, lock, `Settings.bundle/Licenses*` |
| **Third-party notices or license texts** (`THIRD-PARTY-NOTICES.md`, `LICENSE`, `preset-dicts/licenses/`, `licenses/`) | `make -C preset-dicts notices` regenerates the notices and the Licenses pages of the app's Settings.bundle (`scripts/gen-settings-licenses.py`: Settings › Apps › OpenMDict › Licenses); `make -C preset-dicts check-notices` (needs no `output/`; also part of `check-catalog`) fails when either is stale | notices, `Settings.bundle/Licenses*` |
| **Embedding model** | rebuild (see below) → `scripts/precompile-article-embed-model.sh` → `scripts/publish-assets.sh --tag …` (it zips the `.mlpackage` itself) → update the model section of `THIRD-PARTY-NOTICES.md` if the model or its license changed → `make -C preset-dicts notices` | lock, notices, `Settings.bundle/Licenses*` |
| **App icon family** | drop the PNGs / `.icon` bundle into `Apps/iOS/OpenMDict-iOS/Resources/AppIcons/` → add them to the "App Icons" group in Xcode → `CFBundleAlternateIcons` in `Info.plist` → the `AppIcon` enum → `ruby scripts/relink-project-assets.rb --dry-run` must report no absolute references | icons, pbxproj, Info.plist, Swift |
| **Anything in the pbxproj via Xcode's "Add Files…"** | `ruby scripts/relink-project-assets.rb --dry-run` (Xcode happily writes `<absolute>` references) | pbxproj |

Run `scripts/check-assets.sh` before pushing; a failure means the catalog,
the pbxproj and the lock no longer agree.

## Workflows in detail

### Rebuilding a dictionary

```bash
cd preset-dicts
./scripts/fetch_data.sh cedict      # once; checks every pinned file
make cedict                         # output/CEDICT-ZH-EN/CEDICT-ZH-EN.mdx + .meta.json
open output/CEDICT-ZH-EN/cedict_preview.html
make catalog notices                # prints the catalog diff; review it
make check-catalog                  # must pass before you publish
cd ..
scripts/publish-assets.sh --tag assets-2026.11.05   # uploads only what changed to a NEW tag, rewrites the lock
scripts/check-assets.sh --strict
gh release edit assets-2026.11.05 --draft=false     # after reviewing the draft
```

`make all` builds every dictionary and then runs `make check-catalog`; it
never rewrites the catalog. When the rebuilt files differ from the
committed catalog it fails and lists the fields; run `make catalog notices`
and review the result.

**Reproducible output and dictionary IDs.** The app's ID for a preset is
the SHA-256 of the whole `.mdx` file (`PresetDictionaryService.fileSHA256`),
so a rebuild of unchanged content must produce the same bytes, or every
installed copy is offered an update that changes nothing. mdict-utils
stamps today's date into the MDX header (`CreationDate`);
`preset-dicts/scripts/shared/build.py` rewrites it after packing (and
recomputes the header adler32) with the date pinned for that file in
`preset-dicts/build-pins.json`, verbatim. A new dictionary gets the newest
mtime of its inputs, which is then recorded as its pin. Bump a pin only
together with a content change. `SOURCE_DATE_EPOCH` overrides the pins, so
never set it for a build you publish.

**Shipping a changed dictionary.** A new `sha256` is how installed copies
learn that an update exists: the app offers it only when the installed ID
is listed in the entry's `previousSha256`. `make catalog` (and
`sync_catalog_with_output.py`) append the replaced hash automatically and
never drop an earlier one; `scripts/check-assets.sh` verifies that the
catalog's `sha256` equals the lock's and that `previousSha256` holds
neither the current hash nor duplicates.

**`make catalog`** rebuilds `preset-dictionaries.json` from the
`.meta.json` sidecars (display name, description, direction, flag, SPDX
license, data source, tier) and from the `.mdx` files (`sha256`,
`sizeBytes`, `entries` = the key count in the MDX header, the same number
the `openmdict` CLI prints, `headwords` = the records that are not
`@@@LINK=` redirects, shown in the preset picker). It keeps `licenseNote` and `previousSha256`,
refuses to drop a dictionary that has no sidecar, and fails on a license
id or `dataSource` that `gen_third_party_notices.py` cannot attribute. Rows
marked `!` in its diff (filename, flag, source, odrTag, tier, licenseNote)
change how the app identifies or offers a preset; review them before
committing.

### Refreshing the EDRDG data (JMdict, KANJIDIC2)

The EDRDG licence (section 4) requires a procedure for updating JMdict and
KANJIDIC2 regularly from the current releases; the builds warn once their
pinned release is more than 31 days old. Refresh both before every app
build that is uploaded (TestFlight or App Store), and at least once a month:

```bash
cd preset-dicts
./scripts/fetch_data.sh --refresh jmdict kanjidic2
#   files the current releases under data/jmdict/<created>/JMdict_e.gz and
#   data/kanjidic2-<database_version>/kanjidic2.xml.gz, and prints their
#   date / version and SHA-256
# set JMDICT_RELEASE / JMDICT_SHA256 in scripts/build_jmdict_mdx.py and
# KANJIDIC2_DB_VERSION / KANJIDIC2_SHA256 in scripts/build_kanjidic2_mdx.py,
# and the same four values at the top of the matching fetch_data.sh sections
make jmdict kanjidic2
make catalog notices                # new sha256, old one moves to previousSha256
cd ..
scripts/publish-assets.sh --tag assets-YYYY.MM.DD[.N] && scripts/check-assets.sh --strict
```

EDRDG keeps no older releases, so the pinned `.gz` files in `data/` are the
only copies of the inputs of the published dictionaries; keep them (or
attach them to the asset Release).

### Adding or removing a dictionary

1. Source data: add a `fetch_<source>()` to `preset-dicts/scripts/fetch_data.sh`
   (a versioned URL or commit plus its SHA-256, via `fetch_pinned`; add it to
   `ALL_SOURCES`) and record the license. Only openly licensed or
   public-domain data; anything "non-commercial" or "personal use" cannot
   ship.
2. `preset-dicts/scripts/build_<name>_mdx.py` following an existing script
   and `FORMATTING_STANDARD.md`; call `write_catalog_metadata(...)` with an
   SPDX license id.
3. Makefile target; `make <target>`.
4. Catalog entry (`make catalog`, then review the diff) — `bundle` assets are
   listed in `catalog-policy.json`, everything else gets an `odrTag`. It
   fails until `gen_third_party_notices.py` has an attribution row for the
   new `dataSource` and knows its license ids.
5. `ruby scripts/relink-project-assets.rb --sync` adds the `.mdx`
   reference, its `ASSET_TAGS` and the `KnownAssetTags` entry (or removes
   them). Never add preset `.mdx` files through Xcode's file dialog.
6. `make -C preset-dicts notices` (add a `SOURCE_NOTICES` entry in
   `gen_third_party_notices.py` when the license asks for a credit line or
   copyright notice that does not fit in the table), then
   `scripts/publish-assets.sh --tag assets-YYYY.MM.DD[.N]` and publish the
   draft. For a new SPDX license id, add its text as
   `licenses/LICENSE-<id>.txt` (from
   <https://raw.githubusercontent.com/spdx/license-list-data/main/text/<id>.txt>):
   the Settings licenses pages need it, and the publish script attaches that
   copy. For a `LicenseRef-*` license, put its text in
   `preset-dicts/licenses/LICENSE-<id>.txt` so the script can attach it
   (texts there also replace the SPDX download, as for Unicode-3.0, whose
   copyright line matches the Unihan release in use: 1991-2025 for 17.0.0;
   update it together with the Unihan pin).
7. `scripts/check-assets.sh` must pass. For a GPL-licensed source, keep its
   corresponding source archive in `preset-dicts/data/` and map the catalog
   id to it in `gpl_source_for` in `scripts/publish-assets.sh` (the script
   refuses to publish a GPL dictionary without one) and list it in the GPL
   paragraph of `gen_third_party_notices.py`. The script attaches it to
   every new Release.

### Rebuilding the embedding model

Normally you never do this; bootstrap downloads the published
`all-MiniLM-L6-v2.mlpackage.zip` + `vocab.txt`. Only rebuild to change the
model.

- `scripts/model/build-minilm.Dockerfile` pins `torch 2.7.0`,
  `transformers 4.40.0`, `coremltools < 9`, `numpy < 2` — a combination known
  to convert the model cleanly. Build the image with
  `docker build --platform=linux/amd64 -t openmdict-model-build -f scripts/model/build-minilm.Dockerfile scripts/model/`.
  **On Apple Silicon `--platform=linux/amd64` is mandatory**: `coremltools`
  8.x has no `linux/aarch64` wheel, so a native arm64 image fails at
  `pip install`. The emulated build is slow but works. (A native macOS
  Python 3.11 virtualenv also works — arm64 wheels exist — but Homebrew's
  default Python is too new for the pinned `torch`.)
- The production model's metadata records that it was converted with
  `torch 2.7.0+cu126` and `coremltools 8.3.0` on a CUDA machine, not with
  this Dockerfile. Core ML conversion is not bit-reproducible across
  toolchains, so **any rebuild yields a different SHA-256** → a new lock
  entry and a new Release tag, and every device re-downloads the model and
  rebuilds its article sidecars (the sidecar header stores the model
  hash).
- After converting: `scripts/precompile-article-embed-model.sh`, run the
  CLI sanity suite (`.build/release/openmdict articleembed --model … --vocab … --sanity`),
  `scripts/publish-assets.sh --tag …` (it zips the `.mlpackage` with
  `ditto -c -k --keepParent` and uploads it with `vocab.txt`), and update
  the model paragraph in `THIRD-PARTY-NOTICES.md` if the model or its
  license changed. Bootstrap recompiles the `.mlmodelc` whenever the
  `.mlpackage` hash next to its stamp file changes.

### Adding an app icon family

1. Copy the PNG set and the `.icon` bundle into
   `Apps/iOS/OpenMDict-iOS/Resources/AppIcons/` (these are committed; ~4 MB
   total today — keep previews and source files out of the repository).
2. In Xcode add them to the **App Icons** group (the group has
   `path = Resources/AppIcons`, children are bare file names).
3. Register the family in `Info.plist` → `CFBundleAlternateIcons` and in
   the `AppIcon` enum.
4. `ruby scripts/relink-project-assets.rb --dry-run` — the output must
   list no `<absolute>` references. Xcode's "Add Files…"
   dialog writes absolute paths when the files live outside the project
   folder.

Only ship artwork you own or that is explicitly licensed for
redistribution; record it in `THIRD-PARTY-NOTICES.md`.

### Publishing rules

- Tags are `assets-YYYY.MM.DD`, the release date (`.N` for a second
  release on the same day), marked **pre-release** so they never become
  "Latest". The first tags (`assets-2026.10`, `assets-2026.10.1`,
  `assets-2026.10.2`) numbered releases within the month instead.
- Each lock entry carries its own tag; a partial update uploads only the
  changed files to a new tag and leaves the other entries pointing at the
  old one. The compliance payload is the exception: whenever a new tag
  receives anything, the unchanged notices, license texts and GPL source
  archives are re-attached to it too (`carried` in the plan) and their lock
  entries move to the new tag, so every Release that hosts dictionary
  assets is self-contained, as `THIRD-PARTY-NOTICES.md` states.
- `publish-assets.sh` creates a **draft** for a new tag; review it, publish
  with `gh release edit <tag> --draft=false`, then commit the rewritten lock.
- `--amend` revises an existing tag in place (changed files are compared by
  SHA-256 digest, deleted and re-uploaded). Once other people build from the repository, prefer a new
  tag, because an amended file changes under clones that pinned the old lock.
  Clones recover on their own: `bootstrap-assets.sh` replaces files it
  downloaded earlier when the lock moves on, and only refuses to overwrite
  files that look like local builds.
- If Immutable Releases are enabled, assets and tag names are permanently
  fixed — `--amend` then fails and a new tag is the only option.
- The Release payload also carries `THIRD-PARTY-NOTICES.md`, the license
  texts (taken from `preset-dicts/licenses/` when present: the WordNet and
  Unicode licenses; the other SPDX texts, including AGPL-3.0-or-later for
  FreeDict, are fetched), and the GPL source archives
  (`freedict-eng-deu.src.tar.xz`, `freedict-deu-eng.src.tar.xz`,
  `gcide-0.53.tar.xz`, kept in `preset-dicts/data/` by `fetch_data.sh`) so
  the compiled dictionaries satisfy GPLv3 §6. Older Releases keep their own
  copies: assets are never deleted from a published Release.

### Publishing the dictionary sources

The conversion scripts of the GPL/AGPL presets (FreeDict EN-DE, FreeDict
DE-EN, GCIDE) and their upstream source archives are public at
<https://github.com/naco-siren/OpenMDict-dictionary-sources>, which the three
dictionaries' descriptions and `THIRD-PARTY-NOTICES.md` link. Whenever one of
them is rebuilt with a different output, publish a matching tag there (the
asset tag without its `assets-` prefix) before the app build that ships it:

```bash
git clone git@github.com:naco-siren/OpenMDict-dictionary-sources.git /tmp/ds
scripts/export-dictionary-sources.sh /tmp/ds
cd /tmp/ds
make                    # fetches and verifies the archives, rebuilds, checks SHA256SUMS
git add -A && git commit -m "Scripts for assets-YYYY.MM.DD[.N]"
git tag YYYY.MM.DD[.N] && git push origin main YYYY.MM.DD[.N]
gh release create YYYY.MM.DD[.N] --title YYYY.MM.DD[.N] --notes "…" \
  <preset-dicts/data/freedict/freedict-{eng-deu,deu-eng}.src.tar.xz> \
  <preset-dicts/data/gcide/gcide-0.53.tar.xz>
```

`preset-dicts/dictionary-sources/` holds that repository's README, Makefile
and fetch script; the export adds the scripts and shared modules, `LICENSE`,
the three build pins and `SHA256SUMS` from the catalog. Keep every tag and
Release there: each one is the source of dictionary files that an installed
app build may carry.

### Verifying a clean clone

```bash
git clone <repo> omd && cd omd
scripts/bootstrap-assets.sh && scripts/bootstrap-assets.sh --check
swift build -c release && swift test
xcodebuild -project Apps/iOS/OpenMDict-iOS/OpenMDict-iOS.xcodeproj -scheme OpenMDict-iOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

A second `bootstrap-assets.sh` must be a no-op (no mtime changes, no
incremental Xcode work).

## Warning: `git clean -x` and the pipeline directories

`preset-dicts/data/` (source data, several GB) and `preset-dicts/output/`
(built dictionaries, more GB) are gitignored and may be symlinks to
directories outside the checkout. `git clean -x`, `git clean -X` and
`git clean -fdx` **delete ignored files** — they will wipe those
directories (or the symlinks, which is harmless, but a real directory is
gone for good). Prefer `git clean -fd` (no `-x`), run `git clean -n` first,
and keep a backup of `data/`. `bootstrap-assets.sh` can restore `output/`
from the published assets; nothing restores `data/` except
`fetch_data.sh`, and it cannot bring back the pinned release of the
upstreams that serve only their latest one (CC-CEDICT, Kaikki.org,
JMdict, KANJIDIC2, CrossWire KorRV and JapBungo, eBible.org grcbyz).

## Documentation map

| Topic | File |
|---|---|
| Overview, library usage, documentation index | `README.md` |
| Building from a clean clone, running and signing the app, tests | `docs/development.md` |
| `openmdict` command reference | `docs/cli.md` |
| Memory mapping, sidecar index, signposts, `openmdict-bench` | `docs/performance.md` |
| Dictionary pipeline, build targets, licenses by source | `preset-dicts/README.md`, `preset-dicts/FORMATTING_STANDARD.md` |
| MDX/MDD container format (header layout used by the determinism fix) | `docs/MDict_Format_Specification.md` |
| Core Data under Swift 6 strict concurrency | `docs/CoreData_Swift6_Concurrency.md` |
| Semantic search and article embeddings (model, sidecar format, ODR delivery, Xcode quirks) | `docs/article-embeddings.md` |
| Third-party licenses and attributions | `THIRD-PARTY-NOTICES.md` |
