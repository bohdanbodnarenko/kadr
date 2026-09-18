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
    /// The shell's own size and shape. Slower and looser: this is the mass.
    static let shellResponse = 0.42
    static let shellDamping = 0.78

    /// Ears, row, waveform. Quicker and tighter, so nothing wobbles after the shell stops.
    static let contentResponse = 0.28
    static let contentDamping = 0.9

    /// The content waits this long before it follows, in seconds.
    ///
    /// Barely perceptible on its own — it is the difference between a shell that opens and
    /// a shell that opens *and then* fills.
    static let contentDelay = 0.055

    /// How far the shell stretches sideways at the moment a recording begins, and how long
    /// it takes to settle back.
    static let activationStretch = 1.035
    static let activationSettle = 0.5

    static func shell(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: shellResponse, dampingFraction: shellDamping)
    }

    static func content(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
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
