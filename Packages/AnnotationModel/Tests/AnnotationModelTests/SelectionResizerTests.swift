import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

@Suite("Selection resize")
struct SelectionResizerTests {
    private func shape(
        at origin: CGPoint = CGPoint(x: 100, y: 100),
        size: CGSize = CGSize(width: 80, height: 40)
    ) -> AnnotationCommand {
        .shape(ShapeSpec(
            rect: CGRect(origin: origin, size: size),
            stroke: StrokeStyle(width: 0),
            fill: FillStyle(color: .white)
        ))
    }

    // MARK: - Anchors

    @Test("A shape offers eight box anchors and four rotate handles")
    func boxHasEightHandles() {
        let handles = SelectionResizer.anchors(for: [shape()]).map(\.0)
        #expect(handles.filter(\.isCorner).count == 4)
        #expect(handles.filter {
            if case .rotate = $0 {
                true
            } else {
                false
            }
        }.count == 4)
        #expect(handles.count == 12)
    }

    @Test("A lone arrow offers start, middle and end, not a box")
    func arrowUsesPathHandles() {
        let arrow = AnnotationCommand.arrow(ArrowSpec(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 110, y: 10)
        ))
        #expect(SelectionResizer.usesPathHandles([arrow]))
        let handles = SelectionResizer.anchors(for: [arrow]).map(\.0)
        #expect(handles == [.pathStart, .pathMiddle, .pathEnd])
    }

    @Test("Two selected arrows share a box, not two sets of path handles")
    func multiSelectUsesABox() {
        let first = AnnotationCommand.arrow(ArrowSpec(start: .zero, end: CGPoint(x: 40, y: 0)))
        let second = AnnotationCommand.arrow(ArrowSpec(
            start: CGPoint(x: 80, y: 80),
            end: CGPoint(x: 120, y: 80)
        ))
        #expect(!SelectionResizer.usesPathHandles([first, second]))
        #expect(SelectionResizer.anchors(for: [first, second]).count == 8)
    }

    @Test("The pointer has to be on a handle, not merely near the shape")
    func missIsNil() {
        let command = shape()
        let hit = SelectionResizer.handle(
            at: CGPoint(x: 140, y: 120),
            in: [command],
            tolerance: 10
        )
        #expect(hit == nil)
    }

    @Test("A corner grab is recognized")
    func cornerHit() {
        let command = shape()
        let box = SelectionResizer.unionBounds(of: [command])
        let hit = SelectionResizer.handle(at: CGPoint(x: box.maxX, y: box.maxY), in: [command], tolerance: 10)
        #expect(hit == .box(.bottomTrailing))
    }

    @Test("A rotate handle sits 14 pt outside a corner")
    func rotateHandleHit() {
        let command = shape()
        let box = SelectionResizer.unionBounds(of: [command])
        #expect(SelectionResizer.handle(
            at: CGPoint(x: box.minX - SelectionResizer.rotateOffset, y: box.minY - SelectionResizer.rotateOffset),
            in: [command],
            tolerance: 10
        ) == .rotate)
    }

    @Test("Counters have no resize handles; size comes from the inspector")
    func counterIsMoveOnly() {
        let badge = AnnotationCommand.counter(CounterSpec(center: CGPoint(x: 50, y: 50), radius: 20))
        #expect(SelectionResizer.isMoveOnly([badge]))
        #expect(SelectionResizer.anchors(for: [badge]).isEmpty)
        let pair = [
            badge,
            AnnotationCommand.counter(CounterSpec(center: CGPoint(x: 120, y: 50), radius: 20))
        ]
        #expect(SelectionResizer.isMoveOnly(pair))
        #expect(SelectionResizer.anchors(for: pair).isEmpty)
    }

    @Test("Clicking a counter is a move, including on the old corner of its bounds")
    func counterInteriorIsNotAHandle() {
        let badge = AnnotationCommand.counter(CounterSpec(center: CGPoint(x: 50, y: 50), radius: 20))
        #expect(SelectionResizer.handle(at: CGPoint(x: 50, y: 50), in: [badge], tolerance: 12) == nil)
        #expect(SelectionResizer.handle(at: CGPoint(x: 50, y: 70), in: [badge], tolerance: 12) == nil)
        let box = SelectionResizer.unionBounds(of: [badge])
        #expect(SelectionResizer.handle(at: CGPoint(x: box.maxX, y: box.maxY), in: [badge], tolerance: 10) == nil)
    }

    // MARK: - Box scale

    @Test("Dragging the far corner grows the shape; the origin stays put")
    func oppositeCornerAnchors() {
        let command = shape()
        let old = SelectionResizer.unionBounds(of: [command])
        var new = old
        new.size.width += 40
        new.size.height += 20
        let scaled = SelectionResizer.scaled(command, from: old, to: new, widthOnly: false)
        guard case let .shape(spec) = scaled else {
            Issue.record("expected a shape")
            return
        }
        #expect(abs(spec.rect.minX - 100) < 0.01)
        #expect(abs(spec.rect.minY - 100) < 0.01)
        #expect(abs(spec.rect.width - 120) < 0.5)
        #expect(abs(spec.rect.height - 60) < 0.5)
    }

    @Test("A group scale moves a counter without changing its radius")
    func counterKeepsItsRadiusWhenTheGroupScales() {
        let badge = AnnotationCommand.counter(CounterSpec(
            center: CGPoint(x: 50, y: 50),
            radius: 20
        ))
        let old = SelectionResizer.frame(for: [badge])
        var new = old
        new.size.width *= 2
        let scaled = SelectionResizer.scaled(badge, from: old, to: new, widthOnly: false)
        guard case let .counter(spec) = scaled else {
            Issue.record("expected a counter")
            return
        }
        #expect(abs(spec.radius - 20) < 0.01)
        #expect(spec.center != CGPoint(x: 50, y: 50))
    }

    @Test("A side handle on text changes wrap width, not type size")
    func textSideHandleWraps() {
        var style = TextStyle()
        style.fontSize = 24
        let label = AnnotationCommand.text(TextSpec(
            string: "Hi",
            rect: CGRect(x: 10, y: 10, width: 100, height: 30),
            style: style
        ))
        let old = SelectionResizer.frame(for: [label])
        var new = old
        new.size.width += 50
        let scaled = SelectionResizer.scaled(label, from: old, to: new, widthOnly: true)
        guard case let .text(spec) = scaled else {
            Issue.record("expected text")
            return
        }
        #expect(spec.style.fontSize == 24)
        #expect(spec.rect.width > 100)
    }

    @Test("A corner handle on text scales the type")
    func textCornerScalesType() {
        var style = TextStyle()
        style.fontSize = 20
        let label = AnnotationCommand.text(TextSpec(
            string: "Hi",
            rect: CGRect(x: 0, y: 0, width: 100, height: 40),
            style: style
        ))
        let old = SelectionResizer.frame(for: [label])
        var new = old
        new.size.width *= 2
        new.size.height *= 2
        let scaled = SelectionResizer.scaled(label, from: old, to: new, widthOnly: false)
        guard case let .text(spec) = scaled else {
            Issue.record("expected text")
            return
        }
        #expect(abs(spec.style.fontSize - 40) < 0.5)
    }

    // MARK: - Path

    @Test("Dragging an arrow's end moves that end")
    func arrowEndMoves() {
        let arrow = AnnotationCommand.arrow(ArrowSpec(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 80, y: 0)
        ))
        let moved = SelectionResizer.draggingPath(
            arrow,
            handle: .pathEnd,
            to: CGPoint(x: 120, y: 40),
            constrainFrom: nil
        )
        guard case let .arrow(spec) = moved else {
            Issue.record("expected an arrow")
            return
        }
        #expect(spec.start == CGPoint(x: 0, y: 0))
        #expect(spec.end == CGPoint(x: 120, y: 40))
    }

    @Test("⇧ on an arrow end snaps to 45°")
    func arrowEndSnaps() {
        let arrow = AnnotationCommand.arrow(ArrowSpec(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 80, y: 0)
        ))
        let moved = SelectionResizer.draggingPath(
            arrow,
            handle: .pathEnd,
            to: CGPoint(x: 80, y: 10),
            constrainFrom: CGPoint(x: 0, y: 0)
        )
        guard case let .arrow(spec) = moved else {
            Issue.record("expected an arrow")
            return
        }
        #expect(abs(spec.end.y) < 0.001, "a shallow drag must snap back to horizontal")
    }

    @Test("Dragging the middle of a straight arrow bends it; a tiny drag snaps straight")
    func arrowMiddleBends() {
        let arrow = AnnotationCommand.arrow(ArrowSpec(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 0)
        ))
        let bent = SelectionResizer.draggingPath(
            arrow,
            handle: .pathMiddle,
            to: CGPoint(x: 50, y: 30),
            constrainFrom: nil
        )
        guard case let .arrow(curved) = bent else {
            Issue.record("expected an arrow")
            return
        }
        #expect(curved.controlPoint == QuadraticCurve.control(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 0),
            apex: CGPoint(x: 50, y: 30)
        ))

        let straight = SelectionResizer.draggingPath(
            bent,
            handle: .pathMiddle,
            to: CGPoint(x: 50, y: 1),
            constrainFrom: nil
        )
        guard case let .arrow(spec) = straight else {
            Issue.record("expected an arrow")
            return
        }
        #expect(spec.controlPoint == nil)
    }
}
