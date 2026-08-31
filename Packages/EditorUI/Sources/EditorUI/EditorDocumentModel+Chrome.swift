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

    /// Replaces the progressive blur, keeping its identity across inspector edits so the
    /// undo stack sees one command being adjusted rather than a new one each tick.
    func applyProgressiveBlur(_ spec: ProgressiveBlurSpec) {
        var spec = spec
        if let existing = document.progressiveBlur {
            spec.id = existing.id
        }
        document.setProgressiveBlur(spec)
    }

    func clearProgressiveBlur() {
        document.setProgressiveBlur(nil)
    }

    /// Replaces the watermark, keeping its identity across inspector edits so the undo
    /// stack sees one command being adjusted rather than a new one each keystroke.
    func applyWatermark(_ spec: WatermarkSpec) {
        var spec = spec
        if let existing = document.watermark {
            spec.id = existing.id
        }
        document.setWatermark(spec)
    }

    func clearWatermark() {
        document.setWatermark(nil)
    }

    /// Wears a whole look, in one undo step (docs/09 U1.5).
    func applyStylePreset(_ preset: StylePreset) {
        document.applyStylePreset(preset)
    }

    /// Removes the current look. Clicking an already-selected preset also lands here, so
    /// a look is not a one-way door (Screendrop's "None").
    func clearStylePreset() {
        document.applyStylePreset(StylePreset(name: "None"))
    }
}
