import AnnotationModel
import CoreGraphics
import Foundation
import os
import Shared

/// The canvas chrome the inspector edits: beautify and the perspective camera
/// (docs/03 §3 P2, docs/09 U1.1, U1.2).
///
/// Split from the model's own file because chrome is edited by dragging sliders and
/// everything else by dragging the pointer, and the two have almost nothing to say to
/// each other.
public extension EditorDocumentModel {
    func sendSelectionToBack() {
        document.sendToBack(document.selection)
    }

    /// Applies canvas chrome. Successive inspector edits coalesce into one undo step.
    func applyBeautify(_ spec: BeautifySpec) {
        var spec = spec
        if let existing = document.beautify {
            spec.id = existing.id
        }
        document.setBeautify(spec)
    }

    func clearBeautify() {
        document.setBeautify(nil)
    }

    /// Replaces the perspective camera, keeping its identity across inspector edits so the
    /// undo stack sees one command being adjusted rather than a new one each tick.
    func applyCamera(_ spec: AnnotationCameraSpec) {
        var spec = spec
        if let existing = document.camera {
            spec.id = existing.id
        }
        document.setCamera(spec)
    }

    func clearCamera() {
        document.setCamera(nil)
    }
}
