import CoreGraphics
import CoreImage
import Foundation
import StudioSession

/// The talking-head bubble: aspect-fill, round, with a drop and a hairline so it sits
/// on the recording rather than looking stamped in (docs/09 U3.4).
extension StudioFrameComposer {
    func bubble(_ camera: CIImage, over base: CIImage) -> CIImage {
        guard let chrome = cachedBubble, camera.extent.width > 0, camera.extent.height > 0 else {
            return base
        }
        let rect = chrome.rect

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

        let masked = chrome.masking(cropped)
        var result = base
        if let shadow = chrome.shadow {
            result = shadow.composited(over: result)
        }
        result = composite(masked, into: rect, over: result)
        if let stroke = chrome.stroke {
            result = composite(stroke, into: rect, over: result)
        }
        return result
    }
}

/// Everything about the bubble that is not the camera's picture, drawn once.
///
/// The rect, the radius, the rounded mask, the drop shadow and the hairline all follow
/// from the plan and the edit, and neither changes for the life of a composer. They were
/// rasterised on every frame all the same — the shadow on a bitmap the size of the whole
/// output, which at 4K is a 33 MB allocation and a CPU fill sixty times a second, before a
/// GPU blur of the lot.
struct BubbleChrome: Sendable {
    /// Top-left, in output pixels.
    let rect: CGRect
    let radius: CGFloat
    /// White where the camera shows, or nil for a square bubble that needs no mask.
    let mask: CIImage?
    /// Already blurred and placed in output space (bottom-left origin).
    let shadow: CIImage?
    /// Bubble-sized; `composite(_:into:over:)` places it.
    let stroke: CIImage?

    /// Nil when the bubble has no area to draw into.
    init?(plan: StudioRenderPlan, camera: CameraBubble) {
        let canvas = plan.outputSize
        let rect = camera.frame(in: canvas)
        guard rect.width > 1, rect.height > 1 else { return nil }
        let radius = camera.cornerRadius(in: canvas)
        self.rect = rect
        self.radius = radius
        mask = Self.makeMask(size: rect.size, radius: radius)
        shadow = Self.makeShadow(rect: rect, radius: radius, canvas: canvas)
        stroke = Self.makeStroke(size: rect.size, radius: radius, canvas: canvas)
    }

    /// Rounds an image's corners with the cached mask.
    func masking(_ image: CIImage) -> CIImage {
        guard let mask else { return image }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage.empty()
        ])
    }

    /// A drop under the bubble so it reads as sitting on the recording, not stamped in.
    ///
    /// The plate covers the bubble and nothing else (`BoundedPlate`): the blur finds the
    /// same clear pixels beyond its edge that a canvas-sized plate held there.
    private static func makeShadow(rect: CGRect, radius: CGFloat, canvas: CGSize) -> CIImage? {
        let shortest = min(canvas.width, canvas.height)
        let blur = shortest * 0.022
        let drop = shortest * 0.009
        let flipped = CGRect(
            x: rect.minX,
            y: canvas.height - rect.maxY - drop,
            width: rect.width,
            height: rect.height
        )
        guard let plate = BoundedPlate.draw(covering: flipped, canvas: canvas, action: { context in
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.35)
            fillRounded(flipped, radius: radius, in: context)
        }) else {
            return nil
        }
        return plate
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// A white hairline so the bubble does not dissolve into a light recording.
    private static func makeStroke(size: CGSize, radius: CGFloat, canvas: CGSize) -> CIImage? {
        let shortest = min(canvas.width, canvas.height)
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

    /// The rounded-corner mask.
    ///
    /// A drawn mask rather than `CIRoundedRectangleGenerator`, which is macOS 14+ only in
    /// the shape Kadr needs and produces a slightly different curve than the editor's own
    /// rounded rects — the bubble would not match the card it was dragged from.
    private static func makeMask(size: CGSize, radius: CGFloat) -> CIImage? {
        guard radius > 0.5 else { return nil }
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
            return nil
        }
        return CIImage(cgImage: maskImage)
    }

    private static func fillRounded(
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
}
