// swift-tools-version: 6.0
// Kadr — VisionServices
// OCR, QR, subject mask, redaction-candidate detection. Helper process only; async API over XPC.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "VisionServices",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VisionServices", targets: ["VisionServices"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "VisionServices",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VisionServicesTests",
            dependencies: ["VisionServices"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
