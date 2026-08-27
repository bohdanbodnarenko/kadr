import CaptureCore
import CoreGraphics
import Foundation
import Shared
import Testing

/// These talk to the real ScreenCaptureKit and therefore need a Screen Recording grant,
/// a window server and a display.
///
/// They live in the *app's* test target rather than CaptureCore's on purpose: TCC grants
/// attach to a bundle identity, so only a test hosted inside `Kadr.app` inherits the
/// permission the user gave Kadr. A `swift test` helper process has no grant and would
/// see an empty display list.
///
/// CI has neither a grant nor a window server, so they are opt-in. `xcodebuild` does not
/// pass the shell environment to the test host, so the switch lives on the scheme:
/// **Product → Scheme → Edit Scheme → Test → Arguments**, tick `KADR_TCC_INTEGRATION`.
///
/// Then grant Kadr.app Screen Recording in System Settings → Privacy & Security, and run
/// the tests. Without the grant every one of them fails with `.permissionDenied`, which
/// is itself a useful check of the error mapping but proves nothing about pixels.
///
/// Run them on a real desk before shipping a capture change; they are the only thing
/// that proves the point/pixel maths against actual hardware.
private var integrationEnabled: Bool {
    ProcessInfo.processInfo.environment["KADR_TCC_INTEGRATION"] == "1"
}

@Suite("CaptureEngine against real displays", .enabled(if: integrationEnabled))
struct CaptureEngineIntegrationTests {
    private func makeEngine() -> CaptureEngine {
        CaptureEngine(
            frontmostApplication: FixedFrontmostApplication(
                AppIdentity(name: "Test", bundleIdentifier: "app.kadr.tests")
            ),
            ownBundleIdentifier: nil
        )
    }

    @Test("Shareable content lists at least one display")
    func listsDisplays() async throws {
        let snapshot = try await makeEngine().shareableContent()
        #expect(snapshot.displays.isEmpty == false)
        for display in snapshot.displays {
            #expect(display.scale.factor >= 1)
            #expect(display.frame.isEmpty == false)
        }
    }

    @Test("A freeze returns one image per display, at that display's backing size")
    func freezeMatchesBackingStore() async throws {
        let freezes = try await makeEngine().freezeAllDisplays()
        #expect(freezes.isEmpty == false)

        for freeze in freezes {
            let expected = freeze.geometry.pixelSize
            #expect(freeze.image.width == expected.width, "freeze is not at native resolution")
            #expect(freeze.image.height == expected.height, "freeze is not at native resolution")
        }
    }

    @Test("Freezing every display fits the 80 ms budget (docs/04 §4.2)")
    func freezeIsFast() async throws {
        let engine = makeEngine()
        // Warm the framework up; the budget is about steady-state, not first-touch.
        _ = try await engine.freezeAllDisplays()

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await engine.freezeAllDisplays()
        }
        #expect(elapsed < .milliseconds(80), "freeze took \(elapsed)")
    }

    @Test("A region capture comes back at the requested pixel size")
    func regionIsExact() async throws {
        let engine = makeEngine()
        let snapshot = try await engine.shareableContent()
        let display = try #require(snapshot.displays.first)

        let region = DisplayRect(
            x: display.frame.minX + 10,
            y: display.frame.minY + 10,
            width: 200,
            height: 100
        )
        let capture = try await engine.captureRegion(region, on: display.displayID)
        let expected = display.pixels(for: display.localRect(for: region))

        #expect(capture.image.width == expected.width)
        #expect(capture.image.height == expected.height)
        #expect(capture.metadata.displayID == display.displayID)
        #expect(capture.metadata.scale == display.scale)
    }

    @Test("A region off the edge of its display is refused rather than mis-cropped")
    func regionOffDisplay() async throws {
        let engine = makeEngine()
        let snapshot = try await engine.shareableContent()
        let display = try #require(snapshot.displays.first)
        let elsewhere = DisplayRect(x: display.frame.maxX + 500, y: 0, width: 100, height: 100)

        await #expect(throws: CaptureError.regionOutsideDisplay) {
            _ = try await engine.captureRegion(elsewhere, on: display.displayID)
        }
    }

    @Test("An unknown display or window is reported as gone")
    func missingSources() async throws {
        let engine = makeEngine()
        await #expect(throws: CaptureError.displayNotFound(999_999)) {
            _ = try await engine.captureDisplay(999_999)
        }
        await #expect(throws: CaptureError.windowNotFound(999_999)) {
            _ = try await engine.captureWindow(999_999)
        }
    }

    @Test("A window captures unoccluded, with alpha when asked for it")
    func windowCapture() async throws {
        let engine = makeEngine()
        let snapshot = try await engine.shareableContent(onScreenWindowsOnly: true)
        let window = try #require(snapshot.windows.first { $0.isUserWindow })

        let capture = try await engine.captureWindow(
            window.id,
            options: WindowCaptureOptions(includesShadow: false, transparentBackground: true)
        )
        #expect(capture.image.width > 0)
        #expect(capture.metadata.windowTitle == window.title)
        #expect(capture.image.alphaInfo != .none, "transparent mode must produce a real alpha channel")
    }
}
