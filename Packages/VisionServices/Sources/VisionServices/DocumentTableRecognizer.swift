import CoreGraphics
import Foundation
import os
import Shared
import Vision

/// Reads tables out of a capture (docs/06 M25).
///
/// `RecognizeDocumentsRequest` understands document structure — paragraphs, lists,
/// tables — rather than only lines of text. It is a recent addition to Vision's Swift
/// API, and Kadr ships to macOS 14, so this is entirely behind an availability check: on
/// older systems it finds nothing, the ordinary text recognition still runs, and "Copy as
/// Table" is simply not offered.
public struct DocumentTableRecognizer: Sendable {
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    public init() {}

    /// Whether this system can read tables at all.
    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// The tables in an image, in the order the recogniser found them.
    ///
    /// Never throws for "there was no table" — that is the common case, and an empty
    /// array says it without the caller having to catch anything.
    public func tables(in image: CGImage) async -> [RecognizedTable] {
        guard #available(macOS 26.0, *) else { return [] }

        let state = signposter.beginInterval("recognizeTables")
        defer { signposter.endInterval("recognizeTables", state) }

        do {
            let request = RecognizeDocumentsRequest()
            let observations = try await request.perform(on: image)
            let tables = observations.flatMap { Self.tables(in: $0.document) }
            logger.info("Found \(tables.count, privacy: .public) table(s)")
            return tables
        } catch {
            logger.error("Table recognition failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    @available(macOS 26.0, *)
    private static func tables(in container: DocumentObservation.Container) -> [RecognizedTable] {
        container.tables.map { table in
            RecognizedTable(rows: table.rows.map { row in
                row.map { cell in
                    cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            })
        }
    }
}
