import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// A base image with sharp vertical stripes, so blurring is measurable: stripes have high
/// local variance, and a blur that worked destroys it.
private func makeStripedImage(width: Int = 200, height: Int = 200) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    for x in stride(from: 0, to: width, by: 4) {
        let isDark = (x / 4) % 2 == 0
        context.setFillColor(CGColor(gray: isDark ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 4, height: height))
    }
    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }
    return image
}

/// Reads a region's pixels back out of an image.
private func pixels(of image: CGImage, in rect: CGRect) -> [UInt8] {
    let width = Int(rect.width)
    let height = Int(rect.height)
    // Explicitly allocated, not `&someArray`: a `CGContext` keeps the pointer it is
    // given and writes through it during `draw` — past the end of the inout access
    // an array would give it, which is undefined behaviour and does crash.
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
    bytes.initialize(repeating: 0, count: width * height * 4)
    defer { bytes.deallocate() }
    guard let context = CGContext(
        data: bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a readback context")
    }
    context.draw(
        image,
        in: CGRect(x: -rect.minX, y: -rect.minY, width: CGFloat(image.width), height: CGFloat(image.height))
    )
    return Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
}

/// Mean absolute difference between neighbouring pixels — high for sharp stripes, low
/// once they have been blurred away.
private func localContrast(_ bytes: [UInt8], width: Int) -> Double {
    var total = 0.0
    var samples = 0
    let height = bytes.count / (width * 4)
    for y in 0 ..< height {
        for x in 1 ..< width {
            let here = Double(bytes[(y * width + x) * 4])
            let before = Double(bytes[(y * width + x - 1) * 4])
            total += abs(here - before)
            samples += 1
        }
    }
    return samples > 0 ? total / Double(samples) : 0
}

private func makeDocument(
    size: CGSize = CGSize(width: 200, height: 200),
    scale: CGFloat = 1,
    commands: [AnnotationCommand] = []
) -> AnnotationDocument {
    AnnotationDocument(baseImage: BaseImageReference(size: size, scale: scale), commands: commands)
}

@Suite("Exporting a document")
struct AnnotationExportRendererTests {
    private let renderer = AnnotationExportRenderer()

    @Test("An empty document exports the capture at its own size")
    func emptyDocument() throws {
        let image = try renderer.render(baseImage: makeStripedImage(), document: makeDocument())
        #expect(image.width == 200)
        #expect(image.height == 200)
    }

    @Test("A Retina document exports at native pixels, not points")
    func retinaExportsAtNativeScale() throws {
        let base = makeStripedImage(width: 400, height: 400)
        let document = makeDocument(size: CGSize(width: 200, height: 200), scale: 2)
        let image = try renderer.render(baseImage: base, document: document)

        #expect(image.width == 400)
        #expect(image.height == 400)
    }

    @Test("A crop exports only the cropped area")
    func cropLimitsTheCanvas() throws {
        let document = makeDocument(commands: [
            .crop(CropSpec(rect: CGRect(x: 20, y: 20, width: 100, height: 60)))
        ])
        let image = try renderer.render(baseImage: makeStripedImage(), document: document)

        #expect(image.width == 100)
        #expect(image.height == 60)
    }

    @Test("Every annotation type renders without failing", arguments: [
        AnnotationCommand.arrow(ArrowSpec(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 150, y: 120))),
        .arrow(ArrowSpec(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 150, y: 10),
            controlPoint: CGPoint(x: 80, y: 90),
            head: .open
        )),
        .arrow(ArrowSpec(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50), head: .concave)),
        .shape(ShapeSpec(kind: .rectangle, rect: CGRect(x: 10, y: 10, width: 80, height: 40))),
        .shape(ShapeSpec(
            kind: .roundedRectangle(cornerRadius: 12),
            rect: CGRect(x: 10, y: 10, width: 80, height: 40),
            fill: FillStyle(color: .white)
        )),
        .shape(ShapeSpec(kind: .ellipse, rect: CGRect(x: 10, y: 10, width: 80, height: 40))),
        .line(LineSpec(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100))),
        .freehand(FreehandSpec(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 60), CGPoint(x: 90, y: 20)])),
        .highlighter(HighlighterSpec(points: [CGPoint(x: 0, y: 50), CGPoint(x: 180, y: 50)])),
        .text(TextSpec(string: "Hello", rect: CGRect(x: 10, y: 10, width: 150, height: 40))),
        .text(TextSpec(
            string: "Pill",
            rect: CGRect(x: 10, y: 10, width: 100, height: 30),
            style: TextStyle(backgroundColor: .black)
        )),
        .counter(CounterSpec(number: 7, center: CGPoint(x: 100, y: 100)))
    ])
    func rendersEveryCommand(command: AnnotationCommand) throws {
        let document = makeDocument(commands: [command])
        let image = try renderer.render(baseImage: makeStripedImage(), document: document)
        #expect(image.width == 200)
    }

    @Test("An annotation actually changes the pixels it covers")
    func annotationsAreDrawn() throws {
        let base = makeStripedImage()
        let plain = try renderer.render(baseImage: base, document: makeDocument())
        let annotated = try renderer.render(baseImage: base, document: makeDocument(commands: [
            .shape(ShapeSpec(
                rect: CGRect(x: 50, y: 50, width: 100, height: 100),
                fill: FillStyle(color: .annotationRed)
            ))
        ]))

        let region = CGRect(x: 60, y: 60, width: 40, height: 40)
        #expect(pixels(of: plain, in: region) != pixels(of: annotated, in: region))
    }

    @Test("Copy-without-annotations leaves the capture alone but keeps the crop")
    func withoutAnnotations() throws {
        let base = makeStripedImage()
        let document = makeDocument(commands: [
            .shape(ShapeSpec(
                rect: CGRect(x: 0, y: 0, width: 200, height: 200),
                fill: FillStyle(color: .black)
            )),
            .crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        ])

        let bare = try renderer.render(baseImage: base, document: document, includeAnnotations: false)
        let full = try renderer.render(baseImage: base, document: document)

        #expect(bare.width == 100, "the crop still applies")
        let region = CGRect(x: 10, y: 10, width: 40, height: 40)
        #expect(pixels(of: bare, in: region) != pixels(of: full, in: region))
    }
}

