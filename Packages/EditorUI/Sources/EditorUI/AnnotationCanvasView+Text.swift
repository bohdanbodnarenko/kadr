import AnnotationModel
import CoreGraphics
import Foundation

extension AnnotationCanvasView {
    /// Opens the in-place editor over the text annotation under `point`, if there is one.
    func beginEditingText(at point: CGPoint) -> Bool {
        let candidates = model.document.commands.filter { $0.tool == .text }
        guard let hit = AnnotationHitTesting.topmost(in: candidates, at: point) else {
            return false
        }
        return beginEditingText(hit.id)
    }

    /// Opens the in-place editor for a known text annotation.
    @discardableResult
    func beginEditingText(_ id: AnnotationID) -> Bool {
        guard case let .text(spec) = model.document.command(id) else {
            return false
        }

        model.document.selection = [spec.id]
        textEditor.begin(editing: spec, in: self)
        // The annotation is drawn by the field while it is being edited; drawing it
        // underneath as well would double every glyph.
        layers[spec.id]?.isHidden = true
        return true
    }
}
