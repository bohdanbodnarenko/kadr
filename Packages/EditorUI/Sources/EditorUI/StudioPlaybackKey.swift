import AppKit
import Carbon.HIToolbox

/// The studio's bare playback keys (docs/09 U3.3).
///
/// These are the keys that cannot live in a menu. A menu key equivalent with no modifier is
/// resolved before the first responder ever sees the event, so Space would start playback
/// while the user was typing in the transcript and ← would scrub instead of moving the
/// insertion point. They travel the responder chain instead, and the window controller asks
/// this table what an event means.
///
/// A table rather than a `switch` in the controller so the mapping is testable without a
/// window, a key event or a running app.
public enum StudioPlaybackKey: Equatable, Sendable {
    case togglePlayback
    /// Step by whole frames, for trimming to an exact one.
    case step(frames: Int)
    /// Jump by seconds, for getting across a long recording.
    case skip(seconds: TimeInterval)

    /// What an event means, or nil for "not ours — let it keep travelling".
    ///
    /// Anything carrying ⌘ or ⌃ is left alone: those belong to the menus. ⇧ is left alone
    /// too, because the focused timeline uses ⇧-arrow for its own larger nudge.
    public static func match(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> StudioPlaybackKey? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.isSubset(of: [.option, .function, .numericPad]) else { return nil }
        let option = flags.contains(.option)
        switch keyCode {
        case kVK_Space:
            return option ? nil : .togglePlayback
        case kVK_LeftArrow:
            return option ? .skip(seconds: -5) : .step(frames: -1)
        case kVK_RightArrow:
            return option ? .skip(seconds: 5) : .step(frames: 1)
        default:
            return nil
        }
    }
}
