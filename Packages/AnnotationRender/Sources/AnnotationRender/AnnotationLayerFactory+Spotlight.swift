import AnnotationModel
import CoreGraphics
import Foundation
import QuartzCore

/// Spotlight overlay: a dim over the canvas with a rounded hole (docs/03 §3 P2).
extension AnnotationLayerFactory {
    static func resolvedCanvas(_ canvasRect: CGRect?, baseImage: CGImage?, imageScale: CGFloat) -> CGRect {
        if let canvasRect {
            return canvasRect
        }
        if let baseImage, imageScale > 0 {
            return CGRect(
                x: 0,
                y: 0,
                width: CGFloat(baseImage.width) / imageScale,
                height: CGFloat(baseImage.height) / imageScale
            )
        }
        return .zero
    }

    static func spotlightLayer(_ spec: SpotlightSpec, canvasRect: CGRect) -> CALayer {
        let layer = CALayer()
        applySpotlight(to: layer, spec: spec, canvasRect: canvasRect)
        return layer
    }

    static func applySpotlight(to layer: CALayer, spec: SpotlightSpec, canvasRect: CGRect) {
        let bounds = canvasRect.isEmpty
            ? spec.rect.standardized.insetBy(dx: -400, dy: -400)
            : canvasRect
        layer.frame = bounds
        layer.backgroundColor = CGColor(gray: 0, alpha: spec.dimOpacity)
        layer.masksToBounds = true

        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = CGRect(origin: .zero, size: bounds.size)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: bounds.size))
        let hole = spec.rect.standardized.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let radius = spec.fittedCornerRadius
        path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius)
        mask.path = path
        layer.mask = mask
    }
}
