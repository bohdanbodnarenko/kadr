import Foundation

/// The recording studio's model layer (docs/09 U3).
///
/// Everything here is a *value*: a session's layout on disk, the telemetry captured
/// alongside a recording, the timeline an edit describes. Nothing in this package touches
/// ScreenCaptureKit, AVFoundation's capture side, or a window — those live in the agent,
/// which is the only process that may hold the TCC grant (docs/04 §1).
///
/// That split is what makes the studio testable. A cursor reconstruction is a function from
/// telemetry to positions; a zoom timeline is a function from cues to transforms. Both can
/// be checked exhaustively without a display, which is the difference between this and
/// every other screen recorder's editor.
public enum StudioCoreModule {
    public static let name = "StudioCore"
}
