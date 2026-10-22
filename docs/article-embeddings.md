# Semantic search and article embeddings

Design notes for the semantic-search features of OpenMDict-iOS ("M15" in
commit messages). Three phases shipped or were prototyped:

| Phase | Feature | Status |
|---|---|---|
| 1 | *Semantic* search scope over **headwords**, `NLEmbedding` cosine with a per-dictionary vector cache | superseded by Phase 2 |
| 2 | Same scope, cache deleted — `NLEmbedding.neighbors` at query time | shipped |
| 3 | *Article* search scope over **article bodies**, on-device MiniLM embeddings persisted in a sidecar index, model delivered through On-Demand Resources | shipped (iOS 26+) |

Where the code lives:

- `Sources/OpenMDict/Semantic/ArticleEmbed/` — tokenizer, Core ML encoder
  wrapper, sidecar format, writer and mmap reader (platform-agnostic, used
  by the CLI and the app)
- `Apps/CLI/` — `openmdict <mdx> semantic …`, `openmdict articleembed …`,
  `openmdict articleindex {build,info,query} …` probes
- `Apps/iOS/OpenMDict-iOS/OpenMDict-iOS/Services/Semantic/` — headword
  semantic search (Phases 1–2)
- `Apps/iOS/OpenMDict-iOS/OpenMDict-iOS/Services/ArticleEmbed/` — Phase 3
  coordinator, dispatcher, background scheduler, ODR asset provider
- `Apps/iOS/OpenMDict-iOS/Article Embeddings/` — model + vocab assets
  (downloaded by `scripts/bootstrap-assets.sh`, not committed)
- `scripts/model/` — PyTorch → Core ML conversion (only needed to rebuild
  the model)

---

## Phase 1 — In-memory semantic search over headwords

User-visible delivery: a *Semantic* scope in the word-list search bar,
parallel to the existing *Spelling* scope. Tapping the scope toggle swaps the
`LookupSessionProtocol` implementation backing the results table:

```
WordListVC.searchSession: any LookupSessionProtocol
                          │
            ┌─────────────┴─────────────┐
            │                            │
    SpellingLookupSession        SemanticLookupSession
    (Spelling scope)             (Semantic scope)
    Levenshtein + lemma          NLEmbedding cosine
            │                            │
            └────────────┬───────────────┘
                         ▼
            SemanticSearchService.shared (NLEmbedding + per-dict cache)
```

### Steps

- Step 0 — CLI probe (`openmdict <mdx> semantic <word>`); `NLEmbedding`
  quality confirmed.
- Step 0.5 — Lemma fix, stopword filter, automatic language detection,
  lemma dedup against the query.
- Bench — multi-source real-data validation: CEFR-stratified query samples
  cross-checked against Ogden's Basic English (850), the General Service
  List (2000), a general-English frequency list and a published ESL
  difficulty dataset. (The bench driver and datasets are not part of this
  repository.)
- Step 1.1 — `RelatedWordsTier` enum + Settings.bundle entry + 13-language
  strings for the scope-bar labels and the new setting.
- Step 1.2 — `Services/Semantic/SemanticSearchService.swift`: `NLEmbedding`
  compute engine with a per-dict vector cache, lazy preload, lemma dedup,
  cross-group merge, per-phase progress reporting.
- Step 1.3 — `Services/Sessions/SemanticLookupSession.swift`: drop-in
  `LookupSessionProtocol` implementation; idempotent `updateQuery`; clears
  stale state on a new query so the loading spinner surfaces; typo fallback
  via Levenshtein when the semantic count is below 8.
- Step 1.4 — `WordListViewController` scope segmented control with
  on-the-fly session swap; per-scope query/result state preserved across
  flips; phase-status stream surfaced in the loading empty state.
- Step 1.5 — Tier values bumped to 12/24/48 after the candidate-list UX
  overhaul (one row per unique word, no per-dict duplication — smaller
  defaults felt undersized).
- Polish — "searching" empty state redesigned with dynamic phase messages.

### Tier parameters (locked)

| Tier | K |
|---|---:|
| Few | 12 |
| Default | 24 |
| More | 48 |

Single uniform cosine floor of 0.45; the tier knob is purely K. Under-fill
is fine (no padding). Lemma dedup is seeded with the query's canonical
lemma; words are case-folded and deduplicated across dictionaries. Falls
back to Levenshtein fuzzy suggestions when fewer than 8 semantic matches
survive.

### Tools

- `openmdict <mdx> semantic <word> [--lang en] [--limit 10] [--scope both]`
  — single-query probe
- `openmdict <mdx> semantic matrix [--words-file FILE] [--out-json FILE]`
  — bench mode
- `openmdict neighbors-bench [--words-file FILE] [--lang en]
  [--max-neighbors N]` — `NLEmbedding.neighbors` latency probe (Phase 2)

---

## Phase 2 — `NLEmbedding`-direct (no cache)

**Decision: Option C** (see the design history in the appendix). The perf
probe (`openmdict neighbors-bench`) measured
`NLEmbedding.neighbors(for:maximumCount:)` at **p95 ≈ 1.1 ms on a Mac
(~3.5 ms estimated on iOS)** — 50× under the 200 ms gate.

### Outcome

- Per-dict vector cache **deleted**: `DictVectors`, `VectorEntry`, `cache`,
  `inFlight`, `preload`, `computeVectors`, the entire pre-scan path.
- Replaced with a per-query path: group active dicts by detected language →
  for each language `embedding.neighbors(for: query, maximumCount: 500)` →
  filter via `MDictReader.lookup` (O(log N)) → merge + sort + lemma dedup →
  take `tier.k`.
