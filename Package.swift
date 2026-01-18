// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenMDict",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        // Core parsing library (no platform dependencies)
        .library(name: "OpenMDict", targets: ["OpenMDict"]),
        
        // ViewModel layer (depends on Combine, for iOS/macOS apps)
        .library(name: "OpenMDictKit", targets: ["OpenMDictKit"]),
        
        // CLI tool
        .executable(name: "openmdict", targets: ["OpenMDictCLI"])
    ],
    targets: [
        // C library for LZO decompression
        .target(
            name: "CLZ",
            path: "Sources/CLZ",
            publicHeadersPath: "include"
        ),
        
        // Core parsing library
        .target(
            name: "OpenMDict",
            dependencies: ["CLZ"],
            path: "Sources/OpenMDict"
        ),
        
        // ViewModel layer (MDict, MDicts)
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
