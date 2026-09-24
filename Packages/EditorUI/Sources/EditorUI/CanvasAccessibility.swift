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
        let low = min(color.red, color.green, color.blue)
        let chroma = high - low
        if chroma < 0.15 {
            if high > 0.85 { return "white" }
            if high < 0.2 { return "black" }
            return "gray"
        }
        var hue: Double
        if high == color.red {
            hue = (color.green - color.blue) / chroma
        } else if high == color.green {
            hue = (color.blue - color.red) / chroma + 2
        } else {
            hue = (color.red - color.green) / chroma + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15, 345...: return "red"
        case ..<40: return "orange"
        case ..<70: return "yellow"
        case ..<170: return "green"
        case ..<200: return "teal"
        case ..<260: return "blue"
        case ..<290: return "purple"
        default: return "pink"
        }
    }

    /// Tab and ⇧Tab: the next annotation after the current selection, wrapping round.
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
        let step = backward ? -1 : 1
        let next = (anchor + step + items.count) % items.count
        return items[next].id
    }
}
