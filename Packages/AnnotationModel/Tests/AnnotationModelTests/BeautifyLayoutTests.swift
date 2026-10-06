import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// The pure layout function every beautify surface shares (docs/03 §3 P2, docs/09 U1.1).
///
/// Golden-tested because three things draw from it — the live CALayer canvas, the export
/// renderer and any preview — and the only way they agree is that none of them does its own
/// arithmetic. A change here that nobody notices is a change that makes the exported file
/// differ from what the user was looking at.
@Suite("Beautify layout")
struct BeautifyLayoutTests {
    /// A 200×100 capture: shortest edge 100, so a `.relative(0.4)` metric is 40 points.
    private let content = CGSize(width: 200, height: 100)

    private func plain(
        padding: BeautifyMetric = .zero,
        cornerRadius: BeautifyMetric = .zero,
        shadow: BeautifyShadow = .none,
        aspect: BeautifyAspect = .original,
        alignment: BeautifyAlignment = .center,
        sticksToEdges: Bool = false
    ) -> BeautifySpec {
        BeautifySpec(
            padding: padding,
            cornerRadius: cornerRadius,
            shadow: shadow,
            aspect: aspect,
            alignment: alignment,
            sticksToEdges: sticksToEdges
        )
    }

    // MARK: - Padding and the shadow's room

    @Test("Padding grows the canvas equally on every side")
    func paddingOnly() {
        let layout = BeautifyLayout.compute(contentSize: content, spec: plain(padding: .points(40)))

        #expect(layout.canvasSize == CGSize(width: 280, height: 180))
        #expect(layout.cardRect == CGRect(x: 40, y: 40, width: 200, height: 100))
        #expect(layout.imageRect == layout.cardRect, "there is no border ring yet")
    }

    /// The reason metrics are normalized: the same preset on two captures should *look*
    /// the same, which means the padding-to-capture ratio has to be the same.
    @Test("A relative padding scales with the capture", arguments: [
        CGSize(width: 200, height: 100),
        CGSize(width: 2000, height: 1000),
        CGSize(width: 640, height: 640)
    ])
    func relativePaddingScales(content: CGSize) {
        let layout = BeautifyLayout.compute(contentSize: content, spec: plain(padding: .relative(0.1)))
        let shortestEdge = min(content.width, content.height)

        #expect(layout.cardRect.minX == shortestEdge * 0.1)
        #expect(layout.canvasSize.width == content.width + shortestEdge * 0.2)
    }

    @Test("An absolute padding does not scale, because the user asked for points")
    func absolutePaddingIsLiteral() {
        let small = BeautifyLayout.compute(contentSize: content, spec: plain(padding: .points(24)))
        let large = BeautifyLayout.compute(
            contentSize: CGSize(width: 2000, height: 1000),
            spec: plain(padding: .points(24))
        )
        #expect(small.cardRect.minX == 24)
        #expect(large.cardRect.minX == 24)
    }

    @Test("A shadow that sticks out past the padding expands the canvas so it is not clipped")
    func shadowOutset() {
        let spec = plain(
            padding: .points(10),
            shadow: BeautifyShadow(opacity: 0.3, blur: .points(20), offsetY: .points(8))
        )
        let layout = BeautifyLayout.compute(contentSize: CGSize(width: 100, height: 100), spec: spec)
        let expectedInset: CGFloat = 20 + 8

        #expect(layout.canvasSize.width == 100 + expectedInset * 2)
        #expect(layout.cardRect.minX == expectedInset)
    }

    @Test("A disabled shadow asks for no room at all")
    func disabledShadowCostsNothing() {
        let spec = plain(padding: .points(10), shadow: BeautifyShadow(opacity: 0, blur: .points(80)))
        let layout = BeautifyLayout.compute(contentSize: CGSize(width: 100, height: 100), spec: spec)
        #expect(layout.cardRect.minX == 10)
    }

    // MARK: - Aspect

