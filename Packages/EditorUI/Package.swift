// swift-tools-version: 6.0
// Kadr — EditorUI
// SwiftUI editor chrome (toolbars, inspector) hosting the AnnotationRender canvas. Editor app only.
// Layer 3 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "EditorUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditorUI", targets: ["EditorUI"])
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../ControlKit"),
        .package(path: "../AnnotationModel"),
        .package(path: "../AnnotationRender"),
        .package(path: "../MediaExport"),
        .package(path: "../StudioSession"),
        .package(path: "../StudioRender")
    ],
    targets: [
        .target(
            name: "EditorUI",
            dependencies: [
                .product(name: "Shared", package: "Shared"),
                .product(name: "ControlKit", package: "ControlKit"),
                .product(name: "AnnotationModel", package: "AnnotationModel"),
                .product(name: "AnnotationRender", package: "AnnotationRender"),
                .product(name: "MediaExport", package: "MediaExport"),
                .product(name: "StudioSession", package: "StudioSession"),
                .product(name: "StudioRender", package: "StudioRender")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EditorUITests",
            dependencies: [
                "EditorUI",
                .product(name: "StudioSession", package: "StudioSession"),
                .product(name: "StudioRender", package: "StudioRender"),
                .product(name: "MediaExport", package: "MediaExport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
