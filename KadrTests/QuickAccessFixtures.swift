import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import HistoryKit
import MediaExport
import SettingsKit
import Shared
import Testing
import UniformTypeIdentifiers
@testable import Kadr

// Shared fixtures for the overlay and output-policy suites.
//
// They live apart from any one suite because three files now build the same manager;
// a fixture that only one test file can see is a fixture the next one reimplements.

func temporaryDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeCapture() -> Capture {
    guard let context = CGContext(
        data: nil,
        width: 20,
        height: 10,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("Could not create a test capture")
    }
    return Capture(
        image: image,
        metadata: CaptureMetadata(
            source: .display(1),
            displayID: 1,
            scale: .retina,
            pointRect: DisplayRect(x: 0, y: 0, width: 10, height: 5),
            pixelSize: PixelSize(width: 20, height: 10),
            colorSpaceName: nil,
            frontmostApp: AppIdentity(name: "Tester", bundleIdentifier: "app.kadr.tests")
        )
    )
}

/// Everything a Quick Access test needs, wired to throwaway folders and defaults.
@MainActor
struct TestHarness {
    let manager: QuickAccessManager
    let settings: AppSettings
    let output: CaptureOutput
}

@MainActor
func makeManager(
    saveFolder: URL,
    stagingFolder: URL,
    history: HistoryController? = nil
) -> TestHarness {
    let suite = UUID().uuidString
    guard let store = UserDefaults(suiteName: suite) else {
        fatalError("Could not open a throwaway defaults suite")
    }
    store.removePersistentDomain(forName: suite)
    let settings = AppSettings(store: store)
    settings.saveFolderPath = saveFolder.path

    let output = CaptureOutput(
        settings: settings,
        exporter: CaptureExporter(staging: StagingArea(directory: stagingFolder))
    )
    return TestHarness(
        manager: QuickAccessManager(
            settings: settings,
            output: output,
            pins: PinManager(),
            history: history
        ),
        settings: settings,
        output: output
    )
}

@MainActor
func throwawayDefaults() -> UserDefaults {
    let suite = UUID().uuidString
    guard let store = UserDefaults(suiteName: suite) else {
        fatalError("Could not open a throwaway defaults suite")
    }
    store.removePersistentDomain(forName: suite)
    return store
}
