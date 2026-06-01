//
//  ArticleEmbedPOCRunner.swift
//  OpenMDict-iOS  (M15 Phase 3.0.5 POC)
//
//  Throwaway benchmark driver. Loads the bundled all-MiniLM-L6-v2
//  .mlpackage + vocab.txt, opens the bundled WordNet-EN.mdx, then
//  pumps `sampleCount` articles through the full pipeline and reports
//  detailed per-stage timings.
//
//  Logs every interesting number so we can decide:
//
//    Q1. Does CoreML actually route to ANE (iPad Air 3 / A12) or does
//        it fall back to CPU/GPU?
//          → `inspectComputePlan()` output, see "ANE / GPU / CPU ops"
//
//    Q2. How long would full-dict indexing take on each device class?
//          → "projected total time" line at the end
//
//    Q3. Is 150 MB background memory budget reachable?
//          → peak memory sample lines during run
//
//    Q4. Does sustained ANE/GPU work trigger thermal throttling?
//          → `thermalState` sampled every 100 articles
//
//  All logs go to BOTH `print()` (Xcode console) AND a UI `logHandler`
//  callback (the POC VC dumps them into a UITextView for on-device
//  visibility after disconnecting from Xcode).
//

import Foundation
import OpenMDict   // MDictReader + ArticleEncoder + tokenizer all live in core lib
import UIKit

/// Where to find the .mlpackage / vocab.txt / dict at runtime. Resolved
/// from `Bundle.main` since the POC assets sit in the synced group at
/// `OpenMDict-iOS/POC-Resources/`.
///
/// Phase 3.1 model survey (2026-05-26) picked `all-MiniLM-L6-v2`:
/// 1.7× faster than the 12-layer 33M-param alternatives (MiniLM-L12 /
/// bge-small / gte-small / e5-small all cluster at ~71 ips on Mac;
/// MiniLM-L6 hits 120 ips), 1.5× smaller on disk (43 MB vs 63 MB),
/// AND 3× better discriminative power on word-pair tests (related vs
/// unrelated cos ratio: 3.1× vs 1.1-1.7× for the newer models). The
/// newer models cluster scores in [0.7, 0.95] which kills top-K
/// retrieval ranking quality even though their MTEB passage-retrieval
/// scores are higher in published benchmarks.
struct ArticleEmbedPOCAssets {
    let modelURL: URL
    let vocabURL: URL
    let mdxURL: URL

    /// Async resolve — routes the model + vocab through the ODR-aware
    /// `ArticleIndexAssetProvider` (triggers the ~80 MB download on the
    /// first run if not yet local). `WordNet-EN.mdx` is the POC's test
    /// fixture and stays as a plain bundle resource (not part of the
    /// `article-embed-model` ODR tag).
    ///
    /// `progress` is `@Sendable` because it forwards to the provider's
    /// KVO-driven callback (which runs on an arbitrary queue).
    static func resolveAsync(progress: (@Sendable (Double) -> Void)? = nil) async throws
        -> ArticleEmbedPOCAssets?
    {
        let acquired = try await ArticleIndexAssetProvider.shared.acquire(progress: progress)
        guard let mdx = Bundle.main.url(forResource: "WordNet-EN", withExtension: "mdx")
        else { return nil }
        return ArticleEmbedPOCAssets(
            modelURL: acquired.modelURL,
            vocabURL: acquired.vocabURL,
            mdxURL: mdx
        )
    }

    /// Synchronous existence check for the bundled WordNet fixture only —
    /// used by the POC VC's viewDidLoad to warn if the test MDX is
    /// missing (which would happen if a dev forgot to add it). The
    /// model + vocab presence isn't checked here because ODR makes the
    /// answer async-only.
    static func wordnetMDXLocallyAvailable() -> Bool {
        Bundle.main.url(forResource: "WordNet-EN", withExtension: "mdx") != nil
    }
}

/// Drives one full POC run. Create per-run; not designed to be reused.
@MainActor
final class ArticleEmbedPOCRunner {

    /// Callback invoked for every log line. The POC VC appends to a
    /// UITextView; tests could capture into an array.
    typealias LogHandler = (String) -> Void

    private let logHandler: LogHandler
    private var lineNumber: Int = 0

    init(logHandler: @escaping LogHandler) {
        self.logHandler = logHandler
    }

