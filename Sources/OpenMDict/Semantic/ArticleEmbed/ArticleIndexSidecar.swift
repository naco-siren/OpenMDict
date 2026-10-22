//
//  ArticleIndexSidecar.swift
//  OpenMDict
//
//  What to do with a sidecar that is already on disk when the app starts:
//  look at its header (`inspect`), decide whether it can stay, must be
//  converted or must be thrown away (`launchAction`), and convert a
//  complete version-1 (dense) index to the current layout without
//  re-encoding anything (`writeCurrentFromDense`).
//
//  Conversion keeps the vectors of the version-1 file: it walks every key,
//  decides from the MDX record whether the key is an article (alias-ness
//  comes from `@@@LINK=`, not from zero rows) and copies the article rows
//  with their key index. The result is byte-identical to a fresh build
//  with the same model, apart from `created_at`, which keeps the time the
//  version-1 build started.
//
//  It is refused when the version-1 rows do not match what the writer
//  produces from these records, because then the vectors themselves are
//  wrong. Writers before 2026-10-20 embedded `lookup(key)` for every key:
//  alias rows held a copy of their target's vector, and every record of a
//  homograph key got the same (first or joined) vector. Such a file shows
//  a non-zero row for an alias or missing record, or two adjacent records
//  of one key with different text but identical rows; it has to be
//  rebuilt.
//

import Foundation

/// What `ArticleIndexSidecar.inspect(_:)` found at a sidecar path.
public enum ArticleIndexSidecarCondition: Equatable, Sendable {
    /// No file.
    case missing
    /// A current-version file whose committed rows fit the file. Complete
    /// or partial: compare `keyCount` with the dictionary's key count.
    case current(ArticleIndexHeader)
    /// A readable version-1 (dense) file.
    case dense(ArticleIndexHeader)
    /// Neither the reader nor the writer can use it: not a sidecar, a
    /// version this build does not know, or a header whose rows do not
    /// fit (corrupt or truncated). The reason is for logs.
    case unusable(String)
}

/// What to do at launch with a dictionary's sidecar.
public enum ArticleIndexSidecarAction: Equatable, Sendable {
    /// Leave it: it is current (complete, or a partial the writer resumes).
    case keep
    /// A complete version-1 index: convert it to the current layout
    /// (`writeCurrentFromDense`). Until that succeeds it is still queried.
    case convert
    /// Delete the file and restart the dictionary's progress at 0 — the
    /// writer would not resume from it, or there is no file.
    case discard
}

/// Why a version-1 index could not be converted.
public enum ArticleIndexConversionError: Error, CustomStringConvertible, Sendable {
    /// The source is not a readable version-1 sidecar.
    case notDense(String)
    /// The source has rows for `keys` keys, the dictionary has `entryCount`.
    case incomplete(keys: Int, entryCount: Int)
    /// The source was built from a different MDX.
    case mdxMismatch
    /// The rows were not written from these records (see the file header):
    /// the index has to be rebuilt.
    case rowsDisagreeWithRecords(keyIndex: Int, reason: String)
    /// The converted file did not read back as expected.
    case validationFailed(String)
    /// Reading the source or writing the destination failed.
    case ioFailed(String)

    /// True when the version-1 index can never be converted and has to be
    /// rebuilt; false for an I/O failure, which a later attempt may not
    /// hit (the version-1 index is still readable meanwhile).
    public var requiresRebuild: Bool {
        if case .ioFailed = self { return false }
        return true
    }

    public var description: String {
        switch self {
        case .notDense(let why): return "not a version-1 sidecar: \(why)"
        case .incomplete(let keys, let total): return "covers \(keys) of \(total) keys"
        case .mdxMismatch: return "built from a different MDX"
        case .rowsDisagreeWithRecords(let i, let why): return "row \(i): \(why)"
        case .validationFailed(let why): return "converted file invalid: \(why)"
        case .ioFailed(let why): return "I/O: \(why)"
        }
    }
}

public enum ArticleIndexSidecar {

    // MARK: - Inspection

