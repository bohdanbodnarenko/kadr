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
        case let .gradient(start, end):
            return gradient(from: start, to: end)
        case .wallpaper:
            if let wallpaper {
                return Self.filled(wallpaper, to: plan.outputSize)
            }
            return CIImage(color: StudioColor.graphite.ciColor).cropped(to: bounds)
        }
    }

    /// Keeps the recording inside the rounded card so padding shows the backdrop.
    func clipToCard(_ image: CIImage) -> CIImage {
        let card = plan.cardRect
        guard card.width > 1, card.height > 1 else { return image }
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
            return image
        }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: CIImage(cgImage: maskImage),
            kCIInputBackgroundImageKey: CIImage.empty()
        ])
    }

    var cardShadow: CIImage? {
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

    private func fillCard(_ rect: CGRect, radius: CGFloat, in context: CGContext) {
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

    private func gradient(from start: StudioColor, to end: StudioColor) -> CIImage {
        let size = plan.outputSize
        let filter = CIFilter(name: "CILinearGradient")
        filter?.setValue(CIVector(x: 0, y: size.height), forKey: "inputPoint0")
        filter?.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint1")
        filter?.setValue(start.ciColor, forKey: "inputColor0")
        filter?.setValue(end.ciColor, forKey: "inputColor1")
        let generated = filter?.outputImage ?? CIImage(color: start.ciColor)
        return generated.cropped(to: CGRect(origin: .zero, size: size))
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
