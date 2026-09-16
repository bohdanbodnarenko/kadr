import AnnotationModel
import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import AnnotationRender

/// The redaction preview cache and the per-window source that feeds it (docs/10 R1).
@Suite("Redaction preview cache")
struct RedactionPreviewCacheTests {
    private static func image(width: Int, height: Int) -> CGImage {
        RedactionPreviewSamplingTests.striped(width: width, height: height)
    }

    @Test("Keys separate sources, even over the same pixels")
    func keysSeparateSources() {
        let spec = RedactionSpec(rect: CGRect(x: 1, y: 2, width: 30, height: 40), style: .blur(radius: 8))
        let first = RedactionPreviewCache.Key(token: UUID(), spec: spec, scale: 2)
        let second = RedactionPreviewCache.Key(token: UUID(), spec: spec, scale: 2)
        #expect(first != second)
    }

    /// Two rects that round to the same pixels are the same preview; a sub-pixel move that
    /// crosses a pixel is not.
    @Test("Keys are the pixel box the rasteriser crops", arguments: [
        KeyCase(
            first: CGRect(x: 10, y: 10, width: 20, height: 20),
            second: CGRect(x: 10, y: 10, width: 20, height: 20)
        ),
        KeyCase(
            first: CGRect(x: 10, y: 10, width: 20, height: 20),
            second: CGRect(x: 10.2, y: 10, width: 19.8, height: 20)
        ),
        KeyCase(
            first: CGRect(x: 10, y: 10, width: 20, height: 20),
            second: CGRect(x: 10.5, y: 10, width: 20, height: 20),
            same: false
        ),
        KeyCase(
            first: CGRect(x: 10, y: 10, width: 20, height: 20),
            second: CGRect(x: 10.25, y: 10, width: 20, height: 20),
            scale: 2,
            same: false
        ),
        KeyCase(
            first: CGRect(x: 30, y: 30, width: -20, height: -20),
            second: CGRect(x: 10, y: 10, width: 20, height: 20),
            scale: 2
        )
    ])
    func keysArePixelBoxes(example: KeyCase) {
        let token = UUID()
        let id = AnnotationID()
        let scale = example.scale
        let lhs = RedactionPreviewCache.Key(
            token: token,
            spec: RedactionSpec(id: id, rect: example.first),
            scale: scale
        )
        let rhs = RedactionPreviewCache.Key(
            token: token,
            spec: RedactionSpec(id: id, rect: example.second),
            scale: scale
        )
        #expect((lhs == rhs) == example.same)
    }

    struct KeyCase: Sendable {
        var first: CGRect
        var second: CGRect
        var scale: CGFloat = 1
        var same = true
    }

    @Test("A closing window takes its previews with it, and only its own")
    func removeByToken() {
        let cache = RedactionPreviewCache()
        let spec = RedactionSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let mine = RedactionPreviewCache.Key(token: UUID(), spec: spec, scale: 1)
        let theirs = RedactionPreviewCache.Key(token: UUID(), spec: spec, scale: 1)
        cache.insert(Self.image(width: 10, height: 10), for: mine)
        cache.insert(Self.image(width: 10, height: 10), for: theirs)

        cache.removeAll(token: mine.token)
        #expect(cache.image(for: mine) == nil)
        #expect(cache.image(for: theirs) != nil)
        #expect(cache.usage.entries == 1)
        #expect(cache.usage.bytes == 400)
    }

    @Test("The byte budget evicts the oldest preview first")
    func budgetEvictsOldest() {
        let cache = RedactionPreviewCache(budget: 1000)
        let token = UUID()
        let keys = (0 ..< 3).map { index in
            RedactionPreviewCache.Key(
                token: token,
                spec: RedactionSpec(rect: CGRect(x: index, y: 0, width: 10, height: 10)),
                scale: 1
            )
        }
        for key in keys {
            cache.insert(Self.image(width: 10, height: 10), for: key)
        }
        #expect(cache.image(for: keys[0]) == nil)
        #expect(cache.image(for: keys[1]) != nil)
        #expect(cache.image(for: keys[2]) != nil)
        #expect(cache.usage.bytes == 800)
    }
}

@Suite("Redaction gesture stand-in")
struct RedactionGestureImageTests {
    /// Whole stand-in pixels covering a box, snapped outward.
    @Test("The covering cells enclose the box", arguments: [
        CellCase(
            box: CGRect(x: 0, y: 0, width: 10, height: 10),
            factor: 10,
            cells: CGRect(x: 0, y: 0, width: 1, height: 1)
        ),
        CellCase(
            box: CGRect(x: 5, y: 5, width: 10, height: 10),
            factor: 10,
            cells: CGRect(x: 0, y: 0, width: 2, height: 2)
        ),
        CellCase(
            box: CGRect(x: 20, y: 30, width: 20, height: 5),
            factor: 10,
            cells: CGRect(x: 2, y: 3, width: 2, height: 1)
        ),
        CellCase(
            box: CGRect(x: 3, y: 4, width: 5, height: 6),
            factor: 1,
            cells: CGRect(x: 3, y: 4, width: 5, height: 6)
        ),
        CellCase(
            box: CGRect(x: 1, y: 1, width: 1, height: 1),
            factor: 2.5,
            cells: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    ])
    func enclosingCells(example: CellCase) {
        #expect(RedactionGestureImage.enclosingCells(of: example.box, factor: example.factor) == example.cells)
    }

    struct CellCase: Sendable {
        var box: CGRect
        var factor: CGFloat
        var cells: CGRect
    }

    @Test("A mosaic stand-in has one pixel per cell", arguments: [
        MosaicCase(width: 400, height: 300, cell: 10, expectedWidth: 40, expectedHeight: 30),
        MosaicCase(width: 401, height: 299, cell: 10, expectedWidth: 41, expectedHeight: 30),
        MosaicCase(width: 64, height: 64, cell: 40, expectedWidth: 2, expectedHeight: 2)
    ])
    func mosaicSize(example: MosaicCase) throws {
        let image = RedactionPreviewSamplingTests.striped(width: example.width, height: example.height)
        let stand = try #require(
            RedactionRasterizer().gestureImage(for: .pixelate(cellSize: example.cell), from: image)
        )
        #expect(stand.image.width == example.expectedWidth)
        #expect(stand.image.height == example.expectedHeight)
        #expect(stand.factor == CGFloat(RedactionRasterizer.cellPixels(example.cell)))
    }

