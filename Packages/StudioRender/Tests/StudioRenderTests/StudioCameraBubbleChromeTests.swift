import CoreGraphics
import CoreImage
import Foundation
import StudioSession
import Testing
@testable import StudioRender

@Suite("Studio camera bubble chrome")
struct StudioCameraBubbleChromeTests {
    private let sourceSize = CGSize(width: 400, height: 200)

    @Test("A bubble sits on the recording with a drop, not stamped flush")
    func bubbleCastsAShadow() throws {
        var edit = StudioEdit.untouched(duration: 4)
        edit.camera = CameraBubble(
            placement: .centre,
            sizeFraction: 0.4,
            marginFraction: 0,
            roundness: 1,
            isVisible: true
        )
        let camera = try #require(BitmapCanvas.image(width: 160, height: 160) { context in
            context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        })
        let source = try #require(BitmapCanvas.image(width: 400, height: 200) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        })
        let composed = StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: InputTelemetry()
        ).frame(at: 0, source: CIImage(cgImage: source), camera: CIImage(cgImage: camera))

        let width = Int(sourceSize.width)
        let height = Int(sourceSize.height)
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
        let cgImage = try #require(StudioRenderContext.shared.createCGImage(composed, from: composed.extent))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height))

        let rect = edit.camera.frame(in: sourceSize)
        let below = luminance(pixels, width: width, x: Int(rect.midX) - 10, y: Int(rect.maxY) + 4)
        let far = luminance(pixels, width: width, x: 20, y: 20)
        #expect(below < far, "expected a drop under the bubble, below=\(below) far=\(far)")
    }

    private func luminance(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> Int {
        let offset = (y * width + x) * 4
        guard offset + 2 < pixels.count else { return 0 }
        return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
    }
}
