import Foundation

/// How much of the end of a recording is the act of stopping it (docs/03 §1.8).
///
/// Every screen recording ends with the same few seconds: the pointer leaves whatever was
/// being demonstrated, travels to the corner, and presses Stop. macOS trims that off its
/// own screen recordings, and the reason is not tidiness — it is that those seconds are the
/// last thing a viewer sees, and they are of somebody hunting for a button.
///
/// Only the travel is cut, never a fixed amount: a stop pressed straight away has nothing
/// in front of it to remove, and cutting a constant would eat the end of a demo that
/// finished on the button.
///
/// Pure, because the decision is arithmetic and the consequences are destructive: this
/// decides what is *not written to the file*, so it is checked by tests rather than by
/// watching a recording afterwards and wondering.
public enum StopTailPolicy: Sendable {
    /// Below this, the travel is a click that landed where the pointer already was.
    public static let minimumTail: TimeInterval = 0.2
    /// However long somebody took to find the button, this is all that comes off.
    ///
    /// A pointer resting on the controls for a minute before the click is not a minute of
    /// travel — it is a minute of the recording, most likely of the thing being recorded.
    public static let maximumTail: TimeInterval = 2.5
    /// What must survive the trim, so stopping quickly cannot leave nothing at all.
    public static let minimumRemaining: TimeInterval = 1

    /// The seconds to drop from the end.
    ///
    /// - Parameters:
    ///   - travel: how long the pointer had been on Kadr's own controls when Stop was
    ///     pressed, or nil when the stop did not come from them — a hotkey, automation, the
    ///     stream dying. Nothing is trimmed in that case: the pointer never went anywhere,
    ///     and the last second is as much a part of the recording as any other.
    ///   - duration: what has been recorded so far.
    public static func tail(travel: TimeInterval?, duration: TimeInterval) -> TimeInterval {
        guard let travel, travel >= minimumTail, duration > minimumRemaining else { return 0 }
        let wanted = min(travel, maximumTail)
        // Never past the floor: a four-second take stopped after a long hunt keeps its
        // first second rather than becoming an empty file.
        return max(min(wanted, duration - minimumRemaining), 0)
    }
}
