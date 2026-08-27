import CoreGraphics
import Shared

/// Reads pixels out of the frozen screenshot for the magnifier loupe (docs/03 §1.1).
///
/// The loupe reads from the **frozen image**, never from a fresh capture. Doc 04 §4.2 is
/// explicit about why: `SCScreenshotManager` is async, so capturing per mouse-move would
/// lag behind the pointer and burn a capture per frame. Reading a bitmap Kadr already
/// holds is both instant and guaranteed to match what the user will get.
public struct LoupeSampler: Sendable {
    /// The frozen display image, in pixels, top-left origin.
    private let image: CGImage
    /// Pixels per point on this display.
    private let scale: CGFloat

    public init(image: CGImage, scale: DisplayScale) {
        self.image = image
        self.scale = scale.factor
    }

    public var pixelSize: PixelSize {
        PixelSize(width: image.width, height: image.height)
    }

    /// A square of the frozen image centred on the pointer, ready to be drawn magnified.
    ///
    /// - Parameters:
    ///   - point: pointer position in display-local **points**.
    ///   - sideInPoints: how much of the screen the loupe shows, in points.
    /// - Returns: the cropped image, and the pixel rect it came from so the caller can
    ///   line up a pixel grid on it.
    public func magnifiedRegion(around point: CGPoint, sideInPoints: CGFloat) -> (image: CGImage, rect: PixelRect)? {
        guard sideInPoints > 0 else { return nil }
        let side = max(1, (sideInPoints * scale).rounded())
        let centre = CGPoint(x: point.x * scale, y: point.y * scale)

        var rect = CGRect(
            x: (centre.x - side / 2).rounded(.down),
            y: (centre.y - side / 2).rounded(.down),
            width: side,
            height: side
        )
        // Slide back inside rather than shrinking, so the loupe keeps its zoom factor at
        // the edges of the screen instead of quietly changing magnification.
        rect.origin.x = min(max(rect.origin.x, 0), max(0, CGFloat(image.width) - rect.width))
        rect.origin.y = min(max(rect.origin.y, 0), max(0, CGFloat(image.height) - rect.height))
        rect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else { return nil }
        return (
            cropped,
            PixelRect(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height))
        )
    }

    /// The colour of the single pixel under the pointer, for the loupe's readout.
    public func color(at point: CGPoint) -> PixelColor? {
        let x = Int((point.x * scale).rounded(.down))
        let y = Int((point.y * scale).rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return PixelColor(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
}

/// An 8-bit sRGB colour read out of a capture.
public struct PixelColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var hexText: String {
        DimensionFormatter.hexText(red: red, green: green, blue: blue)
    }

    /// Whether to draw the loupe's readout in black or white over this colour.
    ///
    /// Rec. 601 luma, which is the cheap standard choice for a legibility decision.
    public var prefersDarkText: Bool {
        let luma = 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
        return luma > 140
    }
}
