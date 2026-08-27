// swift-tools-version: 6.0
// Kadr — RecordingCore
// SCStream session, AVAssetWriter pipeline, audio engine, pause/resume segmenting, SCRecordingOutput (15+) path.
// Layer 2 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "RecordingCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecordingCore", targets: ["RecordingCore"])
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../CaptureCore")
    ],
    targets: [
        .target(
            name: "RecordingCore",
            dependencies: [
                .product(name: "Shared", package: "Shared"),
                .product(name: "CaptureCore", package: "CaptureCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RecordingCoreTests",
            dependencies: ["RecordingCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
