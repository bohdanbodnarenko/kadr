import CoreGraphics
import Foundation

/// Fills the pad when a crop extends past the capture (CleanShot §8.1, docs/03 §3).
///
/// The crop tool can grow the canvas beyond the screenshot. Export used to paint that
/// padding white, which is wrong on dark UI chrome — CleanShot samples the edge colour
/// instead, and so do we.
enum ExpandCanvasFill {
    /// Averages opaque pixels sampled along the capture's edges.
    static func color(around image: CGImage) -> CGColor {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return CGColor(gray: 1, alpha: 1)
        }

        let inset = min(max(width, height) / 40, max(0, min(width, height) / 2 - 1))
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0

        func accumulate(x: Int, y: Int) {
            guard let sample = sample(image, x: x, y: y) else { return }
            red += sample.red
            green += sample.green
            blue += sample.blue
            count += 1
        }

        let horizontalStride = max(1, (width - 2 * inset) / 48)
        let verticalStride = max(1, (height - 2 * inset) / 48)

        for x in stride(from: inset, to: width - inset, by: horizontalStride) {
            accumulate(x: x, y: inset)
            accumulate(x: x, y: height - 1 - inset)
        }
        for y in stride(from: inset, to: height - inset, by: verticalStride) {
            accumulate(x: inset, y: y)
            accumulate(x: width - 1 - inset, y: y)
        }

        guard count > 0 else { return CGColor(gray: 1, alpha: 1) }
        let scale = 1.0 / Double(count)
        return CGColor(
            red: red * scale,
            green: green * scale,
            blue: blue * scale,
            alpha: 1
        )
    }

    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double
    }

    private static func sample(_ image: CGImage, x: Int, y: Int) -> RGB? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(x),
                y: -CGFloat(y),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        let alpha = Double(pixel[3])
        guard alpha > 12 else { return nil }
        let scale = 255.0 / alpha
        return RGB(
            red: Double(pixel[0]) * scale / 255,
            green: Double(pixel[1]) * scale / 255,
            blue: Double(pixel[2]) * scale / 255
        )
    }
}
