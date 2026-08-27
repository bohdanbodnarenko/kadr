// swift-tools-version: 6.0
// Kadr — SettingsKit
// UserDefaults-backed @Observable settings, migration.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "SettingsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SettingsKit", targets: ["SettingsKit"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(
            name: "SettingsKit",
            dependencies: [
                .product(name: "Shared", package: "Shared")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SettingsKitTests",
            dependencies: ["SettingsKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
