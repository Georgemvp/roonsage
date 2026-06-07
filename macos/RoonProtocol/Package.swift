// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoonProtocol",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RoonProtocol", targets: ["RoonProtocol"]),
        .executable(name: "protocol-check", targets: ["protocol-check"]),
    ],
    targets: [
        .target(name: "RoonProtocol"),
        // Standalone assertion harness — runs with `swift run protocol-check`
        // using only the CommandLineTools toolchain (no Xcode required).
        .executableTarget(name: "protocol-check", dependencies: ["RoonProtocol"]),
        // XCTest suite — requires full Xcode (`swift test`); kept for CI.
        .testTarget(name: "RoonProtocolTests", dependencies: ["RoonProtocol"]),
    ]
)