    /// Classify the file at `url` from its header and size alone (reads
    /// the first 128 bytes).
    public static func inspect(_ url: URL) -> ArticleIndexSidecarCondition {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .unusable("open failed: \(error)")
        }
        defer { try? handle.close() }
        guard let headerData = try? handle.read(upToCount: ArticleIndexFormat.headerSize),
              let end = try? handle.seekToEnd(),
              let fileSize = Int(exactly: end)
        else { return .unusable("read failed") }
        guard let header = ArticleIndexHeader.parse(headerData) else {
            return .unusable("not a sidecar (magic mismatch or truncated header)")
        }
        let layout = header.checkLayout(fileSize: fileSize)
        guard layout == .ok else { return .unusable("\(layout)") }
        return header.isDense ? .dense(header) : .current(header)
    }

    /// The launch decision for a sidecar in `condition`, whose dictionary
    /// is recorded as fully indexed (`recordIsIndexed`) or not.
    ///
    /// - A current file stays — complete, or a partial the writer resumes.
    /// - A version-1 file of an indexed dictionary is converted. Any other
    ///   version-1 file is a partial, which the writer never resumes
    ///   (format mismatch): it is discarded so the saved progress matches
    ///   the build that will run.
    /// - An unusable file is discarded; so is a missing one (the progress
    ///   restarts at 0, an indexed dictionary is indexed again).
    public static func launchAction(for condition: ArticleIndexSidecarCondition,
                                    recordIsIndexed: Bool) -> ArticleIndexSidecarAction {
        switch condition {
        case .current:
            return .keep
        case .dense:
            return recordIsIndexed ? .convert : .discard
        case .missing, .unusable:
            return .discard
        }
    }

    // MARK: - Conversion

    /// Where `writeCurrentFromDense` should write before the converted file
    /// replaces `sidecarURL`: the same directory (so the rename is atomic),
    /// still ending in `.idx`.
    public static func conversionURL(for sidecarURL: URL) -> URL {
        sidecarURL.deletingPathExtension()
            .appendingPathExtension("converting")
            .appendingPathExtension("idx")
    }

    /// Convert the version-1 index at `url` in place: write the current
    /// layout next to it, validate it, then atomically rename it over
    /// `url`. On error `url` is left as it was.
    @discardableResult
    public static func convertDenseInPlace(at url: URL, reader: MDictReader) throws -> ArticleIndexHeader {
        let temp = conversionURL(for: url)
        do {
            let header = try writeCurrentFromDense(source: url, destination: temp, reader: reader)
            try commitConversion(from: temp, to: url)
            return header
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Atomically replace `url` with the converted file at `temp`.
    public static func commitConversion(from temp: URL, to url: URL) throws {
        guard rename(temp.path, url.path) == 0 else {
            throw ArticleIndexConversionError.ioFailed("rename: errno \(errno)")
        }
    }

    /// Rows read from the source per I/O call during a conversion.
    static let conversionBatchRows = 1024

    /// Write a current-version index of `reader`'s dictionary to
    /// `destination` (replacing anything there) from the complete
    /// version-1 index at `source`, and validate it by reading it back.
    /// Each record block is decompressed once; nothing is encoded. The
    /// source is read sequentially, not mapped, so a writer truncating it
    /// meanwhile makes the conversion fail instead of crashing it.
    public static func writeCurrentFromDense(source: URL, destination: URL,
                                             reader: MDictReader) throws -> ArticleIndexHeader {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw ArticleIndexConversionError.ioFailed("open \(source.lastPathComponent): \(error)")
        }
        defer { try? input.close() }

        guard let headerData = try? input.read(upToCount: ArticleIndexFormat.denseHeaderSize),
              let end = try? input.seekToEnd(), let fileSize = Int(exactly: end)
        else { throw ArticleIndexConversionError.ioFailed("read \(source.lastPathComponent)") }
        guard let dense = ArticleIndexHeader.parse(headerData), dense.isDense else {
            throw ArticleIndexConversionError.notDense("version is not \(ArticleIndexFormat.denseVersion)")
        }
        let layout = dense.checkLayout(fileSize: fileSize)
        guard layout == .ok else { throw ArticleIndexConversionError.notDense("\(layout)") }
        guard let mdxHex = reader.metadata.headerSHA256,
              hexBytes(mdxHex) == dense.mdxHeaderSHA256
        else { throw ArticleIndexConversionError.mdxMismatch }
        let keyTotal = reader.entryCount
        guard Int(dense.keyCount) == keyTotal else {
            throw ArticleIndexConversionError.incomplete(keys: Int(dense.keyCount), entryCount: keyTotal)
        }

        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ArticleIndexConversionError.ioFailed("create \(destination.lastPathComponent)")
        }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch {
            throw ArticleIndexConversionError.ioFailed("open \(destination.lastPathComponent): \(error)")
        }
        defer { try? output.close() }

        let header: ArticleIndexHeader
        do {
            try input.seek(toOffset: UInt64(ArticleIndexFormat.denseHeaderSize))
            try output.write(contentsOf: Data(count: ArticleIndexFormat.headerSize))
            let rowCount = try copyArticleRows(from: input, dense: dense, keyTotal: keyTotal,
                                               reader: reader, to: output)
            header = ArticleIndexHeader(
                modelSHA256: dense.modelSHA256, mdxHeaderSHA256: dense.mdxHeaderSHA256,
                embeddingDim: dense.embeddingDim,
                rowCount: UInt32(rowCount), keyCount: UInt32(keyTotal),
                tokenizerMaxLen: dense.tokenizerMaxLen, createdAt: dense.createdAt
            )
            try output.seek(toOffset: 0)
            try output.write(contentsOf: header.serialize())
            try output.synchronize()
        } catch let error as ArticleIndexConversionError {
            throw error
        } catch {
            throw ArticleIndexConversionError.ioFailed("\(error)")
        }

        // Read the result back the way a query does.
        let check: ArticleIndexReader
        do {
            check = try ArticleIndexReader(sidecarURL: destination)
        } catch {
            throw ArticleIndexConversionError.validationFailed("\(error)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? -1
        guard check.header == header,
              check.validate(expectedModelSHA256: dense.modelSHA256,
                             expectedMDXHeaderSHA256: dense.mdxHeaderSHA256) == .ok,
              size == header.expectedFileSize
        else {
            throw ArticleIndexConversionError.validationFailed(
                "header \(check.header), size \(size) (expected \(header.expectedFileSize ?? -1))")
        }
        return header
    }

    /// Copy the version-1 rows of the articles among keys `0..<keyTotal`,
    /// each behind its key index, to `output`; returns the row count.
    /// Throws `rowsDisagreeWithRecords` when a row cannot have come from
    /// the writer's own walk over these records (see the file header).
    private static func copyArticleRows(from input: FileHandle, dense: ArticleIndexHeader, keyTotal: Int,
                                        reader: MDictReader, to output: FileHandle) throws -> Int {
        let vectorBytes = Int(dense.embeddingDim) * 2
        let records = reader.recordWalker()
        var rowCount = 0
        var pending = Data()
        pending.reserveCapacity(conversionBatchRows * (ArticleIndexFormat.rowKeyIndexSize + vectorBytes))
        // The previous article, for the homograph check.
        var previous: (key: String, html: String, row: Data)?

        var batchStart = 0
        while batchStart < keyTotal {
            let batchCount = min(conversionBatchRows, keyTotal - batchStart)
            guard let batch = try input.read(upToCount: batchCount * vectorBytes),
                  batch.count == batchCount * vectorBytes
            else {
                throw ArticleIndexConversionError.ioFailed("source ended before row \(batchStart + batchCount)")
            }
            for j in 0..<batchCount {
                let i = batchStart + j
                let row = batch.subdata(in: j * vectorBytes ..< (j + 1) * vectorBytes)
                let isZero = row.allSatisfy { $0 == 0 }
                try autoreleasepool {
                    guard let entry = records[i], !ArticleIndexWriter.isRedirect(entry.article.html) else {
                        // An alias or missing record: the writer stores a zero row.
                        guard isZero else {
                            throw ArticleIndexConversionError.rowsDisagreeWithRecords(
                                keyIndex: i, reason: "an alias or missing record has a vector")
                        }
                        return
                    }
                    guard !isZero else {
                        throw ArticleIndexConversionError.rowsDisagreeWithRecords(
                            keyIndex: i, reason: "an article has no vector")
                    }
                    if let previous,
                       previous.key.caseInsensitiveCompare(entry.key) == .orderedSame,
                       previous.row == row,
                       ArticleIndexWriter.stripHTML(previous.html) != ArticleIndexWriter.stripHTML(entry.article.html) {
                        throw ArticleIndexConversionError.rowsDisagreeWithRecords(
                            keyIndex: i, reason: "two records of '\(entry.key)' with different text share a vector")
                    }
                    previous = (entry.key, entry.article.html, row)
                    var keyIndex = UInt32(i).littleEndian
                    withUnsafeBytes(of: &keyIndex) { pending.append(contentsOf: $0) }
                    pending.append(row)
                    rowCount += 1
                }
            }
            if !pending.isEmpty {
                try output.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
            batchStart += batchCount
        }
        return rowCount
    }

    /// Hex string → bytes, nil if it isn't hex.
    private static func hexBytes(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
            i += 2
        }
        return data
    }
}
