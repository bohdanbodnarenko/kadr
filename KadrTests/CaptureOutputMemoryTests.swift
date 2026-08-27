import CaptureCore
import CoreGraphics
import Foundation
import ImageIO
import MediaExport
import SettingsKit
import Shared
import Testing
@testable import Kadr

/// A 5120×2880 bitmap — the size doc 04 §7 uses as its worked example, roughly 59 MB
/// decoded and nearly twice the agent's entire idle budget.
private func makeFiveKImage() -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: 5120,
        height: 2880,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("Could not create a 5K test image")
    }
    return image
}

@MainActor
@Suite("Full-resolution captures are not retained", .serialized)
struct CaptureOutputMemoryTests {
    private func makeOutput() -> (CaptureOutput, URL) {
        let suite = UUID().uuidString
        guard let store = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        store.removePersistentDomain(forName: suite)

        let save = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-mem-\(UUID().uuidString)", isDirectory: true)
        let settings = AppSettings(store: store)
        settings.saveFolderPath = save.path
        settings.defaultAction = .saveToFolder

        let staging = save.appendingPathComponent("stage", isDirectory: true)
        return (
            CaptureOutput(settings: settings, exporter: CaptureExporter(staging: StagingArea(directory: staging))),
            save
        )
    }

    /// The deterministic form of "a 5K capture leaves RSS within 5 MB of baseline": if
    /// the bitmap is deallocated, the memory is back, whatever the allocator reports.
    @Test("Exporting a 5K capture releases the bitmap (doc 04 §7 rule 2)")
    func doesNotRetainAfterExport() async {
        let (output, save) = makeOutput()
        defer { try? FileManager.default.removeItem(at: save) }

        let probe: () -> AnyObject?

        do {
            let image = makeFiveKImage()
            probe = { [weak image] in image }
            let capture = Capture(
                image: image,
                metadata: CaptureMetadata(
                    source: .display(1),
                    displayID: 1,
                    scale: .retina,
                    pointRect: DisplayRect(x: 0, y: 0, width: 2560, height: 1440),
                    pixelSize: PixelSize(width: 5120, height: 2880),
                    colorSpaceName: nil,
                    frontmostApp: nil
                )
            )
            let result = output.deliver(capture)
            #expect(result?.fileURL != nil, "the capture should still have been written")
        }

        // Give the autorelease pool a turn; ImageIO holds the source briefly.
        for _ in 0 ..< 20 where probe() != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(probe() == nil, "a 5K bitmap survived its export")
    }

    @Test("The written file is the full-resolution capture, not a thumbnail")
    func writesFullResolution() throws {
        let (output, save) = makeOutput()
        defer { try? FileManager.default.removeItem(at: save) }

        let capture = Capture(
            image: makeFiveKImage(),
            metadata: CaptureMetadata(
                source: .display(1),
                displayID: 1,
                scale: .retina,
                pointRect: DisplayRect(x: 0, y: 0, width: 2560, height: 1440),
                pixelSize: PixelSize(width: 5120, height: 2880),
                colorSpaceName: nil,
                frontmostApp: nil
            )
        )
        let url = try #require(output.deliver(capture)?.fileURL)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 5120)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2880)
    }
}
