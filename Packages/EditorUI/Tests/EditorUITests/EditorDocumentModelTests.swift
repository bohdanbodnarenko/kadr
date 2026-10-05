import AnnotationModel
import CoreGraphics
import Testing
@testable import EditorUI

// swiftlint:disable file_length

@MainActor
private func makeModel(_ commands: [AnnotationCommand] = []) -> EditorDocumentModel {
    EditorDocumentModel(document: AnnotationDocument(
        baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2),
        commands: commands
    ))
}

private func shape(_ rect: CGRect) -> AnnotationCommand {
    .shape(ShapeSpec(rect: rect, fill: FillStyle(color: .white)))
}

@MainActor
@Suite("Drawing with each tool")
struct EditorDraftingTests {
    @Test("A drag with the arrow tool makes an arrow between the two points")
    func drawsAnArrow() {
        let model = makeModel()
        model.tool = .arrow
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 100, y: 60))
        model.pointerUp(at: CGPoint(x: 100, y: 60))

        guard case let .arrow(spec) = try? #require(model.document.commands.first) else {
            Issue.record("expected an arrow")
            return
        }
        #expect(spec.start == CGPoint(x: 10, y: 10))
        #expect(spec.end == CGPoint(x: 100, y: 60))
        #expect(model.selection == [spec.id], "a freshly drawn annotation should be selected")
    }

    @Test("A half-drawn annotation is not in the document until the mouse comes up")
    func draftIsNotCommittedEarly() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 50, y: 50))

        #expect(model.document.commands.isEmpty, "a drag in progress must not be undoable yet")
        #expect(model.draft != nil)

        model.pointerUp(at: CGPoint(x: 50, y: 50))
        #expect(model.document.commands.count == 1)
    }

    @Test("A click with no drag draws nothing")
    func clickWithoutDragDrawsNothing() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerUp(at: CGPoint(x: 10, y: 10))

        #expect(model.document.commands.isEmpty)
    }

    @Test("Shift constrains a shape to a square")
    func shiftMakesASquare() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 100, y: 40), modifiers: .constrain)
        model.pointerUp(at: CGPoint(x: 100, y: 40), modifiers: .constrain)

        guard case let .shape(spec) = try? #require(model.document.commands.first) else { return }
        #expect(spec.rect == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("Option draws a shape out from its center")
    func optionDrawsFromCentre() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: CGPoint(x: 100, y: 100))
        model.pointerDragged(to: CGPoint(x: 150, y: 130), modifiers: .fromCenter)
        model.pointerUp(at: CGPoint(x: 150, y: 130), modifiers: .fromCenter)

        guard case let .shape(spec) = try? #require(model.document.commands.first) else { return }
        #expect(spec.rect == CGRect(x: 50, y: 70, width: 100, height: 60))
    }

    @Test("Shift snaps an arrow to 45°", arguments: [
        (CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 0)),
        (CGPoint(x: 90, y: 100), CGPoint(x: 95, y: 95)),
        (CGPoint(x: 10, y: 100), CGPoint(x: 0, y: 100))
    ])
    func shiftSnapsAngles(drag: CGPoint, expected: CGPoint) {
        let model = makeModel()
        model.tool = .arrow
        model.pointerDown(at: .zero)
        model.pointerDragged(to: drag, modifiers: .constrain)
        model.pointerUp(at: drag, modifiers: .constrain)

        guard case let .arrow(spec) = try? #require(model.document.commands.first) else { return }
        #expect(abs(spec.end.x - expected.x) < 1)
        #expect(abs(spec.end.y - expected.y) < 1)
    }

    @Test("A freehand stroke collects every point it passes through")
    func freehandCollectsPoints() {
        let model = makeModel()
        model.tool = .freehand
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 20, y: 5))
        model.pointerUp(at: CGPoint(x: 20, y: 5))

        guard case let .freehand(spec) = try? #require(model.document.commands.first) else { return }
        #expect(spec.points.count == 3)
    }

    @Test("A counter is placed with a click and numbers itself")
    func counterAutoIncrements() {
        let model = makeModel()
        model.tool = .counter
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerUp(at: CGPoint(x: 10, y: 10))
        model.pointerDown(at: CGPoint(x: 50, y: 50))
        model.pointerUp(at: CGPoint(x: 50, y: 50))

        let numbers = model.document.commands.compactMap { command -> Int? in
            if case let .counter(spec) = command {
                return spec.number
            }
            return nil
        }
        #expect(numbers == [1, 2])
        #expect(model.tool == .counter, "counters stay armed so 1, 2, 3… can be placed in sequence")
    }

    @Test("Clicking an existing badge with the counter tool drags it, rather than stacking another")
    func counterClickOnExistingDrags() throws {
        let model = makeModel()
        model.tool = .counter
        model.pointerDown(at: CGPoint(x: 40, y: 40))
        model.pointerUp(at: CGPoint(x: 40, y: 40))

        model.pointerDown(at: CGPoint(x: 40, y: 40))
        model.pointerDragged(to: CGPoint(x: 120, y: 90))
        model.pointerUp(at: CGPoint(x: 120, y: 90))

        #expect(model.document.commands.count == 1)
        guard case let .counter(spec) = try #require(model.document.commands.first) else { return }
        #expect(spec.center == CGPoint(x: 120, y: 90))
        #expect(spec.number == 1)
        #expect(model.tool == .counter)

        model.undo()
        guard case let .counter(restored) = try #require(model.document.commands.first) else { return }
        #expect(restored.center == CGPoint(x: 40, y: 40), "undo of a re-drag restores position, not deletion")
    }

    @Test("A click on an existing badge without a drag does not place another")
    func counterClickOnExistingWithoutDragKeepsOne() {
        let model = makeModel()
        model.tool = .counter
        model.pointerDown(at: CGPoint(x: 40, y: 40))
        model.pointerUp(at: CGPoint(x: 40, y: 40))

        model.pointerDown(at: CGPoint(x: 40, y: 40))
        model.pointerUp(at: CGPoint(x: 40, y: 40))

        #expect(model.document.commands.count == 1)
    }

    @Test("Holding the click that placed a counter slides it")
    func counterClickHoldMoves() {
        let model = makeModel()
        model.tool = .counter
        model.pointerDown(at: CGPoint(x: 40, y: 40))
        model.pointerDragged(to: CGPoint(x: 90, y: 70))
        model.pointerUp(at: CGPoint(x: 90, y: 70))

        guard case let .counter(spec) = try? #require(model.document.commands.first) else { return }
        #expect(spec.center == CGPoint(x: 90, y: 70))
        #expect(model.document.commands.count == 1)
    }

    @Test("Undo removes a counter, including one that was slid after placing")
    func counterUndoRemovesIt() {
        let model = makeModel()
        model.tool = .counter
        model.pointerDown(at: CGPoint(x: 20, y: 20))
        model.pointerDragged(to: CGPoint(x: 80, y: 60))
        model.pointerUp(at: CGPoint(x: 80, y: 60))

        #expect(model.canUndo)
        model.undo()
        #expect(model.document.commands.isEmpty, "place and the hold-drag are one undo step")

        model.tool = .counter
        model.pointerDown(at: CGPoint(x: 15, y: 15))
        model.pointerUp(at: CGPoint(x: 15, y: 15))
        model.undo()
        #expect(model.document.commands.isEmpty)

        model.tool = .counter
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerUp(at: CGPoint(x: 10, y: 10))
        model.pointerDown(at: CGPoint(x: 50, y: 50))
        model.pointerUp(at: CGPoint(x: 50, y: 50))
        model.undo()
        #expect(model.document.commands.count == 1, "undo removes only the last badge")
        model.undo()
        #expect(model.document.commands.isEmpty)
    }

    @Test("A one-shot tool returns to Select after it lands", arguments: [
        EditorTool.arrow, .shape, .line, .redaction, .spotlight
    ])
    func oneShotToolReturnsToSelect(tool: EditorTool) {
        let model = makeModel()
        model.tool = tool
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 80, y: 60))
        model.pointerUp(at: CGPoint(x: 80, y: 60))

        #expect(model.tool == .select)
        #expect(model.selection.count == 1, "the new annotation stays selected so it can be moved")
    }

    @Test("A discarded click does not switch tools")
    func discardedClickKeepsTheTool() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerUp(at: CGPoint(x: 10, y: 10))

        #expect(model.document.commands.isEmpty)
        #expect(model.tool == .shape)
    }

    @Test("A repeatable stroke tool stays armed", arguments: [
        EditorTool.freehand, .highlighter, .crop, .measure
    ])
    func repeatableToolStaysArmed(tool: EditorTool) {
        let model = makeModel()
        model.tool = tool
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 80, y: 60))
        model.pointerUp(at: CGPoint(x: 80, y: 60))

        #expect(model.tool == tool)
    }

    @Test("Placing text keeps the tool armed until the editor commits")
    func textReturnsToSelectAfterCommit() throws {
        let model = makeModel()
        model.tool = .text
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 80, y: 40))
        model.pointerUp(at: CGPoint(x: 80, y: 40))

        let id = try #require(model.consumePendingTextEdit())
        #expect(model.tool == .text, "typing is the rest of the gesture")

        model.commitTextEdit(id)
        #expect(model.tool == .select)
    }

    @Test("Picking a drawing tool clears the leftover selection")
    func selectToolClearsSelection() {
        let target = shape(CGRect(x: 10, y: 10, width: 50, height: 50))
        let model = makeModel([target])
        model.selection = [target.id]

        model.selectTool(.arrow)
        #expect(model.selection.isEmpty)
        #expect(model.tool == .arrow)

        model.selection = [target.id]
        model.selectTool(.select)
        #expect(model.selection == [target.id], "returning to Select keeps what was selected")
    }

    /// Re-pressing the tool that is already armed clears too.
    ///
    /// It used to return early on an unchanged tool, so the shape drawn a moment ago stayed
    /// selected while the user was lining up the next one — and a colour meant for the next
    /// shape rewrote the previous one instead, which is the kind of thing that reads as the
    /// editor having a mind of its own.
    @Test("Re-picking the armed tool still clears the selection")
    func rePickingTheArmedToolClears() {
        let target = shape(CGRect(x: 10, y: 10, width: 50, height: 50))
        let model = makeModel([target])
        model.selectTool(.arrow)
        model.selection = [target.id]

        model.selectTool(.arrow)
        #expect(model.selection.isEmpty)
        #expect(model.tool == .arrow)
    }

    /// Crop is a mode until Done (docs/03 §3), and Done is `selectTool(.select)` — so
    /// leaving it must keep the crop rather than discard it.
    @Test("Finishing a crop leaves the mode and keeps the crop")
    func finishingCropKeepsIt() {
        let model = makeModel([])
        model.selectTool(.crop)
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 90, y: 70))
        model.pointerUp(at: CGPoint(x: 90, y: 70))
        let cropped = model.document.crop
        #expect(cropped != nil, "the drag did not produce a crop")

        model.selectTool(.select)
        #expect(model.tool == .select)
        #expect(model.document.crop == cropped, "leaving crop mode threw the crop away")
    }

    @Test("Every drawing tool produces its own kind of annotation", arguments: [
        (EditorTool.arrow, AnnotationTool.arrow),
        (.shape, .shape),
        (.line, .line),
        (.freehand, .freehand),
        (.highlighter, .highlighter),
        (.text, .text),
        (.redaction, .redaction),
        (.spotlight, .spotlight),
        (.crop, .crop)
    ])
    func everyToolDraws(tool: EditorTool, expected: AnnotationTool) {
        let model = makeModel()
        model.tool = tool
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 80, y: 60))
        model.pointerUp(at: CGPoint(x: 80, y: 60))

        #expect(model.document.commands.first?.tool == expected)
    }

    @Test("Drawing remembers the style for next time")
    func stylesAreRemembered() {
        let model = makeModel()
        model.styleMemory.remember(StrokeStyle(color: .black, width: 9), for: .arrow)
        model.tool = .arrow
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 50, y: 50))
        model.pointerUp(at: CGPoint(x: 50, y: 50))

        guard case let .arrow(spec) = try? #require(model.document.commands.first) else { return }
        #expect(spec.stroke.width == 9)
        #expect(model.styleMemory.stroke(for: .arrow).width == 9)
    }
}