@Suite("Beautify export")
struct BeautifyExportTests {
    private let renderer = AnnotationExportRenderer()

    @Test("Padding grows the exported bitmap")
    func paddingGrowsExport() throws {
        let document = makeDocument(commands: [
            .beautify(BeautifySpec(padding: .points(40), shadow: .none, aspect: .original))
        ])
        let image = try renderer.render(baseImage: makeStripedImage(), document: document)
        #expect(image.width == 280)
        #expect(image.height == 280)
    }

    @Test("A solid backdrop fills the padding")
    func solidBackdropFillsPadding() throws {
        let red = AnnotationColor(red: 1, green: 0, blue: 0)
        let document = makeDocument(commands: [
            .beautify(BeautifySpec(
                padding: .points(40),
                cornerRadius: .zero,
                backdrop: .solid(red),
                shadow: .none,
                aspect: .original
            ))
        ])
        let image = try renderer.render(baseImage: makeStripedImage(), document: document)
        let corner = pixels(of: image, in: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(corner[0] > 240, "the padding should be the red backdrop, got \(corner[0])")
        #expect(corner[1] < 20)
        #expect(corner[2] < 20)
    }

    @Test("Rounded corners show the backdrop, not the capture")
    func roundedCornersClip() throws {
        let blue = AnnotationColor(red: 0, green: 0, blue: 1)
        let document = makeDocument(size: CGSize(width: 100, height: 100), commands: [
            .beautify(BeautifySpec(
                padding: .points(20),
                cornerRadius: .points(50),
                backdrop: .solid(blue),
                shadow: .none,
                aspect: .original
            ))
        ])
        let image = try renderer.render(
            baseImage: makeStripedImage(width: 100, height: 100),
            document: document
        )
        // The canvas corner is padding; a pixel just inside the content's top-left is
        // outside a fully-rounded card (radius = half the shorter side).
        let outsideCard = pixels(of: image, in: CGRect(x: 20, y: 20, width: 4, height: 4))
        #expect(outsideCard[2] > 240, "the rounded corner should show the blue backdrop")
        #expect(outsideCard[0] < 20)
    }

    @Test("Social presets export at their advertised aspect", arguments: [
        (BeautifySpec.twitter, CGFloat(16) / 9),
        (BeautifySpec.instagram, CGFloat(4) / 5),
        (BeautifySpec.story, CGFloat(9) / 16)
    ])
    func socialPresets(spec: BeautifySpec, ratio: CGFloat) throws {
        let document = makeDocument(
            size: CGSize(width: 400, height: 240),
            commands: [.beautify(spec)]
        )
        let image = try renderer.render(
            baseImage: makeStripedImage(width: 400, height: 240),
            document: document
        )
        let actual = CGFloat(image.width) / CGFloat(image.height)
        #expect(abs(actual - ratio) < 0.02)
    }

    @Test("Copy-without-annotations keeps the beautify chrome")
    func withoutAnnotationsKeepsBeautify() throws {
        let document = makeDocument(commands: [
            .shape(ShapeSpec(
                rect: CGRect(x: 0, y: 0, width: 200, height: 200),
                fill: FillStyle(color: .black)
            )),
            .beautify(BeautifySpec(padding: .points(20), shadow: .none, aspect: .original))
        ])
        let bare = try renderer.render(
            baseImage: makeStripedImage(),
            document: document,
            includeAnnotations: false
        )
        #expect(bare.width == 240)
        #expect(bare.height == 240)
    }
}

/// Doc 03 §3: "irreversible at export … not an overlay that can be removed from the PNG".
@Suite("Redaction is irreversible")
struct RedactionTests {
    private let renderer = AnnotationExportRenderer()

