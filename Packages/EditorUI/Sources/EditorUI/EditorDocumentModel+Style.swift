import AnnotationModel
import CoreGraphics
import Foundation

public extension EditorDocumentModel {
    /// Paints the current tool's memory *and* whatever is selected, which is what changing
    /// a colour in an editor means (docs/03 §3).
    func applyColor(_ color: AnnotationColor) {
        if let annotation = inspectedTool {
            var stroke = styleMemory.stroke(for: annotation)
            stroke.color = color
            styleMemory.remember(stroke, for: annotation)
            if annotation == .text {
                var text = styleMemory.lastTextStyle
                text.color = color
                styleMemory.lastTextStyle = text
            }
        }
        rewriteSelection { $0.applying(color: color) }
    }

    func applyStrokeWidth(_ width: CGFloat) {
        if let annotation = inspectedTool {
            var stroke = styleMemory.stroke(for: annotation)
            stroke.width = width
            styleMemory.remember(stroke, for: annotation)
        }
        rewriteSelection { $0.applying(strokeWidth: width) }
    }

    func applyShapeKind(_ kind: ShapeKind) {
        styleMemory.lastShapeKind = kind
        rewriteSelection { $0.applying(shapeKind: kind) }
    }

    func applyArrowHead(_ head: ArrowHead) {
        styleMemory.lastArrowHead = head
        rewriteSelection { $0.applying(arrowHead: head) }
    }

    func applyShapeFill(_ color: AnnotationColor?) {
        styleMemory.remember(FillStyle(color: color), for: .shape)
        rewriteSelection { command in
            guard case var .shape(spec) = command else { return command }
            spec.fill.color = color
            return .shape(spec)
        }
    }

    /// ⌘D: a copy offset so it is obvious there are now two (docs/03 §3).
    func duplicateSelection() {
        let selected = document.commands.filter { document.selection.contains($0.id) && $0.isSelectable }
        guard !selected.isEmpty else { return }
        let offset = CGSize(width: 16, height: 16)
        let copies = selected.map { command in
            Self.translated(command.withNewIdentity(), by: offset)
        }
        document.perform { $0.append(contentsOf: copies) }
        document.renumberCounters()
        document.selection = Set(copies.map(\.id))
    }

    private func rewriteSelection(_ transform: (AnnotationCommand) -> AnnotationCommand) {
        let selection = document.selection
        guard !selection.isEmpty else { return }
        document.perform { commands in
            for index in commands.indices where selection.contains(commands[index].id) {
                commands[index] = transform(commands[index])
            }
        }
    }
}
