import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import Shared

/// Drawing the canvas when there is no beautify chrome around it (docs/09 U1.2).
///
/// Split from the renderer's own file because the command drawing and the canvas assembly
/// change for different reasons, and because the camera gave this half enough substance to
/// stand on its own.
extension AnnotationExportRenderer {
    /// The un-beautified canvas: the capture and whatever is drawn on it, optionally
    /// projected through the camera (docs/09 U1.2).
    func drawPlainCanvas(_ contents: CardContents, canvas: CGRect, scale: CGFloat, in context: CGContext) {
        let document = contents.document
        let source = contents.source
        let includeAnnotations = contents.includeAnnotations

        func drawContents(into target: CGContext, origin: CGPoint) {
            target.saveGState()
            target.translateBy(x: origin.x, y: origin.y)
            if document.crop?.canExpandCanvas == true {
                target.setFillColor(CGColor(gray: 1, alpha: 1))
                target.fill(canvas)
            }
            target.draw(source, in: document.baseImage.bounds)
            if includeAnnotations {
                for command in document.commands {
                    draw(command, in: target, imageScale: scale)
                }
            }
            target.restoreGState()
        }

        // Without a camera this is one flat draw; with one, the same drawing goes to an
        // offscreen bitmap first so the annotations lean with the capture rather than
        // floating upright over it.
        guard let camera = document.cameraGeometry,
              let flat = renderFlat(canvas: canvas, scale: scale, matching: source, draw: drawContents),
              let projected = CameraCompositor.project(
                  card: flat,
                  onto: camera.quad,
                  canvasSize: canvas.size,
                  scale: scale
              )
        else {
            drawContents(into: context, origin: .zero)
            return
        }

        context.saveGState()
        context.translateBy(x: 0, y: canvas.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(projected, in: canvas)
        context.restoreGState()
    }

    /// Renders the canvas flat, for the camera to project.
    func renderFlat(
        canvas: CGRect,
        scale: CGFloat,
        matching source: CGImage,
        draw contents: (CGContext, CGPoint) -> Void
    ) -> CGImage? {
        let pixelWidth = Int((canvas.width * scale).rounded())
        let pixelHeight = Int((canvas.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let flat = Self.makeContext(width: pixelWidth, height: pixelHeight, matching: source)
        else {
            return nil
        }
        flat.scaleBy(x: scale, y: scale)
        flat.translateBy(x: 0, y: canvas.height)
        flat.scaleBy(x: 1, y: -1)
        contents(flat, CGPoint(x: -canvas.minX, y: -canvas.minY))
        return flat.makeImage()
    }
}