    func run(assets: ArticleEmbedPOCAssets, sampleCount: Int) async {
        log(banner: "M15 Phase 3.0.5 POC — article embedding throughput")
        log("Started at: \(Date())")
        log("Model: all-MiniLM-L6-v2 (FP16, 22M params, 384-dim) — Phase 3.1 winner")
        log("")

        logEnvironment()
        log("")

        // Step 1: Load encoder (the slow bit on first cold run — CoreML
        // compiles the .mlpackage to .mlmodelc and caches it).
        log(banner: "Step 1 / 4 — Load CoreML encoder + tokenizer")
        let loadStart = Date()
        let encoder: ArticleEncoder
        do {
            encoder = try ArticleEncoder(
                modelPath: assets.modelURL.path,
                vocabPath: assets.vocabURL.path
            )
        } catch {
            log("❌ Load failed: \(error)")
            return
        }
        let loadMs = timeMs(since: loadStart)
        log("Model + tokenizer loaded in \(fmt(loadMs)) ms")
        log("")

        // Step 2: Inspect compute plan — CoreML's answer for "what does
        // ANE actually do for this model on this device".
        log(banner: "Step 2 / 4 — Compute plan (CPU / GPU / ANE routing)")
        if #available(iOS 17.4, *) {
            let planLines = await encoder.inspectComputePlan()
            for line in planLines { log(line) }
        } else {
            log("⚠️ MLComputePlan needs iOS 17.4+ (current: \(UIDevice.current.systemVersion))")
        }
        log("")

        // Step 3: Open the WordNet MDX and pick a deterministic sample.
        log(banner: "Step 3 / 4 — Open WordNet-EN MDX + sample keys")
        let dictOpenStart = Date()
        let reader: MDictReader
        do {
            reader = try MDictReader(path: assets.mdxURL.path)
        } catch {
            log("❌ MDX open failed: \(error)")
            return
        }
        let dictOpenMs = timeMs(since: dictOpenStart)
        log("MDX opened in \(fmt(dictOpenMs)) ms — \(reader.entryCount) total entries")

        // Stride-sample so we test against diverse content lengths, not
        // just the alphabetically-leading "a" prefix.
        let allKeys = reader.allKeys
        let stride = max(1, allKeys.count / sampleCount)
        var sampleKeys: [String] = []
        sampleKeys.reserveCapacity(sampleCount)
        var i = 0
        while i < allKeys.count && sampleKeys.count < sampleCount {
            sampleKeys.append(allKeys[i]); i += stride
        }
        log("Stride-sampled \(sampleKeys.count) keys (step = \(stride))")
        log("")

        // Step 4: The actual benchmark. Per-article timings + periodic
        // memory + thermal sampling.
        log(banner: "Step 4 / 4 — Benchmark loop")

        var perArticle: [Double] = []
        perArticle.reserveCapacity(sampleKeys.count)
        var tokenizeMsTotal: Double = 0
        var encodeMsTotal: Double = 0
        var stripMsTotal: Double = 0

        let loopStart = Date()
        var lastSampleAt = loopStart

        for (idx, key) in sampleKeys.enumerated() {
            // Lookup → strip HTML → tokenize → encode. We separate the
            // sub-stage timings so we can see if e.g. tokenization is the
            // bottleneck on the slow device (it shouldn't be).
            guard let entry = reader.lookup(key) else { continue }
            let html = entry.article.html

            let t1 = Date()
            let plain = Self.stripHTML(html)
            let stripMs = timeMs(since: t1)

            let t2 = Date()
            let tokenized = encoder.tokenizerEncode(plain)
            let tokMs = timeMs(since: t2)

            let t3 = Date()
            do {
                _ = try encoder.encodeFromTokens(tokenized)
            } catch {
                log("[\(idx)/\(sampleKeys.count)] ❌ encode error: \(error)")
                continue
            }
            let encMs = timeMs(since: t3)

            stripMsTotal += stripMs
            tokenizeMsTotal += tokMs
            encodeMsTotal += encMs
            perArticle.append(stripMs + tokMs + encMs)

            // Periodic sample: every 50 articles AND every >2s.
            let now = Date()
            if idx == 0
                || idx % 50 == 0
                || now.timeIntervalSince(lastSampleAt) > 2.0
                || idx == sampleKeys.count - 1
            {
                let memMB = Self.currentMemoryMB()
                let thermal = Self.thermalString()
                let elapsedSec = now.timeIntervalSince(loopStart)
                let articlesPerSec = elapsedSec > 0 ? Double(idx + 1) / elapsedSec : 0
                log(String(format: "  [%4d/%d] last=%5.1fms (strip %4.1f / tok %4.1f / enc %5.1f) mem=%5.1fMB thermal=%@ ips=%5.2f",
                    idx + 1, sampleKeys.count,
                    perArticle.last ?? 0,
                    stripMs, tokMs, encMs,
                    memMB, thermal as NSString,
                    articlesPerSec))
                lastSampleAt = now
            }
        }

