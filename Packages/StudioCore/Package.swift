// swift-tools-version: 6.0
// Kadr — StudioCore
// The recording studio's model layer: session packages, input telemetry, cursor
// reconstruction, the virtual camera timeline, clips and the cut planner.
// Layer 2 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "StudioCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "StudioCore",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StudioCoreTests",
            dependencies: ["StudioCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
