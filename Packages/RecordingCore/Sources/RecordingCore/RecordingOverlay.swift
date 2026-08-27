import CoreGraphics
import Foundation
import Shared

/// A click, as it is being drawn (docs/03 §1.8).
public struct ClickPulse: Sendable, Hashable {
    /// Where the click happened, in the recorded area's own points.
    public var position: CGPoint
    /// 0 at the moment of the click, 1 when the pulse has finished.
    public var progress: Double
    public var isRightClick: Bool

    public init(position: CGPoint, progress: Double, isRightClick: Bool = false) {
        self.position = position
        self.progress = min(max(progress, 0), 1)
        self.isRightClick = isRightClick
    }
}

/// Where the keystroke overlay sits.
public enum KeystrokePosition: String, CaseIterable, Sendable {
    case bottomCentre
    case bottomLeading
    case topCentre

    public var title: String {
        switch self {
        case .bottomCentre: "Bottom"
        case .bottomLeading: "Bottom Left"
        case .topCentre: "Top"
        }
    }
}

/// Everything drawn over a frame at one instant (docs/03 §1.8).
///
/// A value, produced by the app and consumed by the compositor. The app owns the event
/// monitors; the recording pipeline owns the drawing, and neither needs to know how the
/// other works.
public struct RecordingOverlay: Sendable {
    public var clicks: [ClickPulse]
    /// The keys shown right now, already formatted — "⌘⇧4" or "Hello".
    public var keystrokes: String?
    public var keystrokePosition: KeystrokePosition
    /// The webcam picture to inset, already the right way round.
    public var webcamFrame: CGImage?
    public var webcamIsCircular: Bool

    public init(
        clicks: [ClickPulse] = [],
        keystrokes: String? = nil,
        keystrokePosition: KeystrokePosition = .bottomCentre,
        webcamFrame: CGImage? = nil,
        webcamIsCircular: Bool = true
    ) {
        self.clicks = clicks
        self.keystrokes = keystrokes
        self.keystrokePosition = keystrokePosition
        self.webcamFrame = webcamFrame
        self.webcamIsCircular = webcamIsCircular
    }

    public var isEmpty: Bool {
        clicks.isEmpty && keystrokes == nil && webcamFrame == nil
    }
}

/// Supplies what to draw, frame by frame.
///
/// Called from the recording pipeline, off the main actor, once per frame — so it must be
/// cheap and must not block. Implementations keep a small snapshot updated by their event
/// monitors rather than doing work here.
public protocol RecordingOverlayProviding: Sendable {
    func overlay(atRecordingTime seconds: TimeInterval) -> RecordingOverlay
}
