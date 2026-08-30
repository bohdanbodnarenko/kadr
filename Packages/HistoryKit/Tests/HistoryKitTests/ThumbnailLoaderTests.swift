import CoreGraphics
import Foundation
import ImageIO
import Shared
import Testing
import UniformTypeIdentifiers
@testable import HistoryKit

/// Writes a PNG of a given size to a temporary file.
private func writeImage(width: Int, height: Int) throws -> URL {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    context.setFillColor(CGColor(srgbRed: 0.4, green: 0.7, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-thumb-\(UUID().uuidString).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Could not create a test image destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write the test image")
    }
    return url
}

@Suite("Thumbnails")
struct ThumbnailLoaderTests {
    private let loader = ThumbnailLoader()

    @Test("A thumbnail is bounded by the longest edge, keeping the aspect ratio")
    func boundsLongestEdge() throws {
        let url = try writeImage(width: 2000, height: 1000)
        let thumbnail = try #require(loader.thumbnail(for: url, maxPixelSize: 400))

        #expect(thumbnail.width == 400)
        #expect(thumbnail.height == 200)
    }

    @Test("A tall image is bounded by its height")
    func boundsTallImage() throws {
        let url = try writeImage(width: 500, height: 2000)
        let thumbnail = try #require(loader.thumbnail(for: url, maxPixelSize: 400))

        #expect(thumbnail.height == 400)
        #expect(thumbnail.width == 100)
    }

    @Test("A 5K capture never decodes at full size — that is the whole point")
    func doesNotDecodeFullSize() throws {
        let url = try writeImage(width: 5120, height: 2880)
        let thumbnail = try #require(loader.thumbnail(for: url, maxPixelSize: 400))

        #expect(thumbnail.width <= 400)
        #expect(thumbnail.height <= 400)
        // A 5120×2880 BGRA bitmap is ~59 MB; this must be a rounding error next to it.
        let bytes = thumbnail.height * thumbnail.bytesPerRow
        #expect(bytes < 1_000_000, "thumbnail is \(bytes) bytes, which is not card-sized")
    }

    @Test("A zero or negative size is refused rather than decoding everything")
    func refusesNonPositiveSize() throws {
        let url = try writeImage(width: 100, height: 100)
        #expect(loader.thumbnail(for: url, maxPixelSize: 0) == nil)
        #expect(loader.thumbnail(for: url, maxPixelSize: -10) == nil)
    }

    @Test("A missing file yields no thumbnail rather than crashing")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/kadr-nope.png")
        #expect(loader.thumbnail(for: url, maxPixelSize: 400) == nil)
    }

    @Test("Pixel size is read from metadata without decoding the image")
    func readsPixelSize() throws {
        let url = try writeImage(width: 1234, height: 567)
        #expect(loader.pixelSize(for: url) == PixelSize(width: 1234, height: 567))
    }

    @Test("Pixel size of a missing file is nil")
    func missingPixelSize() {
        #expect(loader.pixelSize(for: URL(fileURLWithPath: "/nope.png")) == nil)
    }

    @Test("Thumbnails can be made from data in hand")
    func fromData() throws {
        let url = try writeImage(width: 800, height: 400)
        let data = try Data(contentsOf: url)
        let thumbnail = try #require(loader.thumbnail(for: data, maxPixelSize: 200))

        #expect(thumbnail.width == 200)
    }
}

@MainActor
@Suite("Thumbnail cache")
struct ThumbnailCacheTests {
    @Test("A second request for the same thumbnail comes back identical")
    func cachesByURLAndSize() throws {
        let cache = ThumbnailCache()
        let url = try writeImage(width: 800, height: 600)

        let first = try #require(cache.thumbnail(for: url, maxPixelSize: 200))
        let second = try #require(cache.thumbnail(for: url, maxPixelSize: 200))

        #expect(first === second, "the cache returned a freshly decoded image")
    }

    @Test("Different sizes are cached separately")
    func sizeIsPartOfTheKey() throws {
        let cache = ThumbnailCache()
        let url = try writeImage(width: 800, height: 600)

        let small = try #require(cache.thumbnail(for: url, maxPixelSize: 100))
        let large = try #require(cache.thumbnail(for: url, maxPixelSize: 400))

        #expect(small.width == 100)
        #expect(large.width == 400)
    }

    @Test("Purging drops everything, as memory pressure does")
    func purge() throws {
        let cache = ThumbnailCache()
        let url = try writeImage(width: 800, height: 600)
        let first = try #require(cache.thumbnail(for: url, maxPixelSize: 200))

        cache.removeAll()

        let second = try #require(cache.thumbnail(for: url, maxPixelSize: 200))
        #expect(first !== second, "the cache kept an image after being purged")
    }

    @Test("A file that cannot be read caches nothing")
    func missingFile() {
        let cache = ThumbnailCache()
        #expect(cache.thumbnail(for: URL(fileURLWithPath: "/nope.png"), maxPixelSize: 200) == nil)
    }

    @Test("The strip and the grid do not evict each other")
    func scopesAreIndependent() throws {
        let cache = ThumbnailCache()
        let url = try writeImage(width: 800, height: 600)

        let strip = try #require(cache.thumbnail(for: url, maxPixelSize: 100, scope: .strip))
        let grid = try #require(cache.thumbnail(for: url, maxPixelSize: 100, scope: .grid))
        #expect(strip !== grid, "scopes should not share an entry")

        cache.purgeStrip()
        let stripAgain = try #require(cache.thumbnail(for: url, maxPixelSize: 100, scope: .strip))
        let gridAgain = try #require(cache.thumbnail(for: url, maxPixelSize: 100, scope: .grid))
        #expect(stripAgain !== strip, "the strip should have been purged")
        #expect(gridAgain === grid, "purging the strip must not drop the grid")
    }
}
