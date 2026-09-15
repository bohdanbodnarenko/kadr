import CoreGraphics
import Foundation

/// Finds the opaque capture inside a transparent margin (docs/03 §3 P2).
///
/// A window captured with its shadow is saved as the window plus a soft border that is
/// mostly transparent. Beautify needs the window: rounding and shadowing the whole PNG put
/// the card on an invisible rectangle, and the window floated inside it like a second frame
/// whose corners never moved when the Corners slider did.
///
/// Walks in from each edge to the first row or column holding an opaque pixel, so a margin
/// costs its own rows and columns rather than a decision about every pixel in the capture.
public enum CaptureVisibleBounds {
    /// Alpha at or above which a pixel is the window. A baked shadow never gets near it; a
    /// window's anti-aliased corner does, which is why a whole opaque edge is not required.
    static let opaqueAlpha: UInt8 = 250
    /// A margin thinner than this is edge anti-aliasing, not a shadow.
    static let minimumMargin: CGFloat = 2
    /// Below this share of the image, the opaque part is a detail, not the capture.
    static let minimumCoverage: CGFloat = 0.25

    /// The opaque region in points, or `nil` when the capture has no transparent margin.
    public static func find(in image: CGImage, scale: CGFloat) -> CGRect? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return nil
        default:
            break
        }
        let width = image.width
        let height = image.height
        guard width > 4, height > 4 else { return nil }

        // Gray plus alpha: Swift's CGContext needs a colour space, which rules out an
        // alpha-only bitmap, and two bytes a pixel is half of what RGBA would cost.
        let bytesPerPixel = 2
        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, let pixels = opaquePixelBounds(
            bytes: bytes,
            width: width,
            height: height,
            bytesPerPixel: bytesPerPixel,
            alphaOffset: 1
        ) else {
            return nil
        }
        return points(from: pixels, width: width, height: height, scale: scale)
    }

    /// Bounds, top-left origin and in pixels, of every pixel whose alpha is at or above
    /// `opaqueAlpha`.
    ///
    /// `bytes` is row-major from the top, the way a bitmap context lays out its memory.
    static func opaquePixelBounds(
        bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerPixel: Int = 1,
        alphaOffset: Int = 0
    ) -> CGRect? {
        guard width > 0, height > 0, bytesPerPixel > alphaOffset,
              bytes.count >= width * height * bytesPerPixel
        else { return nil }
        return bytes.withUnsafeBufferPointer { pixels -> CGRect? in
            func isOpaque(_ x: Int, _ y: Int) -> Bool {
                pixels[(y * width + x) * bytesPerPixel + alphaOffset] >= opaqueAlpha
            }
            func rowIsOpaque(_ y: Int) -> Bool {
                (0 ..< width).contains { isOpaque($0, y) }
            }
            func columnIsOpaque(_ x: Int, top: Int, bottom: Int) -> Bool {
                (top ... bottom).contains { isOpaque(x, $0) }
            }

            guard let top = (0 ..< height).first(where: rowIsOpaque),
                  let bottom = (0 ..< height).reversed().first(where: rowIsOpaque),
                  let left = (0 ..< width).first(where: { columnIsOpaque($0, top: top, bottom: bottom) }),
                  let right = (0 ..< width).reversed().first(where: { columnIsOpaque($0, top: top, bottom: bottom) })
            else { return nil }
            return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
    }

    /// The pixel bounds in points, when they describe a shadowed capture worth trimming to.
    static func points(from pixels: CGRect, width: Int, height: Int, scale: CGFloat) -> CGRect? {
        let insets = [
            pixels.minX,
            pixels.minY,
            CGFloat(width) - pixels.maxX,
            CGFloat(height) - pixels.maxY
        ]
        // A shadow surrounds a window on every side. An image that is opaque up to one of
        // its edges is not a shadowed capture, and trimming it would cut something real.
        guard insets.allSatisfy({ $0 >= minimumMargin }),
              pixels.width * pixels.height >= CGFloat(width * height) * minimumCoverage
        else { return nil }
        let factor = max(scale, 1)
        return CGRect(
            x: pixels.minX / factor,
            y: pixels.minY / factor,
            width: pixels.width / factor,
            height: pixels.height / factor
        )
    }
}
