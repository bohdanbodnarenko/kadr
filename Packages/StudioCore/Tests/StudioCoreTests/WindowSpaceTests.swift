import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

/// Placing a click inside a window that moves (docs/09 U3.1).
///
/// The reason window recordings could not keep a studio session at all: a click's position
/// in the frame cannot be derived from where it landed on screen without knowing what the
/// frame was showing at that instant. All of that is arithmetic, so all of it is tested
/// here rather than by dragging a window about.
@Suite("Window space")
struct WindowSpaceTests {
    private let window = CGRect(x: 100, y: 200, width: 800, height: 600)
    private let pixelSize = CGSize(width: 1600, height: 1200)

    // MARK: - The fixed pixel size

    @Test("The recording's size comes from the window as it was when it started")
    func pixelSizeFromFirstFrame() {
        let size = WindowSpace.pixelSize(ofFirst: window, scale: 2)
        #expect(size == CGSize(width: 1600, height: 1200))
    }

    @Test("A degenerate window still produces a usable size")
    func degenerateWindow() {
        let size = WindowSpace.pixelSize(ofFirst: .zero, scale: 2)
        #expect(size.width >= 1)
        #expect(size.height >= 1)
    }

    // MARK: - Placing a point

    @Test("The window's top-left corner is the frame's origin")
    func originMapsToOrigin() throws {
        let point = try #require(WindowSpace.framePoint(
            for: CGPoint(x: 100, y: 200),
            contentRect: window,
            pixelSize: pixelSize
        ))
        #expect(point == .zero)
    }

    @Test("The middle of the window is the middle of the frame")
    func centreMapsToCentre() throws {
        let point = try #require(WindowSpace.framePoint(
            for: CGPoint(x: 500, y: 500),
            contentRect: window,
            pixelSize: pixelSize
        ))
        #expect(point == CGPoint(x: 800, y: 600))
    }

    @Test("A click outside the window is not recorded")
    func outsideIsRejected() {
        for point in [CGPoint(x: 50, y: 500), CGPoint(x: 1000, y: 500), CGPoint(x: 500, y: 50)] {
            #expect(
                WindowSpace.framePoint(for: point, contentRect: window, pixelSize: pixelSize) == nil,
                "a click at \(point) is not on the window"
            )
        }
    }

    // MARK: - Moving

    /// Dragging the window must not move the click within the frame: the same button, in
    /// the same place on screen relative to its window, is the same pixel of the recording.
    @Test("Dragging the window leaves a click on the same pixel")
    func draggingDoesNotMoveTheClick() throws {
        let before = try #require(WindowSpace.framePoint(
            for: CGPoint(x: 300, y: 400),
            contentRect: window,
            pixelSize: pixelSize
        ))
        // The window moves 250 right and 100 down, and so does the finger.
        let moved = window.offsetBy(dx: 250, dy: 100)
        let after = try #require(WindowSpace.framePoint(
            for: CGPoint(x: 550, y: 500),
            contentRect: moved,
            pixelSize: pixelSize
        ))
        #expect(before == after)
    }

    // MARK: - Resizing

    /// The correction that is easy to miss. SCK fixes the output size when the stream
    /// starts and scales the window into it, so a window made twice as wide has its content
    /// squeezed to half scale — and a conversion using the scale it started with puts every
    /// later click at twice the distance from the left edge that it should be.
    @Test("Resizing the window keeps a proportional click proportional")
    func resizingScalesProportionally() throws {
        // A third of the way across the original window.
        let before = try #require(WindowSpace.framePoint(
            for: CGPoint(x: 100 + 800.0 / 3.0, y: 200),
            contentRect: window,
            pixelSize: pixelSize
        ))

        // The window doubles in width; the recording's pixel size does not change.
        let wider = CGRect(x: 100, y: 200, width: 1600, height: 600)
        let after = try #require(WindowSpace.framePoint(
            for: CGPoint(x: 100 + 1600.0 / 3.0, y: 200),
            contentRect: wider,
            pixelSize: pixelSize
        ))
        #expect(abs(before.x - after.x) < 0.001, "a third across is a third across at any size")
    }

    /// The specific failure a fixed scale produces, asserted so a regression to it is loud.
    @Test("A doubled window does not report clicks off the right of the frame")
    func resizingDoesNotOverflowTheFrame() throws {
        let wider = CGRect(x: 100, y: 200, width: 1600, height: 1200)
        let point = try #require(WindowSpace.framePoint(
            for: CGPoint(x: 1690, y: 1390),
            contentRect: wider,
            pixelSize: pixelSize
        ))
        #expect(point.x <= pixelSize.width, "the click landed \(point.x) into a \(pixelSize.width)px frame")
        #expect(point.y <= pixelSize.height)
    }

    @Test("A zero-sized window rejects rather than dividing by zero")
    func zeroSizedWindow() {
        let point = WindowSpace.framePoint(
            for: CGPoint(x: 100, y: 200),
            contentRect: CGRect(x: 100, y: 200, width: 0, height: 0),
            pixelSize: pixelSize
        )
        #expect(point == nil)
    }
}
