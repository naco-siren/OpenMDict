import Foundation
import CryptoKit

// MARK: - Internal Info Structure

/// Internal dictionary info (used by MDXParser)
internal struct MDictInfo {
    let title: String
    let description: String
    let entryCount: Int?
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
    /// Indices into `keywords`, sorted by `keywords[i].keyword.lowercased()`.
    /// Backs both prefix search (binary search → forward scan) and exact
    /// lookup (binary search → tie-break by case). Replaces the per-keyword
    /// `[String: Int]` dictionaries that the slow path used to build.
    private let sortedIndices: [UInt32]

    // MARK: - Initialization

    /// Load a dictionary from file
    /// - Parameter path: Path to .mdx file
    /// - Throws: MDictError on failure
    init(path: String) throws {
        // === Signpost interval: "MDXParser.init" ===
        // Instruments: Points of Interest / os_signpost, subsystem
        // "io.github.naco-siren.openmdict", category "perf". The interval
        // spans header parse + sidecar lookup + (fast path OR slow path).
        // A child event "path" fires with value "fast" or "slow" to
        // attribute time to the right branch.
        let signpostID = mdictPerfSignposter.makeSignpostID()
        let state = mdictPerfSignposter.beginInterval(
            "MDXParser.init",
            id: signpostID,
            "\((path as NSString).lastPathComponent)"
        )
        defer { mdictPerfSignposter.endInterval("MDXParser.init", state) }

        guard FileManager.default.fileExists(atPath: path) else {
            throw MDictError.fileNotFound(path)
        }

        self.reader = try BinaryReader(path: path)

        // Parse header (always needed — cheap, a few KB)
        let (parsedHeader, headerData) = try Self.parseHeaderWithData(reader)
        self.header = parsedHeader

        // Check for unsupported encryption (DRM)
        if header.hasKeywordHeaderEncryption {
            throw MDictError.unsupportedEncryption
        }

        // === Sidecar fast path ===
        // If a sidecar cache directory is configured AND a valid sidecar
        // exists for this MDX, skip the entire decompress/parse/calculate
        // pipeline and load directly from the pre-computed sidecar.
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
            // Fast path: everything came from the sidecar
            mdictPerfSignposter.emitEvent("MDXParser.path", id: signpostID, "fast")
            resolvedKeywords = payload.keywords
            resolvedBlocks = payload.recordBlocks
            resolvedSortedIndices = payload.sortedIndices
        } else {
            // Slow path: full parse
            mdictPerfSignposter.emitEvent("MDXParser.path", id: signpostID, "slow")
            let keywordData = try Self.parseKeywordSection(reader, header: header)
            let blocks = try Self.parseRecordBlockInfo(reader, header: header)
            let kws = Self.calculateRecordInfo(keywords: keywordData.keywords, recordBlocks: blocks)
            let sorted = SidecarWriter.computeSortedIndices(kws)
            resolvedKeywords = kws
            resolvedBlocks = blocks
            resolvedSortedIndices = sorted
        }

        self.keywords = resolvedKeywords
        self.recordBlocks = resolvedBlocks
        self.sortedIndices = resolvedSortedIndices

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

        // === Background sidecar write (only when slow path was used) ===
        // Hand the serialization to `MDictSidecarCache.enqueueWrite`, which
        // either dispatches it immediately (default) or appends to a pending
        // queue that the host app flushes after its initial bulk load
        // (reduces CPU contention with parsing). Captured locals are
        // immutable value types, safe to ferry to another queue.
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
                    // Sidecar write is best-effort: a failure just means the
                    // next launch will go through the slow path again.
                    #if DEBUG
                    print("⚠️ MDXParser: sidecar write failed: \(error)")
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
    
    // MARK: - Lookup API
    
    /// Lookup a keyword and return definition with index
    /// Automatically follows @@@LINK= redirects (up to 2 levels).
    /// MDict spec mandates at most one redirect; a second level is a safety margin for malformed MDX.
    /// - Parameter keyword: The word to look up
    /// - Returns: Tuple of (original keyword, definition, index) or nil if not found
    func lookupWithIndex(_ keyword: String) -> (String, String, Int)? {
        return lookupWithRedirect(keyword, depth: 0)
    }

