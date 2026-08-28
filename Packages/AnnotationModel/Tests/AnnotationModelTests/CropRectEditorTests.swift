import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// Dragging a crop rectangle (docs/03 §3, docs/09 U1.8).
///
/// The rules here — which edge moves, what happens at the minimum, how an aspect lock
/// pivots — are all checkable without a window, which is why they live apart from the view.
@Suite("Crop rect editor")
struct CropRectEditorTests {
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    // MARK: - Grabbing

    @Test("Each handle is where it says it is")
    func handlePositions() {
        #expect(CropHandle.topLeading.point(in: rect) == CGPoint(x: 100, y: 100))
        #expect(CropHandle.bottomTrailing.point(in: rect) == CGPoint(x: 300, y: 220))
        #expect(CropHandle.top.point(in: rect) == CGPoint(x: 200, y: 100))
        #expect(CropHandle.body.point(in: rect) == CGPoint(x: 200, y: 160))
    }

    /// At a corner the corner, an edge and the body are all under the pointer; the corner
    /// is the one being aimed at.
    @Test("A corner wins over the edges that meet there")
    func cornerBeatsEdge() {
        #expect(CropRectEditor.handle(at: CGPoint(x: 100, y: 100), in: rect) == .topLeading)
        #expect(CropRectEditor.handle(at: CGPoint(x: 300, y: 220), in: rect) == .bottomTrailing)
    }

    @Test("An edge is grabbed away from the corners")
    func edgeHandles() {
        #expect(CropRectEditor.handle(at: CGPoint(x: 200, y: 100), in: rect) == .top)
        #expect(CropRectEditor.handle(at: CGPoint(x: 100, y: 160), in: rect) == .leading)
    }

    @Test("The middle is the body, and outside is nothing")
    func bodyAndOutside() {
        #expect(CropRectEditor.handle(at: CGPoint(x: 200, y: 160), in: rect) == .body)
        #expect(CropRectEditor.handle(at: CGPoint(x: 500, y: 500), in: rect) == nil)
    }

    // MARK: - Free resizing

    @Test("A corner drag moves two edges and leaves the other two")
    func cornerDrag() {
        let resized = CropRectEditor.resized(
            rect,
            handle: .bottomTrailing,
            translation: CGSize(width: 50, height: 30)
        )
        #expect(resized.minX == rect.minX, "the far edges should not move")
        #expect(resized.minY == rect.minY)
        #expect(resized.maxX == rect.maxX + 50)
        #expect(resized.maxY == rect.maxY + 30)
    }

    @Test("An edge drag moves one edge only")
    func edgeDrag() {
        let resized = CropRectEditor.resized(rect, handle: .leading, translation: CGSize(width: 40, height: 99))
        #expect(resized.minX == rect.minX + 40)
        #expect(resized.maxX == rect.maxX)
        #expect(resized.minY == rect.minY, "a leading drag must not move the top")
        #expect(resized.height == rect.height)
    }

    @Test("The body drag moves the whole rect without resizing it")
    func bodyDrag() {
        let moved = CropRectEditor.resized(rect, handle: .body, translation: CGSize(width: 25, height: -15))
        #expect(moved.size == rect.size)
        #expect(moved.origin == CGPoint(x: 125, y: 85))
    }

    /// Dragging an edge past its opposite flips the rect rather than inverting it, which
    /// is what every crop tool does and what a negative width would not survive.
    @Test("Dragging an edge past its opposite flips rather than inverts")
    func draggingPastTheOpposite() {
        let flipped = CropRectEditor.resized(
            rect,
            handle: .leading,
            translation: CGSize(width: 400, height: 0)
        )
        #expect(flipped.width > 0)
        #expect(flipped.height > 0)
    }

    @Test("A rect cannot be dragged smaller than the minimum")
    func minimumSize() {
        let tiny = CropRectEditor.resized(
            rect,
            handle: .bottomTrailing,
            translation: CGSize(width: -1000, height: -1000)
        )
        #expect(tiny.width >= CropRectEditor.minimumSize)
        #expect(tiny.height >= CropRectEditor.minimumSize)
    }

    /// At the minimum the edge that is *not* being dragged has to stay put, or the rect
    /// walks across the image as the user keeps pulling.
    @Test("At the minimum, the fixed edge stays fixed")
    func minimumKeepsTheFixedEdge() {
        // Just past the point where the rect hits its minimum, but not past the far edge —
        // beyond that the rect flips, which is a different behaviour tested below.
        let tiny = CropRectEditor.resized(
            rect,
            handle: .topLeading,
            translation: CGSize(width: 195, height: 115)
        )
        #expect(tiny.width == CropRectEditor.minimumSize)
        #expect(abs(tiny.maxX - rect.maxX) < 0.001)
        #expect(abs(tiny.maxY - rect.maxY) < 0.001)
    }

    /// Dragged all the way past the far edge, the rect flips around it — the edge the user
    /// was not holding stays where it was and becomes the other side of the rect.
    @Test("A flipped rect keeps the edge it pivoted about")
    func flipKeepsThePivotEdge() {
        let flipped = CropRectEditor.resized(
            rect,
            handle: .topLeading,
            translation: CGSize(width: 1000, height: 1000)
        )
        #expect(abs(flipped.minX - rect.maxX) < 0.001, "the old right edge is now the left one")
        #expect(abs(flipped.minY - rect.maxY) < 0.001)
        #expect(flipped.width > 0)
    }

