import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// Background removal as the editor manages it (docs/03 §3 P3, docs/06 M23).
@MainActor
@Suite("Editor subject lift")
struct EditorSubjectLiftTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 200, height: 100), scale: 2)
        ))
    }

    private let mask = Data([0x01, 0x02, 0x03])

    @Test("A document starts with no lift")
    func startsWithout() {
        let model = makeModel()
        #expect(!model.hasSubjectLift)
        #expect(!model.isLiftingSubject)
        #expect(model.subjectLiftError == nil)
    }

    @Test("Applying a mask adds the lift and clears the busy state")
    func applying() {
        let model = makeModel()
        model.startSubjectLift()
        #expect(model.isLiftingSubject)

        model.applySubjectLift(maskPNG: mask)
        #expect(!model.isLiftingSubject)
        #expect(model.hasSubjectLift)
        #expect(model.document.subjectLift?.maskPNG == mask)
    }

    @Test("The lift sits behind everything else on the canvas")
    func liftGoesFirst() {
        let model = makeModel()
        model.tool = .arrow
        model.pointerDown(at: CGPoint(x: 0, y: 0))
        model.pointerDragged(to: CGPoint(x: 50, y: 50))
        model.pointerUp(at: CGPoint(x: 50, y: 50))

        model.applySubjectLift(maskPNG: mask)
        #expect(model.document.commands.first?.tool == .subjectLift)
    }

    @Test("Applying and removing are each one undo step")
    func undoSteps() {
        let model = makeModel()
        model.applySubjectLift(maskPNG: mask)
        model.removeSubjectLift()
        #expect(!model.hasSubjectLift)

        model.undo()
        #expect(model.hasSubjectLift)
        model.undo()
        #expect(!model.hasSubjectLift)
    }

    @Test("A second lift replaces the first rather than stacking")
    func replacesRatherThanStacks() {
        let model = makeModel()
        model.applySubjectLift(maskPNG: mask)
        model.applySubjectLift(maskPNG: Data([0x09]))
        #expect(model.document.commands.count { $0.tool == .subjectLift } == 1)
        #expect(model.document.subjectLift?.maskPNG == Data([0x09]))
    }

    @Test("Changing the fill keeps the mask, so nothing is segmented twice")
    func backgroundChangeKeepsTheMask() {
        let model = makeModel()
        model.applySubjectLift(maskPNG: mask)
        model.setSubjectLiftBackground(.color(.white))

        #expect(model.document.subjectLift?.maskPNG == mask)
        #expect(model.subjectLiftBackground.color != nil)
        #expect(model.document.subjectLift?.needsTransparency == false)
    }

    @Test("Setting the fill it already has changes nothing")
    func redundantBackgroundChange() {
        let model = makeModel()
        model.applySubjectLift(maskPNG: mask)
        let before = model.document.commands
        model.setSubjectLiftBackground(.transparent)
        #expect(model.document.commands == before)
    }

    @Test("A failure is reported without touching the document")
    func failure() {
        let model = makeModel()
        model.startSubjectLift()
        model.failSubjectLift("Kadr could not find a subject in this capture.")

        #expect(!model.isLiftingSubject)
        #expect(!model.hasSubjectLift)
        #expect(model.subjectLiftError != nil)
    }

    @Test("A retry clears the previous failure message")
    func retryClearsTheError() {
        let model = makeModel()
        model.failSubjectLift("nope")
        model.startSubjectLift()
        #expect(model.subjectLiftError == nil)
    }

    @Test("The lift is chrome, so it can never be selected and dragged")
    func notSelectable() {
        let model = makeModel()
        model.applySubjectLift(maskPNG: mask)
        model.selectAll()
        #expect(model.selection.isEmpty)
    }
}
