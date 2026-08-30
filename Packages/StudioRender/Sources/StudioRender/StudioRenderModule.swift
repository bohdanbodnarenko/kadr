import Shared
import StudioSession

/// The recording studio's render pipeline (docs/09 U3, docs/10 R2.1).
///
/// Frame composition, export, cursor reconstruction and transcription. Editor-only: the
/// agent must never link this package, which is what keeps Speech, CoreImage, VideoToolbox
/// and Vision out of the resident process.
///
/// See `docs/04-swift-architecture.md` §2 for what belongs in this module.
public enum StudioRenderModule {
    /// Stable identifier for the module; matches the package and product name.
    public static let identifier = "StudioRender"

    /// Position of this package in the dependency graph of docs/04 §2.
    public static let layer = 2

    /// The packages this module links, resolved through their real symbols so the
    /// declared graph and the linked graph cannot drift apart.
    public static let dependencies: [(name: String, layer: Int)] = [
        (SharedModule.identifier, SharedModule.layer),
        (StudioSessionModule.identifier, StudioSessionModule.layer)
    ]
}
