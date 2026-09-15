import CoreGraphics
import Foundation

/// Lays several display captures into one image (docs/16 CAP-3).
///
/// Layout uses global point rects at the highest scale factor, with transparent gaps
/// where the displays do not tile. The stitcher never retains the sources — encode and
/// release immediately in the caller.
public enum DisplayStitcher: Sendable {
    public struct Tile: Sendable {
        public var rect: CGRect
        public var scale: CGFloat

        public init(rect: CGRect, scale: CGFloat) {
            self.rect = rect
            self.scale = max(scale, 1)
        }
    }

    public struct Canvas: Sendable {
        public var origin: CGPoint
        public var size: CGSize
        public var scale: CGFloat
    }

    public static func canvas(for tiles: [Tile]) -> Canvas {
        guard let first = tiles.first else {
            return Canvas(origin: .zero, size: CGSize(width: 1, height: 1), scale: 1)
        }
        let scale = tiles.map(\.scale).max() ?? first.scale
        var union = first.rect
        for tile in tiles.dropFirst() {
            union = union.union(tile.rect)
        }
        return Canvas(
            origin: union.origin,
            size: CGSize(width: max(union.width * scale, 1), height: max(union.height * scale, 1)),
            scale: scale
        )
    }

    public static func pixelRect(of tile: Tile, in canvasOrigin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: (tile.rect.minX - canvasOrigin.x) * scale,
            y: (tile.rect.minY - canvasOrigin.y) * scale,
            width: tile.rect.width * scale,
            height: tile.rect.height * scale
        )
    }

    /// Draws `images` into one bitmap. Caller must encode and drop the result.
    public static func compose(_ images: [CGImage], tiles: [Tile]) -> CGImage? {
        guard images.count == tiles.count, let first = images.first else { return nil }
        let canvas = canvas(for: tiles)
        let width = max(Int(canvas.size.width.rounded()), 1)
        let height = max(Int(canvas.size.height.rounded()), 1)
        let colorSpace = first.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for (image, tile) in zip(images, tiles) {
            var rect = pixelRect(of: tile, in: canvas.origin, scale: canvas.scale)
            rect.origin.y = canvas.size.height - rect.maxY
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }
}
