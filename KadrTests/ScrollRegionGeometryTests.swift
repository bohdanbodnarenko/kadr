import CoreGraphics
import Testing
@testable import Kadr

/// The scrolling-capture frame: what a press grabs and what a drag does (docs/03 §1.6).
@Suite("Scroll region frame")
struct ScrollRegionGeometryTests {
    typealias Geometry = ScrollRegionGeometry
    private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("Presses find the right handle, and the inside passes through", arguments: [
        (CGPoint(x: 100, y: 100), Geometry.Target?.some(.resize(.left, .bottom))),
        (CGPoint(x: 503, y: 397), .resize(.right, .top)),
        (CGPoint(x: 98, y: 250), .resize(.left, nil)),
        (CGPoint(x: 502, y: 250), .resize(.right, nil)),
        (CGPoint(x: 250, y: 102), .resize(nil, .bottom)),
        (CGPoint(x: 200, y: 399), .resize(nil, .top)),
        // The move bar sits just above the frame's top edge, across its whole width.
        (CGPoint(x: 300, y: 412), .move),
        (CGPoint(x: 140, y: 412), .move),
        (CGPoint(x: 300, y: 250), nil),
        (CGPoint(x: 700, y: 700), nil)
    ])
    func hitTesting(point: CGPoint, expected: Geometry.Target?) {
        #expect(Geometry.target(at: point, in: rect, bounds: bounds) == expected)
    }

    @Test("Every handle is inside an interactive rect, and the middle is not")
    func interactiveRects() {
        let rects = Geometry.interactiveRects(for: rect, in: bounds)
        for centre in Geometry.handleCentres(for: rect) {
            #expect(rects.contains { $0.contains(centre) })
        }
        #expect(!rects.contains { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) })
    }

    @Test("Dragging resizes the grabbed sides only", arguments: [
        (
            Geometry.Target.resize(.right, nil),
            CGVector(dx: 50, dy: 30),
            CGRect(x: 100, y: 100, width: 450, height: 300)
        ),
        (.resize(.left, .top), CGVector(dx: -20, dy: 40), CGRect(x: 80, y: 100, width: 420, height: 340)),
        (.resize(nil, .bottom), CGVector(dx: 99, dy: -60), CGRect(x: 100, y: 40, width: 400, height: 360)),
        (.move, CGVector(dx: 10, dy: -10), CGRect(x: 110, y: 90, width: 400, height: 300))
    ])
    func dragging(target: Geometry.Target, delta: CGVector, expected: CGRect) {
        #expect(Geometry.dragged(rect, target: target, by: delta, in: bounds) == expected)
    }

    @Test("A frame never leaves the screen or turns inside out")
    func limits() {
        let moved = Geometry.dragged(rect, target: .move, by: CGVector(dx: -500, dy: 2000), in: bounds)
        #expect(bounds.contains(moved))
        #expect(moved.size == rect.size)

        let crushed = Geometry.dragged(rect, target: .resize(.left, nil), by: CGVector(dx: 1000, dy: 0), in: bounds)
        #expect(crushed.width == Geometry.minimumSize.width)
        #expect(crushed.maxX == rect.maxX)

        let stretched = Geometry.dragged(
            rect,
            target: .resize(.right, .top),
            by: CGVector(dx: 5000, dy: 5000),
            in: bounds
        )
        #expect(stretched.maxX == bounds.maxX)
        #expect(stretched.maxY == bounds.maxY)
    }

    @Test("It opens on the window under the pointer, or a centerd area")
    func initialRect() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let window = CGRect(x: 200, y: 100, width: 800, height: 600)
        // Small enough to grab already, so it is used as it is, centred where it was.
        #expect(Geometry.initialRect(window: window, visible: visible) == window)

        let hanging = CGRect(x: 1200, y: 700, width: 800, height: 600)
        let clipped = Geometry.initialRect(window: hanging, visible: visible)
        #expect(visible.contains(clipped))
        #expect(clipped.width >= Geometry.minimumSize.width)

        let fallback = Geometry.initialRect(window: nil, visible: visible)
        #expect(visible.contains(fallback))
        #expect(abs(fallback.midX - visible.midX) <= 1)

        let tiny = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(Geometry.initialRect(window: tiny, visible: visible) == fallback)
    }

    /// A frame with its edges against the screen's has nothing to grab: the corner handle
    /// is under the Dock, and moving it means resizing it smaller first.
    @Test("A maximised window does not open a frame the size of the screen")
    func maximisedWindowIsCappedAndGrabbable() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let maximised = visible

        let frame = Geometry.initialRect(window: maximised, visible: visible)

        #expect(frame.width < visible.width)
        #expect(frame.height < visible.height)
        #expect(visible.contains(frame))
        // Room on every side for the bands that resize it.
        #expect(frame.minX - visible.minX >= Geometry.cornerReach)
        #expect(visible.maxY - frame.maxY >= Geometry.cornerReach)
        #expect(abs(frame.midX - visible.midX) <= 1)
    }

    @Test("The move bar sits above the frame, and inside it at the top of the screen")
    func moveBarFlipsInside() {
        let bar = Geometry.moveBar(for: rect, in: bounds)
        #expect(bar.minY >= rect.maxY)
        #expect(bar.width == rect.width)
        #expect(bar.height == Geometry.moveBarHeight)

        let atTheTop = CGRect(x: 100, y: bounds.maxY - 300, width: 400, height: 300)
        let flipped = Geometry.moveBar(for: atTheTop, in: bounds)
        #expect(bounds.contains(flipped))
        #expect(flipped.maxY <= atTheTop.maxY)
    }

    @Test("A remembered frame is only restored while it still fits")
    func remembersOnlyWhatFits() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        #expect(Geometry.fits(CGRect(x: 40, y: 60, width: 600, height: 400), in: visible))
        // From a monitor that is no longer there.
        #expect(!Geometry.fits(CGRect(x: 2000, y: 60, width: 600, height: 400), in: visible))
        // Smaller than the frame is allowed to be.
        #expect(!Geometry.fits(CGRect(x: 40, y: 60, width: 20, height: 20), in: visible))
    }
}
