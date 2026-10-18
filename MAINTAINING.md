# Maintaining OpenMDict

This page is for people who change the **assets** the iOS app depends on:
the preset dictionaries, the article-embedding model and the app icons.
For building and contributing to the code, see `README.md`; for the
dictionary pipeline itself, see `preset-dicts/README.md`.

## Four sources of truth

The app's assets are described in four places that must agree:

| Where | What it says |
|---|---|
| `preset-dicts/preset-dictionaries.json` (the **catalog**) | Which dictionaries exist, their metadata, `bundle` vs `odr`, `odrTag`, size, entry count, SPDX license |
| `Apps/iOS/OpenMDict-iOS/OpenMDict-iOS.xcodeproj/project.pbxproj` | Which `.mdx` files Xcode copies / tags (`ASSET_TAGS`, `KnownAssetTags`), relative to `SOURCE_ROOT` |
| `preset-dicts/assets.lock.json` (the **lock**) | File name, size, SHA-256 and Release tag of every downloadable asset |
| GitHub Releases (`assets-YYYY.MM[.N]`, pre-release) | The actual bytes: 64 `.mdx`, the zipped `.mlpackage` + `vocab.txt`, the notices and GPL source archives |

Large files are **not** in git and not in LFS. A fresh clone runs
`scripts/bootstrap-assets.sh`, which downloads everything the lock lists,
verifies the hashes and compiles the model. `scripts/check-assets.sh`
verifies that catalog == pbxproj == lock and runs in CI, so drift between
the four is caught before it reaches `main`.

## Prerequisites

| Tool | Needed for |
|---|---|
| Python 3.10+ and `pip install mdict-utils==1.3.14` (provides the `mdict` CLI) | Building dictionaries |
| Ruby with the `xcodeproj` gem (`gem install xcodeproj`) | `scripts/relink-project-assets.rb` |
| `jq`, `curl`, `shasum` (all on macOS 15+) | `scripts/bootstrap-assets.sh` |
| Xcode (for `xcrun coremlcompiler`) | Compiling the model after bootstrap |
| `gh` (GitHub CLI), authenticated | `scripts/publish-assets.sh` |
| Docker (only to **rebuild** the model) | `scripts/model/build-minilm.Dockerfile` |

## The scripts

