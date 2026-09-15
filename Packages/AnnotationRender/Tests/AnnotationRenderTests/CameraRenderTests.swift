import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// The perspective camera, in pixels (docs/09 U1.2).
///
/// The math has its own table-driven tests; these check the part the math cannot: that the
/// projection actually reaches the exported file, that annotations lean *with* the capture
/// rather than floating upright over it, and that a camera the renderer cannot apply
/// degrades to a flat draw rather than to an empty canvas.
@Suite("Camera rendering")
struct CameraRenderTests {
    private let renderer = AnnotationExportRenderer()

    /// A capture with a distinct top half and bottom half, so a projection is visible.
    private func makeSplitImage(size: Int = 200) -> CGImage {
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
        // CoreGraphics is bottom-left, so this fills the visual bottom first.
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
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

    // MARK: - The projection reaches the file

    /// The capture's top half is red and its bottom half blue. A projection that never
    /// happened leaves those halves exactly where they were.
    @Test("An identity camera changes nothing")
    func identityCameraIsAFlatDraw() throws {
        let plain = try renderer.render(baseImage: makeSplitImage(), document: document([]))
        let withCamera = try renderer.render(
            baseImage: makeSplitImage(),
            document: document([.camera(.identity)])
        )

        #expect(plain.width == withCamera.width)
        let plainTop = pixel(plain, x: 100, y: 20)
        let cameraTop = pixel(withCamera, x: 100, y: 20)
        #expect(plainTop.red == cameraTop.red)
        #expect(plainTop.blue == cameraTop.blue)
    }

    @Test("A tilted camera moves pixels off the corners")
    func tiltEmptiesTheCorners() throws {
        // Zoomed in so the tilt pushes the top corners past the canvas edge and leaves
        // transparent backdrop behind them.
        let spec = AnnotationCameraSpec(tiltDegrees: 40, fieldOfViewDegrees: 70, zoom: 0.8)
        let image = try renderer.render(baseImage: makeSplitImage(), document: document([.camera(spec)]))

        let topLeft = pixel(image, x: 2, y: 2)
        let middle = pixel(image, x: 100, y: 100)
        #expect(topLeft.alpha < 40, "a tilt should leave the corner empty, got \(topLeft)")
        #expect(middle.alpha > 200, "and the middle should still be covered, got \(middle)")
    }

    @Test("The exported canvas grows to hold a camera that leans off the capture")
    func canvasGrowsForALeaningCamera() throws {
        let spec = AnnotationCameraSpec(tiltDegrees: 45, fieldOfViewDegrees: 80, zoom: 1.6)
        let image = try renderer.render(baseImage: makeSplitImage(), document: document([.camera(spec)]))
        #expect(image.width >= 200)
        #expect(image.height >= 200)
    }

    /// The ordering that matters: the card is flattened *then* projected, so an arrow drawn
    /// on the capture leans with it. Drawing annotations after the projection would leave
    /// them upright over a tilted screenshot.
    @Test("Annotations are projected along with the capture")
    func annotationsLeanWithTheCapture() throws {
        let mark = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 60, y: 0, width: 80, height: 24),
            fill: FillStyle(color: AnnotationColor(red: 0, green: 1, blue: 0))
        ))
        let flat = try renderer.render(baseImage: makeSplitImage(), document: document([mark]))
        let tilted = try renderer.render(
            baseImage: makeSplitImage(),
            document: document([mark, .camera(AnnotationCameraSpec(tiltDegrees: 45, fieldOfViewDegrees: 80))])
        )

        func greenRow(_ image: CGImage, y: Int) -> Int {
            (0 ..< image.width).count { x in
                let sample = pixel(image, x: x, y: y)
                return sample.green > 150 && sample.red < 120
            }
        }

        let flatWidth = greenRow(flat, y: 8)
        let tiltedWidth = greenRow(tilted, y: 8)
        #expect(flatWidth > 60, "the marker should be wide when flat, got \(flatWidth)")
        #expect(tiltedWidth != flatWidth, "a tilt should foreshorten the marker too, got \(tiltedWidth)")
    }

    // MARK: - With beautify

    @Test("A camera inside a beautified canvas leans within the frame")
    func cameraInsideBeautify() throws {
        let backdrop = AnnotationColor(red: 0, green: 1, blue: 0)
        let commands: [AnnotationCommand] = [
            .beautify(BeautifySpec(
                padding: .points(40),
                cornerRadius: .zero,
                backdrop: .solid(backdrop),
                shadow: .none,
                aspect: .original,
                alignment: .center,
                sticksToEdges: false
            )),
            .camera(AnnotationCameraSpec(tiltDegrees: 35, fieldOfViewDegrees: 70))
        ]
        let image = try renderer.render(baseImage: makeSplitImage(), document: document(commands))

        #expect(image.width == 280, "beautify still decides the canvas")
        // The padding is still the backdrop.
        let corner = pixel(image, x: 4, y: 4)
        #expect(corner.green > 200, "the backdrop should be untouched, got \(corner)")

        /// And the capture is no longer a plain rectangle: the row just inside the card's
        /// top edge is narrower than the one near its bottom.
        func coveredRow(_ y: Int) -> Int {
            (0 ..< image.width).count { x in pixel(image, x: x, y: y).green < 150 }
        }
        #expect(coveredRow(45) < coveredRow(230), "the far edge should be foreshortened")
    }

    @Test("Camera and crop compose: the crop decides what is projected")
    func cameraWithCrop() throws {
        let commands: [AnnotationCommand] = [
            .crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 100, height: 100))),
            .camera(.lean)
        ]
        let image = try renderer.render(baseImage: makeSplitImage(), document: document(commands))
        #expect(image.width >= 100)
        #expect(image.height >= 100)
        #expect(image.width < 200, "the crop, not the full capture, is what was projected")
    }

    // MARK: - Degenerate input

    @Test("A camera on a tiny capture renders rather than failing")
    func tinyCapture() throws {
        let document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 2, height: 2), scale: 1),
            commands: [.camera(.hero)]
        )
        let image = try renderer.render(baseImage: makeSplitImage(size: 2), document: document)
        #expect(image.width == 2)
    }

    @Test("Copy-without-annotations still applies the camera")
    func withoutAnnotationsKeepsTheCamera() throws {
        let commands: [AnnotationCommand] = [
            .shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 200, height: 200), fill: FillStyle(color: .black))),
            .camera(AnnotationCameraSpec(tiltDegrees: 40, fieldOfViewDegrees: 70, zoom: 0.8))
        ]
        let bare = try renderer.render(
            baseImage: makeSplitImage(),
            document: document(commands),
            includeAnnotations: false
        )
        let corner = pixel(bare, x: 2, y: 2)
        #expect(corner.alpha < 40, "the camera is canvas chrome, not an annotation")
    }
}
