import CoreGraphics
import CoreImage
import Foundation
import StudioSession
import Testing
@testable import StudioRender

@Suite("Studio click ripples")
struct StudioClickOverlayTests {
    private let sourceSize = CGSize(width: 400, height: 200)
    private let press = CGPoint(x: 200, y: 100)

    @Test("A larger ripple scale covers more of the frame")
    func clickScaleGrowsTheRipple() throws {
        var telemetry = InputTelemetry(
            pointer: [
                PointerSample(time: 0, position: press),
                PointerSample(time: 4, position: press)
            ]
        )
        telemetry.clicks = [ClickEvent(time: 2, position: press)]

        var smallEdit = StudioEdit.untouched(duration: 4)
        smallEdit.showsClicks = true
        smallEdit.showsCursor = false
        smallEdit.clickScale = 1

        var largeEdit = smallEdit
        largeEdit.clickScale = 3

        let small = try render(smallEdit, telemetry: telemetry)
        let large = try render(largeEdit, telemetry: telemetry)
        #expect(
            whiteness(in: large) > whiteness(in: small),
            "a 3× ripple should paint more white than the default"
        )
    }

    @Test("A colored ripple is that color, not always white")
    func clickColorTintsTheRipple() throws {
        var telemetry = InputTelemetry(
            pointer: [
                PointerSample(time: 0, position: press),
                PointerSample(time: 4, position: press)
            ]
        )
        telemetry.clicks = [ClickEvent(time: 2, position: press)]

        var whiteEdit = StudioEdit.untouched(duration: 4)
        whiteEdit.showsClicks = true
        whiteEdit.showsCursor = false
        whiteEdit.clickScale = 3

        var redEdit = whiteEdit
        redEdit.clickColor = StudioColor(red: 1, green: 0, blue: 0)

        let white = try render(whiteEdit, telemetry: telemetry, fill: .blue)
        let red = try render(redEdit, telemetry: telemetry, fill: .blue)
        #expect(
            redness(in: red) > redness(in: white),
            "a red ripple should paint more red than a white one on a blue field"
        )
    }

    @Test("A filled ripple covers more of the frame than an outline")
    func filledCoversMoreThanOutline() throws {
        var telemetry = InputTelemetry(
            pointer: [
                PointerSample(time: 0, position: press),
                PointerSample(time: 4, position: press)
            ]
        )
        telemetry.clicks = [ClickEvent(time: 2, position: press)]

        var outline = StudioEdit.untouched(duration: 4)
        outline.showsClicks = true
        outline.showsCursor = false
        outline.clickScale = 3
        outline.clickStyle = .outline

        var filled = outline
        filled.clickStyle = .filled

        let ring = try render(outline, telemetry: telemetry)
        let disc = try render(filled, telemetry: telemetry)
        #expect(
            whiteness(in: disc) > whiteness(in: ring),
            "a filled disc should paint more of the scene than a ring"
        )
    }

    private enum Fill {
        case red
        case blue
    }

    private func render(
        _ edit: StudioEdit,
        telemetry: InputTelemetry,
        fill: Fill = .red
    ) throws -> [UInt8] {
        let source = try #require(BitmapCanvas.image(width: 400, height: 200) { context in
            switch fill {
            case .red:
                context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            case .blue:
                context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            }
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        })
        let composed = StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: telemetry
        ).frame(at: 2.1, source: CIImage(cgImage: source), camera: nil)

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
        let image = try #require(StudioRenderContext.shared.createCGImage(composed, from: composed.extent))
        context.draw(image, in: CGRect(origin: .zero, size: sourceSize))
        return pixels
    }

    private func whiteness(in pixels: [UInt8]) -> Int {
        channelCount(in: pixels) { offset in
            pixels[offset + 2] > 15 && pixels[offset] > 15
        }
    }

    private func redness(in pixels: [UInt8]) -> Int {
        channelCount(in: pixels) { offset in
            pixels[offset] > 150 && pixels[offset + 2] < 80
        }
    }

    private func channelCount(in pixels: [UInt8], where matches: (Int) -> Bool) -> Int {
        let width = Int(sourceSize.width)
        let height = Int(sourceSize.height)
        var count = 0
        let radius = 40
        for y in Int(press.y) - radius ... Int(press.y) + radius where y >= 0 && y < height {
            for x in Int(press.x) - radius ... Int(press.x) + radius where x >= 0 && x < width {
                if matches((y * width + x) * 4) {
                    count += 1
                }
            }
        }
        return count
    }
}
