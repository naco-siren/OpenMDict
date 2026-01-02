// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MDictPOC",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .executable(name: "mdict-poc", targets: ["MDict"])
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
        // Main Swift executable
        .executableTarget(
            name: "MDict",
            dependencies: ["CLZ"],
            path: "Sources/MDict"
        )
    ]
)
