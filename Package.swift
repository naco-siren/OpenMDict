// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenMDict",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "OpenMDict", targets: ["OpenMDict"]),
        .executable(name: "openmdict", targets: ["OpenMDictCLI"])
    ],
    targets: [
        // C library for LZO decompression
        .target(
            name: "CLZ",
            path: "Sources/CLZ",
            publicHeadersPath: "include"
        ),
        
        // Main library
        .target(
            name: "OpenMDict",
            dependencies: ["CLZ"],
            path: "Sources/OpenMDict"
        ),
        
        // CLI tool (in Apps folder)
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
