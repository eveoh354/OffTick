// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OffTick",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "OffTick", targets: ["OffTick"])
    ],
    targets: [
        .executableTarget(
            name: "OffTick",
            path: "Sources/OffTick",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
