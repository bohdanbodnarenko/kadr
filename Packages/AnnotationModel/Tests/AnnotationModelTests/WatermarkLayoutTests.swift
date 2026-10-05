import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// Where the copies of a watermark go (docs/09 U1.4).
///
/// The interesting failure is invisible in a preview and wrong in the file: a tiled grid
/// laid out upright and then rotated leaves the corners bare, which is exactly where a
/// watermark most needs to be. So the coverage is asserted rather than eyeballed.
@Suite("Watermark layout")
struct WatermarkLayoutTests {
    private let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let textSize = CGSize(width: 120, height: 30)

    private func layout(_ spec: WatermarkSpec) -> WatermarkLayout {
        WatermarkLayout.compute(spec, in: canvas, textSize: textSize)
    }

    // MARK: - Nothing to draw

    @Test("An empty watermark draws nothing", arguments: [
        WatermarkSpec(text: ""),
        WatermarkSpec(text: "   "),
        WatermarkSpec(text: "Kadr", opacity: 0),
        WatermarkSpec(text: "Kadr", fontSize: .zero)
    ])
    func emptyDrawsNothing(spec: WatermarkSpec) {
        #expect(spec.isIdentity)
        #expect(layout(spec).placements.isEmpty)
    }

    @Test("A watermark with text is not empty")
    func nonEmpty() {
        #expect(!WatermarkSpec.signature("Kadr").isIdentity)
        #expect(!WatermarkSpec.tiled("Kadr").isIdentity)
    }

    // MARK: - A single mark

    @Test("A single mark is one placement")
    func singleMark() {
        #expect(layout(.signature("Kadr")).placements.count == 1)
    }

    @Test("A single mark sits inside the canvas, away from the edge", arguments: BeautifyAlignment.allCases)
    func singleMarkStaysInside(placement: BeautifyAlignment) {
        var spec = WatermarkSpec.signature("Kadr")
        spec.placement = placement
        let mark = layout(spec).placements[0]

        #expect(canvas.contains(mark.center))
        // The whole text has to fit, not just its centre.
        #expect(mark.center.x - textSize.width / 2 > canvas.minX)
        #expect(mark.center.x + textSize.width / 2 < canvas.maxX)
    }

    @Test("The corner it is aligned to is the corner it lands in")
    func placementFollowsAlignment() {
        var topLeft = WatermarkSpec.signature("Kadr")
        topLeft.placement = .topLeading
        var bottomRight = WatermarkSpec.signature("Kadr")
        bottomRight.placement = .bottomTrailing

        let first = layout(topLeft).placements[0].center
        let second = layout(bottomRight).placements[0].center
        #expect(first.x < second.x)
        #expect(first.y < second.y)
    }

    @Test("A mark too big for a corner is centerd rather than pushed off the canvas")
    func oversizedMarkIsCentred() {
        let huge = WatermarkLayout.compute(
            .signature("Kadr"),
            in: canvas,
            textSize: CGSize(width: 4000, height: 3000)
        )
        #expect(huge.placements.count == 1)
        #expect(huge.placements[0].center == CGPoint(x: canvas.midX, y: canvas.midY))
    }

    // MARK: - Tiling

    @Test("A tiled watermark is many placements")
    func tiledIsMany() {
        #expect(layout(.tiled("Kadr")).placements.count > 10)
    }

    /// The property the whole rotated-frame construction exists for. Every corner of the
    /// canvas must have a mark near it, or a crop of that corner comes out clean.
    @Test("The tiling covers every corner", arguments: [CGFloat(0), -30, 45, 90, 135])
    func tilingCoversTheCorners(angle: CGFloat) {
        var spec = WatermarkSpec.tiled("Kadr")
        spec.rotationDegrees = angle
        let placements = layout(spec).placements

        let reach = max(textSize.width, textSize.height) * spec.spacing * 2
        for corner in [
            CGPoint(x: canvas.minX, y: canvas.minY),
            CGPoint(x: canvas.maxX, y: canvas.minY),
            CGPoint(x: canvas.maxX, y: canvas.maxY),
            CGPoint(x: canvas.minX, y: canvas.maxY)
        ] {
            let nearest = placements
                .map { hypot($0.center.x - corner.x, $0.center.y - corner.y) }
                .min() ?? .infinity
            #expect(nearest < reach, "corner \(corner) at \(angle)° is \(nearest) from the nearest mark")
        }
    }

    @Test("Every tile carries the same rotation")
    func tilesShareTheAngle() {
        var spec = WatermarkSpec.tiled("Kadr")
        spec.rotationDegrees = -30
        #expect(layout(spec).placements.allSatisfy { $0.rotationDegrees == -30 })
    }

    @Test("Wider spacing means fewer marks")
    func spacingThinsTheGrid() {
        var tight = WatermarkSpec.tiled("Kadr")
        tight.spacing = 1
        var loose = WatermarkSpec.tiled("Kadr")
        loose.spacing = 4

        #expect(layout(tight).placements.count > layout(loose).placements.count)
    }

    /// Alternate rows are offset, so the result reads as a texture rather than as columns.
    @Test("The rows are staggered")
    func rowsAreStaggered() {
        var spec = WatermarkSpec.tiled("Kadr")
        spec.rotationDegrees = 0
        let placements = layout(spec).placements

        // Group by row, then compare two adjacent rows' x positions: a staggered grid
        // offsets every other row by half a step, so they cannot line up.
        let rows = Dictionary(grouping: placements) { ($0.center.y * 100).rounded() }
        let ordered = rows.keys.sorted()
        #expect(ordered.count >= 2)
        let first = Set((rows[ordered[0]] ?? []).map { ($0.center.x * 100).rounded() })
        let second = Set((rows[ordered[1]] ?? []).map { ($0.center.x * 100).rounded() })
        #expect(first != second, "adjacent rows should not share their x positions")
    }

