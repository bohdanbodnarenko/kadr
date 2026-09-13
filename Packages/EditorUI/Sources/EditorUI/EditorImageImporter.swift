import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loads an image file as PNG bytes the composition tool can place (docs/03 §3 P2).
public enum EditorImageImporter {
    public static func png(from url: URL) -> (data: Data, pixelSize: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return png(from: image)
    }

    public static func png(from image: CGImage) -> (data: Data, pixelSize: CGSize)? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (
            data as Data,
            CGSize(width: image.width, height: image.height)
        )
    }
}
