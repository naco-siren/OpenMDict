# Command-line tools

The Swift package builds two executables:

- `openmdict`: reads a dictionary from the command line (information, lookups,
  prefix search, MDD resources) and manages the sidecar cache.
- `openmdict-bench`: benchmarks loading and lookups; see
  [Performance](performance.md#benchmarking-with-openmdict-bench).

Run them through SwiftPM, or build once and call the binary:

```bash
swift run -c release openmdict dict.mdx lookup hello
swift build -c release && .build/release/openmdict dict.mdx lookup hello
```

`openmdict` with no arguments prints the full usage, including the
experimental commands listed below.

## Reading a dictionary

| Command | Output |
|---|---|
| `openmdict <mdx>` | Header information, entry count, MDD resource summary and the first entries |
| `openmdict <mdx> lookup <word>` | The article for `<word>`, with the lookup fallbacks applied |
| `openmdict <mdx> search <prefix>` | Up to 20 keys that start with `<prefix>` (falling back to width- and diacritic-folded matches) |
| `openmdict <mdx> list [count]` | The first `count` keys (default 20) |
| `openmdict <mdx> resources [count]` | The first `count` resource paths (default 20) in the MDD file(s) beside the MDX, and how many more there are |
| `openmdict <mdx> resource <path>` | Size, MIME type and a preview of one resource (text truncated, binary as a hex dump) |
| `openmdict <mdx> header` | The raw header XML |
| `openmdict <mdx> describe` | The header description as the parser extracts it |
| `openmdict <mdx> debug <prefix>` | A hex dump of up to five keys, found as by `search` |

MDD files are found next to the MDX by name (`dict.mdd`, `dict.1.mdd`, ...).

## Output formats

`--format` (or `-f`) changes the output of `lookup`. With `raw` or `json`,
the other `openmdict <mdx>` commands print their usual output without the
`Opening` banner and the dictionary-information block, and `openmdict <mdx>`
with no command prints nothing.

| Format | Output |
|---|---|
| `pretty` (default) | Colored, decorated and truncated, for reading in a terminal |
| `raw` | The article HTML only, untruncated. A missing word prints `Not found: <word>` to stderr and exits with status 1. |
| `json` | One JSON document. A missing word exits with status 0 and `"found": false` plus `"suggestions"`. |

```bash
openmdict dict.mdx lookup hello --format=raw > hello.html
openmdict dict.mdx lookup hello --format=json | jq '.links[]'

# cross-references that point at an anchor inside another entry
openmdict dict.mdx lookup hello --format=json \
  | jq -r '.links[] | select(.type == "entry" and .fragment != null) | .raw'
```

The JSON document has these top-level keys:

| Key | Content |
|---|---|
| `word`, `found`, `lookupTimeMs` | The query, whether it matched, and the lookup time |
| `dict` | `title`, `path`, `entryCount` and `headerSHA256` (the sidecar cache key) |
| `entry` | `html`, `index` and `navigation` (`previous` / `next` keys) |
| `links` | References found in the article, each with `raw` and `type`: `entry` (cross-reference, with `word` and an optional `fragment`), `audio` (`sound://`, with `path`), `localResource` (a path ending in `.css`, `.js`, `.png`, `.jpg`, `.gif`, `.svg`, `.ttf` or `.woff`, with `path`) or `webLink` (any other reference, including site-relative links). Absolute `http(s)` URLs and in-page `#anchors` are not listed. |
| `suggestions` | Spelling suggestions, when the word is not found |

## Sidecar cache

Set `OPENMDICT_SIDECAR_DIR` to let the `openmdict <mdx> ...` commands use
the [sidecar index](performance.md#persistent-sidecar-index), for example to
compare a first and a second open of the same file:

```bash
OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache openmdict dict.mdx lookup hello
```

With the variable set, the process waits about 2 s before exiting so that
the background sidecar write can finish. Compare the `Load Time` line that
`openmdict <mdx>` prints rather than the wall-clock time of the process.
The experimental `articleembed`, `articleindex` and `neighbors-bench`
commands ignore the variable.

The `sidecar` subcommands manage the cache. `info` and `rebuild` read the
directory from `OPENMDICT_SIDECAR_DIR`; `list` takes it as an argument.

```bash
OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache openmdict sidecar info dict.mdx
OPENMDICT_SIDECAR_DIR=/tmp/mdx-cache openmdict sidecar rebuild dict.mdx
openmdict sidecar list /tmp/mdx-cache
```

- `info` shows, for the MDX and the same-name `.mdd` beside it (numbered
  `.1.mdd` files are not listed), the start of the header SHA-256 and whether
  a sidecar file exists, with its size and age. The full SHA-256 is the name
  of the `.idx` file in the `file:` or `expected at:` line. The `valid` line
  reports that a reader opened the dictionary and how long that took; a
  sidecar that fails validation is skipped silently, so a long init time is
  the sign of a slow-path open.
- `rebuild` deletes the MDX's sidecar and writes a new one from a full parse.
- `list` lists every `.idx` file in the directory with its size and age and
  checks its magic bytes (the source files are not consulted).

## Experimental commands

These commands probe the semantic-search features of the iOS app; see
[Semantic search and article embeddings](article-embeddings.md).

| Command | Purpose |
|---|---|
| `openmdict <mdx> semantic <word> [--lang auto] [--limit 10] [--scope all\|dict\|both]` | Nearest words by `NLEmbedding`, across its vocabulary and/or restricted to the dictionary's keys |
| `openmdict neighbors-bench [--words-file FILE] [--lang en] [--max-neighbors N]` | Latency of `NLEmbedding.neighbors()` over a word list |
| `openmdict articleembed --model PATH --vocab PATH "text"` | Encode text with the Core ML sentence-embedding model; `--pair "a" "b"` prints a cosine similarity, `--sanity` runs a known-answer suite, `--bench N` measures throughput |
| `openmdict articleindex build <mdx> --model PATH --vocab PATH --out PATH` | Build an article-embedding index (`.semantic.idx`) for a dictionary |
| `openmdict articleindex info <index> [--mdx PATH --model PATH]` | Show an index header and, with `--mdx` and `--model`, whether it is stale |
| `openmdict articleindex query <index> --model PATH --vocab PATH --mdx PATH <query> [-k N]` | Top-K articles for a query |

The model and vocabulary are downloaded by `scripts/bootstrap-assets.sh` into
`Apps/iOS/OpenMDict-iOS/Article Embeddings/`.
