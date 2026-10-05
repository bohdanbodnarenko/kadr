import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// The zoom target drawn on the preview (docs/09 U3.3).
@Suite("Studio zoom target")
struct StudioZoomTargetTests {
    private let fitted = CGRect(x: 100, y: 50, width: 800, height: 450)

    @Test("At 1× the target is the whole picture")
    func wholePictureAtOne() {
        let target = StudioZoomTargetGeometry.viewport(
            anchor: CGPoint(x: 0.5, y: 0.5),
            magnification: 1,
            in: fitted
        )

        #expect(abs(target.width - fitted.width) < 0.001)
        #expect(abs(target.height - fitted.height) < 0.001)
        #expect(abs(target.midX - fitted.midX) < 0.001)
    }

    @Test("The target centers on the anchor when there is room")
    func centresOnAnchor() {
        let target = StudioZoomTargetGeometry.viewport(
            anchor: CGPoint(x: 0.5, y: 0.5),
            magnification: 2,
            in: fitted
        )

        #expect(abs(target.width - fitted.width / 2) < 0.001)
        #expect(abs(target.midX - fitted.midX) < 0.001)
        #expect(abs(target.midY - fitted.midY) < 0.001)
    }

    /// The render has nothing to show outside the recording, so a target aimed at a corner
    /// stops with its edge against the picture's edge rather than hanging off it.
    @Test("A target aimed at a corner stops inside the picture", arguments: [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)
    ])
    func clampedToThePicture(anchor: CGPoint) {
        let target = StudioZoomTargetGeometry.viewport(anchor: anchor, magnification: 3, in: fitted)

        #expect(target.minX >= fitted.minX - 0.001)
        #expect(target.minY >= fitted.minY - 0.001)
        #expect(target.maxX <= fitted.maxX + 0.001)
        #expect(target.maxY <= fitted.maxY + 0.001)
        #expect(abs(target.width - fitted.width / 3) < 0.001)
    }

    @Test("A point on the picture round-trips through the anchor it stands for")
    func anchorRoundTrip() {
        let point = CGPoint(x: fitted.minX + fitted.width * 0.25, y: fitted.minY + fitted.height * 0.75)
        let anchor = StudioZoomTargetGeometry.anchor(at: point, in: fitted)

        #expect(abs(anchor.x - 0.25) < 0.001)
        #expect(abs(anchor.y - 0.75) < 0.001)

        // Away from the edges, the target that anchor produces is centred back on the point.
        let target = StudioZoomTargetGeometry.viewport(anchor: anchor, magnification: 2, in: fitted)
        #expect(abs(target.midX - point.x) < 0.001)
    }

    @Test("Dragging outside the picture still aims at its edge")
    func anchorClamps() {
        let anchor = StudioZoomTargetGeometry.anchor(
            at: CGPoint(x: fitted.maxX + 500, y: fitted.minY - 500),
            in: fitted
        )

        #expect(anchor == CGPoint(x: 1, y: 0))
    }

    @Test("A corner dragged towards the center zooms in")
    func cornerDragZoomsIn() {
        let anchor = CGPoint(x: 0.5, y: 0.5)
        let far = StudioZoomTargetGeometry.magnification(
            draggingCornerTo: CGPoint(x: fitted.maxX, y: fitted.maxY),
            anchor: anchor,
            in: fitted
        )
        let near = StudioZoomTargetGeometry.magnification(
            draggingCornerTo: CGPoint(x: fitted.midX + 100, y: fitted.midY + 56),
            anchor: anchor,
            in: fitted
        )

        #expect(abs(far - 1) < 0.01, "a corner at the picture's corner is the whole picture")
        #expect(near > far)
        #expect(near <= StudioZoomTargetGeometry.magnificationLimit.upperBound)
    }

    @Test("Magnification stays within its limits", arguments: [-400.0, 0.0, 1.0, 10000.0])
    func magnificationClamps(offset: Double) {
        let zoom = StudioZoomTargetGeometry.magnification(
            draggingCornerTo: CGPoint(x: fitted.midX + offset, y: fitted.midY + offset),
            anchor: CGPoint(x: 0.5, y: 0.5),
            in: fitted,
            limit: 1 ... 8
        )

        #expect(zoom >= 1)
        #expect(zoom <= 8)
    }

    @Test("A recorded pointer sample maps onto the picture")
    func pointerSampleMaps() throws {
        let point = try #require(StudioZoomTargetGeometry.point(
            forPixel: CGPoint(x: 960, y: 270),
            in: CGSize(width: 1920, height: 1080),
            fitted: fitted
        ))

        #expect(abs(point.x - fitted.midX) < 0.001)
        #expect(abs(point.y - (fitted.minY + fitted.height * 0.25)) < 0.001)
    }

    @Test("A recording with no size has nowhere to put the pointer")
    func pointerSampleNeedsASize() {
        #expect(StudioZoomTargetGeometry.point(
            forPixel: .zero,
            in: .zero,
            fitted: fitted
        ) == nil)
    }
}
