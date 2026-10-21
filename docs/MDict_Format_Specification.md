# MDict (MDX / MDD) Format Notes

Reference notes on the MDict container format as implemented by
`Sources/OpenMDict`. They are distilled from the community reference
implementations (readmdict / writemdict, mdict-utils, mdict-analysis) and
from inspecting real dictionaries; MDict has no official public
specification. Where this document and the parser in
`Sources/OpenMDict/Parsers/` disagree, the parser is authoritative.

---

## 1. File types

| File | Extension | Purpose | Count |
|------|-----------|---------|-------|
| **MDX** | `.mdx` | Headword index + article HTML | 1 |
| **MDD** | `.mdd` | Resources (images, audio, CSS, JS, fonts) | 0–N |
| **CSS** | `.css` | External stylesheet override (optional) | 0–N |
| **JS** | `.js` | External script (optional) | 0–N |

### MDD naming convention

```
baseName.mdd       # primary resource file (or baseName.0.mdd)
baseName.1.mdd     # additional resources (often audio)
baseName.2.mdd     # more resources
...
```

---

## 2. MDX structure

### 2.1 Format versions

| Version | Builder | Compression | Encryption | Marker |
|---------|---------|-------------|------------|--------|
| **V1** | MdxBuilder 2.x | LZO1X | "fast" XOR | `GeneratedByEngineVersion < 2.0` |
| **V2** | MdxBuilder 3.x | zlib | "fast" XOR | `GeneratedByEngineVersion >= 2.0` |
| **V3** | MdxBuilder 4.x | zlib | Salsa20 | `GeneratedByEngineVersion >= 3.0`, has `UUID` |

OpenMDict reads V1 and V2. V3 files (MdxBuilder 4.x, Salsa20) are not
supported, and files with record-block encryption (`Encrypted` bit 1) are
rejected at open time. The preset dictionaries shipped with the app are V2
files written by mdict-utils.

### 2.2 Section layout

```
┌─────────────────────────────────────┐
│ Header                              │ ← XML metadata (section 2.3)
├─────────────────────────────────────┤
│ Key block info                      │ ← index of the key blocks
├─────────────────────────────────────┤
│ Key blocks                          │ ← compressed headword lists
├─────────────────────────────────────┤
│ Record block info                   │ ← index of the record blocks
├─────────────────────────────────────┤
│ Record blocks                       │ ← compressed article HTML
└─────────────────────────────────────┘
```

### 2.3 Header

The header is an XML element (`<Dictionary .../>` for MDX,
`<Library_Data .../>` for MDD):

```xml
<Dictionary
    GeneratedByEngineVersion="2.0"
    RequiredEngineVersion="2.0"
    Format="Html"
    KeyCaseSensitive="No"
    StripKey="Yes"
    Encrypted="0"
    Encoding="UTF-8"
    CreationDate="2026-02-21"
    Title="Example Dictionary"
    Description="..."
    StyleSheet="..."
/>
```

| Attribute | Meaning | Example |
|-----------|---------|---------|
| `GeneratedByEngineVersion` | Format version | `1.2`, `2.0`, `3.0` |
| `Title` | Dictionary title | `Example Dictionary` |
| `Description` | Dictionary description (HTML, may be long) | |
| `Encoding` | Text encoding of keys and records | `UTF-8`, `UTF-16`, `GBK` |
| `Encrypted` | Encryption flags: `0` none, `1` record blocks, `2` key info, `3` both (`Yes` = `1`) | `0` |
| `KeyCaseSensitive` | Whether lookups compare case | `No` |
| `StripKey` | Whether punctuation/whitespace is ignored when comparing keys | `Yes` |
| `CreationDate` | Free-form date string; mdict-utils writes it unpadded (`2026-2-21`), the preset pipeline pins ISO `YYYY-MM-DD` | |
| **`StyleSheet`** | **Embedded "compact HTML" style table** (section 3.2) | |
| `UUID` | V3 only; key material for Salsa20 | 36-char UUID |

#### Binary layout of the header

```
offset  size      field
0       4         N = length of the header text, uint32 big-endian
4       N         header text: UTF-16LE XML, usually terminated by
                  "\r\n" and a NUL character (encoded as 00 00);
                  some builders emit a UTF-16LE BOM (FF FE) first
4+N     4         adler32 of the N header bytes, uint32 LITTLE-endian
8+N     ...       key block info (section 2.4)
```

Nothing after the header stores an absolute file offset, so the header may
be rewritten with a different length as long as `N` and the adler32 are
updated (this is how `preset-dicts/scripts/shared/build.py` pins
`CreationDate`). The iOS app's dictionary id is the SHA-256 of the whole
`.mdx` file (`PresetDictionaryService.fileSHA256`), so any byte change,
including a header change, produces a new id. The SHA-256 of the raw header
bytes keys the sidecar index cache (validated together with file size and
mtime).

