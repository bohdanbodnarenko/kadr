import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

private let baseImage = BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)

private func makeDocument(_ commands: [AnnotationCommand] = []) -> AnnotationDocument {
    AnnotationDocument(baseImage: baseImage, commands: commands)
}

private func shape(_ x: CGFloat = 0) -> AnnotationCommand {
    .shape(ShapeSpec(rect: CGRect(x: x, y: 0, width: 40, height: 40)))
}

private func counter(_ number: Int, at x: CGFloat = 0) -> AnnotationCommand {
    .counter(CounterSpec(number: number, center: CGPoint(x: x, y: 0)))
}

@Suite("Base image")
struct BaseImageTests {
    @Test("Pixel size follows the scale")
    func pixelSize() {
        #expect(baseImage.pixelSize == CGSize(width: 1600, height: 1200))
        #expect(BaseImageReference(size: CGSize(width: 100, height: 50), scale: 1).pixelSize
            == CGSize(width: 100, height: 50))
    }

    @Test("A scale below one is refused — there is no such display")
    func refusesSubUnitScale() {
        #expect(BaseImageReference(size: .zero, scale: 0).scale == 1)
    }
}

@Suite("Editing a document")
struct DocumentEditingTests {
    @Test("A new document is empty and has nothing to undo")
    func emptyDocument() {
        let document = makeDocument()
        #expect(document.isEmpty)
        #expect(document.canUndo == false)
        #expect(document.canRedo == false)
    }

    @Test("Adding appends to the front of the z-order")
    func addAppends() {
        var document = makeDocument()
        let first = shape(0)
        let second = shape(50)
        document.add(first)
        document.add(second)

        #expect(document.commands.map(\.id) == [first.id, second.id])
        #expect(document.index(of: second.id) == 1)
    }

    @Test("Removing takes the annotation and its selection with it")
    func remove() {
        let target = shape(0)
        var document = makeDocument([target, shape(50)])
        document.selection = [target.id]

        document.remove([target.id])

        #expect(document.commands.count == 1)
        #expect(document.selection.isEmpty)
        #expect(document.command(target.id) == nil)
    }

    @Test("Updating replaces an annotation without moving it in the z-order")
    func updateKeepsOrder() {
        var spec = ShapeSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        var document = makeDocument([.shape(spec), shape(100)])
        spec.rect = CGRect(x: 5, y: 5, width: 20, height: 20)

        document.update(.shape(spec))

        #expect(document.index(of: spec.id) == 0)
        if case let .shape(updated) = try? #require(document.command(spec.id)) {
            #expect(updated.rect == CGRect(x: 5, y: 5, width: 20, height: 20))
        }
    }

    @Test("Updating an annotation that is not there changes nothing")
    func updateUnknownIsIgnored() {
        var document = makeDocument([shape()])
        let before = document.commands
        document.update(shape(999))
        #expect(document.commands == before)
    }

    @Test("A change that changes nothing does not add an undo step")
    func noOpDoesNotRecordHistory() {
        var document = makeDocument([shape()])
        document.perform { _ in }
        #expect(document.canUndo == false)
    }

    @Test("The canvas is the base image until a crop says otherwise")
    func canvasFollowsCrop() {
        var document = makeDocument()
        #expect(document.canvasRect == baseImage.bounds)

        let crop = CropSpec(rect: CGRect(x: 10, y: 10, width: 100, height: 80))
        document.add(.crop(crop))
        #expect(document.canvasRect == crop.rect)
        #expect(document.canvasPoint(fromImage: crop.rect.origin) == .zero)
        #expect(document.imagePoint(fromCanvas: .zero) == crop.rect.origin)
        #expect(document.imageSpaceFrame.origin == CGPoint(x: -crop.rect.minX, y: -crop.rect.minY))
    }

    @Test("A second crop supersedes the first")
    func lastCropWins() {
        var document = makeDocument()
        document.add(.crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 100, height: 100))))
        let second = CropSpec(rect: CGRect(x: 5, y: 5, width: 50, height: 50))
        document.add(.crop(second))

        #expect(document.crop?.id == second.id)
        #expect(document.canvasRect == second.rect)
    }

    @Test("Beautify expands the canvas around the capture")
    func beautifyExpandsCanvas() {
        var document = makeDocument()
        document.setBeautify(BeautifySpec(padding: .points(40), shadow: .none, aspect: .original))

        #expect(document.canvasRect == CGRect(x: 0, y: 0, width: 880, height: 680))
        #expect(document.contentRect == baseImage.bounds)
        #expect(document.beautify?.padding == .points(40))
    }

    @Test("Beautify wraps a crop rather than the whole image")
    func beautifyUsesCropSize() {
        var document = makeDocument()
        document.add(.crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 200, height: 100))))
        document.setBeautify(BeautifySpec(padding: .points(20), shadow: .none, aspect: .original))

        #expect(document.contentRect == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(document.canvasRect.size == CGSize(width: 240, height: 140))
    }

    @Test("A point on the padding is still a drawable image-space point")
    func paddingMapsIntoImageSpace() {
        var document = makeDocument()
        document.setBeautify(BeautifySpec(padding: .points(40), shadow: .none, aspect: .original))

        let onPadding = document.imagePoint(fromCanvas: CGPoint(x: 10, y: 10))
        #expect(onPadding.x == -30)
        #expect(onPadding.y == -30)
        #expect(document.canvasPoint(fromImage: onPadding) == CGPoint(x: 10, y: 10))
        #expect(document.imageSpaceFrame.origin == CGPoint(x: 40, y: 40))
    }

    @Test("Replacing beautify coalesces onto one undo step")
    func beautifyCoalesces() {
        var document = makeDocument()
        document.setBeautify(BeautifySpec(padding: .points(10), shadow: .none))
        document.setBeautify(BeautifySpec(padding: .points(20), shadow: .none))
        document.setBeautify(BeautifySpec(padding: .points(30), shadow: .none))

        #expect(document.canUndo)
        document.undo()
        #expect(document.beautify == nil)
        #expect(document.canUndo == false)
    }
}

