import Foundation

// MARK: - Models

/// Dictionary header parsed from XML
struct MDictHeader {
    let generatedByEngineVersion: String
    let requiredEngineVersion: String
    let encrypted: Int
    let encoding: String
    let format: String
    let title: String
    let description: String
    let creationDate: String
    let keyCaseSensitive: Bool
    
    var isVersion2: Bool {
        generatedByEngineVersion.hasPrefix("2")
    }
    
    /// Whether keyword header (40 bytes) is encrypted with Salsa20/8
    var hasKeywordHeaderEncryption: Bool {
        (encrypted & 1) != 0
    }
    
    /// Whether keyword index is encrypted with RIPEMD128
    var hasKeywordIndexEncryption: Bool {
        (encrypted & 2) != 0
    }
}

/// A single keyword entry with its location info
struct KeywordEntry {
    let keyword: String
    let recordBlockIndex: Int
    let recordOffset: UInt64
    let recordSize: Int
}

/// Info about a record block
struct RecordBlockInfo {
    let compressedSize: UInt64
    let decompressedSize: UInt64
    let fileOffset: UInt64
}

// MARK: - Errors

enum MDictError: Error, CustomStringConvertible {
    case invalidHeader(String)
    case unsupportedVersion(String)
    case unsupportedEncryption
    case decompressionFailed(String)
    case keywordNotFound(String)
    case invalidFormat(String)
    
    var description: String {
        switch self {
        case .invalidHeader(let msg): return "Invalid header: \(msg)"
        case .unsupportedVersion(let v): return "Unsupported version: \(v)"
        case .unsupportedEncryption: return "DRM encryption (Encrypted=1 or 3) not supported"
        case .decompressionFailed(let msg): return "Decompression failed: \(msg)"
        case .keywordNotFound(let k): return "Keyword not found: \(k)"
        case .invalidFormat(let msg): return "Invalid format: \(msg)"
        }
    }
}

// MARK: - Main Reader

/// MDX/MDD file reader
final class MDictReader {
    let path: String
    let header: MDictHeader
    let entryCount: Int
    
    private let reader: BinaryReader
    private var keywords: [KeywordEntry] = []
    private var recordBlocks: [RecordBlockInfo] = []
    private var recordBlocksOffset: UInt64 = 0
    private let textEncoding: String.Encoding
    
    /// Open and parse an MDX/MDD file
    init(path: String) throws {
        self.path = path
        self.reader = try BinaryReader(path: path)
        
        // Initialize LZO
        Decompressor.initialize()
        
        // Parse header
        self.header = try Self.parseHeader(reader)
        
        // Check for DRM
        if header.hasKeywordHeaderEncryption {
            throw MDictError.unsupportedEncryption
        }
        
        // Determine text encoding
        self.textEncoding = Self.encodingFromString(header.encoding)
        
        // Parse keyword section
        let keywordData = try Self.parseKeywordSection(reader, header: header)
        
        // Parse record section header
        self.recordBlocks = try Self.parseRecordBlockInfo(reader, header: header)
        self.recordBlocksOffset = reader.position
        
        // Post-process keywords: calculate recordSize and recordBlockIndex
        self.keywords = Self.calculateRecordInfo(keywords: keywordData.keywords, recordBlocks: recordBlocks)
        self.entryCount = keywords.count
        
        // Build keyword index for fast lookup
        buildKeywordIndex()
    }
    
