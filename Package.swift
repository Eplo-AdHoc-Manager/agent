// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "eplo-agent",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "eplo-agent",
            targets: ["EploAgent"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(path: "../protocol-spec"),
    ],
    targets: [
        .executableTarget(
            name: "EploAgent",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "EploProtocol", package: "protocol-spec"),
            ]
        ),
        .testTarget(
            name: "EploAgentTests",
            dependencies: ["EploAgent"]
        ),
    ]
)
