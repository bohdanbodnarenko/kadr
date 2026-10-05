import Foundation

/// How the reconstructed pointer is cleaned up after recording (CleanShot §14.4).
///
/// The spring that draws the path is shared with the camera only when both should feel
/// the same. Off leaves the recorded samples in place so a click lands exactly where it
/// happened; Natural is a light cleanup; Smooth is the aggressive pass that makes a
/// hand-moved pointer look deliberate.
public enum CursorSmoothing: String, Sendable, Hashable, Codable, CaseIterable {
    /// Follow the recorded samples. Clicks stay pixel-exact; jitter stays too.
    case off
    /// A light cleanup: enough to take the shake out, not enough to lag a click.
    case natural
    /// Aggressive smoothing. The default, because that is how Kadr has drawn reconstructed
    /// pointers since the studio landed.
    case smooth

    public var title: String {
        switch self {
        case .off: String(localized: "Off", bundle: .module)
        case .natural: String(localized: "Natural", bundle: .module)
        case .smooth: String(localized: "Smooth", bundle: .module)
        }
    }

    /// Stiffness for the critically damped spring that walks the path.
    ///
    /// Higher arrives sooner. Off is stiff enough that a 120 Hz step lands on the sample
    /// within a frame, which is indistinguishable from unsmoothed at 60 fps.
    public var stiffness: Double {
        switch self {
        case .off: 400
        case .natural: 24
        case .smooth: 12
        }
    }
}

/// How a click is drawn on the reconstructed pointer (CleanShot §13.4 / §14.4).
public enum ClickRippleStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// A ring, the live overlay's look.
    case outline
    /// A filled disc that punches into the scene.
    case filled

    public var title: String {
        switch self {
        case .outline: String(localized: "Outline", bundle: .module)
        case .filled: String(localized: "Filled", bundle: .module)
        }
    }
}

/// How the camera moves in and out of a zoom (CleanShot §14.3).
///
/// Independent of cursor smoothing: a snappy zoom with a natural pointer is a real look,
/// and tying the two to one spring is what made them feel like the same control.
public enum ZoomAnimationStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// The existing camera spring — arrives without a punch.
    case smooth
    /// A snappier move, closer to a cut that still eases.
    case dynamic

    public var title: String {
        switch self {
        case .smooth: String(localized: "Smooth", bundle: .module)
        case .dynamic: String(localized: "Dynamic", bundle: .module)
        }
    }

    public var stiffness: Double {
        switch self {
        case .smooth: 12
        case .dynamic: 28
        }
    }
}
