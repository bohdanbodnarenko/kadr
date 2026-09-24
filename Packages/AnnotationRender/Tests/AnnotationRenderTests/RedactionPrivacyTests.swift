import AnnotationModel
import CoreGraphics
import Testing
@testable import AnnotationRender

/// A redaction is a promise about what leaves the Mac, so every export keeps it (T-ED-12).
@Suite("Redaction privacy")
struct RedactionPrivacyTests {
    private let renderer = AnnotationExportRenderer()

    @Test("Copy without annotations keeps the redaction burned in")
    func withoutAnnotationsKeepsRedaction() throws {
        let base = makeStripedImage()
        let region = CGRect(x: 40, y: 40, width: 100, height: 100)
        let document = makeDocument(commands: [
            .redaction(RedactionSpec(rect: region, style: .blur(radius: 12))),
            .shape(ShapeSpec(
                rect: CGRect(x: 0, y: 0, width: 20, height: 20),
                fill: FillStyle(color: .black)
            ))
        ])

        let before = localContrast(pixels(of: base, in: region), width: 100)
        let bare = try renderer.render(
            baseImage: base,
            document: document,
            includeAnnotations: false,
            randomSeed: 42
        )
        let after = localContrast(pixels(of: bare, in: region), width: 100)

        #expect(after < before / 4, "the secret survived a copy without annotations")
        let corner = CGRect(x: 2, y: 2, width: 10, height: 10)
        #expect(pixels(of: bare, in: corner) == pixels(of: base, in: corner), "the shape is still left out")
    }
}