- Service surface shrank to `relatedKeywords(query:in:tier:)`. No progress
  callback, no `SemanticSearchPhase` enum.
- `SemanticLookupSession` no longer narrates per-phase status; only
  `statusCheckingSpelling` remains (the Levenshtein fallback is slow enough
  to warrant a line).
- L10n: `statusLoadingDict` / `statusComputingSemantic` dropped from
  `L10n.swift`; the xcstrings entries were kept so the translations survive
  if the phases return.
- Quality: top-10 neighbors for *happy / quick / beautiful / sad / anger /
  laugh* spot-checked against the Phase 1 brute-force CLI baseline — 6–10
  dictionary-found candidates per query out of the top 10, enough to fill
  K = 12/24/48 across a multi-dictionary group.

### Memory impact

The ~845 MB Phase 1 cost was not novel storage; it was **duplication**.
`NLEmbedding` already holds its full vector vocabulary internally; Phase 1
copied those vectors per dictionary, keyed by every word in every
dictionary. Across a 13-dictionary group, common-word vectors were copied
10+ times. Option C keeps only `NLEmbedding`'s internal copy.

| | Phase 1 | Phase 2 (Option C) |
|---|---:|---:|
| NLEmbedding framework (not ours to change) | ~70 MB | ~70 MB |
| App-owned `[dictId: DictVectors]` cache | **~845 MB** (duplicates) | **0** |
| Per-dict language tag | — | ~16 B × #dicts |
| **Net semantic feature overhead** | **~915 MB** | **~70 MB** |

Roughly a **13× drop** in the headroom needed to enable the semantic scope
on a large group; the app footprint went from 1.1 GB+ (with occasional
jetsam kills) back to normal. The ~70 MB framework figure is
back-of-envelope (Apple's EN model ~57k × 300 × 4 B + CN model ~30k × 300 ×
4 B ≈ 104 MB raw, less if the framework compresses internally).

### Known trade-offs (the embeddings are now a black box)

- **Vocabulary is fixed** — ~57k EN / ~30k CN etc., Apple's rather than
  ours. Domain-specific words absent from Apple's vocabulary silently
  return no semantic matches; the Levenshtein fallback catches typos but
  not legitimate out-of-vocabulary terms.
- **Distance metric / threshold are opaque** —
  `neighbors(for:maximumCount:)` applies an internal cosine-distance
  threshold (empirically ~1.0) that caps the result around 50 candidates
  regardless of `maximumCount`. Phase 1's brute-force sweep at least
  exposed a score.
- **No introspection** — vectors cannot be inspected, persisted or shared
  with other features.
- **Behavior drifts with iOS** — Apple may update vocabulary, vectors or
  threshold in any release; the Phase 1 bench is a snapshot of iOS 18.x
  behavior and should be re-run on each major iOS bump.
- **Languages without an `NLEmbedding` model get nothing** — Hindi, Arabic,
  Thai and several others have no word-level model; the scope silently
  falls through to spelling suggestions for them. Phase 1 could in
  principle have shipped our own embeddings; Phase 2 forecloses that path.

Accepted because (a) jetsam is the hard ceiling, (b) Apple's EN/CN coverage
is good enough per the Phase 1 bench, (c) training or maintaining
embeddings is out of scope. Worth re-evaluating if a major-language
dictionary ships that `NLEmbedding` materially under-serves.

### What did not land

- **Option A (folded per-language cache)** — fallback if Option C had
  failed the perf gate. Not needed.
- **Option B (sidecar v2 mmap)** — wrong layer: the cache duplicated vectors
  `NLEmbedding` already had, so persistence would not have removed the
  duplication.
- **Sidecar persistence for headword vectors** — moot; there is no
  per-headword cache any more. (Phase 3's body-text vectors *do* use sidecar
  persistence, but that is a different cache and a different problem.)

---

## Phase 3 — Article-body semantic indexing

Phase 2 exposed that "semantic" via headword neighbors is bounded by Apple's
`NLEmbedding` vocabulary. Phase 3 makes the article **body text**
searchable semantically — "find articles whose content discusses my query".
This is where the Neural Engine / GPU earn their keep.

### Decisions locked

- **UX**: a third scope, *Article*, parallel to *Spelling* and *Semantic*.
  Not merged into *Semantic* because (a) it is the most expensive and (b)
  first-time access on an unindexed dictionary may trigger indexing — users
  opt in explicitly.
- **Two indexing triggers**: at dictionary import (hidden inside the
  existing import progress flow), and at scope switch (missing sidecar →
  on-the-fly indexing with progress UI, or queued background best-effort).
- **Model runtime**: Core ML only. No llama.cpp / MediaPipe / ONNX Runtime
  / Python interop. The only model-side Swift code we own is the WordPiece
  tokenizer (~200 LOC, dependency-free) and a thin `MLModel` wrapper.
- **Model delivery**: On-Demand Resources, the same mechanism preset
  dictionaries use. The ~80 MB model never bloats the base download.

### Indexing pipeline (per dictionary, one-time)

```
for each MDX article:
  1. strip HTML → plaintext       (~50 LOC, regex + entity decode)
  2. tokenize → token ids          (WordPiece, ~200 LOC + vocab.txt)
  3. Core ML MiniLM encoder        (auto-routed to ANE/GPU)
       → 384-dim float32
  4. L2-normalize → Float16
  5. append to sidecar
```

### Query pipeline (per query)

