import CoreGraphics
import Foundation
import ImageIO
import os
import Shared
import UniformTypeIdentifiers

/// Rotate, flip, and Retina-downscale a still image (CleanShot §6.2, docs/03 §3 P2).
public enum ImageTransform: Sendable, Equatable {
    /// 90° clockwise.
    case rotateClockwise
    case flipHorizontal
    case flipVertical
    case downscaleRetina(DisplayScale)
}

/// Rewrites a capture on disk. Used by the overlay context menu so a card can be
/// rotated or halved without opening the editor.
public struct ImageTransformer: Sendable {
    private let encoder = ImageEncoder()
    private let logger = KadrLog.logger(.overlay)

    public init() {}

    /// Applies the transform in memory.
    public func apply(_ transform: ImageTransform, to image: CGImage) throws -> CGImage {
        switch transform {
        case .rotateClockwise:
            try rotateClockwise(image)
        case .flipHorizontal:
            try flipHorizontal(image)
        case .flipVertical:
            try flipVertical(image)
        case let .downscaleRetina(scale):
            try encoder.downscale(image, by: scale.factor)
        }
    }

    /// Replaces `url` atomically with the transformed image. Returns the new pixel size.
    @discardableResult
    public func rewrite(_ url: URL, applying transform: ImageTransform) throws -> PixelSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ExportError.writeFailed("Could not read \(url.lastPathComponent)")
        }

        let transformed = try apply(transform, to: image)
        let format = Self.format(from: url)
        let scale: DisplayScale = switch transform {
        case .downscaleRetina: .oneToOne
        case .rotateClockwise, .flipHorizontal, .flipVertical: Self.scale(of: source)
        }
        let data = try encoder.encode(transformed, options: EncodingOptions(format: format, scale: scale))
        try replace(url, with: data)
        return PixelSize(width: transformed.width, height: transformed.height)
    }

    public static func format(from url: URL) -> ImageFormat {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "webp": .webp
        default: .png
        }
    }

    public static func scale(of source: CGImageSource) -> DisplayScale {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0
        else {
            return .oneToOne
        }
        return DisplayScale(max(1, CGFloat((dpi / 72).rounded())))
    }

    private func rotateClockwise(_ image: CGImage) throws -> CGImage {
        try drawn(width: image.height, height: image.width, from: image) { context in
            context.translateBy(x: CGFloat(image.height), y: 0)
            context.rotate(by: .pi / 2)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private func flipHorizontal(_ image: CGImage) throws -> CGImage {
        try drawn(width: image.width, height: image.height, from: image) { context in
            context.translateBy(x: CGFloat(image.width), y: 0)
            context.scaleBy(x: -1, y: 1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private func flipVertical(_ image: CGImage) throws -> CGImage {
        try drawn(width: image.width, height: image.height, from: image) { context in
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private func drawn(
        width: Int,
        height: Int,
        from image: CGImage,
        body: (CGContext) -> Void
    ) throws -> CGImage {
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
        body(context)
        guard let result = context.makeImage() else { throw ExportError.downscaleFailed }
        return result
    }

    private func replace(_ url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".kadr-xform-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }
}
