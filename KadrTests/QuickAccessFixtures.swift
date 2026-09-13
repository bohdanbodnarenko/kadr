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
func ephemeralPinManager() -> PinManager {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-pins-\(UUID().uuidString).json")
    return PinManager(store: PinStore(fileURL: storeURL))
}

@MainActor
func makeManager(
    saveFolder: URL,
    stagingFolder: URL,
    history: HistoryController? = nil,
    pins: PinManager = ephemeralPinManager()
) -> TestHarness {
    let suite = UUID().uuidString
    guard let store = UserDefaults(suiteName: suite) else {
        fatalError("Could not open a throwaway defaults suite")
    }
    store.removePersistentDomain(forName: suite)
    let settings = AppSettings(store: store)
    settings.saveFolderPath = saveFolder.path
    // Past the first capture by default. The one-time tip pauses auto-dismiss while it is
    // up — deliberately, so the card is not taken away from under its own explanation — and
    // a harness that started before it would make every auto-close test a first-run test.
    // `OverlayCoachTipTests` turns it back off and asserts that behaviour on purpose.
    settings.hasSeenQuickAccessTip = true

    let output = CaptureOutput(
        settings: settings,
        exporter: CaptureExporter(staging: StagingArea(directory: stagingFolder))
    )
    return TestHarness(
        manager: QuickAccessManager(
            settings: settings,
            output: output,
            pins: pins,
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

/// Waits for a sequential dismiss cascade to finish (CleanShot §6.3 / 4.7.5).
@MainActor
func waitForEmptyStack(_ manager: QuickAccessManager, timeoutMs: Int = 2_500) async throws {
    let steps = max(1, timeoutMs / 50)
    for _ in 0 ..< steps {
        if manager.items.isEmpty { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Overlay stack did not empty within \(timeoutMs)ms (count=\(manager.items.count))")
}
