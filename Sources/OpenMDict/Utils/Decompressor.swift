import Foundation
import Compression

/// Compression type markers in MDX blocks
enum CompressionType: UInt8 {
    case none = 0
    case lzo = 1
    case zlib = 2
}

/// Errors during decompression
enum DecompressionError: Error, CustomStringConvertible {
    case unknownType(UInt8)
    case lzoFailed(LZO1XError)
    case zlibFailed
    case checksumMismatch(expected: UInt32, got: UInt32)
    
    var description: String {
        switch self {
        case .unknownType(let t):
            return "Unknown compression type: \(t)"
        case .lzoFailed(let error):
            return "LZO decompression failed: \(error)"
        case .zlibFailed:
            return "Zlib decompression failed"
        case .checksumMismatch(let expected, let got):
            return "Checksum mismatch: expected \(String(format: "0x%08X", expected)), got \(String(format: "0x%08X", got))"
        }
    }
}

/// Decompressor for MDX blocks
struct Decompressor {
    
    /// Decompress a block based on compression type
    /// - Parameters:
    ///   - data: Compressed data (after the 8-byte header: 4 bytes type + 4 bytes checksum)
    ///   - type: Compression type
    ///   - decompressedSize: Expected size of decompressed data
    /// - Returns: Decompressed data
    static func decompress(_ data: Data, type: CompressionType, decompressedSize: Int) throws -> Data {
        switch type {
        case .none:
            return data
            
        case .lzo:
            return try decompressLZO(data, outputSize: decompressedSize)
            
        case .zlib:
            return try decompressZlib(data, outputSize: decompressedSize)
        }
    }
    
    /// Decompress using LZO1X (pure-Swift decoder, see `LZO1X`).
    ///
    /// Like `lzo1x_decompress_safe`, a stream that decodes to fewer bytes than
    /// `outputSize` yields a shorter result rather than an error.
    static func decompressLZO(_ input: Data, outputSize: Int) throws -> Data {
        do {
            return try LZO1X.decompress(input, expectedSize: outputSize)
        } catch let error as LZO1XError {
            throw DecompressionError.lzoFailed(error)
        }
    }
    
    /// Decompress using zlib (via Apple's Compression framework)
    static func decompressZlib(_ input: Data, outputSize: Int) throws -> Data {
        // Compression framework expects raw deflate, but MDX uses zlib format
        // zlib = 2 byte header + deflate + 4 byte adler32
        // We need to skip the 2-byte zlib header
        guard input.count > 6 else {
            throw DecompressionError.zlibFailed
        }
        
        // Check zlib header (typically 0x78 0x9C for default compression)
        let header = input.prefix(2)
        let hasZlibHeader = (header[0] == 0x78)
        
        let deflateData: Data
        if hasZlibHeader {
            // Skip 2-byte header, remove 4-byte trailer
            deflateData = input.dropFirst(2).dropLast(4)
        } else {
            // Might be raw deflate
            deflateData = input
        }
        
        var output = Data(count: outputSize)
        
        let decodedSize = output.withUnsafeMutableBytes { outPtr -> Int in
            deflateData.withUnsafeBytes { inPtr -> Int in
                compression_decode_buffer(
                    outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    outputSize,
                    inPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    deflateData.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        
        guard decodedSize > 0 else {
            throw DecompressionError.zlibFailed
        }
        
        return output.prefix(decodedSize)
    }
}
