import AnnotationModel
import AppKit
import EditorUI

/// Responder-chain commands for the annotation editor (docs/14 UX-27).
///
/// Mirrors `StudioWindowController`: the Edit menu's selectors reach the key document
/// through this object rather than through invisible SwiftUI buttons.
extension EditorWindowController {
    // MARK: - Edit menu

    @objc func undo(_ sender: Any?) {
        model.undo()
    }

    @objc func redo(_ sender: Any?) {
        model.redo()
    }

    @objc func cut(_ sender: Any?) {
        guard copyAnnotationsToPasteboard() else { return }
        model.deleteSelection()
    }

    @objc func copy(_ sender: Any?) {
        if copyAnnotationsToPasteboard() {
            model.requestCopyToast()
            return
        }
        export(.copyFlattened)
    }

    @objc func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.data(forType: .kadrAnnotations),
           model.pasteEncoded(data) {
            return
        }
        pasteImageFromClipboardIfPresent()
    }

    func pasteImageFromClipboardIfPresent() {
        guard let image = NSImage(pasteboard: .general),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let imported = EditorImageImporter.png(from: cgImage)
        else {
            return
        }
        placeImportedImage(imported.data, pixelSize: imported.pixelSize)
    }

    @objc override func selectAll(_ sender: Any?) {
        model.selectAll()
    }

    @objc func duplicate(_ sender: Any?) {
        model.duplicateSelection()
    }

    @objc func bringToFront(_ sender: Any?) {
        model.bringSelectionToFront()
    }

    @objc func bringForward(_ sender: Any?) {
        model.bringSelectionForward()
    }

    @objc func sendBackward(_ sender: Any?) {
        model.sendSelectionBackward()
    }

    @objc func sendToBack(_ sender: Any?) {
        model.sendSelectionToBack()
    }

    @objc func toggleInspector(_ sender: Any?) {
        model.isInspectorPresented.toggle()
    }

    @objc func zoomIn(_ sender: Any?) {
        canvasSession.zoomIn()
    }

    @objc func zoomOut(_ sender: Any?) {
        canvasSession.zoomOut()
    }

    @objc func zoomToFit(_ sender: Any?) {
        canvasSession.fit()
    }

    @objc func zoomActualSize(_ sender: Any?) {
        canvasSession.setPercent(100)
    }

    @objc func increaseToolSize(_ sender: Any?) {
        model.adjustToolSize(by: 1)
    }

    @objc func decreaseToolSize(_ sender: Any?) {
        model.adjustToolSize(by: -1)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return model.canUndo
        case #selector(redo(_:)):
            return model.canRedo
        case #selector(cut(_:)):
            return !model.selection.isEmpty
        case #selector(copy(_:)):
            return true
        case #selector(paste(_:)):
            return NSPasteboard.general.data(forType: .kadrAnnotations) != nil
        case #selector(selectAll(_:)):
            return model.document.commands.contains(where: \.isSelectable)
        case #selector(duplicate(_:)),
             #selector(bringToFront(_:)),
             #selector(bringForward(_:)),
             #selector(sendBackward(_:)),
             #selector(sendToBack(_:)):
            return !model.selection.isEmpty && !model.isCanvasLocked
        case #selector(toggleInspector(_:)):
            menuItem.title = model.isInspectorPresented ? "Hide Inspector" : "Show Inspector"
            return true
        case #selector(toggleCanvasLock(_:)):
            menuItem.state = model.isCanvasLocked ? .on : .off
            return true
        default:
            return true
        }
    }

    @objc func toggleCanvasLock(_ sender: Any?) {
        model.isCanvasLocked.toggle()
    }

    @discardableResult
    private func copyAnnotationsToPasteboard() -> Bool {
        guard let data = model.encodedSelection() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .kadrAnnotations)
        return true
    }
}
