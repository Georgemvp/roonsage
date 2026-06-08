// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoonSage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RoonSageCore", targets: ["RoonSageCore"]),
        .library(name: "AudioAnalysis", targets: ["AudioAnalysis"]),
        .executable(name: "RoonSage", targets: ["RoonSage"]),
        .executable(name: "roonsage-mcp", targets: ["RoonSageMCP"]),
        .executable(name: "roonsage-analyzer", targets: ["RoonSageAnalyzer"]),
    ],
    dependencies: [
        .package(path: "../RoonProtocol"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "RoonSageCore",
            dependencies: [
                .product(name: "RoonProtocol", package: "RoonProtocol"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "RoonSage",
            dependencies: ["RoonSageCore"],
            path: "Sources/RoonSage",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "RoonSageMCP",
            dependencies: ["RoonSageCore"],
            path: "Sources/RoonSageMCP"
        ),
        .target(
            name: "AudioAnalysis",
            path: "Sources/AudioAnalysis"
        ),
        .executableTarget(
            name: "RoonSageAnalyzer",
            dependencies: [
                "AudioAnalysis",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/RoonSageAnalyzer"
        ),
        .testTarget(
            name: "RoonSageCoreTests",
            dependencies: ["RoonSageCore"]
        ),
    ]
)
