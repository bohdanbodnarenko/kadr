import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import StudioSession

/// The padded card, its shadow and the fill behind it (docs/09 U3.5).
extension StudioFrameComposer {
    var usesCardChrome: Bool {
        Self.usesCardChrome(plan: plan, edit: edit)
    }

    static func usesCardChrome(plan: StudioRenderPlan, edit: StudioEdit) -> Bool {
        !edit.canvas.isIdentity || plan.cardCornerRadius > 0.5
    }

    /// The fill behind the card, as a recipe.
    ///
    /// Only ever evaluated once per composer, by `makeGround`. A computed property on the
    /// composer used to rebuild it — gradient rasterisation and all — for every frame.
    static func makeCanvasBackdrop(plan: StudioRenderPlan, edit: StudioEdit, wallpaper: CIImage?) -> CIImage {
        let bounds = CGRect(origin: .zero, size: plan.outputSize)
        switch edit.canvas.background {
        case .none:
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        case let .solid(color):
            return CIImage(color: color.ciColor).cropped(to: bounds)
        case let .gradient(ramp):
            return gradient(ramp, size: plan.outputSize)
        case .wallpaper:
            if let wallpaper {
                return filled(wallpaper, to: plan.outputSize)
            }
            return CIImage(color: StudioColor.graphite.ciColor).cropped(to: bounds)
        }
    }

    /// The backdrop with the card's shadow on it, rendered to pixels once.
    ///
    /// Nothing in it moves: the card does not, the backdrop does not and the shadow is a
    /// function of both. So it is rendered once into an IOSurface-backed buffer, which
    /// CoreImage then samples in place on every frame — no upload, no blur, no gradient.
    /// The per-frame alternative was a full-canvas Gaussian blur on the GPU, because the
    /// shared context does not cache intermediates, plus a full-canvas CPU gradient.
    ///
    /// Eight bits per channel, in sRGB: the same format and space the export writes, so the
    /// padding comes out as the same bytes it did when it was composed live. Falls back to
    /// the live recipe if a buffer cannot be had, which is slower and otherwise identical.
    static func makeGround(plan: StudioRenderPlan, edit: StudioEdit, wallpaper: CIImage?) -> CIImage {
        let bounds = CGRect(origin: .zero, size: plan.outputSize)
        var ground = makeCanvasBackdrop(plan: plan, edit: edit, wallpaper: wallpaper)
        if let shadow = makeCardShadow(plan: plan, edit: edit) {
            ground = shadow.composited(over: ground)
        }
        ground = ground.cropped(to: bounds)
        return baked(ground, size: plan.outputSize) ?? ground
    }

