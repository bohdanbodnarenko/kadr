import Foundation
import SwiftUI

/// How the notch shell moves between its states (docs/03 §1.8).
///
/// One spring per *thing that moves*, not one spring for the view. The shell's size is
/// heavy and overshoots a little; the content inside it is light, settles sooner, and
/// arrives a beat later — which is what makes the shell read as stretching and the content
/// as landing in it, rather than the whole thing scaling as one picture.
///
/// The numbers are here, together and named, because they are a choreography: changing one
/// without the others is what turns a fluid morph into three unrelated animations.
nonisolated enum RecordingNotchMorph {
    /// The shell's own size and shape while it opens. Slower and looser: this is the mass.
    static let shellResponse = 0.42
    static let shellDamping = 0.78

    /// Closing is a different gesture from opening, and wants different numbers.
    ///
    /// Opening is an offer and can afford to overshoot; closing is an answer — the user has
    /// left, and the shell's job is to be out of the way. Quicker, and damped hard enough
    /// that it does not spring back open a hair's width on the way, which reads as the shell
    /// changing its mind.
    static let collapseResponse = 0.26
    static let collapseDamping = 0.95

    /// Ears, row, waveform. Quicker and tighter, so nothing wobbles after the shell stops.
    static let contentResponse = 0.28
    static let contentDamping = 0.9

    /// What the row leaves in, closing: short enough to be gone before the shell has
    /// finished shrinking, long enough not to blink out of existence.
    static let collapseContentResponse = 0.14

    /// The content waits this long before it follows, in seconds.
    ///
    /// Barely perceptible on its own — it is the difference between a shell that opens and
    /// a shell that opens *and then* fills. Only on the way open: closing, the content
    /// leads and the shell follows it down, which is the same order in reverse.
    static let contentDelay = 0.055

    /// How long the pointer can be off the shell before it closes, in milliseconds.
    ///
    /// Long enough to cross the seam between the shell and its tooltip, short enough that
    /// leaving reads as a decision. It was 350, which is a third of a second of a panel
    /// hanging over somebody's work after they have moved on.
    static let collapseDelayMilliseconds = 180

    /// How far the shell stretches sideways at the moment a recording begins, and how long
    /// it takes to settle back.
    static let activationStretch = 1.035
    static let activationSettle = 0.5

    static func shell(isExpanding: Bool = true, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        guard isExpanding else {
            return .spring(response: collapseResponse, dampingFraction: collapseDamping)
        }
        return .spring(response: shellResponse, dampingFraction: shellDamping)
    }

    static func content(isExpanding: Bool = true, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        guard isExpanding else {
            // No delay on the way out: the content leads and the shell closes behind it, so
            // the shell is never a black box with nothing in it.
            return .spring(response: collapseContentResponse, dampingFraction: 1)
        }
        return .spring(response: contentResponse, dampingFraction: contentDamping)
            .delay(contentDelay)
    }

    /// The settle after the activation stretch: a softer spring, no delay.
    static func activation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: activationSettle, dampingFraction: 0.62)
    }

    /// The horizontal scale to draw the shell at, for a state that has just changed.
    ///
    /// Only sideways, and only a little: the shell's top edge is the display's top edge, so
    /// anything that scales vertically lifts it off the hardware and shows a line of
    /// wallpaper where the housing should be.
    static func stretch(isStretching: Bool, reduceMotion: Bool) -> CGFloat {
        guard isStretching, !reduceMotion else { return 1 }
        return activationStretch
    }
}
