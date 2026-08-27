// swift-tools-version: 6.0
// Kadr — HistoryKit
// Capture records, thumbnail pipeline (ImageIO downsample), SQLite index + FTS5, retention/eviction.
// Layer 2 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "HistoryKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HistoryKit", targets: ["HistoryKit"])
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../MediaExport")
    ],
    targets: [
        .target(
            name: "HistoryKit",
            dependencies: [
                .product(name: "Shared", package: "Shared"),
                .product(name: "MediaExport", package: "MediaExport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HistoryKitTests",
            dependencies: ["HistoryKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
