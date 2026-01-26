import Foundation

// MARK: - Internal Info Structure

/// Internal dictionary info (used by MDXParser)
internal struct MDictInfo {
    let title: String
    let description: String
    let entryCount: Int
    let format: String
    let encoding: String
    let engineVersion: String
    let creationDate: String
    let isEncrypted: Bool
    let isCaseSensitive: Bool
}

// MARK: - MDXParser

/// Internal MDX file parser
/// Used by MDictReader facade
internal final class MDXParser {
    
    // MARK: - Properties
    
    /// Dictionary metadata
    let info: MDictInfo
    
    /// Number of entries
    var entryCount: Int { keywords.count }
    
    /// All keywords (for iteration/display)
    var allKeywords: [String] {
        keywords.map { $0.keyword }
    }
    
    // MARK: - Internal State (initialized once)
    
    private let reader: BinaryReader
    private let header: MDictHeader
    private let keywords: [KeywordEntry]
    private let recordBlocks: [RecordBlockInfo]
    private let exactIndex: [String: Int]        // exact keyword -> index
    private let caseInsensitiveIndex: [String: Int]  // lowercased keyword -> index (for case-insensitive dicts)
    
    // MARK: - Initialization
    
    /// Load a dictionary from file
    /// - Parameter path: Path to .mdx file
    /// - Throws: MDictError on failure
    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MDictError.fileNotFound(path)
        }
        
        self.reader = try BinaryReader(path: path)
        
        // Parse header
        self.header = try Self.parseHeader(reader)
        
        // Check for unsupported encryption (DRM)
        if header.hasKeywordHeaderEncryption {
            throw MDictError.unsupportedEncryption
        }
        
        // Parse keyword section
        let keywordData = try Self.parseKeywordSection(reader, header: header)
        
        // Parse record block info
        let blocks = try Self.parseRecordBlockInfo(reader, header: header)
        self.recordBlocks = blocks
        
        // Post-process keywords (calculate record sizes and block indices)
        self.keywords = Self.calculateRecordInfo(keywords: keywordData.keywords, recordBlocks: blocks)
        
        // Build keyword indexes for O(1) lookup
        var exact: [String: Int] = [:]
        var caseInsensitive: [String: Int] = [:]
        exact.reserveCapacity(keywords.count)
        if !header.keyCaseSensitive {
            caseInsensitive.reserveCapacity(keywords.count)
        }
        for (i, entry) in keywords.enumerated() {
            exact[entry.keyword] = i
            if !header.keyCaseSensitive {
                caseInsensitive[entry.keyword.lowercased()] = i
            }
        }
        self.exactIndex = exact
        self.caseInsensitiveIndex = caseInsensitive
        
        // Create public info
        self.info = MDictInfo(
            title: header.title,
            description: header.description,
            entryCount: keywords.count,
            format: header.format,
            encoding: header.encoding,
            engineVersion: header.generatedByEngineVersion,
            creationDate: header.creationDate,
            isEncrypted: header.encrypted != 0,
            isCaseSensitive: header.keyCaseSensitive
        )
    }
    
    // MARK: - Lookup API
    
    /// Lookup a keyword and return definition with index
    /// Automatically follows @@@LINK= redirects (up to 5 levels)
    /// - Parameter keyword: The word to look up
    /// - Returns: Tuple of (original keyword, definition, index) or nil if not found
    func lookupWithIndex(_ keyword: String) -> (String, String, Int)? {
        return lookupWithRedirect(keyword, depth: 0)
    }

    /// Internal lookup with redirect following
    /// - Parameters:
    ///   - keyword: The word to look up
    ///   - depth: Current redirect depth (to prevent infinite loops)
    /// - Returns: Tuple of (original keyword, definition, index) or nil if not found
    private func lookupWithRedirect(_ keyword: String, depth: Int) -> (String, String, Int)? {
       // Prevent infinite redirect loops
        guard depth < 5 else {
            print("⚠️ MDXParser: Max redirect depth reached for '\(keyword)'")
            return nil
        }

        // 1. Try exact match first
        if let idx = exactIndex[keyword] {
            guard let definition = try? loadRecord(keywords[idx]) else {
                return nil
            }
            return resolveRedirect(keyword: keywords[idx].keyword, definition: definition, index: idx, depth: depth)
        }
        
        // 2. Fallback to case-insensitive match (only for case-insensitive dicts)
        if !header.keyCaseSensitive {
            let searchKey = keyword.lowercased()
            if let idx = caseInsensitiveIndex[searchKey] {
                guard let definition = try? loadRecord(keywords[idx]) else {
                    return nil
                }
                return resolveRedirect(keyword: keywords[idx].keyword, definition: definition, index: idx, depth: depth)
            }
        }
        
        return nil
    }
    
    /// Check if definition is a @@@LINK= redirect and follow it
    /// - Parameters:
    ///   - keyword: Original keyword
    ///   - definition: Definition content to check
    ///   - index: Original index
    ///   - depth: Current redirect depth
    /// - Returns: Final resolved entry or original if not a redirect
    private func resolveRedirect(keyword: String, definition: String, index: Int, depth: Int) -> (String, String, Int)? {
        let trimmed = definition.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for @@@LINK= prefix (case-insensitive)
        let linkPrefix = "@@@LINK="
        guard trimmed.uppercased().hasPrefix(linkPrefix) else {
            // Not a redirect, return as-is
            return (keyword, definition, index)
        }

        // Extract target keyword
        let target = String(trimmed.dropFirst(linkPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            print("⚠️ MDXParser: Empty @@@LINK= target for '\(keyword)'")
            return (keyword, definition, index)
        }

        // Follow redirect
        return lookupWithRedirect(target, depth: depth + 1)
    }

    /// Get entry at specific index
    /// - Parameter index: Index in keyword list
    /// - Returns: Tuple of (keyword, definition) or nil if out of bounds
    func entryAt(_ index: Int) -> (String, String)? {
        guard index >= 0, index < keywords.count else {
            return nil
        }
        
        let kw = keywords[index]
        guard let definition = try? loadRecord(kw) else {
            return nil
        }
        
        return (kw.keyword, definition)
    }
    
    /// Search for keywords with a prefix
    /// - Parameters:
    ///   - prefix: Prefix to search for
    ///   - limit: Maximum results (default 20)
    /// - Returns: Array of matching keywords (original case preserved)
    func search(prefix: String, limit: Int = 20) -> [String] {
        let searchPrefix = header.keyCaseSensitive ? prefix : prefix.lowercased()
        
        var results: [String] = []
        results.reserveCapacity(min(limit, 100))
        
        for entry in keywords {
            let key = header.keyCaseSensitive ? entry.keyword : entry.keyword.lowercased()
            if key.hasPrefix(searchPrefix) {
                results.append(entry.keyword)
                if results.count >= limit { break }
            }
        }
        return results
    }
    
    /// Get suggestions for a keyword (did you mean?)
    /// - Parameters:
    ///   - keyword: The word to find suggestions for
    ///   - limit: Maximum suggestions
    /// - Returns: Array of similar keywords
    func suggestions(for keyword: String, limit: Int = 5) -> [String] {
        // Try progressively shorter prefixes
        for prefixLen in stride(from: min(keyword.count, 5), through: 1, by: -1) {
            let prefix = String(keyword.prefix(prefixLen))
            let matches = search(prefix: prefix, limit: limit)
            if !matches.isEmpty { return matches }
        }
        return []
    }
    
    // MARK: - Private: Record Loading
    
    private func loadRecord(_ entry: KeywordEntry) throws -> String {
        let blockInfo = recordBlocks[entry.recordBlockIndex]
        
        reader.seek(to: blockInfo.fileOffset)
        let compressedData = try reader.readBytes(Int(blockInfo.compressedSize))
        
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
        
        let recordData = decompressedBlock[recordStart..<recordEnd]
        let encoding = encodingFromString(header.encoding)
        
        // Strip trailing nulls
        var endIdx = recordData.endIndex
        while endIdx > recordData.startIndex && recordData[recordData.index(before: endIdx)] == 0 {
            endIdx = recordData.index(before: endIdx)
        }
        
        return String(data: Data(recordData[recordData.startIndex..<endIdx]), encoding: encoding) ?? ""
    }
}

