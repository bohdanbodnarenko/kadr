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

    /// A restored pin used to decode once for its captured size and again, 120 ms later,
    /// for the size it was restored to.
    @Test("A pin built at a remembered frame decodes once, at that size")
    func restoredFrameDecodesOnce() throws {
        let url = try makeCapture(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let remembered = CGRect(x: 40, y: 40, width: 100, height: 75)
        let panel = try #require(PinPanel(fileURL: url, scale: 2, frame: remembered))
        defer { panel.dismiss() }

        #expect(panel.frame.size == remembered.size)
        #expect(panel.decodeCount == 1)
        panel.applyPersistedState(frame: remembered, alpha: 0.5, clickThrough: false)
        #expect(!panel.hasPendingReload, "the persisted frame must not schedule a second decode")
        #expect(panel.decodeCount == 1)
    }

    @Test("The backing texture is decoded off the main thread and lands on the panel")
    func decodeLandsAsynchronously() async throws {
        let url = try makeCapture()
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = try #require(PinPanel(fileURL: url, scale: 2))
        defer { panel.dismiss() }

        await panel.decodeTask?.value
        let image = try #require(panel.contentView?.subviews.compactMap { $0 as? NSImageView }.first?.image)
        #expect(image.size == panel.frame.size)
    }

    @Test("The drag image keeps the texture's shape inside 256 points", arguments: [
        (1024, 512, NSSize(width: 256, height: 128)),
        (300, 600, NSSize(width: 128, height: 256)),
        (100, 50, NSSize(width: 100, height: 50)),
        (256, 256, NSSize(width: 256, height: 256))
    ])
    func dragImageSize(width: Int, height: Int, expected: NSSize) throws {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        #expect(PinPanel.dragImageSize(for: image) == expected)
    }

    @Test("A pin over a file that is not an image is refused, not crashed")
    func unreadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-pin-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PinPanel(fileURL: url, scale: 2) == nil)
    }

    @Test("Resizing a pin keeps the capture's aspect ratio")
    func keepsAspectRatio() throws {
        let url = try makeCapture(width: 400, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = try #require(PinPanel(fileURL: url, scale: 1))
        defer { panel.dismiss() }

        // `contentAspectRatio` is what AppKit applies to a *user's* live resize; a
        // programmatic `setFrame` bypasses it by design, so asserting on one was testing
        // AppKit rather than the pin, and failed on every run (docs/17 T-REL-7).
        let aspect = panel.contentAspectRatio
        let ratio = aspect.width / max(aspect.height, 1)
        #expect(abs(ratio - 2) < 0.05)
    }
}
