// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenMDict",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .executable(name: "openmdict", targets: ["OpenMDictCLI"]),
        .library(name: "OpenMDict", targets: ["OpenMDict"])
    ],
    targets: [
        // C library for LZO decompression
        .target(
            name: "CLZ",
            path: "Sources/CLZ",
            publicHeadersPath: "include",
            cSettings: [
                .define("MINILZO_HAVE_CONFIG_H", to: "0")
            ]
        ),
        // Main OpenMDict library
        .target(
            name: "OpenMDict",
            dependencies: ["CLZ"],
            path: "Sources/OpenMDict"
        ),
        // CLI executable
        .executableTarget(
            name: "OpenMDictCLI",
            dependencies: ["OpenMDict"],
            path: "Sources/OpenMDictCLI"
        ),
        // Tests
        .testTarget(
            name: "OpenMDictTests",
            dependencies: ["OpenMDict"],
            path: "Tests/OpenMDictTests"
        )
    ]
)
