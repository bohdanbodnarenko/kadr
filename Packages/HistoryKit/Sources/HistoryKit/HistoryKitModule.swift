import MediaExport
import Shared

/// Placeholder for the `HistoryKit` package.
///
/// Capture records, thumbnail pipeline (ImageIO downsample), SQLite index and FTS5, retention/eviction.
///
/// Scaffolding only (milestone M0.1) — no behaviour lives here yet. The type exists so the
/// package, its dependency edges and its test target are wired up and verified by CI.
/// See `docs/04-swift-architecture.md` §2 for what belongs in this module.
public enum HistoryKitModule {
    /// Stable identifier for the module; matches the package and product name.
    public static let identifier = "HistoryKit"

    /// Position of this package in the dependency graph of docs/04 §2.
    /// A package may only depend on packages in a strictly lower layer.
    public static let layer = 2

    /// The packages this module links, resolved through their real symbols so the
    /// declared graph and the linked graph cannot drift apart.
    public static let dependencies: [(name: String, layer: Int)] = [
        (SharedModule.identifier, SharedModule.layer),
        (MediaExportModule.identifier, MediaExportModule.layer)
    ]
}
