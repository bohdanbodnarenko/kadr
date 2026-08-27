import CoreGraphics
import Foundation
import Shared
import Testing
@testable import CaptureCore

private let builtIn = DisplayGeometry(
    displayID: 1,
    frame: DisplayRect(x: 0, y: 0, width: 2560, height: 1440),
    scale: .retina
)

private let external = DisplayGeometry(
    displayID: 2,
    frame: DisplayRect(x: 2560, y: 0, width: 1920, height: 1080),
    scale: .oneToOne
)

private func snapshot(windows: [WindowInfo] = []) -> ShareableContentSnapshot {
    ShareableContentSnapshot(displays: [builtIn, external], windows: windows)
}

private func window(id: CGWindowID, frame: DisplayRect, layer: Int = 0) -> WindowInfo {
    WindowInfo(
        id: id,
        title: "Window \(id)",
        applicationName: "Test",
        bundleIdentifier: "com.example.test",
        processID: 42,
        frame: frame,
        isOnScreen: true,
        layer: layer
    )
}

@Suite("Shareable content snapshot")
struct ShareableContentSnapshotTests {
    @Test("Displays are found by ID")
    func lookupByID() {
        #expect(snapshot().display(1) == builtIn)
        #expect(snapshot().display(99) == nil)
    }

    @Test("A rect wholly on one display picks that display")
    func containedRect() {
        let rect = DisplayRect(x: 100, y: 100, width: 200, height: 200)
        #expect(snapshot().display(containing: rect) == builtIn)
    }

    @Test("A rect straddling two displays picks the one it covers most")
    func straddlingRect() {
        // 300 points wide, 100 of them on the built-in display and 200 on the external.
        let rect = DisplayRect(x: 2460, y: 100, width: 300, height: 100)
        #expect(snapshot().display(containing: rect) == external)
    }

    @Test("A rect on no display picks none")
    func offscreenRect() {
        let rect = DisplayRect(x: -5000, y: -5000, width: 100, height: 100)
        #expect(snapshot().display(containing: rect) == nil)
    }

    @Test("Only real windows count as user windows")
    func userWindowFiltering() {
        let real = window(id: 1, frame: DisplayRect(x: 0, y: 0, width: 800, height: 600))
        let menuBar = window(id: 2, frame: DisplayRect(x: 0, y: 0, width: 2560, height: 24), layer: 24)
        let sliver = window(id: 3, frame: DisplayRect(x: 0, y: 0, width: 10, height: 10))

        #expect(real.isUserWindow)
        #expect(menuBar.isUserWindow == false)
        #expect(sliver.isUserWindow == false)
    }
}

@Suite("Relaunch helper")
struct RelaunchHelperTests {
    private final class FakeRelauncher: ApplicationRelaunching, @unchecked Sendable {
        var launchError: (any Error)?
        private(set) var launchedURLs: [URL] = []
        private(set) var terminateCount = 0

        func relaunch(bundleURL: URL) async throws {
            if let launchError {
                throw launchError
            }
            launchedURLs.append(bundleURL)
        }

        func terminate() {
            terminateCount += 1
        }
    }

    @Test("Relaunching starts the new instance and then quits this one")
    func relaunchOrder() async throws {
        let relauncher = FakeRelauncher()
        let url = URL(fileURLWithPath: "/Applications/Kadr.app")
        let helper = RelaunchHelper(relauncher: relauncher, bundleURL: url)

        try await helper.relaunchForNewGrant()

        #expect(relauncher.launchedURLs == [url])
        #expect(relauncher.terminateCount == 1)
    }

    @Test("A failed launch leaves the running app alive")
    func failedLaunchDoesNotTerminate() async {
        let relauncher = FakeRelauncher()
        relauncher.launchError = CaptureError.noCaptureSource
        let helper = RelaunchHelper(relauncher: relauncher, bundleURL: URL(fileURLWithPath: "/tmp/Kadr.app"))

        await #expect(throws: CaptureError.self) {
            try await helper.relaunchForNewGrant()
        }
        #expect(relauncher.terminateCount == 0, "quitting after a failed relaunch would leave no app running")
    }
}
