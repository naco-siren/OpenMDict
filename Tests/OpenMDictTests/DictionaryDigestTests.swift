import Testing
import Foundation
import CryptoKit
@testable import OpenMDict

/// Opt-in golden-digest test for parser/decoder refactors.
///
/// Walks every entry and every MDD resource of each listed dictionary and
/// prints one SHA-256 line per file. Run it once before a refactor and once
/// after; the digests must not change. Disabled unless `MDICT_DIGEST_DICTS`
/// is set, because it needs real (often licensed) dictionaries and can take
/// minutes on large ones.
///
///     MDICT_DIGEST_DICTS="a.mdx:b.mdx" MDICT_DIGEST_OUT=/tmp/digest.txt \
///         swift test -c release --filter DictionaryDigestTests
@Suite(.serialized)
struct DictionaryDigestTests {

    @Test("Digest every entry and resource of each configured dictionary")
    func digestConfiguredDictionaries() throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["MDICT_DIGEST_DICTS"], !list.isEmpty else {
            return  // opt-in only
        }
        let saved = MDictSidecarCache.cacheDirectory
        MDictSidecarCache.cacheDirectory = nil
        defer { MDictSidecarCache.cacheDirectory = saved }

        var lines: [String] = []
        for path in list.split(separator: ":").map(String.init) {
            let started = Date()
            let reader = try MDictReader(path: path)
            var hasher = SHA256()
            var htmlBytes = 0
            for index in 0..<reader.entryCount {
                guard let entry = reader[index] else {
                    hasher.update(data: Data("<nil \(index)>".utf8))
                    continue
                }
                hasher.update(data: Data(entry.key.utf8))
                hasher.update(data: Data([0]))
                let html = Data(entry.article.html.utf8)
                htmlBytes += html.count
                hasher.update(data: html)
                hasher.update(data: Data([10]))
            }
            var resourceBytes = 0
            for resourcePath in reader.allResourcePaths.sorted() {
                hasher.update(data: Data(resourcePath.utf8))
                hasher.update(data: Data([0]))
                if let data = reader.resource(for: resourcePath) {
                    resourceBytes += data.count
                    hasher.update(data: data)
                } else {
                    hasher.update(data: Data("<nil>".utf8))
                }
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            let line = "\(hex)  entries=\(reader.entryCount) html=\(htmlBytes)B "
                + "resources=\(reader.allResourcePaths.count)/\(resourceBytes)B \(elapsed)  \(path)"
            print(line)
            lines.append(line)
            #expect(reader.entryCount > 0, "\(path) has no entries")
        }
        if let out = env["MDICT_DIGEST_OUT"] {
            try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
