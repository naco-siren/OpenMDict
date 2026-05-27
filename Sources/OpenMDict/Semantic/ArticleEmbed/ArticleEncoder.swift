//
//  ArticleEncoder.swift
//  OpenMDict  (M15 Phase 3)
//
//  CoreML wrapper around a sentence-transformer model. Loads
//  .mlpackage / .mlmodelc, auto-detects token-level vs sentence-level
//  output, mean-pools by attention mask, L2-normalizes. Lives in the
//  `OpenMDict` core lib (alongside the MDX parser) — not in
//  `OpenMDictKit`, which is reserved for GUI-binding ViewModels.
//  CoreML / Accelerate are Apple-platform-wide frameworks (not
//  GUI-only like UIKit), so they're acceptable in the core lib. Both
//  the CLI (offline pre-indexing) and the iOS app's ArticleIndexCoordinator
//  (on-device incremental indexing) import this from OpenMDict directly.
//
//  The interesting addition for the POC is `inspectComputePlan()`,
//  which uses `MLComputePlan` (iOS 17.4+) to report exactly which ops
//  the framework intends to route to ANE vs GPU vs CPU. Without that,
//  we'd only know what we *requested* (`.all`), not what we got.
//
//  Input shape:
//    input_ids       (1, maxLen) Int32
//    attention_mask  (1, maxLen) Int32
//
//  Output shape (auto-detected at first prediction):
//    EITHER (1, hiddenDim)         — already sentence-pooled
//    OR     (1, maxLen, hiddenDim) — token-level, we mean-pool here
//
//  After mean-pooling (if needed) we L2-normalize so cosine similarity
//  with another normalized vector is just a dot product.
//
//  CoreML config: `.all` — let the framework auto-route to Neural Engine
//  if available, else GPU, else CPU. iPad 6 (A10, no ANE) will route
//  everything to CPU/GPU; iPad Air 3 (A12, 1st-gen ANE) should land
//  most of the transformer ops on ANE.
//

import Foundation
import CoreML

/// Loaded model + tokenizer pair. Construct once, reuse across many
/// `encode` calls. Thread-safe for concurrent `encode` invocations —
/// MLModel is documented thread-safe by Apple. Marked `@unchecked
/// Sendable` so we can pass it into background Tasks; the only
/// non-Sendable bits are the dim detection flags, which are
/// monotonically set on first call and not mutated thereafter.
public final class ArticleEncoder: @unchecked Sendable {

    private let model: MLModel
    private let tokenizer: ArticleTokenizer
    private let inputIdsKey: String
    private let attentionMaskKey: String
    private let outputKey: String
    /// Compiled model location + config retained so we can re-inspect the
    /// model graph after init (e.g. `MLComputePlan` for compute-unit
    /// routing reports). Reading the model file twice is cheap relative
    /// to the actual conversion.
    private let compiledURL: URL
    private let config: MLModelConfiguration

    /// Number of output dimensions. Detected at first `encode` from the
    /// model's `modelDescription` output schema, then frozen.
    public private(set) var dimension: Int = 0

    /// Set to true after first `encode` if the model output is 3D
    /// (token-level) and needs mean-pooling. Set to false if the model
    /// already pools internally.
    private var needsMeanPool: Bool = false

