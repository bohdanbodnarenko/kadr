import CoreGraphics
import Foundation
import Testing
@testable import Shared

/// Finding the lines worth snapping to (docs/03 §3 P3, docs/06 M21).
///
/// Table-driven over synthetic bitmaps, because the thing being tested is a judgement
/// call — "is this a window border or is it text?" — and the only honest way to pin that
/// down is to draw both and assert which one survives.
@Suite("Edge detection")
struct EdgeDetectionTests {
    private let width = 100
    private let height = 80

    /// A blank canvas, mid grey.
    private func canvas(_ level: UInt8 = 128) -> [UInt8] {
        [UInt8](repeating: level, count: width * height)
    }

    private func candidates(
        _ pixels: [UInt8],
        options: EdgeDetectionOptions = .default
    ) -> EdgeCandidates {
        pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .none }
            return EdgeDetector.candidates(
                grayscale: base,
                width: width,
                height: height,
                bytesPerRow: width,
                options: options
            )
        }
    }

    private func drawColumn(_ pixels: inout [UInt8], at x: Int, level: UInt8 = 0, rows: Range<Int>? = nil) {
        for y in rows ?? 0 ..< height {
            pixels[y * width + x] = level
        }
    }

    private func drawRow(_ pixels: inout [UInt8], at y: Int, level: UInt8 = 0, columns: Range<Int>? = nil) {
        for x in columns ?? 0 ..< width {
            pixels[y * width + x] = level
        }
    }

    // MARK: - What counts as an edge

    @Test("A blank image has no edges")
    func blankHasNothing() {
        #expect(candidates(canvas()).isEmpty)
    }

    @Test("A full-height line is a vertical edge")
    func verticalLine() {
        var pixels = canvas()
        drawColumn(&pixels, at: 40)
        let found = candidates(pixels)
        #expect(found.verticalEdges.contains(40) || found.verticalEdges.contains(41))
        #expect(found.horizontalEdges.isEmpty)
    }

    @Test("A full-width line is a horizontal edge")
    func horizontalLine() {
        var pixels = canvas()
        drawRow(&pixels, at: 25)
        let found = candidates(pixels)
        #expect(found.horizontalEdges.contains(25) || found.horizontalEdges.contains(26))
        #expect(found.verticalEdges.isEmpty)
    }

    /// The point of the coverage threshold: a paragraph of text produces contrast
    /// everywhere and must not become a hundred snap targets.
    @Test("A short mark is not an edge")
    func shortMarksAreIgnored() {
        var pixels = canvas()
        drawColumn(&pixels, at: 40, rows: 10 ..< 18)
        drawRow(&pixels, at: 30, columns: 5 ..< 12)
        #expect(candidates(pixels).isEmpty)
    }

    @Test("A faint line is not an edge")
    func lowContrastIsIgnored() {
        var pixels = canvas(128)
        drawColumn(&pixels, at: 40, level: 136)
        #expect(candidates(pixels).verticalEdges.isEmpty)
    }

    @Test("An anti-aliased border collapses to one candidate, not three")
    func antiAliasedBorderCollapses() {
        var pixels = canvas()
        drawColumn(&pixels, at: 39, level: 90)
        drawColumn(&pixels, at: 40, level: 0)
        drawColumn(&pixels, at: 41, level: 90)
        #expect(candidates(pixels).verticalEdges.count == 1)
    }

    @Test("A window-shaped box gives four edges")
    func boxGivesFourEdges() {
        var pixels = canvas(200)
        drawColumn(&pixels, at: 20)
        drawColumn(&pixels, at: 80)
        drawRow(&pixels, at: 15)
        drawRow(&pixels, at: 60)
        let found = candidates(pixels)
        #expect(found.verticalEdges.count == 2)
        #expect(found.horizontalEdges.count == 2)
    }

    @Test("Degenerate images are handled rather than trapped", arguments: [(0, 0), (1, 1), (1, 40)])
    func degenerateSizes(size: (width: Int, height: Int)) {
        let pixels = [UInt8](repeating: 0, count: max(1, size.width * size.height))
        let found = pixels.withUnsafeBufferPointer { buffer -> EdgeCandidates in
            guard let base = buffer.baseAddress else { return .none }
            return EdgeDetector.candidates(
                grayscale: base,
                width: size.width,
                height: size.height,
                bytesPerRow: max(1, size.width)
            )
        }
        #expect(found.isEmpty)
    }

    @Test("A CGImage takes the same path as a raw buffer")
    func imageOverload() throws {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 30, y: 0, width: 1, height: height))

        let image = try #require(context.makeImage())
        let found = EdgeDetector.candidates(in: image)
        #expect(found.pixelSize == PixelSize(width: width, height: height))
        #expect(found.verticalEdges.count == 1)
    }
}