@MainActor
@Suite("Selecting and moving")
struct EditorSelectionTests {
    @Test("Clicking an annotation selects it")
    func clickSelects() {
        let target = shape(CGRect(x: 10, y: 10, width: 100, height: 100))
        let model = makeModel([target])
        model.tool = .select
        model.pointerDown(at: CGPoint(x: 50, y: 50))
        model.pointerUp(at: CGPoint(x: 50, y: 50))

        #expect(model.selection == [target.id])
    }

    @Test("Clicking empty space clears the selection")
    func clickEmptySpaceDeselects() {
        let target = shape(CGRect(x: 10, y: 10, width: 50, height: 50))
        let model = makeModel([target])
        model.selection = [target.id]
        model.tool = .select
        model.pointerDown(at: CGPoint(x: 400, y: 400))
        model.pointerUp(at: CGPoint(x: 400, y: 400))

        #expect(model.selection.isEmpty)
    }

    @Test("Command-click adds to and removes from the selection")
    func commandClickToggles() {
        let first = shape(CGRect(x: 0, y: 0, width: 50, height: 50))
        let second = shape(CGRect(x: 100, y: 0, width: 50, height: 50))
        let model = makeModel([first, second])
        model.tool = .select

        model.pointerDown(at: CGPoint(x: 25, y: 25))
        model.pointerUp(at: CGPoint(x: 25, y: 25))
        model.pointerDown(at: CGPoint(x: 125, y: 25), modifiers: .extendSelection)
        model.pointerUp(at: CGPoint(x: 125, y: 25), modifiers: .extendSelection)

        #expect(model.selection == [first.id, second.id])

        model.pointerDown(at: CGPoint(x: 125, y: 25), modifiers: .extendSelection)
        model.pointerUp(at: CGPoint(x: 125, y: 25), modifiers: .extendSelection)
        #expect(model.selection == [first.id])
    }