    /// Load a compiled `.mlmodelc` directory or an uncompiled `.mlpackage`
    /// (the framework compiles on-the-fly). Vocab is loaded eagerly so
    /// startup errors surface immediately.
    public init(modelPath: String, vocabPath: String, maxLength: Int = 128) throws {
        let modelURL = URL(fileURLWithPath: modelPath)

        // .mlpackage / .mlmodel both need compilation; .mlmodelc is already compiled.
        let compiledURL: URL
        if modelPath.hasSuffix(".mlmodelc") {
            compiledURL = modelURL
        } else {
            compiledURL = try MLModel.compileModel(at: modelURL)
        }

        let config = MLModelConfiguration()
        // .all = framework picks ANE / GPU / CPU per op. For sentence
        // transformers this almost always ends up on ANE on iPhone,
        // GPU/CPU on Mac. .cpuAndGPU is a safer fallback if ANE
        // compilation flakes out on a specific iOS version.
        config.computeUnits = .all
        self.compiledURL = compiledURL
        self.config = config
        self.model = try MLModel(contentsOf: compiledURL, configuration: config)

        // Resolve the input/output feature names. Sentence-transformer
        // exports vary in naming — some use "input_ids", some "inputIds",
        // some idiosyncratic names. We match by shape/type, not name.
        let desc = self.model.modelDescription
        let inputs = desc.inputDescriptionsByName
        let outputs = desc.outputDescriptionsByName

        // Two MLMultiArray inputs of equal shape → input_ids + attention_mask.
        // Identify which is which by name heuristic (most models name them
        // exactly "input_ids" and "attention_mask"), falling back to
        // alphabetical order.
        let inputNames = inputs.keys.sorted()
        var idsKey: String?
        var maskKey: String?
        for name in inputNames {
            if name.lowercased().contains("input") {
                idsKey = name
            } else if name.lowercased().contains("mask") {
                maskKey = name
            }
        }
        guard let idsKey, let maskKey else {
            throw ArticleEncoderError.unrecognizedInputSchema(Array(inputs.keys))
        }
        self.inputIdsKey = idsKey
        self.attentionMaskKey = maskKey

        // Pick the first (or any single) MLMultiArray output. Some models
        // expose multiple outputs (pooled + token-level); prefer the one
        // whose name contains "embedding" / "pooled" / "sentence".
        let outputNames = outputs.keys.sorted()
        var picked: String?
        for keyword in ["sentence", "pooled", "embedding"] {
            picked = outputNames.first(where: { $0.lowercased().contains(keyword) })
            if picked != nil { break }
        }
        self.outputKey = picked ?? outputNames.first ?? ""
        guard !self.outputKey.isEmpty else {
            throw ArticleEncoderError.unrecognizedOutputSchema(Array(outputs.keys))
        }

        self.tokenizer = try ArticleTokenizer(vocabPath: vocabPath, maxLength: maxLength)
    }

    /// Tokenize-only — exposed so callers can measure tokenize/encode
    /// stages separately (POC sub-stage timing).
    public func tokenizerEncode(_ text: String) -> Tokenized {
        tokenizer.encode(text)
    }

    /// Run the model + mean-pool + L2-normalize, given pre-tokenized
    /// input. The POC runner uses this to time the encoder in isolation.
    public func encodeFromTokens(_ tok: Tokenized) throws -> [Float] {
        try encodeInternal(tok)
    }

    /// Tokenize, run the encoder, mean-pool (if needed), L2-normalize.
    /// Returns a 1D vector of length `dimension`.
    public func encode(_ text: String) throws -> [Float] {
        let tok = tokenizer.encode(text)
        return try encodeInternal(tok)
    }

