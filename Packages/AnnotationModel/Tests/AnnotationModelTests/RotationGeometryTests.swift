import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// One pivot for every rotated annotation, and a selection that turns with it
/// (docs/16 ED-10).
@Suite("Rotation geometry")
struct RotationGeometryTests {
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 80)

    private func shape(_ radians: CGFloat) -> AnnotationCommand {
        .shape(ShapeSpec(rect: rect, stroke: StrokeStyle(width: 4), rotation: radians))
    }

    private func close(_ lhs: CGPoint, _ rhs: CGPoint, within tolerance: CGFloat = 0.01) -> Bool {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y) <= tolerance
    }

    @Test("Every rotatable annotation turns about the centre of its own extent", arguments: [
        AnnotationCommand.shape(ShapeSpec(rect: CGRect(x: 10, y: 20, width: 100, height: 40), rotation: 0.5)),
        .text(TextSpec(string: "Hi", rect: CGRect(x: 10, y: 20, width: 100, height: 40), rotation: 0.5)),
        .redaction(RedactionSpec(rect: CGRect(x: 10, y: 20, width: 100, height: 40), rotation: 0.5)),
        .spotlight(SpotlightSpec(rect: CGRect(x: 10, y: 20, width: 100, height: 40), rotation: 0.5)),
        .freehand(FreehandSpec(points: [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 60)], rotation: 0.5))
    ])
    func pivotIsTheCentre(command: AnnotationCommand) {
        let box = AnnotationHitTesting.unrotatedBounds(of: command)
        #expect(close(AnnotationHitTesting.rotationPivot(of: command), CGPoint(x: box.midX, y: box.midY)))
        #expect(close(AnnotationHitTesting.rotationPivot(of: command), CGPoint(x: 60, y: 40)))
    }

    @Test("rotate and inverse undo each other", arguments: [0.3, -1.2, .pi / 2, .pi])
    func rotateRoundTrips(radians: CGFloat) {
        let centre = CGPoint(x: 40, y: 70)
        let point = CGPoint(x: 123, y: -9)
        let turned = AnnotationRotation.rotate(point, around: centre, radians: radians)
        #expect(close(AnnotationRotation.inverse(turned, around: centre, radians: radians), point))
        let viaTransform = point.applying(AnnotationRotation.transform(radians: radians, around: centre))
        #expect(close(viaTransform, turned))
    }

    @Test("An unrotated or multiple selection keeps the axis-aligned frame")
    func orientedOnlyForOneRotated() {
        #expect(OrientedSelection([shape(0)]) == nil)
        #expect(OrientedSelection([shape(0.4), shape(0.4)]) == nil)
        #expect(OrientedSelection([shape(0.4)]) != nil)
    }

    @Test("The handles of a rotated shape sit on its turned corners and sides", arguments: [0.4, .pi / 2, -2.2])
    func handlesFollowTheShape(radians: CGFloat) throws {
        let command = shape(radians)
        let oriented = try #require(OrientedSelection([command]))
        let anchors = SelectionResizer.anchors(for: [command])
        let box = AnnotationHitTesting.unrotatedBounds(of: command)
        let pivot = AnnotationHitTesting.rotationPivot(of: command)
        for (handle, point) in anchors {
            guard case let .box(crop) = handle else { continue }
            let expected = AnnotationRotation.rotate(crop.point(in: box), around: pivot, radians: radians)
            #expect(close(point, expected))
            // …and a handle hit-tests as part of the shape's own outline, not empty space.
            #expect(close(oriented.local(point), crop.point(in: box)))
        }
        #expect(anchors.contains { $0.0.isRotate })
        let outline = SelectionResizer.outline(for: [command]).boundingBoxOfPath
        let expectedOutline = AnnotationRotation.aabb(
            box.insetBy(dx: -SelectionResizer.framePadding, dy: -SelectionResizer.framePadding),
            radians: radians
        )
        #expect(abs(outline.minX - expectedOutline.minX) < 0.01)
        #expect(abs(outline.maxY - expectedOutline.maxY) < 0.01)
    }

    @Test("Resizing a rotated shape grows it along its own axis and holds the opposite side")
    func resizeInLocalSpace() throws {
        let radians = CGFloat.pi / 2
        let command = shape(radians)
        let oriented = try #require(OrientedSelection([command]))
        let box = oriented.box
        // The trailing handle, dragged 50 points further along the shape's own x axis.
        let handleWorld = oriented.world(CropHandle.trailing.point(in: box))
        let direction = oriented.world(CGPoint(x: box.midX + 1, y: box.midY))
        let axis = CGVector(dx: direction.x - oriented.center.x, dy: direction.y - oriented.center.y)
        let target = CGPoint(x: handleWorld.x + axis.dx * 50, y: handleWorld.y + axis.dy * 50)

        let resized = oriented.resized(
            command,
            by: OrientedSelection.Drag(handle: .trailing, from: handleWorld, to: target)
        )
        guard case let .shape(spec) = resized else {
            Issue.record("not a shape")
            return
        }
        // Scaled the way an unrotated resize scales: by the stroke-inclusive box.
        #expect(abs(spec.rect.width - rect.width * (box.width + 50) / box.width) < 0.01)
        #expect(abs(spec.rect.height - rect.height) < 0.5)
        #expect(spec.rotation == radians)

        // The leading side is where it was on the canvas.
        let before = oriented.world(CropHandle.leading.point(in: box))
        let after = try #require(OrientedSelection([resized]))
        let leadingAfter = after.world(CropHandle.leading.point(in: after.box))
        #expect(close(before, leadingAfter, within: 0.5))
        // And the dragged side followed the pointer.
        let trailingAfter = after.world(CropHandle.trailing.point(in: after.box))
        #expect(close(trailingAfter, target, within: 0.5))
    }

    @Test("A rotated spotlight's hole is turned with it")
    func spotlightHoleTurns() throws {
        let spotlight = AnnotationCommand.spotlight(SpotlightSpec(rect: rect, cornerRadius: 0, rotation: .pi / 2))
        let composite = try #require(SpotlightComposite.from(commands: [spotlight]))
        let hole = try #require(composite.holes.first).path().boundingBoxOfPath
        let expected = AnnotationRotation.aabb(rect, radians: .pi / 2)
        #expect(abs(hole.width - expected.width) < 0.01)
        #expect(abs(hole.height - expected.height) < 0.01)
        #expect(abs(hole.midX - rect.midX) < 0.01)
    }
}
