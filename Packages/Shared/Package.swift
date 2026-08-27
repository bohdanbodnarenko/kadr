// swift-tools-version: 6.0
// Kadr — Shared
// Logging (os.Logger + signposts), geometry helpers (point/pixel, flipped coords), error types.
// Layer 0 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "Shared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Shared", targets: ["Shared"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Shared",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SharedTests",
            dependencies: ["Shared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
