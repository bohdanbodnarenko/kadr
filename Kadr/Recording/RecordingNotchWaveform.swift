import SwiftUI

/// The live waveform in the notch's left ear (docs/03 §1.8).
///
/// What the ear showed before was a red dot: true, and the same at every moment of a
/// recording. This moves with the sound going into the file, which is the one thing about a
/// recording in progress that is worth a glance — a mic that has gone quiet, or a machine
/// recording silence, shows here before the file is a waste of ten minutes.
///
/// Its own leaf view, reading the meter and nothing else, because the level changes ten
/// times a second and anything that reads it redraws with it (PRD §8). The bars do not
/// animate on a timer either: each level lands on a short spring, and the springs' phase
/// offsets are what make five bars read as a waveform rather than five bars.
struct RecordingNotchWaveform: View {
    let meter: RecordingAudioMeterModel
    /// Recording, but paused or muted: the waveform rests instead of reporting silence as
    /// a flat line that looks like a broken microphone.
    var isResting = false
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 2

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(0 ..< Bars.count, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(
                        width: Self.barWidth,
                        height: Bars.height(level: meter.level, index: index, isResting: isResting)
                    )
            }
        }
        .opacity(isResting ? 0.45 : 1)
        .animation(barAnimation, value: meter.level)
        .animation(barAnimation, value: isResting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int((meter.level * 100).rounded())) percent")
    }

    /// Short, slightly springy: long enough to carry between two meter ticks, short enough
    /// that a clap still reads as a clap.
    private var barAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.18, dampingFraction: 0.72)
    }

    /// The bar heights, as arithmetic rather than as a view.
    ///
    /// Pulled out so the shape can be checked without a screen: that silence still draws an
    /// arc, that louder is taller everywhere, and that nothing outgrows the ear it sits in.
    nonisolated enum Bars {
        /// Taller in the middle, so a loud moment makes a shape rather than a block.
        static let weights: [CGFloat] = [0.55, 0.85, 1, 0.8, 0.5]
        static let minimumHeight: CGFloat = 3
        /// How much of the arc survives at silence.
        static let restingRise: CGFloat = 2.5
        static let maximumHeight: CGFloat = 14

        static var count: Int {
            weights.count
        }

        static func height(level: Float, index: Int, isResting: Bool) -> CGFloat {
            let weight = weights[min(max(index, 0), weights.count - 1)]
            // Even in silence the bars keep the arc, so a quiet room reads as a waveform at
            // rest rather than as a row of dots — which is what a broken meter looks like.
            let resting = minimumHeight + weight * restingRise
            guard !isResting else { return resting }
            let level = CGFloat(max(min(level, 1), 0))
            // The middle bars lead the outer ones by a fraction of the level, which is the
            // ripple that makes it look like sound travelling rather than a bar chart.
            let lead: CGFloat = switch index {
            case 2: 1
            case 1, 3: 0.88
            default: 0.72
            }
            return resting + (maximumHeight - resting) * level * weight * lead
        }
    }
}
