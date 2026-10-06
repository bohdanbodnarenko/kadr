// swift-tools-version: 6.0
// Kadr — StudioRender
// The studio's render pipeline: frame composer, exporter, cursor reconstruction,
// transcription. Editor-only — the agent must never link this target (docs/10 R2.1).
// Layer 2 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "StudioRender",
    // Display titles are localized from this package's own catalog, through
    // Bundle.module (docs/18 X-4). Only the agent and editor link it, so the
    // resource bundle always ships beside the code.
    defaultLocalization: "en",
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
            resources: [.process("Resources")],
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
