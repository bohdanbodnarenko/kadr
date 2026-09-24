import AnnotationModel
import AppKit

/// The canvas as VoiceOver sees it (T-ED-11, HIG › Accessibility).
///
/// A layout area whose children are the annotations, each with a spoken label, a frame
/// and actions: Press selects it, Delete removes it. Tab and ⇧Tab walk the same list from
/// the keyboard (see `applyTabKey`), so the canvas no longer needs a pointer.
public extension AnnotationCanvasView {
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .layoutArea
    }

    override func accessibilityLabel() -> String? {
        "Canvas"
    }

    override func accessibilityHelp() -> String? {
        "Tab and Shift-Tab select annotations. Arrow keys move the selection."
    }

    override func accessibilityChildren() -> [Any]? {
        CanvasAccessibility.items(for: model.document.commands).map { item in
            CanvasAnnotationElement(item: item, frame: viewRect(fromImage: item.frame), canvas: self)
        }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityChildren()?.filter {
            guard let element = $0 as? CanvasAnnotationElement else { return false }
            return model.selection.contains(element.annotationID)
        }
    }

    /// An image-space rectangle in this view's coordinates.
    internal func viewRect(fromImage rect: CGRect) -> CGRect {
        let first = viewPoint(fromImage: CGPoint(x: rect.minX, y: rect.minY))
        let second = viewPoint(fromImage: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    /// Selects one annotation from VoiceOver or the keyboard.
    internal func selectForAccessibility(_ id: AnnotationID) {
        if model.tool != .select {
            model.selectTool(.select)
        }
        model.selection = [id]
        refreshAfterEdit()
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    /// Deletes one annotation from VoiceOver.
    internal func deleteForAccessibility(_ id: AnnotationID) {
        model.selection = [id]
        model.deleteSelection()
        refreshAfterEdit()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// Tab and ⇧Tab cycle the selection through the annotations. Returns false when there
    /// is nothing to select, so the key view loop can take focus onwards instead.
    internal func applyTabKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        else {
            return false
        }
        let items = CanvasAccessibility.items(for: model.document.commands)
        guard let next = CanvasAccessibility.nextSelection(
            in: items,
            after: model.selection,
            backward: event.modifierFlags.contains(.shift)
        ) else {
            return false
        }
        selectForAccessibility(next)
        return true
    }
}

/// One annotation, for VoiceOver.
final class CanvasAnnotationElement: NSAccessibilityElement {
    let annotationID: AnnotationID
    private weak var canvas: AnnotationCanvasView?

    init(item: CanvasAccessibility.Item, frame: CGRect, canvas: AnnotationCanvasView) {
        annotationID = item.id
        self.canvas = canvas
        super.init()
        setAccessibilityRole(.layoutItem)
        setAccessibilityLabel(item.label)
        setAccessibilityParent(canvas)
        setAccessibilityFrameInParentSpace(frame)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Delete") { [weak canvas, id = item.id] in
                MainActor.assumeIsolated {
                    guard let canvas else { return false }
                    canvas.deleteForAccessibility(id)
                    return true
                }
            }
        ])
    }

    /// Accessibility calls arrive on the main thread; the element type just is not
    /// annotated as such.
    override func accessibilityPerformPress() -> Bool {
        let canvas = canvas
        let id = annotationID
        return MainActor.assumeIsolated {
            guard let canvas else { return false }
            canvas.selectForAccessibility(id)
            return true
        }
    }

    override func isAccessibilitySelected() -> Bool {
        let canvas = canvas
        let id = annotationID
        return MainActor.assumeIsolated {
            canvas?.model.selection.contains(id) ?? false
        }
    }
}
