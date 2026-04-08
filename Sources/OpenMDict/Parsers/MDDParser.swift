import Foundation
import CryptoKit

// MARK: - MDD Resource Reader

/// MDict resource file (.mdd) reader
/// Used for CSS, images, audio, and other assets
public final class MDDParser {

    // MARK: - Public Properties

    /// Number of resources
    public let resourceCount: Int

    /// All resource paths
    public var allPaths: [String] {
        keywords.map { $0.keyword }
    }

    // MARK: - Internal State

    private let reader: BinaryReader
    private let header: MDictHeader
    private let keywords: [KeywordEntry]
    private let recordBlocks: [RecordBlockInfo]
    private let keywordIndex: [String: Int]

    // MARK: - Initialization

    /// Load a resource file
    /// - Parameter path: Path to .mdd file
    public init(path: String) throws {
        // Signpost interval — same shape as MDXParser.init. See
        // `MDictPerfLog.swift` for the collection instructions.
        let signpostID = mdictPerfSignposter.makeSignpostID()
        let state = mdictPerfSignposter.beginInterval(
            "MDDParser.init",
            id: signpostID,
            "\((path as NSString).lastPathComponent)"
        )
        defer { mdictPerfSignposter.endInterval("MDDParser.init", state) }

        guard FileManager.default.fileExists(atPath: path) else {
            throw MDictError.fileNotFound(path)
        }

        self.reader = try BinaryReader(path: path)

        // Parse header (MDD uses UTF-16 for paths)
        let (parsedHeader, headerData) = try Self.parseHeaderWithData(reader)
        self.header = parsedHeader

        // Check encryption
        if header.hasKeywordHeaderEncryption {
            throw MDictError.unsupportedEncryption
        }

        // === Sidecar fast path ===
        // Same shape as MDXParser: if a sidecar cache directory is configured
        // and a valid sidecar exists, skip the entire parse pipeline.
        let headerSHA256Hex = Self.sha256Hex(of: headerData)
        var sidecarPayload: SidecarPayload? = nil
        if let sidecarURL = MDictSidecarCache.sidecarURL(forHeaderSHA256: headerSHA256Hex),
           let identity = SidecarSourceIdentity.capture(path: path, headerSHA256Hex: headerSHA256Hex),
           let payload = SidecarLoader.load(from: sidecarURL, expectedIdentity: identity) {
            sidecarPayload = payload
        }

        let resolvedKeywords: [KeywordEntry]
        let resolvedBlocks: [RecordBlockInfo]
        let resolvedSortedIndices: [UInt32]

        if let payload = sidecarPayload {
            mdictPerfSignposter.emitEvent("MDDParser.path", id: signpostID, "fast")
            resolvedKeywords = payload.keywords
            resolvedBlocks = payload.recordBlocks
            resolvedSortedIndices = payload.sortedIndices
        } else {
            // Slow path: full parse
            mdictPerfSignposter.emitEvent("MDDParser.path", id: signpostID, "slow")
            let keywordData = try Self.parseKeywordSection(reader, header: header)
            let blocks = try Self.parseRecordBlockInfo(reader, header: header)
            let kws = Self.calculateRecordInfo(keywords: keywordData.keywords, recordBlocks: blocks)
            // sortedIndices is required by the sidecar format, even though
            // MDD lookups go through the dict — generation is cheap (a few
            // ms for typical 30k-entry MDDs).
            let sorted = SidecarWriter.computeSortedIndices(kws)
            resolvedKeywords = kws
            resolvedBlocks = blocks
            resolvedSortedIndices = sorted
        }

        self.keywords = resolvedKeywords
        self.recordBlocks = resolvedBlocks
        self.resourceCount = resolvedKeywords.count

        // Build O(1) lookup dict (kept for MDD — typical 30k entries means
        // build cost is <10ms and per-lookup latency matters more here
        // because each article triggers many resource fetches).
        var index: [String: Int] = [:]
        index.reserveCapacity(resolvedKeywords.count)
        for (i, entry) in resolvedKeywords.enumerated() {
            // MDD paths are case-insensitive and use backslash
            let key = entry.keyword.lowercased().replacingOccurrences(of: "\\", with: "/")
            index[key] = i
        }
        self.keywordIndex = index

        // === Background sidecar write (slow path only) ===
        // See MDXParser for the rationale behind MDictSidecarCache.enqueueWrite.
        if sidecarPayload == nil,
           let sidecarURL = MDictSidecarCache.sidecarURL(forHeaderSHA256: headerSHA256Hex),
           let identity = SidecarSourceIdentity.capture(path: path, headerSHA256Hex: headerSHA256Hex) {
            let kws = resolvedKeywords
            let blks = resolvedBlocks
            let sorted = resolvedSortedIndices
            let encoding = header.encoding
            let caseSensitive = header.keyCaseSensitive
            MDictSidecarCache.enqueueWrite {
                do {
                    try SidecarWriter.write(
                        to: sidecarURL,
                        identity: identity,
                        keywords: kws,
                        recordBlocks: blks,
                        sortedIndices: sorted,
                        encoding: encoding,
                        isCaseSensitive: caseSensitive
                    )
                } catch {
                    #if DEBUG
                    print("⚠️ MDDParser: sidecar write failed: \(error)")
                    #endif
                }
            }
        }
    }

