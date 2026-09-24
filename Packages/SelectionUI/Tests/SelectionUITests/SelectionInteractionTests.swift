import CoreGraphics
import Shared
import Testing
@testable import SelectionUI

/// A 1000×800 point display, top-left origin.
private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

private func interaction() -> SelectionInteraction {
    SelectionInteraction(bounds: bounds)
}

@Suite("Dragging a selection")
struct SelectionDragTests {
    @Test("Dragging down-right makes the obvious rect")
    func dragDownRight() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 300, y: 250))

        #expect(selection.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(selection.phase == .dragging)
    }

    @Test("Dragging up-left makes the same rect, not a negative one")
    func dragUpLeft() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 300, y: 250))
        selection.drag(to: CGPoint(x: 100, y: 100))

        #expect(selection.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test("⇧ locks the drag to a square, keeping the drag direction", arguments: [
        (CGPoint(x: 300, y: 250), CGRect(x: 100, y: 100, width: 200, height: 200)),
        (CGPoint(x: 150, y: 400), CGRect(x: 100, y: 100, width: 300, height: 300)),
        (CGPoint(x: 0, y: 0), CGRect(x: 0, y: 0, width: 100, height: 100))
    ])
    func shiftLocksAspect(to point: CGPoint, expected: CGRect) {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: point, modifiers: .lockAspect)

        #expect(selection.rect == expected)
    }

    @Test("A locked 16:9 preset keeps that ratio without ⇧")
    func lockedSixteenNinePreset() throws {
        var selection = interaction()
        selection.lockedAspect = CGSize(width: 16, height: 9)
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 260, y: 400))

        let rect = try #require(selection.rect)
        #expect(abs(rect.width / rect.height - 16 / 9) < 0.02)
        #expect(rect.minX == 100)
        #expect(rect.minY == 100)
    }

    @Test("⇧ still squares even when a preset is on")
    func shiftOverridesAspectPreset() {
        var selection = interaction()
        selection.lockedAspect = CGSize(width: 16, height: 9)
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 300, y: 250), modifiers: .lockAspect)

        #expect(selection.rect == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test("⌥ grows the rect around where the drag started")
    func optionDragsFromCentre() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 500, y: 400))
        selection.drag(to: CGPoint(x: 600, y: 450), modifiers: .fromCenter)

        #expect(selection.rect == CGRect(x: 400, y: 350, width: 200, height: 100))
    }

    @Test("⌥⇧ together give a square centred on the anchor")
    func optionShiftTogether() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 500, y: 400))
        selection.drag(to: CGPoint(x: 600, y: 450), modifiers: [.fromCenter, .lockAspect])

        #expect(selection.rect == CGRect(x: 400, y: 300, width: 200, height: 200))
    }

    @Test("A drag past the edge is clamped to the display")
    func dragBeyondEdgeClamps() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 900, y: 700))
        selection.drag(to: CGPoint(x: 1500, y: 1200))

        #expect(selection.rect == CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    @Test("Releasing with a real rect selects it")
    func releaseSelects() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 10, y: 10))
        selection.drag(to: CGPoint(x: 110, y: 60))
        selection.end()

        #expect(selection.phase == .selected)
        #expect(selection.rect == CGRect(x: 10, y: 10, width: 100, height: 50))
    }

    @Test("A click with no drag selects nothing rather than a zero-size rect")
    func clickWithoutDrag() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 10, y: 10))
        selection.end()

        #expect(selection.phase == .idle)
        #expect(selection.rect == nil)
    }

    @Test("Esc clears everything")
    func escapeClears() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 10, y: 10))
        selection.drag(to: CGPoint(x: 110, y: 60))
        selection.cancelSelection()

        #expect(selection.phase == .idle)
        #expect(selection.rect == nil)
        #expect(selection.anchor == nil)
    }
}

