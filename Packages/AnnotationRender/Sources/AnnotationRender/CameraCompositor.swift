import AnnotationModel
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import os
import Shared

/// Projects the finished card through the perspective camera (docs/09 U1.2).
///
/// The order matters and is the whole design: the card — capture, annotations, rounded
/// corners and all — is rendered flat first, and *then* projected as one image. Projecting
/// the capture and drawing the annotations on top afterwards would leave the arrows
/// unrotated, floating over a tilted screenshot. Everything the user drew leans with it
/// because everything the user drew is in the bitmap before the camera sees it.
enum CameraCompositor {
    private static let logger = KadrLog.logger(.capture)

    /// Renders `card` — which occupies `cardRect` in canvas points — projected onto `quad`.
    ///
    /// - Parameters:
    ///   - card: the flattened card, at `scale` pixels per point.
    ///   - canvasSize: the whole canvas, in points.
    ///   - scale: pixels per point.
    /// - Returns: the projected image covering the whole canvas, or nil if CoreImage
    ///   refused — in which case the caller draws the card flat, because a screenshot
    ///   without its perspective beats no screenshot.
    static func project(
        card: CGImage,
        onto quad: CameraQuad,
        canvasSize: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let pixelCanvas = CGRect(
            x: 0,
            y: 0,
            width: (canvasSize.width * scale).rounded(),
            height: (canvasSize.height * scale).rounded()
        )
        guard pixelCanvas.width >= 1, pixelCanvas.height >= 1 else { return nil }

        // CoreImage works bottom-left and in pixels; the model works top-left and in
        // points. One conversion, here, rather than a flip smeared through the filter.
        let pixelQuad = quad
            .flipped(inHeight: canvasSize.height)
            .scaled(by: scale)

        // Corner for corner: once the quad is in a y-up space, the model's top-left corner
        // *is* CoreImage's top-left corner, and so is the card image's own first row.
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = CIImage(cgImage: card)
        filter.topLeft = pixelQuad.topLeft
        filter.topRight = pixelQuad.topRight
        filter.bottomRight = pixelQuad.bottomRight
        filter.bottomLeft = pixelQuad.bottomLeft

        guard let output = filter.outputImage else {
            logger.error("The perspective camera produced no image; drawing the card flat")
            return nil
        }
        return KadrRenderContext.shared.createCGImage(output, from: pixelCanvas)
    }

    /// The path the projected card occupies, for casting its shadow.
    static func path(of quad: CameraQuad) -> CGPath {
        let path = CGMutablePath()
        path.move(to: quad.topLeft)
        path.addLine(to: quad.topRight)
        path.addLine(to: quad.bottomRight)
        path.addLine(to: quad.bottomLeft)
        path.closeSubpath()
        return path
    }
}

extension CameraQuad {
    /// The quad in pixels rather than points.
    func scaled(by scale: CGFloat) -> CameraQuad {
        func scalePoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale, y: point.y * scale)
        }
        return CameraQuad(
            topLeft: scalePoint(topLeft),
            topRight: scalePoint(topRight),
            bottomRight: scalePoint(bottomRight),
            bottomLeft: scalePoint(bottomLeft)
        )
    }
}
