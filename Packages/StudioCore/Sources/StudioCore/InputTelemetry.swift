import CoreGraphics
import Foundation

/// What the pointer was doing, at one instant (docs/09 U3.1).
///
/// Timestamps are *recording* time — seconds since the recording started, with pauses
/// excluded. Wall time would drift from the footage the moment somebody paused, which is
/// the bug the live overlay had before U0.3 fixed it (docs/07 M2); the sidecar starts from
/// the corrected model rather than inheriting the broken one.
public struct PointerSample: Codable, Sendable, Hashable {
    public var time: TimeInterval
    /// Where the pointer was, in the recorded area's own pixels.
    public var position: CGPoint
    /// Which cursor image was showing, as an index into the session's cursor artwork.
    public var cursorIndex: Int?

    public init(time: TimeInterval, position: CGPoint, cursorIndex: Int? = nil) {
        self.time = time
        self.position = position
        self.cursorIndex = cursorIndex
    }
}

/// A button going down or up.
public struct ClickEvent: Codable, Sendable, Hashable {
    public enum Button: String, Codable, Sendable {
        case left, right, other
    }

    public var time: TimeInterval
    public var position: CGPoint
    public var button: Button
    public var isDown: Bool

    public init(time: TimeInterval, position: CGPoint, button: Button = .left, isDown: Bool = true) {
        self.time = time
        self.position = position
        self.button = button
        self.isDown = isDown
    }
}

/// A key combination worth captioning (docs/09 U3.1).
///
/// Chords and special keys only, and that is a privacy decision rather than a simplifying
/// one: a recording's sidecar must never become a keylogger. Plain typing — the letters
/// somebody types into a password field, a message, a search box — is not recorded at all,
/// so there is nothing in the file to leak, redact, or be subpoenaed.
public struct KeystrokeEvent: Codable, Sendable, Hashable {
    public var time: TimeInterval
    /// The caption to draw, already assembled: "⌘S", "⇧⌘4", "Return".
    public var caption: String

    public init(time: TimeInterval, caption: String) {
        self.time = time
        self.caption = caption
    }
}

/// One cursor image, kept so the export can draw the real thing (docs/09 U3.1).
///
/// Recording with `showsCursor = false` and drawing the pointer back afterwards is what
/// makes smooth zooms possible — a baked-in cursor cannot be moved, smoothed, or scaled
/// with the camera. Which means the *actual* cursor artwork has to be captured, including
/// the hotspot: an I-beam drawn as an arrow is worse than no reconstruction at all.
public struct CursorImage: Codable, Sendable, Hashable {
    /// The image, as PNG.
    public var pngData: Data
    /// Where the pointer actually points, in the image's own pixels.
    public var hotspot: CGPoint
    /// The image's size in points, so a Retina cursor is not drawn double.
    public var size: CGSize

    public init(pngData: Data, hotspot: CGPoint, size: CGSize) {
        self.pngData = pngData
        self.hotspot = hotspot
        self.size = size
    }
}

/// Where the recorded window was, at one instant.
///
/// A window that moves during a recording moves everything drawn relative to it. Sampling
/// its geometry per frame is what lets the studio keep a zoom anchored to a button rather
/// than to a screen position the button has since left.
public struct WindowGeometrySample: Codable, Sendable, Hashable {
    public var time: TimeInterval
    public var frame: CGRect

    public init(time: TimeInterval, frame: CGRect) {
        self.time = time
        self.frame = frame
    }
}

/// Everything captured alongside the footage (docs/09 U3.1).
///
/// Written once when the recording stops rather than streamed: the samples are small, the
/// recording is the thing that must not stutter, and a sidecar half-written by a crash is
/// worse than one that is simply absent.
public struct InputTelemetry: Codable, Sendable, Hashable {
    /// Bumped when a field's meaning changes, as against a field being added.
    public static let currentVersion = 1

    public var version: Int
    public var pointer: [PointerSample]
    public var clicks: [ClickEvent]
    public var keystrokes: [KeystrokeEvent]
    public var cursors: [CursorImage]
    public var windowGeometry: [WindowGeometrySample]
    /// How the samples were gathered, so a reconstruction can say why it is coarse.
    public var source: TelemetrySource

    public init(
        version: Int = InputTelemetry.currentVersion,
        pointer: [PointerSample] = [],
        clicks: [ClickEvent] = [],
        keystrokes: [KeystrokeEvent] = [],
        cursors: [CursorImage] = [],
        windowGeometry: [WindowGeometrySample] = [],
        source: TelemetrySource = .eventTap
    ) {
        self.version = version
        self.pointer = pointer
        self.clicks = clicks
        self.keystrokes = keystrokes
        self.cursors = cursors
        self.windowGeometry = windowGeometry
        self.source = source
    }

    public var isEmpty: Bool {
        pointer.isEmpty && clicks.isEmpty && keystrokes.isEmpty
    }

    /// The last moment anything was recorded.
    public var duration: TimeInterval {
        let times = pointer.map(\.time) + clicks.map(\.time) + keystrokes.map(\.time)
        return times.max() ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case version, pointer, clicks, keystrokes, cursors, windowGeometry, source
    }

    /// Every field defaults, so a sidecar written by a later Kadr still opens — it simply
    /// arrives without whatever was added (docs/08 §2.6).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            pointer: container.decodeIfPresent([PointerSample].self, forKey: .pointer) ?? [],
            clicks: container.decodeIfPresent([ClickEvent].self, forKey: .clicks) ?? [],
            keystrokes: container.decodeIfPresent([KeystrokeEvent].self, forKey: .keystrokes) ?? [],
            cursors: container.decodeIfPresent([CursorImage].self, forKey: .cursors) ?? [],
            windowGeometry: container.decodeIfPresent(
                [WindowGeometrySample].self,
                forKey: .windowGeometry
            ) ?? [],
            source: container.decodeIfPresent(TelemetrySource.self, forKey: .source) ?? .eventTap
        )
    }
}

/// How the pointer was watched (docs/09 U3.1).
///
/// The triple fallback exists because each layer can fail independently and silently. A
/// CGEvent tap is the good path — every movement, listen-only, no interception — but it
/// needs Accessibility and macOS can disable a tap that takes too long in its callback.
/// AppKit monitors still see presses without any permission. A polling sampler sees only
/// where the pointer *is*, which is coarse but never nothing.
///
/// Recorded in the sidecar so a reconstruction can explain itself rather than looking
/// mysteriously bad.
public enum TelemetrySource: String, Codable, Sendable, CaseIterable {
    /// A listen-only `CGEvent` tap: every movement and every press.
    case eventTap
    /// AppKit global monitors: presses, and movement only while the pointer is over an
    /// application that reports it.
    case appKitMonitors
    /// A timer reading the pointer's position: movement at the sampling rate, no presses.
    case sampler

    public var title: String {
        switch self {
        case .eventTap: "Full"
        case .appKitMonitors: "Reduced"
        case .sampler: "Sampled"
        }
    }

    /// Whether this source sees button presses at all.
    public var capturesClicks: Bool {
        self != .sampler
    }

    /// What to tell the user when the reconstruction is not as good as it could be.
    public var limitation: String? {
        switch self {
        case .eventTap: nil
        case .appKitMonitors:
            "Kadr could not watch the pointer continuously, so its motion is approximate."
        case .sampler:
            "Kadr could not watch clicks during this recording; only pointer motion was captured."
        }
    }
}
