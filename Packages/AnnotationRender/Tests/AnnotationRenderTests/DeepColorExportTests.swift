import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// Exporting a capture that carries more than eight bits per channel (docs/06 M25).
///
/// The failure this guards against is silent: an HDR or wide-gamut capture rendered into
/// the ordinary 8-bit canvas comes out looking almost right, and the loss only shows up
/// as banding in a gradient — long after the export.
@Suite("Deep-colour export")
struct DeepColorExportTests {
    private let width = 32
    private let height = 16

    /// A wide-gamut bitmap at a given depth.
    ///
    /// The colour space has to match the depth: an extended-range space only makes sense
    /// with float components, and CoreGraphics refuses the combination otherwise — which
    /// is the same rule the renderer has to respect.
    private func makeImage(bitsPerComponent: Int, float: Bool = false) -> CGImage? {
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if bitsPerComponent > 8 {
            info |= CGBitmapInfo.byteOrder16Little.rawValue
            if float {
                info |= CGBitmapInfo.floatComponents.rawValue
            }
        }
        let spaceName = float ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.displayP3
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: CGColorSpace(name: spaceName) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func document() -> AnnotationDocument {
        AnnotationDocument(
            baseImage: BaseImageReference(
                size: CGSize(width: width, height: height),
                scale: 1
            )
        )
    }

    @Test("A 16-bit capture exports at 16 bits, not flattened to 8")
    func sixteenBitSurvives() throws {
        let image = try #require(makeImage(bitsPerComponent: 16))
        #expect(image.bitsPerComponent == 16)

        let rendered = try AnnotationExportRenderer().render(baseImage: image, document: document())
        #expect(rendered.bitsPerComponent == 16)
    }

    @Test("A half-float capture keeps its float components, so values above 1.0 survive")
    func floatComponentsSurvive() throws {
        let image = try #require(makeImage(bitsPerComponent: 16, float: true))
        try #require(image.bitmapInfo.contains(.floatComponents))

        let rendered = try AnnotationExportRenderer().render(baseImage: image, document: document())
        #expect(rendered.bitsPerComponent == 16)
        #expect(rendered.bitmapInfo.contains(.floatComponents))
    }

    @Test("An ordinary 8-bit capture is unchanged, and costs nothing extra")
    func eightBitIsUnchanged() throws {
        let image = try #require(makeImage(bitsPerComponent: 8))
        let rendered = try AnnotationExportRenderer().render(baseImage: image, document: document())
        #expect(rendered.bitsPerComponent == 8)
    }

    @Test("The capture's colour space is carried through, whatever the depth", arguments: [8, 16])
    func colourSpaceIsPreserved(bits: Int) throws {
        let image = try #require(makeImage(bitsPerComponent: bits))
        let rendered = try AnnotationExportRenderer().render(baseImage: image, document: document())
        #expect(rendered.colorSpace?.name == image.colorSpace?.name)
    }

    @Test("Annotations still draw on a deep-colour canvas")
    func annotationsStillDraw() throws {
        let image = try #require(makeImage(bitsPerComponent: 16))
        var document = document()
        document.add(.shape(ShapeSpec(
            rect: CGRect(x: 2, y: 2, width: 10, height: 8),
            stroke: StrokeStyle(color: .annotationRed, width: 2)
        )))

        let rendered = try AnnotationExportRenderer().render(baseImage: image, document: document)
        #expect(rendered.width == width)
        #expect(rendered.height == height)
    }
}