@Suite("Undo and redo")
struct UndoRedoTests {
    @Test("Undo restores the previous state and redo puts it back")
    func undoRedoRoundTrip() {
        var document = makeDocument()
        document.add(shape(0))
        let afterFirst = document.commands
        document.add(shape(50))
        let afterSecond = document.commands

        let undone = document.undo()
        #expect(undone)
        #expect(document.commands == afterFirst)

        let redone = document.redo()
        #expect(redone)
        #expect(document.commands == afterSecond)
    }

    @Test("Undo at the beginning and redo at the end report failure rather than trapping")
    func boundaries() {
        var document = makeDocument()
        let undone = document.undo()
        #expect(undone == false)

        document.add(shape())
        let redone = document.redo()
        #expect(redone == false)
    }

    @Test("A new edit after undoing discards the redo branch")
    func editTruncatesRedo() {
        var document = makeDocument()
        document.add(shape(0))
        document.add(shape(50))
        document.undo()

        document.add(shape(100))

        #expect(document.canRedo == false)
        #expect(document.commands.count == 2)
    }

    @Test("Undo goes at least 100 deep, as docs/03 §3 requires")
    func undoDepth() {
        var document = makeDocument()
        for index in 0 ..< 120 {
            document.add(shape(CGFloat(index)))
        }
        var undone = 0
        while document.undo() {
            undone += 1
        }
        #expect(undone >= 100, "only \(undone) levels of undo were available")
    }

    @Test("History is bounded, so a long session cannot grow without limit")
    func historyIsBounded() {
        var document = makeDocument()
        for index in 0 ..< (AnnotationDocument.undoDepth * 2) {
            document.add(shape(CGFloat(index)))
        }
        var undone = 0
        while document.undo() {
            undone += 1
        }
        #expect(undone < AnnotationDocument.undoDepth + 1)
    }

    @Test("Undoing a delete does not leave the selection pointing at ghosts")
    func selectionIsPruned() {
        let target = shape()
        var document = makeDocument([target])
        document.selection = [target.id]
        document.remove([target.id])
        document.undo()

        #expect(document.commands.count == 1)
        #expect(document.selection.isEmpty, "the selection came back stale")
    }
}

