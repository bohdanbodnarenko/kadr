import AnnotationModel
import AnnotationRender
import AppKit
import QuartzCore

extension AnnotationCanvasView {
    func updateCompositeSpotlight() {
        guard let composite = SpotlightComposite.from(commands: model.document.resolvedCommands) else {
            compositeSpotlightLayer.isHidden = true
            compositeSpotlightLayer.mask = nil
            return
        }
        let canvas = CGRect(origin: .zero, size: bounds.size)
        var shifted = composite
        shifted.holes = composite.holes.map { hole in
            let origin = model.document.canvasPoint(fromImage: hole.rect.origin)
            return SpotlightComposite.Hole(
                rect: CGRect(origin: origin, size: hole.rect.size),
                cornerRadius: hole.cornerRadius
            )
        }
        AnnotationLayerFactory.applyCompositeSpotlight(shifted, to: compositeSpotlightLayer, canvas: canvas)
        compositeSpotlightLayer.isHidden = cameraLayer.isHidden == false
    }

    func updateWatermarkLayer() {
        watermarkLayer.contentsScale = window?.backingScaleFactor ?? 2
        watermarkLayer.apply(model.document.watermark)
        if cameraLayer.isHidden == false {
            watermarkLayer.isHidden = true
        }
    }

    func updateBindingHint() {
        guard let target = liveBindingTarget() else {
            bindingHintLayer.isHidden = true
            bindingHintLayer.path = nil
            return
        }
        let box = AnnotationHitTesting.boundingBox(of: target)
        bindingHintLayer.path = CGPath(
            roundedRect: box.insetBy(dx: -2, dy: -2),
            cornerWidth: 4,
            cornerHeight: 4,
            transform: nil
        )
        bindingHintLayer.isHidden = false
    }

    func liveBindingTarget() -> AnnotationCommand? {
        let point: CGPoint?
        let excluding: AnnotationID?
        if case let .arrow(spec) = model.draft {
            point = spec.end
            excluding = spec.id
        } else if model.resizeHandle == .pathEnd || model.resizeHandle == .pathStart,
                  let id = model.selection.first,
                  case let .arrow(spec)? = model.document.command(id) {
            point = model.resizeHandle == .pathEnd ? spec.end : spec.start
            excluding = id
        } else {
            return nil
        }
        guard let point, let excluding,
              let binding = model.binding(at: point, excluding: excluding)
        else {
            return nil
        }
        return model.document.command(binding.targetID)
    }
}
