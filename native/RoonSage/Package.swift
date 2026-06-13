// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoonSage",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RoonSageCore", targets: ["RoonSageCore"]),
        .library(name: "RoonSageUI", targets: ["RoonSageUI"]),
        .library(name: "AudioAnalysis", targets: ["AudioAnalysis"]),
        .library(name: "AnalyzerCore", targets: ["AnalyzerCore"]),
        .executable(name: "RoonSage", targets: ["RoonSage"]),
        .executable(name: "roonsage-mcp", targets: ["RoonSageMCP"]),
        .executable(name: "roonsage-analyzer", targets: ["RoonSageAnalyzer"]),
        .executable(name: "RoonSageAnalyzerApp", targets: ["RoonSageAnalyzerApp"]),
    ],
    dependencies: [
        .package(path: "../RoonProtocol"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "RoonSageCore",
            dependencies: [
                "AudioAnalysis",
                .product(name: "RoonProtocol", package: "RoonProtocol"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "RoonSageUI",
            dependencies: ["RoonSageCore"],
            path: "Sources/RoonSageUI"
        ),
        .executableTarget(
            name: "RoonSage",
            dependencies: ["RoonSageCore", "RoonSageUI"],
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
        .target(
            name: "AnalyzerCore",
            dependencies: [
                "AudioAnalysis",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AnalyzerCore"
        ),
        .executableTarget(
            name: "RoonSageAnalyzer",
            dependencies: ["AnalyzerCore", "AudioAnalysis"],
            path: "Sources/RoonSageAnalyzer"
        ),
        .executableTarget(
            name: "RoonSageAnalyzerApp",
            dependencies: ["AnalyzerCore", "AudioAnalysis"],
            path: "Sources/RoonSageAnalyzerApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "RoonSageCoreTests",
            dependencies: ["RoonSageCore", "AudioAnalysis", "AnalyzerCore"]
        ),
    ]
)
