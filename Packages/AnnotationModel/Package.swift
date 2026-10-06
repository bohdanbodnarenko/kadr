// swift-tools-version: 6.0
// Kadr — AnnotationModel
// Pure value types: AnnotationCommand enum, document model, undo stack, JSON (de)serialization (.kadr). No AppKit.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "AnnotationModel",
    // Display titles are localized from this package's own catalog, through
    // Bundle.module (docs/18 X-4). Only the agent and editor link it, so the
    // resource bundle always ships beside the code.
    defaultLocalization: "en",
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
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AnnotationModelTests",
            dependencies: ["AnnotationModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
