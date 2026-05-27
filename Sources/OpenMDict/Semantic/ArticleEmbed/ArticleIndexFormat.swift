//
//  ArticleIndexFormat.swift
//  OpenMDictCLI  (M15 Phase 3.2)
//
//  Binary layout for the article-embedding sidecar (.semantic.idx file).
//  Mirrors M13's MDXIndex sidecar in spirit (atomic write, 3-field
//  invalidation, mmap-friendly) but stores Float16 sentence embeddings
//  instead of parsed keyword tables.
//
//  Layout:
//
//    Header (96 bytes, fixed, all little-endian):
//      0   magic "SIDX"                 4
//      4   format version (= 1)         2
//      6   reserved (zero)              2
//      8   model_sha256                 32
//     40   mdx_header_sha256            32
//     72   embedding_dim (e.g. 384)     4
//     76   article_count                4
//     80   tokenizer_max_len (e.g. 128) 4
//     84   created_at (UNIX seconds)    8
//     92   reserved (zero)              4
//
//    Body:
//      96 .. end   article_count × embedding_dim × Float16, row-major
//                  row i = embedding for MDictReader.allKeys[i]
//
//    file_size invariant: 96 + (article_count × embedding_dim × 2)
//
//  Three-field invalidation: model_sha256 + mdx_header_sha256 + format
//  version. Any mismatch → silent rebuild. No CRC because the 3 hashes
//  already cover content drift, and a partial-corruption sidecar would
//  fail in the cosine scan anyway.
//
//  Endianness: native little-endian. Apple-only (iOS + macOS) — no
//  cross-platform concern. If a future Linux port matters, swap to
//  explicit byte-order helpers.
//

import Foundation

/// Article-embedding sidecar binary format constants. Keep in sync with
/// the layout doc-comment at the top of this file.
public enum ArticleIndexFormat {
    /// Magic bytes at offset 0. ASCII "SIDX" = 0x58444953 little-endian.
    public static let magicBytes: [UInt8] = [0x53, 0x49, 0x44, 0x58]  // 'S' 'I' 'D' 'X'
    public static let magicLE: UInt32 = 0x58444953

    /// Format version. Bump when the binary layout changes — any reader
    /// seeing a different version treats the sidecar as stale.
    public static let currentVersion: UInt16 = 1

    /// Fixed header size in bytes. All offsets in the layout doc above
    /// must fit within this.
    public static let headerSize: Int = 96

    /// File extension for sidecar files. The full filename convention is
    /// `<dictId>.semantic.idx` to mirror the M13 keyword sidecar naming.
    public static let fileExtension: String = "semantic.idx"
}

/// Header view of an article-embedding sidecar. Constructed from a byte
/// buffer via `ArticleIndexHeader.parse(_:)` or built fresh via
/// `ArticleIndexHeader.init(...)` then serialized via `serialize()`.
public struct ArticleIndexHeader: Equatable {
    public let formatVersion: UInt16
    public let modelSHA256: Data           // 32 bytes
    public let mdxHeaderSHA256: Data       // 32 bytes
    public let embeddingDim: UInt32        // e.g. 384 for MiniLM-L6
    public let articleCount: UInt32
    public let tokenizerMaxLen: UInt32     // e.g. 128
    public let createdAt: UInt64           // UNIX seconds

    /// Total file size implied by `articleCount` × `embeddingDim` × 2
    /// (Float16) + the 96-byte header.
    public var expectedFileSize: Int {
        ArticleIndexFormat.headerSize
            + Int(articleCount) * Int(embeddingDim) * 2
    }

    /// Build a fresh header. `createdAt` defaults to now.
    public init(modelSHA256: Data,
         mdxHeaderSHA256: Data,
         embeddingDim: UInt32,
         articleCount: UInt32,
         tokenizerMaxLen: UInt32,
         createdAt: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        precondition(modelSHA256.count == 32, "model_sha256 must be 32 bytes")
        precondition(mdxHeaderSHA256.count == 32, "mdx_header_sha256 must be 32 bytes")
        self.formatVersion = ArticleIndexFormat.currentVersion
        self.modelSHA256 = modelSHA256
        self.mdxHeaderSHA256 = mdxHeaderSHA256
        self.embeddingDim = embeddingDim
        self.articleCount = articleCount
        self.tokenizerMaxLen = tokenizerMaxLen
        self.createdAt = createdAt
    }

