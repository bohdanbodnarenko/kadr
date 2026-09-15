import AnnotationModel
import CoreGraphics
import QuartzCore
import Testing
@testable import AnnotationRender

@Suite("Editing layer tree")
struct AnnotationLayerFactoryTests {
    @Test("Every drawable annotation gets a layer", arguments: [
        AnnotationCommand.arrow(ArrowSpec(start: .zero, end: CGPoint(x: 50, y: 50))),
        .shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20))),
        .line(LineSpec(start: .zero, end: CGPoint(x: 10, y: 10))),
        .freehand(FreehandSpec(points: [.zero, CGPoint(x: 5, y: 5)])),
        .highlighter(HighlighterSpec(points: [.zero, CGPoint(x: 5, y: 5)])),
        .text(TextSpec(string: "x", rect: CGRect(x: 0, y: 0, width: 20, height: 20))),
        .counter(CounterSpec(center: CGPoint(x: 10, y: 10))),
        .redaction(RedactionSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20))),
        .spotlight(SpotlightSpec(rect: CGRect(x: 10, y: 10, width: 80, height: 60)))
    ])
    func makesLayers(command: AnnotationCommand) throws {
        let layer = try #require(AnnotationLayerFactory.makeLayer(for: command, contentsScale: 2))
        #expect(layer.contentsScale == 2)
        #expect(layer.name == command.id.rawValue.uuidString, "layers must be traceable to their annotation")
    }

    @Test("A crop is chrome, not an object on the canvas")
    func cropHasNoLayer() {
        let crop = AnnotationCommand.crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(AnnotationLayerFactory.makeLayer(for: crop, contentsScale: 2) == nil)
    }

    @Test("Beautify is chrome, not an object on the canvas")
    func beautifyHasNoLayer() {
        let chrome = AnnotationCommand.beautify(BeautifySpec())
        #expect(AnnotationLayerFactory.makeLayer(for: chrome, contentsScale: 2) == nil)
    }

    @Test("Dragging updates the existing layer instead of rebuilding it")
    func updateMutatesInPlace() throws {
        var spec = ShapeSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        let layer = try #require(
            AnnotationLayerFactory.makeLayer(for: .shape(spec), contentsScale: 2) as? CAShapeLayer
        )
        let before = layer.path

        spec.rect = CGRect(x: 50, y: 50, width: 80, height: 80)
        AnnotationLayerFactory.update(layer, for: .shape(spec))

        #expect(layer.path != before)
        #expect(layer.path?.boundingBox == CGRect(x: 50, y: 50, width: 80, height: 80))
    }

    @Test("Updating a shape in place also applies a new stroke width and fill")
    func updateAppliesStrokeAndFill() throws {
        var spec = ShapeSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        let layer = try #require(
            AnnotationLayerFactory.makeLayer(for: .shape(spec), contentsScale: 2) as? CAShapeLayer
        )
        #expect(layer.lineWidth == spec.stroke.width)

        spec.stroke.width = 16
        spec.fill.color = .black.withAlpha(0.4)
        AnnotationLayerFactory.update(layer, for: .shape(spec))

        #expect(layer.lineWidth == 16)
        #expect(layer.fillColor != nil)
    }

    @Test("A highlighter multiplies, so text under it stays readable")
    func highlighterMultiplies() throws {
        let command = AnnotationCommand.highlighter(HighlighterSpec(points: [.zero, CGPoint(x: 50, y: 0)]))
        let layer = try #require(AnnotationLayerFactory.makeLayer(for: command, contentsScale: 2))
        #expect(layer.compositingFilter as? String == "multiplyBlendMode")
    }

    @Test("An open arrow head is not filled in")
    func openArrowIsUnfilled() throws {
        let open = AnnotationCommand.arrow(ArrowSpec(start: .zero, end: CGPoint(x: 50, y: 0), head: .open))
        let filled = AnnotationCommand.arrow(ArrowSpec(start: .zero, end: CGPoint(x: 50, y: 0), head: .filled))

        let openLayer = try #require(
            AnnotationLayerFactory.makeLayer(for: open, contentsScale: 2) as? CAShapeLayer
        )
        let filledLayer = try #require(
            AnnotationLayerFactory.makeLayer(for: filled, contentsScale: 2) as? CAShapeLayer
        )

        #expect(openLayer.fillColor == nil)
        #expect(filledLayer.fillColor != nil)
    }

    @Test("A curved arrow's path is not the straight one")
    func curvedArrowDiffers() {
        let straight = ArrowSpec(start: .zero, end: CGPoint(x: 100, y: 0))
        let curved = ArrowSpec(start: .zero, end: CGPoint(x: 100, y: 0), controlPoint: CGPoint(x: 50, y: 80))

        #expect(AnnotationLayerFactory.arrowPath(straight) != AnnotationLayerFactory.arrowPath(curved))
        #expect(AnnotationLayerFactory.arrowPath(curved).boundingBox.height > 10)
    }

    @Test("A rounded rectangle's corner radius cannot exceed half its shorter side")
    func cornerRadiusIsClamped() {
        let spec = ShapeSpec(
            kind: .roundedRectangle(cornerRadius: 500),
            rect: CGRect(x: 0, y: 0, width: 40, height: 20)
        )
        // A radius larger than the rect would produce an inverted path; clamped it is a
        // capsule, which is what the user sees when they drag the slider to the end.
        #expect(AnnotationLayerFactory.shapePath(spec).boundingBox == CGRect(x: 0, y: 0, width: 40, height: 20))
    }

    @Test("An empty freehand stroke makes an empty path rather than crashing")
    func emptyStroke() {
        #expect(AnnotationLayerFactory.strokePath([]).isEmpty)
    }

    @Test("Resizing a counter updates the badge layer, not only its frame")
    func counterUpdateRedraws() throws {
        var spec = CounterSpec(number: 8, center: CGPoint(x: 40, y: 40), radius: 18)
        let layer = try #require(
            AnnotationLayerFactory.makeLayer(for: .counter(spec), contentsScale: 2) as? CounterBadgeLayer
        )
        #expect(layer.frame == CGRect(x: 22, y: 22, width: 36, height: 36))

        spec.radius = 40
        AnnotationLayerFactory.update(layer, for: .counter(spec))
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 80, height: 80))
        #expect(layer.bounds.size == CGSize(width: 80, height: 80))
    }

    @Test("More digits get a smaller face so they stay inside the disc")
    func counterFontFitsTheDisc() {
        let one = CounterSpec(number: 8, center: .zero, radius: 18)
        let ten = CounterSpec(number: 10, center: .zero, radius: 18)
        let hundred = CounterSpec(number: 100, center: .zero, radius: 18)
        #expect(CounterRendering.fontSize(for: one) < one.radius * 2)
        #expect(CounterRendering.fontSize(for: ten) == CounterRendering.fontSize(for: one))
        #expect(CounterRendering.fontSize(for: hundred) < CounterRendering.fontSize(for: one))
    }

    @Test("A live blur preview destroys the detail under the box")
    func previewBlurs() throws {
        let image = stripedImage()
        let spec = RedactionSpec(
            rect: CGRect(x: 8, y: 8, width: 48, height: 48),
            style: .blur(radius: 12)
        )
        let preview = try #require(RedactionRasterizer().preview(spec, from: image, scale: 1))
        #expect(preview.width == 48)
        #expect(preview.height == 48)
    }

    /// Nothing outside the box bleeds into its edge (Screendrop's behaviour).
    ///
    /// Padding the blur with the surrounding image smeared a band of whatever sat next to
    /// the box along each edge. The box here is the black half, right up against the white
    /// half; its edge must stay black.
    @Test("A blur uses only the box's own pixels, so its edges do not smear in the surroundings")
    func blurDoesNotBleedInNeighbours() {
        let image = splitToneImage()
        let spec = RedactionSpec(
            rect: CGRect(x: 0, y: 0, width: 16, height: 16),
            style: .blur(radius: 8)
        )
        let result = RedactionRasterizer().apply([spec], to: image, scale: 1)
        let edge = pixel(result, x: 15, y: 8)
        #expect(edge.red < 8, "white from outside the box bled into its edge (\(edge.red))")
        let outside = pixel(result, x: 16, y: 8)
        #expect(outside.red > 245, "pixels outside the box stay the original white")

        if let preview = RedactionRasterizer().preview(spec, from: image, scale: 1) {
            #expect(pixel(preview, x: 15, y: 8).red < 8, "the preview bled too")
        } else {
            Issue.record("the blur preview could not be rendered")
        }
    }

    @Test("A redaction with the capture's pixels shows a real blur, not a grey box")
    func redactionSamplesTheImage() throws {
        let image = stripedImage()
        let spec = RedactionSpec(
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            style: .blur(radius: 12)
        )
        let layer = try #require(AnnotationLayerFactory.makeLayer(
            for: .redaction(spec),
            contentsScale: 1,
            imageScale: 1,
            baseImage: image
        ))
        #expect(layer.contents != nil, "the layer must show sampled pixels")
        #expect(layer.backgroundColor == nil)
        #expect(layer.frame == spec.rect)
        #expect(layer.magnificationFilter == .linear, "a nearest-neighbour Gaussian looks pixelated")
        #expect(layer.minificationFilter == .linear)
    }

    @Test("Moving a redaction re-samples the pixels under the new box")
    func redactionUpdateResamples() throws {
        let image = stripedImage()
        var spec = RedactionSpec(
            rect: CGRect(x: 4, y: 4, width: 20, height: 20),
            style: .pixelate(cellSize: 8)
        )
        let layer = try #require(AnnotationLayerFactory.makeLayer(
            for: .redaction(spec),
            contentsScale: 1,
            imageScale: 1,
            baseImage: image
        ))

        spec.rect = CGRect(x: 40, y: 40, width: 30, height: 30)
        AnnotationLayerFactory.update(layer, for: .redaction(spec), imageScale: 1, baseImage: image)

        #expect(layer.frame == spec.rect)
        #expect(layer.contents != nil)
    }

    @Test("Erase fills with the colour of the region's edge")
    func eraseFillsFromTheEdge() throws {
        let image = splitToneImage(width: 64, height: 64)
        let spec = RedactionSpec(
            rect: CGRect(x: 40, y: 16, width: 16, height: 16),
            style: .erase
        )
        let preview = try #require(RedactionRasterizer().preview(spec, from: image, scale: 1))
        let sample = pixel(preview, x: 8, y: 8)
        #expect(sample.red > 200, "a box on the white half should erase to white, not the black half")

        let burned = RedactionRasterizer().apply([spec], to: image, scale: 1)
        let inside = pixel(burned, x: 48, y: 24)
        #expect(inside.red > 200)
        let left = pixel(burned, x: 8, y: 24)
        #expect(left.red < 40, "pixels outside the box stay the original black")
    }

    /// Erasing a line of light text on a dark background must erase to the background.
    ///
    /// The border of such a box is mostly background with text crossing it. A mean of the
    /// edge lands between the two — a grey slab on a dark terminal; the commonest colour is
    /// the background.
    @Test("Erase over text takes the background, not a mean with the text")
    func eraseIgnoresTextCrossingTheEdge() {
        let width = 64
        let height = 32
        let image = patternImage(width: width, height: height) { x, y in
            // Near-black field. Vertical strokes cross the top and bottom edges the way glyphs
            // cut a box's border; horizontal strokes stay inside. The border is still mostly
            // background — its mean is not (about 0.38).
            let vertical = x % 6 == 3
            let horizontal = y % 7 == 3 && y > 0 && y < height - 1
            return vertical || horizontal ? 250 : 30
        }
        let sample = RedactionRasterizer.dominantEdgeColor(of: image)
        #expect(sample.red < 0.2, "erase came out \(sample.red): it averaged in the text")
    }

    @Test("The preview mosaic holds still for the same annotation")
    func pixelatePreviewIsStable() throws {
        let image = stripedImage()
        let spec = RedactionSpec(rect: CGRect(x: 4, y: 4, width: 48, height: 48), style: .pixelate(cellSize: 8))
        let first = try #require(RedactionRasterizer().preview(spec, from: image, scale: 1))
        let second = try #require(RedactionRasterizer().preview(spec, from: image, scale: 1))
        #expect(first.dataProvider?.data == second.dataProvider?.data)
    }
}

private func stripedImage(width: Int = 80, height: Int = 80) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap")
    }
    for x in stride(from: 0, to: width, by: 4) {
        context.setFillColor(CGColor(gray: (x / 4).isMultiple(of: 2) ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 4, height: height))
    }
    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }
    return image
}

/// A grey image whose level at each pixel comes from `level(x, y)`, top-left origin.
private func patternImage(width: Int, height: Int, level: (Int, Int) -> UInt8) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let value = level(x, y)
            let offset = (y * width + x) * 4
            bytes[offset] = value
            bytes[offset + 1] = value
            bytes[offset + 2] = value
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          )
    else {
        fatalError("Could not create a pattern image")
    }
    return image
}

private func splitToneImage(width: Int = 32, height: Int = 16) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap")
    }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }
    return image
}

/// One pixel read back out of a rendered layer.
///
/// A named type rather than a four-member tuple: the assertions read `pixel.alpha` either
/// way, but a tuple this wide is one reordering away from a test that compares green to blue
/// and passes.
struct SampledPixel: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> SampledPixel {
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
    bytes.initialize(repeating: 0, count: 4)
    defer { bytes.deallocate() }
    guard let context = CGContext(
        data: bytes,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a sampling context")
    }
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return SampledPixel(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
}
