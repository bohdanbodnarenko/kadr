import Foundation
import Testing
@testable import ControlKit

/// Typing a value into a slider (docs/09 U1.5).
///
/// Table-driven because parsing user input is where a control like this goes wrong, and it
/// goes wrong quietly: an unparsed "45%" that silently becomes zero looks like the slider
/// jumping for no reason.
@Suite("Slider value format")
struct SliderValueFormatTests {
    // MARK: - Writing

    @Test("A per-cent value is written the way it is read", arguments: [
        (0.0, "0%"),
        (0.45, "45%"),
        (1.0, "100%")
    ])
    func percentFormatting(value: Double, expected: String) {
        #expect(SliderValueFormat.percent.string(for: value) == expected)
    }

    @Test("Each unit carries its own suffix")
    func suffixes() {
        #expect(SliderValueFormat.points.string(for: 12) == "12 px")
        #expect(SliderValueFormat.degrees.string(for: 30) == "30°")
        #expect(SliderValueFormat.multiplier.string(for: 1.5) == "1.50×")
        #expect(SliderValueFormat(unit: .plain).string(for: 7) == "7")
    }

    // MARK: - Reading

    /// The round trip that matters: a field showing "45%" has to accept "45%".
    ///
    /// To within the field's own precision, which is the honest bound — a field that shows
    /// whole degrees cannot promise to remember a quarter of one, and pretending otherwise
    /// would be testing the display rather than the parser.
    @Test("Whatever the field shows, the field accepts", arguments: [
        SliderValueFormat.percent,
        .points,
        .degrees,
        .multiplier
    ])
    func roundTrips(format: SliderValueFormat) throws {
        let tolerance = 0.5 / (pow(10, Double(format.decimals)) * format.unit.displayScale)
        for value in [0.0, 0.25, 1.0, 12.0] {
            let written = format.string(for: value)
            let read = try #require(format.value(from: written), "could not read back \(written)")
            #expect(abs(read - value) <= tolerance, "\(written) came back as \(read)")
        }
    }

    @Test("A bare number is accepted, because nobody retypes the suffix", arguments: [
        ("45", 0.45),
        ("0", 0.0),
        ("100", 1.0)
    ])
    func bareNumbers(text: String, expected: Double) throws {
        #expect(try #require(SliderValueFormat.percent.value(from: text)) == expected)
    }

    @Test("Every spelling of a unit is accepted", arguments: [
        "30deg", "30 deg", "30°", "30 degrees", "30"
    ])
    func degreeSpellings(text: String) throws {
        #expect(try #require(SliderValueFormat.degrees.value(from: text)) == 30)
    }

    @Test("Point spellings too", arguments: ["12px", "12 pt", "12 pts", "12 pixels", "12"])
    func pointSpellings(text: String) throws {
        #expect(try #require(SliderValueFormat.points.value(from: text)) == 12)
    }

    @Test("Multiplier spellings too", arguments: ["1.5×", "1.5x", "1.5"])
    func multiplierSpellings(text: String) throws {
        #expect(try #require(SliderValueFormat.multiplier.value(from: text)) == 1.5)
    }

    /// A stray unit from another field is a slip, not an instruction — the field knows
    /// what it means, so it takes the number and ignores the noise.
    @Test("The wrong unit is ignored rather than refused")
    func wrongUnitIsIgnored() throws {
        #expect(try #require(SliderValueFormat.percent.value(from: "45px")) == 0.45)
    }

    @Test("A comma decimal separator works, because most keyboards produce one")
    func commaSeparator() throws {
        #expect(try #require(SliderValueFormat.multiplier.value(from: "1,5")) == 1.5)
    }

    @Test("Whitespace and case do not matter", arguments: ["  45 %  ", "45 PERCENT", "45%"])
    func forgivingWhitespace(text: String) throws {
        #expect(try #require(SliderValueFormat.percent.value(from: text)) == 0.45)
    }

    @Test("A negative value is read as one")
    func negatives() throws {
        #expect(try #require(SliderValueFormat.degrees.value(from: "-30°")) == -30)
    }

    @Test("Nonsense is refused rather than turned into zero", arguments: [
        "", "   ", "abc", "%", "px", "1.2.3", "∞"
    ])
    func nonsenseIsRefused(text: String) {
        #expect(SliderValueFormat.percent.value(from: text) == nil)
    }

