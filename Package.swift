// swift-tools-version: 6.2
//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "WirenHome",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "wb-homekit", targets: ["WirenHome"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        // Already pulled in by mqtt-nio; listed for direct NIOCore/NIOPosix imports.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"6.0.0")
    ],
    targets: [
        .target(name: "Common"),
        .target(
            name: "WBKit",
            dependencies: [
                "Common",
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .target(
            name: "HAPKit",
            dependencies: [
                "Common",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .target(name: "Discovery", dependencies: ["Common"]),
        .target(name: "Bridge", dependencies: ["Common", "WBKit", "HAPKit", "Discovery"]),
        .executableTarget(name: "WirenHome", dependencies: ["Bridge", "Common"]),
        .testTarget(name: "WBKitTests", dependencies: ["WBKit"]),
        .testTarget(name: "HAPKitTests", dependencies: ["HAPKit", .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery"]),
        .testTarget(name: "BridgeTests", dependencies: ["Bridge", "WBKit", "HAPKit"]),
        .testTarget(name: "WirenHomeTests", dependencies: ["WirenHome", "Common"])
    ]
)