### 2.4 Key block info (V2)

Immediately after the header checksum:

```
uint64 BE   number of key blocks
uint64 BE   number of entries (headwords, including @@@LINK redirects)
uint64 BE   decompressed size of the key block info
uint64 BE   compressed size of the key block info
uint64 BE   total size of all key blocks
uint32 BE   adler32 of the preceding 40 bytes
```

Then the key block info itself, framed like every compressed block
(section 2.6). When `Encrypted & 2`, the compressed key block info is
additionally obfuscated with the "fast" XOR scheme whose key is
`ripemd128(adler32_bytes + 0x95 0x36 0x00 0x00)`. Decompressed, it lists
for each key block:

```
uint64 BE   number of entries in the block
uint16 BE   length of the first headword (in code units)   + headword + terminator
uint16 BE   length of the last headword                    + headword + terminator
uint64 BE   compressed size of the block
uint64 BE   decompressed size of the block
```

(V1 differs throughout: the leading fields are four `uint32` values — block
count, entry count, compressed key-block-info size, total key-block size —
with no decompressed-size field and no checksum; the key block info itself
is stored uncompressed, with 8-bit headword lengths and no terminators.)
The first/last headwords allow a binary search over blocks without
decompressing them.

### 2.5 Key blocks

Each key block decompresses to a sequence of

```
uint64 BE   record offset (byte offset into the concatenated, decompressed record data)
            headword text in the header Encoding, NUL-terminated
```

(V1: uint32 offsets.) Headwords are sorted by the builder; comparisons are
case-insensitive unless `KeyCaseSensitive="Yes"` and ignore punctuation when
`StripKey="Yes"`.

### 2.6 Compressed block framing

Every key block, record block and the key block info share one frame:

```
4 bytes     compression type: 00 00 00 00 = none, 01 00 00 00 = LZO1X,
            02 00 00 00 = zlib
uint32 BE   adler32 of the DECOMPRESSED data
...         payload
```

### 2.7 Record block info and record blocks

```
uint64 BE   number of record blocks
uint64 BE   number of entries
uint64 BE   size of the record block info that follows
uint64 BE   total size of all record blocks
for each record block:
    uint64 BE   compressed size
    uint64 BE   decompressed size
```

Record blocks follow, framed as in 2.6. An entry's article is the bytes at
its record offset, up to the next entry's offset (articles are typically
NUL-terminated HTML in the header Encoding).

---

## 3. CSS / styling sources

### 3.1 Three sources, lowest to highest priority

```
1. MDX header StyleSheet      ← embedded compact-HTML style table
        ↓
2. CSS files inside the MDD   ← e.g. \style.css
        ↓
3. External CSS next to MDX   ← e.g. MyDict.css (highest priority)
```

### 3.2 Source 1: header `StyleSheet` (compact HTML)

The `StyleSheet` attribute holds a table of style definitions, three lines
per entry:

```
style number
opening tag(s)
closing tag(s)
```

Example:

```
1
<span class="headword">
</span>
2
<span class="pronunciation">
</span>
3
<div class="definition">
</div>
```

Articles reference the table with backtick-number markers:

```html
`1`hello`2`/həˈləʊ/`3`a word said to greet someone
```

which expand to:

```html
<span class="headword">hello</span>
<span class="pronunciation">/həˈləʊ/</span>
<div class="definition">a word said to greet someone</div>
```

Reference implementation (mdict-utils `chtml.py`), paraphrased:

```python
class CompactHTML:
    def __init__(self, stylesheet):
        # three lines per entry: index, prefix, suffix
        css = {}
        for count, line in enumerate(stylesheet.split(b'\r\n')):
            if count % 3 == 0:   index = line
            elif count % 3 == 1: prefix = line
            else:                css[index] = (prefix, line)
        self._css = css

    def to_html(self, chtml):
        # replace each `N` with prefix + content + suffix
        re_index = re.compile(b'`(\\d+)`')
        ...
```

### 3.3 Source 2: CSS inside the MDD

An MDD is a key-value store; CSS files are ordinary entries:

| Key | Value |
|-----|-------|
| `\style.css` | CSS bytes |
| `\css\custom.css` | another CSS file |

```python
for key, value in mdd.items():
    if key.lower().endswith('.css'):
        ...
```

Keys use backslashes as separators and are matched case-insensitively.

### 3.4 Source 3: external CSS next to the MDX

A stand-alone CSS file in the same directory **overrides** everything else:

```
MyDict/
├── MyDict.mdx
├── MyDict.mdd
└── MyDict.css    ← external CSS, overrides styles inside the MDD
```

This priority order ("external CSS beats CSS inside mdx/mdd") is the
community convention and what dictionary authors rely on.

