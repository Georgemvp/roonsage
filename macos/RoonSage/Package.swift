// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoonSage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RoonSageCore", targets: ["RoonSageCore"]),
        .executable(name: "RoonSage", targets: ["RoonSage"]),
        .executable(name: "roonsage-mcp", targets: ["RoonSageMCP"]),
    ],
    dependencies: [
        .package(path: "../RoonProtocol"),
    ],
    targets: [
        .target(
            name: "RoonSageCore",
            dependencies: [.product(name: "RoonProtocol", package: "RoonProtocol")]
        ),
        .executableTarget(
            name: "RoonSage",
            dependencies: ["RoonSageCore"],
            path: "Sources/RoonSage"
        ),
        .executableTarget(
            name: "RoonSageMCP",
            dependencies: ["RoonSageCore"],
            path: "Sources/RoonSageMCP"
        ),
        .testTarget(
            name: "RoonSageCoreTests",
            dependencies: ["RoonSageCore"]
        ),
    ]
)
