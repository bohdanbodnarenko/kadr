import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// Arrows that follow what they point at (docs/09 U1.7).
///
/// The trim math is tested as a property rather than case by case: "the endpoint is on the
/// target's boundary, and on the segment" holds for every geometry, and enumerating
/// examples would test the ones I happened to think of.
@Suite("Arrow bindings")
struct ArrowBindingTests {
    private let box = CGRect(x: 100, y: 100, width: 120, height: 80)

    private func shape(_ rect: CGRect, kind: ShapeKind = .rectangle) -> AnnotationCommand {
        .shape(ShapeSpec(kind: kind, rect: rect))
    }

    private func arrow(
        from start: CGPoint,
        to end: CGPoint,
        endBoundTo target: AnnotationID? = nil,
        anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> ArrowSpec {
        ArrowSpec(
            start: start,
            end: end,
            endBinding: target.map { ArrowBinding(targetID: $0, anchor: anchor) }
        )
    }

    // MARK: - Anchors

    @Test("An anchor is a fraction of the target's own box")
    func anchorIsNormalized() {
        let binding = ArrowBinding(targetID: AnnotationID(), anchor: CGPoint(x: 0.5, y: 0))
        #expect(binding.point(in: box) == CGPoint(x: 160, y: 100))
    }

    /// The reason anchors are normalized rather than offsets: a resize must not detach the
    /// arrow from the part of the shape it was pointing at.
    @Test("An anchor survives the target being resized")
    func anchorSurvivesResize() {
        let binding = ArrowBinding(targetID: AnnotationID(), anchor: CGPoint(x: 1, y: 0.5))
        #expect(binding.point(in: box) == CGPoint(x: 220, y: 140))

        let bigger = CGRect(x: 100, y: 100, width: 400, height: 200)
        #expect(binding.point(in: bigger) == CGPoint(x: 500, y: 200), "still the right edge, mid-height")
    }

    @Test("A point maps back to the anchor it came from", arguments: [
        CGPoint(x: 100, y: 100),
        CGPoint(x: 160, y: 140),
        CGPoint(x: 220, y: 180)
    ])
    func anchorRoundTrips(point: CGPoint) {
        let anchor = ArrowBinding.anchor(for: point, in: box)
        let binding = ArrowBinding(targetID: AnnotationID(), anchor: anchor)
        let back = binding.point(in: box)
        #expect(abs(back.x - point.x) < 0.001)
        #expect(abs(back.y - point.y) < 0.001)
    }

    @Test("A zero-sized target does not divide by zero")
    func zeroSizedTarget() {
        #expect(ArrowBinding.anchor(for: .zero, in: .zero) == CGPoint(x: 0.5, y: 0.5))
    }

    // MARK: - Following

    @Test("A bound arrow follows its target when it moves")
    func followsAMove() {
        let target = shape(box)
        let spec = arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 160, y: 140), endBoundTo: target.id)

        let before = ArrowBindingResolver.resolved(spec, in: [target, .arrow(spec)])
        let moved = shape(box.offsetBy(dx: 200, dy: 0))
        var movedTarget = moved
        if case var .shape(shapeSpec) = movedTarget {
            shapeSpec.id = target.id
            movedTarget = .shape(shapeSpec)
        }
        let after = ArrowBindingResolver.resolved(spec, in: [movedTarget, .arrow(spec)])

