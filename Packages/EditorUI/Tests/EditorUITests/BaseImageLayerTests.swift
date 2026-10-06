import CoreGraphics
import QuartzCore
import Testing
@testable import EditorUI

/// Very tall captures are drawn in strips, never as one oversized layer (docs/18 ED-13).
@Suite("Base image tiling")
struct BaseImageLayerTests {
    private static func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    @Test("Strip rects cover the image exactly, top-down", arguments: [
        (1440, 900, 0),
        (1440, 8192, 0),
        (1440, 8193, 3),
        (1440, 30000, 8),
        (30000, 1440, 8)
    ])
    func stripRects(width: Int, height: Int, expectedCount: Int) {
        let rects = BaseImageLayer.tileRects(width: width, height: height)
        #expect(rects.count == expectedCount)
        guard !rects.isEmpty else { return }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        #expect(union == CGRect(x: 0, y: 0, width: width, height: height))
        let longest = rects.map { max($0.width, $0.height) }.max() ?? 0
        #expect(Int(longest) <= max(BaseImageLayer.tileLength, min(width, height)))
    }

    @Test("A 30,000 px capture never sits in one full-size layer")
    func tallCaptureIsTiled() throws {
        let layer = BaseImageLayer()
        layer.image = try Self.image(width: 1200, height: 30000)

        #expect(layer.contents == nil)
        #expect(layer.tiles.count == 8)
        for tile in layer.tiles {
            let image = try #require(tile.contents.map { $0 as! CGImage }) // swiftlint:disable:this force_cast
            #expect(image.height <= BaseImageLayer.tileLength)
        }
    }

    @Test("An ordinary capture stays one layer, and strips go when it changes back")
    func ordinaryCaptureIsSingle() throws {
        let layer = BaseImageLayer()
        layer.image = try Self.image(width: 1200, height: 30000)
        layer.image = try Self.image(width: 1440, height: 900)

        #expect(layer.contents != nil)
        #expect(layer.tiles.isEmpty)
        #expect(layer.sublayers?.isEmpty ?? true)
    }

    @Test("Strips are laid out to fill the layer")
    func layout() throws {
        let layer = BaseImageLayer()
        layer.image = try Self.image(width: 1000, height: 10000)
        layer.frame = CGRect(x: 0, y: 0, width: 100, height: 1000)
        layer.layoutIfNeeded()

        let union = layer.tiles.dropFirst().reduce(layer.tiles[0].frame) { $0.union($1.frame) }
        #expect(abs(union.width - 100) < 0.001)
        #expect(abs(union.height - 1000) < 0.001)
    }
}
