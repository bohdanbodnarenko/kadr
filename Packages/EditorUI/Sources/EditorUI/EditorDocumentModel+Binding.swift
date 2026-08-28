import AnnotationModel
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
}