        #expect(after.end.x > before.end.x + 150, "the arrow should have followed")
    }

    @Test("An unbound arrow is returned untouched")
    func unboundIsUntouched() {
        let spec = arrow(from: .zero, to: CGPoint(x: 50, y: 50))
        #expect(ArrowBindingResolver.resolved(spec, in: []) == spec)
    }

    @Test("An arrow whose target has gone keeps its last position")
    func missingTargetKeepsPosition() {
        let spec = arrow(from: .zero, to: CGPoint(x: 50, y: 50), endBoundTo: AnnotationID())
        let resolved = ArrowBindingResolver.resolved(spec, in: [])
        #expect(resolved.end == CGPoint(x: 50, y: 50))
    }

    /// Both ends resolve against the *stored* geometry, so the result does not depend on
    /// which end was computed first.
    @Test("Two bound ends do not depend on each other")
    func bothEndsAreIndependent() {
        let first = shape(CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = shape(CGRect(x: 300, y: 300, width: 40, height: 40))
        let spec = ArrowSpec(
            start: CGPoint(x: 20, y: 20),
            end: CGPoint(x: 320, y: 320),
            startBinding: ArrowBinding(targetID: first.id),
            endBinding: ArrowBinding(targetID: second.id)
        )
        let resolved = ArrowBindingResolver.resolved(spec, in: [first, second, .arrow(spec)])

        #expect(resolved.start.x > 20, "the start should be trimmed to its own shape's edge")
        #expect(resolved.end.x < 320, "and the end to its own")
    }

    // MARK: - Trimming, as a property

    /// The endpoint is on the target's boundary and on the segment. Every geometry, not a
    /// chosen handful.
    @Test("A trimmed endpoint lands on the target's edge", arguments: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 400, y: 0),
        CGPoint(x: 400, y: 400),
        CGPoint(x: 0, y: 400),
        CGPoint(x: 160, y: 0),
        CGPoint(x: 160, y: 400),
        CGPoint(x: 0, y: 140),
        CGPoint(x: 400, y: 140)
    ])
    func trimmedEndpointIsOnTheEdge(from other: CGPoint) throws {
        let crossing = try #require(ArrowBindingResolver.rectCrossing(
            from: other,
            to: CGPoint(x: box.midX, y: box.midY),
            in: box
        ))

        // On the boundary: one coordinate is on an edge, and the point is within the box.
        let onEdge = abs(crossing.x - box.minX) < 0.001 || abs(crossing.x - box.maxX) < 0.001
            || abs(crossing.y - box.minY) < 0.001 || abs(crossing.y - box.maxY) < 0.001
        #expect(onEdge, "\(crossing) is not on the edge of \(box)")
        #expect(box.insetBy(dx: -0.001, dy: -0.001).contains(crossing))

        // And on the segment between the two points.
        let distance = AnnotationHitTesting.distanceToSegment(
            crossing,
            from: other,
            to: CGPoint(x: box.midX, y: box.midY)
        )
        #expect(distance < 0.001, "\(crossing) is not on the segment")
    }

    /// It stops at the *near* edge: an arrow crossing a shape to reach an anchor on the far
    /// side should meet the shape where it visually touches it.
    @Test("The arrow stops at the near edge, not the far one")
    func stopsAtTheNearEdge() throws {
        let crossing = try #require(ArrowBindingResolver.rectCrossing(
            from: CGPoint(x: 0, y: 140),
            to: CGPoint(x: 220, y: 140),
            in: box
        ))
        #expect(abs(crossing.x - box.minX) < 0.001, "expected the left edge, got \(crossing)")
    }

    @Test("An ellipse target is trimmed to its curve, not its box", arguments: [
        CGPoint(x: 0, y: 140),
        CGPoint(x: 400, y: 140),
        CGPoint(x: 160, y: 0),
        CGPoint(x: 0, y: 0)
    ])
    func ellipseTrimming(from other: CGPoint) throws {
        let crossing = try #require(ArrowBindingResolver.ellipseCrossing(
            from: other,
            to: CGPoint(x: box.midX, y: box.midY),
            in: box
        ))

        // On the ellipse: the normalized radius is 1.
        let normalized = hypot(
            (crossing.x - box.midX) / (box.width / 2),
            (crossing.y - box.midY) / (box.height / 2)
        )
        #expect(abs(normalized - 1) < 0.001, "\(crossing) is not on the ellipse")
    }

    @Test("A diagonal approach to a corner still lands on the boundary")
    func cornerApproach() throws {
        let crossing = try #require(ArrowBindingResolver.rectCrossing(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 220, y: 180),
            in: box
        ))
        #expect(box.insetBy(dx: -0.001, dy: -0.001).contains(crossing))
    }

    /// An arrow drawn from inside the shape has no edge to stop at; the head goes to the
    /// anchor rather than to a crossing behind it.
    ///
    /// Measured against the shape's *drawn* box, which includes half its stroke — an arrow
    /// should meet the line the user can see, not the geometric rect underneath it.
    @Test("An arrow starting inside the target aims at the anchor")
    func insideTheTarget() {
        let target = shape(box)
        let drawn = AnnotationHitTesting.boundingBox(of: target)
        let endpoint = ArrowBindingResolver.endpoint(
            ArrowBinding(targetID: target.id, anchor: CGPoint(x: 1, y: 0.5)),
            target: target,
            aimingFrom: CGPoint(x: drawn.midX, y: drawn.midY)
        )
        #expect(endpoint == CGPoint(x: drawn.maxX, y: drawn.midY))
    }

    @Test("A degenerate segment does not crash the trim")
    func degenerateSegment() {
        #expect(ArrowBindingResolver.rectCrossing(
            from: CGPoint(x: 160, y: 140),
            to: CGPoint(x: 160, y: 140),
            in: box
        ) == nil)
    }

    // MARK: - Document behaviour

    private func makeDocument(_ commands: [AnnotationCommand]) -> AnnotationDocument {
        AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2),
            commands: commands
        )
    }

    @Test("Deleting the target unbinds the arrow and leaves it where it was")
    func deletingTargetUnbinds() {
        let target = shape(box)
        let spec = arrow(from: CGPoint(x: 0, y: 140), to: CGPoint(x: 160, y: 140), endBoundTo: target.id)
        var document = makeDocument([target, .arrow(spec)])

        let drawnBefore = ArrowBindingResolver.resolved(spec, in: document.commands).end
        document.remove([target.id])

        guard case let .arrow(after) = document.commands[0] else {
            Issue.record("the arrow should have survived")
            return
        }
        #expect(after.endBinding == nil, "the binding should be gone with its target")
        #expect(abs(after.end.x - drawnBefore.x) < 0.001, "and the arrow should not have jumped")
    }

    @Test("Deleting something else leaves the binding alone")
    func deletingSomethingElse() {
        let target = shape(box)
        let bystander = shape(CGRect(x: 400, y: 400, width: 20, height: 20))
        let spec = arrow(from: .zero, to: CGPoint(x: 160, y: 140), endBoundTo: target.id)
        var document = makeDocument([target, bystander, .arrow(spec)])

        document.remove([bystander.id])
        #expect(document.commands.contains { $0.hasArrowBinding })
    }

    /// Bindings are by identity, so the z-order of the commands is irrelevant — which is
    /// what makes "bring to front" safe.
    @Test("Reordering the commands does not disturb a binding")
    func reorderingIsSafe() {
        let target = shape(box)
        let spec = arrow(from: CGPoint(x: 0, y: 140), to: CGPoint(x: 160, y: 140), endBoundTo: target.id)

        let forwards = ArrowBindingResolver.resolved(spec, in: [target, .arrow(spec)])
        let backwards = ArrowBindingResolver.resolved(spec, in: [.arrow(spec), target])
        #expect(forwards.end == backwards.end)
    }

    @Test("A binding survives undo and redo")
    func survivesUndoRedo() {
        let target = shape(box)
        var document = makeDocument([target])
        let spec = arrow(from: .zero, to: CGPoint(x: 160, y: 140), endBoundTo: target.id)
        document.add(.arrow(spec))

        document.undo()
        #expect(!document.commands.contains { $0.hasArrowBinding })

        document.redo()
        #expect(document.commands.contains { $0.hasArrowBinding })
    }

    @Test("A binding survives a document round trip")
    func survivesRoundTrip() throws {
        let target = shape(box)
        let spec = arrow(
            from: .zero,
            to: CGPoint(x: 160, y: 140),
            endBoundTo: target.id,
            anchor: CGPoint(x: 0.25, y: 0.75)
        )
        let document = makeDocument([target, .arrow(spec)])

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)

        guard case let .arrow(restored) = decoded.commands[1] else {
            Issue.record("the arrow did not survive")
            return
        }
        #expect(restored.endBinding?.targetID == target.id)
        #expect(restored.endBinding?.anchor == CGPoint(x: 0.25, y: 0.75))
    }

    /// An arrow written before bindings existed has none, and still opens.
    @Test("An older arrow decodes without bindings")
    func olderArrowDecodes() throws {
        let json = """
        {"id": {"rawValue": "6E1F3A5C-0B4D-4A6E-9F2C-8D7E5A1B3C4D"},
         "start": [0, 0], "end": [10, 10]}
        """
        let spec = try JSONDecoder().decode(ArrowSpec.self, from: Data(json.utf8))
        #expect(spec.startBinding == nil)
        #expect(spec.endBinding == nil)
        #expect(spec.head == .filled)
    }

    @Test("Resolved commands leave everything that is not a bound arrow alone")
    func resolvedCommandsAreOtherwiseIdentical() {
        let plain = makeDocument([shape(box), .arrow(arrow(from: .zero, to: CGPoint(x: 5, y: 5)))])
        #expect(plain.resolvedCommands == plain.commands)
    }

    @Test("Resolved commands move the bound arrow")
    func resolvedCommandsMoveTheArrow() {
        let target = shape(box)
        let spec = arrow(from: CGPoint(x: 0, y: 140), to: CGPoint(x: 500, y: 500), endBoundTo: target.id)
        let document = makeDocument([target, .arrow(spec)])

        guard case let .arrow(resolved) = document.resolvedCommands[1] else {
            Issue.record("the arrow should still be an arrow")
            return
        }
        let drawn = AnnotationHitTesting.boundingBox(of: target)
        #expect(resolved.end != spec.end)
        #expect(abs(resolved.end.x - drawn.minX) < 0.001, "trimmed to the near edge")
    }
}