**Per-dictionary streaming, not all-at-once.** Mirrors the Action Extension
pattern: load → scan → emit → unload → next. Trades a little wall-clock time
for a flat memory profile and incremental UX (rows appear as each
dictionary completes, in the user's group order).

```
1. query → tokenize → encode             (~2 ms on ANE / ~30 ms on A12 GPU)
2. for dict in activeDicts (group order):
     mmap dict.sidecar                   // ~10–40 MB clean, transient
     vDSP_dotpr cosine vs dict vectors   // 5–50 ms depending on dict size
     pick top-K per dict
     append to view model → WordListVC   // user sees rows incrementally
     munmap dict.sidecar                 // immediate page release
3. final dedup pass on accumulated results (cross-dict identical key)
```

Cancellation: a new query mid-loop cancels the in-flight dictionary's scan,
munmaps and restarts with the new query. Never more than one sidecar is
mapped at a time.

### Sidecar format

Path: `AppGroup/Library/Caches/SemanticIndex/<dictId>.semantic.idx`
(parallel to the keyword sidecar under `MDXIndex/`; OS-evictable, not
backed up, not synced). Source of truth:
`Sources/OpenMDict/Semantic/ArticleEmbed/ArticleIndexFormat.swift`.

**Binary layout**, format version 2 (128-byte little-endian header + one
row per real article):

```
Off    Size  Field
─────────────────────────────────────────
  0      4   magic "SIDX"
  4      2   format version (= 2)
  6      2   reserved
  8     32   model_sha256
 40     32   mdx_header_sha256
 72      4   embedding_dim (= 384 for MiniLM-L6)
 76      4   0 (version 1's article_count — a version-1 reader sees no rows)
 80      4   tokenizer_max_len (= 128)
 84      8   created_at (UNIX seconds)
 92      4   reserved
 96      4   row_count  (vector rows committed)
100      4   key_count  (MDX keys covered from index 0; = entryCount when complete)
104     24   reserved
─── 128 bytes ───
128+   R×(4+d×2)  rows in ascending key order:
                  u32 key_index (position in MDictReader.allKeys)
                  d × Float16 embedding of that record
─────────────────────────────────────────
file_size = 128 + R × (4 + d × 2)
```

Only real articles get a row. A `@@@LINK=` alias (or a missing record) is
walked past and counted in `key_count`, but stores nothing — alias-heavy
dictionaries used to spend most of their index on all-zero rows:

| Dictionary | Keys | Articles | v1 (dense) | v2 (sparse) |
|---|---:|---:|---:|---:|
| Bible-KJV-EN | 77,616 | 1,189 | 56.8 MB | 0.9 MB |
| LSJ-GRC-EN | 343,051 | 115,717 | 251.3 MB | 85.2 MB |
| JMdict-JA-EN | 583,290 | 223,713 | 427.2 MB | 164.7 MB |

(384-dim, all-MiniLM-L6-v2. KJV and LSJ measured with `openmdict
articleindex build`; JMdict from the formulas above.) The 4-byte key index
costs 0.5% per row, so a dictionary without aliases grows by that much.
A build costs the encode of each article plus one decompression per record
block: aliases are never encoded, and the writer walks the keys in record
order keeping the last decompressed block (`MDictRecordWalker`), so telling
an alias from an article does not decompress its block again (KJV on an
Intel i7 Mac: 137.9 G → 87.7 G instructions, 22.5 s → 15.5 s; the rows are
identical). The cosine scan reads only the article rows,
so it shrinks in the same proportion (KJV on an Intel i7 Mac: ~55 ms → ~1 ms
per query). The query result is unchanged: hits carry the key index, rows
are scanned in key order, and an alias never had a non-zero row to match.

**Version 1** (the dense layout used before) has the same fields up to offset
96, where the body starts: `article_count` (offset 76) rows of `d × Float16`,
row *i* ↔ `allKeys[i]`, aliases as all-zero rows the scan skips.
`ArticleIndexReader` still queries it. The writer never resumes a version-1
partial — like any other format mismatch it starts the build over in
version 2.

**Launch check.** When the app starts, `ArticleIndexCoordinator` reads every
recorded dictionary's sidecar header (off the main actor; builds wait for
it) and makes the record agree with the file (`ArticleIndexSidecar`):

- a version-2 file stays — complete, or a partial the writer resumes;
- a complete version-1 index is converted in place once its dictionary has
  loaded: the article rows are copied behind their key index, aliases
  (decided from the `@@@LINK=` records) dropped, the result written next to
  it, read back and renamed over it. Nothing is encoded, and the result is
  byte-identical to a fresh version-2 build apart from `created_at`. Until
  then the version-1 index is still queried;
- a version-1 index whose rows don't match its records is deleted and
  rebuilt instead. Writers before 2026-10-20 (app 1.0.1 and earlier)
  embedded `lookup(key)` for every key: alias rows hold a copy
  of their target's vector — which made one article fill the top-K under
  each of its alias keys — and the records of a homograph key share one
  vector. The converter sees a non-zero alias row, or two adjacent records
  of one key with different text but the same row;
- anything else is deleted and the dictionary's progress restarts at 0: a
  version-1 partial, a version this build doesn't know (a newer build wrote
  it), a corrupt or truncated file. So is the progress of a record whose
  file is gone (Caches/ evicted). An indexed dictionary becomes
  `.notIndexed`, so the backfill rebuilds it.

