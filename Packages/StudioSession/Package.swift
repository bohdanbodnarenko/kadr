// swift-tools-version: 6.0
// Kadr — StudioSession
// Agent-linkable studio capture models: session packages, input telemetry, the edit
// document, clips and the teleprompter script. Foundation and CoreGraphics only — Speech,
// CoreImage and AVFoundation stay in StudioRender so a user who never records does not
// pay for them at idle (docs/10 R2.1).
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "StudioSession",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StudioSession", targets: ["StudioSession"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "StudioSession",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StudioSessionTests",
            dependencies: ["StudioSession"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
