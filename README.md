# OpenMDict

A Swift library for reading MDict dictionary files (.mdx/.mdd).

## Features

- ✅ MDX v2.0 format support
- ✅ Encrypted=2 (keyword index encryption) auto-decryption
- ✅ zlib and LZO decompression
- ✅ O(1) keyword lookup via HashMap
- ✅ Prefix search for autocomplete
- ✅ Entry navigation (prev/next)
- ✅ Cross-platform: macOS, iOS, iPadOS

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/user/OpenMDict.git", from: "1.0.0")
]
```

## Usage

```swift
import OpenMDict

// Load dictionary
let dict = try MDictReader(path: "MyDict.mdx")

// Get info
print("Title: \(dict.info.title)")
print("Entries: \(dict.info.entryCount)")

// Query a word
if let entry = dict.query("hello") {
    print("Definition: \(entry.definition)")
    
    // Navigate to adjacent entries
    if let prev = entry.prev {
        print("Previous: \(prev.keyword)")
    }
    if let next = entry.next {
        print("Next: \(next.keyword)")
    }
}

// Search by prefix
let results = dict.search(prefix: "hel", limit: 20)

// Get suggestions for misspelled words
let suggestions = dict.suggestions(for: "helo")
```

## CLI Tool

```bash
# Build
swift build -c release

# Run
swift run -c release openmdict MyDict.mdx lookup hello
swift run -c release openmdict MyDict.mdx search hel
swift run -c release openmdict MyDict.mdx list 20
```

## Testing

```bash
# Set test dictionary path
export MDICT_TEST_FILE=/path/to/dictionary.mdx

# Run tests
swift test
```

## Supported Formats

| Format | Version | Encryption | Status |
|--------|---------|------------|--------|
| MDX | 2.0 | None (0) | ✅ |
| MDX | 2.0 | Index (2) | ✅ |
| MDX | 2.0 | DRM (1,3) | ❌ Not supported |
| MDX | 1.x | - | ⚠️ Untested |
| MDX | 3.0 | - | ❌ Not supported |
| MDD | - | - | 🚧 Planned |

## License

MIT

## Credits

- Format documentation: [writemdict](https://github.com/zhansliu/writemdict/blob/master/fileformat.md)
- Reference implementation: [mdict-utils](https://github.com/liuyug/mdict-utils)
