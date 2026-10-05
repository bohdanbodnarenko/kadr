import CoreGraphics
import Testing
@testable import AnnotationModel

/// Place-and-type as one undo step, and undo over an open gesture (docs/18 ED-5).
@Suite("Folding undo steps")
struct AnnotationDocumentFoldTests {
    private func makeDocument() -> AnnotationDocument {
        AnnotationDocument(baseImage: BaseImageReference(size: CGSize(width: 100, height: 100), scale: 1))
    }

    private func type(_ string: String, into id: AnnotationID, of document: inout AnnotationDocument) {
        document.beginGesture()
        document.updateGesture { commands in
            guard let index = commands.firstIndex(where: { $0.id == id }),
                  case var .text(spec) = commands[index] else { return }
            spec.string = string
            commands[index] = .text(spec)
        }
    }

    @Test("Placing and typing fold into one step")
    func placeAndType() {
        var document = makeDocument()
        let spec = TextSpec(rect: CGRect(x: 0, y: 0, width: 50, height: 20))
        document.add(.text(spec))
        type("Hello", into: spec.id, of: &document)
        let ended = document.endGesture()
        let folded = document.foldLastStep()
        #expect(ended)
        #expect(folded)

        let undone = document.undo()
        #expect(undone)
        #expect(document.commands.isEmpty)
        #expect(!document.canUndo)
    }

    @Test("A fold that changes nothing leaves no step")
    func emptyPlacement() {
        var document = makeDocument()
        let spec = TextSpec(rect: CGRect(x: 0, y: 0, width: 50, height: 20))
        document.add(.text(spec))
        document.remove([spec.id])
        let folded = document.foldLastStep()
        #expect(folded)
        #expect(!document.canUndo)
    }

    @Test("Undo closes an open gesture, then steps over all of it")
    func undoOverOpenGesture() {
        var document = makeDocument()
        let spec = TextSpec(rect: CGRect(x: 0, y: 0, width: 50, height: 20))
        document.add(.text(spec))
        type("Hel", into: spec.id, of: &document)
        let undone = document.undo()
        #expect(undone)
        #expect(document.commands.count == 1)
        if case let .text(restored)? = document.commands.first {
            #expect(restored.string == spec.string)
        }
    }
}