---

## 4. MDD resource files

### 4.1 Format

An MDD uses exactly the same binary format as an MDX, but

- keys are resource paths (e.g. `\pic\logo.jpg`)
- values are raw file bytes

### 4.2 Resource paths

```
\                           ← root
\style.css                  ← CSS at the root
\pic\accordion.jpg          ← image directory
\sound\hello.mp3            ← audio directory
\font\custom.ttf            ← font directory
```

- Separator is `\` (Windows style).
- Matching is **case-insensitive**.

### 4.3 Resource types

| Type | Extensions | Use |
|------|------------|-----|
| Images | `.jpg`, `.png`, `.gif`, `.svg` | Illustrations |
| Audio | `.mp3`, `.wav`, `.ogg`, `.spx` | Pronunciations |
| Styles | `.css` | Article styling |
| Scripts | `.js` | Interactive articles |
| Fonts | `.ttf`, `.otf`, `.woff` | Custom typefaces |

---

## 5. Resource references inside articles

### 5.1 Reference forms

```html
<!-- image -->
<img src="/pic/logo.jpg">
<img src="file://pic/logo.jpg">

<!-- audio -->
<a href="sound://hello.mp3">🔊</a>

<!-- CSS (link or inline) -->
<link rel="stylesheet" href="/style.css">

<!-- jump to another entry -->
<a href="entry://another_word">See also</a>
```

### 5.2 Common schemes

| Scheme | Purpose | Example |
|--------|---------|---------|
| `sound://` | Play audio | `sound://us/hello.mp3` |
| `entry://` | Jump to another entry (may carry a `#fragment`) | `entry://world` |
| `@@@LINK=` | Entry redirect (article body, not a URL) | `@@@LINK=main_entry` |

---

## 6. Special entry types

### 6.1 Redirects

An article whose body starts with `@@@LINK=` is a redirect:

```
Key:   colour
Value: @@@LINK=color
```

Looking up "colour" should display the article for "color". Redirect
chains exist in the wild; readers should cap the depth.

### 6.2 HTML entries

Ordinary articles are HTML fragments:

```html
<div class="entry">
    <span class="headword">hello</span>
    <span class="pos">interjection</span>
    <div class="sense">
        a word said to greet someone...
    </div>
</div>
```

---

## 7. Implementation notes (OpenMDict)

### 7.1 CSS loading order

```swift
func loadStyles(for dict: MDict) -> [String] {
    var styles: [String] = []

    // 1. MDX header StyleSheet (expand compact HTML markers)
    if let stylesheet = dict.metadata.stylesheet {
        styles.append(expandCompactHTML(stylesheet))
    }

    // 2. CSS inside the MDD(s)
    for cssPath in dict.resourceProvider.findCSS() {
        if let css = dict.resourceProvider.get(cssPath) {
            styles.append(String(decoding: css, as: UTF8.self))
        }
    }

    // 3. External CSS (highest priority, loaded last)
    for externalCSS in dict.externalCSSFiles {
        styles.append(try! String(contentsOf: externalCSS))
    }

    return styles
}
```

### 7.2 Case-insensitive resource lookup

```swift
func findResource(_ path: String) -> Data? {
    // MDD keys are case-insensitive and backslash-separated
    let normalized = path.lowercased().replacingOccurrences(of: "/", with: "\\")

    for mdd in mddFiles {
        if let data = mdd.get(normalized) {
            return data
        }
    }

    // Fallback: loose file next to the dictionary
    return loadFromExternalFile(path)
}
```

### 7.3 Compact HTML expansion

```swift
func expandCompactHTML(_ text: String, stylesheet: [String: (String, String)]) -> String {
    // Expand `1`content`2`more into <prefix1>content<suffix1><prefix2>more<suffix2>
    let pattern = /`(\d+)`/
    ...
}
```

---

## 8. Appendix

### 8.1 Reference implementations

| Project | Language | Link |
|---------|----------|------|
| mdict-utils | Python | https://github.com/liuyug/mdict-utils |
| writemdict | Python | https://github.com/zhansliu/writemdict |
| mdict-analysis | Python | https://bitbucket.org/xwang/mdict-analysis |
| readmdict.py | Python | original reader, bundled with the projects above |

### 8.2 Key takeaways

1. **CSS priority**: external file > CSS inside MDD > header `StyleSheet`.
2. **Paths**: MDD keys use `\` and are case-insensitive.
3. **Compact HTML**: header `StyleSheet` markers `` `N` `` must be expanded.
4. **Isolation**: a dictionary can only see its own MDD(s) and loose files.
5. **Header**: `uint32 BE length` + UTF-16LE XML + `uint32 LE adler32`; no
   absolute offsets follow, so the header may change length.
