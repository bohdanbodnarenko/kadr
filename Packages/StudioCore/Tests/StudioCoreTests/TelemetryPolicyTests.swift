import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

/// What the pointer recorder decides, without the plumbing (docs/09 U3.1).
///
/// The privacy rule is the important one here, and it is the one that would otherwise be
/// untestable: it lives in the agent's event callback, which needs a TCC grant and a
/// running user. Lifted out, it is a function, and a function can be checked exhaustively.
@Suite("Telemetry policy")
struct TelemetryPolicyTests {
    // MARK: - Privacy

    /// The rule, stated plainly: plain typing never reaches the sidecar. There is no
    /// setting to turn this off, because a keylogger that is off by default is still a
    /// keylogger in the file format.
    @Test("Plain characters are never captioned", arguments: ["a", "z", "5", "é", "!", " "])
    func plainTypingIsNotRecorded(character: String) {
        #expect(TelemetryPolicy.caption(characters: character, specialKey: nil, modifiers: []) == nil)
    }

    /// Shift alone is how capital letters are typed. Treating it as a chord would record
    /// every capitalised word somebody types.
    @Test("Shift alone does not make a chord")
    func shiftIsNotAChord() {
        #expect(TelemetryPolicy.caption(characters: "a", specialKey: nil, modifiers: [.shift]) == nil)
        #expect(!TelemetryPolicy.Modifiers.shift.makesChord)
    }

    struct ChordCase: Sendable {
        var modifiers: TelemetryPolicy.Modifiers
        var key: String
        var expected: String
    }

    static let chordCases: [ChordCase] = [
        ChordCase(modifiers: .command, key: "s", expected: "⌘S"),
        ChordCase(modifiers: [.command, .shift], key: "4", expected: "⇧⌘4"),
        ChordCase(modifiers: [.control, .option, .command], key: "d", expected: "⌃⌥⌘D"),
        ChordCase(modifiers: .option, key: "e", expected: "⌥E")
    ]

    @Test("A chord is captioned", arguments: chordCases)
    func chordsAreCaptioned(testCase: ChordCase) {
        let caption = TelemetryPolicy.caption(
            characters: testCase.key,
            specialKey: nil,
            modifiers: testCase.modifiers
        )
        #expect(caption == testCase.expected)
    }

    /// Navigation and commitment explain a recording; the letters somebody typed are a
    /// transcript of their password.
    @Test("Special keys are captioned on their own", arguments: TelemetryPolicy.SpecialKey.allCases)
    func specialKeysAreCaptioned(key: TelemetryPolicy.SpecialKey) {
        let caption = TelemetryPolicy.caption(characters: nil, specialKey: key, modifiers: [])
        #expect(caption == key.caption)
        #expect(!key.caption.isEmpty)
    }

    @Test("A special key with modifiers shows both")
    func specialKeyWithModifiers() {
        let caption = TelemetryPolicy.caption(
            characters: nil,
            specialKey: .returnKey,
            modifiers: [.command]
        )
        #expect(caption == "⌘Return")
    }

    @Test("Modifier symbols come out in the order macOS uses")
    func modifierOrder() {
        let all: TelemetryPolicy.Modifiers = [.command, .shift, .option, .control]
        #expect(all.symbols == "⌃⌥⇧⌘")
    }

    @Test("A chord with nothing to press is not a caption")
    func chordWithoutAKey() {
        #expect(TelemetryPolicy.caption(characters: nil, specialKey: nil, modifiers: [.command]) == nil)
        #expect(TelemetryPolicy.caption(characters: "", specialKey: nil, modifiers: [.command]) == nil)
    }

    /// A chord is conventionally written ⌘S rather than ⌘s, whatever the shift state was.
    @Test("A chord's letter is upper-cased")
    func chordLettersAreUpperCased() {
        #expect(TelemetryPolicy.caption(characters: "s", specialKey: nil, modifiers: [.command]) == "⌘S")
    }

    // MARK: - Sampling

    @Test("The first sample is always worth recording")
    func firstSample() {
        #expect(TelemetryPolicy.shouldRecord(.zero, at: 0, lastSample: nil))
    }

    /// A sample too soon after the last one adds a row and no information.
    @Test("A sample too soon is skipped")
    func tooSoon() {
        let last = PointerSample(time: 1, position: .zero)
        #expect(!TelemetryPolicy.shouldRecord(CGPoint(x: 100, y: 100), at: 1.001, lastSample: last))
    }

    /// A pointer sitting still is inferred perfectly well from the absence of samples.
    @Test("A sample in the same place is skipped")
    func sameePlace() {
        let last = PointerSample(time: 1, position: CGPoint(x: 10, y: 10))
        #expect(!TelemetryPolicy.shouldRecord(CGPoint(x: 10, y: 10), at: 2, lastSample: last))
    }

    @Test("A real move after enough time is recorded")
    func realMove() {
        let last = PointerSample(time: 1, position: CGPoint(x: 10, y: 10))
        #expect(TelemetryPolicy.shouldRecord(CGPoint(x: 40, y: 40), at: 1.1, lastSample: last))
    }

    @Test("The sample rate is the display's, not higher")
    func sampleRate() {
        #expect(TelemetryPolicy.sampleRate <= 60)
    }

    // MARK: - The fallback ladder

    /// Each rung fails independently and quietly, so the ladder has to have a floor.
    static let ladderCases: [(availability: TelemetryPolicy.Availability, expected: TelemetrySource)] = [
        (TelemetryPolicy.Availability(hasEventTap: true, hasAppKitMonitors: true), .eventTap),
        (TelemetryPolicy.Availability(hasEventTap: true, hasAppKitMonitors: false), .eventTap),
        (TelemetryPolicy.Availability(hasEventTap: false, hasAppKitMonitors: true), .appKitMonitors),
        (TelemetryPolicy.Availability(hasEventTap: false, hasAppKitMonitors: false), .sampler)
    ]

    @Test("The best available source is chosen", arguments: ladderCases)
    func fallbackLadder(testCase: (availability: TelemetryPolicy.Availability, expected: TelemetrySource)) {
        #expect(TelemetryPolicy.source(for: testCase.availability) == testCase.expected)
    }

    /// There is always a source: a recording with no telemetry at all is worse than a
    /// coarse one, because the studio has nothing to reconstruct from.
    @Test("There is always a source, however little is available")
    func thereIsAlwaysAFloor() {
        #expect(TelemetryPolicy.source(for: TelemetryPolicy.Availability()) == .sampler)
    }

    /// A tap macOS has disabled reports nothing and says nothing, so silence is the only
    /// signal there is.
    @Test("A dead tap is detected by silence, within a couple of seconds")
    func silenceTimeout() {
        #expect(TelemetryPolicy.tapSilenceTimeout > 0)
        #expect(TelemetryPolicy.tapSilenceTimeout <= 5, "a long timeout loses the start of the recording")
    }
}
