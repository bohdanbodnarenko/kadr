import AnnotationModel
import AnnotationRender
import CoreGraphics
import Foundation
import os
import Shared

/// Attaching an arrow to what it was drawn onto (docs/09 U1.7).
///
/// The geometry lives in `AnnotationModel`; this is only the gesture — which annotation
/// the user let go over, and what anchor that corresponds to.
extension EditorDocumentModel {
    /// Attaches an arrow's ends to whatever they were dropped on (docs/09 U1.7).
    ///
    /// Done on commit rather than while dragging, because a half-drawn arrow sweeps across
    /// everything between its two ends and binding to each in turn would be a light show.
    /// The end the user let go over is the one they meant.
    func bindingArrowEnds(of command: AnnotationCommand) -> AnnotationCommand {
        guard case var .arrow(spec) = command else { return command }
        spec.startBinding = binding(at: spec.start, excluding: spec.id)
        spec.endBinding = binding(at: spec.end, excluding: spec.id)
        return .arrow(spec)
    }

    /// A binding to the topmost annotation under `point`, if there is one to bind to.
    ///
    /// Canvas chrome is skipped: an arrow bound to the beautify backdrop would follow a
    /// background rather than a thing.
    func binding(at point: CGPoint, excluding id: AnnotationID) -> ArrowBinding? {
        let candidates = document.commands.filter { $0.id != id && $0.isSelectable }
        guard let target = AnnotationHitTesting.topmost(in: candidates, at: point) else { return nil }
        return ArrowBinding(
            targetID: target.id,
            anchor: ArrowBinding.anchor(for: point, in: AnnotationHitTesting.boundingBox(of: target))
        )
    }

    /// Follows the in-place text editor, keystroke by keystroke (docs/09 U1.8).
    ///
    /// Through a gesture, so a typed sentence is one undo step rather than one per letter —
    /// the same primitive a pointer drag uses (docs/07 C2).
    func updateText(_ id: AnnotationID, string: String) {
        document.beginGesture()
        document.updateGesture { commands in
            guard let index = commands.firstIndex(where: { $0.id == id }),
                  case var .text(spec) = commands[index]
            else {
                return
            }
            spec.string = string
            spec = TextRendering.fitted(spec)
            commands[index] = .text(spec)
        }
    }

    /// Closes the gesture the editing opened, and drops an annotation left empty.
    func commitTextEdit(_ id: AnnotationID) {
        document.endGesture()
        if case let .text(spec)? = document.command(id) {
            if spec.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document.remove([id])
            }
        }
        // Typing was the rest of the text tool's gesture, so the pointer returns to
        // Select the way finishing an arrow does (docs/03 §3).
        if tool == .text {
            tool = .select
        }
    }

    // MARK: - Crop (docs/09 U1.8)

    /// The ratio the crop tool is holding.
    var cropAspect: CropAspectPreset {
        get { styleMemory.lastCropAspect }
        set { styleMemory.lastCropAspect = newValue }
    }

    /// Switches the ratio and reshapes the existing crop to match.
    ///
    /// Reshaping now rather than at the next drag, because a ratio the picture does not
    /// have yet is a setting that appears to have done nothing.
    func applyCropAspect(_ preset: CropAspectPreset) {
        cropAspect = preset
        guard var spec = document.crop,
              let ratio = preset.ratio(original: document.baseImage.size)
        else {
            return
        }
        spec.rect = CropRectEditor.resized(
            spec.rect,
            handle: .bottomTrailing,
            translation: .zero,
            aspect: ratio,
            bounds: spec.canExpandCanvas ? nil : document.baseImage.bounds
        )
        document.setCrop(spec)
    }

    /// Whether the crop may extend past the capture, adding blank space rather than cutting.
    func setCropCanExpandCanvas(_ allowed: Bool) {
        var spec = document.crop ?? CropSpec(rect: document.baseImage.bounds)
        guard spec.canExpandCanvas != allowed else { return }
        spec.canExpandCanvas = allowed
        if !allowed {
            // Coming back inside: a crop that was allowed to grow may be outside the image.
            spec.rect = spec.rect.intersection(document.baseImage.bounds)
        }
        document.setCrop(spec)
    }

    func clearCrop() {
        document.setCrop(nil)
    }
}