    /// Calculate recordSize and recordBlockIndex for each keyword
    private static func calculateRecordInfo(keywords: [KeywordEntry], recordBlocks: [RecordBlockInfo]) -> [KeywordEntry] {
        guard !keywords.isEmpty else { return [] }
        
        // Build cumulative offset map for record blocks
        var blockStartOffsets: [UInt64] = []
        var cumulative: UInt64 = 0
        for block in recordBlocks {
            blockStartOffsets.append(cumulative)
            cumulative += block.decompressedSize
        }
        let totalRecordSize = cumulative
        
        var result: [KeywordEntry] = []
        
        for i in 0..<keywords.count {
            let entry = keywords[i]
            let offset = entry.recordOffset
            
            // Find which block this offset belongs to
            var blockIndex = 0
            for j in 0..<blockStartOffsets.count {
                if j + 1 < blockStartOffsets.count {
                    if offset >= blockStartOffsets[j] && offset < blockStartOffsets[j + 1] {
                        blockIndex = j
                        break
                    }
                } else {
                    blockIndex = j
                }
            }
            
            // Calculate local offset within the block
            let localOffset = offset - blockStartOffsets[blockIndex]
            
            // Calculate record size: distance to next entry's offset (or end of data)
            let nextOffset: UInt64
            if i + 1 < keywords.count {
                nextOffset = keywords[i + 1].recordOffset
            } else {
                nextOffset = totalRecordSize
            }
            let recordSize = Int(nextOffset - offset)
            
            result.append(KeywordEntry(
                keyword: entry.keyword,
                recordBlockIndex: blockIndex,
                recordOffset: localOffset,
                recordSize: recordSize
            ))
        }
        
        return result
    }
    
    /// All keywords in the dictionary
    var entries: [String] {
        keywords.map { $0.keyword }
    }
    
    /// Lookup a keyword and return its content
    func lookup(_ keyword: String) throws -> String? {
        // Binary search for keyword
        let searchKey = header.keyCaseSensitive ? keyword : keyword.lowercased()
        
        guard let entry = findEntry(searchKey) else {
            return nil
        }
        
        // Load the record
        let content = try loadRecord(entry)
        return content
    }
    
    /// Search for keywords with a given prefix
    func search(prefix: String, limit: Int = 20) -> [String] {
        let searchPrefix = header.keyCaseSensitive ? prefix : prefix.lowercased()
        
        // Find first match using binary search
        var left = 0
        var right = keywords.count
        
        while left < right {
            let mid = (left + right) / 2
            let key = header.keyCaseSensitive ? keywords[mid].keyword : keywords[mid].keyword.lowercased()
            
            if key < searchPrefix {
                left = mid + 1
            } else {
                right = mid
            }
        }
        
        // Collect matches
        var results: [String] = []
        for i in left..<min(left + limit * 2, keywords.count) {
            let key = keywords[i].keyword
            let compareKey = header.keyCaseSensitive ? key : key.lowercased()
            
            if compareKey.hasPrefix(searchPrefix) {
                results.append(key)
                if results.count >= limit {
                    break
                }
            } else if compareKey > searchPrefix && !compareKey.hasPrefix(searchPrefix) {
                break
            }
        }
        
        return results
    }
    
    // MARK: - Private Methods
    
    // Build keyword index for fast lookup
    private var keywordIndex: [String: Int] = [:]
    
    private func buildKeywordIndex() {
        for (idx, entry) in keywords.enumerated() {
            let key = header.keyCaseSensitive ? entry.keyword : entry.keyword.lowercased()
            keywordIndex[key] = idx
        }
    }
    
    private func findEntry(_ keyword: String) -> KeywordEntry? {
        let searchKey = header.keyCaseSensitive ? keyword : keyword.lowercased()
        
        if let idx = keywordIndex[searchKey] {
            return keywords[idx]
        }
        
        return nil
    }
    