@Suite("Space moves the selection")
struct SelectionMoveTests {
    @Test("Holding Space slides the rect without resizing it")
    func spaceMoves() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 300, y: 200))
        selection.beginMovingSelection()
        selection.drag(to: CGPoint(x: 350, y: 260))

        #expect(selection.rect == CGRect(x: 150, y: 160, width: 200, height: 100))
    }

    @Test("A move that would leave the display slides back inside, keeping its size")
    func moveClampsWithoutResizing() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 800, y: 600))
        selection.drag(to: CGPoint(x: 900, y: 700))
        selection.beginMovingSelection()
        selection.drag(to: CGPoint(x: 1000, y: 800))

        #expect(selection.rect?.size == CGSize(width: 100, height: 100))
        #expect(selection.rect == CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    @Test("Releasing Space re-anchors so resizing continues from the rect, not the old start")
    func releasingSpaceReanchors() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 200, y: 200))
        selection.beginMovingSelection()
        selection.drag(to: CGPoint(x: 400, y: 400))
        selection.endMovingSelection()
        selection.drag(to: CGPoint(x: 500, y: 500))

        #expect(selection.isMovingSelection == false)
        #expect(selection.rect == CGRect(x: 300, y: 300, width: 200, height: 200))
    }
}

@Suite("Re-anchoring and moving a committed selection (T-CAP-12)")
struct SelectionReanchorTests {
    @Test("Releasing Space keeps the corner opposite the pointer", arguments: [
        // Dragged up-left, so the pointer is the rect's top-left and the anchor bottom-right.
        (CGPoint(x: 300, y: 300), CGPoint(x: 100, y: 100), CGPoint(x: 350, y: 350),
         CGRect(x: 350, y: 350, width: 50, height: 50)),
        // Dragged down-right: the anchor is the top-left, as before.
        (CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300), CGPoint(x: 450, y: 450),
         CGRect(x: 200, y: 200, width: 250, height: 250)),
    ])
    func oppositeCorner(start: CGPoint, end: CGPoint, resizeTo: CGPoint, expected: CGRect) {
        var selection = interaction()
        selection.begin(at: start)
        selection.drag(to: end)
        selection.beginMovingSelection()
        selection.drag(to: CGPoint(x: end.x + 100, y: end.y + 100))
        selection.endMovingSelection()
        selection.drag(to: resizeTo)
        #expect(selection.rect == expected)
    }

    @Test("A click inside a committed selection keeps it")
    func clickInsideKeeps() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 300, y: 200))
        selection.end()
        selection.beginMove(at: CGPoint(x: 150, y: 150))
        selection.end()
        #expect(selection.phase == .selected)
        #expect(selection.rect == CGRect(x: 100, y: 100, width: 200, height: 100))
    }

    @Test("Dragging inside a committed selection moves it without resizing")
    func dragInsideMoves() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 300, y: 200))
        selection.end()
        selection.beginMove(at: CGPoint(x: 150, y: 150))
        selection.drag(to: CGPoint(x: 170, y: 190))
        selection.end()
        #expect(selection.rect == CGRect(x: 120, y: 140, width: 200, height: 100))
    }

    @Test("The corner opposite a point", arguments: [
        (CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20)),
        (CGPoint(x: 20, y: 20), CGPoint(x: 10, y: 10)),
        (CGPoint(x: 20, y: 0), CGPoint(x: 10, y: 20)),
        (CGPoint(x: 0, y: 20), CGPoint(x: 20, y: 10)),
    ])
    func corner(point: CGPoint, expected: CGPoint) {
        let rect = CGRect(x: 10, y: 10, width: 10, height: 10)
        #expect(SelectionInteraction.corner(of: rect, opposite: point) == expected)
    }
}

