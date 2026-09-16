import CoreGraphics
import CoreImage
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Frames from a source that is not at the size the plan was built for (docs/10 R1.1).
///
/// The preview decodes small and plans small; a compositor may be handed whatever the track
/// holds. Either way the composer has to produce the frame the export would, only smaller.
@Suite("Studio composer source size")
struct StudioComposerSourceSizeTests {
    private let sourceSize = CGSize(width: 400, height: 200)

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, size: CGSize) throws -> CIImage {
        let image = try #require(BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
        })
        return CIImage(cgImage: image)
    }

    /// Left half red, right half blue.
    private func halved(size: CGSize) throws -> CIImage {
        let image = try #require(BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        })
        return CIImage(cgImage: image)
    }

    /// RGBA bytes of an image, top row first.
    private func bytes(of image: CIImage, size: CGSize) throws -> [UInt8] {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(StudioRenderContext.shared.createCGImage(
            image,
            from: CGRect(origin: .zero, size: size),
            format: .RGBA8,
            colorSpace: StudioRenderContext.sRGB
        ))
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return pixels
    }

    // MARK: - Source size

    @Test("A source already at the recorded size is passed through untouched")
    func normalizedSourceIsIdentity() throws {
        let edit = StudioEdit.untouched(duration: 1)
        let composer = StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: InputTelemetry()
        )
        let source = try halved(size: sourceSize)
        #expect(composer.normalizedSource(source) === source)
        let infinite = CIImage(color: .red)
        #expect(composer.normalizedSource(infinite) === infinite)
    }

    @Test("A downscaled decode is scaled back to the recorded size", arguments: [
        CGSize(width: 200, height: 100),
        CGSize(width: 100, height: 50),
        CGSize(width: 800, height: 400),
        CGSize(width: 333, height: 170)
    ])
    func normalizedSourceScales(decoded: CGSize) throws {
        let edit = StudioEdit.untouched(duration: 1)
        let composer = StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: InputTelemetry()
        )
        let small = try halved(size: decoded).transformed(by: CGAffineTransform(translationX: 7, y: -3))
        let normalized = composer.normalizedSource(small)
        #expect(abs(normalized.extent.minX) < 0.001 && abs(normalized.extent.minY) < 0.001)
        #expect(abs(normalized.extent.width - sourceSize.width) < 0.001)
        #expect(abs(normalized.extent.height - sourceSize.height) < 0.001)

        // And the frame built from it is the frame built from the full-size source.
        let frame = try bytes(of: composer.frame(at: 0, source: small, camera: nil), size: sourceSize)
        let width = Int(sourceSize.width)
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8) {
            let offset = (y * width + x) * 4
            return (frame[offset], frame[offset + 2])
        }
        #expect(pixel(50, 100) == (255, 0), "the left of the frame is not the left of the recording")
        #expect(pixel(350, 100) == (0, 255), "the right of the frame is not the right of the recording")
        #expect(pixel(5, 5) == (255, 0), "the recording does not reach the corner")
        #expect(pixel(394, 194) == (0, 255), "the recording does not reach the far corner")
    }

    // MARK: - Capped output

    /// The preview asks for a small plan; the source stays in recorded pixels.
    @Test("A capped plan produces a capped frame that the source covers completely")
    func cappedPlanIsCovered() throws {
        var zoomed = StudioEdit.untouched(duration: 2)
        zoomed.zooms = [ZoomCue(start: 0, duration: 2, magnification: 2)]
        for edit in [StudioEdit.untouched(duration: 2), zoomed] {
            let plan = StudioRenderPlan(edit: edit, sourceSize: sourceSize, maxLongestEdge: 160)
            #expect(plan.outputSize == CGSize(width: 160, height: 80))
            let composer = StudioFrameComposer(plan: plan, edit: edit, telemetry: InputTelemetry())
            let frame = try composer.frame(at: 1.5, source: solid(0, 1, 0, size: sourceSize), camera: nil)
            #expect(frame.extent == CGRect(origin: .zero, size: plan.outputSize))

            let pixels = try bytes(of: frame, size: plan.outputSize)
            let uncovered = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 1] < 250 }
            #expect(uncovered.isEmpty, "\(uncovered.count) pixels are not the source")
        }
    }
}
