import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the on-disk JPEG that the history grid pages from (docs/03 §5, docs/04 §7.2).
///
/// The browser never opens the original capture: a 400-pixel JPEG is enough for a cell,
/// and `CGImageSourceCreateThumbnailAtIndex` never decodes the full bitmap.
public enum HistoryThumbnailWriter {
    public static let maxPixelSize = 400

    /// Builds a JPEG next to the content-addressed capture, or from a still the caller
    /// already produced (a recording poster frame).
    public static func write(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            return
        }
        let loader = ThumbnailLoader()
        guard let image = loader.thumbnail(for: source, maxPixelSize: maxPixelSize) else {
            throw HistoryError.writeFailed("Could not thumbnail \(source.lastPathComponent)")
        }
        try write(image, to: destination)
    }

    public static func write(_ image: CGImage, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw HistoryError.writeFailed("Could not create a thumbnail file")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.75
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw HistoryError.writeFailed("Could not write a thumbnail")
        }
    }
}