    private func loadRecord(_ entry: KeywordEntry) throws -> String {
        print("    [LOAD] keyword: '\(entry.keyword)', blockIndex: \(entry.recordBlockIndex), offset: \(entry.recordOffset), size: \(entry.recordSize)")
        
        let blockInfo = recordBlocks[entry.recordBlockIndex]
        print("    [LOAD] block fileOffset: \(blockInfo.fileOffset), compSize: \(blockInfo.compressedSize), decompSize: \(blockInfo.decompressedSize)")
        
        // Seek to block and read compressed data
        reader.seek(to: blockInfo.fileOffset)
        let compressedData = try reader.readBytes(Int(blockInfo.compressedSize))
        
        // Parse compression header
        let compType = compressedData[0]
        guard let compression = CompressionType(rawValue: compType) else {
            throw MDictError.decompressionFailed("Unknown compression type: \(compType)")
        }
        
        // Skip 4-byte comp_type + 4-byte checksum
        let payload = compressedData.dropFirst(8)
        
        // Decompress
        let decompressed = try Decompressor.decompress(
            Data(payload),
            type: compression,
            decompressedSize: Int(blockInfo.decompressedSize)
        )
        
        // Extract the specific record
        let recordStart = Int(entry.recordOffset)
        let recordEnd = recordStart + entry.recordSize
        
        print("    [LOAD] decompressed size: \(decompressed.count), recordStart: \(recordStart), recordEnd: \(recordEnd)")
        
        guard recordEnd <= decompressed.count else {
            throw MDictError.invalidFormat("Record offset out of bounds: \(recordEnd) > \(decompressed.count)")
        }
        
        let recordData = decompressed[recordStart..<recordEnd]
        print("    [LOAD] recordData size: \(recordData.count), first 50 bytes: \(recordData.prefix(50).map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Decode as string (remove null terminator if present)
        var trimmedData = Data(recordData)
        if let lastByte = trimmedData.last, lastByte == 0 {
            trimmedData = trimmedData.dropLast()
        }
        
        guard let content = String(data: trimmedData, encoding: textEncoding) else {
            throw MDictError.invalidFormat("Cannot decode record as \(header.encoding)")
        }
        
        return content
    }
}

// MARK: - Header Parsing

extension MDictReader {
    
    static func parseHeader(_ reader: BinaryReader) throws -> MDictHeader {
        // Header length (4 bytes, BE)
        let headerLen = try reader.readUInt32BE()
        
        // Header XML (UTF-16LE encoded)
        let headerData = try reader.readBytes(Int(headerLen))
        
        // Skip 4-byte Adler32 checksum
        reader.skip(4)
        
        // Decode XML
        guard let xmlString = String(data: headerData, encoding: .utf16LittleEndian) else {
            throw MDictError.invalidHeader("Cannot decode header XML")
        }
        
        // Parse XML attributes
        return try parseHeaderXML(xmlString)
    }
    
    private static func parseHeaderXML(_ xml: String) throws -> MDictHeader {
        // Simple attribute extraction (avoiding full XML parser dependency)
        func attr(_ name: String) -> String {
            let pattern = "\(name)=\"([^\"]*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
                  let range = Range(match.range(at: 1), in: xml) else {
                return ""
            }
            return String(xml[range])
        }
        
        let version = attr("GeneratedByEngineVersion")
        guard version.hasPrefix("1") || version.hasPrefix("2") else {
            throw MDictError.unsupportedVersion(version)
        }
        
        return MDictHeader(
            generatedByEngineVersion: version,
            requiredEngineVersion: attr("RequiredEngineVersion"),
            encrypted: Int(attr("Encrypted")) ?? 0,
            encoding: attr("Encoding").isEmpty ? "UTF-8" : attr("Encoding"),
            format: attr("Format"),
            title: attr("Title"),
            description: attr("Description"),
            creationDate: attr("CreationDate"),
            keyCaseSensitive: attr("KeyCaseSensitive").lowercased() == "yes"
        )
    }
    
    static func encodingFromString(_ name: String) -> String.Encoding {
        switch name.uppercased() {
        case "UTF-8", "UTF8": return .utf8
        case "UTF-16", "UTF16": return .utf16LittleEndian
        case "GBK", "GB2312", "GB18030": return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "BIG5": return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        default: return .utf8
        }
    }
}

// MARK: - Keyword Section Parsing

extension MDictReader {
    
    struct KeywordParseResult {
        let keywords: [KeywordEntry]
    }
    
