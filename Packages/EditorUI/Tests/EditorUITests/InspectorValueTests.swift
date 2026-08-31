import Foundation
import Testing
@testable import EditorUI

/// Typing a value into a slider (docs/09 U1.5).
///
/// Table-driven because parsing user input is where a control like this goes wrong, and it
/// goes wrong quietly: an unparsed "45%" that silently becomes zero looks like the slider
/// jumping for no reason.
@Suite("Inspector value format")
struct InspectorValueTests {
    // MARK: - Writing

    @Test("A per-cent value is written the way it is read", arguments: [
        (0.0, "0%"),
        (0.45, "45%"),
        (1.0, "100%")
    ])
    func percentFormatting(value: Double, expected: String) {
        #expect(InspectorValueFormat.percent.string(for: value) == expected)
    }

    @Test("Each unit carries its own suffix")
    func suffixes() {
        #expect(InspectorValueFormat.points.string(for: 12) == "12 px")
        #expect(InspectorValueFormat.degrees.string(for: 30) == "30°")
        #expect(InspectorValueFormat.multiplier.string(for: 1.5) == "1.50×")
        #expect(InspectorValueFormat(unit: .plain).string(for: 7) == "7")
    }

    // MARK: - Reading

    /// The round trip that matters: a field showing "45%" has to accept "45%".
    ///
    /// To within the field's own precision, which is the honest bound — a field that shows
    /// whole degrees cannot promise to remember a quarter of one, and pretending otherwise
    /// would be testing the display rather than the parser.
    @Test("Whatever the field shows, the field accepts", arguments: [
        InspectorValueFormat.percent,
        .points,
        .degrees,
        .multiplier
    ])
    func roundTrips(format: InspectorValueFormat) throws {
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
        #expect(try #require(InspectorValueFormat.percent.value(from: text)) == expected)
    }

    @Test("Every spelling of a unit is accepted", arguments: [
        "30deg", "30 deg", "30°", "30 degrees", "30"
    ])
    func degreeSpellings(text: String) throws {
        #expect(try #require(InspectorValueFormat.degrees.value(from: text)) == 30)
    }

    @Test("Point spellings too", arguments: ["12px", "12 pt", "12 pts", "12 pixels", "12"])
    func pointSpellings(text: String) throws {
        #expect(try #require(InspectorValueFormat.points.value(from: text)) == 12)
    }

    @Test("Multiplier spellings too", arguments: ["1.5×", "1.5x", "1.5"])
    func multiplierSpellings(text: String) throws {
        #expect(try #require(InspectorValueFormat.multiplier.value(from: text)) == 1.5)
    }

    /// A stray unit from another field is a slip, not an instruction — the field knows
    /// what it means, so it takes the number and ignores the noise.
    @Test("The wrong unit is ignored rather than refused")
    func wrongUnitIsIgnored() throws {
        #expect(try #require(InspectorValueFormat.percent.value(from: "45px")) == 0.45)
    }

    @Test("A comma decimal separator works, because most keyboards produce one")
    func commaSeparator() throws {
        #expect(try #require(InspectorValueFormat.multiplier.value(from: "1,5")) == 1.5)
    }

    @Test("Whitespace and case do not matter", arguments: ["  45 %  ", "45 PERCENT", "45%"])
    func forgivingWhitespace(text: String) throws {
        #expect(try #require(InspectorValueFormat.percent.value(from: text)) == 0.45)
    }

    @Test("A negative value is read as one")
    func negatives() throws {
        #expect(try #require(InspectorValueFormat.degrees.value(from: "-30°")) == -30)
    }

    @Test("Nonsense is refused rather than turned into zero", arguments: [
        "", "   ", "abc", "%", "px", "1.2.3", "∞"
    ])
    func nonsenseIsRefused(text: String) {
        #expect(InspectorValueFormat.percent.value(from: text) == nil)
    }

    // MARK: - Stepping

    /// An arrow key steps by one of whatever the field shows, not by one of what it
    /// stores — a per-cent field that stepped by 1.0 would leap from 45% to 145%.
    @Test("An arrow key steps by one of the displayed unit")
    func stepping() {
        #expect(abs(InspectorValueFormat.percent.stepped(0.45, by: 1) - 0.46) < 0.0001)
        #expect(InspectorValueFormat.degrees.stepped(30, by: -1) == 29)
        #expect(InspectorValueFormat.points.stepped(12, by: 5) == 17)
        #expect(abs(InspectorValueFormat.multiplier.stepped(1.5, by: 1) - 1.51) < 0.0001)
        #expect(abs(InspectorValueFormat.seconds.stepped(1.5, by: -1) - 1.4) < 0.0001)
    }

    @Test("A signed range writes a leading plus so the field matches the detent")
    func signedPlus() {
        #expect(InspectorValueFormat.degrees(signed: true).string(for: 30) == "+30°")
        #expect(InspectorValueFormat.degrees(signed: true).string(for: -30) == "-30°")
        #expect(InspectorValueFormat.degrees(signed: true).string(for: 0) == "0°")
        #expect(InspectorValueFormat.percent(signed: true).string(for: 0.45) == "+45%")
    }

    @Test("The focused field shows the number without the suffix")
    func editingOmitsSuffix() {
        #expect(InspectorValueFormat.percent.editingString(for: 0.45) == "45")
        #expect(InspectorValueFormat.points.editingString(for: 12) == "12")
        #expect(InspectorValueFormat.multiplier.editingString(for: 1.5) == "1.50")
        #expect(InspectorValueFormat.seconds.editingString(for: 1.5) == "1.5")
    }

    @Test("Seconds are written with a unit and read back")
    func secondsRoundTrip() throws {
        #expect(InspectorValueFormat.seconds.string(for: 1.5) == "1.5 s")
        #expect(try #require(InspectorValueFormat.seconds.value(from: "1.5 s")) == 1.5)
        #expect(try #require(InspectorValueFormat.seconds.value(from: "2sec")) == 2)
    }
}
