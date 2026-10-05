// swift-tools-version: 6.0
// Kadr — SettingsKit
// UserDefaults-backed @Observable settings, migration.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "SettingsKit",
    // Display titles are localized from this package's own catalog, through
    // Bundle.module (docs/18 X-4). Only the agent and editor link it, so the
    // resource bundle always ships beside the code.
    defaultLocalization: "en",
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
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SettingsKitTests",
            dependencies: ["SettingsKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
