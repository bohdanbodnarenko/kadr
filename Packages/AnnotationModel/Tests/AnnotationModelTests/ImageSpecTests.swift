import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// Placing a second capture on the canvas (docs/03 §3 P2, docs/06 M24).
///
/// The placement rule is the whole user experience of the feature: an insert that lands
/// off-screen, or that exactly covers the capture it was dropped onto, reads as a bug
/// whatever the code does afterwards.
@Suite("Inserted images")
struct ImageSpecTests {
    private let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test("A small image keeps its natural size")
    func smallImageIsNotResized() {
        let rect = ImageSpec.placement(
            pixelSize: CGSize(width: 200, height: 100),
            scale: 1,
            droppedAt: CGPoint(x: 400, y: 300),
            in: canvas
        )
        #expect(rect.width == 200)
        #expect(rect.height == 100)
    }

    @Test("A Retina insert is placed at its point size, not double")
    func retinaInsertIsHalved() {
        let rect = ImageSpec.placement(
            pixelSize: CGSize(width: 400, height: 200),
            scale: 2,
            droppedAt: CGPoint(x: 400, y: 300),
            in: canvas
        )
        #expect(rect.width == 200)
        #expect(rect.height == 100)
    }

    @Test("It lands centerd on where it was dropped")
    func centredOnTheDrop() {
        let rect = ImageSpec.placement(
            pixelSize: CGSize(width: 200, height: 100),
            scale: 1,
            droppedAt: CGPoint(x: 400, y: 300),
            in: canvas
        )
        #expect(rect.midX == 400)
        #expect(rect.midY == 300)
    }

    @Test("An image bigger than the canvas is scaled to fit, keeping its aspect ratio")
    func largeImageIsScaledDown() {
        let rect = ImageSpec.placement(
            pixelSize: CGSize(width: 4000, height: 2000),
            scale: 1,
            droppedAt: CGPoint(x: 400, y: 300),
            in: canvas
        )
        #expect(rect.width <= canvas.width * 2 / 3 + 0.001)
        #expect(rect.height <= canvas.height * 2 / 3 + 0.001)
        #expect(abs(rect.width / rect.height - 2) < 0.001)
    }

    @Test("A drop near the edge is nudged back inside, not clipped", arguments: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 800, y: 600),
        CGPoint(x: 0, y: 600)
    ])
    func staysInsideTheCanvas(point: CGPoint) {
        let rect = ImageSpec.placement(
            pixelSize: CGSize(width: 300, height: 200),
            scale: 1,
            droppedAt: point,
            in: canvas
        )
        #expect(canvas.contains(rect))
    }

    @Test("A zero-sized image is refused rather than placed")
    func zeroSizeIsRefused() {
        let rect = ImageSpec.placement(
            pixelSize: .zero,
            scale: 1,
            droppedAt: CGPoint(x: 10, y: 10),
            in: canvas
        )
        #expect(rect.isEmpty)
    }

    // MARK: - Sizing

    @Test("A freshly placed image is at 100%")
    func startsAtFullSize() {
        let spec = ImageSpec(pngData: Data([1]), rect: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(spec.scaleFactor == 1)
        #expect(spec.naturalSize == CGSize(width: 200, height: 100))
    }

    @Test("Resizing is relative to the size it was inserted at, so it can be undone")
    func resizeIsRelative() {
        var spec = ImageSpec(pngData: Data([1]), rect: CGRect(x: 0, y: 0, width: 200, height: 100))
        spec.scale(to: 2)
        #expect(spec.rect.width == 400)
        #expect(spec.scaleFactor == 2)

        spec.scale(to: 0.5)
        #expect(spec.rect.width == 100)

        spec.scale(to: 1)
        #expect(spec.rect.width == 200, "a slider back at 100% has to give the original size")
    }

    @Test("Resizing keeps the image where it is")
    func resizeIsAroundTheCentre() {
        var spec = ImageSpec(pngData: Data([1]), rect: CGRect(x: 100, y: 100, width: 200, height: 100))
        let centre = CGPoint(x: spec.rect.midX, y: spec.rect.midY)
        spec.scale(to: 1.5)
        #expect(spec.rect.midX == centre.x)
        #expect(spec.rect.midY == centre.y)
    }

    @Test("The size is clamped, so a slider cannot produce something unusable")
    func resizeIsClamped() {
        var spec = ImageSpec(pngData: Data([1]), rect: CGRect(x: 0, y: 0, width: 200, height: 100))
        spec.scale(to: 100)
        #expect(spec.scaleFactor <= 4)
        spec.scale(to: 0)
        #expect(spec.scaleFactor >= 0.1)
    }

    // MARK: - As a command

    @Test("An image is selectable and moves with the selection")
    func isSelectable() {
        let command = AnnotationCommand.image(ImageSpec(
            pngData: Data([1]),
            rect: CGRect(x: 10, y: 10, width: 50, height: 50)
        ))
        #expect(command.isSelectable)
        #expect(AnnotationHitTesting.hitTest(command, at: CGPoint(x: 20, y: 20)))
        #expect(!AnnotationHitTesting.hitTest(command, at: CGPoint(x: 200, y: 200)))
    }

    @Test("A composition round-trips through the project format with its pixels")
    func roundTripsThroughAProject() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 300), scale: 2)
        )
        document.add(.image(ImageSpec(pngData: png, rect: CGRect(x: 5, y: 5, width: 100, height: 80))))

        let data = try KadrDocumentFile.data(for: KadrDocumentFile.Contents(
            document: document,
            baseImagePNG: png
        ))
        let reopened = try KadrDocumentFile.contents(of: data)

        guard case let .image(spec) = reopened.document.commands.first else {
            Issue.record("expected an inserted image")
            return
        }
        #expect(spec.pngData == png, "a project has to carry the images it is composed of")
        #expect(spec.rect == CGRect(x: 5, y: 5, width: 100, height: 80))
    }
}