    @Test("A marquee selects what it encloses")
    func marqueeSelects() {
        let inside = shape(CGRect(x: 20, y: 20, width: 30, height: 30))
        // Well clear of the marquee, which runs from (0,0) to (100,100).
        let outside = shape(CGRect(x: 300, y: 300, width: 30, height: 30))
        let model = makeModel([inside, outside])
        model.tool = .select

        // Dragged bottom-right to top-left, so backwards marquees are covered too.
        model.pointerDown(at: CGPoint(x: 100, y: 100))
        model.pointerDragged(to: CGPoint(x: 0, y: 0))
        model.pointerUp(at: CGPoint(x: 0, y: 0))

        #expect(model.selection == [inside.id])
    }

    @Test("Dragging a selected annotation moves it")
    func dragMoves() {
        let target = shape(CGRect(x: 10, y: 10, width: 50, height: 50))
        let model = makeModel([target])
        model.tool = .select

        model.pointerDown(at: CGPoint(x: 30, y: 30))
        model.pointerDragged(to: CGPoint(x: 130, y: 80))
        model.pointerUp(at: CGPoint(x: 130, y: 80))

        guard case let .shape(spec) = try? #require(model.document.command(target.id)) else { return }
        #expect(spec.rect == CGRect(x: 110, y: 60, width: 50, height: 50))
    }

