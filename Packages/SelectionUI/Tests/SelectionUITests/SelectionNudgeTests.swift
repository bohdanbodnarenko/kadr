import CoreGraphics
import Testing
@testable import SelectionUI

/// docs/18 CAP-6: arrows nudge outside confirm mode, by one device pixel.
@Suite("Arrow nudges in every mode")
struct SelectionNudgeTests {
    private func interaction() -> SelectionInteraction {
        SelectionInteraction(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    @Test("A nudge mid-drag moves the whole drag and survives the next mouse move")
    func nudgeDuringDrag() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 200, y: 200))
        selection.nudge(.right)
        #expect(selection.rect == CGRect(x: 101, y: 100, width: 100, height: 100))

        selection.drag(to: CGPoint(x: 250, y: 200))
        #expect(selection.rect == CGRect(x: 101, y: 100, width: 150, height: 100))
    }

    @Test("A step is one device pixel", arguments: [
        (CGFloat(1), false, CGFloat(1)),
        (0.5, false, 0.5),
        (0.5, true, 5)
    ])
    func pixelStep(step: CGFloat, coarse: Bool, expected: CGFloat) {
        var selection = interaction()
        selection.pixelStep = step
        selection.setRect(CGRect(x: 100, y: 100, width: 50, height: 50))
        selection.nudge(.right, coarse: coarse)
        #expect(selection.rect?.minX == 100 + expected)
    }
}
