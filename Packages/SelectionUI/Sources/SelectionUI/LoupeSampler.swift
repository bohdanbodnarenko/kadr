import CoreGraphics
import os
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
    /// The one-pixel canvas every colour read draws into, made once per freeze rather than
    /// once per mouse move.
    private let probe = PixelProbe()

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
        return probe.color(of: pixel)
    }
}

/// A reusable 1×1 sRGB canvas for reading one pixel's colour (docs/03 §1.1).
///
/// The loupe reads a colour on every mouse move. Allocating a buffer and a `CGContext` for
/// each read was the bulk of that work; the canvas is the same every time, so it is made
/// once. Only the crop is per move, and cropping a `CGImage` shares its pixels rather than
/// copying them.
///
/// Reading straight out of the frozen image's data provider would skip the draw as well,
/// but asking a provider for its bytes copies the whole display — tens of megabytes per
/// freeze — and would need a decoder for every pixel format ScreenCaptureKit can hand
/// back. Drawing one pixel through CoreGraphics gets the colour management right for free.
final class PixelProbe: @unchecked Sendable {
    /// Invariant for `@unchecked`: `bytes` and `context` are used only inside
    /// `lock.withLockUnchecked`, and `bytes` lives exactly as long as the probe.
    private let lock = OSAllocatedUnfairLock()
    /// Explicitly allocated, not `&someArray`: a `CGContext` keeps the pointer it is given
    /// and writes through it during `draw`, which is past the end of the inout access an
    /// array would give it. That is undefined behaviour, and it does crash.
    private let bytes: UnsafeMutablePointer<UInt8>
    private let context: CGContext?

    init() {
        bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        bytes.initialize(repeating: 0, count: 4)
        context = CGContext(
            data: bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    deinit {
        bytes.deinitialize(count: 4)
        bytes.deallocate()
    }

    /// The colour of a one-pixel image.
    func color(of pixel: CGImage) -> PixelColor? {
        lock.withLockUnchecked {
            guard let context else { return nil }
            // Cleared by hand so a translucent pixel is not composited over the last one.
            bytes.update(repeating: 0, count: 4)
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return PixelColor(red: bytes[0], green: bytes[1], blue: bytes[2])
        }
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

    /// The same colour as the value the conversions and contrast maths work on
    /// (docs/06 M22).
    public var rgb: SampledColor {
        SampledColor(red8: red, green8: green, blue8: blue)
    }
}
