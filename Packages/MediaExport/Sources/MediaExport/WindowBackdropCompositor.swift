import CoreGraphics
import Foundation

/// Fill used behind a captured window (docs/03 §1.2, CleanShot §10).
public enum WindowBackdropFill: Sendable {
    case color(red: CGFloat, green: CGFloat, blue: CGFloat)
    case image(CGImage)
}

/// Composites a window capture onto a padded backdrop so rounded corners and the
/// shadow sit on wallpaper or a solid colour rather than on SCK's opaque plate.
public enum WindowBackdropCompositor {
    /// Draws `window` centred on `fill` with `padding` pixels of margin.
    public static func composite(
        _ window: CGImage,
        onto fill: WindowBackdropFill,
        padding: Int
    ) -> CGImage? {
        let margin = max(0, padding)
        let width = window.width + margin * 2
        let height = window.height + margin * 2
        let colorSpace = window.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        paint(fill, in: context, canvas: canvas)
        context.draw(
            window,
            in: CGRect(x: margin, y: margin, width: window.width, height: window.height)
        )
        return context.makeImage()
    }

    private static func paint(_ fill: WindowBackdropFill, in context: CGContext, canvas: CGRect) {
        switch fill {
        case let .color(red, green, blue):
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(canvas)
        case let .image(image):
            let fitted = aspectFill(image.size, in: canvas.size)
            context.draw(image, in: fitted)
        }
    }

    /// The rect that covers `canvas` while keeping `image` proportional.
    private static func aspectFill(_ image: CGSize, in canvas: CGSize) -> CGRect {
        let scale = max(canvas.width / max(image.width, 1), canvas.height / max(image.height, 1))
        let width = image.width * scale
        let height = image.height * scale
        return CGRect(
            x: (canvas.width - width) / 2,
            y: (canvas.height - height) / 2,
            width: width,
            height: height
        )
    }
}

private extension CGImage {
    var size: CGSize {
        CGSize(width: width, height: height)
    }
}