    @Test("Arrow keys nudge the selection")
    func nudge() {
        let target = shape(CGRect(x: 10, y: 10, width: 50, height: 50))
        let model = makeModel([target])
        model.selection = [target.id]

        model.nudgeSelection(dx: 5, dy: -3)

        guard case let .shape(spec) = try? #require(model.document.command(target.id)) else { return }
        #expect(spec.rect.origin == CGPoint(x: 15, y: 7))
    }

    @Test("Locking the canvas stops moves but still allows new strokes")
    func canvasLockBlocksMoves() {
        let target = shape(CGRect(x: 10, y: 10, width: 50, height: 50))
        let model = makeModel([target])
        model.tool = .select
        model.isCanvasLocked = true

        model.pointerDown(at: CGPoint(x: 30, y: 30))
        model.pointerDragged(to: CGPoint(x: 130, y: 80))
        model.pointerUp(at: CGPoint(x: 130, y: 80))

        guard case let .shape(spec) = try? #require(model.document.command(target.id)) else { return }
        #expect(spec.rect == CGRect(x: 10, y: 10, width: 50, height: 50))

        model.tool = .arrow
        model.pointerDown(at: CGPoint(x: 0, y: 0))
        model.pointerDragged(to: CGPoint(x: 40, y: 40))
        model.pointerUp(at: CGPoint(x: 40, y: 40))
        #expect(model.document.commands.contains {
            if case .arrow = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test("Locking the canvas blocks nudging and duplicating")
    func canvasLockBlocksEdits() {
        let target = shape(CGRect(x: 10, y: 10, width: 50, height: 50))
        let model = makeModel([target])
        model.selection = [target.id]
        model.isCanvasLocked = true

        model.nudgeSelection(dx: 5, dy: 5)
        model.duplicateSelection()

        #expect(model.document.commands.count == 1)
        guard case let .shape(spec) = try? #require(model.document.command(target.id)) else { return }
        #expect(spec.rect.origin == CGPoint(x: 10, y: 10))
    }

    @Test("Every annotation type can be moved", arguments: [
        AnnotationCommand.arrow(ArrowSpec(start: .zero, end: CGPoint(x: 10, y: 10))),
        .line(LineSpec(start: .zero, end: CGPoint(x: 10, y: 10))),
        .shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
        .freehand(FreehandSpec(points: [.zero, CGPoint(x: 10, y: 10)])),
        .highlighter(HighlighterSpec(points: [.zero, CGPoint(x: 10, y: 10)])),
        .text(TextSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
        .redaction(RedactionSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
        .spotlight(SpotlightSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
        .counter(CounterSpec(center: .zero)),
        .crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
    ])
    func everyTypeTranslates(command: AnnotationCommand) {
        let moved = EditorDocumentModel.translated(command, by: CGSize(width: 20, height: 30))
        let before = AnnotationHitTesting.boundingBox(of: command)
        let after = AnnotationHitTesting.boundingBox(of: moved)

        #expect(abs(after.minX - before.minX - 20) < 0.001)
        #expect(abs(after.minY - before.minY - 30) < 0.001)
        #expect(after.size == before.size, "moving must not resize")
        #expect(moved.id == command.id, "moving must not change identity")
    }

    @Test("Delete removes the selection")
    func deleteSelection() {
        let first = shape(CGRect(x: 0, y: 0, width: 10, height: 10))
        let second = shape(CGRect(x: 50, y: 0, width: 10, height: 10))
        let model = makeModel([first, second])
        model.selection = [first.id]

        model.deleteSelection()

        #expect(model.document.commands.map(\.id) == [second.id])
        #expect(model.selection.isEmpty)
    }

    @Test("Select-all takes everything selectable but not the crop")
    func selectAll() {
        let target = shape(CGRect(x: 0, y: 0, width: 10, height: 10))
        let crop = AnnotationCommand.crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let model = makeModel([target, crop])
        model.tool = .arrow

        model.selectAll()

        #expect(model.selection == [target.id])
        #expect(model.tool == .select)
    }

    @Test("Undo reaches back through a drag")
    func undoAfterDrag() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 50, y: 50))
        model.pointerUp(at: CGPoint(x: 50, y: 50))

        #expect(model.canUndo)
        model.undo()
        #expect(model.document.commands.isEmpty)

        model.redo()
        #expect(model.document.commands.count == 1)
    }

    @Test("Rotate and flip are undoable canvas chrome")
    func rotateAndFlipUndo() {
        let model = makeModel()
        model.rotateClockwise()
        #expect(model.document.orientation.quarterTurnsCW == 1)
        model.flipHorizontal()
        #expect(model.document.orientation.isFlippedHorizontally)
        model.undo()
        #expect(model.document.orientation.quarterTurnsCW == 1)
        #expect(!model.document.orientation.isFlippedHorizontally)
        model.undo()
        #expect(model.document.orientation.isIdentity)

        model.flipVertical()
        #expect(model.document.orientation.quarterTurnsCW == 2)
        #expect(model.document.orientation.isFlippedHorizontally)
        model.undo()
        #expect(model.document.orientation.isIdentity)
    }

    @Test("Beautify is undoable canvas chrome")
    func beautifyUndo() {
        let model = makeModel()
        model.applyBeautify(.cleanWhite)
        #expect(model.document.beautify != nil)
        model.clearBeautify()
        #expect(model.document.beautify == nil)
        model.undo()
        #expect(model.document.beautify != nil)
    }
}

@Suite("Tool metadata")
struct EditorToolTests {
    @Test("Every tool has a distinct keyboard shortcut")
    func distinctShortcuts() {
        let shortcuts = EditorTool.allCases.map(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test("Select is the only tool that draws nothing")
    func selectDrawsNothing() {
        #expect(EditorTool.select.annotation == nil)
        for tool in EditorTool.allCases where tool != .select {
            #expect(tool.annotation != nil, "\(tool) should draw something")
        }
    }

    @Test("Every annotation tool the pointer can draw is reachable from the toolbar")
    func everyAnnotationToolIsReachable() {
        let reachable = Set(EditorTool.allCases.compactMap(\.annotation))
        let chrome: Set<AnnotationTool> = [
            .beautify, .subjectLift, .camera, .progressiveBlur, .watermark
        ]
        #expect(reachable == Set(AnnotationTool.allCases).subtracting(chrome))
    }

    @Test("One-shot tools return to Select; repeatable tools stay armed")
    func returnsToSelectAfterUse() {
        let oneShot: Set<EditorTool> = [.arrow, .shape, .line, .text, .redaction, .spotlight]
        for tool in EditorTool.allCases {
            #expect(tool.returnsToSelectAfterUse == oneShot.contains(tool), "\(tool)")
        }
    }
}

// swiftlint:enable file_length
