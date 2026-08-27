import CoreGraphics
import Foundation
import ImageIO
import os
import Shared
import UniformTypeIdentifiers

/// How to encode a capture (docs/03 §8.3, §9).
public struct EncodingOptions: Sendable, Hashable {
    public var format: ImageFormat
    /// Quality for lossy formats, 0...1.
    public var quality: Double
    /// The display scale the image was captured at, used for the DPI tag.
    public var scale: DisplayScale
    /// Halve a Retina capture on the way out (docs/03 §8.3).
    public var downscaleToOneToOne: Bool

    public init(
        format: ImageFormat = .png,
        quality: Double = 0.9,
        scale: DisplayScale = .oneToOne,
        downscaleToOneToOne: Bool = false
    ) {
        self.format = format
        self.quality = min(max(quality, 0), 1)
        self.scale = scale
        self.downscaleToOneToOne = downscaleToOneToOne
    }
}

public enum ExportError: Error, Equatable, Sendable {
    case unsupportedFormat(ImageFormat)
    case encodingFailed(ImageFormat)
    case downscaleFailed
    case writeFailed(String)
}

/// Turns captures into file data (docs/03 §9).
///
/// Two details here are the difference between a screenshot that looks right and one
/// that does not:
///
/// * **The colour profile travels with the image.** A capture off a P3 display written
///   without its profile looks washed out everywhere else.
/// * **The DPI tag matches the scale.** A Retina capture is tagged 144 dpi so Preview,
///   Word and browsers show it at the size the user selected rather than at double size.
public struct ImageEncoder: Sendable {
    private let logger = KadrLog.logger(.capture)

    public init() {}

    /// Encodes an image, applying downscaling and metadata.
    public func encode(_ image: CGImage, options: EncodingOptions) throws -> Data {
        let source = options.downscaleToOneToOne && options.scale.factor > 1
            ? try downscale(image, by: options.scale.factor)
            : image

        guard options.format.isWritable else {
            throw ExportError.unsupportedFormat(options.format)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            options.format.contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.unsupportedFormat(options.format)
        }

        CGImageDestinationAddImage(destination, source, properties(for: options) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed(options.format)
        }
        return data as Data
    }

    /// Image properties: quality, and the DPI that makes a Retina capture display at its
    /// true size (docs/03 §9).
    func properties(for options: EncodingOptions) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]

        if options.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }

        // 72 dpi is the baseline; a 2× capture kept at 2× is 144 dpi. A downscaled
        // capture is back to one pixel per point, so it is 72 again.
        let effectiveScale = options.downscaleToOneToOne ? 1 : options.scale.factor
        // Boxed as Double, not CGFloat: a CGFloat inside `Any` does not cast back to
        // Double, which silently breaks anything reading these properties.
        let dpi = Double(72 * effectiveScale)
        properties[kCGImagePropertyDPIWidth] = dpi
        properties[kCGImagePropertyDPIHeight] = dpi

        return properties
    }

    /// High-quality halving of a Retina capture (docs/03 §8.3).
    ///
    /// Drawn through a `CGContext` with high interpolation rather than handed to ImageIO
    /// with a smaller size, because the latter uses a cheaper filter and a screenshot of
    /// text shows the difference immediately.
    func downscale(_ image: CGImage, by factor: CGFloat) throws -> CGImage {
        guard factor > 1 else { return image }
        let width = Int((CGFloat(image.width) / factor).rounded())
        let height = Int((CGFloat(image.height) / factor).rounded())
        guard width > 0, height > 0 else { throw ExportError.downscaleFailed }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ExportError.downscaleFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ExportError.downscaleFailed }
        return result
    }
}
