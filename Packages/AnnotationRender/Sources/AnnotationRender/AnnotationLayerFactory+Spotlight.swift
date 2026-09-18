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
        // Hit proxy only. The dim itself is one composite layer under the annotations
        // (docs/16 ED-9), so stacking two holes cannot darken either of them.
        _ = canvasRect
        layer.frame = spec.rect.standardized
        layer.backgroundColor = nil
        layer.masksToBounds = false
        layer.mask = nil
    }

    /// One even-odd dim covering the canvas, with every spotlight hole punched out.
    public static func applyCompositeSpotlight(
        _ composite: SpotlightComposite,
        to layer: CALayer,
        canvas: CGRect
    ) {
        layer.frame = canvas
        layer.backgroundColor = CGColor(gray: 0, alpha: composite.dimOpacity)
        layer.masksToBounds = true
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = CGRect(origin: .zero, size: canvas.size)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: canvas.size))
        for hole in composite.holes {
            path.addPath(hole.path(offsetBy: CGSize(width: -canvas.minX, height: -canvas.minY)))
        }
        mask.path = path
        layer.mask = mask
        layer.isHidden = false
    }
}