A version the reader does not know is refused (`.wrongVersion`), and so is a
header whose `embedding_dim` is outside 1…4096 or whose sizes overflow
(`.headerInvalid`); the query path skips such a dictionary until the launch
check has reset it. An older app build reads a version-2 file as an empty
version-1 index (offset 76 is 0) and never rebuilds it; turning article
search off and on there rebuilds every index.

Three-field invalidation (model SHA-256 + MDX header SHA-256 + format
version) catches any model swap or MDX edit; a mismatch makes the writer
start over instead of resuming.

**Resumable writes.** The writer appends rows to one file and checkpoints
every 2,000 keys: truncate to the committed size, write `row_count`, then
`key_count`, fsync. Progress and `indexedThrough` count keys (aliases
included) against `entryCount`, which is known without reading any record.
After a crash, trailing bytes past the committed rows are overwritten, and if
the process died between the two header writes the resume continues after
the last row's key index, so no record gets a second row.

50k articles × (4 + 384 × 2 B) ≈ 37 MB on disk per dictionary; a 13-dictionary
group ≈ 480 MB, mapped as clean file-backed pages (jetsam-friendly).

Implementation notes:

- **Hand-rolled Float → FP16 bit conversion** (instead of Swift's `Float16`
  type) because Intel macOS toolchains have inconsistent `Float16` support;
  direct IEEE 754 bit manipulation makes the on-disk bytes identical across
  Intel and Apple Silicon machines.
- **macOS-only `autoreleasepool`** around each `encoder.encode` call —
  without it the IOSurface/MTLBuffer pool leaks across the inference loop
  and the CLI writer crashes after a few hundred predictions with "Failed to
  allocate memory IOSurface object". iOS does not need it (its run loop
  autoreleases naturally); the CLI uses it defensively.
- Verified end-to-end on the first 500 WordNet-EN articles: 105 ips on an
  Intel Mac (GPU path); file size 375 KB (= 96 + 500 × 384 × 2 exactly, in
  the version-1 layout);
  `articleindex info` validates the header against the MDX and the model
  and detects a model-SHA mismatch.

### Heterogeneous compute: estimates vs. reality

Pre-POC estimates (vs. single-thread CPU):

| Stage | CPU 1-thread | Neural Engine | Metal/GPU |
|---|---:|---:|---:|
| Index 650k articles | ~3 h | **~3 min** | ~5 min |
| Embed 1 query | ~50 ms | **~2 ms** | ~5 ms |
| 650k-vector cosine scan | ~100 ms vDSP | n/a | **~5 ms** MPS |

The actual POC (below) showed the ANE column is gated by FP16 conversion:
the FP32 `.mlpackage` does not engage the ANE on A12/A14-class chips (those
generations only accept FP16 weights at the ANE).

### Query-time memory model

Per-dictionary streaming keeps the runtime footprint **flat regardless of
group size**. Numbers for a 13-dictionary group with ~338k articles in
total:

| Component | Dirty (counts against jetsam) | Clean (mmap, kernel-evictable) |
|---|---:|---:|
| Idle app baseline | ~200 MB | — |
| Model resident (FP32 mlmodelc) | ~90 MB | — |
| Sidecar of the CURRENT dict | — | ~10–40 MB |
| Sidecars of PAST/FUTURE dicts | 0 | 0 |
| Query-embed inference transient | +~150 MB peak | — |
| **Peak during query** | **~440 MB** | **~40 MB** |
| Idle after query | ~290 MB (model keep-alive) | 0 |

Compared with a naive all-at-once design:

| | Per-dict streaming (chosen) | All-at-once |
|---|---:|---:|
| Peak clean mmap | ~40 MB | ~260 MB |
| Peak dirty | ~440 MB | ~440 MB |
| Query wall clock | sum of dict scans (~650 ms) | max of parallel scans (~50 ms) |
| First result visible | t ≈ 80 ms (after dict 1) | t ≈ 650 ms (after merge) |
| Cancellable mid-query | trivial (no global state) | needs extra plumbing |

Clean pages do not count against jetsam, but they do consume physical RAM
until the kernel evicts them; on memory-pressured devices that pressure
fires app-level memory warnings. Streaming sidesteps that entirely.

### Phase 3.0 — Toolchain and CLI probe

- WordPiece tokenizer in Swift
  (`Sources/OpenMDict/Semantic/ArticleEmbed/ArticleTokenizer.swift`, ~200
  LOC, BERT-uncased variant; EN-only for the MVP, CJK per-character
  segmentation deferred).
- `MLModel`-based encoder wrapper (`ArticleEncoder.swift`) with
  auto-detection of token-level vs sentence-level output, attention-masked
  mean pooling, L2 normalization, `MLModelConfiguration.computeUnits = .all`.
- CLI `openmdict articleembed --model PATH --vocab PATH "text"` with three
  modes: single encode, `--pair` cosine, `--sanity` known-good suite.
- `sentence-transformers/all-MiniLM-L6-v2` converted to Core ML with
  `coremltools` (`scripts/model/build-minilm-coreml.py` inside the pinned
  Linux container from `scripts/model/build-minilm.Dockerfile`, which
  avoids the Colab / Intel-PyTorch-wheel dependency churn). 85.8 MB
  `.mlpackage` at FP32.
- `--sanity` 8/8 pass: cat/dog 0.66, cat/kitten 0.79, king/queen 0.68,
  happiness/joy 0.59, cat/calculus 0.21, dog/mathematics 0.26, compound
  text 0.76.

Gotchas discovered along the way (so nobody re-steps in them):

- `tokenizer.save_vocabulary` silently no-ops for `BertTokenizerFast` in
  newer `transformers` — pull `vocab.txt` directly via `hf_hub_download`.
