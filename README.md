# OpenMDict

A pure Swift library for parsing MDict dictionary files (.mdx/.mdd).

## Features

- ✅ **MDX V2 (2.0)** - Full support with zlib decompression
- ✅ **MDX V1 (1.x)** - Full support with LZO decompression (official minilzo 2.10)
- ✅ **MDD Resources** - Images, audio, CSS, and other embedded files
- ✅ **Salted Dictionaries** - RIPEMD128 decryption for obfuscated dictionaries
- ✅ **Cross-platform** - macOS, iOS, iPadOS (Swift Package Manager)

## Requirements

- Swift 5.9+
- macOS 12+ / iOS 15+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/naco-siren/OpenMDict.git", from: "0.1.0")
]
```

## Usage

### Basic Lookup

```swift
import OpenMDict

// Load dictionary
let dict = try MDictReader(path: "dictionary.mdx")

// Lookup a word
if let entry = dict.lookup("hello") {
    print(entry.article.html)
}

// Search by prefix
let words = dict.search(prefix: "hel", limit: 10)

// Access by index
if let first = dict[0] {
    print("\(first.key): \(first.article.html)")
}
```

### Dictionary Metadata

```swift
let dict = try MDictReader(path: "dictionary.mdx")

print("Title: \(dict.metadata.title)")
print("Entries: \(dict.entryCount)")
print("Format: \(dict.metadata.format)")
print("Encoding: \(dict.metadata.encoding)")
```

### Resource Files (MDD)

```swift
// Resources are loaded automatically if .mdd file exists alongside .mdx
let dict = try MDictReader(path: "dictionary.mdx")

// Get CSS
if let css = dict.resourceString(for: "style.css") {
    print(css)
}

// Get image data
if let imageData = dict.resource(for: "logo.png") {
    // Use image data
}

// Check if resource exists
if dict.hasResource("sound.mp3") {
    // ...
}
```

### Static Metadata (Fast)

```swift
// Load only header info without parsing full dictionary
if let metadata = MDictReader.loadMetadata(from: "dictionary.mdx") {
    print("Title: \(metadata.title)")
    print("Entries: \(metadata.entryCount)")
}
```

## CLI Tool

```bash
# Build
swift build -c release

# Dictionary info
swift run openmdict dict.mdx info

# Lookup word
swift run openmdict dict.mdx lookup hello

# Search by prefix
swift run openmdict dict.mdx search hel

# List entries
swift run openmdict dict.mdx list --limit 20
```

## Testing

```bash
# Run tests with a dictionary file
MDICT_TEST_FILE=path/to/dict.mdx swift test

# With specific test word
MDICT_TEST_FILE=path/to/dict.mdx MDICT_TEST_WORD=hello swift test

# With custom sample size
MDICT_TEST_FILE=path/to/dict.mdx MDICT_TEST_SAMPLE=10 swift test
```

## Project Structure

```
OpenMDict/
├── Sources/
│   ├── OpenMDict/          # Core library
│   │   ├── MDictReader.swift
│   │   ├── Parsers/
│   │   └── Utils/
│   └── CLZ/                # LZO C library (minilzo 2.10)
├── Apps/
│   ├── CLI/                # Command-line tool
│   ├── iOS/                # iOS/iPadOS app (planned)
│   └── Shared/             # Shared ViewModels
├── Tests/
└── Package.swift
```

## Format Support

| Format | Compression | Status |
|--------|-------------|--------|
| MDX V2 (2.0) | zlib | ✅ Full support |
| MDX V1 (1.x) | LZO | ✅ Full support |
| MDX V1 (1.x) | zlib | ✅ Supported |
| MDD V2 | zlib | ✅ Full support |
| MDD V1 | LZO/zlib | ✅ Supported |
| Salted (obfuscated) | - | ✅ Supported |

## License

MIT License

## Acknowledgments

- [minilzo](http://www.oberhumer.com/opensource/lzo/) - LZO compression library by Markus F.X.J. Oberhumer
- [readmdict](https://github.com/zhansliu/writemdict) - Python MDict reference implementation
