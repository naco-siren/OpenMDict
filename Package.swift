// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenMDict",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(name: "OpenMDict", targets: ["OpenMDict"]),
        .library(name: "OpenMDictKit", targets: ["OpenMDictKit"]),
        .executable(name: "openmdict", targets: ["OpenMDictCLI"]),
        .executable(name: "openmdict-bench", targets: ["OpenMDictBench"])
    ],
    targets: [
        // Core parsing library (platform-agnostic, pure Swift)
        .target(
            name: "OpenMDict",
            path: "Sources/OpenMDict"
        ),
        
        // ViewModel layer for iOS/macOS
        .target(
            name: "OpenMDictKit",
            dependencies: ["OpenMDict"],
            path: "Sources/OpenMDictKit"
        ),
        
        // CLI tool — depends on OpenMDict core only. Per the three-layer
        // architecture (Core / Kit / App), the CLI is a test + dev tool
        // for the core lib and must not pull in Kit's UI-focused
        // ViewModels. M15 Phase 3's article-embedding code lives in
        // `Sources/OpenMDict/Semantic/ArticleEmbed/` (alongside the
        // MDX parser) precisely so the CLI can use it without crossing
        // layers; CoreML / Accelerate are Apple-platform-wide
        // frameworks (not GUI-only like UIKit), so they're acceptable
        // in the core lib.
        .executableTarget(
            name: "OpenMDictCLI",
            dependencies: ["OpenMDict"],
            path: "Apps/CLI"
        ),

        // Performance benchmark tool (sidecar index A/B)
        .executableTarget(
            name: "OpenMDictBench",
            dependencies: ["OpenMDict"],
            path: "Apps/Bench"
        ),
        
        // Tests
        .testTarget(
            name: "OpenMDictTests",
            dependencies: ["OpenMDict"],
            path: "Tests/OpenMDictTests"
        ),

        // Kit tests: pure sync/reconciliation policies plus the Core Data
        // persistent-history mechanics the iOS app's CloudKit code relies on.
        .testTarget(
            name: "OpenMDictKitTests",
            dependencies: ["OpenMDictKit"],
            path: "Tests/OpenMDictKitTests"
        )
    ]
)