// MARK: - Internal Models

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
    
    var isVersion2: Bool { generatedByEngineVersion.hasPrefix("2") }
    var hasKeywordHeaderEncryption: Bool { (encrypted & 1) != 0 }
    var hasKeywordIndexEncryption: Bool { (encrypted & 2) != 0 }
}

struct KeywordEntry {
    let keyword: String
    let recordBlockIndex: Int
    let recordOffset: UInt64
    let recordSize: Int
}

struct RecordBlockInfo {
    let compressedSize: UInt64
    let decompressedSize: UInt64
    let fileOffset: UInt64
}

// MARK: - Header Parsing

extension MDXParser {
    
    /// Read only the header without parsing keywords (fast)
    /// Used for displaying dictionary list without full loading
    static func readHeaderOnly(path: String) -> MDictInfo? {
        guard FileManager.default.fileExists(atPath: path),
              let reader = try? BinaryReader(path: path) else {
            return nil
        }
        
        guard let header = try? parseHeader(reader) else {
            return nil
        }
        
        // We can't know the exact entry count without parsing keywords,
        // but we can estimate from header or return 0
        return MDictInfo(
            title: header.title,
            description: header.description,
            entryCount: 0,  // Unknown without full parse
            format: header.format,
            encoding: header.encoding,
            engineVersion: header.generatedByEngineVersion,
            creationDate: header.creationDate,
            isEncrypted: header.encrypted != 0,
            isCaseSensitive: header.keyCaseSensitive
        )
    }
    
