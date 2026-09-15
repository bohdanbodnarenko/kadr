import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import StudioSession

/// The padded card, its shadow and the fill behind it (docs/09 U3.5).
extension StudioFrameComposer {
    var usesCardChrome: Bool {
        !edit.canvas.isIdentity || plan.cardCornerRadius > 0.5
    }

    var canvasBackdrop: CIImage {
        let bounds = CGRect(origin: .zero, size: plan.outputSize)
        switch edit.canvas.background {
        case .none:
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        case let .solid(color):
            return CIImage(color: color.ciColor).cropped(to: bounds)
        case let .gradient(ramp):
            return gradient(ramp)
        case .wallpaper:
            if let wallpaper {
                return Self.filled(wallpaper, to: plan.outputSize)
            }
            return CIImage(color: StudioColor.graphite.ciColor).cropped(to: bounds)
        }
    }

    /// Keeps the recording inside the rounded card so padding shows the backdrop.
    func clipToCard(_ image: CIImage) -> CIImage {
        guard let mask = cachedCardMask else { return image }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage.empty()
        ])
    }

    var cardShadow: CIImage? {
        cachedCardShadow
    }

    static func makeCardMask(plan: StudioRenderPlan, edit: StudioEdit) -> CIImage? {
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
        guard let maskImage = BitmapCanvas.image(
            width: Int(canvas.width.rounded()),
            height: Int(canvas.height.rounded()),
            action: { context in
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                fillCard(flipped, radius: radius, in: context)
            }
        ) else {
            return nil
        }
        return CIImage(cgImage: maskImage)
    }

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
        guard let plate = BitmapCanvas.image(
            width: Int(canvas.width.rounded()),
            height: Int(canvas.height.rounded()),
            action: { context in
                context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.55 * strength)
                fillCard(flipped, radius: radius, in: context)
            }
        ) else {
            return nil
        }
        return CIImage(cgImage: plate)
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

    private func gradient(_ ramp: StudioGradient) -> CIImage {
        let size = plan.outputSize
        let bounds = CGRect(origin: .zero, size: size)
        guard let image = BitmapCanvas.image(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            action: { context in
                Self.fillGradient(ramp, in: bounds, context: context)
            }
        ) else {
            return CIImage(color: ramp.start.ciColor).cropped(to: bounds)
        }
        return CIImage(cgImage: image)
    }

    private static func fillGradient(_ ramp: StudioGradient, in rect: CGRect, context: CGContext) {
        let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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
