// swift-tools-version: 6.0
// Kadr — AutomationKit
// URL-scheme + CLI verb parsing into typed AppCommand values.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "AutomationKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutomationKit", targets: ["AutomationKit"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "AutomationKit",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AutomationKitTests",
            dependencies: [
                "AutomationKit",
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
