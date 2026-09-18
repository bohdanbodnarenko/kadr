import Foundation

/// The inspector's four panes (docs/09 U3.3–U3.5).
///
/// Nine collapsible groups in one column meant scrolling past six of them to reach the two
/// in use, and every recording started by re-folding whatever the last one had left open.
/// Four panes is the shape every macOS inspector with this much in it settles on — Keynote,
/// Xcode, Final Cut — because a pane is a question the user is currently answering.
///
/// Ordered the way an edit goes: what is selected, then the picture, then what is drawn on
/// it, then the sound.
public enum StudioInspectorTab: String, CaseIterable, Identifiable, Sendable {
    /// The clip under the playhead, and the selected zoom.
    case clip
    /// Aspect, crop, canvas and the camera bubble — the shape of the picture.
    case frame
    /// Pointer, clicks, zoom motion and shortcut captions.
    case effects
    case audio

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .clip: String(localized: "Clip")
        case .frame: String(localized: "Frame")
        case .effects: String(localized: "Effects")
        case .audio: String(localized: "Audio")
        }
    }

    /// For VoiceOver, where "Frame" alone is ambiguous between a rectangle and a video frame.
    public var accessibilityLabel: String {
        switch self {
        case .clip: String(localized: "Clip and zoom")
        case .frame: String(localized: "Frame and canvas")
        case .effects: String(localized: "Pointer and overlays")
        case .audio: String(localized: "Audio and speech")
        }
    }

    /// The pane a new selection should bring forward, or nil to leave the user where they are.
    ///
    /// Selecting a zoom in the timeline and finding the inspector still on Audio is the
    /// failure this prevents — the same reason Keynote jumps to Format when you click a
    /// shape. Only a *new* selection moves the panes: clearing one leaves them alone, so
    /// pressing Escape does not also throw away the pane you were reading.
    public static func revealing(zoom: Bool, clip: Bool) -> StudioInspectorTab? {
        zoom || clip ? .clip : nil
    }
}
