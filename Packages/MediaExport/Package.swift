// swift-tools-version: 6.0
// Kadr — MediaExport
// ImageIO writers (PNG/JPEG/HEIC/WebP), metadata, filename templates, GIF encode orchestration.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "MediaExport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MediaExport", targets: ["MediaExport"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "MediaExport",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaExportTests",
            dependencies: ["MediaExport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
