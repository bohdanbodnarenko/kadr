import AnnotationModel
import CoreGraphics
import Foundation

public extension EditorDocumentModel {
    /// Paints the current tool's memory *and* whatever is selected, which is what changing
    /// a colour in an editor means (docs/03 §3).
    func applyColor(_ color: AnnotationColor) {
        endInspectorStyleEdit()
        if inspectedTool == .counter {
            applyCounterFill(color)
            return
        }
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

    /// `` ` `` / `+` / `-` adjust the armed tool's size (CleanShot §8.2).
    func adjustToolSize(by steps: Int) {
        guard steps != 0, let tool = inspectedTool else { return }
        if tool == .text {
            adjustTextSize(by: steps)
            return
        }
        if tool == .counter {
            applyCounterSize(styleMemory.lastCounterSize.advanced(by: steps))
            return
        }
        guard toolUsesStrokeWidth(tool) else { return }
        let step: CGFloat = 2
        let current = styleMemory.stroke(for: tool).width
        applyStrokeWidth(current + CGFloat(steps) * step)
    }

    private func toolUsesStrokeWidth(_ tool: AnnotationTool) -> Bool {
        switch tool {
        case .arrow, .shape, .line, .freehand, .highlighter:
            true
        default:
            false
        }
    }

    private func adjustTextSize(by steps: Int) {
        var style = styleMemory.lastTextStyle
        style.fontSize = Self.clampedTextSize(style.fontSize + CGFloat(steps) * 2)
        applyTextStyleLive(style)
    }

    /// The range the size control and the `` ` ``/`+` shortcuts both work in.
    static let textSizeRange: ClosedRange<CGFloat> = 10 ... 120

    static func clampedTextSize(_ size: CGFloat) -> CGFloat {
        min(max(size, textSizeRange.lowerBound), textSizeRange.upperBound)
    }

    /// Applies a whole text style to the memory *and* to whatever text is selected, as one
    /// undoable edit (docs/03 §3, docs/14 UX-30A).
    ///
    /// The preset picker used to write `styleMemory.lastTextStyle` directly, which meant
    /// choosing Heading with a caption selected changed the *next* annotation and left the
    /// selected one alone — a control that looked like it edited the selection and did not.
    func applyTextStyle(_ style: TextStyle) {
        endInspectorStyleEdit()
        var next = style
        next.fontSize = Self.clampedTextSize(next.fontSize)
        styleMemory.lastTextStyle = next
        // The text tool's stroke memory carries the colour for the swatch strip, which is
        // shared with every other tool's inspector.
        var stroke = styleMemory.stroke(for: .text)
        stroke.color = next.color
        styleMemory.remember(stroke, for: .text)
        rewriteSelection { command in
            guard case var .text(spec) = command else { return command }
            spec.style = next
            return .text(spec)
        }
    }

    /// The same edit, coalesced, for the size slider and the size shortcuts.
    func applyTextStyleLive(_ style: TextStyle) {
        var next = style
        next.fontSize = Self.clampedTextSize(next.fontSize)
        styleMemory.lastTextStyle = next
        rewriteSelectionLive { command in
            guard case var .text(spec) = command else { return command }
            spec.style = next
            return .text(spec)
        }
    }

    /// The style the text inspector is editing: the selection's, or the tool's memory.
    ///
    /// Reading the selection first is what makes the inspector describe what is on screen.
    /// A picker bound only to style memory shows "Callout" over a selected heading.
    var inspectedTextStyle: TextStyle {
        // In document order rather than selection order: a `Set` would answer differently
        // between two runs with the same two captions selected.
        for command in document.commands where document.selection.contains(command.id) {
            if case let .text(spec) = command {
                return spec.style
            }
        }
        return styleMemory.lastTextStyle
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

    func applyStartArrowHead(_ head: ArrowHead?) {
        endInspectorStyleEdit()
        styleMemory.lastStartArrowHead = head
        rewriteSelection { $0.applying(startArrowHead: head) }
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

    /// The Strength slider: every tick amends one undo step until `endInspectorStyleEdit`
    /// (docs/18 ED-4).
    func applyRedactionStyleLive(_ style: RedactionStyle) {
        styleMemory.lastRedactionStyle = style
        rewriteSelectionLive { $0.applying(redactionStyle: style) }
    }

    func applyCounterNumbering(_ numbering: CounterNumbering) {
        endInspectorStyleEdit()
        styleMemory.lastCounterNumbering = numbering
        rewriteCounters { $0.applying(counterNumbering: numbering) }
    }

    /// Size is shared by every badge: the inspector picker rewrites them all so a
    /// sequence of 1, 2, 3 stays one size (docs/03 §3).
    func applyCounterSize(_ size: CounterBadgeSize) {
        endInspectorStyleEdit()
        styleMemory.lastCounterSize = size
        rewriteCounters { $0.applying(counterRadius: size.radius) }
    }

    func applyCounterFill(_ color: AnnotationColor) {
        endInspectorStyleEdit()
        styleMemory.lastCounterFill = color
        rewriteCounters { $0.applying(color: color) }
    }

    func applySpotlightDimOpacity(_ opacity: CGFloat) {
        styleMemory.lastSpotlightDimOpacity = opacity
        rewriteSelectionLive { $0.applying(spotlightDimOpacity: opacity) }
    }

    func applySpotlightCornerRadius(_ radius: CGFloat) {
        styleMemory.lastSpotlightCornerRadius = radius
        rewriteSelectionLive { $0.applying(spotlightCornerRadius: radius) }
    }

    /// ⌘D: a copy offset so it is obvious there are now two (docs/03 §3).
    func duplicateSelection() {
        guard !isCanvasLocked else { return }
        insertCopies(selectedCommands)
    }

    /// JSON of the current selection, for the pasteboard (CleanShot 4.4).
    func encodedSelection() -> Data? {
        let selected = selectedCommands
        guard !selected.isEmpty else { return nil }
        return try? JSONEncoder().encode(selected)
    }

    /// Pastes annotations copied from this editor or another (CleanShot 4.4).
    @discardableResult
    func pasteEncoded(_ data: Data) -> Bool {
        guard let commands = try? JSONDecoder().decode([AnnotationCommand].self, from: data),
              !commands.isEmpty
        else { return false }
        insertCopies(commands)
        return true
    }

    func insertCopies(_ commands: [AnnotationCommand]) {
        guard !commands.isEmpty else { return }
        pasteCascadeCount += 1
        let offset = CGSize(width: 16 * CGFloat(pasteCascadeCount), height: 16 * CGFloat(pasteCascadeCount))
        let copies = commands.map { command in
            Self.translated(command.withNewIdentity(), by: offset)
        }
        document.perform { $0.append(contentsOf: copies) }
        document.renumberCounters()
        document.selection = Set(copies.map(\.id))
    }

    /// Counters share one size and colour, so a style change rewrites every badge,
    /// not just the selection.
    private func rewriteCounters(_ transform: (AnnotationCommand) -> AnnotationCommand) {
        guard document.commands.contains(where: { $0.tool == .counter }) else { return }
        document.perform { commands in
            for index in commands.indices {
                guard case .counter = commands[index] else { continue }
                commands[index] = transform(commands[index])
            }
        }
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
    internal func rewriteSelectionLive(_ transform: (AnnotationCommand) -> AnnotationCommand) {
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