    static func parseHeader(_ reader: BinaryReader) throws -> MDictHeader {
        let headerLen = try reader.readUInt32BE()
        let headerData = try reader.readBytes(Int(headerLen))
        _ = try reader.readUInt32LE()  // adler32
        
        let headerStr: String
        if headerData.count >= 2 && headerData[0] == 0xFF && headerData[1] == 0xFE {
            headerStr = String(data: Data(headerData), encoding: .utf16LittleEndian) ?? ""
        } else if headerData.count >= 2 && headerData.suffix(2) == Data([0x00, 0x00]) {
            headerStr = String(data: Data(headerData.dropLast(2)), encoding: .utf16LittleEndian) ?? ""
        } else {
            headerStr = String(data: Data(headerData), encoding: .utf8) ?? ""
        }
        
        return parseHeaderXML(headerStr)
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
            encoding: attr("Encoding").isEmpty ? "UTF-8" : attr("Encoding"),
            format: attr("Format"),
            title: attr("Title"),
            description: attr("Description"),
            creationDate: attr("CreationDate"),
            keyCaseSensitive: attr("KeyCaseSensitive") == "Yes"
        )
    }
}

// MARK: - Keyword Section Parsing

extension MDXParser {
    
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
            _ = try reader.readUInt32BE()  // keyBlocksTotalLen
            keyIndexDecompLen = 0
        }
        
        if isV2 { _ = try reader.readUInt32BE() }  // adler32
        
        let keyIndexData = try reader.readBytes(Int(keyIndexCompLen))
        
        let decompressedIndex: Data
        if isV2 {
            // V2: key index has 8-byte header (compression type + checksum)
            let compType = keyIndexData[0]
            var indexDataToDecompress = Data(keyIndexData.dropFirst(8))
            
            if header.hasKeywordIndexEncryption {
                let checksumBytes = Data(keyIndexData[4..<8])
                indexDataToDecompress = KeyIndexDecryptor.decrypt(Data(keyIndexData.dropFirst(8)), checksumBytes: checksumBytes)
            }
            
            if let compression = CompressionType(rawValue: compType), compression != .none {
                decompressedIndex = try Decompressor.decompress(indexDataToDecompress, type: compression, decompressedSize: Int(keyIndexDecompLen))
            } else {
                decompressedIndex = indexDataToDecompress
            }
        } else {
            // V1: key index is NOT compressed and has NO header - it's raw data
            decompressedIndex = keyIndexData
        }
        
        // Parse block infos
        var keyBlockInfos: [(compSize: UInt64, decompSize: UInt64)] = []
        var indexOffset = 0
        let encoding = encodingFromString(header.encoding)
        let charWidth = (encoding == .utf16LittleEndian) ? 2 : 1
        
        for _ in 0..<numBlocks {
            guard indexOffset + 10 <= decompressedIndex.count else { break }
            
            if isV2 {
                indexOffset += 8  // numEntries
                let firstKeyLen = Int(decompressedIndex.readUInt16BE(at: indexOffset))
                indexOffset += 2 + firstKeyLen * charWidth + charWidth
                let lastKeyLen = Int(decompressedIndex.readUInt16BE(at: indexOffset))
                indexOffset += 2 + lastKeyLen * charWidth + charWidth
            } else {
                // V1: numEntries (4) + firstKeyLen (1) + firstKey + lastKeyLen (1) + lastKey + compSize (4) + decompSize (4)
                // NO null terminators in V1 block info!
                indexOffset += 4  // numEntries
                let firstKeyLen = Int(decompressedIndex[indexOffset])
                indexOffset += 1 + firstKeyLen * charWidth  // NO null terminator
                let lastKeyLen = Int(decompressedIndex[indexOffset])
                indexOffset += 1 + lastKeyLen * charWidth  // NO null terminator
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
        let nullTermLen = charWidth
        let numberWidth = isV2 ? 8 : 4
        
        for blockInfo in keyBlockInfos {
            let compressedBlock = try reader.readBytes(Int(blockInfo.compSize))
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
                
                var keyEnd = blockOffset
                if encoding == .utf16LittleEndian {
                    while keyEnd + 1 < decompressedBlock.count && !(decompressedBlock[keyEnd] == 0 && decompressedBlock[keyEnd + 1] == 0) {
                        keyEnd += 2
                    }
                } else {
                    while keyEnd < decompressedBlock.count && decompressedBlock[keyEnd] != 0 {
                        keyEnd += 1
                    }
                }
                
                if keyEnd == blockOffset { break }
                
                let rawKeyword = String(data: Data(decompressedBlock[blockOffset..<keyEnd]), encoding: encoding) ?? ""
                // Trim whitespace - some dictionaries have trailing spaces in keys
                let keyword = rawKeyword.trimmingCharacters(in: .whitespaces)
                blockOffset = keyEnd + nullTermLen
                
                // Skip empty keywords after trimming
                guard !keyword.isEmpty else { continue }
                
                allKeywords.append(KeywordEntry(keyword: keyword, recordBlockIndex: 0, recordOffset: entryRecordOffset, recordSize: 0))
            }
        }
        
        return KeywordParseResult(keywords: allKeywords)
    }
}

// MARK: - Record Section Parsing

extension MDXParser {
    
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
            _ = try reader.readUInt32BE()  // numEntries
            recordIndexLen = UInt64(try reader.readUInt32BE())
            _ = try reader.readUInt32BE()  // recordBlocksTotalLen
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

// MARK: - Helpers

func encodingFromString(_ str: String) -> String.Encoding {
    switch str.uppercased() {
    case "UTF-16", "UTF-16LE": return .utf16LittleEndian
    case "UTF-16BE": return .utf16BigEndian
    case "GBK", "GB2312", "GB18030": return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    case "BIG5": return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
    default: return .utf8
    }
}
