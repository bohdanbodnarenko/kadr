import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// Gestures as single undo steps (docs/03 §3, docs/07 C2, docs/09 U0.2).
///
/// The primitive behind the editor's drag fix. A gesture is a run of live edits — one per
/// mouse-moved event — that has to land in history as one step, and has to leave the
/// document byte-identical to a single equivalent edit.
@Suite("Gesture history")
struct GestureHistoryTests {
    private func makeDocument() -> AnnotationDocument {
        AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 300), scale: 2),
            commands: [.shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))]
        )
    }

    private func moveShape(_ commands: inout [AnnotationCommand], to origin: CGPoint) {
        guard case var .shape(spec) = commands[0] else { return }
        spec.rect.origin = origin
        commands[0] = .shape(spec)
    }

    private func origin(of document: AnnotationDocument) -> CGPoint? {
        guard case let .shape(spec) = document.commands[0] else { return nil }
        return spec.rect.origin
    }

    @Test("Many live edits collapse into one undo step")
    func gestureIsOneStep() {
        var document = makeDocument()
        document.beginGesture()
        for step in 1 ... 60 {
            document.updateGesture { moveShape(&$0, to: CGPoint(x: CGFloat(step), y: 0)) }
        }
        document.endGesture()

        #expect(origin(of: document) == CGPoint(x: 60, y: 0))
        let undone = document.undo()
        #expect(undone)
        #expect(origin(of: document) == .zero, "undo must land before the gesture, not inside it")
        #expect(!document.canUndo, "one gesture must not leave sixty steps behind")
    }

    @Test("Redo replays the finished gesture")
    func redoReplaysTheEndState() {
        var document = makeDocument()
        document.beginGesture()
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 5, y: 5)) }
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 9, y: 9)) }
        document.endGesture()

        document.undo()
        document.redo()
        #expect(origin(of: document) == CGPoint(x: 9, y: 9))
    }

    @Test("A gesture that changed nothing leaves history untouched")
    func emptyGestureIsNotAStep() {
        var document = makeDocument()
        #expect(!document.canUndo)

        document.beginGesture()
        document.updateGesture { moveShape(&$0, to: .zero) }
        let recorded = document.endGesture()
        #expect(!recorded)
        #expect(!document.canUndo)
    }

    @Test("A gesture that ends where it began is not a step either")
    func roundTripGestureIsNotAStep() {
        var document = makeDocument()
        document.beginGesture()
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 40, y: 40)) }
        document.updateGesture { moveShape(&$0, to: .zero) }

        let recorded = document.endGesture()
        #expect(!recorded)
        #expect(!document.canUndo)
        #expect(origin(of: document) == .zero)
    }

    @Test("The live state is visible while the gesture is open")
    func liveStateIsVisible() {
        var document = makeDocument()
        document.beginGesture()
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 7, y: 7)) }

        #expect(document.isGestureOpen)
        #expect(origin(of: document) == CGPoint(x: 7, y: 7), "the canvas renders from this")
        document.endGesture()
        #expect(!document.isGestureOpen)
    }

    @Test("Closing a gesture nobody opened is harmless")
    func endWithoutBeginIsSafe() {
        var document = makeDocument()
        let recorded = document.endGesture()
        #expect(!recorded)
        #expect(!document.canUndo)
    }

    @Test("Opening a gesture twice keeps the first baseline")
    func beginIsIdempotent() {
        var document = makeDocument()
        document.beginGesture()
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 3, y: 0)) }
        document.beginGesture()
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 6, y: 0)) }
        document.endGesture()

        document.undo()
        #expect(origin(of: document) == .zero, "undo must reach the start of the whole drag")
    }

    /// Without a gesture open, a live edit has to behave exactly like an ordinary one —
    /// a caller that forgets `beginGesture` gets noisy history, never wrong history.
    @Test("Outside a gesture, updateGesture is an ordinary edit")
    func updateOutsideGestureRecordsHistory() {
        var document = makeDocument()
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 2, y: 2)) }
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 4, y: 4)) }

        let first = document.undo()
        #expect(first)
        #expect(origin(of: document) == CGPoint(x: 2, y: 2))
        let second = document.undo()
        #expect(second)
        #expect(origin(of: document) == .zero)
    }

    @Test("perform during a gesture amends it rather than hiding it behind another step")
    func performDuringGestureIsOneStep() {
        var document = makeDocument()
        document.beginGesture()
        document.perform { $0.append(.counter(CounterSpec(center: CGPoint(x: 8, y: 8)))) }
        document.endGesture()

        #expect(document.commands.count == 2)
        document.undo()
        #expect(document.commands.count == 1)
        #expect(!document.canUndo)
    }

    @Test("A gesture discards a pending redo, like any other edit")
    func gestureDiscardsRedo() {
        var document = makeDocument()
        document.perform { moveShape(&$0, to: CGPoint(x: 1, y: 1)) }
        document.undo()
        #expect(document.canRedo)

        document.beginGesture()
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 8, y: 8)) }
        document.endGesture()

        #expect(!document.canRedo)
        #expect(origin(of: document) == CGPoint(x: 8, y: 8))
    }

    /// A gesture belongs to a drag in progress, so it must not survive being written to
    /// disk — a decoded document is never mid-drag.
    @Test("An open gesture is not part of the encoded document")
    func gestureIsNotEncoded() throws {
        var document = makeDocument()
        document.beginGesture()
        document.updateGesture { moveShape(&$0, to: CGPoint(x: 11, y: 11)) }

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)

        #expect(!decoded.isGestureOpen)
        #expect(origin(of: decoded) == CGPoint(x: 11, y: 11), "the live state is what was on screen")
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("gestureBaseline"))
    }
}
