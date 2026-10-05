import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

@Suite("Editor canvas layout")
struct EditorCanvasLayoutTests {
    private let noPadding = EditorCanvasPadding(top: 0, leading: 0, bottom: 0, trailing: 0)

    @Test("A capture smaller than the viewport scales up to fill it")
    func smallCaptureFills() {
        let mag = EditorCanvasLayout.fitMagnification(
            canvas: CGSize(width: 400, height: 300),
            viewport: CGSize(width: 800, height: 600),
            padding: noPadding
        )
        #expect(mag == 2)
    }

    @Test("Padding shrinks the box the capture has to fit")
    func paddingShrinksFit() {
        let mag = EditorCanvasLayout.fitMagnification(
            canvas: CGSize(width: 400, height: 400),
            viewport: CGSize(width: 800, height: 800),
            padding: EditorCanvasPadding(top: 100, leading: 100, bottom: 100, trailing: 100)
        )
        #expect(mag == 1.5)
    }

    @Test("A 5K capture shrinks to the viewport rather than overflowing it")
    func largeCaptureShrinks() {
        let mag = EditorCanvasLayout.fitMagnification(
            canvas: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 800, height: 800),
            padding: noPadding
        )
        #expect(abs(mag - 0.4) < 0.0001)
    }

    @Test("A stitched page fits its width, not both axes")
    func tallPageFitsWidth() {
        let mag = EditorCanvasLayout.fitMagnification(
            canvas: CGSize(width: 400, height: 1600),
            viewport: CGSize(width: 800, height: 600),
            padding: noPadding
        )
        #expect(mag == 2)
    }

    @Test("Cropping insets the fit so handles stay on-screen")
    func cropInsetShrinksFit() {
        let open = EditorCanvasLayout.fitMagnification(
            canvas: CGSize(width: 400, height: 400),
            viewport: CGSize(width: 800, height: 800),
            padding: noPadding,
            isCropping: false
        )
        let cropping = EditorCanvasLayout.fitMagnification(
            canvas: CGSize(width: 400, height: 400),
            viewport: CGSize(width: 800, height: 800),
            padding: noPadding,
            isCropping: true
        )
        #expect(open == 2)
        #expect(cropping == (800 - EditorCanvasLayout.cropHandleMargin * 2) / 400)
        #expect(cropping < open)
    }

    @Test("An empty canvas or viewport does not divide by zero")
    func emptySizesAreSafe() {
        #expect(
            EditorCanvasLayout.fitMagnification(
                canvas: .zero,
                viewport: CGSize(width: 800, height: 600)
            ) == 1
        )
        #expect(
            EditorCanvasLayout.fitMagnification(
                canvas: CGSize(width: 400, height: 300),
                viewport: .zero
            ) == 1
        )
    }

    @Test("Magnification is clamped to the pinch range")
    func magnificationClamps() {
        #expect(EditorCanvasLayout.clampMagnification(0) == 0.1)
        #expect(EditorCanvasLayout.clampMagnification(100) == 8)
        #expect(EditorCanvasLayout.zoomPercent(for: 1) == 100)
        #expect(EditorCanvasLayout.zoomPercent(for: 0.5) == 50)
    }

    @Test("A capture smaller than the clip sits in the middle")
    func smallDocumentCenters() {
        let origin = EditorCanvasLayout.clipOrigin(
            document: CGSize(width: 800, height: 600),
            clip: CGSize(width: 1000, height: 800),
            proposed: .zero
        )
        #expect(origin == CGPoint(x: -100, y: -100))
    }

    @Test("A live clip shrink recenters even when AppKit proposes the origin")
    func liveClipShrinkStaysCentered() {
        let document = CGSize(width: 800, height: 600)
        let wide = EditorCanvasLayout.clipOrigin(
            document: document,
            clip: CGSize(width: 1000, height: 800),
            proposed: .zero
        )
        let narrowed = EditorCanvasLayout.clipOrigin(
            document: document,
            clip: CGSize(width: 900, height: 800),
            proposed: .zero
        )
        #expect(wide == CGPoint(x: -100, y: -100))
        #expect(narrowed == CGPoint(x: -50, y: -100))
    }

    @Test("A capture larger than the clip keeps a clamped proposed origin")
    func largeDocumentClamps() {
        let origin = EditorCanvasLayout.clipOrigin(
            document: CGSize(width: 2000, height: 1500),
            clip: CGSize(width: 1000, height: 800),
            proposed: CGPoint(x: -50, y: 100)
        )
        #expect(origin == CGPoint(x: 0, y: 100))
    }

    @Test("A tall capture that is narrower than the clip centers horizontally and scrolls from the top")
    func tallNarrowCentersX() {
        let origin = EditorCanvasLayout.clipOrigin(
            document: CGSize(width: 800, height: 1500),
            clip: CGSize(width: 1000, height: 800),
            proposed: .zero
        )
        #expect(origin.x == -100)
        #expect(origin.y == 0)
    }

    @Test("Pan is offered only when the scaled canvas overflows the viewport")
    func panWhenOverflowing() {
        #expect(
            !EditorCanvasLayout.canPan(
                canvas: CGSize(width: 400, height: 300),
                viewport: CGSize(width: 800, height: 600),
                magnification: 1
            )
        )
        #expect(
            EditorCanvasLayout.canPan(
                canvas: CGSize(width: 400, height: 300),
                viewport: CGSize(width: 800, height: 600),
                magnification: 3
            )
        )
    }

    // MARK: - Zoom anchoring

    /// The bug this guards was not in the arithmetic, so no arithmetic test would have found
    /// it: `NSScrollView` magnifies about the clip view's *origin* when you assign to
    /// `magnification`, and about a point when you call `setMagnification(_:centeredAt:)`.
    /// The editor assigned. Zooming out therefore walked the visible region towards the
    /// top-left and, once the canvas fitted, left it parked there — reported as "sometimes it
    /// jumps to the left top corner".
    ///
    /// Asserted structurally because the behaviour belongs to AppKit: what this codebase can
    /// get wrong is *which call it makes*, and that is what this checks.
    @Test("A user zoom is anchored, not assigned")
    func userZoomIsAnchored() throws {
        let source = try String(
            contentsOf: hostSourceURL(),
            encoding: .utf8
        )
        #expect(
            source.contains("setMagnification(target, centeredAt:"),
            "the centerd API is gone; zoom will magnify about the corner again"
        )
        #expect(
            source.contains("setMagnification(target, centeredAt: scrollView.viewportCenter)"),
            "a keyboard zoom has to anchor at the middle of what the user is looking at"
        )
    }

    /// A ⌘-scroll names its own anchor, so zooming in on a detail must not require scrolling
    /// back to it afterwards.
    @Test("A command-scroll zoom is anchored under the pointer")
    func commandScrollZoomIsAnchoredAtThePointer() throws {
        let source = try String(contentsOf: hostSourceURL(), encoding: .utf8)
        #expect(source.contains("zoom(by: step, at: contentView.convert(event.locationInWindow, from: nil))"))
    }

    /// Fit is the one case that *should* assign: it recentres by definition, and the centred
    /// API recentring mid-resize is the jump the original comment was about.
    @Test("Fit still assigns rather than anchoring")
    func fitStillAssigns() throws {
        let source = try String(contentsOf: hostSourceURL(), encoding: .utf8)
        #expect(source.contains("scrollView.magnification = target"))
    }

    /// Inspector-divider (and window) resize constrains the clip bounds directly. Waiting
    /// for `apply()` to call `scroll(to:)` left a frame of origin-zero on screen.
    @Test("The clip view constrains its origin on resize, not only on scroll")
    func clipViewConstrainsBoundsOnResize() throws {
        let source = try String(contentsOf: hostSourceURL(), encoding: .utf8)
        #expect(source.contains("override func constrainBoundsRect"))
        #expect(source.contains("queue: nil"), "a main-queue observer is one turn too late")
    }

    private func hostSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EditorUI/EditorCanvasHost.swift")
    }
}