@Suite("Keyboard adjustment")
struct SelectionKeyboardTests {
    private func selected() -> SelectionInteraction {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 300, y: 200))
        selection.end()
        return selection
    }

    @Test("Arrow keys nudge by one point", arguments: [
        (NudgeDirection.left, CGRect(x: 99, y: 100, width: 200, height: 100)),
        (NudgeDirection.right, CGRect(x: 101, y: 100, width: 200, height: 100)),
        (NudgeDirection.up, CGRect(x: 100, y: 99, width: 200, height: 100)),
        (NudgeDirection.down, CGRect(x: 100, y: 101, width: 200, height: 100))
    ])
    func nudge(direction: NudgeDirection, expected: CGRect) {
        var selection = selected()
        selection.nudge(direction)
        #expect(selection.rect == expected)
    }

    @Test("⇧ makes an arrow key move ten points")
    func coarseNudge() {
        var selection = selected()
        selection.nudge(.right, coarse: true)
        #expect(selection.rect == CGRect(x: 110, y: 100, width: 200, height: 100))
    }

    @Test("Nudging at the edge stops rather than shrinking the selection")
    func nudgeAtEdge() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 0, y: 0))
        selection.drag(to: CGPoint(x: 100, y: 100))
        selection.end()
        selection.nudge(.left)

        #expect(selection.rect == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("Resize keys grow and shrink the rect")
    func resize() {
        var selection = selected()
        selection.resize(.right, coarse: true)
        #expect(selection.rect == CGRect(x: 100, y: 100, width: 210, height: 100))

        selection.resize(.left)
        #expect(selection.rect == CGRect(x: 100, y: 100, width: 209, height: 100))
    }

    @Test("A resize can never take the rect below one point")
    func resizeFloor() {
        var selection = interaction()
        selection.begin(at: CGPoint(x: 10, y: 10))
        selection.drag(to: CGPoint(x: 12, y: 12))
        selection.end()
        for _ in 0 ..< 10 {
            selection.resize(.left)
        }

        #expect(selection.rect?.width == 1)
    }

    @Test("A typed size is applied from the selection's corner")
    func typedSize() {
        var selection = selected()
        selection.setSize(CGSize(width: 640, height: 480))

        #expect(selection.rect == CGRect(x: 100, y: 100, width: 640, height: 480))
        #expect(selection.phase == .selected)
    }

    @Test("A typed size with nothing selected starts from the pointer")
    func typedSizeFromPointer() {
        var selection = interaction()
        selection.pointerMoved(to: CGPoint(x: 200, y: 150))
        selection.setSize(CGSize(width: 100, height: 100))

        #expect(selection.rect == CGRect(x: 200, y: 150, width: 100, height: 100))
    }

    @Test("A typed size bigger than the display is trimmed to it")
    func typedSizeTooBig() {
        var selection = interaction()
        selection.pointerMoved(to: CGPoint(x: 900, y: 700))
        selection.setSize(CGSize(width: 5000, height: 5000))

        #expect(selection.rect == bounds)
    }

    @Test("A zero or negative typed size is ignored")
    func typedSizeIgnoresNonsense() {
        var selection = selected()
        let before = selection.rect
        selection.setSize(CGSize(width: 0, height: 100))
        selection.setSize(CGSize(width: -5, height: -5))

        #expect(selection.rect == before)
    }

    @Test("Select-all takes the whole display")
    func selectAll() {
        var selection = interaction()
        selection.selectAll()

        #expect(selection.rect == bounds)
        #expect(selection.phase == .selected)
    }
}

@Suite("Handing the selection to the capture engine")
struct SelectionGlobalRectTests {
    @Test("A selection on the primary display is already global")
    func primaryDisplay() {
        let display = DisplayGeometry(
            displayID: 1,
            frame: DisplayRect(x: 0, y: 0, width: 1000, height: 800),
            scale: .retina
        )
        var selection = interaction()
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 300, y: 200))
        selection.end()

        #expect(selection.globalRect(on: display) == DisplayRect(x: 100, y: 100, width: 200, height: 100))
    }

    @Test("A selection on a second display is offset by that display's origin")
    func secondaryDisplay() {
        let display = DisplayGeometry(
            displayID: 2,
            frame: DisplayRect(x: 2560, y: -400, width: 1000, height: 800),
            scale: .oneToOne
        )
        var selection = interaction()
        selection.begin(at: CGPoint(x: 10, y: 20))
        selection.drag(to: CGPoint(x: 110, y: 70))
        selection.end()

        #expect(selection.globalRect(on: display) == DisplayRect(x: 2570, y: -380, width: 100, height: 50))
    }

    @Test("No selection means nothing to capture")
    func noSelection() {
        let display = DisplayGeometry(
            displayID: 1,
            frame: DisplayRect(x: 0, y: 0, width: 1000, height: 800),
            scale: .retina
        )
        #expect(interaction().globalRect(on: display) == nil)
    }
}
