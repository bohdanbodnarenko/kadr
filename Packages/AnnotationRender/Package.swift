// swift-tools-version: 6.0
// Kadr — AnnotationRender
// Command list into a CALayer tree (editing) and into a CGContext (export). Blur/pixelate rasterization.
// Layer 2 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "AnnotationRender",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnnotationRender", targets: ["AnnotationRender"])
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../AnnotationModel"),
        .package(path: "../SettingsKit")
    ],
    targets: [
        .target(
            name: "AnnotationRender",
            dependencies: [
                .product(name: "Shared", package: "Shared"),
                .product(name: "AnnotationModel", package: "AnnotationModel"),
                .product(name: "SettingsKit", package: "SettingsKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AnnotationRenderTests",
            dependencies: ["AnnotationRender", .product(name: "SettingsKit", package: "SettingsKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