/// Pulling a selection onto the lines that were found (docs/06 M21).
@Suite("Edge snapping")
struct EdgeSnapperTests {
    private let candidates = EdgeCandidates(
        verticalEdges: [10, 100, 300],
        horizontalEdges: [20, 200],
        pixelSize: PixelSize(width: 400, height: 300)
    )

    @Test("A value near a line snaps to it")
    func snapsWhenClose() {
        #expect(EdgeSnapper.snapped(103, to: candidates.verticalEdges, tolerance: 6) == 100)
        #expect(EdgeSnapper.snapped(96, to: candidates.verticalEdges, tolerance: 6) == 100)
    }

    @Test("A value far from every line stays where it is")
    func doesNotSnapWhenFar() {
        #expect(EdgeSnapper.snapped(150, to: candidates.verticalEdges, tolerance: 6) == nil)
    }

    @Test("The nearest line wins")
    func nearestWins() {
        #expect(EdgeSnapper.snapped(55, to: [10, 60, 100], tolerance: 10) == 60)
    }

    @Test("A tolerance of zero disables snapping entirely")
    func zeroToleranceIsOff() {
        #expect(EdgeSnapper.snapped(100, to: candidates.verticalEdges, tolerance: 0) == nil)
    }

    @Test("Each edge of a rect snaps on its own")
    func rectEdgesSnapIndependently() {
        let rect = PixelRect(x: 12, y: 198, width: 90, height: 4)
        let snapped = EdgeSnapper.snapped(rect, to: candidates, tolerance: 6)
        #expect(snapped.x == 10)
        #expect(snapped.x + snapped.width == 100)
        #expect(snapped.y == 200)
        // Nothing to snap the bottom to, so it keeps the pixel the user dragged it to.
        #expect(snapped.y + snapped.height == 202)
    }

    @Test("A snap that would invert or empty the rect is refused")
    func refusesDegenerateSnap() {
        let rect = PixelRect(x: 98, y: 5, width: 4, height: 40)
        let snapped = EdgeSnapper.snapped(rect, to: candidates, tolerance: 6)
        #expect(snapped.width > 0)
        #expect(snapped.height > 0)
    }

    @Test("With no candidates the rect is untouched")
    func noCandidatesNoChange() {
        let rect = PixelRect(x: 3, y: 4, width: 5, height: 6)
        #expect(EdgeSnapper.snapped(rect, to: .none, tolerance: 8) == rect)
    }

    @Test("A point inside a box measures that box")
    func enclosingRect() throws {
        let rect = try #require(EdgeSnapper.enclosingRect(aroundX: 50, y: 100, in: candidates))
        #expect(rect == PixelRect(x: 10, y: 20, width: 90, height: 180))
    }

    @Test("Sides with no line fall back to the image's own bounds")
    func enclosingRectUsesImageBounds() throws {
        let rect = try #require(EdgeSnapper.enclosingRect(aroundX: 350, y: 250, in: candidates))
        #expect(rect == PixelRect(x: 300, y: 200, width: 100, height: 100))
    }

    @Test("A point outside the image measures nothing")
    func enclosingRectOutside() {
        #expect(EdgeSnapper.enclosingRect(aroundX: 500, y: 10, in: candidates) == nil)
        #expect(EdgeSnapper.enclosingRect(aroundX: -1, y: 10, in: candidates) == nil)
    }
}