    /// Internal lookup with redirect following.
    ///
    /// Uses binary search over `sortedIndices` (which is sorted by lowercased
    /// keyword) instead of the previous `[String: Int]` dictionaries. This
    /// is O(log n) per lookup but eliminates the per-init dict construction
    /// (which cost ~50–100ms and ~10–20MB for 300k-entry dictionaries).
    ///
    /// - Parameters:
    ///   - keyword: The word to look up
    ///   - depth: Current redirect depth (to prevent infinite loops)
    /// - Returns: Tuple of (original keyword, definition, index) or nil if not found
    private func lookupWithRedirect(_ keyword: String, depth: Int) -> (String, String, Int)? {
        // Prevent infinite redirect loops (MDict spec: max 1 redirect; allow 2 for safety)
        guard depth < 2 else {
            print("⚠️ MDXParser: Max redirect depth reached for '\(keyword)'")
            return nil
        }

        guard let idx = findKeywordIndex(keyword) else { return nil }
        guard let definition = try? loadRecord(keywords[idx]) else {
            return nil
        }
        return resolveRedirect(
            keyword: keywords[idx].keyword,
            definition: definition,
            index: idx,
            depth: depth
        )
    }

    /// Find the index of a keyword via binary search over `sortedIndices`.
    ///
    /// Semantics preserved from the previous dict-based implementation:
    /// - Case-sensitive dict: only an exact-case match is returned.
    /// - Case-insensitive dict: prefer an exact-case match, otherwise fall
    ///   back to the first case-insensitive match.
    private func findKeywordIndex(_ query: String) -> Int? {
        let loweredQuery = query.lowercased()

        // Binary search for the first sortedIndices position whose
        // lowercased(keyword) >= loweredQuery.
        var lo = 0
        var hi = sortedIndices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let mk = keywords[Int(sortedIndices[mid])].keyword.lowercased()
            if mk < loweredQuery { lo = mid + 1 } else { hi = mid }
        }

        // Walk forward through entries that lowercase to the same string
        // (i.e. ties in case-insensitive ordering).
        var firstLowerMatch: Int? = nil
        var i = lo
        while i < sortedIndices.count {
            let idx = Int(sortedIndices[i])
            let kw = keywords[idx].keyword
            if kw.lowercased() != loweredQuery { break }

            if kw == query {
                return idx  // exact case match always wins
            }
            if firstLowerMatch == nil {
                firstLowerMatch = idx
            }
            i += 1
        }

        // No exact-case hit. Case-insensitive dicts fall back to lowered match.
        return header.keyCaseSensitive ? nil : firstLowerMatch
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
    
    /// Search for keywords with a prefix.
    ///
    /// Uses binary search over `sortedIndices` (sorted by lowercased keyword)
    /// to locate the first match in O(log n), then scans forward sequentially
    /// while keys still share the prefix. Replaces the previous O(n) linear
    /// scan over the entire keyword list.
    ///
    /// Note: although MDX files do not strictly enforce alphabetical key order
    /// in their on-disk layout, `sortedIndices` is built by us during slow-path
    /// parsing (or loaded from sidecar) so binary search is always safe.
    ///
    /// - Parameters:
    ///   - prefix: Prefix to search for
    ///   - limit: Maximum results (default 20)
    /// - Returns: Array of matching keywords (original case preserved)
    func search(prefix: String, limit: Int = 20) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let loweredPrefix = prefix.lowercased()

