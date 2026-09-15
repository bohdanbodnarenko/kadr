import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// A window captured with its shadow: Beautify composes the window, not the transparent
/// margin around it (docs/03 §3 P2).
@Suite("Visible bounds")
struct VisibleBoundsTests {
    private let window = CGRect(x: 30, y: 20, width: 340, height: 220)

    private func shadowedDocument() -> AnnotationDocument {
        AnnotationDocument(baseImage: BaseImageReference(
            size: CGSize(width: 400, height: 280),
            scale: 2,
            visibleBounds: window
        ))
    }

    @Test("A plain capture keeps its shadow margin")
    func plainCaptureIsWhole() {
        let document = shadowedDocument()
        #expect(document.contentRect == CGRect(x: 0, y: 0, width: 400, height: 280))
    }

    @Test("Beautify composes the window, so the card is the window")
    func beautifyComposesTheWindow() throws {
        var document = shadowedDocument()
        document.setBeautify(.cleanWhite)
        #expect(document.contentRect == window)

        let layout = try #require(document.beautifyLayout)
        #expect(layout.imageRect.size == window.size)
        // The window's top-left pixel lands on the card's image origin.
        #expect(document.canvasPoint(fromImage: window.origin) == layout.imageRect.origin)
        #expect(document.imagePoint(fromCanvas: layout.imageRect.origin) == window.origin)
    }

    @Test("A crop still wins over the measured window")
    func cropWins() {
        var document = shadowedDocument()
        document.setBeautify(.cleanWhite)
        let crop = CGRect(x: 50, y: 40, width: 100, height: 80)
        document.setCrop(CropSpec(rect: crop))
        #expect(document.contentRect == crop)
    }

    @Test("A region that is not a margin is discarded", arguments: [
        CGRect(x: 0, y: 0, width: 400, height: 280),
        CGRect(x: 10, y: 10, width: 0, height: 50),
        CGRect(x: 500, y: 500, width: 20, height: 20)
    ])
    func invalidRegionsAreNil(rect: CGRect) {
        let reference = BaseImageReference(size: CGSize(width: 400, height: 280), visibleBounds: rect)
        #expect(reference.visibleBounds == nil)
    }

    @Test("Measured bounds survive being saved, and older files open without them")
    func persistence() throws {
        let reference = BaseImageReference(size: CGSize(width: 400, height: 280), visibleBounds: window)
        let decoded = try JSONDecoder().decode(
            BaseImageReference.self,
            from: JSONEncoder().encode(reference)
        )
        #expect(decoded.visibleBounds == window)

        let legacy = Data(#"{"size":[400,280],"scale":2}"#.utf8)
        let old = try JSONDecoder().decode(BaseImageReference.self, from: legacy)
        #expect(old.visibleBounds == nil)
    }

    @Test("A document measured after opening adopts the window without an undo step")
    func adoptingIsNotAnEdit() {
        var document = AnnotationDocument(baseImage: BaseImageReference(size: CGSize(width: 400, height: 280)))
        document.adoptVisibleBounds(window)
        #expect(document.baseImage.visibleBounds == window)
        #expect(!document.canUndo)
    }
}
