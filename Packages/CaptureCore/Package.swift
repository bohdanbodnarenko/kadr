// swift-tools-version: 6.0
// Kadr — CaptureCore
// ScreenCaptureKit wrappers: shareable content, screenshots, filters, permission state machine. No UI. Agent-only.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "CaptureCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "CaptureCore",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
