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
        if tool == .crop, self.tool != .crop {
            cropBaseline = document.crop
        }
        self.tool = tool
        if tool != .select {
            selection = []
        }
    }

    /// Esc during Crop restores the crop as it was when the mode was entered (docs/16 ED-17).
    func cancelCropToBaseline() {
        document.setCrop(cropBaseline)
        cropBaseline = nil
        selectTool(.select)
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
    ///
    /// The gesture stays open so holding the click slides the new badge, and releasing
    /// records place+move as one undo step — ⌘Z removes it, rather than parking it where
    /// the pointer went down.
    internal func place(_ annotationTool: AnnotationTool, at point: CGPoint) {
        document.beginGesture()
        switch annotationTool {
        case .counter:
            let fill = styleMemory.lastCounterFill
            let command = AnnotationCommand.counter(CounterSpec(
                number: document.nextCounterNumber,
                center: point,
                radius: styleMemory.lastCounterSize.radius,
                fill: fill,
                textColor: fill.contrastingInk,
                numbering: styleMemory.lastCounterNumbering
            ))
            document.add(command)
            document.selection = [command.id]
            rememberStyle(of: command)
            beginDragOfPlaced(command)
        case .image:
            placeSticker(at: point)
            if let id = document.selection.first, let command = document.command(id) {
                beginDragOfPlaced(command)
            }
        default:
            break
        }
    }

    /// Holding the click that placed an annotation slides it, the way a sticker does on
    /// a board: put it down, then nudge before you let go.
    private func beginDragOfPlaced(_ command: AnnotationCommand) {
        guard !isCanvasLocked else { return }
        dragStartCommands = [command.id: command]
        captureArrowDependents()
        isMovingSelection = true
    }

    func placeSticker(at point: CGPoint) {
        guard let rendered = EmojiSticker.png(emoji: stickerEmoji, scale: document.baseImage.scale) else {
            return
        }
        _ = insertImage(pngData: rendered.data, pixelSize: rendered.pixelSize, at: point)
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