    /// Internal init for parsing — allows version != currentVersion
    /// (so parse can return a valid header that the validator then
    /// rejects, distinguishing "corrupt" from "stale version").
    private init(formatVersion: UInt16,
                 modelSHA256: Data, mdxHeaderSHA256: Data,
                 embeddingDim: UInt32, articleCount: UInt32,
                 tokenizerMaxLen: UInt32, createdAt: UInt64) {
        self.formatVersion = formatVersion
        self.modelSHA256 = modelSHA256
        self.mdxHeaderSHA256 = mdxHeaderSHA256
        self.embeddingDim = embeddingDim
        self.articleCount = articleCount
        self.tokenizerMaxLen = tokenizerMaxLen
        self.createdAt = createdAt
    }

    /// Serialize to exactly `headerSize` bytes.
    public func serialize() -> Data {
        var data = Data(capacity: ArticleIndexFormat.headerSize)
        // Reusable scratch for little-endian primitives.
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        // 0..4   magic
        data.append(contentsOf: ArticleIndexFormat.magicBytes)
        // 4..6   version
        appendLE(formatVersion)
        // 6..8   reserved
        appendLE(UInt16(0))
        // 8..40  model_sha256
        data.append(modelSHA256)
        // 40..72 mdx_header_sha256
        data.append(mdxHeaderSHA256)
        // 72..76 embedding_dim
        appendLE(embeddingDim)
        // 76..80 article_count
        appendLE(articleCount)
        // 80..84 tokenizer_max_len
        appendLE(tokenizerMaxLen)
        // 84..92 created_at
        appendLE(createdAt)
        // 92..96 reserved
        appendLE(UInt32(0))
        precondition(data.count == ArticleIndexFormat.headerSize,
                     "Header serialization size mismatch")
        return data
    }

    /// Parse a 96-byte header buffer. Returns nil if the magic bytes
    /// don't match (file isn't a sidecar at all). Otherwise returns a
    /// header even if `formatVersion` is stale — callers should check
    /// the version separately.
    public static func parse(_ data: Data) -> ArticleIndexHeader? {
        guard data.count >= ArticleIndexFormat.headerSize else { return nil }
        // Magic check.
        guard data[0] == ArticleIndexFormat.magicBytes[0],
              data[1] == ArticleIndexFormat.magicBytes[1],
              data[2] == ArticleIndexFormat.magicBytes[2],
              data[3] == ArticleIndexFormat.magicBytes[3]
        else { return nil }

        func readLE<T: FixedWidthInteger>(at offset: Int, _ type: T.Type) -> T {
            data.withUnsafeBytes { ptr in
                let raw = ptr.baseAddress!.advanced(by: offset)
                return raw.loadUnaligned(as: T.self).littleEndian
            }
        }
        let version: UInt16 = readLE(at: 4, UInt16.self)
        let modelSHA = data.subdata(in: 8..<40)
        let mdxSHA = data.subdata(in: 40..<72)
        let dim: UInt32 = readLE(at: 72, UInt32.self)
        let count: UInt32 = readLE(at: 76, UInt32.self)
        let maxLen: UInt32 = readLE(at: 80, UInt32.self)
        let createdAt: UInt64 = readLE(at: 84, UInt64.self)

        return ArticleIndexHeader(
            formatVersion: version,
            modelSHA256: modelSHA, mdxHeaderSHA256: mdxSHA,
            embeddingDim: dim, articleCount: count,
            tokenizerMaxLen: maxLen, createdAt: createdAt
        )
    }
}

