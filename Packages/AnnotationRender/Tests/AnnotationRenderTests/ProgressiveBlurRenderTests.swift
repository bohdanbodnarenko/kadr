import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// The progressive blur, in pixels (docs/09 U1.3).
///
/// Measured as local contrast rather than by comparing to a reference image: the exact
/// output of `CIMaskedVariableBlur` is Core Image's business and may change, but "the
/// corners lost their detail and the middle kept it" is the effect, and it is checkable.
@Suite("Progressive blur rendering")
struct ProgressiveBlurRenderTests {
    private let renderer = AnnotationExportRenderer()

    /// Vertical stripes, so blur is measurable as a loss of contrast anywhere.
    ///
    /// Twelve points wide rather than two: a two-pixel stripe is destroyed by a one-pixel
    /// blur, so a fine fixture reads "fully blurred" everywhere the mask is above almost
    /// zero and cannot tell a gentle falloff from a harsh one.
    private func makeStripedImage(size: Int = 240) -> CGImage {
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
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 0, to: size, by: 24) {
            context.fill(CGRect(x: x, y: 0, width: 12, height: size))
        }
        guard let image = context.makeImage() else {
            fatalError("Could not create a test capture")
        }
        return image
    }

    /// Mean absolute difference between neighbouring pixels: high for sharp stripes, low
    /// once they have been blurred away.
    private func localContrast(_ image: CGImage, in rect: CGRect) -> Double {
        let width = Int(rect.width)
        let height = Int(rect.height)
        let bytesPerRow = width * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        bytes.initialize(repeating: 0, count: bytesPerRow * height)
        defer { bytes.deallocate() }

        guard let context = CGContext(
            data: bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a sampling context")
        }
        context.draw(
            image,
            in: CGRect(
                x: -rect.minX,
                y: -(CGFloat(image.height) - rect.maxY),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )

        var total = 0.0
        var samples = 0
        for y in 0 ..< height {
            for x in 1 ..< width {
                let here = Double(bytes[y * bytesPerRow + x * 4])
                let before = Double(bytes[y * bytesPerRow + (x - 1) * 4])
                total += abs(here - before)
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }

    private func document(_ commands: [AnnotationCommand], size: CGFloat = 240) -> AnnotationDocument {
        AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: size, height: size), scale: 1),
            commands: commands
        )
    }

    // MARK: - The effect reaches the file

    /// The whole point, in one assertion: sharp in the middle, soft at the edges.
    @Test("A radial blur softens the corners and keeps the middle sharp")
    func radialKeepsTheMiddleSharp() throws {
        let spec = ProgressiveBlurSpec(radius: .relative(0.08), focusRadius: 0.15, falloffRadius: 0.6)
        let image = try renderer.render(baseImage: makeStripedImage(), document: document([.progressiveBlur(spec)]))

        let middle = localContrast(image, in: CGRect(x: 100, y: 100, width: 40, height: 40))
        let corner = localContrast(image, in: CGRect(x: 4, y: 4, width: 40, height: 40))
        #expect(middle > corner * 2, "middle \(middle), corner \(corner)")
    }

    @Test("Inverting it softens the middle instead")
    func invertedSoftensTheMiddle() throws {
        let spec = ProgressiveBlurSpec(
            radius: .relative(0.08),
            focusRadius: 0.15,
            falloffRadius: 0.6,
            isInverted: true
        )
        let image = try renderer.render(baseImage: makeStripedImage(), document: document([.progressiveBlur(spec)]))

        let middle = localContrast(image, in: CGRect(x: 100, y: 100, width: 40, height: 40))
        let corner = localContrast(image, in: CGRect(x: 4, y: 4, width: 40, height: 40))
        #expect(corner > middle * 2, "middle \(middle), corner \(corner)")
    }

    @Test("A directional blur softens one end and not the other")
    func directionalIsOneSided() throws {
        let spec = ProgressiveBlurSpec(
            shape: .directional,
            radius: .relative(0.08),
            focusRadius: 0.1,
            falloffRadius: 0.9,
            angleDegrees: 90
        )
        let image = try renderer.render(baseImage: makeStripedImage(), document: document([.progressiveBlur(spec)]))

        let top = localContrast(image, in: CGRect(x: 100, y: 4, width: 40, height: 30))
        let bottom = localContrast(image, in: CGRect(x: 100, y: 206, width: 40, height: 30))
        #expect(top > bottom * 3, "top \(top), bottom \(bottom)")
    }

    @Test("A blur with no strength changes nothing")
    func zeroRadiusIsANoOp() throws {
        let plain = try renderer.render(baseImage: makeStripedImage(), document: document([]))
        let blurred = try renderer.render(
            baseImage: makeStripedImage(),
            document: document([.progressiveBlur(ProgressiveBlurSpec(radius: .zero))])
        )
        let sampled = CGRect(x: 20, y: 20, width: 60, height: 60)
        #expect(abs(localContrast(plain, in: sampled) - localContrast(blurred, in: sampled)) < 0.5)
    }

    // MARK: - Extent

    /// "Capture only" leaves the beautify backdrop crisp; "whole canvas" does not. That
    /// difference is the setting's entire meaning.
    @Test("A clipped blur leaves the backdrop alone")
    func clippedBlurSparesTheBackdrop() throws {
        let commands: [AnnotationCommand] = [
            .beautify(BeautifySpec(
                padding: .points(40),
                cornerRadius: .zero,
                backdrop: .solid(AnnotationColor(red: 0, green: 1, blue: 0)),
                shadow: .none,
                aspect: .original,
                alignment: .center,
                sticksToEdges: false
            )),
            .progressiveBlur(ProgressiveBlurSpec(
                extent: .clipped,
                radius: .relative(0.1),
                focusRadius: 0,
                falloffRadius: 0.3
            ))
        ]
        let image = try renderer.render(baseImage: makeStripedImage(), document: document(commands))

        // The backdrop is a flat fill, so its contrast is zero either way; what a scene
        // blur would do is smear the card's edge into it. Sample right at the boundary.
        let edge = localContrast(image, in: CGRect(x: 30, y: 100, width: 20, height: 40))
        #expect(edge < 30, "the padding should stay flat, got \(edge)")
    }

    @Test("A scene blur covers the backdrop too")
    func sceneBlurCoversEverything() throws {
        let commands: [AnnotationCommand] = [
            .beautify(BeautifySpec(
                padding: .points(40),
                cornerRadius: .zero,
                backdrop: .solid(AnnotationColor(red: 0, green: 1, blue: 0)),
                shadow: .none,
                aspect: .original,
                alignment: .center,
                sticksToEdges: false
            )),
            .progressiveBlur(ProgressiveBlurSpec(
                extent: .scene,
                radius: .relative(0.12),
                focusRadius: 0,
                falloffRadius: 0.3
            ))
        ]
        let image = try renderer.render(baseImage: makeStripedImage(), document: document(commands))
        let clipped = try renderer.render(
            baseImage: makeStripedImage(),
            document: document([commands[0], .progressiveBlur(ProgressiveBlurSpec(
                extent: .clipped,
                radius: .relative(0.12),
                focusRadius: 0,
                falloffRadius: 0.3
            ))])
        )

        // The card's edge against the backdrop: a scene blur smears it, a clipped one
        // leaves it hard.
        let sceneEdge = localContrast(image, in: CGRect(x: 32, y: 100, width: 16, height: 40))
        let clippedEdge = localContrast(clipped, in: CGRect(x: 32, y: 100, width: 16, height: 40))
        #expect(sceneEdge < clippedEdge, "scene \(sceneEdge), clipped \(clippedEdge)")
    }

    // MARK: - Composition

    @Test("A blur composes with the camera")
    func blurWithCamera() throws {
        let commands: [AnnotationCommand] = [
            .progressiveBlur(ProgressiveBlurSpec(radius: .relative(0.06))),
            .camera(.lean)
        ]
        let image = try renderer.render(baseImage: makeStripedImage(), document: document(commands))
        #expect(image.width == 240)
        #expect(image.height == 240)
    }

    @Test("The canvas keeps its size whatever the blur does", arguments: [
        ProgressiveBlurSpec.focus,
        .fade,
        .obscureCentre
    ])
    func canvasSizeIsUnchanged(spec: ProgressiveBlurSpec) throws {
        let image = try renderer.render(baseImage: makeStripedImage(), document: document([.progressiveBlur(spec)]))
        #expect(image.width == 240)
        #expect(image.height == 240)
    }

    /// A redaction is a security claim; a progressive blur is decoration. They must not
    /// interfere, and in particular the decorative one must not be what hides a secret.
    @Test("A redaction still burns in with a progressive blur present")
    func redactionSurvives() throws {
        let commands: [AnnotationCommand] = [
            .redaction(RedactionSpec(rect: CGRect(x: 20, y: 20, width: 60, height: 60))),
            .progressiveBlur(.focus)
        ]
        let image = try renderer.render(baseImage: makeStripedImage(), document: document(commands))
        let redacted = localContrast(image, in: CGRect(x: 30, y: 30, width: 40, height: 40))
        let elsewhere = localContrast(image, in: CGRect(x: 110, y: 110, width: 40, height: 40))
        #expect(redacted < elsewhere, "the redaction should still be the strongest blur")
    }
}
