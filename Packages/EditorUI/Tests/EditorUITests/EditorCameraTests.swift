import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// The perspective camera as the editor sees it (docs/09 U1.2).
///
/// The camera is only worth having if the image stays *editable* while it is tilted, which
/// comes down to two things: a slider drag must not flood the undo stack, and a click must
/// find the annotation under the pointer rather than the one that would have been there
/// upright.
@MainActor
@Suite("Editor camera")
struct EditorCameraTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    // MARK: - Undo

    @Test("Turning the camera on is one undo step")
    func enablingIsOneStep() {
        let model = makeModel()
        model.applyCamera(.lean)

        #expect(model.document.camera == .lean)
        model.undo()
        #expect(model.document.camera == nil)
    }

    /// The failure this exists to prevent: one drag of the tilt slider is dozens of
    /// commits, and each one landing in history would swallow the whole stack.
    @Test("A slider drag collapses into one undo step")
    func draggingCoalesces() {
        let model = makeModel()
        model.applyCamera(.identity)
        model.applyCamera(AnnotationCameraSpec(tiltDegrees: 5))
        for degrees in stride(from: 6.0, through: 40.0, by: 1) {
            model.applyCamera(AnnotationCameraSpec(tiltDegrees: degrees))
        }
        #expect(model.document.camera?.tiltDegrees == 40)

        model.undo()
        #expect(model.document.camera == nil, "the whole drag should be one step")
    }

    @Test("The camera keeps its identity across edits, so history sees one command")
    func identityIsStable() {
        let model = makeModel()
        model.applyCamera(.lean)
        let first = model.document.camera?.id
        model.applyCamera(.hero)
        #expect(model.document.camera?.id == first)
    }

    @Test("Turning the camera off is its own step, not a coalesced one")
    func disablingIsItsOwnStep() {
        let model = makeModel()
        model.applyCamera(.hero)
        model.clearCamera()
        #expect(model.document.camera == nil)

        model.undo()
        #expect(model.document.camera != nil, "undo should bring the camera back")
    }

    /// An identity camera is not stored at all: it does nothing, and a command that does
    /// nothing still costs a CoreImage pass on every render.
    @Test("An identity camera is not written into the document")
    func identityIsNotStored() {
        let model = makeModel()
        model.applyCamera(.identity)
        #expect(model.document.camera == nil)
    }

    // MARK: - Hit-testing

    /// The behaviour that makes a tilted capture editable rather than a picture of one.
    @Test("A click on the tilted image maps back to the pixel under it", arguments: [
        CGPoint(x: 100, y: 100),
        CGPoint(x: 400, y: 300),
        CGPoint(x: 700, y: 550)
    ])
    func clicksMapThroughTheProjection(contentPoint: CGPoint) throws {
        let model = makeModel()
        model.applyCamera(AnnotationCameraSpec(tiltDegrees: 30, orbitDegrees: -20, rollDegrees: 8))
        let camera = try #require(model.document.cameraGeometry)

        let onScreen = try #require(camera.canvasPoint(from: contentPoint))
        let back = try #require(camera.contentPoint(from: onScreen))
        #expect(abs(back.x - contentPoint.x) < 0.05)
        #expect(abs(back.y - contentPoint.y) < 0.05)
    }

    @Test("With no camera there is no geometry to map through")
    func noCameraNoGeometry() {
        let model = makeModel()
        #expect(model.document.cameraGeometry == nil)
        model.applyCamera(.identity)
        #expect(model.document.cameraGeometry == nil)
    }

    /// With beautify, the camera leans the *card* — so its geometry is measured against
    /// the card's frame, not the capture's own bounds.
    @Test("Inside a beautified canvas the camera works on the card")
    func cameraFollowsTheCard() throws {
        let model = makeModel()
        model.applyBeautify(BeautifySpec(padding: .points(50), shadow: .none))
        model.applyCamera(.identity)
        model.applyCamera(AnnotationCameraSpec(zoom: 1))

        let card = try #require(model.document.beautifyLayout?.cardRect)
        let camera = AnnotationCameraGeometry(spec: AnnotationCameraSpec(zoom: 1), contentRect: card)
        #expect(camera.quad.topLeft.x == card.minX)
        #expect(camera.quad.topLeft.y == card.minY)
    }

    // MARK: - Interaction with the rest of the editor

    @Test("The camera is canvas chrome, so it is never selectable")
    func cameraIsNotSelectable() {
        let command = AnnotationCommand.camera(.hero)
        #expect(!command.isSelectable)
        #expect(AnnotationTool.camera.isCanvasChrome)
        #expect(!AnnotationTool.camera.isPointerTool)
    }

    @Test("Selecting everything does not select the camera")
    func selectAllSkipsTheCamera() {
        let model = makeModel()
        model.applyCamera(.hero)
        model.document.add(.shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 40, height: 40))))
        model.selectAll()

        #expect(model.selection.count == 1)
        #expect(!model.selection.contains(AnnotationCommand.camera(.hero).id))
    }

    @Test("A camera survives a document round trip")
    func roundTripsInTheDocument() throws {
        let model = makeModel()
        model.applyCamera(.hero)

        let data = try JSONEncoder().encode(model.document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        #expect(decoded.camera == .hero)
    }
}
