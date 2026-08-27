// swift-tools-version: 6.0
// Kadr — OverlayKit
// AppKit panel primitives: NonActivatingPanel, per-screen window sets, screen-freeze surfaces, collectionBehavior
// presets.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "OverlayKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OverlayKit", targets: ["OverlayKit"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "OverlayKit",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OverlayKitTests",
            dependencies: ["OverlayKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
