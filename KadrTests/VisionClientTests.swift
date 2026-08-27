import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Shared
import Testing
import UniformTypeIdentifiers
@testable import Kadr

/// Renders text into an image the recogniser can actually read.
private func makeTextImage(_ string: String) -> CGImage {
    let width = 600
    let height = 160
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
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
    let attributed = NSAttributedString(string: string, attributes: [
        .init(kCTFontAttributeName as String): font,
        .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ])
    context.textPosition = CGPoint(x: 20, y: 60)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)

    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }
    return image
}

/// Exercises the real XPC round-trip to the embedded helper.
///
/// This runs inside `Kadr.app`, which is what makes it possible: an XPC service is looked
/// up inside its containing bundle, so only a test hosted by the agent can reach it.
@MainActor
@Suite("Vision helper over XPC", .serialized)
struct VisionClientTests {
    @Test("The helper recognises text and sends it back")
    func roundTrip() async throws {
        let client = VisionClient()
        defer { client.disconnect() }

        let analysis = try await client.analyze(
            makeTextImage("Kadr OCR"),
            options: TextRecognitionOptions()
        )
        let text = analysis.text(preservingLineBreaks: true)

        #expect(text.localizedCaseInsensitiveContains("Kadr"), "helper returned \(text.debugDescription)")
    }

    @Test("A typical region comes back inside the one-second budget (docs/03 §1.7)")
    func withinBudget() async throws {
        let client = VisionClient()
        defer { client.disconnect() }
        let image = makeTextImage("Warm up the helper")

        // The first call pays for spawning the process and loading Vision's models; the
        // budget in doc 03 §1.7 is about the steady state a user actually experiences.
        _ = try? await client.analyze(image, options: TextRecognitionOptions())

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await client.analyze(image, options: TextRecognitionOptions())
        }
        #expect(elapsed < .seconds(1), "recognition took \(elapsed)")
    }

    @Test("Line-break handling follows the request")
    func lineBreaks() async throws {
        let client = VisionClient()
        defer { client.disconnect() }

        let analysis = try await client.analyze(
            makeTextImage("Kadr OCR"),
            options: TextRecognitionOptions(preservesLineBreaks: false)
        )
        #expect(analysis.text(preservingLineBreaks: false).contains("\n") == false)
    }

    @Test("Disconnecting is safe to repeat, so the helper can always be let go")
    func disconnectIsIdempotent() {
        let client = VisionClient()
        client.disconnect()
        client.disconnect()
    }
}

/// The helper's whole value is that it goes away again (docs/04 §1, §7 rule 4).
///
/// Slow by nature — it waits out the 30-second idle timeout — so it is opt-in through the
/// same scheme switch as the other long checks: **Product → Scheme → Edit Scheme → Test →
/// Arguments**, tick `KADR_SLOW_TESTS`.
@MainActor
@Suite("Vision helper lifetime", .enabled(if: ProcessInfo.processInfo.environment["KADR_SLOW_TESTS"] == "1"))
struct VisionHelperLifetimeTests {
    @Test("The helper exits once it has been idle, giving its Vision models back")
    func exitsWhenIdle() async throws {
        let client = VisionClient()
        _ = try await client.analyze(makeTextImage("wake up"), options: TextRecognitionOptions())
        #expect(isHelperRunning(), "the helper should be running right after a recognition")

        client.disconnect()

        // The timeout plus a margin for the process actually going.
        let deadline = VisionServiceName.idleTimeout + 10
        var waited = 0.0
        while waited < deadline, isHelperRunning() {
            try? await Task.sleep(for: .seconds(1))
            waited += 1
        }
        #expect(isHelperRunning() == false, "the helper was still running after \(Int(waited))s idle")
    }

    private func isHelperRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "HelperTools"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
