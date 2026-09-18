import Foundation

/// How much of the end of a recording is the act of stopping it (docs/03 §1.8).
///
/// Every screen recording ends with the same few seconds: the pointer leaves whatever was
/// being demonstrated, travels to the corner, and presses Stop. macOS trims that off its
/// own screen recordings, and the reason is not tidiness — it is that those seconds are the
/// last thing a viewer sees, and they are of somebody hunting for a button.
///
/// The trip to the button is the *budget*, never the answer on its own. Everything else
/// here exists to give some of it back, because the cost of trimming a second too much is
/// far higher than the cost of leaving one: a viewer who sees an extra second of a pointer
/// travelling has seen an untidy ending, and a presenter whose last three words were cut
/// has lost the point of the recording.
///
/// Three signals say "this was still the recording", and the latest of them wins:
///
/// * **Speech and sound.** Somebody saying "…and that's it, thanks" while reaching for
///   Stop is talking over the whole trip. Nothing is cut over live audio.
/// * **Clicks and keystrokes.** A press is content, and the second after it is the result
///   of that press, which is the thing worth showing.
/// * **The floor.** A short take stopped after a long hunt keeps a second of itself rather
///   than becoming an empty file.
///
/// Pure, because the decision is arithmetic and the consequences are destructive: this
/// decides what is *not written to the file*.
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
    /// Kept after the last click or keystroke, so the result of it is on screen.
    public static let inputGrace: TimeInterval = 0.8
    /// Kept after the last sound, so a sentence is not clipped on its final consonant.
    public static let audioGrace: TimeInterval = 0.4
    /// Loud enough to be someone talking rather than a room.
    ///
    /// The meter is normalised peak, and the level a quiet room idles at on a laptop
    /// microphone sits under this.
    public static let audibleLevel: Float = 0.06

    /// What the recording itself was still doing as it ended.
    public struct Content: Sendable, Hashable {
        /// When the last click or keystroke landed, on the recording's clock. Kadr's own
        /// controls are not in the telemetry, so this is the user's work, not their stop.
        public var lastInput: TimeInterval?
        /// When audio was last above `audibleLevel`.
        public var lastAudible: TimeInterval?

        public init(lastInput: TimeInterval? = nil, lastAudible: TimeInterval? = nil) {
            self.lastInput = lastInput
            self.lastAudible = lastAudible
        }

        /// The last moment the recording was still showing something, with the grace each
        /// kind of evidence earns.
        var lastMoment: TimeInterval? {
            let moments = [
                lastInput.map { $0 + inputGrace },
                lastAudible.map { $0 + audioGrace }
            ].compactMap(\.self)
            return moments.max()
        }
    }

    /// The seconds to drop from the end.
    ///
    /// - Parameters:
    ///   - travel: how long the pointer had been on Kadr's own controls when Stop was
    ///     pressed, or nil when the stop did not come from them — a hotkey, automation, the
    ///     stream dying. Nothing is trimmed in that case: the pointer never went anywhere,
    ///     and the last second is as much a part of the recording as any other.
    ///   - content: what the recording was still doing while that trip happened.
    ///   - duration: what has been recorded so far.
    public static func tail(
        travel: TimeInterval?,
        content: Content = Content(),
        duration: TimeInterval
    ) -> TimeInterval {
        guard let travel, travel >= minimumTail, duration > minimumRemaining else { return 0 }

        // The trip is the most that can come off: it is the only span anyone knows was
        // navigation. Everything below can shorten it and nothing can lengthen it.
        var tail = min(travel, maximumTail)

        // Content that ran into the trip takes its own time back.
        if let lastMoment = content.lastMoment {
            tail = min(tail, max(duration - lastMoment, 0))
        }

        // And the floor, so a short take survives its own ending.
        tail = min(tail, max(duration - minimumRemaining, 0))

        // Under the floor after all that, there was nothing to trim in the first place.
        return tail >= minimumTail ? tail : 0
    }
}
