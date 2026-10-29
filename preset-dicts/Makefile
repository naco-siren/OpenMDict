# ── OpenMDict preset-dicts build system ──────────────────────
#
# Usage:
#   make all            Build all dictionaries, then check the catalog
#   make cedict         Build a single dictionary
#   make catalog        Regenerate preset-dictionaries.json from output/
#   make check-catalog  Fail if the catalog or the notices are out of date
#   make check-notices  Fail if the notices or the Settings licenses are stale (needs no output/)
#   make notices        Regenerate ../THIRD-PARTY-NOTICES.md (generated part) and the Settings.bundle Licenses pages
#   make list           Show all available targets
#
# Each build script produces output/<Name>/<Name>.mdx + a .meta.json
# sidecar. `make catalog` builds the catalog from the sidecars (names,
# descriptions, licenses, tiers) and from the .mdx files themselves
# (sha256, sizeBytes, entries), keeps licenseNote and previousSha256, and
# prints every field it changed: review that diff before committing.
#
# `make all` never rewrites the catalog. It ends with `check-catalog`,
# which fails (listing the fields) when the rebuilt files no longer match
# the committed catalog or THIRD-PARTY-NOTICES.md; then run
# `make catalog notices` and review the result.
#
# NOTE  data/ and output/ are gitignored (and may be symlinks to a
#       directory outside the checkout). `git clean -x` / `-X` deletes
#       them -- that is many gigabytes of source data and build output.
#       See ../MAINTAINING.md.
#
# Reproducible output: scripts/shared/build.py stamps the MDX header
# CreationDate from build-pins.json, so rebuilding unchanged inputs yields
# byte-identical .mdx files (and unchanged dictionary IDs). Do not set
# SOURCE_DATE_EPOCH for release builds: it overrides the pins.
# ──────────────────────────────────────────────────────────────

PYTHON   := python3
SCRIPTS  := scripts
MANIFEST := preset-dictionaries.json

# ── Individual dictionary targets ─────────────────────────────

.PHONY: all catalog check-catalog check-notices notices descriptions list help \
        wordnet moby cedict jmdict gcide kanjidic2 unihan \
        perseus cccanto bible freedict kaikki wikdict wiktionary

wordnet:
	$(PYTHON) $(SCRIPTS)/build_wordnet_mdx.py

moby:
	$(PYTHON) $(SCRIPTS)/build_moby_thesaurus_mdx.py

cedict:
	$(PYTHON) $(SCRIPTS)/build_cedict_mdx.py

jmdict:
	$(PYTHON) $(SCRIPTS)/build_jmdict_mdx.py

gcide:
	$(PYTHON) $(SCRIPTS)/build_gcide_mdx.py

kanjidic2:
	$(PYTHON) $(SCRIPTS)/build_kanjidic2_mdx.py

unihan:
	$(PYTHON) $(SCRIPTS)/build_unihan_mdx.py

perseus:
	$(PYTHON) $(SCRIPTS)/build_perseus_mdx.py

cccanto:
	$(PYTHON) $(SCRIPTS)/build_cccanto_mdx.py

bible:
	$(PYTHON) $(SCRIPTS)/build_bible_mdx.py

freedict:
	$(PYTHON) $(SCRIPTS)/build_freedict_mdx.py

kaikki:
	$(PYTHON) $(SCRIPTS)/build_kaikki_mdx.py

wikdict:
	$(PYTHON) $(SCRIPTS)/build_wikdict_mdx.py --all

wiktionary:
	$(PYTHON) $(SCRIPTS)/build_wiktionary_mdx.py

# ── Aggregate targets ─────────────────────────────────────────

all: wordnet moby cedict jmdict gcide kanjidic2 unihan \
     perseus cccanto bible freedict kaikki wikdict wiktionary
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  All dictionaries built.  Checking the catalog…"
	@echo "══════════════════════════════════════════════════════"
	@$(MAKE) --no-print-directory check-catalog

# ── Catalog generation ──────────────────────────────────────────

catalog:
	@$(PYTHON) $(SCRIPTS)/generate_preset_catalog.py

# Drift check: the catalog must describe the files in output/ (sha256,
# sizeBytes, entries, and the sidecars' licenses and descriptions), and
# the notices must match the catalog.
check-catalog:
	@$(PYTHON) $(SCRIPTS)/generate_preset_catalog.py --check
	@$(MAKE) --no-print-directory check-notices

# The notices and the Settings licenses can be checked without output/.
check-notices:
	@$(PYTHON) $(SCRIPTS)/gen_third_party_notices.py --check
	@$(PYTHON) ../scripts/gen-settings-licenses.py --check

# ── Third-party notices (generated block in ../THIRD-PARTY-NOTICES.md, and the
#    Licenses pages of the app's Settings.bundle that are generated from it) ──

notices:
	@$(PYTHON) $(SCRIPTS)/gen_third_party_notices.py
	@$(PYTHON) ../scripts/gen-settings-licenses.py

# ── Header descriptions (no build) ──────────────────────────────
# Every build script exposes descriptions(); this writes the HTML each
# dictionary's MDX header will carry to output/_descriptions/ (one file
# per dictionary plus index.html) so the text can be reviewed first.
descriptions:
	@$(PYTHON) $(SCRIPTS)/preview_descriptions.py --out output/_descriptions

# ── Utilities ─────────────────────────────────────────────────

list:
	@echo "Individual:  wordnet moby cedict jmdict gcide kanjidic2 unihan"
	@echo "             perseus cccanto bible freedict kaikki wikdict wiktionary"
	@echo "Aggregate:   all            (builds everything, then check-catalog)"
	@echo "Catalog:     catalog        (regenerate preset-dictionaries.json, print the diff)"
	@echo "             check-catalog  (fail if the catalog or notices are stale)"
	@echo "             check-notices  (notices and Settings licenses only; needs no output/)"
	@echo "Notices:     notices"
	@echo "Preview:     descriptions   (write every header description to output/_descriptions/)"

help: list
