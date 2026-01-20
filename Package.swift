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
        .executable(name: "openmdict", targets: ["OpenMDictCLI"])
    ],
    targets: [
        // C library for LZO decompression
        .target(
            name: "CLZ",
            path: "Sources/CLZ",
            publicHeadersPath: "include"
        ),
        
        // Core parsing library (platform-agnostic)
        .target(
            name: "OpenMDict",
            dependencies: ["CLZ"],
            path: "Sources/OpenMDict"
        ),
        
        // ViewModel layer for iOS/macOS
        .target(
            name: "OpenMDictKit",
            dependencies: ["OpenMDict"],
            path: "Sources/OpenMDictKit"
        ),
        
        // CLI tool
        .executableTarget(
            name: "OpenMDictCLI",
            dependencies: ["OpenMDict"],
            path: "Apps/CLI"
        ),
        
        // Tests
        .testTarget(
            name: "OpenMDictTests",
            dependencies: ["OpenMDict"],
            path: "Tests/OpenMDictTests"
        )
    ]
)
