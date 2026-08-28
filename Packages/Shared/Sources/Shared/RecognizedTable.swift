import Foundation

/// A table read out of a capture (docs/06 M25).
///
/// Screenshots of tables are one of the most common things people take and one of the
/// most annoying to retype. macOS 15's document recogniser can see the grid, so Kadr can
/// hand back something that pastes into a spreadsheet instead of a wall of text.
public struct RecognizedTable: Codable, Sendable, Hashable {
    /// Rows of cells, already in reading order. Ragged rows are padded so every row has
    /// the same number of columns — a spreadsheet paste with uneven rows is worse than
    /// one with a blank cell.
    public let rows: [[String]]

    public init(rows: [[String]]) {
        let width = rows.map(\.count).max() ?? 0
        self.rows = rows.map { row in
            row + Array(repeating: "", count: max(0, width - row.count))
        }
    }

    public var rowCount: Int {
        rows.count
    }

    public var columnCount: Int {
        rows.first?.count ?? 0
    }

    /// A table has to have at least two of each to be worth calling one; anything less
    /// is a list, and the plain text is a better answer for it.
    public var isMeaningful: Bool {
        rowCount >= 2 && columnCount >= 2
    }

    /// Tab-separated, which is what pastes straight into Numbers, Excel and Sheets.
    ///
    /// Tabs inside a cell would break the grid, so they become spaces — a cell that says
    /// the wrong thing is worse than one that lost its indentation.
    public var tabSeparated: String {
        rows
            .map { row in row.map(Self.flattened).joined(separator: "\t") }
            .joined(separator: "\n")
    }

    /// A GitHub-flavoured Markdown table, for pasting into a pull request or an issue.
    ///
    /// The first row becomes the header, because that is what it almost always is and
    /// Markdown has no way to express a table without one.
    public var markdown: String {
        guard isMeaningful, let header = rows.first else { return tabSeparated }
        var lines = ["| " + header.map(Self.escapedForMarkdown).joined(separator: " | ") + " |"]
        lines.append("|" + String(repeating: " --- |", count: header.count))
        for row in rows.dropFirst() {
            lines.append("| " + row.map(Self.escapedForMarkdown).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func flattened(_ cell: String) -> String {
        cell
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A pipe inside a cell would end the column early.
    private static func escapedForMarkdown(_ cell: String) -> String {
        flattened(cell).replacingOccurrences(of: "|", with: "\\|")
    }
}
