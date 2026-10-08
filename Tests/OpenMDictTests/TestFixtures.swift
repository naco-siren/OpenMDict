import Foundation

/// Locates the dictionary used by the integration suites.
///
/// Set `MDICT_TEST_FILE` to run the suites against a real dictionary;
/// otherwise the tiny synthetic fixture under `Tests/Fixtures/` is used so
/// that a plain `swift test` passes on a clean clone.
enum TestFixtures {

    /// Directory containing `tiny.mdx` / `tiny.mdd` (resolved from this
    /// source file's location, so it works for `swift test` and Xcode alike).
    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenMDictTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// `MDICT_TEST_FILE` if set and non-empty, else the bundled tiny fixture.
    static var mdxPath: String {
        if let env = ProcessInfo.processInfo.environment["MDICT_TEST_FILE"], !env.isEmpty {
            return env
        }
        return fixturesDirectory.appendingPathComponent("tiny.mdx").path
    }

    /// True when the suites are running against the bundled fixture rather
    /// than a user-supplied dictionary.
    static var isUsingBundledFixture: Bool {
        ProcessInfo.processInfo.environment["MDICT_TEST_FILE"].map(\.isEmpty) ?? true
    }
}
