import CoreGraphics
import Foundation
import ImageIO
import os
import Shared

/// Makes card-sized thumbnails without ever decoding a capture at full size.
///
/// This is doc 04 §7 rule 2 in code. A 5K capture is roughly 59 MB decoded; a 400 pt card
/// needs well under a megabyte. `CGImageSourceCreateThumbnailAtIndex` decodes straight to
/// the requested size, so the big bitmap never exists in the agent at all — which is the
/// difference between an overlay that costs a few MB and one that blows the entire idle
/// budget (PRD §8).
public struct ThumbnailLoader: Sendable {
    private let logger = KadrLog.logger(.history)

    public init() {}

    /// Loads a thumbnail from a file, decoding no larger than `maxPixelSize`.
    ///
    /// - Parameter maxPixelSize: the longest edge, in pixels. Pass the card's size in
    ///   points multiplied by the display scale so the card is sharp without being
    ///   wasteful.
    public func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        // Deferred cache: creating the source must not read the whole file.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            logger.error("Could not read \(url.lastPathComponent, privacy: .private) for a thumbnail")
            return nil
        }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    /// Loads a thumbnail from data already in hand.
    public func thumbnail(for data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Decode now, while the size is bounded, rather than lazily at draw time.
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The pixel size of an image, read from its metadata without decoding it.
    public func pixelSize(for url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return PixelSize(width: width, height: height)
    }
}