    private func encodeInternal(_ tok: Tokenized) throws -> [Float] {
        let maxLen = tokenizer.maxLength

        // Build MLMultiArray inputs. Int32 is what BERT-family conversions
        // expect; some older conversions want Int64 — we'll add a fallback
        // only if a real model needs it.
        let shape: [NSNumber] = [1, NSNumber(value: maxLen)]
        let inputIds = try MLMultiArray(shape: shape, dataType: .int32)
        let attentionMask = try MLMultiArray(shape: shape, dataType: .int32)
        for i in 0..<maxLen {
            inputIds[i] = NSNumber(value: tok.inputIds[i])
            attentionMask[i] = NSNumber(value: tok.attentionMask[i])
        }

        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
            inputIdsKey: MLFeatureValue(multiArray: inputIds),
            attentionMaskKey: MLFeatureValue(multiArray: attentionMask),
        ])

        let outputProvider = try model.prediction(from: inputProvider)
        guard let outArray = outputProvider.featureValue(for: outputKey)?.multiArrayValue else {
            throw ArticleEncoderError.predictionMissingOutput(outputKey)
        }

        // Output shape determines whether we mean-pool.
        // (1, dim)             → already sentence-level, just normalize
        // (1, seqLen, dim)     → token-level, mean-pool by attention mask
        let outShape = outArray.shape.map { $0.intValue }
        let vec: [Float]
        if outShape.count == 2 {
            self.dimension = outShape[1]
            vec = Self.extractRow(outArray, dim: self.dimension)
            self.needsMeanPool = false
        } else if outShape.count == 3 {
            self.dimension = outShape[2]
            vec = Self.meanPool(outArray, seqLen: outShape[1], dim: self.dimension, mask: tok.attentionMask)
            self.needsMeanPool = true
        } else {
            throw ArticleEncoderError.unexpectedOutputRank(outShape)
        }

        return Self.l2Normalize(vec)
    }

    // MARK: - Numeric helpers

    /// Extract a contiguous 1×D row from an MLMultiArray. Assumes the
    /// array's dataType is .float32 (the standard CoreML output for
    /// transformer encoders).
    private static func extractRow(_ array: MLMultiArray, dim: Int) -> [Float] {
        // MLMultiArray.dataPointer is row-major; for (1, D) the first D
        // floats are exactly what we want.
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: dim)
        return Array(UnsafeBufferPointer(start: ptr, count: dim))
    }

    /// Mean-pool a (1, seqLen, dim) token-level output using the attention
    /// mask. This is what `sentence-transformers` does on the Python side
    /// when the model itself doesn't include a Pooling layer in CoreML.
    private static func meanPool(_ array: MLMultiArray, seqLen: Int, dim: Int, mask: [Int32]) -> [Float] {
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: seqLen * dim)
        var sums = [Float](repeating: 0, count: dim)
        var validCount: Float = 0
        for t in 0..<seqLen {
            guard mask[t] == 1 else { continue }
            validCount += 1
            let base = t * dim
            for d in 0..<dim {
                sums[d] += ptr[base + d]
            }
        }
        guard validCount > 0 else { return sums }
        for d in 0..<dim {
            sums[d] /= validCount
        }
        return sums
    }

    /// L2-normalize in place-conceptually (returns a new array). For
    /// pre-normalized cosine, a dot product of two normalized vectors
    /// equals their cosine similarity.
    private static func l2Normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - Public similarity helper

    /// Cosine similarity between two L2-normalized vectors = dot product.
    /// Caller is responsible for using vectors from `encode`, which
    /// already normalizes.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vector dim mismatch")
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    // MARK: - POC: Compute plan inspection

    /// Walk the model graph and report which compute unit (ANE/GPU/CPU)
    /// CoreML actually plans to use for each op. This is the answer to
    /// "did ANE routing actually happen, or did everything fall back to
    /// CPU?" — without this, we'd only know what we *requested* via
    /// `MLModelConfiguration.computeUnits = .all`, not what we got.
    ///
    /// iOS 17.4+ only. Both POC target devices (iPadOS 17 / 18) qualify.
    @available(iOS 17.4, macOS 14.4, *)
    public func inspectComputePlan() async -> [String] {
        var out: [String] = []
        // Build a fresh MLModelConfiguration locally rather than capturing
        // self.config — MLModelConfiguration is not Sendable, so passing
        // it across the `await MLComputePlan.load` boundary trips Swift 6
        // strict concurrency. The local config has the same settings.
        let inspectConfig = MLModelConfiguration()
        inspectConfig.computeUnits = .all
        let url = compiledURL  // URL is Sendable, fine to capture
        do {
            let plan = try await MLComputePlan.load(
                contentsOf: url, configuration: inspectConfig
            )
            out.append("✓ MLComputePlan loaded")

            var totalOps = 0
            var aneOps = 0
            var gpuOps = 0
            var cpuOps = 0
            var unknownOps = 0
            var opNamesByDevice: [String: [String: Int]] = [
                "ANE": [:], "GPU": [:], "CPU": [:], "?": [:],
            ]

            // mlprogram format: structure.program.functions[name].block.operations
            switch plan.modelStructure {
            case .program(let program):
                for (funcName, function) in program.functions {
                    out.append("  Function: \(funcName)")
                    Self.walkBlock(
                        function.block, plan: plan,
                        totalOps: &totalOps,
                        aneOps: &aneOps, gpuOps: &gpuOps,
                        cpuOps: &cpuOps, unknownOps: &unknownOps,
                        opNamesByDevice: &opNamesByDevice
                    )
                }
            default:
                out.append("  ⚠️ structure is not .program; can't break down")
            }

            func pct(_ n: Int, _ total: Int) -> String {
                guard total > 0 else { return "0%" }
                return String(format: "%.1f%%", Double(n) / Double(total) * 100)
            }

            out.append("")
            out.append("  Total ops: \(totalOps)")
            out.append("    → ANE:  \(aneOps)  (\(pct(aneOps, totalOps)))")
            out.append("    → GPU:  \(gpuOps)  (\(pct(gpuOps, totalOps)))")
            out.append("    → CPU:  \(cpuOps)  (\(pct(cpuOps, totalOps)))")
            if unknownOps > 0 {
                out.append("    → ?:    \(unknownOps)  (\(pct(unknownOps, totalOps)))")
            }

            // Top op-name breakdown per device — useful to see "which kinds
            // of ops fell back from ANE to CPU". E.g. if 'gelu' is all CPU
            // but 'matmul' is all ANE, that's the typical pre-A14 pattern.
            for device in ["ANE", "GPU", "CPU"] {
                let counts = opNamesByDevice[device] ?? [:]
                guard !counts.isEmpty else { continue }
                let top = counts.sorted { $0.value > $1.value }.prefix(8)
                let summary = top.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
                out.append("  \(device) ops: \(summary)")
            }
        } catch {
            out.append("❌ Failed to load MLComputePlan: \(error)")
        }
        return out
    }

    /// Recursive op walker. mlprogram blocks can nest (e.g. control flow
    /// ops contain sub-blocks), so this is recursive.
    @available(iOS 17.4, macOS 14.4, *)
    private static func walkBlock(
        _ block: MLModelStructure.Program.Block,
        plan: MLComputePlan,
        totalOps: inout Int,
        aneOps: inout Int, gpuOps: inout Int,
        cpuOps: inout Int, unknownOps: inout Int,
        opNamesByDevice: inout [String: [String: Int]]
    ) {
        for op in block.operations {
            totalOps += 1
            let device = classify(plan.deviceUsage(for: op)?.preferred)
            switch device {
            case "ANE": aneOps += 1
            case "GPU": gpuOps += 1
            case "CPU": cpuOps += 1
            default:    unknownOps += 1
            }
            let key = device
            opNamesByDevice[key, default: [:]][op.operatorName, default: 0] += 1
        }
    }

    /// Map `MLComputeDevice` to a short device tag for tally tables.
    @available(iOS 17.4, macOS 14.4, *)
    private static func classify(_ device: MLComputeDevice?) -> String {
        guard let device else { return "?" }
        switch device {
        case .cpu:           return "CPU"
        case .gpu:           return "GPU"
        case .neuralEngine:  return "ANE"
        @unknown default:    return "?"
        }
    }
}

public enum ArticleEncoderError: Error, CustomStringConvertible {
    case unrecognizedInputSchema([String])
    case unrecognizedOutputSchema([String])
    case predictionMissingOutput(String)
    case unexpectedOutputRank([Int])

    public var description: String {
        switch self {
        case .unrecognizedInputSchema(let names):
            return "CoreML model has inputs \(names); expected something like input_ids + attention_mask"
        case .unrecognizedOutputSchema(let names):
            return "CoreML model has outputs \(names); could not pick a sentence-embedding tensor"
        case .predictionMissingOutput(let name):
            return "CoreML prediction did not return output named \(name)"
        case .unexpectedOutputRank(let shape):
            return "CoreML model output has shape \(shape); expected rank 2 (1,D) or 3 (1,L,D)"
        }
    }
}