    // MARK: - Aspect lock

    @Test("A locked drag holds its ratio", arguments: [CGFloat(1), CGFloat(16) / 9, CGFloat(4) / 5])
    func aspectIsHeld(aspect: CGFloat) {
        let resized = CropRectEditor.resized(
            rect,
            handle: .bottomTrailing,
            translation: CGSize(width: 90, height: 10),
            aspect: aspect
        )
        #expect(abs(resized.width / resized.height - aspect) < 0.001)
    }

    /// The corner under the pointer follows it and nothing else moves. Pivoting on the
    /// centre instead makes the rect appear to slide away from the pointer.
    @Test("A locked corner drag pivots on the opposite corner", arguments: [
        CropHandle.topLeading, .topTrailing, .bottomLeading, .bottomTrailing
    ])
    func lockedDragPivotsOnTheOppositeCorner(handle: CropHandle) throws {
        let opposite = try #require(handle.oppositeCorner)
        let before = opposite.point(in: rect)

        let resized = CropRectEditor.resized(
            rect,
            handle: handle,
            translation: CGSize(width: 40, height: 40),
            aspect: 1
        )
        let after = opposite.point(in: resized)
        #expect(abs(after.x - before.x) < 0.001, "\(handle) moved its anchor")
        #expect(abs(after.y - before.y) < 0.001)
    }

    @Test("A locked edge drag derives the other dimension")
    func lockedEdgeDrag() {
        let resized = CropRectEditor.resized(
            rect,
            handle: .trailing,
            translation: CGSize(width: 100, height: 0),
            aspect: 2
        )
        #expect(abs(resized.width - 300) < 0.001)
        #expect(abs(resized.height - 150) < 0.001)
    }

    @Test("A locked rect never shrinks below the minimum")
    func lockedMinimum() {
        let tiny = CropRectEditor.resized(
            rect,
            handle: .bottomTrailing,
            translation: CGSize(width: -1000, height: -1000),
            aspect: 1
        )
        #expect(tiny.width >= CropRectEditor.minimumSize)
        #expect(tiny.height >= CropRectEditor.minimumSize)
    }

    // MARK: - Bounds

    @Test("A bounded drag stops at the edge of the image")
    func boundedResize() {
        let resized = CropRectEditor.resized(
            rect,
            handle: .bottomTrailing,
            translation: CGSize(width: 5000, height: 5000),
            bounds: bounds
        )
        #expect(bounds.contains(resized))
        #expect(resized.maxX == bounds.maxX)
    }

    @Test("A bounded move slides back in rather than sticking")
    func boundedMove() {
        let moved = CropRectEditor.resized(
            rect,
            handle: .body,
            translation: CGSize(width: -5000, height: 0),
            bounds: bounds
        )
        #expect(moved.minX == bounds.minX)
        #expect(moved.size == rect.size, "a move must not resize")
    }

    /// Expand-canvas is the absence of bounds, so the rect is allowed off the image.
    @Test("With no bounds the rect may leave the image")
    func unboundedResize() {
        let resized = CropRectEditor.resized(
            rect,
            handle: .topLeading,
            translation: CGSize(width: -500, height: -500)
        )
        #expect(resized.minX < 0)
        #expect(resized.minY < 0)
    }

    /// Clamping a locked rect must shrink it to fit, not crop it to fit — cropping would
    /// break the ratio the user asked for.
    @Test("A bounded locked drag keeps its ratio")
    func boundedLockedDrag() {
        let resized = CropRectEditor.resized(
            CGRect(x: 700, y: 500, width: 80, height: 80),
            handle: .bottomTrailing,
            translation: CGSize(width: 500, height: 500),
            aspect: 1,
            bounds: bounds
        )
        #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(resized))
        #expect(abs(resized.width - resized.height) < 0.5, "\(resized) is no longer square")
    }

    // MARK: - Presets

    @Test("Every preset gives a ratio except free")
    func presetRatios() {
        let original = CGSize(width: 1600, height: 900)
        for preset in CropAspectPreset.allCases {
            let ratio = preset.ratio(original: original)
            if preset == .free {
                #expect(ratio == nil)
            } else {
                #expect((ratio ?? 0) > 0, "\(preset) has no ratio")
            }
        }
    }

    @Test("The original preset follows the capture")
    func originalPreset() {
        #expect(CropAspectPreset.original.ratio(original: CGSize(width: 1600, height: 900)) == 16.0 / 9)
        #expect(CropAspectPreset.original.ratio(original: .zero) == nil)
    }

    @Test("Handles know which edges they move")
    func handleEdges() {
        #expect(CropHandle.topLeading.moves(.top))
        #expect(CropHandle.topLeading.moves(.leading))
        #expect(!CropHandle.topLeading.moves(.bottom))
        #expect(!CropHandle.body.moves(.top))
    }

    @Test("Only corners have an opposite")
    func opposites() {
        #expect(CropHandle.topLeading.oppositeCorner == .bottomTrailing)
        #expect(CropHandle.top.oppositeCorner == nil)
        #expect(CropHandle.body.isCorner == false)
    }
}