    struct MosaicCase: Sendable {
        var width: Int
        var height: Int
        var cell: CGFloat
        var expectedWidth: Int
        var expectedHeight: Int
    }

    @Test("A blur stand-in is capped on its long edge", arguments: [
        FactorCase(width: 1000, height: 800, factor: 1),
        FactorCase(width: 4096, height: 1024, factor: 2),
        FactorCase(width: 2048, height: 4096, factor: 2)
    ])
    func blurFactor(example: FactorCase) {
        #expect(RedactionRasterizer.gestureBlurFactor(width: example.width, height: example.height) == example.factor)
    }

    struct FactorCase: Sendable {
        var width: Int
        var height: Int
        var factor: CGFloat
    }

    @Test("A stand-in region sits where its box is, in capture pixels")
    func regionPlacement() throws {
        let image = RedactionPreviewSamplingTests.striped(width: 400, height: 300)
        let stand = try #require(RedactionRasterizer().gestureImage(for: .pixelate(cellSize: 10), from: image))
        let region = try #require(stand.region(covering: CGRect(x: 25, y: 35, width: 30, height: 10)))
        #expect(region.pixelRect == CGRect(x: 20, y: 30, width: 40, height: 20))
        #expect(region.image.width == 4)
        #expect(region.image.height == 2)
    }

    @Test("Erase has no stand-in: its exact preview is already cheap")
    func eraseHasNone() {
        let image = RedactionPreviewSamplingTests.striped(width: 40, height: 40)
        #expect(RedactionRasterizer().gestureImage(for: .erase, from: image) == nil)
    }
}

@Suite("Redaction preview source")
@MainActor
struct RedactionPreviewSourceTests {
    @Test("An exact preview renders off the main actor and reports back")
    func exactArrives() async throws {
        let cache = RedactionPreviewCache()
        let image = RedactionPreviewSamplingTests.striped(width: 200, height: 200)
        let source = RedactionPreviewSource(image: image, scale: 1, cache: cache)
        let spec = RedactionSpec(rect: CGRect(x: 10, y: 10, width: 50, height: 40), style: .blur(radius: 6))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source.onPreviewReady = {
                source.onPreviewReady = nil
                continuation.resume()
            }
            source.requestExact(spec)
        }
        let preview = try #require(source.cachedExact(spec))
        #expect(preview.width == 50)
        #expect(preview.height == 40)
    }

    @Test("Releasing a source removes its previews from the shared cache")
    func releasingPurges() {
        let cache = RedactionPreviewCache()
        let image = RedactionPreviewSamplingTests.striped(width: 100, height: 100)
        let spec = RedactionSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20), style: .erase)
        var source: RedactionPreviewSource? = RedactionPreviewSource(image: image, scale: 1, cache: cache)
        _ = source?.renderExactNow(spec)
        #expect(cache.usage.entries == 1)
        source = nil
        #expect(cache.usage.entries < 1)
    }

    @Test("While dragging, a box shows the stand-in in a clipped sublayer")
    func liveUsesStandIn() async {
        let cache = RedactionPreviewCache()
        let image = RedactionPreviewSamplingTests.striped(width: 400, height: 400)
        let source = RedactionPreviewSource(image: image, scale: 2, cache: cache)
        let spec = RedactionSpec(rect: CGRect(x: 10, y: 10, width: 40, height: 30), style: .pixelate(cellSize: 8))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source.onPreviewReady = {
                source.onPreviewReady = nil
                continuation.resume()
            }
            _ = source.gestureImage(for: spec.style)
        }

        let context = AnnotationLayerContext(
            imageScale: 2,
            baseImage: image,
            redaction: RedactionPreviewContext(source: source, isLive: true)
        )
        let layer = AnnotationLayerFactory.makeLayer(for: .redaction(spec), contentsScale: 2, context: context)
        let sublayer = layer?.sublayers?.first { $0.name == "kadr.redaction.gesture" }
        #expect(layer?.masksToBounds == true)
        #expect(layer?.contents == nil)
        #expect(sublayer?.isHidden == false)
        #expect(sublayer?.contents != nil)
        // The box is 20…100 capture pixels; cells of 8 snap that out to 16…104.
        #expect(sublayer?.frame == CGRect(x: -2, y: -2, width: 44, height: 32))
        #expect(cache.usage.entries < 1, "nothing is cached mid-drag")
    }
}