    // MARK: - SHA256 helper (used for sidecar identity)

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Public API
             
    /// Subscript access by index
    public subscript(path: String) -> Data? {
        lookup(path)
    }

    /// Look up a resource by path
    /// - Parameter path: Resource path (e.g., "/mydict.css" or "\\img\\logo.png")
    /// - Returns: Raw data or nil if not found
    public func lookup(_ path: String) -> Data? {
        // Normalize path: lowercase, forward slashes
        let normalizedPath = path.lowercased().replacingOccurrences(of: "\\", with: "/")
        
        // Try with and without leading slash
        let searchPaths = [normalizedPath, "/" + normalizedPath, normalizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        
        for searchPath in searchPaths {
            if let idx = keywordIndex[searchPath] {
                return try? loadRecord(keywords[idx])
            }
        }
        
        return nil
    }
    
    /// Check if a resource exists
    public func contains(_ path: String) -> Bool {
        let normalizedPath = path.lowercased().replacingOccurrences(of: "\\", with: "/")
        let searchPaths = [normalizedPath, "/" + normalizedPath, normalizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        
        for searchPath in searchPaths {
            if keywordIndex[searchPath] != nil {
                return true
            }
        }
        return false
    }
    
    // MARK: - Private: Record Loading
    
    private func loadRecord(_ entry: KeywordEntry) throws -> Data {
        let blockInfo = recordBlocks[entry.recordBlockIndex]

        // Atomic seek+read: thread-safe for concurrent loadRecord calls
        let compressedData = try reader.atomicRead(
            at: blockInfo.fileOffset,
            count: Int(blockInfo.compressedSize)
        )

        guard compressedData.count >= 8 else {
            throw MDictError.invalidFormat("MDD record block too small: \(compressedData.count) bytes")
        }
        let compType = compressedData[0]
        guard let compression = CompressionType(rawValue: compType) else {
            throw MDictError.invalidFormat("Unknown compression type: \(compType)")
        }
        
        let decompressedBlock: Data
        if compression != .none {
            decompressedBlock = try Decompressor.decompress(
                Data(compressedData.dropFirst(8)),
                type: compression,
                decompressedSize: Int(blockInfo.decompressedSize)
            )
        } else {
            decompressedBlock = Data(compressedData.dropFirst(8))
        }
        
        let recordStart = Int(entry.recordOffset)
        let recordEnd = recordStart + entry.recordSize
        
        guard recordStart >= 0, recordEnd <= decompressedBlock.count else {
            throw MDictError.invalidFormat("Record offset out of bounds")
        }
        
        return Data(decompressedBlock[recordStart..<recordEnd])
    }
}

// MARK: - Parsing (shared with MDictReader)

extension MDDParser {
    
    /// Parse the MDD header and return both the parsed struct and raw bytes
    /// (raw bytes are used by the sidecar fast-path to compute headerSHA256).
    static func parseHeaderWithData(_ reader: BinaryReader) throws -> (MDictHeader, Data) {
        let headerLen = try reader.readUInt32BE()
        let headerBytes = try reader.readBytes(Int(headerLen))
        _ = try reader.readUInt32LE()  // adler32

        // MDD header is always UTF-16 LE
        let headerStr: String
        if headerBytes.count >= 2 && headerBytes[0] == 0xFF && headerBytes[1] == 0xFE {
            headerStr = String(data: Data(headerBytes), encoding: .utf16LittleEndian) ?? ""
        } else if headerBytes.count >= 2 && headerBytes.suffix(2) == Data([0x00, 0x00]) {
            headerStr = String(data: Data(headerBytes.dropLast(2)), encoding: .utf16LittleEndian) ?? ""
        } else {
            headerStr = String(data: Data(headerBytes), encoding: .utf16LittleEndian) ?? ""
        }

        return (parseHeaderXML(headerStr), headerBytes)
    }

    static func parseHeader(_ reader: BinaryReader) throws -> MDictHeader {
        try parseHeaderWithData(reader).0
    }
    
    private static func parseHeaderXML(_ xml: String) -> MDictHeader {
        func attr(_ name: String) -> String {
            let pattern = "\(name)=\"([^\"]*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
                  let range = Range(match.range(at: 1), in: xml) else { return "" }
            return String(xml[range])
        }
        
        let encryptedStr = attr("Encrypted")
        let encrypted = encryptedStr.isEmpty || encryptedStr == "No" ? 0 :
                        encryptedStr == "Yes" ? 1 : (Int(encryptedStr) ?? 0)
        
        return MDictHeader(
            generatedByEngineVersion: attr("GeneratedByEngineVersion"),
            requiredEngineVersion: attr("RequiredEngineVersion"),
            encrypted: encrypted,
            encoding: "UTF-16",  // MDD always uses UTF-16 for paths
            format: attr("Format"),
            title: attr("Title"),
            description: attr("Description"),
            creationDate: attr("CreationDate"),
            keyCaseSensitive: false  // MDD paths are case-insensitive
        )
    }
    
    struct KeywordParseResult {
        let keywords: [KeywordEntry]
    }
    
    static func parseKeywordSection(_ reader: BinaryReader, header: MDictHeader) throws -> KeywordParseResult {
        let isV2 = header.isVersion2
        
        let numBlocks: UInt64
        let numEntries: UInt64
        let keyIndexDecompLen: UInt64
        let keyIndexCompLen: UInt64
        
        if isV2 {
            numBlocks = try reader.readUInt64BE()
            numEntries = try reader.readUInt64BE()
            keyIndexDecompLen = try reader.readUInt64BE()
            keyIndexCompLen = try reader.readUInt64BE()
            _ = try reader.readUInt64BE()  // keyBlocksTotalLen
        } else {
            numBlocks = UInt64(try reader.readUInt32BE())
            numEntries = UInt64(try reader.readUInt32BE())
            keyIndexCompLen = UInt64(try reader.readUInt32BE())
            _ = try reader.readUInt32BE()
            keyIndexDecompLen = 0
        }
        
        if isV2 { _ = try reader.readUInt32BE() }  // adler32
        
        let keyIndexData = try reader.readBytes(Int(keyIndexCompLen))
        guard keyIndexData.count >= 8 else {
            throw MDictError.invalidFormat("MDD key-index data too small: \(keyIndexData.count) bytes")
        }
        let compType = keyIndexData[0]
        var indexDataToDecompress = Data(keyIndexData.dropFirst(8))

        if header.hasKeywordIndexEncryption {
            let checksumBytes = Data(keyIndexData[4..<8])
            indexDataToDecompress = KeyIndexDecryptor.decrypt(Data(keyIndexData.dropFirst(8)), checksumBytes: checksumBytes)
        }
        
        let decompressedIndex: Data
        if let compression = CompressionType(rawValue: compType), compression != .none {
            decompressedIndex = try Decompressor.decompress(indexDataToDecompress, type: compression, decompressedSize: Int(keyIndexDecompLen))
        } else {
            decompressedIndex = indexDataToDecompress
        }
        
        // Parse block infos - MDD uses UTF-16 for paths
        var keyBlockInfos: [(compSize: UInt64, decompSize: UInt64)] = []
        var indexOffset = 0
        let charWidth = 2  // UTF-16
        
        for _ in 0..<numBlocks {
            guard indexOffset + 10 <= decompressedIndex.count else { break }
            
            if isV2 {
                indexOffset += 8  // numEntries
                let firstKeyLen = Int(decompressedIndex.readUInt16BE(at: indexOffset))
                indexOffset += 2 + firstKeyLen * charWidth + charWidth
                let lastKeyLen = Int(decompressedIndex.readUInt16BE(at: indexOffset))
                indexOffset += 2 + lastKeyLen * charWidth + charWidth
            } else {
                indexOffset += 4
                let firstKeyLen = Int(decompressedIndex[indexOffset])
                indexOffset += 1 + firstKeyLen * charWidth + charWidth
                let lastKeyLen = Int(decompressedIndex[indexOffset])
                indexOffset += 1 + lastKeyLen * charWidth + charWidth
            }
            
            let compSize = isV2 ? decompressedIndex.readUInt64BE(at: indexOffset) : UInt64(decompressedIndex.readUInt32BE(at: indexOffset))
            indexOffset += isV2 ? 8 : 4
            let decompSize = isV2 ? decompressedIndex.readUInt64BE(at: indexOffset) : UInt64(decompressedIndex.readUInt32BE(at: indexOffset))
            indexOffset += isV2 ? 8 : 4
            
            keyBlockInfos.append((compSize, decompSize))
        }
        
        // Parse keyword blocks
        var allKeywords: [KeywordEntry] = []
        allKeywords.reserveCapacity(Int(numEntries))
        let numberWidth = isV2 ? 8 : 4
        
        for blockInfo in keyBlockInfos {
            let compressedBlock = try reader.readBytes(Int(blockInfo.compSize))
            // Every block carries an 8-byte header (1 byte compression type
            // + 4 byte checksum + 3 byte padding). A block shorter than 8
            // bytes means the MDD index was miscomputed or the file is
            // truncated/corrupt — fail cleanly instead of indexing into
            // an empty Data which traps.
            guard compressedBlock.count >= 8 else {
                throw MDictError.invalidFormat("MDD keyword block too small: \(compressedBlock.count) bytes (need >= 8)")
            }
            let blockCompType = compressedBlock[0]

            let decompressedBlock: Data
            if let compression = CompressionType(rawValue: blockCompType), compression != .none {
                decompressedBlock = try Decompressor.decompress(Data(compressedBlock.dropFirst(8)), type: compression, decompressedSize: Int(blockInfo.decompSize))
            } else {
                decompressedBlock = Data(compressedBlock.dropFirst(8))
            }
            
            var blockOffset = 0
            while blockOffset + numberWidth < decompressedBlock.count {
                let entryRecordOffset = isV2 ? decompressedBlock.readUInt64BE(at: blockOffset) : UInt64(decompressedBlock.readUInt32BE(at: blockOffset))
                blockOffset += numberWidth
                
                // Find null terminator (UTF-16: 0x00 0x00)
                var keyEnd = blockOffset
                while keyEnd + 1 < decompressedBlock.count {
                    if decompressedBlock[keyEnd] == 0 && decompressedBlock[keyEnd + 1] == 0 {
                        break
                    }
                    keyEnd += 2
                }
                
                if keyEnd == blockOffset { break }
                
                let keyword = String(data: Data(decompressedBlock[blockOffset..<keyEnd]), encoding: .utf16LittleEndian) ?? ""
                blockOffset = keyEnd + 2  // Skip null terminator
                
                allKeywords.append(KeywordEntry(keyword: keyword, recordBlockIndex: 0, recordOffset: entryRecordOffset, recordSize: 0))
            }
        }
        
        return KeywordParseResult(keywords: allKeywords)
    }
    
    static func parseRecordBlockInfo(_ reader: BinaryReader, header: MDictHeader) throws -> [RecordBlockInfo] {
        let isV2 = header.isVersion2
        
        let numBlocks: UInt64
        let recordIndexLen: UInt64
        
        if isV2 {
            numBlocks = try reader.readUInt64BE()
            _ = try reader.readUInt64BE()  // numEntries
            recordIndexLen = try reader.readUInt64BE()
            _ = try reader.readUInt64BE()  // recordBlocksTotalLen
        } else {
            numBlocks = UInt64(try reader.readUInt32BE())
            _ = try reader.readUInt32BE()
            recordIndexLen = UInt64(try reader.readUInt32BE())
            _ = try reader.readUInt32BE()
        }
        
        var blocks: [RecordBlockInfo] = []
        var fileOffset = reader.position + recordIndexLen
        
        for _ in 0..<numBlocks {
            let compSize = isV2 ? try reader.readUInt64BE() : UInt64(try reader.readUInt32BE())
            let decompSize = isV2 ? try reader.readUInt64BE() : UInt64(try reader.readUInt32BE())
            
            blocks.append(RecordBlockInfo(compressedSize: compSize, decompressedSize: decompSize, fileOffset: fileOffset))
            fileOffset += compSize
        }
        
        return blocks
    }
    
    static func calculateRecordInfo(keywords: [KeywordEntry], recordBlocks: [RecordBlockInfo]) -> [KeywordEntry] {
        guard !keywords.isEmpty, !recordBlocks.isEmpty else { return keywords }
        
        var blockStartOffsets: [UInt64] = []
        var cumOffset: UInt64 = 0
        for block in recordBlocks {
            blockStartOffsets.append(cumOffset)
            cumOffset += block.decompressedSize
        }
        
        var result: [KeywordEntry] = []
        result.reserveCapacity(keywords.count)
        
        for i in 0..<keywords.count {
            let entry = keywords[i]
            let globalOffset = entry.recordOffset
            
            var blockIndex = 0
            for j in 0..<blockStartOffsets.count {
                if j + 1 < blockStartOffsets.count && blockStartOffsets[j + 1] <= globalOffset {
                    blockIndex = j + 1
                } else if blockStartOffsets[j] <= globalOffset {
                    blockIndex = j
                    break
                }
            }
            
            let localOffset = globalOffset - blockStartOffsets[blockIndex]
            let recordSize: Int
            if i + 1 < keywords.count {
                recordSize = Int(keywords[i + 1].recordOffset - entry.recordOffset)
            } else {
                let blockEnd = blockStartOffsets[blockIndex] + recordBlocks[blockIndex].decompressedSize
                recordSize = Int(blockEnd - globalOffset)
            }
            
            result.append(KeywordEntry(keyword: entry.keyword, recordBlockIndex: blockIndex, recordOffset: localOffset, recordSize: recordSize))
        }
        
        return result
    }
}