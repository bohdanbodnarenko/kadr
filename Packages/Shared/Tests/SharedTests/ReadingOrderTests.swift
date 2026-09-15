import CoreGraphics
import Foundation
import Testing
@testable import Shared

@Suite("OCR reading order")
struct ReadingOrderTests {
    @Test("Split fragments on one row join left to right")
    func splitFragmentsJoin() {
        let lines = [
            RecognizedLine(text: "World", confidence: 1, boundingBox: CGRect(x: 0.5, y: 0.4, width: 0.3, height: 0.1)),
            RecognizedLine(text: "Hello", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.41, width: 0.3, height: 0.1))
        ]
        let rows = ReadingOrder.visualLines(lines)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.text) == ["Hello", "World"])
        #expect(ReadingOrder.joinedText(lines, preservingLineBreaks: true) == "Hello World")
    }

    @Test("A two-column form becomes two rows")
    func twoColumnForm() {
        let lines = [
            RecognizedLine(text: "Name", confidence: 1, boundingBox: CGRect(x: 0.05, y: 0.7, width: 0.2, height: 0.08)),
            RecognizedLine(text: "Ada", confidence: 1, boundingBox: CGRect(x: 0.5, y: 0.7, width: 0.2, height: 0.08)),
            RecognizedLine(text: "City", confidence: 1, boundingBox: CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.08)),
            RecognizedLine(text: "Paris", confidence: 1, boundingBox: CGRect(x: 0.5, y: 0.4, width: 0.2, height: 0.08))
        ]
        let rows = ReadingOrder.visualLines(lines)
        #expect(rows.count == 2)
        #expect(ReadingOrder.joinedText(lines, preservingLineBreaks: true) == "Name\tAda\nCity\tParis")
    }

    @Test("Slightly skewed boxes on one line still group")
    func skewedLineGroups() {
        let lines = [
            RecognizedLine(text: "The", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.50, width: 0.15, height: 0.1)),
            RecognizedLine(
                text: "quick",
                confidence: 1,
                boundingBox: CGRect(x: 0.28, y: 0.53, width: 0.2, height: 0.1)
            ),
            RecognizedLine(text: "fox", confidence: 1, boundingBox: CGRect(x: 0.52, y: 0.49, width: 0.15, height: 0.1))
        ]
        #expect(ReadingOrder.visualLines(lines).count == 1)
    }

    @Test("An empty list stays empty")
    func emptyList() {
        #expect(ReadingOrder.visualLines([]).isEmpty)
        #expect(ReadingOrder.joinedText([], preservingLineBreaks: true).isEmpty)
    }
}
