// swift-tools-version: 6.0
// Kadr — AnnotationModel
// Pure value types: AnnotationCommand enum, document model, undo stack, JSON (de)serialization (.kadr). No AppKit.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "AnnotationModel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnnotationModel", targets: ["AnnotationModel"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "AnnotationModel",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AnnotationModelTests",
            dependencies: ["AnnotationModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
