// swift-tools-version: 6.0
// Kadr — ControlKit
// SwiftUI controls shared by the agent's Settings and the editor's inspector: the pill slider.
// Layer 1 in the dependency graph of docs/04-swift-architecture.md §2 —
// this package may only depend on packages in strictly lower layers.

import PackageDescription

let package = Package(
    name: "ControlKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ControlKit", targets: ["ControlKit"])
    ],
    targets: [
        .target(
            name: "ControlKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ControlKitTests",
            dependencies: ["ControlKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