| Script | Purpose |
|---|---|
| `scripts/bootstrap-assets.sh [--check\|--force]` | Download every asset in the lock into place (`preset-dicts/output/<Name>/<Name>.mdx`, `Apps/iOS/OpenMDict-iOS/Article Embeddings/`), verify SHA-256, unzip the model and run the precompile step when the model changed. Files that already match the lock are skipped without touching their mtime. `--check` only reports drift (non-zero exit) and is what CI and the Xcode "Check bootstrapped assets" run-script use. Files it downloaded (or verified) earlier are replaced automatically when the lock moves on. `--force` also overwrites local files whose hash differs from the lock and that were never published (for example a dictionary you rebuilt locally); without it the script refuses and tells you which files differ. `OPENMDICT_ASSETS_BASE_URL` overrides the download base (default: this repository's Releases) so a staging directory served with `python3 -m http.server` can be used for dry runs. While the repository is private, unauthenticated Release downloads return 404 and the script switches to `gh release download` (requires `gh auth login`). |
| `scripts/publish-assets.sh --tag assets-YYYY.MM[.N]` | Hash the local assets, upload only the ones whose hash is not yet in the lock to a **draft** pre-release under the given (new) tag, rewrite the lock, and stage the compliance payload: the committed `THIRD-PARTY-NOTICES.md` (regenerate it first — the script copies, it does not generate), `LICENSE-<SPDX>.txt` texts (SPDX ids are fetched; `LicenseRef-*` texts such as the WordNet license are taken from `preset-dicts/licenses/`) and the GPL source archives. Review the draft, then `gh release edit <tag> --draft=false` and commit the lock. `--dry-run` / `--stage-only` need no `gh`. |
| `scripts/check-assets.sh` | Consistency gate: every catalog entry has a pbxproj reference with the right `ASSET_TAGS`, every `odrTag` is in `KnownAssetTags`, every file is in the lock, and nothing in the lock is orphaned. Exit non-zero on drift. Runs in CI. |
| `scripts/relink-project-assets.rb [--sync] [--dry-run] [--project PATH]` | Rewrite the pbxproj (defaults to the iOS app project) so every asset reference is relative (`SOURCE_ROOT`), never absolute. `--sync` additionally adds/removes `.mdx` references and `ASSET_TAGS` to match the catalog and merges `KnownAssetTags`. `--dry-run` prints what would change. Idempotent. |
| `scripts/precompile-article-embed-model.sh` | `.mlpackage → .mlmodelc` with `xcrun coremlcompiler` (invoked by bootstrap when needed). |
| `preset-dicts/scripts/gen_third_party_notices.py [--check]` | Regenerate the dictionary table in `THIRD-PARTY-NOTICES.md` from the catalog. |
| `preset-dicts/scripts/sync_catalog_with_output.py [--check]` | Make the catalog's `sizeBytes` (and, with `--openmdict`, `entries`) match the `.mdx` files on disk. |

Read each script's header comment for the full option list.

## Change matrix

| You changed… | Then run… | Commit |
|---|---|---|
| **Dictionary content** (a build script, source data, `FORMATTING_STANDARD.md`) | `make -C preset-dicts <target>` → check the output → `scripts/publish-assets.sh --tag assets-YYYY.MM[.N]` → publish the draft | updated lock (+ catalog if size/entries changed) |
| **Added or removed a dictionary** | add/remove the build script + Makefile target + catalog entry (+ `bundle_assets` in `catalog-policy.json` if bundled) → `make -C preset-dicts <target>` → `ruby scripts/relink-project-assets.rb --sync` → `python3 preset-dicts/scripts/gen_third_party_notices.py` → `scripts/publish-assets.sh --tag assets-YYYY.MM[.N]` → `scripts/check-assets.sh` | catalog, pbxproj, lock, `THIRD-PARTY-NOTICES.md` |
| **Catalog metadata only** (description, tier, license) | edit `preset-dictionaries.json` → `python3 preset-dicts/scripts/gen_third_party_notices.py` → `scripts/check-assets.sh` | catalog, notices |
| **Embedding model** | rebuild (see below) → `scripts/precompile-article-embed-model.sh` → `scripts/publish-assets.sh --tag …` (it zips the `.mlpackage` itself) → update the model section of `THIRD-PARTY-NOTICES.md` if the model or its license changed | lock, notices |
| **App icon family** | drop the PNGs / `.icon` bundle into `Apps/iOS/OpenMDict-iOS/Resources/AppIcons/` → add them to the "App Icons" group in Xcode → `CFBundleAlternateIcons` in `Info.plist` → the `AppIcon` enum → `ruby scripts/relink-project-assets.rb --dry-run` must report no absolute references | icons, pbxproj, Info.plist, Swift |
| **Anything in the pbxproj via Xcode's "Add Files…"** | `ruby scripts/relink-project-assets.rb --dry-run` (Xcode happily writes `<absolute>` references) | pbxproj |

`scripts/check-assets.sh` runs in CI on every push; a red check means one of
the four sources of truth drifted.

## Workflows in detail

### Rebuilding a dictionary

```bash
cd preset-dicts
./scripts/fetch_data.sh cedict      # once; idempotent
make cedict                         # output/CEDICT-ZH-EN/CEDICT-ZH-EN.mdx + .meta.json
open output/CEDICT-ZH-EN/cedict_preview.html
cd ..
scripts/publish-assets.sh --tag assets-2026.11   # uploads only what changed to a NEW tag, rewrites the lock
gh release edit assets-2026.11 --draft=false     # after reviewing the draft
```

**Reproducible output.** mdict-utils stamps today's date into the MDX
header (`CreationDate`), which would make every rebuild a new file and force
a re-upload of everything. `preset-dicts/scripts/shared/build.py` therefore
rewrites the header after packing and recomputes its adler32, so an
unchanged input produces a byte-identical `.mdx`. The date is taken from,
in order: an explicit `creation_date=` argument, `SOURCE_DATE_EPOCH`, the
newest mtime of the `inputs=` passed by the build script, or the newest
mtime of any file under `preset-dicts/data/`. Fetching new data for *one*
source therefore moves the default date for every dictionary rebuilt
afterwards; when you want a rebuilt dictionary to match a published one
exactly, pin the date:

```bash
# -u: the epoch is interpreted in UTC when it is turned back into a date
SOURCE_DATE_EPOCH=$(date -ju -f %Y-%m-%d 2026-02-21 +%s) make cedict
```

The app identifies a dictionary by the SHA-256 of its raw header, so a
stable `CreationDate` also keeps the dictionary id stable across rebuilds.

**`make catalog`** regenerates `preset-dictionaries.json` from the
`.meta.json` sidecars, i.e. from whatever the build scripts emitted. The
committed catalog carries SPDX license ids and sizes that match the
*published* files; after regenerating, diff the result, restore the SPDX
spellings if a build script still emits the old ones, and run
`scripts/sync_catalog_with_output.py --check`.

### Adding or removing a dictionary

1. Source data: add a `fetch_<source>()` to `preset-dicts/scripts/fetch_data.sh`
   and record the license. Only openly licensed or public-domain data;
   anything "non-commercial" or "personal use" cannot ship.
2. `preset-dicts/scripts/build_<name>_mdx.py` following an existing script
   and `FORMATTING_STANDARD.md`; call `write_catalog_metadata(...)` with an
   SPDX license id.
3. Makefile target; `make <target>`.
4. Catalog entry (`make catalog`, then review the diff) — `bundle` assets are
   listed in `catalog-policy.json`, everything else gets an `odrTag`.
5. `ruby scripts/relink-project-assets.rb --sync` adds the `.mdx`
   reference, its `ASSET_TAGS` and the `KnownAssetTags` entry (or removes
   them). Never add preset `.mdx` files through Xcode's file dialog.
6. `python3 preset-dicts/scripts/gen_third_party_notices.py` (it fails if
   the new `dataSource` or license id has no row — add one), then
   `scripts/publish-assets.sh --tag assets-YYYY.MM[.N]` and publish the
   draft. For a `LicenseRef-*` license, put its text in
   `preset-dicts/licenses/LICENSE-<id>.txt` so the script can attach it.
7. `scripts/check-assets.sh` must pass. For a GPL-licensed source, attach
   the corresponding source archive to the same Release.

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

- Tags are `assets-YYYY.MM` (`.N` for a second release in the same month),
  marked **pre-release** so they never become "Latest".
- Each lock entry carries its own tag; a partial update uploads only the
  changed files to a new tag and leaves the other entries pointing at the
  old one.
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
  texts (SPDX texts are fetched; `LicenseRef-*` texts such as the WordNet
  license come from `preset-dicts/licenses/`), and the GPL source archives (`freedict-eng-deu.src.tar.xz`,
  `freedict-deu-eng.src.tar.xz`, `gcide-0.53.tar.xz`) so the compiled
  dictionaries satisfy GPLv3 §6.

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
`fetch_data.sh` (and some Bible sources are manual downloads).

## Documentation map

| Topic | File |
|---|---|
| Library API, CLI, tests, sidecar index | `README.md` |
| Dictionary pipeline, build targets, licenses by source | `preset-dicts/README.md`, `preset-dicts/FORMATTING_STANDARD.md` |
| MDX/MDD container format (header layout used by the determinism fix) | `docs/MDict_Format_Specification.md` |
| Core Data under Swift 6 strict concurrency | `docs/CoreData_Swift6_Concurrency.md` |
| Semantic search and article embeddings (model, sidecar format, ODR delivery, Xcode quirks) | `docs/article-embeddings.md` |
| Third-party licenses and attributions | `THIRD-PARTY-NOTICES.md` |
