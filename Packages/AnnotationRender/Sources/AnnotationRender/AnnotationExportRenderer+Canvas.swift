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
    func drawPlainCanvas(
        _ contents: CardContents,
        canvas: CGRect,
        scale: CGFloat,
        readoutScale: CGFloat? = nil,
        in context: CGContext
    ) {
        let document = contents.document
        let source = contents.source
        let includeAnnotations = contents.includeAnnotations

        func drawContents(into target: CGContext, origin: CGPoint) {
            target.saveGState()
            target.translateBy(x: origin.x, y: origin.y)
            if document.crop?.canExpandCanvas == true {
                target.setFillColor(ExpandCanvasFill.color(around: source))
                target.fill(canvas)
            }
            target.draw(source, in: document.baseImage.bounds)
            if includeAnnotations {
                drawSpotlights(of: document, in: target)
                for command in document.resolvedCommands {
                    draw(command, in: target, imageScale: readoutScale ?? scale)
                }
            }
            target.restoreGState()
        }

        // Without a camera or a capture blur this is one flat draw. With either, the same
        // drawing goes to an offscreen bitmap first — so the annotations lean with the
        // capture rather than floating upright over it, and so the blur has an image to
        // work on.
        let camera = document.cameraGeometry
        let blur = document.progressiveBlur.flatMap { $0.extent == .clipped ? $0 : nil }
        guard camera != nil || blur != nil,
              var flat = renderFlat(canvas: canvas, scale: scale, matching: source, draw: drawContents)
        else {
            drawContents(into: context, origin: .zero)
            return
        }

        if let blur {
            let local = CGRect(origin: .zero, size: canvas.size)
            flat = ProgressiveBlurCompositor.apply(blur, to: flat, in: local, scale: scale) ?? flat
        }
        if let camera {
            guard let projected = CameraCompositor.project(
                card: flat,
                onto: camera.quad,
                canvasSize: canvas.size,
                scale: scale
            ) else {
                drawContents(into: context, origin: .zero)
                return
            }
            flat = projected
        }

        context.saveGState()
        context.translateBy(x: 0, y: canvas.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(flat, in: canvas)
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

    /// Scene blur, then the watermark, then rotate/flip (docs/16 ED-3).
    func finish(
        _ image: CGImage,
        document: AnnotationDocument,
        canvas: CGRect,
        scale: CGFloat,
        applyOrientation: Bool,
        includeWatermark: Bool = true
    ) -> CGImage {
        var composed: CGImage = if let blur = document.progressiveBlur, blur.extent == .scene {
            ProgressiveBlurCompositor.apply(blur, to: image, in: canvas, scale: scale) ?? image
        } else {
            image
        }
        if includeWatermark, let watermark = document.watermark {
            composed = WatermarkCompositor.stamp(watermark, onto: composed, canvas: canvas, scale: scale)
                ?? composed
        }
        guard applyOrientation, !document.orientation.isIdentity else { return composed }
        return document.orientation.applying(to: composed) ?? composed
    }

    /// Halves (or otherwise shrinks) an export. Never upscales — that cannot add detail.
    static func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let clamped = min(max(factor, 0.25), 1)
        guard abs(clamped - 1) > 0.001 else { return image }
        let width = max(1, Int((CGFloat(image.width) * clamped).rounded()))
        let height = max(1, Int((CGFloat(image.height) * clamped).rounded()))
        guard width != image.width || height != image.height else { return image }
        guard let context = makeContext(width: width, height: height, matching: image) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage()
    }
}
