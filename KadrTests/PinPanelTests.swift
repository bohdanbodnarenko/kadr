import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Kadr

/// Pin windows (docs/03 §4, docs/07 M9, docs/09 U0.5).
///
/// The review's finding: the pin re-decoded its capture from disk on every frame of a live
/// resize and every scroll tick. On a 5K screenshot that is a full JPEG/PNG decode per
/// screen refresh — the pin stutters and the agent's memory spikes while the user is
/// simply dragging a corner.
@MainActor
@Suite("Pin panel", .serialized)
struct PinPanelTests {
    /// A real PNG on disk, since the pin loads through ImageIO.
    private func makeCapture(width: Int = 400, height: Int = 300) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-pin-\(UUID().uuidString).png")
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.featureUnsupported)
        }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The M9 failure, stated as a budget: a live resize is many frame changes and must
    /// not be many decodes.
    @Test("A burst of resizes does not decode the capture again and again")
    func resizeDoesNotDecodePerFrame() throws {
        let url = try makeCapture()
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = try #require(PinPanel(fileURL: url, scale: 2))
        defer { panel.dismiss() }

        let initial = panel.decodeCount
        for step in 1 ... 60 {
            panel.setFrame(
                CGRect(x: 0, y: 0, width: 200 + CGFloat(step), height: 150 + CGFloat(step) * 0.75),
                display: false
            )
        }
        #expect(panel.decodeCount == initial, "sixty frames of a drag must not be sixty decodes")
    }

    @Test("The sharp texture arrives once the resize settles")
    func settlingReloads() throws {
        let url = try makeCapture()
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = try #require(PinPanel(fileURL: url, scale: 2))
        defer { panel.dismiss() }

        let initial = panel.decodeCount
        panel.setFrame(CGRect(x: 0, y: 0, width: 60, height: 45), display: false)
        panel.reloadBackingImage()
        #expect(panel.decodeCount == initial + 1, "a settled size should be resolved sharply")
    }

    /// The pin asks for no more pixels than it shows, so shrinking one gives the memory
    /// back rather than holding the capture at full size (docs/03 §4).
    @Test("A resize to the same texture size decodes nothing at all")
    func sameTargetIsFree() throws {
        let url = try makeCapture()
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = try #require(PinPanel(fileURL: url, scale: 2))
        defer { panel.dismiss() }

        panel.setFrame(CGRect(x: 0, y: 0, width: 100, height: 75), display: false)
        panel.reloadBackingImage()
        let settled = panel.decodeCount

        // Same longest edge, different origin: nothing to fetch.
        panel.setFrame(CGRect(x: 40, y: 40, width: 100, height: 75), display: false)
        panel.reloadBackingImage()
        #expect(panel.decodeCount == settled)
    }

    @Test("A pin over a file that is not an image is refused, not crashed")
    func unreadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-pin-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PinPanel(fileURL: url, scale: 2) == nil)
    }
}
