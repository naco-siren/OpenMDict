//
//  MDDResourceExtractor.swift
//  OpenMDict-ActionExtension
//
//  Extracts MDD resources referenced in article HTML and caches them to disk.
//  Designed for phased memory usage: MDX reader is released BEFORE MDD parsers are created.
//
//  Lifecycle:
//    1. MDictReader(path:) — MDX only, no MDD
//    2. reader.lookup() → html strings
//    3. reader deinit — MDX index freed
//    4. extractResourcePaths(from: html) — lightweight regex, no parser needed
//    5. MDDParser(path:) per MDD file — MDD index loaded
//    6. extractAndCache() — each resource read → write disk → Data freed
//    7. MDDParsers deinit — MDD index freed
//

import Foundation
import OpenMDict

/// Extracts MDD resources from article HTML and writes them to the App Group
/// `Library/Caches/MDD/` directory so the scheme handler can serve them from disk.
nonisolated enum MDDResourceExtractor {

    /// Cache root: `AppGroup/Library/Caches/MDD/`
    static let cacheRootURL: URL = {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier
        ) else {
            fatalError("App Group container unavailable")
        }
        return groupURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("MDD", isDirectory: true)
    }()

    /// Extract resources referenced in HTML from MDD parsers and write to disk cache.
    ///
    /// Uses `MDDParser` directly (not `MDictReader`) so the caller can release
    /// the MDX reader before loading MDD indexes — they never coexist in memory.
    ///
    /// - Parameters:
    ///   - resourcePaths: Resource paths extracted from HTML (via `HTMLResourceRewriter.extractResourcePaths`)
    ///   - mddParsers: MDD parser instances (one per .mdd file)
    ///   - dictId: Dictionary ID for partitioning the cache
    /// - Returns: Number of resources newly extracted and cached
    @discardableResult
    static func extractAndCache(
        resourcePaths: Set<String>,
        mddParsers: [MDDParser],
        dictId: String
    ) -> Int {
        guard !resourcePaths.isEmpty, !mddParsers.isEmpty else { return 0 }

        let dictCacheDir = cacheRootURL.appendingPathComponent(dictId, isDirectory: true)
        print("🗂️ MDD cache dir: \(dictCacheDir.path)")
        var extractedCount = 0
        var skippedCached = 0
        var notFoundInMDD = 0

        for path in resourcePaths {
            // Normalize: remove leading slash for file path
            let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard !cleanPath.isEmpty else { continue }

            let destURL = dictCacheDir.appendingPathComponent(cleanPath)

            // Skip if already cached on disk
            if FileManager.default.fileExists(atPath: destURL.path) {
                skippedCached += 1
                continue
            }

            // Try multiple path variations against each MDD parser
            let pathsToTry = [
                path,                                                            // as-is
                path.hasPrefix("/") ? String(path.dropFirst()) : path,           // without leading /
                "\\" + (path.hasPrefix("/") ? String(path.dropFirst()) : path)   // MDD backslash format
            ]

            var data: Data?
            outer: for parser in mddParsers {
                for tryPath in pathsToTry {
                    if let d = parser.lookup(tryPath) {
                        data = d
                        break outer
                    }
                }
            }

            guard let resourceData = data else {
                notFoundInMDD += 1
                print("🗂️ ✗ NOT in MDD: '\(path)' (tried: \(pathsToTry))")
                continue
            }

            // Create intermediate directories
            let parentDir = destURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )

            // Write to disk (atomic to avoid partial writes), then resourceData is freed
            do {
                try resourceData.write(to: destURL, options: .atomic)
                extractedCount += 1
                print("🗂️ ✓ cached: '\(cleanPath)' (\(resourceData.count) bytes)")
            } catch {
                print("🗂️ ✗ write failed: '\(cleanPath)' error=\(error)")
            }
        }

        print("🗂️ Summary: extracted=\(extractedCount), skippedCached=\(skippedCached), notFoundInMDD=\(notFoundInMDD)")

        return extractedCount
    }
}