    /// `image` rendered into a pixel buffer and wrapped back up as a `CIImage`.
    ///
    /// IOSurface-backed, so every frame samples it in place rather than uploading 33 MB.
    static func baked(_ image: CIImage, size: CGSize) -> CIImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            return nil
        }
        // Waited for explicitly. The GPU draws straight into the surface, so "the call
        // returned" and "the pixels are there" are not promised to be the same moment.
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = StudioRenderContext.sRGB
        destination.alphaMode = .premultiplied
        do {
            let task = try StudioRenderContext.shared.startTask(
                toRender: image,
                from: CGRect(x: 0, y: 0, width: width, height: height),
                to: destination,
                at: .zero
            )
            _ = try task.waitUntilCompleted()
        } catch {
            return nil
        }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: StudioRenderContext.sRGB])
    }

    /// Keeps the recording inside the rounded card so padding shows the backdrop.
    func clipToCard(_ image: CIImage) -> CIImage {
        guard let mask = cachedCardMask else { return image }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage.empty()
        ])
    }

    /// The card's alpha mask, only as large as the card.
    ///
    /// Outside its extent a mask reads as clear, which is exactly what the full-canvas
    /// version held there — so the canvas-sized plate was 33 MB at 4K of zeros that the
    /// blend would have supplied for free.
    static func makeCardMask(plan: StudioRenderPlan, edit _: StudioEdit) -> CIImage? {
        let card = plan.cardRect
        guard card.width > 1, card.height > 1 else { return nil }
        let canvas = plan.outputSize
        let radius = plan.cardCornerRadius
        let flipped = CGRect(
            x: card.minX,
            y: canvas.height - card.maxY,
            width: card.width,
            height: card.height
        )
        return BoundedPlate.draw(covering: flipped, canvas: canvas) { context in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            fillCard(flipped, radius: radius, in: context)
        }
    }

    /// The card's drop shadow, blurred, cropped to the canvas.
    ///
    /// The plate is only as large as the card: a Gaussian blur samples beyond its input's
    /// extent as clear, which is what the rest of a full-canvas plate held anyway.
    static func makeCardShadow(plan: StudioRenderPlan, edit: StudioEdit) -> CIImage? {
        let strength = edit.canvas.shadow
        guard strength > 0.01 else { return nil }
        let card = plan.cardRect
        let canvas = plan.outputSize
        let shortest = min(canvas.width, canvas.height)
        let radius = plan.cardCornerRadius
        let blur = shortest * 0.045 * strength
        let drop = shortest * 0.016 * strength
        let flipped = CGRect(
            x: card.minX,
            y: canvas.height - card.maxY - drop,
            width: card.width,
            height: card.height
        )
        guard let plate = BoundedPlate.draw(covering: flipped, canvas: canvas, action: { context in
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.55 * strength)
            fillCard(flipped, radius: radius, in: context)
        }) else {
            return nil
        }
        return plate
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private static func fillCard(_ rect: CGRect, radius: CGFloat, in context: CGContext) {
        if radius > 0.5 {
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: min(radius, rect.width / 2),
                cornerHeight: min(radius, rect.height / 2),
                transform: nil
            ))
            context.fillPath()
        } else {
            context.fill(rect)
        }
    }

    private static func gradient(_ ramp: StudioGradient, size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        guard let image = BitmapCanvas.image(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            action: { context in
                fillGradient(ramp, in: bounds, context: context)
            }
        ) else {
            return CIImage(color: ramp.start.ciColor).cropped(to: bounds)
        }
        return CIImage(cgImage: image)
    }

    private static func fillGradient(_ ramp: StudioGradient, in rect: CGRect, context: CGContext) {
        let colourSpace = StudioRenderContext.sRGB
        let locations = (0 ..< ramp.stops.count).map { CGFloat($0) / CGFloat(max(ramp.stops.count - 1, 1)) }
        guard let gradient = CGGradient(
            colorsSpace: colourSpace,
            colors: ramp.stops.map(\.cgColor) as CFArray,
            locations: locations
        ) else {
            context.setFillColor(ramp.start.cgColor)
            context.fill(rect)
            return
        }
        let angle = ramp.angleDegrees * .pi / 180
        let length = hypot(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let startPoint = CGPoint(x: center.x - cos(angle) * length, y: center.y - sin(angle) * length)
        let endPoint = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient,
            start: startPoint,
            end: endPoint,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    /// Aspect-fills `image` to `size`, cropping the surplus.
    static func filled(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, size.width > 1, size.height > 1 else {
            return CIImage(color: StudioColor.graphite.ciColor)
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let x = scaledExtent.minX + (scaledExtent.width - size.width) / 2
        let y = scaledExtent.minY + (scaledExtent.height - size.height) / 2
        return scaled
            .cropped(to: CGRect(x: x, y: y, width: size.width, height: size.height))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }
}

extension StudioColor {
    var ciColor: CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

/// A plate for a shape that covers only part of the canvas.
///
/// Drawn on a bitmap just large enough for the shape and placed with a translation, rather
/// than on a bitmap the size of the whole output. The origin is snapped to whole pixels so
/// the rasteriser sees exactly the same pixel grid the full-canvas plate had — antialiased
/// edges come out byte for byte the same — and the bounds are clamped to the canvas, since
/// the full-canvas plate had nothing beyond its edges either and a blur must not find
/// anything there now.
enum BoundedPlate {
    /// One pixel of slack on every side, for the antialiased edge.
    static let margin: CGFloat = 1

    static func draw(covering shape: CGRect, canvas: CGSize, action: (CGContext) -> Void) -> CIImage? {
        let canvasWidth = canvas.width.rounded()
        let canvasHeight = canvas.height.rounded()
        let minX = max((shape.minX - margin).rounded(.down), 0)
        let minY = max((shape.minY - margin).rounded(.down), 0)
        let maxX = min((shape.maxX + margin).rounded(.up), canvasWidth)
        let maxY = min((shape.maxY + margin).rounded(.up), canvasHeight)
        guard maxX > minX, maxY > minY,
              let image = BitmapCanvas.image(
                  width: Int(maxX - minX),
                  height: Int(maxY - minY),
                  action: { context in
                      context.translateBy(x: -minX, y: -minY)
                      action(context)
                  }
              )
        else {
            return nil
        }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: minX, y: minY))
    }
}

/// Loads a canvas wallpaper once per preview or export, not per frame.
public enum StudioWallpaper {
    public static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: true
        ] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