    // MARK: - Stepping

    /// An arrow key steps by one of whatever the field shows, not by one of what it
    /// stores — a per-cent field that stepped by 1.0 would leap from 45% to 145%.
    @Test("An arrow key steps by one of the displayed unit")
    func stepping() {
        #expect(abs(SliderValueFormat.percent.stepped(0.45, by: 1) - 0.46) < 0.0001)
        #expect(SliderValueFormat.degrees.stepped(30, by: -1) == 29)
        #expect(SliderValueFormat.points.stepped(12, by: 5) == 17)
        #expect(abs(SliderValueFormat.multiplier.stepped(1.5, by: 1) - 1.51) < 0.0001)
        #expect(abs(SliderValueFormat.seconds.stepped(1.5, by: -1) - 1.4) < 0.0001)
    }

    @Test("A signed range writes a leading plus so the field matches the detent")
    func signedPlus() {
        #expect(SliderValueFormat.degrees(signed: true).string(for: 30) == "+30°")
        #expect(SliderValueFormat.degrees(signed: true).string(for: -30) == "-30°")
        #expect(SliderValueFormat.degrees(signed: true).string(for: 0) == "0°")
        #expect(SliderValueFormat.percent(signed: true).string(for: 0.45) == "+45%")
    }

    /// Rounding a tiny negative number gives "-0", which reads as a value that is somehow not
    /// zero — and a drag past the end of a range, or a preview that nudges a value, produces them.
    @Test("Zero has no sign, however it was reached", arguments: [-0.004, -0.0, 0.004, 0.0])
    func negativeZero(value: Double) {
        #expect(SliderValueFormat.percent.string(for: value) == "0%")
        #expect(SliderValueFormat.percent(signed: true).string(for: value) == "0%")
        #expect(SliderValueFormat.percent.editingString(for: value) == "0")
    }

    @Test("A small value that does not round to zero keeps its sign")
    func smallValuesKeepTheirSign() {
        #expect(SliderValueFormat.percent.string(for: -0.006) == "-1%")
        #expect(SliderValueFormat.percent(signed: true).string(for: 0.006) == "+1%")
        #expect(SliderValueFormat.degrees(signed: true).string(for: 0.4) == "0°")
    }

    @Test("The focused field shows the number without the suffix")
    func editingOmitsSuffix() {
        #expect(SliderValueFormat.percent.editingString(for: 0.45) == "45")
        #expect(SliderValueFormat.points.editingString(for: 12) == "12")
        #expect(SliderValueFormat.multiplier.editingString(for: 1.5) == "1.50")
        #expect(SliderValueFormat.seconds.editingString(for: 1.5) == "1.5")
    }

    @Test("Settings units carry their own suffix and read it back")
    func settingsUnits() throws {
        #expect(SliderValueFormat.screenPoints.string(for: 240) == "240 pt")
        #expect(SliderValueFormat.wordsPerMinute.string(for: 150) == "150 wpm")
        #expect(try #require(SliderValueFormat.screenPoints.value(from: "240 pt")) == 240)
        #expect(try #require(SliderValueFormat.wordsPerMinute.value(from: "150wpm")) == 150)
        #expect(try #require(SliderValueFormat.wordsPerMinute.value(from: "150 words per minute")) == 150)
    }

    /// A slider with its own grid steps by that grid, not by one displayed unit.
    @Test("An explicit step size overrides the displayed unit")
    func explicitStepSize() {
        #expect(SliderValueFormat.wordsPerMinute.stepped(150, by: 1, stepSize: 5) == 155)
        #expect(abs(SliderValueFormat.percent.stepped(0.5, by: -2, stepSize: 0.05) - 0.4) < 0.0001)
    }

    @Test("Seconds are written with a unit and read back")
    func secondsRoundTrip() throws {
        #expect(SliderValueFormat.seconds.string(for: 1.5) == "1.5 s")
        #expect(try #require(SliderValueFormat.seconds.value(from: "1.5 s")) == 1.5)
        #expect(try #require(SliderValueFormat.seconds.value(from: "2sec")) == 2)
    }
}
