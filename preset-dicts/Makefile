# ── OpenMDict preset-dicts build system ──────────────────────
#
# Usage:
#   make all          Build all dictionaries + regenerate the catalog
#   make catalog      Regenerate preset-dictionaries.json from .meta.json sidecars
#   make cedict       Build a single dictionary
#   make list         Show all available targets
#
# Each build script produces <Name>/<Name>.mdx + a .meta.json sidecar
# under output/. `make catalog` collects all sidecars into
# preset-dictionaries.json.
#
# NOTE  `make catalog` rewrites the catalog from the sidecars, i.e. from
#       whatever the build scripts emitted. The committed catalog carries
#       SPDX license ids (see gen_third_party_notices.py) and sizes that
#       match the *published* .mdx files; after regenerating, diff the
#       result and run scripts/sync_catalog_with_output.py --check.
#
# NOTE  data/ and output/ are gitignored (and may be symlinks to a
#       directory outside the checkout). `git clean -x` / `-X` deletes
#       them -- that is many gigabytes of source data and build output.
#       See ../MAINTAINING.md.
#
# Reproducible output: the MDX header CreationDate is pinned by
# scripts/shared/build.py (SOURCE_DATE_EPOCH > newest input mtime), so
# rebuilding unchanged inputs yields byte-identical .mdx files.
#   SOURCE_DATE_EPOCH=1700000000 make cedict
# ──────────────────────────────────────────────────────────────

PYTHON   := python3
SCRIPTS  := scripts
MANIFEST := preset-dictionaries.json

# ── Individual dictionary targets ─────────────────────────────

.PHONY: all catalog notices list help \
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
	$(PYTHON) $(SCRIPTS)/build_wikdict_mdx.py

wiktionary:
	$(PYTHON) $(SCRIPTS)/build_wiktionary_mdx.py

# ── Aggregate targets ─────────────────────────────────────────

all: wordnet moby cedict jmdict gcide kanjidic2 unihan \
     perseus cccanto bible freedict kaikki wikdict wiktionary \
     catalog
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  All dictionaries built.  Catalog refreshed."
	@echo "══════════════════════════════════════════════════════"

# ── Catalog generation ──────────────────────────────────────────

catalog:
	@$(PYTHON) $(SCRIPTS)/generate_preset_catalog.py

# ── Third-party notices (table in ../THIRD-PARTY-NOTICES.md) ──

notices:
	@$(PYTHON) $(SCRIPTS)/gen_third_party_notices.py

# ── Utilities ─────────────────────────────────────────────────

list:
	@echo "Individual:  wordnet moby cedict jmdict gcide kanjidic2 unihan"
	@echo "             perseus cccanto bible freedict kaikki wikdict wiktionary"
	@echo "Aggregate:   all"
	@echo "Catalog:     catalog"
	@echo "Notices:     notices"

help: list
