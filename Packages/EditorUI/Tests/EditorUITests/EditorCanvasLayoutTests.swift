import CoreGraphics
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
}
