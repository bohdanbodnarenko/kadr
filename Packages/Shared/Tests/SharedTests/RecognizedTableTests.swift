import Foundation
import Testing
@testable import Shared

/// Turning a recognised table into something pasteable (docs/06 M25).
///
/// The formatting is the feature: a grid that pastes into Numbers with the columns
/// shifted, or a Markdown table that a stray `|` breaks, is worse than plain text.
@Suite("Recognized tables")
struct RecognizedTableTests {
    private let table = RecognizedTable(rows: [
        ["Name", "Status", "Owner"],
        ["Build", "Passing", "CI"],
        ["Deploy", "Failing", "Ops"]
    ])

    @Test("Tab-separated output is one line per row")
    func tabSeparated() {
        #expect(table.tabSeparated == """
        Name\tStatus\tOwner
        Build\tPassing\tCI
        Deploy\tFailing\tOps
        """)
    }

    @Test("Markdown uses the first row as the header")
    func markdown() {
        #expect(table.markdown == """
        | Name | Status | Owner |
        | --- | --- | --- |
        | Build | Passing | CI |
        | Deploy | Failing | Ops |
        """)
    }

    /// The failure this prevents: a spreadsheet paste where every row after the ragged
    /// one is shifted a column left.
    @Test("A ragged table is padded so the columns stay aligned")
    func raggedRowsArePadded() {
        let ragged = RecognizedTable(rows: [["a", "b", "c"], ["d"], ["e", "f"]])
        #expect(ragged.columnCount == 3)
        #expect(ragged.rows[1] == ["d", "", ""])
        #expect(ragged.tabSeparated == "a\tb\tc\nd\t\t\ne\tf\t")
    }

    @Test("A tab inside a cell cannot break the grid")
    func tabsInsideCells() {
        let awkward = RecognizedTable(rows: [["one\ttwo", "three"], ["four", "five"]])
        #expect(awkward.tabSeparated.split(separator: "\n").allSatisfy { $0.filter { $0 == "\t" }.count == 1 })
    }

    @Test("A newline inside a cell cannot break the row")
    func newlinesInsideCells() {
        let awkward = RecognizedTable(rows: [["one\ntwo", "three"], ["four", "five"]])
        #expect(awkward.tabSeparated.split(separator: "\n").count == 2)
    }

    @Test("A pipe inside a cell is escaped so Markdown survives it")
    func pipesAreEscaped() {
        let awkward = RecognizedTable(rows: [["a|b", "c"], ["d", "e"]])
        #expect(awkward.markdown.contains("a\\|b"))
    }

    @Test("Something that is not really a table is not offered as one", arguments: [
        [["only one row", "here"]],
        [["one column"], ["per row"]],
        []
    ])
    func meaningfulness(rows: [[String]]) {
        #expect(!RecognizedTable(rows: rows).isMeaningful)
    }

    @Test("A real grid is offered")
    func realGridIsMeaningful() {
        #expect(table.isMeaningful)
        #expect(table.rowCount == 3)
        #expect(table.columnCount == 3)
    }

    /// Markdown has no way to express a table without a header row, so a table too small
    /// to have one falls back to something that still pastes.
    @Test("A table too small for Markdown falls back to tab-separated")
    func tinyTableFallsBack() {
        let tiny = RecognizedTable(rows: [["a"]])
        #expect(tiny.markdown == tiny.tabSeparated)
    }

    @Test("The largest table is the one the toast offers")
    func primaryTableIsTheLargest() {
        let analysis = VisionAnalysis(tables: [
            RecognizedTable(rows: [["a", "b"], ["c", "d"]]),
            table
        ])
        #expect(analysis.primaryTable == table)
    }

    @Test("A capture with no real table offers none")
    func noPrimaryTable() {
        let analysis = VisionAnalysis(tables: [RecognizedTable(rows: [["lonely"]])])
        #expect(analysis.primaryTable == nil)
    }

    @Test("Tables survive the trip from the helper")
    func codableRoundTrip() throws {
        let analysis = VisionAnalysis(lines: [], tables: [table])
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(VisionAnalysis.self, from: data)
        #expect(decoded.tables == [table])
    }

    /// An analysis encoded before tables existed still decodes.
    @Test("An older payload with no tables decodes as having none")
    func decodesLegacyPayload() throws {
        let json = Data(#"{"lines":[],"codes":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(VisionAnalysis.self, from: json)
        #expect(decoded.tables.isEmpty)
    }
}

/// HDR, and what it means for a capture (docs/04 §4.1, §4.3, docs/06 M25).
@Suite("Dynamic range")
struct DynamicRangeTests {
    @Test("Standard is the default, because HDR looks wrong in apps that ignore it")
    func standardIsDefault() {
        #expect(DynamicRange.standard.resolved == .standard)
        #expect(!DynamicRange.standard.isHigh)
    }

    @Test("HDR degrades to standard when the system cannot do it")
    func degradesGracefully() {
        // Whichever system this runs on, `resolved` must never claim a range the system
        // cannot produce.
        #expect(DynamicRange.high.resolved == (DynamicRange.isAvailable ? .high : .standard))
    }

    @Test("The settings UI only offers what the system can do")
    func availableMatchesTheSystem() {
        #expect(DynamicRange.available.contains(.standard))
        #expect(DynamicRange.available.contains(.high) == DynamicRange.isAvailable)
    }

    @Test("Only formats that carry more than eight bits are used for an HDR capture")
    func formatsForHDR() {
        #expect(ImageFormat.heic.supportsHighBitDepth)
        #expect(ImageFormat.png.supportsHighBitDepth)
        #expect(!ImageFormat.jpeg.supportsHighBitDepth)
        #expect(!ImageFormat.webp.supportsHighBitDepth)
    }
}
