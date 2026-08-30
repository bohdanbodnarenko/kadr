import CoreGraphics
import Testing
@testable import EditorUI

@Suite("Editor window geometry")
struct EditorWindowGeometryTests {
    @Test("A small capture still opens at the minimum window size")
    func smallCaptureUsesMinimum() {
        let size = EditorWindowGeometry.preferredContentSize(
            canvasSize: CGSize(width: 200, height: 100)
        )
        #expect(size.width == EditorWindowGeometry.minSize.width)
        #expect(size.height == EditorWindowGeometry.minSize.height)
    }

    @Test("A large capture grows the window to hug it")
    func largeCaptureGrowsWindow() {
        let size = EditorWindowGeometry.preferredContentSize(
            canvasSize: CGSize(width: 1200, height: 800)
        )
        #expect(size.width > EditorWindowGeometry.minSize.width)
        #expect(size.height > EditorWindowGeometry.minSize.height)
    }

    @Test("Hiding the inspector returns that column to the canvas")
    func hidingInspectorNarrowsWindow() {
        let withInspector = EditorWindowGeometry.preferredContentSize(
            canvasSize: CGSize(width: 1200, height: 800),
            inspectorVisible: true
        )
        let without = EditorWindowGeometry.preferredContentSize(
            canvasSize: CGSize(width: 1200, height: 800),
            inspectorVisible: false
        )
        #expect(withInspector.width - without.width == EditorWindowGeometry.inspectorWidth)
        #expect(withInspector.height == without.height)
    }

    @Test("The frame is centered on the screen and never larger than 92% of it")
    func frameFitsScreen() {
        let screen = CGRect(x: 100, y: 50, width: 1440, height: 900)
        let frame = EditorWindowGeometry.preferredFrame(
            canvasSize: CGSize(width: 5000, height: 4000),
            on: screen
        )
        #expect(abs(frame.midX - screen.midX) < 0.5)
        #expect(abs(frame.midY - screen.midY) < 0.5)
        #expect(frame.width <= screen.width * EditorWindowGeometry.screenFill + 0.5)
        #expect(frame.height <= screen.height * EditorWindowGeometry.screenFill + 0.5)
        #expect(screen.contains(frame))
    }
}
