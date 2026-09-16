import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// The offscreen chrome preview renders at the density it is seen at (docs/10 R1.5).
@Suite("Chrome preview density")
struct PreviewRenderTests {
    /// `min(1, magnification × backing / imageScale)` of the capture's own density.
    struct ScaleCase: Sendable {
        var imageScale: CGFloat
        var magnification: CGFloat
        var backing: CGFloat
        var expected: CGFloat
    }

    @Test("The preview scale is what the window can show, never more than the capture has", arguments: [
        ScaleCase(imageScale: 2, magnification: 1, backing: 2, expected: 2),
        ScaleCase(imageScale: 2, magnification: 0.25, backing: 2, expected: 0.5),
        ScaleCase(imageScale: 2, magnification: 0.5, backing: 1, expected: 0.5),
        ScaleCase(imageScale: 1, magnification: 0.3, backing: 2, expected: 0.6),
        ScaleCase(imageScale: 2, magnification: 4, backing: 2, expected: 2),
        ScaleCase(imageScale: 3, magnification: 0.5, backing: 2, expected: 1)
    ])
    func previewScale(example: ScaleCase) {
        let scale = AnnotationExportRenderer.previewPixelScale(
            imageScale: example.imageScale,
            magnification: example.magnification,
            backingScale: example.backing
        )
        #expect(abs(scale - example.expected) < 0.0001)
    }

    struct StrengthCase: Sendable {
        var style: RedactionStyle
        var ratio: CGFloat
        var expected: RedactionStyle
    }

    @Test("Redaction strength shrinks with the preview, within its floors", arguments: [
        StrengthCase(style: .blur(radius: 20), ratio: 0.5, expected: .blur(radius: 10)),
        StrengthCase(style: .blur(radius: 2), ratio: 0.1, expected: .blur(radius: 0.5)),
        StrengthCase(style: .pixelate(cellSize: 40), ratio: 0.25, expected: .pixelate(cellSize: 10)),
        StrengthCase(style: .pixelate(cellSize: 4), ratio: 0.25, expected: .pixelate(cellSize: 2)),
        StrengthCase(style: .erase, ratio: 0.25, expected: .erase)
    ])
    func scaledStrength(example: StrengthCase) {
        #expect(AnnotationExportRenderer.scaled(example.style, by: example.ratio) == example.expected)
    }

    @Test("A preview at a quarter of the density is a quarter of the pixels a side")
    func previewSize() throws {
        let base = RedactionPreviewSamplingTests.striped(width: 800, height: 400)
        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 200), scale: 2)
        )
        document.add(.redaction(RedactionSpec(rect: CGRect(x: 10, y: 10, width: 100, height: 50))))
        let renderer = AnnotationExportRenderer(objectShadowsEnabled: false)
        let preview = try renderer.renderPreview(
            baseImage: base,
            document: document,
            pixelScale: 0.5,
            randomSeed: 1
        )
        #expect(preview.width == 200)
        #expect(preview.height == 100)

        let full = try renderer.renderPreview(baseImage: base, document: document, pixelScale: 2, randomSeed: 1)
        #expect(full.width == 800)
        #expect(full.height == 400)
    }
}
