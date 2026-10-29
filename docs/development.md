# Development guide

Building the package and the iOS app from source, running the tests, and
signing a build of your own. For the preset dictionaries, the embedding
model and the app icons, see [MAINTAINING.md](../MAINTAINING.md).

- [Requirements](#requirements)
- [Building from a clean clone](#building-from-a-clean-clone)
- [Running the app](#running-the-app)
- [Forking and signing](#forking-and-signing)
- [Testing](#testing)

## Requirements

| Tool | Needed for |
|---|---|
| Swift 6.2 or later (Xcode 26) | The Swift package: library, CLI tools and tests |
| Xcode 26 on macOS 15.6 or later, with the iOS platform installed | The iOS app, and compiling the Core ML model during the asset bootstrap |
| `curl`, `shasum`, `jq` (included in macOS 15 and later) | `scripts/bootstrap-assets.sh` |
| Python 3 with `pip install mdict-utils` | Only to regenerate the test fixtures |

If Xcode reports a missing iOS SDK or simulator runtime, run
`xcodebuild -downloadPlatform iOS` once. The tools for rebuilding the preset
dictionaries and the model are listed in
[MAINTAINING.md](../MAINTAINING.md#prerequisites).

## Building from a clean clone

```bash
git clone https://github.com/naco-siren/OpenMDict.git
cd OpenMDict

# Library, CLI tools and tests: no downloads, no Xcode project
swift build && swift test

# Assets for the iOS app (about 700 MB)
scripts/bootstrap-assets.sh

# Compile check of the app, without signing
xcodebuild -project Apps/iOS/OpenMDict-iOS/OpenMDict-iOS.xcodeproj \
    -scheme OpenMDict-iOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
```

The preset dictionaries and the article-embedding model are not committed.
`scripts/bootstrap-assets.sh` downloads the build inputs listed in
`preset-dicts/assets.lock.json` from the GitHub Releases the lock points to
(64 `.mdx` files of about 660 MB in total, plus the zipped Core ML model and
its vocabulary; the Release-only notice files are skipped), checks each
SHA-256, and puts them where the Xcode project references them. It then:

- compiles the model (`.mlpackage` to `.mlmodelc`) with `xcrun coremlcompiler`,
  which needs Xcode. `--skip-precompile` skips this step; use it only when
  you will not build the app, because the Xcode project references the
  compiled `.mlmodelc` (as an On-Demand Resource) and the build fails
  without it;
- creates `Apps/iOS/OpenMDict-iOS/Local.xcconfig` from
  `Local.xcconfig.template` if it does not exist.

Files that already match the lock are left alone, so a second run does
nothing. `--check` only reports what is missing or different. When the
Releases are in a private repository, unauthenticated downloads fail and the
script falls back to the GitHub CLI (`gh auth login` first). The other options
and `OPENMDICT_ASSETS_BASE_URL` are described in the script header and in
[MAINTAINING.md](../MAINTAINING.md#the-scripts).

Every build configuration of the project and its targets uses
`Local.xcconfig` (git-ignored) as its base configuration, so `xcodebuild`
fails with "Unable to open base configuration reference file" when it is
missing. The template's placeholder team identifier is enough for the
unsigned build above.

## Running the app

The unsigned build only shows that the project compiles and that every
referenced asset is present. It does not produce an app that runs: the app
resolves its App Group container at launch and stops with a fatal error when
the entitlement is missing.

To run it:

1. Set `DEVELOPMENT_TEAM` in `Apps/iOS/OpenMDict-iOS/Local.xcconfig` to your
   team identifier (Xcode ▸ Settings ▸ Accounts).
2. Open `Apps/iOS/OpenMDict-iOS/OpenMDict-iOS.xcodeproj`, choose a simulator
   or a device, and Run.

The team must be able to use the capabilities listed under
[Forking and signing](#forking-and-signing). With automatic signing, Xcode
registers the App IDs, the App Group and the iCloud container.

Two preset dictionaries are bundled with the app; the others are On-Demand
Resources (see [preset-dicts/README.md](../preset-dicts/README.md#xcode-integration)).
An app installed into a simulator from an `xcodebuild` build cannot download
its On-Demand Resources, because the asset packs are served from the local
Derived Data folder, so only the bundled dictionaries are available there,
and article search has no model (it is an On-Demand Resource as well).
Runs started from Xcode, and TestFlight and App Store builds, are not
affected.

## Forking and signing

The project file carries no team identifier; it comes from `Local.xcconfig`
(see above). To distribute a build of your own, also replace the identifiers
below with ones registered to your team. They share the `io.github.naco-siren`
prefix, and each must stay identical everywhere it appears. Paths are
relative to `Apps/iOS/OpenMDict-iOS/`.

| Identifier | Value in this repository | Where it appears |
|---|---|---|
| Bundle identifiers | `io.github.naco-siren.OpenMDict-iOS` (app), `io.github.naco-siren.OpenMDict-iOS.OpenMDict-ActionExtension`, `io.github.naco-siren.OpenMDict-iOS.OpenMDict-ShareExtension` | `PRODUCT_BUNDLE_IDENTIFIER` of the three targets. The same prefix names the URL type, user-activity types and imported UTIs in `OpenMDict-iOS/Info.plist` and `OpenMDict-iOS/Data/Constants.swift`. |
| App Group | `group.io.github.naco-siren.openmdict` | `OpenMDict-iOS/OpenMDict_iOS.entitlements`, `OpenMDict-ActionExtension/OpenMDict-ActionExtension.entitlements`, `AppIdentifiers.appGroupIdentifier` in `OpenMDict-iOS/Data/Constants.swift` |
| iCloud container | `iCloud.io.github.naco-siren.OpenMDict-iOS` | `OpenMDict-iOS/OpenMDict_iOS.entitlements` (`com.apple.developer.icloud-container-identifiers`), `AppIdentifiers.cloudKitContainerID` in `OpenMDict-iOS/Data/Constants.swift` |
| Push environment | `aps-environment` = `development` | `OpenMDict-iOS/OpenMDict_iOS.entitlements`; needed for CloudKit's silent change notifications. Xcode switches it to `production` when exporting for distribution. |
| Background task | `io.github.naco-siren.openmdict.articleindex` | `BGTaskSchedulerPermittedIdentifiers` in `OpenMDict-iOS/Info.plist`, `AppIdentifiers.articleIndexBGTaskID` in `OpenMDict-iOS/Data/Constants.swift` |

Capabilities by App ID:

- App: **App Groups**, **iCloud (CloudKit)** and **Push Notifications**. The
  app also declares the *Remote notifications* and *Background processing*
  background modes in `Info.plist`; they need no App ID capability.
- Action Extension: **App Groups**.
- Share Extension: none.

The CloudKit schema is created on first use in the development environment.
Deploy it to production in the CloudKit Console before distributing a build
through TestFlight or the App Store, since both use the production
environment.

## Testing

```bash
swift test                                    # both test targets, bundled fixtures
MDICT_TEST_FILE=path/to/dict.mdx swift test   # reader and parser suites on a real dictionary
```

`OpenMDictTests` covers the MDX and MDD parsers, `MDictReader`, lookups and
their fallbacks, entry links, the sidecar index (slow-path and fast-path
lookups must match byte for byte; invalidation; write modes), the
article-embedding index format and the LZO1X decoder (known-answer vectors;
truncated input must throw, corrupted input must not crash). `OpenMDictKitTests`
covers lookups through the `MDict` model, the sync and preset-update rules,
and the Core Data persistent-history behavior the app's CloudKit code relies
on.

The suites use the synthetic dictionaries in `Tests/Fixtures/` (see
[Tests/Fixtures/README.md](../Tests/Fixtures/README.md); regenerate them with
`python3 Tests/Fixtures/make-fixture.py`). `MDICT_TEST_FILE` replaces
`tiny.mdx` in `MDictReaderTests`, `MDXParserTests`, `ResourceTests` and
`SidecarRoundTripTests`; the last parses the file several times, which takes
minutes for a large dictionary.

```bash
# one suite
MDICT_TEST_FILE=path/to/dict.mdx swift test --filter SidecarRoundTripTests

# MDXParserTests and MDictReaderTests: a specific word, or a larger sample (default 5)
MDICT_TEST_FILE=path/to/dict.mdx MDICT_TEST_WORD=hello swift test --filter MDXParserTests
MDICT_TEST_FILE=path/to/dict.mdx MDICT_TEST_SAMPLE=10 swift test --filter MDXParserTests
```

Two suites run only when asked to:

```bash
# Digests of every entry and resource. Run before and after a parser or
# decoder change and compare the files (MDX 1.x dictionaries exercise LZO).
MDICT_DIGEST_DICTS="a.mdx:b.mdx" MDICT_DIGEST_OUT=/tmp/digest.txt \
    swift test -c release --filter DictionaryDigestTests

# LZO1X decode throughput (MB/s per test vector)
MDICT_LZO_BENCH=1 swift test -c release --filter LZO1XBenchmark
```