    @Test("A blurred region loses the detail that was under it")
    func blurDestroysDetail() throws {
        let base = makeStripedImage()
        let region = CGRect(x: 40, y: 40, width: 100, height: 100)
        let document = makeDocument(commands: [
            .redaction(RedactionSpec(rect: region, style: .blur(radius: 12)))
        ])

        let before = localContrast(pixels(of: base, in: region), width: 100)
        let exported = try renderer.render(baseImage: base, document: document, randomSeed: 42)
        let after = localContrast(pixels(of: exported, in: region), width: 100)

        #expect(before > 40, "the fixture should start sharp, measured \(before)")
        #expect(after < before / 4, "blur left \(after) of \(before) contrast — detail survived")
    }

    @Test("A pixelated region loses the detail that was under it")
    func pixelateDestroysDetail() throws {
        let base = makeStripedImage()
        let region = CGRect(x: 40, y: 40, width: 100, height: 100)
        let document = makeDocument(commands: [
            .redaction(RedactionSpec(rect: region, style: .pixelate(cellSize: 16)))
        ])

        let before = localContrast(pixels(of: base, in: region), width: 100)
        let exported = try renderer.render(baseImage: base, document: document, randomSeed: 7)
        let after = localContrast(pixels(of: exported, in: region), width: 100)

        #expect(after < before / 4, "pixelation left \(after) of \(before) contrast")
    }

    @Test("Pixelation is jittered, so the mosaic grid is not predictable")
    func pixelateIsJittered() throws {
        // A predictable grid over known glyph shapes is attackable: each cell's average
        // leaks what was under it. Two runs must not produce the same cell boundaries.
        let base = makeStripedImage()
        let region = CGRect(x: 40, y: 40, width: 100, height: 100)
        let document = makeDocument(commands: [
            .redaction(RedactionSpec(rect: region, style: .pixelate(cellSize: 16)))
        ])

        let first = try renderer.render(baseImage: base, document: document, randomSeed: 1)
        let second = try renderer.render(baseImage: base, document: document, randomSeed: 2)

        #expect(
            pixels(of: first, in: region) != pixels(of: second, in: region),
            "two pixelations produced an identical grid"
        )
    }

    @Test("The redaction is burned in, not drawn on top")
    func redactionIsNotAnOverlay() throws {
        // If redaction were an overlay, rendering with annotations off would leave the
        // region blurred anyway — because the blur would be a separate layer. It is not:
        // the base image itself is modified, so turning annotations off shows the
        // original. That asymmetry is exactly what proves it is burned in at export.
        let base = makeStripedImage()
        let region = CGRect(x: 40, y: 40, width: 100, height: 100)
        let document = makeDocument(commands: [
            .redaction(RedactionSpec(rect: region, style: .blur(radius: 12)))
        ])

        let redacted = try renderer.render(baseImage: base, document: document)
        let contrast = localContrast(pixels(of: redacted, in: region), width: 100)
        #expect(contrast < 20, "the exported file still contains sharp detail")
    }

    @Test("A redaction outside the image is ignored rather than crashing")
    func offImageRedaction() throws {
        let document = makeDocument(commands: [
            .redaction(RedactionSpec(rect: CGRect(x: 5000, y: 5000, width: 100, height: 100)))
        ])
        let image = try renderer.render(baseImage: makeStripedImage(), document: document)
        #expect(image.width == 200)
    }

    @Test("A zero-sized redaction is ignored")
    func emptyRedaction() throws {
        let document = makeDocument(commands: [
            .redaction(RedactionSpec(rect: .zero))
        ])
        let image = try renderer.render(baseImage: makeStripedImage(), document: document)
        #expect(image.width == 200)
    }
}

@Suite("Seeded randomness")
struct SeededGeneratorTests {
    @Test("The same seed gives the same sequence")
    func deterministic() {
        var first = SeededGenerator(seed: 99)
        var second = SeededGenerator(seed: 99)
        #expect((0 ..< 8).map { _ in first.next() } == (0 ..< 8).map { _ in second.next() })
    }

    @Test("Different seeds give different sequences")
    func differentSeeds() {
        var first = SeededGenerator(seed: 1)
        var second = SeededGenerator(seed: 2)
        #expect(first.next() != second.next())
    }

    @Test("A zero seed still produces varying output")
    func zeroSeed() {
        var generator = SeededGenerator(seed: 0)
        let values = (0 ..< 4).map { _ in generator.next() }
        #expect(Set(values).count == 4)
    }
}
