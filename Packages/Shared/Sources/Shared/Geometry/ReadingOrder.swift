import CoreGraphics
import Foundation

/// Groups OCR boxes into visual reading order (docs/16 X-4).
///
/// Vision returns observations in an order that is not a reading order. Lines whose
/// vertical centres overlap by half a box height belong together; each group is then
/// left to right. A tolerance comparator is not a strict weak ordering, so this is an
/// explicit grouping pass rather than a sort.
public enum ReadingOrder: Sendable {
    /// Lines grouped into visual rows, each row already left-to-right.
    public static func visualLines(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
        guard !lines.isEmpty else { return [] }
        let ordered = lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) < 0.0001 {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        var rows: [[RecognizedLine]] = []
        for line in ordered {
            if let index = rows.firstIndex(where: { belongs(line, in: $0) }) {
                rows[index].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }
    }

    /// Joins grouped lines. Words on one row are spaced, or tab-separated when the gap
    /// is more than about twice the median character width.
    public static func joinedText(_ lines: [RecognizedLine], preservingLineBreaks: Bool) -> String {
        let rows = visualLines(lines)
        let rowTexts = rows.map(join(row:))
        return rowTexts.joined(separator: preservingLineBreaks ? "\n" : " ")
    }

    private static func belongs(_ line: RecognizedLine, in row: [RecognizedLine]) -> Bool {
        guard let seed = row.first else { return false }
        let tolerance = max(line.boundingBox.height, seed.boundingBox.height) / 2
        return abs(line.boundingBox.midY - seed.boundingBox.midY) <= tolerance
    }

    private static func join(row: [RecognizedLine]) -> String {
        guard let first = row.first else { return "" }
        guard row.count > 1 else { return first.text }
        let widths = row.compactMap { line -> CGFloat? in
            let count = CGFloat(max(line.text.count, 1))
            let width = line.boundingBox.width / count
            return width > 0 ? width : nil
        }
        let medianWidth = median(widths) ?? 0.02
        var text = first.text
        for index in 1 ..< row.count {
            let previous = row[index - 1]
            let current = row[index]
            let gap = current.boundingBox.minX - previous.boundingBox.maxX
            text += gap > medianWidth * 2 ? "\t" : " "
            text += current.text
        }
        return text
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
