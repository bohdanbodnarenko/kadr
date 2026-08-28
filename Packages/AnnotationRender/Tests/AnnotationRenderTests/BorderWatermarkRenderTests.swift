import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// The ring and the mark, in pixels (docs/09 U1.4).
@Suite("Border and watermark rendering")
struct BorderWatermarkRenderTests {
    private let renderer = AnnotationExportRenderer()

    private func makeImage(size: Int = 200, red: CGFloat = 1) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a test capture")
        }
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else {
            fatalError("Could not create a test capture")
        }
        return image
    }

    private struct Sample {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> Sample {
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
        return Sample(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }

    private func document(_ commands: [AnnotationCommand], size: CGFloat = 200) -> AnnotationDocument {
        AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: size, height: size), scale: 1),
            commands: commands
        )
    }

    // MARK: - The border

    /// The ring, the capture and the backdrop are three distinct colours, sampled in
    /// order from the outside in.
    @Test("A border is a ring of its own colour between the backdrop and the capture")
    func borderIsARing() throws {
        let spec = BeautifySpec(
            padding: .points(30),
            cornerRadius: .zero,
            backdrop: .solid(AnnotationColor(red: 0, green: 1, blue: 0)),
            shadow: .none,
            aspect: .original,
            border: BeautifyBorder(thickness: .points(10), color: AnnotationColor(red: 0, green: 0, blue: 1)),
            alignment: .center,
            sticksToEdges: false
        )
        let image = try renderer.render(baseImage: makeImage(), document: document([.beautify(spec)]))

        // Canvas is 200 + 2*10 (border) + 2*30 (padding) = 280.
        #expect(image.width == 280)
        let backdrop = pixel(image, x: 5, y: 140)
        let ring = pixel(image, x: 35, y: 140)
        let capture = pixel(image, x: 140, y: 140)

        #expect(backdrop.green > 200, "outside is backdrop, got \(backdrop)")
        #expect(ring.blue > 200, "then the ring, got \(ring)")
        #expect(capture.red > 200, "then the capture, got \(capture)")
    }

    @Test("Turning a border on does not shrink the capture")
    func borderDoesNotShrinkTheCapture() throws {
        func captureWidth(_ border: BeautifyBorder) throws -> Int {
            let spec = BeautifySpec(
                padding: .zero,
                cornerRadius: .zero,
                backdrop: .solid(AnnotationColor(red: 0, green: 1, blue: 0)),
                shadow: .none,
                aspect: .original,
                border: border,
                alignment: .center,
                sticksToEdges: false
            )
            let image = try renderer.render(baseImage: makeImage(), document: document([.beautify(spec)]))
            // Red *and not white*: the ring's own colour must not be counted as capture,
            // which is why the border below is blue rather than the default white.
            return (0 ..< image.width).count { x in
                let sample = pixel(image, x: x, y: image.height / 2)
                return sample.red > 200 && sample.blue < 100 && sample.green < 100
            }
        }

        let bordered = BeautifyBorder(thickness: .points(12), color: AnnotationColor(red: 0, green: 0, blue: 1))
        #expect(try captureWidth(.none) == 200)
        #expect(try captureWidth(bordered) == 200)
    }

    @Test("A border survives the perspective camera")
    func borderWithCamera() throws {
        let commands: [AnnotationCommand] = [
            .beautify(BeautifySpec(
                padding: .points(20),
                cornerRadius: .zero,
                backdrop: .solid(AnnotationColor(red: 0, green: 1, blue: 0)),
                shadow: .none,
                aspect: .original,
                border: BeautifyBorder(thickness: .points(10), color: AnnotationColor(red: 0, green: 0, blue: 1)),
                alignment: .center,
                sticksToEdges: false
            )),
            .camera(AnnotationCameraSpec(tiltDegrees: 20, fieldOfViewDegrees: 50, zoom: 0.7))
        ]
        let image = try renderer.render(baseImage: makeImage(), document: document(commands))

        let blue = (0 ..< image.width).count { x in pixel(image, x: x, y: image.height / 2).blue > 150 }
        #expect(blue > 0, "the ring should still be in the projected card")
    }

    // MARK: - The watermark

    @Test("A watermark marks the image")
    func watermarkDraws() throws {
        let spec = WatermarkSpec(
            text: "CONFIDENTIAL",
            fontSize: .relative(0.1),
            color: AnnotationColor(red: 0, green: 0, blue: 1),
            opacity: 1,
            rotationDegrees: 0
        )
        let plain = try renderer.render(baseImage: makeImage(), document: document([]))
        let marked = try renderer.render(baseImage: makeImage(), document: document([.watermark(spec)]))

        func blueCount(_ image: CGImage) -> Int {
            var total = 0
            for y in stride(from: 0, to: image.height, by: 2) {
                for x in stride(from: 0, to: image.width, by: 2) where pixel(image, x: x, y: y).blue > 100 {
                    total += 1
                }
            }
            return total
        }
        #expect(blueCount(plain) == 0)
        #expect(blueCount(marked) > 20, "the mark should be visible")
    }

    @Test("An empty watermark draws nothing at all")
    func emptyWatermarkIsANoOp() throws {
        let plain = try renderer.render(baseImage: makeImage(), document: document([]))
        let marked = try renderer.render(
            baseImage: makeImage(),
            document: document([.watermark(WatermarkSpec(text: ""))])
        )
        #expect(pixel(plain, x: 100, y: 100).red == pixel(marked, x: 100, y: 100).red)
    }

    /// A tiled watermark exists to survive a crop, which means it has to reach the corners.
    @Test("A tiled watermark reaches the corners")
    func tiledReachesTheCorners() throws {
        var spec = WatermarkSpec.tiled("KADR")
        spec.color = AnnotationColor(red: 0, green: 0, blue: 1)
        spec.opacity = 1
        spec.fontSize = .relative(0.08)
        let image = try renderer.render(baseImage: makeImage(), document: document([.watermark(spec)]))

        func hasMark(_ region: CGRect) -> Bool {
            for y in Int(region.minY) ..< Int(region.maxY) {
                for x in Int(region.minX) ..< Int(region.maxX) where pixel(image, x: x, y: y).blue > 100 {
                    return true
                }
            }
            return false
        }
        #expect(hasMark(CGRect(x: 0, y: 0, width: 60, height: 60)), "the top-left corner should be marked")
        #expect(hasMark(CGRect(x: 140, y: 140, width: 60, height: 60)), "as should the bottom-right")
    }

    @Test("Opacity does what it says", arguments: [CGFloat(0.2), 1])
    func opacityChangesTheMark(opacity: CGFloat) throws {
        var spec = WatermarkSpec(
            text: "KADR",
            fontSize: .relative(0.15),
            color: AnnotationColor(red: 0, green: 0, blue: 1),
            rotationDegrees: 0
        )
        spec.opacity = opacity
        spec.placement = .center
        let image = try renderer.render(baseImage: makeImage(), document: document([.watermark(spec)]))

        var strongest: UInt8 = 0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                strongest = max(strongest, pixel(image, x: x, y: y).blue)
            }
        }
        if opacity == 1 {
            #expect(strongest > 200, "a solid mark should be solid, got \(strongest)")
        } else {
            #expect(strongest < 120, "a faint mark should be faint, got \(strongest)")
        }
    }

    /// A watermark that the camera could tilt would be a watermark somebody removes by
    /// turning the camera off. It goes on last, over everything.
    @Test("A watermark is drawn over the perspective camera, not through it")
    func watermarkIsNotProjected() throws {
        var spec = WatermarkSpec(
            text: "KADR",
            fontSize: .relative(0.15),
            color: AnnotationColor(red: 0, green: 0, blue: 1),
            opacity: 1,
            rotationDegrees: 0
        )
        spec.placement = .center

        let upright = try renderer.render(baseImage: makeImage(), document: document([.watermark(spec)]))
        let tilted = try renderer.render(
            baseImage: makeImage(),
            document: document([
                .watermark(spec),
                .camera(AnnotationCameraSpec(tiltDegrees: 45, fieldOfViewDegrees: 80))
            ])
        )

        func markRow(_ image: CGImage, y: Int) -> Int {
            (0 ..< image.width).count { x in pixel(image, x: x, y: y).blue > 100 }
        }
        // Same width through the middle of the mark: the camera did not touch it.
        #expect(markRow(upright, y: 100) == markRow(tilted, y: 100))
    }

    @Test("Copy-without-annotations leaves the watermark off")
    func withoutAnnotationsDropsTheWatermark() throws {
        var spec = WatermarkSpec(text: "KADR", fontSize: .relative(0.15), opacity: 1)
        spec.color = AnnotationColor(red: 0, green: 0, blue: 1)
        let bare = try renderer.render(
            baseImage: makeImage(),
            document: document([.watermark(spec)]),
            includeAnnotations: false
        )
        for y in stride(from: 0, to: bare.height, by: 3) {
            for x in stride(from: 0, to: bare.width, by: 3) {
                #expect(pixel(bare, x: x, y: y).blue < 60)
            }
        }
    }
}