        // Binary search for first sortedIndices position whose
        // lowercased(keyword) >= loweredPrefix.
        var lo = 0
        var hi = sortedIndices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let mk = keywords[Int(sortedIndices[mid])].keyword.lowercased()
            if mk < loweredPrefix { lo = mid + 1 } else { hi = mid }
        }

        var results: [String] = []
        results.reserveCapacity(min(limit, 100))
        let caseSensitive = header.keyCaseSensitive

        var i = lo
        while i < sortedIndices.count {
            let kw = keywords[Int(sortedIndices[i])].keyword
            let lowerKw = kw.lowercased()
            // Stop as soon as we leave the prefix range.
            guard lowerKw.hasPrefix(loweredPrefix) else { break }

            if caseSensitive {
                // Honour original case-sensitive semantics.
                if kw.hasPrefix(prefix) {
                    results.append(kw)
                    if results.count >= limit { break }
                }
            } else {
                results.append(kw)
                if results.count >= limit { break }
            }
            i += 1
        }
        return results
    }
    
    /// Get suggestions for a keyword (did you mean?).
    ///
    /// 1. **Candidate generation**: tries progressively shorter prefixes (8→1 chars),
    ///    collecting ALL matches across every prefix length (not stopping at the first hit).
    /// 2. **Ranking**: candidates are sorted by Levenshtein edit distance to `keyword`.
    /// 3. **Filtering**: exact matches and candidates beyond a dynamic distance threshold
    ///    are excluded.
    ///
    /// - Parameters:
    ///   - keyword: The word to find suggestions for
    ///   - limit: Maximum suggestions
    /// - Returns: Array of similar keywords, closest matches first
    func suggestions(for keyword: String, limit: Int = 5) -> [ScoredSuggestion] {
        let lower = keyword.lowercased()
        let keyLen = lower.count

        guard keyLen >= 2 else {
            return search(prefix: keyword, limit: limit)
                .map { ScoredSuggestion(word: $0, distance: levenshteinDistance(lower, $0.lowercased())) }
        }

        // Phase 1: Candidate generation
        // Scale prefix search depth with keyword length for better coverage
        let maxPrefixLen = min(keyLen, 8)
        let candidateLimit = limit * 20
        var seen = Set<String>()
        var candidates: [String] = []

        for prefixLen in stride(from: maxPrefixLen, through: 1, by: -1) {
            let prefix = String(lower.prefix(prefixLen))
            for match in search(prefix: prefix, limit: candidateLimit) {
                let key = match.lowercased()
                if seen.insert(key).inserted {
                    candidates.append(match)
                }
            }
            // Stop early once we have a large enough pool from longer prefixes
            if candidates.count >= candidateLimit { break }
        }

        // Phase 2: Rank by Levenshtein edit distance
        let maxDist = max(keyLen / 2, 2)
        let ranked = candidates
            .map { ScoredSuggestion(word: $0, distance: levenshteinDistance(lower, $0.lowercased())) }
            .filter { $0.distance > 0 && $0.distance <= maxDist }
            .sorted { $0.distance < $1.distance }

        return Array(ranked.prefix(limit))
    }
    
    // MARK: - Private: Record Loading
    
    private func loadRecord(_ entry: KeywordEntry) throws -> String {
        let blockInfo = recordBlocks[entry.recordBlockIndex]

        // Atomic seek+read: thread-safe for concurrent loadRecord calls
        let compressedData = try reader.atomicRead(
            at: blockInfo.fileOffset,
            count: Int(blockInfo.compressedSize)
        )

        guard compressedData.count >= 8 else {
            throw MDictError.invalidFormat("MDX record block too small: \(compressedData.count) bytes")
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

/// Result of reading header with raw data for hashing
internal struct MDictInfoWithRawHeader {
    let info: MDictInfo
    /// Raw header bytes (for SHA256 hash calculation)
    let headerData: Data
}

extension MDXParser {
    
    /// Read only the header without parsing keywords (fast)
    /// Used for displaying dictionary list without full loading
    static func readHeaderOnly(path: String) -> MDictInfo? {
        readHeaderOnlyWithData(path: path)?.info
    }
    
    /// Read header and return both parsed info and raw header data
    /// The raw header data is used for SHA256 hash calculation (duplicate detection)
    static func readHeaderOnlyWithData(path: String) -> MDictInfoWithRawHeader? {
        guard FileManager.default.fileExists(atPath: path),
              let reader = try? BinaryReader(path: path) else {
            return nil
        }
        
        guard let (header, headerData) = try? parseHeaderWithData(reader) else {
            return nil
        }
        
        // We can't know the exact entry count without parsing keywords,
        let info = MDictInfo(
            title: header.title,
            description: header.description,
            entryCount: nil,  // Unknown without full parse
            format: header.format,
            encoding: header.encoding,
            engineVersion: header.generatedByEngineVersion,
            creationDate: header.creationDate,
            isEncrypted: header.encrypted != 0,
            isCaseSensitive: header.keyCaseSensitive
        )
        
        return MDictInfoWithRawHeader(info: info, headerData: headerData)
    }
    
    /// Parse header and return both the parsed struct and raw bytes
    static func parseHeaderWithData(_ reader: BinaryReader) throws -> (MDictHeader, Data) {
        let headerLen = try reader.readUInt32BE()
        let headerBytes = try reader.readBytes(Int(headerLen))
        _ = try reader.readUInt32LE()  // adler32
        
        let headerData = Data(headerBytes)
        
        let headerStr: String
        if headerBytes.count >= 2 && headerBytes[0] == 0xFF && headerBytes[1] == 0xFE {
            headerStr = String(data: headerData, encoding: .utf16LittleEndian) ?? ""
        } else if headerBytes.count >= 2 && headerBytes.suffix(2) == Data([0x00, 0x00]) {
            headerStr = String(data: Data(headerBytes.dropLast(2)), encoding: .utf16LittleEndian) ?? ""
        } else {
            headerStr = String(data: headerData, encoding: .utf8) ?? ""
        }
        
        return (parseHeaderXML(headerStr), headerData)
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

        /// Some MDX files embed HTML tags (e.g. `<h1>`) in attribute values.
        /// Strip them at the parser level so all consumers receive plain text.
        func stripHTML(_ value: String) -> String {
            value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                 .trimmingCharacters(in: .whitespacesAndNewlines)
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
            title: stripHTML(attr("Title")),
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
            guard keyIndexData.count >= 8 else {
                throw MDictError.invalidFormat("MDX key-index data too small: \(keyIndexData.count) bytes")
            }
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
            guard compressedBlock.count >= 8 else {
                throw MDictError.invalidFormat("MDX keyword block too small: \(compressedBlock.count) bytes")
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
