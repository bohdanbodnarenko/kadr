import CoreGraphics
import Testing
@testable import Kadr

/// The notch's waveform and the choreography it lives in (docs/03 §1.8).
@Suite("Recording notch motion")
struct RecordingNotchMotionTests {
    private typealias Bars = RecordingNotchWaveform.Bars

    @Test("Silence still draws a waveform, not a row of dots")
    func silenceKeepsItsShape() {
        let heights = (0 ..< Bars.count).map { Bars.height(level: 0, index: $0, isResting: false) }

        #expect(Set(heights).count > 1, "a flat line is what a broken meter looks like")
        #expect(heights[2] == heights.max(), "the middle bar leads")
        #expect(heights.allSatisfy { $0 >= Bars.minimumHeight })
    }

    @Test("Louder is taller, on every bar", arguments: 0 ..< 5)
    func levelRaisesEveryBar(index: Int) {
        let quiet = Bars.height(level: 0.1, index: index, isResting: false)
        let middling = Bars.height(level: 0.5, index: index, isResting: false)
        let loud = Bars.height(level: 1, index: index, isResting: false)

        #expect(quiet < middling)
        #expect(middling < loud)
    }

    @Test("Nothing outgrows the ear it sits in", arguments: [-3.0, 0.0, 0.5, 1.0, 40.0])
    func heightsStayInRange(level: Double) {
        for index in 0 ..< Bars.count {
            let height = Bars.height(level: Float(level), index: index, isResting: false)
            #expect(height >= Bars.minimumHeight)
            #expect(height <= Bars.maximumHeight)
        }
    }

    /// A muted or silent microphone rests rather than reporting a flat line as a level.
    @Test("Resting sits below the same level playing")
    func restingIsQuieter() {
        for index in 0 ..< Bars.count {
            let resting = Bars.height(level: 0.9, index: index, isResting: true)
            let live = Bars.height(level: 0.9, index: index, isResting: false)
            #expect(resting < live)
            #expect(resting == Bars.height(level: 0, index: index, isResting: false))
        }
    }

    /// The shell is the mass and the content is what lands in it: the shell moves for
    /// longer, the content settles harder, and it starts a beat later.
    @Test("The shell leads and the content follows")
    func choreographyHasTwoWeights() {
        #expect(RecordingNotchMorph.shellResponse > RecordingNotchMorph.contentResponse)
        #expect(RecordingNotchMorph.contentDamping > RecordingNotchMorph.shellDamping)
        #expect(RecordingNotchMorph.contentDelay > 0)
        // Perceptible as a sequence, not as a pause.
        #expect(RecordingNotchMorph.contentDelay < 0.12)
    }

    @Test("The activation stretch is sideways and slight")
    func activationIsSubtle() {
        #expect(RecordingNotchMorph.stretch(isStretching: true, reduceMotion: false) > 1)
        #expect(RecordingNotchMorph.stretch(isStretching: true, reduceMotion: false) < 1.08)
        #expect(RecordingNotchMorph.stretch(isStretching: false, reduceMotion: false) == 1)
    }

    @Test("Reduce Motion turns the whole choreography off")
    func reduceMotionStopsEverything() {
        #expect(RecordingNotchMorph.shell(reduceMotion: true) == nil)
        #expect(RecordingNotchMorph.content(reduceMotion: true) == nil)
        #expect(RecordingNotchMorph.activation(reduceMotion: true) == nil)
        #expect(RecordingNotchMorph.stretch(isStretching: true, reduceMotion: true) == 1)
        // And leaves them on otherwise.
        #expect(RecordingNotchMorph.shell(reduceMotion: false) != nil)
    }
}
