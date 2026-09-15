import CoreGraphics
import Foundation
import Testing
@testable import MediaExport

@Suite("Display stitcher")
struct DisplayStitcherTests {
    @Test("Mixed DPI and a negative origin still tile")
    func mixedDPI() {
        let tiles = [
            DisplayStitcher.Tile(rect: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1),
            DisplayStitcher.Tile(rect: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        ]
        let canvas = DisplayStitcher.canvas(for: tiles)
        #expect(canvas.scale == 2)
        #expect(abs(canvas.size.width - (1920 + 1512) * 2) < 0.5)
        let left = DisplayStitcher.pixelRect(of: tiles[0], in: canvas.origin, scale: canvas.scale)
        #expect(abs(left.minX) < 0.5)
        let right = DisplayStitcher.pixelRect(of: tiles[1], in: canvas.origin, scale: canvas.scale)
        #expect(right.minX > left.maxX - 1)
    }
}