/// Validation outcome — distinguishes "this isn't a sidecar at all" from
/// "it's a sidecar but stale" (rebuilding either way, but reported
/// differently in `articleindex info`).
public enum ArticleIndexValidationResult: Equatable {
    case ok
    case notASidecar              // magic mismatch
    case wrongVersion(UInt16)     // version != current
    case modelMismatch            // model_sha256 != expected
    case mdxMismatch              // mdx_header_sha256 != expected
    case dimMismatch(UInt32)      // embedding_dim != expected
    case sizeMismatch(expected: Int, actual: Int)
}

extension ArticleIndexHeader {
    /// Cross-check this header against the current model + MDX + file
    /// size, returning the first mismatch found.
    public func validate(
        expectedModelSHA256: Data,
        expectedMDXHeaderSHA256: Data,
        expectedEmbeddingDim: UInt32,
        actualFileSize: Int
    ) -> ArticleIndexValidationResult {
        if formatVersion != ArticleIndexFormat.currentVersion {
            return .wrongVersion(formatVersion)
        }
        if modelSHA256 != expectedModelSHA256 {
            return .modelMismatch
        }
        if mdxHeaderSHA256 != expectedMDXHeaderSHA256 {
            return .mdxMismatch
        }
        if embeddingDim != expectedEmbeddingDim {
            return .dimMismatch(embeddingDim)
        }
        if expectedFileSize != actualFileSize {
            return .sizeMismatch(expected: expectedFileSize, actual: actualFileSize)
        }
        return .ok
    }
}

/// Convert a Float32 to its IEEE 754 binary16 (Float16) bit pattern,
/// via manual bit twiddling. We hand-roll this (rather than using
/// Swift's `Float16` type) because `Float16` on Intel macOS has
/// inconsistent init/conversion support across toolchain versions —
/// hand rolling guarantees the same byte output everywhere.
/// Trade-off: ~50 ns/element vs <10 ns for native Float16 on Apple
/// Silicon. Negligible for our use case (one-shot indexing).
@inline(__always)
public func float16Bits(from f: Float) -> UInt16 {
    let bits = f.bitPattern
    let signBit = UInt16((bits >> 31) & 0x1) << 15
    let exp32 = Int32((bits >> 23) & 0xFF) - 127
    let mant32 = bits & 0x7FFFFF

    if exp32 == 128 {
        // Inf / NaN: preserve sign, mark as inf (mantissa-payload
        // collapsed since the consumer doesn't distinguish NaN
        // payloads).
        return signBit | 0x7C00 | (mant32 != 0 ? 1 : 0)
    }
    let exp16 = exp32 + 15
    if exp16 >= 31 { return signBit | 0x7C00 }       // overflow → inf
    if exp16 <= 0  { return signBit }                // underflow → ±0
    let mant16 = mant32 >> 13                        // 23-bit mant → 10-bit
    return signBit | UInt16(exp16 << 10) | UInt16(mant16)
}

/// Convert an IEEE 754 binary16 bit pattern to Float32 via manual
/// bit manipulation. Mirror of `float16Bits(from:)` for the reverse
/// direction. Used only for diagnostic output (sidecar info preview).
public func float32FromFloat16Bits(_ h: UInt16) -> Float {
    let sign = UInt32(h >> 15) & 0x1
    let exp  = UInt32((h >> 10) & 0x1F)
    let mant = UInt32(h & 0x3FF)
    let s = sign << 31

    if exp == 0 {
        if mant == 0 { return Float(bitPattern: s) }   // ±0
        // Subnormal half → normalized float32.
        var e: Int32 = Int32(exp)
        var m = mant
        while (m & 0x400) == 0 { m <<= 1; e &-= 1 }
        e &+= 1
        m &= 0x3FF
        return Float(bitPattern: s | (UInt32(e + 112) << 23) | (m << 13))
    } else if exp == 0x1F {
        // Inf / NaN — preserve mantissa for NaN payload.
        return Float(bitPattern: s | 0x7F800000 | (mant << 13))
    } else {
        // Normal.
        return Float(bitPattern: s | ((exp + 112) << 23) | (mant << 13))
    }
}