        let totalSec = -loopStart.timeIntervalSinceNow

        // Final stats.
        log("")
        log(banner: "Summary")
        let n = perArticle.count
        if n == 0 {
            log("⚠️ No articles processed")
            return
        }
        let sorted = perArticle.sorted()
        func percentile(_ p: Double) -> Double {
            let i = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
            return sorted[i]
        }
        log("Wall clock:       \(fmt(totalSec)) s  for \(n) articles")
        log("Throughput:       \(fmt(Double(n) / totalSec)) articles/sec")
        log("Per-article:")
        log("    min  \(fmt(sorted.first ?? 0)) ms")
        log("    p50  \(fmt(percentile(0.50))) ms")
        log("    p95  \(fmt(percentile(0.95))) ms")
        log("    p99  \(fmt(percentile(0.99))) ms")
        log("    max  \(fmt(sorted.last ?? 0)) ms")
        log("Sub-stage averages:")
        log("    strip HTML  \(fmt(stripMsTotal / Double(n))) ms")
        log("    tokenize    \(fmt(tokenizeMsTotal / Double(n))) ms")
        log("    encode      \(fmt(encodeMsTotal / Double(n))) ms")
        log("Memory peak:      \(fmt(Self.currentMemoryMB())) MB (final sample)")
        log("Thermal final:    \(Self.thermalString())")

        // Project to full WordNet (153,888 entries) — the headline number
        // that tells us "would a full index of THIS dict on THIS device
        // take seconds, minutes, hours?".
        let projectedSec = Double(reader.entryCount) / (Double(n) / totalSec)
        log("")
        log("Projected full-dict index time (\(reader.entryCount) entries):")
        log("    \(fmt(projectedSec / 60)) min  (\(fmt(projectedSec)) s)")
        log("")
        log(banner: "POC complete")
    }

    // MARK: - Env logging

    private func logEnvironment() {
        log(banner: "Environment")
        let device = UIDevice.current
        let proc = ProcessInfo.processInfo
        log("Device:           \(Self.modelIdentifier()) (\(device.name))")
        log("System:           \(device.systemName) \(device.systemVersion)")
        log("Locale:           \(Locale.current.identifier)")
        log("Processors:       \(proc.processorCount) (active \(proc.activeProcessorCount))")
        let memGB = Double(proc.physicalMemory) / 1024.0 / 1024.0 / 1024.0
        log("Physical memory:  \(fmt(memGB)) GB")
        log("Thermal:          \(Self.thermalString())")
        log("Low power mode:   \(proc.isLowPowerModeEnabled)")
        log("Started memory:   \(fmt(Self.currentMemoryMB())) MB")
    }

    /// Hardware model identifier (e.g. "iPad7,5" for iPad 6). Read via
    /// `sysctl(hw.machine)`. `UIDevice.current.model` only gives the
    /// generic "iPad", not the version we need.
    private static func modelIdentifier() -> String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    // MARK: - Logging helpers

    private func log(_ line: String) {
        lineNumber += 1
        let prefix = String(format: "[%4d]  ", lineNumber)
        let formatted = prefix + line
        print(formatted)            // Xcode console
        logHandler(formatted)        // on-device UI
    }

    private func log(banner: String) {
        log("")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("  \(banner)")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    private func timeMs(since: Date) -> Double {
        -since.timeIntervalSinceNow * 1000
    }

    // MARK: - System sampling

    /// Returns the app's resident memory footprint in MB. Uses
    /// `task_vm_info` because `task_basic_info.resident_size` is
    /// notoriously inaccurate (counts dirty memory only); `phys_footprint`
    /// matches Activity Monitor / Xcode debugger figures.
    static func currentMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }

    static func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    /// Cheap HTML → plaintext for POC. Strips tags, decodes a few common
    /// entities, collapses whitespace. Phase 3.1 would replace with a
    /// more thorough WebView-equivalent extraction.
    static func stripHTML(_ html: String) -> String {
        // Drop <script> and <style> blocks entirely.
        let scriptStripped = html.replacingOccurrences(
            of: "<(script|style)[^>]*>.*?</\\1>", with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        // Drop all tags.
        let tagStripped = scriptStripped.replacingOccurrences(
            of: "<[^>]+>", with: " ",
            options: .regularExpression
        )
        // Common entities (not exhaustive — Phase 3.1 task).
        let entityMap: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&copy;": "©",
        ]
        var out = tagStripped
        for (entity, replacement) in entityMap {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse whitespace.
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