@Suite("Z-order")
struct ZOrderTests {
    @Test("Bring to front and send to back move the selection to the ends")
    func toFrontAndBack() {
        let first = shape(0), second = shape(50), third = shape(100)
        var document = makeDocument([first, second, third])

        document.bringToFront([first.id])
        #expect(document.commands.map(\.id) == [second.id, third.id, first.id])

        document.sendToBack([third.id])
        #expect(document.commands.map(\.id) == [third.id, second.id, first.id])
    }

    @Test("Forward and backward move one step at a time")
    func oneStep() {
        let first = shape(0), second = shape(50), third = shape(100)
        var document = makeDocument([first, second, third])

        document.bringForward([first.id])
        #expect(document.commands.map(\.id) == [second.id, first.id, third.id])

        document.sendBackward([first.id])
        #expect(document.commands.map(\.id) == [first.id, second.id, third.id])
    }

    @Test("Moving the front annotation forward does nothing")
    func atTheEdges() {
        let first = shape(0), second = shape(50)
        var document = makeDocument([first, second])

        document.bringForward([second.id])
        #expect(document.commands.map(\.id) == [first.id, second.id])

        document.sendBackward([first.id])
        #expect(document.commands.map(\.id) == [first.id, second.id])
    }

    @Test("Two adjacent selected annotations keep their relative order")
    func adjacentSelectionKeepsOrder() {
        let first = shape(0), second = shape(50), third = shape(100)
        var document = makeDocument([first, second, third])

        document.bringForward([first.id, second.id])

        #expect(document.commands.map(\.id) == [third.id, first.id, second.id])
    }

    @Test("Reordering nothing is not an edit")
    func emptySelectionIsNoOp() {
        var document = makeDocument([shape()])
        document.bringToFront([])
        #expect(document.canUndo == false)
    }
}

@Suite("Counter renumbering")
struct CounterRenumberingTests {
    @Test("Counters number themselves 1…n in z-order as they are added")
    func numbersOnAdd() {
        var document = makeDocument()
        document.add(counter(1, at: 0))
        document.add(counter(1, at: 50))
        document.add(counter(1, at: 100))

        #expect(counterNumbers(document) == [1, 2, 3])
    }

    @Test("Reordering renumbers, which is what docs/03 §3 asks for")
    func renumbersOnReorder() {
        let first = counter(1, at: 0)
        let second = counter(2, at: 50)
        let third = counter(3, at: 100)
        var document = makeDocument([first, second, third])
        document.renumberCounters()

        document.bringToFront([first.id])

        #expect(counterNumbers(document) == [1, 2, 3])
        if case let .counter(spec) = try? #require(document.command(first.id)) {
            #expect(spec.number == 3, "the annotation moved to the front should now be number 3")
        }
    }

    @Test("Deleting a counter closes the gap")
    func renumbersOnDelete() {
        let first = counter(1, at: 0)
        let second = counter(2, at: 50)
        let third = counter(3, at: 100)
        var document = makeDocument([first, second, third])
        document.renumberCounters()

        document.remove([second.id])

        #expect(counterNumbers(document) == [1, 2])
    }

    @Test("Renumbering is not a separate undo step")
    func renumberingIsPartOfTheEdit() {
        var document = makeDocument()
        document.add(counter(1, at: 0))
        document.add(counter(1, at: 50))

        document.undo()

        #expect(document.commands.count == 1, "renumbering should not need its own undo")
    }

    @Test("Other annotations do not take counter numbers")
    func onlyCountersAreNumbered() {
        var document = makeDocument([shape(), counter(1), shape(50), counter(1, at: 100)])
        document.renumberCounters()
        #expect(counterNumbers(document) == [1, 2])
    }

    @Test("The next counter number follows the ones already placed")
    func nextNumber() {
        var document = makeDocument()
        #expect(document.nextCounterNumber == 1)

        document.add(counter(1))
        #expect(document.nextCounterNumber == 2)
    }

    private func counterNumbers(_ document: AnnotationDocument) -> [Int] {
        document.commands.compactMap { command in
            if case let .counter(spec) = command {
                return spec.number
            }
            return nil
        }
    }
}
