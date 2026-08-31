import AnnotationModel
import CoreGraphics
import Foundation

public extension EditorDocumentModel {
    /// Paints the current tool's memory *and* whatever is selected, which is what changing
    /// a colour in an editor means (docs/03 §3).
    func applyColor(_ color: AnnotationColor) {
        endInspectorStyleEdit()
        if let annotation = inspectedTool {
            var stroke = styleMemory.stroke(for: annotation)
            stroke.color = color
            styleMemory.remember(stroke, for: annotation)
            if annotation == .text {
                var text = styleMemory.lastTextStyle
                text.color = color
                styleMemory.lastTextStyle = text
            }
            if annotation == .shape, styleMemory.fill(for: .shape).color != nil {
                styleMemory.remember(
                    FillStyle(color: color.withAlpha(styleMemory.lastFillOpacity)),
                    for: .shape
                )
            }
        }
        rewriteSelection { $0.applying(color: color) }
    }

    func applyStrokeWidth(_ width: CGFloat) {
        let clamped = min(max(width, StrokeStyle.widthRange.lowerBound), StrokeStyle.widthRange.upperBound)
        if let annotation = inspectedTool {
            var stroke = styleMemory.stroke(for: annotation)
            stroke.width = clamped
            styleMemory.remember(stroke, for: annotation)
        }
        rewriteSelectionLive { $0.applying(strokeWidth: clamped) }
    }

    func applyShapeKind(_ kind: ShapeKind) {
        endInspectorStyleEdit()
        styleMemory.lastShapeKind = kind
        rewriteSelection { $0.applying(shapeKind: kind) }
    }

    func applyArrowHead(_ head: ArrowHead) {
        endInspectorStyleEdit()
        styleMemory.lastArrowHead = head
        rewriteSelection { $0.applying(arrowHead: head) }
    }

    func applyShapeFill(_ color: AnnotationColor?) {
        endInspectorStyleEdit()
        styleMemory.remember(FillStyle(color: color), for: .shape)
        rewriteSelection { command in
            guard case var .shape(spec) = command else { return command }
            spec.fill.color = color
            return .shape(spec)
        }
    }

    /// Fill alpha for the selected shape (docs/03 §3). Successive slider ticks coalesce
    /// into one undo step, the same as stroke width.
    func applyFillOpacity(_ opacity: Double) {
        let clamped = min(max(opacity, 0), 1)
        styleMemory.lastFillOpacity = clamped
        if let fill = styleMemory.fill(for: .shape).color {
            styleMemory.remember(FillStyle(color: fill.withAlpha(clamped)), for: .shape)
        }
        rewriteSelectionLive { $0.applying(fillOpacity: clamped) }
    }

    /// Closes a run of inspector slider edits so they land as one undo step.
    ///
    /// Safe to call when no inspector gesture is open — a click on a swatch or the canvas
    /// just leaves history as it is.
    func endInspectorStyleEdit() {
        guard inspectorStyleGesture else { return }
        inspectorStyleGesture = false
        document.endGesture()
    }

    func applyRedactionStyle(_ style: RedactionStyle) {
        endInspectorStyleEdit()
        styleMemory.lastRedactionStyle = style
        rewriteSelection { $0.applying(redactionStyle: style) }
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

    /// Same rewrite, but successive calls amend one undo step until `endInspectorStyleEdit`.
    ///
    /// A stroke-width slider fires on every mouse-moved event. Routing those through
    /// `perform` would fill the undo stack in a single drag and freeze the canvas while
    /// each tick rebuilt history.
    private func rewriteSelectionLive(_ transform: (AnnotationCommand) -> AnnotationCommand) {
        let selection = document.selection
        guard !selection.isEmpty else { return }
        if !document.isGestureOpen {
            document.beginGesture()
            inspectorStyleGesture = true
        }
        document.updateGesture { commands in
            for index in commands.indices where selection.contains(commands[index].id) {
                commands[index] = transform(commands[index])
            }
        }
    }
}
