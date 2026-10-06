import AnnotationModel
import CoreGraphics
import QuartzCore
import Testing
@testable import AnnotationRender

/// Rotated annotations appear where the model says they are — on the canvas and in the
/// export (docs/16 ED-10).
@Suite("Rotated rendering")
struct RotationRenderTests {
    private static let rect = CGRect(x: 60, y: 90, width: 120, height: 40)
    private static let radians = CGFloat.pi / 2

    private func close(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y) < 0.01
    }

    @Test("Each layer turns about the annotation's pivot, whatever its frame", arguments: [
        AnnotationCommand.shape(ShapeSpec(rect: rect, rotation: radians)),
        .freehand(FreehandSpec(points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], rotation: radians)),
        .text(TextSpec(string: "Rotated", rect: rect, rotation: radians)),
        .redaction(RedactionSpec(rect: rect, style: .erase, rotation: radians)),
        .spotlight(SpotlightSpec(rect: rect, rotation: radians))
    ])
    func layersTurnAboutThePivot(command: AnnotationCommand) throws {
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let layer = try #require(AnnotationLayerFactory.makeLayer(for: command, contentsScale: 2))
        host.addSublayer(layer)

        // A point on the layer maps to that point turned about the pivot — which is the
        // pivot itself staying put, and any other point going where the model sends it.
        let pivot = AnnotationHitTesting.rotationPivot(of: command)
        let unturned = CATransform3DIsIdentity(layer.transform)
        #expect(!unturned)
        let pivotInLayer = layerPoint(forUnrotated: pivot, of: layer)
        #expect(close(layer.convert(pivotInLayer, to: host), pivot))

        let corner = CGPoint(x: Self.rect.minX, y: Self.rect.minY)
        let cornerInLayer = layerPoint(forUnrotated: corner, of: layer)
        let expected = AnnotationRotation.rotate(corner, around: pivot, radians: Self.radians)
        #expect(close(layer.convert(cornerInLayer, to: host), expected))
    }

    @Test("Updating a rotated layer in place does not move it")
    func updateKeepsThePlace() throws {
        let command = AnnotationCommand.text(TextSpec(string: "Rotated", rect: Self.rect, rotation: Self.radians))
        let host = CALayer()
        let layer = try #require(AnnotationLayerFactory.makeLayer(for: command, contentsScale: 2))
        host.addSublayer(layer)
        let corner = layerPoint(forUnrotated: Self.rect.origin, of: layer)
        let before = layer.convert(corner, to: host)
        AnnotationLayerFactory.update(layer, for: command)
        AnnotationLayerFactory.update(layer, for: command)
        #expect(close(layer.convert(corner, to: host), before))
    }

    /// Where a canvas point sits in the layer's own coordinates, before its transform.
    private func layerPoint(forUnrotated point: CGPoint, of layer: CALayer) -> CGPoint {
        let anchor = CGPoint(
            x: layer.bounds.minX + layer.anchorPoint.x * layer.bounds.width,
            y: layer.bounds.minY + layer.anchorPoint.y * layer.bounds.height
        )
        return CGPoint(x: point.x - layer.position.x + anchor.x, y: point.y - layer.position.y + anchor.y)
    }

    // MARK: - Export

    private func blank(_ size: Int = 240) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(gray: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context?.makeImage()
    }

    /// The red channel at a top-left point of an image.
    private func red(_ image: CGImage, at point: CGPoint) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(
                x: -point.x,
                y: point.y - CGFloat(image.height) + 1,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            ))
        }
        return pixel[0]
    }

    /// Green, so "red channel low" means "painted".
    private let fill = FillStyle(color: AnnotationColor(red: 0, green: 0.8, blue: 0))

    @Test("The export draws a rotated shape turned, not level")
    func exportRotatesShapes() throws {
        let base = try #require(blank())
        // A wide bar turned a quarter: it now covers what was above and below it.
        let spec = ShapeSpec(rect: Self.rect, stroke: StrokeStyle(width: 0.1), fill: fill, rotation: Self.radians)
        let document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 240, height: 240), scale: 1),
            commands: [.shape(spec)]
        )
        let image = try AnnotationExportRenderer().render(baseImage: base, document: document)
        let centre = CGPoint(x: Self.rect.midX, y: Self.rect.midY)
        #expect(red(image, at: CGPoint(x: centre.x, y: centre.y - 50)) < 60, "turned bar covers above the center")
        #expect(red(image, at: CGPoint(x: Self.rect.minX + 5, y: centre.y)) > 200, "the level bar's end is empty")
    }

    /// Vertical stripes two pixels wide: sharp enough that a blur visibly flattens them.
    private func striped(_ size: Int = 240) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        for x in stride(from: 0, to: size, by: 2) {
            context?.setFillColor(CGColor(gray: (x / 2) % 2 == 0 ? 0 : 1, alpha: 1))
            context?.fill(CGRect(x: x, y: 0, width: 2, height: size))
        }
        return context?.makeImage()
    }

    /// How much neighbouring pixels differ along a short row — high on sharp stripes.
    private func contrast(_ image: CGImage, row: CGFloat, from start: CGFloat) -> Int {
        (0 ..< 8).reduce(0) { total, offset in
            let here = Int(red(image, at: CGPoint(x: start + CGFloat(offset), y: row)))
            let next = Int(red(image, at: CGPoint(x: start + CGFloat(offset) + 1, y: row)))
            return total + abs(here - next)
        }
    }

    @Test("A rotated blur is burned in turned, and only inside the turned rect")
    func exportRotatesRedactions() throws {
        let base = try #require(striped())
        let turned = RedactionSpec(rect: Self.rect, style: .blur(radius: 6), rotation: .pi / 4)
        let image = RedactionRasterizer().apply([turned], to: base, scale: 1)

        // The level rect's corner is outside the turned one: its stripes are untouched.
        let corner = CGPoint(x: Self.rect.minX + 2, y: Self.rect.minY + 2)
        #expect(red(image, at: corner) == red(base, at: corner))
        #expect(contrast(image, row: corner.y, from: corner.x) == contrast(base, row: corner.y, from: corner.x))

        // The middle is inside either way, and the blur has flattened it.
        let middle = CGPoint(x: Self.rect.midX - 4, y: Self.rect.midY)
        #expect(contrast(image, row: middle.y, from: middle.x) < contrast(base, row: middle.y, from: middle.x) / 4)

        // A point the turned rect covers but the level one does not is blurred too: 45
        // points along the bar's own axis, which after the turn is below the level rect.
        let centre = CGPoint(x: Self.rect.midX, y: Self.rect.midY)
        let along = AnnotationRotation.rotate(
            CGPoint(x: centre.x + 45, y: centre.y),
            around: centre,
            radians: .pi / 4
        )
        #expect(along.y > Self.rect.maxY)
        let row = along.y.rounded()
        let start = along.x.rounded() - 4
        #expect(contrast(image, row: row, from: start) < contrast(base, row: row, from: start) / 2)
    }
}