- `attn_implementation="eager"` is required; the SDPA path generates
  `new_ones` ops `coremltools` cannot convert.
- `compute_precision=FLOAT16` produces all-NaN output because BERT's
  attention-mask sentinel `torch.finfo(float32).min` (−3.4e38) casts to −inf
  in FP16, and `(1 − mask) × −inf = 0 × −inf = NaN` poisons the softmax.
- A local `import shutil` inside a function shadows the module-level import
  for the whole function scope.

### Phase 3.0.5 — iOS device POC (three-device matrix)

500-article stride sample of the bundled WordNet-EN.mdx (153,888 entries),
FP32 `.mlpackage`, `computeUnits = .all`.

| Device | SoC | OS | RAM | Throughput | p50 | Memory peak | Projected WordNet |
|---|---|---|---:|---:|---:|---:|---:|
| iPad (6th gen) | A10 Fusion | iPadOS 17.7 | 2 GB | **10.75 ips** | 92 ms | 274 MB | ~4 h |
| iPad Air (3rd gen) | A12 Bionic | iPadOS 18.6 | 3 GB | **33.88 ips** | 24 ms | 341 MB | ~75 min |
| iPhone 11 | A13 Bionic | iOS 26.4 | 4 GB | **35.01 ips** | 24 ms | 258 MB | ~73 min |

`MLComputePlan` op routing (359 ops total):

| Device | ANE | GPU | CPU | "?" (layout-only ops) |
|---|---:|---:|---:|---:|
| iPad (6th gen) | 0 (no hardware) | 0 | 42.6% (153 ops) | 57.4% (206) |
| iPad Air (3rd gen) | **0 (FP32 blocks ANE)** | **42.6% (153 ops)** | 0 | 57.4% (206) |
| iPhone 11 | **0 (FP32 blocks ANE)** | **42.6% (153 ops)** | 0 | 57.4% (206) |

**A12 ≈ A13 on this workload** (33.88 vs 35.01 ips, within noise), contrary
to the "generation bump = 50% faster" intuition:

1. A12 and A13 share the same 4-core GPU architecture; A14 is the next
   generation (5-core, redesigned).
2. Batch-1 transformer inference is memory-bandwidth and dispatch bound, not
   peak-FLOPS bound; A12 and A13 share ~33 GB/s LPDDR4X.
3. Core ML's single-query API offers no batching window for a multi-core
   GPU to amortize over.

So the FP32-on-GPU ceiling is **~35 ips across A12–A13**. The only path
above it on that range is engaging the Neural Engine via FP16 weights.

The ANE compiler (`MLE5Engine`) refuses the FP32 model on A12 with:

```
MLE5Engine does not support profiling options on the current device.
Invalid layer: Invalid input tensor channel 1 and format size 2 bytes,
must be aligned on 64 bytes
```

The error refers to BERT's masking constant — the same
`torch.finfo(float32).min` that caused the FP16 NaN in Phase 3.0. An FP16
retry with a `-1e4` mask constant is the path to the ANE.

Other observations: the A10 iPad hits 10 ips on pure CPU (the 6-layer model
maps well to vDSP-accelerated CPU); memory peaks of 258–341 MB are all above
the 150 MB background budget assumed pre-POC; thermal state stayed
`nominal` on all three devices.

### Phase 3.0.6 — Model and ANE survey

Two parallel attacks on the "FP32 blocks ANE" finding:

**Attack 1 — ANE-friendly architecture.** Apple's
`ane-distilbert-base-uncased-finetuned-sst-2-english` backbone with the BC1S
layout from `ml-ane-transformers`:

