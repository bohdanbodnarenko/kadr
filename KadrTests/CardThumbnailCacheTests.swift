import CoreGraphics
import Testing
@testable import Kadr

/// docs/18 OUT-11: card thumbnails are decoded once, and the cache stays small.
@MainActor
@Suite("Card thumbnail cache")
struct CardThumbnailCacheTests {
    private func key(_ index: Int) -> CardThumbnailCache.Key {
        CardThumbnailCache.Key(path: "/c/\(index).png", revision: 0, maxPixelSize: 400)
    }

    @Test("The cache keeps only the newest entries, and empties with the cards")
    func bounded() throws {
        let cache = CardThumbnailCache()
        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let total = CardThumbnailCache.capacity + 3
        for index in 0 ..< total {
            cache.insert(image, for: key(index))
        }

        #expect(cache.count == CardThumbnailCache.capacity)
        #expect(cache.image(for: key(0)) == nil)
        #expect(cache.image(for: key(total - 1)) != nil)
        cache.removeAll()
        #expect(cache.image(for: key(total - 1)) == nil)
    }
}
