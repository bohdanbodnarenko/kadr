import CoreGraphics
import CoreImage
import Foundation
import StudioSession

/// The talking-head bubble: aspect-fill, round, with a drop and a hairline so it sits
/// on the recording rather than looking stamped in (docs/09 U3.4).
extension StudioFrameComposer {
    func bubble(_ camera: CIImage, over base: CIImage) -> CIImage {
        let rect = edit.camera.frame(in: plan.outputSize)
        guard rect.width > 1, rect.height > 1, camera.extent.width > 0, camera.extent.height > 0 else {
            return base
        }

        // Aspect-fill: a webcam is 16:9 and the bubble is usually round, so fitting it
        // would letterbox a circle — which looks like a bug rather than a choice.
        let scale = max(rect.width / camera.extent.width, rect.height / camera.extent.height)
        let scaled = camera
            .transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let inset = CGRect(
            x: (scaled.extent.width - rect.width) / 2,
            y: (scaled.extent.height - rect.height) / 2,
            width: rect.width,
            height: rect.height
        )
        let cropped = scaled
            .cropped(to: inset)
            .transformed(by: CGAffineTransform(translationX: -inset.minX, y: -inset.minY))

        let radius = edit.camera.cornerRadius(in: plan.outputSize)
        let masked = mask(cropped, size: rect.size, radius: radius)
        var result = base
        if let shadow = bubbleShadow(rect: rect, radius: radius) {
            result = shadow.composited(over: result)
        }
        result = composite(masked, into: rect, over: result)
        if let stroke = bubbleStroke(size: rect.size, radius: radius) {
            result = composite(stroke, into: rect, over: result)
        }
        return result
    }

    /// A drop under the bubble so it reads as sitting on the recording, not stamped in.
    private func bubbleShadow(rect: CGRect, radius: CGFloat) -> CIImage? {
        let canvas = plan.outputSize
        let shortest = min(canvas.width, canvas.height)
        let blur = shortest * 0.022
        let drop = shortest * 0.009
        let flipped = CGRect(
            x: rect.minX,
            y: canvas.height - rect.maxY - drop,
            width: rect.width,
            height: rect.height
        )
        guard let plate = BitmapCanvas.image(
            width: Int(canvas.width.rounded()),
            height: Int(canvas.height.rounded()),
            action: { context in
                context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.35)
                fillRounded(flipped, radius: radius, in: context)
            }
        ) else {
            return nil
        }
        return CIImage(cgImage: plate)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// A white hairline so the bubble does not dissolve into a light recording.
    private func bubbleStroke(size: CGSize, radius: CGFloat) -> CIImage? {
        let shortest = min(plan.outputSize.width, plan.outputSize.height)
        let line = max(1, shortest * 0.0018)
        let inset = line / 2
        guard let image = BitmapCanvas.image(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            action: { context in
                context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.35)
                context.setLineWidth(line)
                let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                fillRounded(box, radius: max(radius - inset, 0), in: context, stroke: true)
            }
        ) else {
            return nil
        }
        return CIImage(cgImage: image)
    }

    private func fillRounded(
        _ rect: CGRect,
        radius: CGFloat,
        in context: CGContext,
        stroke: Bool = false
    ) {
        if radius > 0.5 {
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: min(radius, rect.width / 2),
                cornerHeight: min(radius, rect.height / 2),
                transform: nil
            ))
        } else {
            context.addRect(rect)
        }
        if stroke {
            context.strokePath()
        } else {
            context.fillPath()
        }
    }

    /// Rounds an image's corners.
    ///
    /// A drawn mask rather than `CIRoundedRectangleGenerator`, which is macOS 14+ only in
    /// the shape Kadr needs and produces a slightly different curve than the editor's own
    /// rounded rects — the bubble would not match the card it was dragged from.
    func mask(_ image: CIImage, size: CGSize, radius: CGFloat) -> CIImage {
        guard radius > 0.5 else { return image }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let maskImage = BitmapCanvas.image(width: width, height: height, action: { context in
                  context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                  fillRounded(
                      CGRect(x: 0, y: 0, width: size.width, height: size.height),
                      radius: radius,
                      in: context
                  )
              })
        else {
            return image
        }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: CIImage(cgImage: maskImage),
            kCIInputBackgroundImageKey: CIImage.empty()
        ])
    }
}
