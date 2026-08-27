import MediaExport
import Shared

/// Capture records, thumbnail pipeline (ImageIO downsample), SQLite index and FTS5, retention/eviction.
///
/// See `docs/04-swift-architecture.md` §2 and §9, and `docs/03-features.md` §5.
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
