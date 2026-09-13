import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Shared

/// One captured frame, reduced to what stitching actually needs (docs/04 §4.4).
///
/// Colour is irrelevant to finding a scroll offset and quadruples the work, so every frame
/// becomes 8-bit grayscale on the way in — through vImage, which does the conversion in a
/// single vectorised pass rather than a per-pixel loop.
struct GrayscaleFrame {
    let width: Int
    let height: Int
    /// Packed: one byte per pixel, no row padding.
    var bytesPerRow: Int {
        width
    }

    let pixels: [UInt8]
    let profile: RowProfile
    let columnProfile: ColumnProfile

    init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.init(image)
    }

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(CGColorSpaceCreateDeviceRGB()),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var source = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&source, &format, nil, image, vImage_Flags(kvImageNoFlags))
            == kvImageNoError
        else { return nil }
        defer { free(source.data) }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let converted = pixels.withUnsafeMutableBytes { destinationBytes -> vImage_Error in
            var destination = vImage_Buffer(
                data: destinationBytes.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )
            // Memory order under byteOrder32Little + premultipliedFirst is B, G, R, A, so
            // the luminance weights are given in that order. They sum to the divisor, so
            // white stays 255.
            let weights: [Int16] = [29, 150, 77, 0]
            return vImageMatrixMultiply_ARGB8888ToPlanar8(
                &source, &destination, weights, 256, nil, 0, vImage_Flags(kvImageNoFlags)
            )
        }
        guard converted == kvImageNoError else { return nil }

        self.width = width
        self.height = height
        self.pixels = pixels
        profile = pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return RowProfile(height: 0, values: []) }
            return RowProfile(grayscale: base, width: width, height: height, bytesPerRow: width)
        }
        columnProfile = pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return ColumnProfile(width: 0, values: []) }
            return ColumnProfile(grayscale: base, width: width, height: height, bytesPerRow: width)
        }
    }
}