    static func parseKeywordSection(_ reader: BinaryReader, header: MDictHeader) throws -> KeywordParseResult {
        let isV2 = header.isVersion2
        
        // Read keyword section summary (40 bytes for v2, 20 for v1)
        let numBlocks: UInt64
        let numEntries: UInt64
        let keyIndexDecompLen: UInt64
        let keyIndexCompLen: UInt64
        let keyBlocksTotalLen: UInt64
        
        if isV2 {
            numBlocks = try reader.readUInt64BE()
            numEntries = try reader.readUInt64BE()
            keyIndexDecompLen = try reader.readUInt64BE()
            keyIndexCompLen = try reader.readUInt64BE()
            keyBlocksTotalLen = try reader.readUInt64BE()
        } else {
            numBlocks = UInt64(try reader.readUInt32BE())
            numEntries = UInt64(try reader.readUInt32BE())
            keyIndexDecompLen = UInt64(try reader.readUInt32BE())
            keyIndexCompLen = UInt64(try reader.readUInt32BE())
            keyBlocksTotalLen = UInt64(try reader.readUInt32BE())
        }
        
        // Debug output
        print("  [DEBUG] Keyword section summary:")
        print("    numBlocks: \(numBlocks)")
        print("    numEntries: \(numEntries)")
        print("    keyIndexDecompLen: \(keyIndexDecompLen)")
        print("    keyIndexCompLen: \(keyIndexCompLen)")
        print("    keyBlocksTotalLen: \(keyBlocksTotalLen)")
        
        // v2.0 has a 4-byte adler32 checksum of the summary BEFORE the key index
        if isV2 {
            let summaryAdler32 = try reader.readUInt32BE()
            print("    summary adler32: \(String(format: "0x%08X", summaryAdler32))")
        }
        
        // Read key index compressed block
        var keyIndexData = try reader.readBytes(Int(keyIndexCompLen))
        print("    keyIndexData raw size: \(keyIndexData.count)")
        print("    keyIndexData first 16 bytes: \(keyIndexData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Key index structure:
        // [0:4]   comp_type
        // [4:8]   adler32 checksum of decompressed data
        // [8:]    compressed data (possibly encrypted)
        
        let compTypeByte = keyIndexData[0]
        let checksumBytes = Data(keyIndexData[4..<8])
        print("    compression type: \(String(format: "0x%02X", compTypeByte))")
        print("    checksum bytes: \(checksumBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Handle encryption (Encrypted=2 means key index is encrypted)
        var compressedPayload = Data(keyIndexData.dropFirst(8))
        
        if header.hasKeywordIndexEncryption {
            print("    [DEBUG] Decrypting keyword index...")
            print("    encrypted first 8 bytes: \(compressedPayload.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))")
            
            compressedPayload = KeyIndexDecryptor.decrypt(compressedPayload, checksumBytes: checksumBytes)
            print("    decrypted first 8 bytes: \(compressedPayload.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        
        // Decompress keyword index
        let decompressedIndex: Data
        
        if let compression = CompressionType(rawValue: compTypeByte), compression != .none {
            print("    [DEBUG] Decompressing with \(compression)...")
            decompressedIndex = try Decompressor.decompress(
                compressedPayload,
                type: compression,
                decompressedSize: Int(keyIndexDecompLen)
            )
            print("    decompressed size: \(decompressedIndex.count)")
        } else {
            decompressedIndex = compressedPayload
            print("    no compression")
        }
        
        print("    decompressedIndex first 32 bytes: \(decompressedIndex.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Parse keyword block info from index
        // v2.0 format for each block entry:
        //   8 bytes: number of entries in block
        //   2 bytes: first key length (in chars, not bytes for UTF-16)
        //   N bytes: first key (null terminated)
        //   2 bytes: last key length
        //   N bytes: last key (null terminated)
        //   8 bytes: compressed block size
        //   8 bytes: decompressed block size
        
        var keyBlockInfos: [(numEntries: Int, firstKey: String, lastKey: String, compSize: UInt64, decompSize: UInt64)] = []
        var indexOffset = 0
        let encoding = encodingFromString(header.encoding)
        let charWidth = (encoding == .utf16LittleEndian) ? 2 : 1
        
        print("    [DEBUG] Parsing \(numBlocks) block infos, encoding: \(header.encoding), charWidth: \(charWidth)")
        
        for blockIdx in 0..<numBlocks {
            guard indexOffset + 10 <= decompressedIndex.count else {
                print("    [ERROR] indexOffset \(indexOffset) out of bounds at block \(blockIdx)")
                break
            }
            
            let blockEntryCount: Int
            let firstKeyLen: Int  // This is character count, not byte count
            
            if isV2 {
                blockEntryCount = Int(decompressedIndex.readUInt64BE(at: indexOffset))
                firstKeyLen = Int(decompressedIndex.readUInt16BE(at: indexOffset + 8))
                indexOffset += 10
            } else {
                blockEntryCount = Int(decompressedIndex.readUInt32BE(at: indexOffset))
                firstKeyLen = Int(decompressedIndex[indexOffset + 4])
                indexOffset += 5
            }
            
            if blockIdx < 3 {
                print("    Block \(blockIdx): entryCount=\(blockEntryCount), firstKeyLen=\(firstKeyLen)")
            }
            
            // For v2 with UTF-8, key length is in bytes
            // For v2 with UTF-16, key length is in characters (multiply by 2 for bytes)
            let firstKeyByteLen = firstKeyLen * charWidth
            let firstKeyEndOffset = indexOffset + firstKeyByteLen
            
            guard firstKeyEndOffset + charWidth <= decompressedIndex.count else {
                print("    [ERROR] firstKey out of bounds: offset=\(indexOffset), len=\(firstKeyByteLen)")
                break
            }
            
            // Read first key
            let firstKeyData = decompressedIndex[indexOffset..<firstKeyEndOffset]
            let firstKey = String(data: Data(firstKeyData), encoding: encoding) ?? ""
            indexOffset = firstKeyEndOffset + charWidth  // Skip null terminator
            
            if blockIdx < 3 {
                print("      firstKey: '\(firstKey.prefix(30))'")
            }
            
            // Read last key length
            let lastKeyLen: Int
            if isV2 {
                guard indexOffset + 2 <= decompressedIndex.count else {
                    print("    [ERROR] lastKeyLen out of bounds")
                    break
                }
                lastKeyLen = Int(decompressedIndex.readUInt16BE(at: indexOffset))
                indexOffset += 2
            } else {
                lastKeyLen = Int(decompressedIndex[indexOffset])
                indexOffset += 1
            }
            
            let lastKeyByteLen = lastKeyLen * charWidth
            let lastKeyEndOffset = indexOffset + lastKeyByteLen
            
            guard lastKeyEndOffset + charWidth <= decompressedIndex.count else {
                print("    [ERROR] lastKey out of bounds")
                break
            }
            
            // Read last key
            let lastKeyData = decompressedIndex[indexOffset..<lastKeyEndOffset]
            let lastKey = String(data: Data(lastKeyData), encoding: encoding) ?? ""
            indexOffset = lastKeyEndOffset + charWidth  // Skip null terminator
            
            // Read block sizes
            let blockCompSize: UInt64
            let blockDecompSize: UInt64
            
            if isV2 {
                guard indexOffset + 16 <= decompressedIndex.count else {
                    print("    [ERROR] block sizes out of bounds")
                    break
                }
                blockCompSize = decompressedIndex.readUInt64BE(at: indexOffset)
                blockDecompSize = decompressedIndex.readUInt64BE(at: indexOffset + 8)
                indexOffset += 16
            } else {
                guard indexOffset + 8 <= decompressedIndex.count else {
                    print("    [ERROR] block sizes out of bounds")
                    break
                }
                blockCompSize = UInt64(decompressedIndex.readUInt32BE(at: indexOffset))
                blockDecompSize = UInt64(decompressedIndex.readUInt32BE(at: indexOffset + 4))
                indexOffset += 8
            }
            
            if blockIdx < 3 {
                print("      lastKey: '\(lastKey.prefix(30))', compSize=\(blockCompSize), decompSize=\(blockDecompSize)")
            }
            
            keyBlockInfos.append((blockEntryCount, firstKey, lastKey, blockCompSize, blockDecompSize))
        }
        
        print("    [DEBUG] Parsed \(keyBlockInfos.count) block infos")
        
        // Read and parse keyword blocks
        var allKeywords: [KeywordEntry] = []
        
        for (blockIdx, blockInfo) in keyBlockInfos.enumerated() {
            let compressedBlock = try reader.readBytes(Int(blockInfo.compSize))
            
            // Decompress block
            let blockCompType = compressedBlock[0]
            let decompressedBlock: Data
            
            if let compression = CompressionType(rawValue: blockCompType), compression != .none {
                decompressedBlock = try Decompressor.decompress(
                    Data(compressedBlock.dropFirst(8)),
                    type: compression,
                    decompressedSize: Int(blockInfo.decompSize)
                )
            } else {
                decompressedBlock = Data(compressedBlock.dropFirst(8))
            }
            
            // Parse entries from block - iterate until end of block (like Python version)
            var blockOffset = 0
            let encoding = encodingFromString(header.encoding)
            let nullTermLen = (encoding == .utf16LittleEndian) ? 2 : 1
            let numberWidth = isV2 ? 8 : 4
            
            while blockOffset < decompressedBlock.count {
                // Need at least numberWidth bytes for the record offset
                if blockOffset + numberWidth > decompressedBlock.count {
                    break
                }
                
                // Read record offset
                let entryRecordOffset: UInt64
                if isV2 {
                    entryRecordOffset = decompressedBlock.readUInt64BE(at: blockOffset)
                } else {
                    entryRecordOffset = UInt64(decompressedBlock.readUInt32BE(at: blockOffset))
                }
                blockOffset += numberWidth
                
                // Find null terminator for keyword
                var keyEnd = blockOffset
                if encoding == .utf16LittleEndian {
                    while keyEnd + 1 < decompressedBlock.count {
                        if decompressedBlock[keyEnd] == 0 && decompressedBlock[keyEnd + 1] == 0 {
                            break
                        }
                        keyEnd += 2
                    }
                } else {
                    while keyEnd < decompressedBlock.count && decompressedBlock[keyEnd] != 0 {
                        keyEnd += 1
                    }
                }
                
                // Safeguard: if keyEnd didn't move, we're stuck
                if keyEnd == blockOffset {
                    break
                }
                
                let keyData = decompressedBlock[blockOffset..<keyEnd]
                let keyword = String(data: Data(keyData), encoding: encoding) ?? ""
                blockOffset = keyEnd + nullTermLen
                
                let entry = KeywordEntry(
                    keyword: keyword,
                    recordBlockIndex: 0, // Will be recalculated
                    recordOffset: entryRecordOffset,
                    recordSize: 0 // Will be filled in later
                )
                
                allKeywords.append(entry)
            }
        }
        
        return KeywordParseResult(keywords: allKeywords)
    }
}

// MARK: - Record Section Parsing

extension MDictReader {
    
    static func parseRecordBlockInfo(_ reader: BinaryReader, header: MDictHeader) throws -> [RecordBlockInfo] {
        let isV2 = header.isVersion2
        
        // Read record section summary
        let numBlocks: UInt64
        let numEntries: UInt64
        let recordIndexLen: UInt64
        let recordBlocksTotalLen: UInt64
        
        if isV2 {
            numBlocks = try reader.readUInt64BE()
            numEntries = try reader.readUInt64BE()
            recordIndexLen = try reader.readUInt64BE()
            recordBlocksTotalLen = try reader.readUInt64BE()
        } else {
            numBlocks = UInt64(try reader.readUInt32BE())
            numEntries = UInt64(try reader.readUInt32BE())
            recordIndexLen = UInt64(try reader.readUInt32BE())
            recordBlocksTotalLen = UInt64(try reader.readUInt32BE())
        }
        
        // Read record block info
        var blocks: [RecordBlockInfo] = []
        var currentOffset = reader.position + recordIndexLen
        
        for _ in 0..<numBlocks {
            let compSize: UInt64
            let decompSize: UInt64
            
            if isV2 {
                compSize = try reader.readUInt64BE()
                decompSize = try reader.readUInt64BE()
            } else {
                compSize = UInt64(try reader.readUInt32BE())
                decompSize = UInt64(try reader.readUInt32BE())
            }
            
            blocks.append(RecordBlockInfo(
                compressedSize: compSize,
                decompressedSize: decompSize,
                fileOffset: currentOffset
            ))
            
            currentOffset += compSize
        }
        
        return blocks
    }
}
