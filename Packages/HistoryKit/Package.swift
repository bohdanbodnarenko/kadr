// swift-tools-version: 6.0
// Kadr — HistoryKit
// Capture records, thumbnail pipeline (ImageIO downsample), SQLite index + FTS5, retention/eviction.
// Layer 2 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "HistoryKit",
    // Display titles are localized from this package's own catalog, through
    // Bundle.module (docs/18 X-4). Only the agent and editor link it, so the
    // resource bundle always ships beside the code.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HistoryKit", targets: ["HistoryKit"])
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../MediaExport"),
        // The index is SQLite, reached through GRDB (docs/04 §9, §12). GRDB rather than
        // raw sqlite3 for the same reason the rest of this codebase leans on types: the
        // migrations, the value mapping and the FTS5 support that P3 search needs are all
        // things worth not hand-rolling. It has no networking of its own, which
        // Scripts/check-layering.sh insists on.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "HistoryKit",
            dependencies: [
                .product(name: "Shared", package: "Shared"),
                .product(name: "MediaExport", package: "MediaExport"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HistoryKitTests",
            dependencies: ["HistoryKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