    @Test("A 1:1 preset never shrinks the capture", arguments: [
        CGSize(width: 200, height: 100),
        CGSize(width: 100, height: 200),
        CGSize(width: 150, height: 150)
    ])
    func squareDoesNotShrink(content: CGSize) {
        let layout = BeautifyLayout.compute(contentSize: content, spec: plain(aspect: .square))

        #expect(layout.canvasSize.width == layout.canvasSize.height)
        #expect(layout.canvasSize.width >= content.width)
        #expect(layout.canvasSize.height >= content.height)
        #expect(layout.cardRect.size == content)
    }

    @Test("Social presets produce the advertised aspect", arguments: [
        (BeautifySpec.twitter, CGFloat(16) / 9),
        (BeautifySpec.instagram, CGFloat(4) / 5),
        (BeautifySpec.story, CGFloat(9) / 16),
        (BeautifySpec.stuckBottom, CGFloat(16) / 9)
    ])
    func socialAspect(spec: BeautifySpec, ratio: CGFloat) {
        let layout = BeautifyLayout.compute(contentSize: CGSize(width: 800, height: 500), spec: spec)
        let actual = layout.canvasSize.width / layout.canvasSize.height
        #expect(abs(actual - ratio) < 0.001)
    }

    // MARK: - Alignment

    @Test("Center splits the leftover space")
    func centreSplitsLeftover() {
        let layout = BeautifyLayout.compute(contentSize: content, spec: plain(aspect: .square))
        #expect(layout.cardRect.origin == CGPoint(x: 0, y: 50))
    }

    /// Alignment moves the card *within* the padding, not through it: an unstuck bottom
    /// alignment still leaves its padding underneath.
    @Test("An unstuck alignment keeps its padding on every edge")
    func unstuckAlignmentKeepsPadding() {
        let spec = plain(padding: .points(20), aspect: .square, alignment: .bottom)
        let layout = BeautifyLayout.compute(contentSize: content, spec: spec)

        #expect(layout.cardRect.maxY == layout.canvasSize.height - 20)
        #expect(layout.cardRect.minX == 20)
    }

    @Test("Every alignment keeps the card inside the canvas", arguments: BeautifyAlignment.allCases)
    func alignmentStaysInBounds(alignment: BeautifyAlignment) {
        let spec = plain(padding: .points(16), aspect: .square, alignment: alignment)
        let layout = BeautifyLayout.compute(contentSize: content, spec: spec)
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)

