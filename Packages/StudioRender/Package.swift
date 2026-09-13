// swift-tools-version: 6.0
// Kadr — StudioRender
// The studio's render pipeline: frame composer, exporter, cursor reconstruction,
// transcription. Editor-only — the agent must never link this target (docs/10 R2.1).
// Layer 2 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "StudioRender",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StudioRender", targets: ["StudioRender"])
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../StudioSession")
    ],
    targets: [
        .target(
            name: "StudioRender",
            dependencies: [
                .product(name: "Shared", package: "Shared"),
                .product(name: "StudioSession", package: "StudioSession")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StudioRenderTests",
            dependencies: [
                "StudioRender",
                .product(name: "Shared", package: "Shared"),
                .product(name: "StudioSession", package: "StudioSession")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