- A12: ANE 2.8%, 10.43 ips (vs MiniLM's 35.5 ips on GPU) — slower.
- A13: ANE 4.6%, 16.5 ips (vs MiniLM's 41) — same conclusion.
- M2 iPad Pro: ANE 44.1%, 118.75 ips (vs MiniLM's 554) — 3× slower because
  DistilBERT-base is 3× larger than MiniLM.
- A10: pure CPU, 2.63 ips (vs MiniLM's 4.95) — 2× slower.

Conclusion: `ml-ane-transformers` is honest about its "A14+/M1+" claim. On
A12/A13 the alignment workaround unlocks only a sliver of ANE ops and the
3× model-size penalty drowns the win.

**Attack 2 — newer small models.** `bge-small-en-v1.5`, `gte-small`,
`e5-small-v2`, `all-MiniLM-L12-v2` (all 33M params / 12 layers / 384 dim /
63 MB) converted and benchmarked on a Mac:

| Model | Mac ips | p50 | Discriminative ratio* |
|---|---:|---:|---:|
| **all-MiniLM-L6-v2** (chosen) | **120** | **8.3 ms** | **3.1×** |
| all-MiniLM-L12-v2 | 71 | 14.0 ms | 3.0× |
| bge-small-en-v1.5 | 71 | 14.0 ms | 1.7× |
| gte-small | 71 | 14.0 ms | **1.13×** |
| e5-small-v2 | 71 | 14.0 ms | **1.14×** |

\* avg cosine of related pairs ÷ avg cosine of unrelated pairs; higher means
clearer top-K separation.

The newer models cluster all scores in `[0.7, 0.95]` even for unrelated
pairs; their MTEB ranks come from long-passage retrieval, and 1–10-word
dictionary queries hit them out of distribution.

**Caveat**: the quality comparison used 8 hand-picked word pairs and is
statistically meaningless. A proper evaluation needs ~500+ query/article
pairs with relevance labels and MAP/MRR/nDCG. Re-run the survey with that
framework if MiniLM-L6 quality issues surface.

**Decision: `sentence-transformers/all-MiniLM-L6-v2`** — faster (1.7×),
smaller (1.5×), better top-K separation on short queries, proven end-to-end
on five devices. The generalized converter
`scripts/model/build-st-coreml.py` stays parameterized for future swaps.

### Phase 3.1 — Per-language model catalog (future direction)

Architecture decision: **one model per language**, one model in memory at a
time, per-language ODR delivery. A multilingual model exists only as a
`key="multi"` fallback for languages without a good per-language model; the
caller still asks "embed in language X" and the dispatch layer hides the
fallback.

```swift
struct ArticleEmbedderModelSpec {
    let language: NLLanguage   // or "multi" sentinel for fallback
    let hfRepo: String          // for reference / future re-convert
    let mlmodelHash: String     // for sidecar invalidation
    let expectedDim: Int        // 384 for MiniLM, 512 for some others
    let odrTag: String          // per-language ODR asset tag
    let vocabAsset: String      // tokenizer vocab.txt bundle name
    let displayName: String     // user-facing in download prompt
    let approximateSize: Int    // bytes, for download confirmation
}
```

Only the English model (`all-MiniLM-L6-v2`, 85 MB FP32) has been converted;
candidate models for zh / ja / ko / de / es / fr / it / pt / ru were
surveyed but not shipped.

### Phase 3.2 — Registry and dispatcher

Single-model-at-a-time dispatch layer:

```swift
@MainActor
final class ArticleEmbedderRegistry {
    static let shared = ArticleEmbedderRegistry()

    private var currentLang: NLLanguage?
    private var current: ArticleEmbedder?        // the one model in RAM
    private var queue: PriorityQueue<EmbedJob>   // high (interactive) + low (batch)

    func enqueue(_ job: EmbedJob, priority: Priority)
    func runBatches() async  // dispatcher loop
    func unload() async
}
```

Dispatcher policy:

1. Drain the `high` queue first regardless of language (load/unload per
   query is wasteful, but interactive latency wins).
2. For the `low` queue: group by language, pick the heaviest bucket (best
   amortization of load cost), drain it, unload, pick the next.
3. Between batches: check `thermalState`, memory footprint and the
   remaining time budget (background mode).

### Phase 3.3 — `ArticleIndexCoordinator` (persistence, lifecycle, availability gate)

**Single point of availability enforcement.** Every entry point that could
trigger Phase 3 work (scope toggle, import hook, scope-switch double-check,
settings page) goes through Coordinator APIs that return
`Result<T, ArticleIndexUnavailableReason>`. The Coordinator performs the
OS-version, hardware and language checks; callers switch on `.success` /
`.failure` and render either the normal UI or a `ContentUnavailableView`
with the reason's localized strings. This keeps `if #available(iOS 26, *)`
out of every call site.

```swift
enum ArticleIndexUnavailableReason: Sendable, Equatable {
    /// iOS version too old. iOS 26 is the floor because A13 is the
    /// oldest chip eligible for iOS 26 — gating by OS version
    /// transitively gates by hardware capability.
    case osVersionTooOld(current: String, minimum: String)
    /// Detected dict language has no embedding model in the catalog.
    case languageNotSupported(NLLanguage)
    /// Model exists in the catalog but is not downloaded yet (ODR pending).
    case modelNotDownloaded(language: NLLanguage, sizeBytes: Int)
    /// Sidecar is stale or corrupt and the rebuild has not finished.
    case indexingInProgress(progress: Double)
    /// User explicitly excluded this dict from indexing.
    case userExcluded

    var localizedTitle: String { ... }
    var localizedMessage: String { ... }
    var sfSymbol: String { ... }
}

@MainActor
final class ArticleIndexCoordinator {
    static let shared = ArticleIndexCoordinator()

    /// Cheap top-level availability — does the device + OS allow Phase 3 at all.
    var availability: Result<Void, ArticleIndexUnavailableReason> { ... }

    /// Per-dict status: OS check + language check + sidecar presence + user exclusion.
    func state(for dictId: String) -> Result<ArticleIndexState, ArticleIndexUnavailableReason>

    /// User-initiated; fails if any precondition (OS, language, model download) is unmet.
    func userRequestedIndex(_ dictId: String) -> Result<Void, ArticleIndexUnavailableReason>

    /// Query side: `.success(nil)` when the dict is not indexed (skip silently in the
    /// streaming scan); `.failure` only when the feature itself is unavailable.
    func openReader(dictId: String) -> Result<ArticleIndexReader?, ArticleIndexUnavailableReason>

    // Lifecycle hooks are intentionally no-throw / no-Result — notifications
    // the Coordinator may ignore when the feature is unavailable.
    func handleDictImported(_ dictId: String)   // no-op on iOS < 26
    func handleDictDeleted(_ dictId: String)    // ALWAYS runs (cleanup)
}
```

UI consumption mirrors the existing `ContentUnavailableView` pattern:

```swift
switch ArticleIndexCoordinator.shared.availability {
case .success:
    // set up FullTextLookupSession, etc.
case .failure(let reason):
    showContentUnavailable(title: reason.localizedTitle,
                           message: reason.localizedMessage,
                           symbol: reason.sfSymbol)
}
```

#### Why iOS 26 as the floor (not iOS 17/18)

- A13 is the oldest chip eligible for iOS 26. Gating on
  `#available(iOS 26, *)` transitively excludes A10/A11/A12 — the tier the
  POC measured as CPU-only (A10) or stuck at the GPU-saturation ceiling
  (A12/A13). Devices on iOS 26 are A13+ and clear the ~35 ips bar.
- A14+ devices get a meaningful uplift from Core ML improvements in iOS 26
  (better ANE routing heuristics for transformer workloads).
- A single OS-version check instead of a per-chip lookup table is simpler to
  maintain.

#### Persistent state

Per-dict state is a Core Data entity alongside the existing sync schema:

```
entity ArticleIndexRecord
    dictId: String            (primary key, same as DictionaryMetadataRecord)
    stateRaw: String          (notIndexed / indexing / indexed / …)
    indexedThrough: Int32     (checkpoint for resumable indexing)
    modelHash: String         (sidecar invalidation)
    mdxHash: String           (same)
    lastUpdated: Date
    userPriorityOrder: Int32  (drag-to-reorder)
    errorMessage: String?
    syncable: NO              (sidecars rebuild locally; only user prefs sync)
```

Only user preferences (`userPriorityOrder`, the exclusion flag, pause
state) would sync through CloudKit; indexing state is per device because
each device indexes independently.

#### Three-priority work queue

1. **Interactive** — user typed in the Article scope and the dict is not yet
   indexed → high-priority foreground batch with progress UI.
2. **Background** — `BGProcessingTask` fires, drain the low-priority queue.
3. **Backfill** — app launch finds dicts in `.notIndexed`, queues them as
   low priority for the next background slot.

```swift
enum ArticleIndexState {
    case notSupported
    case pendingDownload(MB: Int)
    case notIndexed
    case indexing(progress: Double) // 0...1
    case paused                     // user-paused or thermal/battery
    case indexed
    case error(String)
}
```

### Phase 3.4 — `BGProcessingTask` integration

- `BGProcessingTaskRequest(identifier: "openmdict.body-indexing")`
- `requiresExternalPower = true` (the Photos precedent),
  `requiresNetworkConnectivity = false`
- Per-task work budget: **2 minutes hard cap**, checkpoint at 80 s
- Always re-`schedule()` at the end of a task if work remains
- `thermalState >= .serious` → checkpoint + bail + reschedule
- Memory footprint > 180 MB → checkpoint + bail + reschedule

Edge case: if the task has not fired in more than 7 days **and** unindexed
work exceeds a threshold (e.g. 10k articles), the Article-scope empty state
shows a soft banner — *"Indexing progress is slow. Keep the app open for a
few minutes to speed things up."* — in the tone Apple Photos uses.

Decisions deliberately left for dogfood data: `requiresExternalPower`
default, the banner trigger condition, and the FP16 model retry.

### Phase 3.6 / 3.7 — Query path and UX surface

- `ArticleIndexReader` — mmap'd sidecar, `vDSP_dotpr` cosine scan.
- `FullTextLookupSession : LookupSessionProtocol`; the word list gains the
  third scope segment.
- Result merging with headword *Semantic* results: combine, dedup by
  `(dictId, articleKey)`, rank by the maximum similarity from either source.
- Per-dict state machine surfaced in the Article scope's empty state when
  not indexed yet.
- Overview page (reusing the preset-downloader list pattern): sections by
  language (mirrors the model boundary); per row a progress bar,
  pause/resume swipe and drag-to-reorder priority; global toggles for Wi-Fi
  only, charger required, cellular model download.
- 13-language L10n (one new section in the string catalog).

### Phase 3.5 — On-Demand Resources for model + vocab

Goal: keep the ~80 MB compiled model out of the base IPA so users on iOS
versions where the feature is gated off never pay the size cost. Only iOS
26+ users who enable Article search trigger the download.

**Xcode gotchas** (preserved so the next ODR-tagged binary asset does not
re-step in them):

1. **`.mlpackage` is a "source file", not a resource.** Xcode auto-compiles
   `.mlpackage → .mlmodelc` via `coremlcompiler` during the Sources build
   phase. Resources (and thus ODR `ASSET_TAGS`) only apply to pre-compiled
   assets; selecting a `.mlpackage` in the File Inspector shows *"Only
   resources are taggable"*.
2. **`.mlmodelc` is a directory bundle.** Pre-compiling with
   `xcrun coremlcompiler compile foo.mlpackage .` produces `foo.mlmodelc/`
   (`model.mil` + weights + coremldata). Xcode's *Add Files* dialog treats
   directory bundles as already-opened packages — the `.mlmodelc` itself
   cannot be selected, only the files inside; drag-and-drop from Finder is
   blocked too.
3. **`fileSystemSynchronizedGroups` does not help.** The top-level app group
   uses Xcode 16's auto-sync, but `Article Embeddings/` is a plain
   `PBXGroup` (intentional — the `.mlpackage` source needs an explicit
   `path`), so a `.mlmodelc` dropped on disk does not appear in the project.

**Solution — patch the pbxproj directly.** Four changes:

```
1) New PBXFileReference (sibling of the existing .mlpackage ref):
   XXXX /* all-MiniLM-L6-v2.mlmodelc */ = {
       isa = PBXFileReference;
       lastKnownFileType = wrapper.coreml-model-compiled;
       path = "all-MiniLM-L6-v2.mlmodelc";
       sourceTree = "<group>";
   };

2) Add it to the Article Embeddings PBXGroup's children.

3) New PBXBuildFile in Resources (carries the ODR tag):
   YYYY /* all-MiniLM-L6-v2.mlmodelc in Resources */ = {
       isa = PBXBuildFile;
       fileRef = XXXX;
       settings = { ASSET_TAGS = ("article-embed-model", ); };
   };
   Add it to the app target's PBXResourcesBuildPhase `files`.

4) Remove the `.mlpackage in Sources` PBXBuildFile so Xcode stops
   auto-compiling; the pre-compiled .mlmodelc ships directly. Tag vocab.txt
   with the same ASSET_TAGS so both files move together.
```

This is the same `ASSET_TAGS = ("preset-dict-…")` mechanism the preset
dictionaries use. **Maintenance**: whenever the model changes, re-run
`scripts/precompile-article-embed-model.sh`; it regenerates the
`.mlmodelc` via `xcrun coremlcompiler compile`, and Xcode picks up the new
contents because the project references the directory by path. (The
bootstrap script does this automatically after downloading a new model —
see `MAINTAINING.md`.)

**Code-side architecture** —
`Services/ArticleEmbed/ArticleIndexAssetProvider.swift`:

- Singleton wrapping `NSBundleResourceRequest(tags: ["article-embed-model"])`.
- `acquire(progress:) async throws -> Assets` — fast path returns
  immediately when resources are local; slow path triggers the ~80 MB
  download. The progress callback is `@Sendable` (called from the
  `NSProgress` KVO queue; callers hop to the main actor).
- `release()` drops the held request so the OS may purge under storage
  pressure; called by `ArticleIndexDispatcher.evictEncoder` to pair the
  lifecycle with the encoder.
- `resourcesAvailableLocally() async -> Bool` — cheap probe
  (`conditionallyBeginAccessingResources`) for UI hints.

**Dispatcher integration**:

- `executeJob` awaits the asset acquire **before** loading the encoder.
- New `.downloadingModel` case in `PauseReason` plus a `@Published
  downloadProgress: Double?`.
- Post-acquire re-checks (user pause, section toggle, gate triggered,
  master toggle) — the download window is long enough for state to change
  mid-flight, and any of the four causes a clean bail.
- The overview VC renders "Downloading language model (38%)…" on the row
  being acquired.

**App extensions**: the Action and Share extensions exclude
`Article Embeddings/` in their `membershipExceptions` and do not import the
encoder, so an ODR-only (extension-inaccessible) model is safe.

---

## Appendix — Phase 2 design history

### The problem

Phase 1 dogfooding surfaced a serious memory problem. With a 13-dictionary
group (~338k headwords vectorized in aggregate) `SemanticSearchService.cache`
grew to roughly 845 MB of resident memory after the first preload; the app
ballooned from a ~300 MB baseline to **1.1 GB+, with occasional jetsam kills
on memory-pressured devices**.

Per-entry cost of the cache:

```swift
struct VectorEntry: Sendable {
    let key: String        // ~10–30 B (UTF-8 + String overhead)
    let keyLower: String   // ~10–30 B
    let vec: [Double]      // 300 × 8 = 2400 B  ← dominates
}
```

≈ 2.5 KB per entry, all dirty memory counted against the jetsam budget;
338k entries ≈ 845 MB. The three largest dictionaries in that group alone
accounted for ~130 MB each.

The cache was dense: `NLEmbedding`'s English vocabulary is only ~57k words,
yet every English-leaning dictionary re-stored the same word's vector in
its own `DictVectors` — at least 5–6× duplication in the worst case.

### Option A — folded per-language cache

One `(word, vector)` per language, keyed by the lowercased word; per
dictionary only a `Set<String>` of contributed words.

```
SemanticSearchService
├── perLanguage: [NLLanguage: LanguageVectors]
│   LanguageVectors
│   ├── vectors: [(word: String, vec: [Float])]   ← unified pool, max ~57k EN
│   └── wordIndex: [String: Int]
└── perDict: [dictId: DictKeywordSet]
    DictKeywordSet
    ├── language: NLLanguage
    └── words: Set<String>
```

English worst case: 57k × 1.2 KB (Float instead of Double) ≈ 70 MB, plus
~0.8 MB per dictionary — roughly **845 MB → ~110 MB** for a mixed
English + Chinese group. Medium implementation cost.

### Option B — sidecar v2 persistence

Persist each dictionary's vectors to a binary sidecar and mmap it. Resident
size shrinks under pressure, but a brute-force cosine sweep touches every
page, so the working set is back to ~845 MB during a query. High
implementation cost (format, atomic writes, versioning, invalidation) for a
fix at the wrong layer: the problem was duplication, not disk-vs-RAM.

### Option C — no cache; `NLEmbedding.neighbors` at query time

`NLEmbedding` already holds the vocabulary and vectors. At query time:

1. `embedding.neighbors(for: query, maximumCount: 500)` →
   `[(word, distance)]`
2. Filter to words present as keys in at least one active dictionary
3. Apply the existing lemma dedup
4. Take the top `tier.k`

Zero app-owned vector storage; much less code; no preload phase. Risks:
unmeasured `neighbors` latency (hence the perf probe), and rare words
outside the top 500 (mitigation: raise `maximumCount`).

### Plan that was executed

1. Perf probe (`openmdict neighbors-bench`) on the 600-query
   CEFR-stratified bench list; decision gate p95 < 200 ms → Option C.
2. Option C implementation: new `relatedKeywords` body, delete the cache and
   preload path, re-run the bench and confirm quality matches Phase 1.
3. Option A kept as the fallback (not needed).
4. Memory regression check against the same 13-dictionary group; target
   < 400 MB total footprint.
5. Sidecar persistence deferred to Phase 3, where it serves body-text
   vectors rather than headwords.