    /// A pathological spacing against a huge canvas must not ask for millions of tiles.
    @Test("An absurd request is capped rather than run")
    func tileCountIsCapped() {
        let enormous = WatermarkLayout.compute(
            .tiled("Kadr"),
            in: CGRect(x: 0, y: 0, width: 100_000, height: 100_000),
            textSize: CGSize(width: 1, height: 1)
        )
        #expect(enormous.placements.count <= WatermarkLayout.maximumTiles)
    }

    @Test("A zero-sized canvas draws nothing rather than dividing by zero")
    func zeroCanvas() {
        #expect(WatermarkLayout.compute(.tiled("Kadr"), in: .zero, textSize: textSize)
            .placements.isEmpty)
    }

    // MARK: - Sizing and persistence

    @Test("The font size is relative to the canvas", arguments: [
        CGSize(width: 800, height: 600),
        CGSize(width: 8000, height: 6000)
    ])
    func fontSizeScales(size: CGSize) {
        let computed = WatermarkLayout.compute(
            WatermarkSpec(text: "Kadr", fontSize: .relative(0.05)),
            in: CGRect(origin: .zero, size: size),
            textSize: textSize
        )
        #expect(computed.fontSize == min(size.width, size.height) * 0.05)
    }

    @Test("Spacing is clamped so tiles never smear together")
    func spacingIsClamped() {
        #expect(WatermarkSpec(spacing: 0).spacing >= 1)
        #expect(WatermarkSpec(spacing: 999).spacing <= 12)
    }

    @Test("A watermark round-trips", arguments: [
        WatermarkSpec.signature("Kadr"),
        .tiled("Confidential"),
        WatermarkSpec(text: "Draft", rotationDegrees: 45, isTiled: true, spacing: 3)
    ])
    func roundTrips(spec: WatermarkSpec) throws {
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(WatermarkSpec.self, from: data) == spec)
    }

    @Test("A spec with no fields decodes to something harmless")
    func emptyObject() throws {
        let spec = try JSONDecoder().decode(WatermarkSpec.self, from: Data("{}".utf8))
        #expect(spec.isIdentity, "no text means nothing is drawn")
    }
}

/// The border ring, which is card geometry rather than a thing drawn on top (docs/09 U1.4).
@Suite("Beautify border")
struct BeautifyBorderTests {
    private let content = CGSize(width: 400, height: 300)

    private func layout(_ border: BeautifyBorder, padding: BeautifyMetric = .zero) -> BeautifyLayout {
        BeautifyLayout.compute(
            contentSize: content,
            spec: BeautifySpec(
                padding: padding,
                cornerRadius: .points(20),
                shadow: .none,
                border: border,
                sticksToEdges: false
            )
        )
    }

    @Test("With no border the card and the image are the same rect")
    func noBorder() {
        let computed = layout(.none)
        #expect(computed.cardRect == computed.imageRect)
        #expect(computed.corners == computed.imageCorners)
    }

    /// A border grows the card outwards. Turning one on must not shrink the screenshot.
    @Test("A border grows the card and leaves the capture its own size")
    func borderGrowsTheCard() {
        let computed = layout(BeautifyBorder(thickness: .points(10)))
        #expect(computed.imageRect.size == content)
        #expect(computed.cardRect.size == CGSize(width: 420, height: 320))
    }

    @Test("The capture sits centerd inside the ring")
    func captureIsCentredInTheRing() {
        let computed = layout(BeautifyBorder(thickness: .points(10)))
        #expect(computed.imageRect.minX - computed.cardRect.minX == 10)
        #expect(computed.cardRect.maxY - computed.imageRect.maxY == 10)
    }

    /// Concentric curves, or the ring reads as two rounded rectangles near each other.
    @Test("The inner corners are the outer ones less the thickness")
    func cornersAreConcentric() {
        let computed = layout(BeautifyBorder(thickness: .points(6)))
        #expect(computed.corners.topLeading == 20)
        #expect(computed.imageCorners.topLeading == 14)
    }

    @Test("A ring thicker than the radius squares the inside rather than inverting it")
    func thickRingSquaresTheInside() {
        let computed = layout(BeautifyBorder(thickness: .points(40)))
        #expect(computed.imageCorners.largest == 0)
    }

    @Test("The thickness scales with the capture", arguments: [
        CGSize(width: 400, height: 300),
        CGSize(width: 4000, height: 3000)
    ])
    func thicknessScales(size: CGSize) {
        let computed = BeautifyLayout.compute(
            contentSize: size,
            spec: BeautifySpec(padding: .zero, shadow: .none, border: BeautifyBorder(thickness: .relative(0.02)))
        )
        let expected = min(size.width, size.height) * 0.02
        #expect(computed.imageRect.minX - computed.cardRect.minX == expected)
    }

    @Test("Padding still surrounds the ring")
    func paddingSurroundsTheRing() {
        let computed = layout(BeautifyBorder(thickness: .points(10)), padding: .points(30))
        #expect(computed.cardRect.minX == 30)
        #expect(computed.imageRect.minX == 40)
        #expect(computed.canvasSize == CGSize(width: 480, height: 380))
    }

    @Test("A border round-trips, and an older document simply has none")
    func persistence() throws {
        let spec = BeautifySpec(border: .mount)
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(BeautifySpec.self, from: data).border == .mount)

        let legacy = try JSONDecoder().decode(BeautifySpec.self, from: Data("{}".utf8))
        #expect(legacy.border == .none)
    }
}
