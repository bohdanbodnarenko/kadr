import Shared

/// The recording studio's capture models (docs/09 U3, docs/10 R2.1).
///
/// Everything here is a *value*: a session's layout on disk, the telemetry captured
/// alongside a recording, the timeline an edit describes. Nothing in this package touches
/// ScreenCaptureKit, AVFoundation, Speech or CoreImage — those live in the agent (capture)
/// and in `StudioRender` (playback and export). Splitting them is what keeps Speech.framework
/// and the CoreImage/Metal stack out of every launch of a user who never records.
///
/// See `docs/04-swift-architecture.md` §2 for what belongs in this module.
public enum StudioSessionModule {
    /// Stable identifier for the module; matches the package and product name.
    public static let identifier = "StudioSession"

    /// Position of this package in the dependency graph of docs/04 §2.
    public static let layer = 1

    /// The packages this module links, resolved through their real symbols so the
    /// declared graph and the linked graph cannot drift apart.
    public static let dependencies: [(name: String, layer: Int)] = [
        (SharedModule.identifier, SharedModule.layer)
    ]
}
