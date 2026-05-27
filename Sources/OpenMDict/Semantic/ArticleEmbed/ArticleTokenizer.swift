//
//  ArticleTokenizer.swift
//  OpenMDictCLI
//
//  M15 Phase 3.0 — WordPiece tokenizer (BERT-uncased variant) for feeding
//  text into a sentence-transformer CoreML model. Pure Swift, no
//  dependencies. Intentionally minimal: covers what `all-MiniLM-L6-v2`
//  needs (English-only, lowercased, no accent stripping yet, no CJK
//  per-char segmentation). When Phase 3.1 picks the production model
//  (multilingual or otherwise), expand here.
//
//  Pipeline mirrors HuggingFace `BertTokenizer(do_lower_case=True)`:
//
//    1. lowercase + strip control chars
//    2. whitespace split
//    3. punctuation split (each punct becomes its own token)
//    4. greedy longest-match WordPiece against vocab.txt
//    5. wrap with [CLS] … [SEP], pad to max_length with [PAD]
//
//  Output: `Tokenized` = (inputIds, attentionMask). Caller feeds both
//  into the CoreML model.
//

import Foundation

/// Tokenized output ready for the CoreML model. Shapes match the
/// `input_ids` / `attention_mask` 2D tensors most BERT-family
/// conversions expect: 1 × maxLen Int32, zero-padded.
public struct Tokenized {
    /// Token IDs, length == maxLength. Padded with the vocab's [PAD] id.
    public let inputIds: [Int32]
    /// Attention mask, length == maxLength. 1 for real tokens, 0 for padding.
    public let attentionMask: [Int32]
    /// Number of real (non-padding) tokens including [CLS] and [SEP].
    public let actualLength: Int
}

/// Minimal BERT-uncased WordPiece tokenizer.
///
/// Loaded once with a vocab file (a vocab.txt with one token per line,
/// 0-indexed) and reused per query. Cheap — ~30k strings + a dictionary,
/// a few MB resident.
public final class ArticleTokenizer {

    private let vocab: [String: Int32]
    private let unkId: Int32
    private let clsId: Int32
    private let sepId: Int32
    private let padId: Int32
    /// "##" prefix for subsequent WordPiece subwords. Stored as raw scalar
    /// values so the tight-loop scanner avoids repeated String comparisons.
    private static let continuationPrefix = "##"

    /// Maximum sequence length including [CLS] and [SEP]. Anything longer
    /// gets truncated. 128 is the default for sentence-transformer models;
    /// MiniLM was trained at 128, going past hurts quality.
    public let maxLength: Int

    /// Load vocab.txt — one token per line, 0-indexed. Caller passes the
    /// path to the file bundled alongside the model package.
    public init(vocabPath: String, maxLength: Int = 128) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: vocabPath)),
              let text = String(data: data, encoding: .utf8) else {
            throw ArticleTokenizerError.vocabLoadFailed(vocabPath)
        }

        var dict: [String: Int32] = [:]
        var idx: Int32 = 0
        text.enumerateLines { line, _ in
            // BERT vocab files conventionally have no leading/trailing whitespace
            // in tokens; we trim defensively in case of CRLF line endings.
            let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                dict[token] = idx
            }
            idx += 1
        }

        guard let unk = dict["[UNK]"],
              let cls = dict["[CLS]"],
              let sep = dict["[SEP]"],
              let pad = dict["[PAD]"] else {
            throw ArticleTokenizerError.missingSpecialTokens
        }

        self.vocab = dict
        self.unkId = unk
        self.clsId = cls
        self.sepId = sep
        self.padId = pad
        self.maxLength = maxLength
    }

    /// Encode arbitrary input text. Truncates to `maxLength - 2` real tokens
    /// (leaving room for [CLS] and [SEP]). Pads to `maxLength`.
    public func encode(_ text: String) -> Tokenized {
        let pieces = wordpieceTokenize(text)

        // -2 for [CLS] and [SEP].
        let truncated = pieces.count > maxLength - 2
            ? Array(pieces.prefix(maxLength - 2))
            : pieces

        var ids: [Int32] = []
        ids.reserveCapacity(maxLength)
        var mask: [Int32] = []
        mask.reserveCapacity(maxLength)

        ids.append(clsId); mask.append(1)
        for p in truncated {
            ids.append(vocab[p] ?? unkId)
            mask.append(1)
        }
        ids.append(sepId); mask.append(1)

        let actual = ids.count
        while ids.count < maxLength {
            ids.append(padId)
            mask.append(0)
        }

        return Tokenized(inputIds: ids, attentionMask: mask, actualLength: actual)
    }

    // MARK: - Tokenization pipeline

    /// Step 1+2+3: lowercase, whitespace-split, punctuation-split.
    /// Returns the list of "basic" tokens before WordPiece subword splitting.
    private func basicTokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var tokens: [String] = []
        var current = ""

        for scalar in lowered.unicodeScalars {
            // Drop control chars (\u{0000}..\u{001F}, \u{007F}). Replace nothing,
            // they're just noise from HTML extraction.
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }

            if isWhitespace(scalar) {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }

            if isPunctuation(scalar) {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(scalar))
                continue
            }

            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Step 4: greedy longest-match WordPiece. Each input token gets split
    /// into the longest matching subword pieces in the vocab. Subsequent
    /// pieces are prefixed with "##". If no match is found, the whole token
    /// becomes [UNK].
    private func wordpieceTokenize(_ text: String) -> [String] {
        var out: [String] = []
        for word in basicTokenize(text) {
            let chars = Array(word)
            if chars.count > 200 {
                // BERT's default: skip very long tokens (URLs, random data).
                out.append("[UNK]")
                continue
            }

            var subTokens: [String] = []
            var start = 0
            var failed = false
            while start < chars.count {
                var end = chars.count
                var found: String? = nil
                while start < end {
                    let piece: String = start == 0
                        ? String(chars[start..<end])
                        : Self.continuationPrefix + String(chars[start..<end])
                    if vocab[piece] != nil {
                        found = piece
                        break
                    }
                    end -= 1
                }
                guard let f = found else { failed = true; break }
                subTokens.append(f)
                start = end
            }

            if failed {
                out.append("[UNK]")
            } else {
                out.append(contentsOf: subTokens)
            }
        }
        return out
    }

    // MARK: - Character classification

    /// Matches BERT's `_is_whitespace`: ASCII whitespace + the Unicode whitespace
    /// category Zs. We use Foundation's set for compactness.
    private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Matches BERT's `_is_punctuation`: ASCII punctuation U+0021–U+002F /
    /// U+003A–U+0040 / U+005B–U+0060 / U+007B–U+007E, plus the Unicode
    /// punctuation categories (P*). The ASCII-range explicit listing
    /// matters because some chars (e.g. `_`) are in P but BERT also
    /// treats them as punctuation regardless.
    private func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (0x21...0x2F).contains(v)
            || (0x3A...0x40).contains(v)
            || (0x5B...0x60).contains(v)
            || (0x7B...0x7E).contains(v) {
            return true
        }
        return CharacterSet.punctuationCharacters.contains(scalar)
    }
}

public enum ArticleTokenizerError: Error, CustomStringConvertible {
    case vocabLoadFailed(String)
    case missingSpecialTokens

    public var description: String {
        switch self {
        case .vocabLoadFailed(let p): return "Failed to load vocab file at \(p)"
        case .missingSpecialTokens:   return "vocab.txt is missing one of [UNK]/[CLS]/[SEP]/[PAD]"
        }
    }
}
