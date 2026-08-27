// swift-tools-version: 6.0
// Kadr — SelectionUI
// The selection overlay: CALayer crosshair/marching-ants, magnifier loupe, dimension badge, keyboard handling.
// Layer 2 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "SelectionUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SelectionUI", targets: ["SelectionUI"])
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../OverlayKit")
    ],
    targets: [
        .target(
            name: "SelectionUI",
            dependencies: [
                .product(name: "Shared", package: "Shared"),
                .product(name: "OverlayKit", package: "OverlayKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SelectionUITests",
            dependencies: ["SelectionUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
