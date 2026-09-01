import AnnotationModel
import CoreGraphics
import Foundation

/// Tool picking, hand-off after a stroke, and the inspector's follow-the-selection rule
/// (docs/03 §3).
public extension EditorDocumentModel {
    /// User-initiated tool change from the toolbar or a shortcut.
    ///
    /// Picking a drawing tool clears the selection so the inspector shows that
    /// tool's defaults rather than a leftover annotation. Returning to Select
    /// keeps whatever is selected, which is how you resume editing it.
    func selectTool(_ tool: EditorTool) {
        pendingTextEditID = nil
        // Clearing runs even when the tool is unchanged (docs/03 §3: "picking a drawing
        // tool from the toolbar clears the current selection"). The early return that used
        // to guard this made re-pressing the armed tool a no-op, so the shape drawn a
        // moment ago stayed selected while the user was lining up the next one — and any
        // style change meant for the *next* shape rewrote the previous one instead.
        self.tool = tool
        if tool != .select {
            selection = []
        }
    }

    /// The canvas takes this after mouse-up so the in-place editor can open.
    func consumePendingTextEdit() -> AnnotationID? {
        defer { pendingTextEditID = nil }
        return pendingTextEditID
    }

    /// The annotation kind the inspector and style memory should follow.
    ///
    /// A selection takes priority: after a one-shot tool hands off to Select, the
    /// inspector still belongs to what was just drawn. With nothing selected, it
    /// follows the armed drawing tool.
    var inspectedTool: AnnotationTool? {
        if let id = selection.first, let command = document.command(id), command.isSelectable {
            return command.tool
        }
        return tool.annotation
    }

    /// Counters are placed with a click, and auto-increment (docs/03 §3).
    internal func place(_ annotationTool: AnnotationTool, at point: CGPoint) {
        guard annotationTool == .counter else { return }
        let command = AnnotationCommand.counter(CounterSpec(
            number: document.nextCounterNumber,
            center: point
        ))
        document.add(command)
        document.selection = [command.id]
        // The tool stays armed: a numbered badge is one of a sequence.
    }

    /// Hands the pointer back to Select after a one-shot tool lands.
    ///
    /// Text is the exception: placing the box opens the in-place editor, and the
    /// tool stays armed until that editor commits (docs/03 §3).
    internal func finishAppliedTool(placed id: AnnotationID) {
        if tool == .text {
            pendingTextEditID = id
            return
        }
        if tool.returnsToSelectAfterUse {
            tool = .select
        }
    }
}
