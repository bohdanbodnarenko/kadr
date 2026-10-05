import AnnotationModel
import Foundation

/// What VoiceOver and the keyboard see of the canvas (T-ED-11).
///
/// Pure, so the wording and the Tab order are tested without a window. The canvas turns
/// each `Item` into an `NSAccessibilityElement`.
enum CanvasAccessibility {
    struct Item: Equatable {
        let id: AnnotationID
        /// "Arrow 3, red", "Text “Click here”", "Counter 2".
        let label: String
        /// In image coordinates.
        let frame: CGRect
    }

    /// One item per annotation the user can select, in drawing order, numbered per kind.
    static func items(for commands: [AnnotationCommand]) -> [Item] {
        var counts: [AnnotationTool: Int] = [:]
        return commands.filter(\.isSelectable).map { command in
            let tool = command.tool
            counts[tool, default: 0] += 1
            return Item(
                id: command.id,
                label: label(for: command, ordinal: counts[tool] ?? 1),
                frame: AnnotationHitTesting.boundingBox(of: command)
            )
        }
    }

    static func label(for command: AnnotationCommand, ordinal: Int) -> String {
        let title = command.tool.title
        switch command {
        case let .text(spec):
            let text = spec.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "\(title) \(ordinal), empty" : "\(title) \u{201C}\(text)\u{201D}"
        case let .counter(spec):
            return "\(title) \(spec.label)"
        default:
            let base = "\(title) \(ordinal)"
            return color(of: command).map { "\(base), \(spokenName(of: $0))" } ?? base
        }
    }

    /// The colour a person would name the annotation by.
    static func color(of command: AnnotationCommand) -> AnnotationColor? {
        switch command {
        case let .arrow(spec): spec.stroke.color
        case let .line(spec): spec.stroke.color
        case let .freehand(spec): spec.stroke.color
        case let .highlighter(spec): spec.stroke.color
        case let .shape(spec): spec.fill.color ?? spec.stroke.color
        default: nil
        }
    }

    /// A plain colour word: enough to tell "the red arrow" from "the blue one".
    static func spokenName(of color: AnnotationColor) -> String {
        let high = max(color.red, color.green, color.blue)
        let chroma = high - min(color.red, color.green, color.blue)
        guard chroma >= 0.15 else {
            return high > 0.85 ? "white" : high < 0.2 ? "black" : "gray"
        }
        let hue = hue(of: color, high: high, chroma: chroma)
        return hueNames.first { hue < $0.upperBound }?.name ?? "red"
    }

    /// Hue names by the upper edge of their band, in degrees.
    private static let hueNames: [(upperBound: Double, name: String)] = [
        (15, "red"), (40, "orange"), (70, "yellow"), (170, "green"), (200, "teal"),
        (260, "blue"), (290, "purple"), (345, "pink"), (360, "red")
    ]

    private static func hue(of color: AnnotationColor, high: Double, chroma: Double) -> Double {
        let sector = if high == color.red {
            (color.green - color.blue) / chroma
        } else if high == color.green {
            (color.blue - color.red) / chroma + 2
        } else {
            (color.red - color.green) / chroma + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Tab and ⇧Tab: the next annotation after the current selection, or nil past either
    /// end, so focus can leave the canvas for the rest of the window instead of being
    /// trapped in it under Full Keyboard Access (docs/18 ED-9).
    static func nextSelection(
        in items: [Item],
        after selection: Set<AnnotationID>,
        backward: Bool
    ) -> AnnotationID? {
        guard !items.isEmpty else { return nil }
        let indices = items.indices.filter { selection.contains(items[$0].id) }
        guard let anchor = backward ? indices.first : indices.last else {
            return backward ? items.last?.id : items.first?.id
        }
        let next = anchor + (backward ? -1 : 1)
        return items.indices.contains(next) ? items[next].id : nil
    }
}