        #expect(canvas.contains(layout.cardRect))
        #expect(layout.cardRect.size == content)
    }

    @Test("Alignment does not change the canvas, only the card's place in it", arguments: BeautifyAlignment.allCases)
    func alignmentDoesNotResizeTheCanvas(alignment: BeautifyAlignment) {
        let base = BeautifyLayout.compute(contentSize: content, spec: plain(padding: .points(16), aspect: .square))
        let moved = BeautifyLayout.compute(
            contentSize: content,
            spec: plain(padding: .points(16), aspect: .square, alignment: alignment)
        )
        #expect(base.canvasSize == moved.canvasSize)
    }

    // MARK: - Stuck edges

    /// The composition the whole alignment feature exists for: the capture runs off the
    /// bottom of the frame rather than floating above it.
    @Test("Sticking to the bottom removes the padding there and squares those corners")
    func stuckBottom() {
        let spec = plain(
            padding: .points(20),
            cornerRadius: .points(12),
            aspect: .square,
            alignment: .bottom,
            sticksToEdges: true
        )
        let layout = BeautifyLayout.compute(contentSize: content, spec: spec)

        #expect(layout.cardRect.maxY == layout.canvasSize.height, "the capture should reach the edge")
        #expect(layout.corners.bottomLeading == 0)
        #expect(layout.corners.bottomTrailing == 0)
        #expect(layout.corners.topLeading == 12, "the corners away from the edge stay round")
        #expect(layout.corners.topTrailing == 12)
        #expect(layout.stuckEdges == .bottom)
    }

    @Test("A stuck corner presses two edges and squares three corners")
    func stuckCorner() {
        let spec = plain(
            padding: .points(20),
            cornerRadius: .points(10),
            aspect: .square,
            alignment: .bottomTrailing,
            sticksToEdges: true
        )
        let layout = BeautifyLayout.compute(contentSize: content, spec: spec)

        #expect(layout.cardRect.maxY == layout.canvasSize.height)
        #expect(layout.cardRect.maxX == layout.canvasSize.width)
        #expect(layout.corners.topLeading == 10, "only the corner away from both edges stays round")
        #expect(layout.corners.topTrailing == 0)
        #expect(layout.corners.bottomLeading == 0)
        #expect(layout.corners.bottomTrailing == 0)
    }

    @Test("Center never sticks to anything, whatever the toggle says")
    func centreNeverSticks() {
        let spec = plain(padding: .points(20), alignment: .center, sticksToEdges: true)
        let layout = BeautifyLayout.compute(contentSize: content, spec: spec)

        #expect(layout.stuckEdges == .none)
        #expect(layout.cardRect.minX == 20)
    }

    @Test("Turning sticking off restores the padding", arguments: BeautifyAlignment.allCases)
    func unstickingRestoresPadding(alignment: BeautifyAlignment) {
        let spec = plain(padding: .points(20), alignment: alignment, sticksToEdges: false)
        let layout = BeautifyLayout.compute(contentSize: content, spec: spec)

        #expect(layout.stuckEdges == .none)
        #expect(layout.cardRect.minX == 20)
        #expect(layout.cardRect.minY == 20)
        #expect(layout.canvasSize == CGSize(width: 240, height: 140))
    }

    // MARK: - Corners

    @Test("A radius is never more than half the shorter side")
    func radiusIsClamped() {
        let spec = plain(cornerRadius: .points(500))
        let layout = BeautifyLayout.compute(contentSize: content, spec: spec)
        #expect(layout.corners.largest == 50, "half of the 100-point side")
    }

    @Test("A relative radius scales with the capture")
    func relativeRadiusScales() {
        let spec = plain(cornerRadius: .relative(0.05))
        let small = BeautifyLayout.compute(contentSize: content, spec: spec)
        let large = BeautifyLayout.compute(contentSize: CGSize(width: 2000, height: 1000), spec: spec)

        #expect(small.corners.topLeading == 5)
        #expect(large.corners.topLeading == 50)
    }

    // MARK: - Degenerate input

    @Test("A zero-sized capture lays out rather than dividing by zero")
    func zeroContent() {
        let layout = BeautifyLayout.compute(contentSize: .zero, spec: plain(padding: .relative(0.1)))
        #expect(layout.canvasSize.width > 0)
        #expect(layout.canvasSize.height > 0)
    }

    @Test("A negative metric is treated as none")
    func negativeMetric() {
        let layout = BeautifyLayout.compute(contentSize: content, spec: plain(padding: .relative(-2)))
        #expect(layout.canvasSize == content)
    }

    @Test("A camera that leans off the card grows the canvas")
    func cameraGrowsTheStage() {
        let camera = AnnotationCameraSpec(tiltDegrees: 40, fieldOfViewDegrees: 80, zoom: 1.4)
        let without = BeautifyLayout.compute(contentSize: content, spec: plain(padding: .points(10)))
        let layout = without.expanded(toFit: camera)
        #expect(layout.canvasSize.width >= without.canvasSize.width - 0.5)
        #expect(layout.canvasSize.height >= without.canvasSize.height - 0.5)
        let quad = AnnotationCameraGeometry.project(spec: camera, contentRect: layout.cardRect)
        #expect(quad.boundingBox.minX >= -0.5)
        #expect(quad.boundingBox.minY >= -0.5)
        #expect(quad.boundingBox.maxX <= layout.canvasSize.width + 0.5)
        #expect(quad.boundingBox.maxY <= layout.canvasSize.height + 0.5)
    }

    @Test("A camera ignores stuck edges so the lean is not clipped")
    func cameraClearsStuckEdges() {
        let spec = BeautifySpec(
            padding: .points(20),
            cornerRadius: .points(8),
            alignment: .bottom,
            sticksToEdges: true
        )
        let stuck = BeautifyLayout.compute(contentSize: content, spec: spec)
        let camera = BeautifyLayout.compute(
            contentSize: content,
            spec: spec,
            camera: AnnotationCameraSpec(tiltDegrees: 20)
        )
        #expect(stuck.stuckEdges.contains(.bottom))
        #expect(camera.stuckEdges == .none)
    }
}
