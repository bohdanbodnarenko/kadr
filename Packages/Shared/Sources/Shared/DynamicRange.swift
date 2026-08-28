import Foundation

/// Whether a capture keeps the display's HDR range (docs/04 §4.1, §4.3, docs/06 M25).
///
/// Standard is still the default, and deliberately: an HDR screenshot looks wrong in every
/// app that does not understand it — washed out in some, blown out in others — and most
/// screenshots are of user interfaces where there is no HDR content to keep. It matters
/// for the cases where it matters: a capture of a video, a photo, or a game.
public enum DynamicRange: String, CaseIterable, Sendable, Hashable, Codable {
    case standard
    case high

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .high: "HDR"
        }
    }

    public var isHigh: Bool {
        self == .high
    }

    /// Whether this build is running on a system that can capture HDR at all.
    ///
    /// ScreenCaptureKit gained `captureDynamicRange` in macOS 15; Kadr ships to 14, so
    /// everything HDR is behind this and the UI hides the option rather than offering a
    /// switch that does nothing.
    public static var isAvailable: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    /// What the settings UI should offer, given the system it is running on.
    public static var available: [DynamicRange] {
        isAvailable ? allCases : [.standard]
    }

    /// The range actually usable here — `high` degrades to `standard` on macOS 14 rather
    /// than failing a capture.
    public var resolved: DynamicRange {
        (self == .high && !Self.isAvailable) ? .standard : self
    }
}
