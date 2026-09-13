import CoreGraphics
import Testing
@testable import AnnotationModel

@Suite("Canvas orientation")
struct CanvasOrientationTests {
    private let size = CGSize(width: 200, height: 100)

    @Test("A 90° turn swaps the axes")
    func quarterTurnSwapsSize() {
        #expect(CanvasOrientation(quarterTurnsCW: 1).orientedSize(of: size) == CGSize(width: 100, height: 200))
        #expect(CanvasOrientation(quarterTurnsCW: 2).orientedSize(of: size) == size)
        #expect(CanvasOrientation(quarterTurnsCW: 3).orientedSize(of: size) == CGSize(width: 100, height: 200))
    }

    @Test("Apply then unapply restores every corner")
    func applyUnapplyRoundTrip() {
        let points = [
            CGPoint.zero,
            CGPoint(x: 200, y: 0),
            CGPoint(x: 0, y: 100),
            CGPoint(x: 200, y: 100),
            CGPoint(x: 80, y: 40)
        ]
        for turns in 0 ..< 4 {
            for flipped in [false, true] {
                let orientation = CanvasOrientation(quarterTurnsCW: turns, isFlippedHorizontally: flipped)
                for point in points {
                    let mapped = orientation.unapply(orientation.apply(point, unoriented: size), unoriented: size)
                    #expect(abs(mapped.x - point.x) < 0.001)
                    #expect(abs(mapped.y - point.y) < 0.001)
                }
            }
        }
    }

    @Test("The top-left corner of a landscape capture lands on the top-right after 90° CW")
    func topLeftMapsToTopRight() {
        let oriented = CanvasOrientation(quarterTurnsCW: 1).apply(.zero, unoriented: size)
        #expect(oriented == CGPoint(x: 100, y: 0))
    }

    @Test("Four clockwise turns return to identity")
    func fourTurnsAreIdentity() {
        var orientation = CanvasOrientation.identity
        for _ in 0 ..< 4 {
            orientation = orientation.rotatedClockwise()
        }
        #expect(orientation.isIdentity)
    }

    @Test("Two horizontal flips cancel")
    func twoFlipsCancel() {
        let flipped = CanvasOrientation.identity.flippedHorizontally().flippedHorizontally()
        #expect(flipped.isIdentity)
    }

    @Test("Two vertical flips cancel")
    func twoVerticalFlipsCancel() {
        let flipped = CanvasOrientation.identity.flippedVertically().flippedVertically()
        #expect(flipped.isIdentity)
    }

    @Test("A vertical flip then a horizontal flip is a half turn")
    func verticalThenHorizontalIsHalfTurn() {
        let orientation = CanvasOrientation.identity.flippedVertically().flippedHorizontally()
        #expect(orientation.quarterTurnsCW == 2)
        #expect(!orientation.isFlippedHorizontally)
    }

    @Test("A visual vertical flip of a side-on canvas is just a horizontal flip of the original")
    func verticalFlipOnSideCanvas() {
        let orientation = CanvasOrientation(quarterTurnsCW: 1).flippedVertically()
        #expect(orientation.quarterTurnsCW == 1)
        #expect(orientation.isFlippedHorizontally)
    }
}
