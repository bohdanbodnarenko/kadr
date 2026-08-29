import AppKit
import Foundation
import OverlayKit
import SettingsKit
import StudioCore
import Testing
@testable import Kadr

/// The prompter as the agent runs it (docs/08).
///
/// The reading, the pacing and the following are tested in StudioCore, where they are
/// arithmetic. What is left here is what only the agent can be wrong about: that the panel
/// stays out of the recording, that it appears only when there is something to read, and
/// that it exists solely while a recording does.
@MainActor
@Suite("Teleprompter")
struct TeleprompterTests {
    /// Its own defaults suite per test, so one test's script is not another's.
    private func settings() -> AppSettings {
        let suite = UserDefaults(suiteName: "app.kadr.tests.teleprompter.\(UUID().uuidString)")
        return AppSettings(store: suite ?? .standard)
    }

    // MARK: - Staying out of the recording

    /// The failure that makes the whole feature useless: a prompter in the file is a
    /// recording somebody has to make again.
    @Test("The panel excludes itself from captures")
    func panelIsExcluded() {
        let panel = TeleprompterPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        panel.orderFrontRegardless()
        defer {
            panel.retire()
            panel.orderOut(nil)
        }
        #expect(CaptureExclusionRegistry.shared.excludedWindowIDs.contains(CGWindowID(panel.windowNumber)))
    }

    @Test("Retiring the panel takes it off the exclusion list")
    func retiringUnregisters() {
        let panel = TeleprompterPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        panel.orderFrontRegardless()
        panel.retire()
        defer { panel.orderOut(nil) }
        #expect(!CaptureExclusionRegistry.shared.excludedWindowIDs.contains(CGWindowID(panel.windowNumber)))
    }

    /// Taking focus is the one thing a prompter must never do: the user is demonstrating
    /// another app, and stealing key status changes what they are showing.
    @Test("The panel never takes focus")
    func panelNeverTakesFocus() {
        let panel = TeleprompterPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { panel.orderOut(nil) }
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    /// A prompter has to sit where the reader's eyes want it, which is usually under the
    /// camera — so unlike Kadr's other overlays this one moves.
    @Test("The panel can be dragged")
    func panelIsMovable() {
        let panel = TeleprompterPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { panel.orderOut(nil) }
        #expect(panel.isMovable)
        #expect(panel.isMovableByWindowBackground)
    }

    // MARK: - Placement

    /// A script at the bottom of the screen films somebody looking down, which is the exact
    /// problem a prompter is meant to solve.
    @Test("A prompter that has never been placed goes near the top of the screen")
    func defaultPlacementIsHigh() throws {
        let panel = TeleprompterPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { panel.orderOut(nil) }
        panel.positionOnScreen(nil)

        let screen = try #require(NSScreen.main)
        #expect(panel.frame.midY > screen.visibleFrame.midY, "the script is below the middle of the screen")
    }

    @Test("A remembered position is used")
    func rememberedPlacement() throws {
        let screen = try #require(NSScreen.main)
        let saved = NSRect(x: screen.visibleFrame.minX + 50, y: screen.visibleFrame.minY + 60, width: 500, height: 180)
        let panel = TeleprompterPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { panel.orderOut(nil) }
        panel.positionOnScreen(saved)
        #expect(panel.frame == saved)
    }

    /// A position saved against a display that has since been unplugged would put the
    /// script somewhere nobody can see it.
    @Test("A position on a display that is gone falls back to the default")
    func offscreenPlacementIsIgnored() {
        let panel = TeleprompterPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { panel.orderOut(nil) }
        panel.positionOnScreen(NSRect(x: -9000, y: -9000, width: 500, height: 180))
        #expect(NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
    }

    // MARK: - Only while recording

    @Test("Nothing appears when the prompter is off")
    func offShowsNothing() {
        let settings = settings()
        settings.teleprompterEnabled = false
        settings.teleprompterScript = "Something to read"

        let controller = TeleprompterController(settings: settings)
        controller.start()
        defer { controller.stop() }
        #expect(!controller.isShowing)
    }

    /// Somebody who left the setting on and the script blank wants nothing on screen, not
    /// an empty panel reminding them.
    @Test("Nothing appears when there is no script")
    func emptyScriptShowsNothing() {
        let settings = settings()
        settings.teleprompterEnabled = true
        settings.teleprompterScript = "   \n  "

        let controller = TeleprompterController(settings: settings)
        controller.start()
        defer { controller.stop() }
        #expect(!controller.isShowing)
    }

    @Test("The prompter appears with a script and goes away when recording stops")
    func lifecycle() {
        let settings = settings()
        settings.teleprompterEnabled = true
        settings.teleprompterScript = "Welcome to Kadr, the screen recorder."

        let controller = TeleprompterController(settings: settings)
        controller.start()
        #expect(controller.isShowing)

        controller.stop()
        #expect(!controller.isShowing, "the prompter outlived the recording")
    }

    @Test("Starting twice does not stack two prompters")
    func startIsIdempotent() {
        let settings = settings()
        settings.teleprompterEnabled = true
        settings.teleprompterScript = "One two three."

        let controller = TeleprompterController(settings: settings)
        controller.start()
        controller.start()
        defer { controller.stop() }
        #expect(controller.isShowing)
    }

    @Test("Stopping without starting is harmless")
    func stopWithoutStart() {
        let controller = TeleprompterController(settings: settings())
        controller.stop()
        #expect(!controller.isShowing)
    }

    // MARK: - Remembering where it was left

    @Test("The panel's position is remembered for next time")
    func positionIsSaved() {
        let settings = settings()
        settings.teleprompterEnabled = true
        settings.teleprompterScript = "Something to read aloud."

        let controller = TeleprompterController(settings: settings)
        controller.start()
        controller.stop()

        let saved = settings.teleprompterFrame ?? ""
        #expect(!saved.isEmpty, "the prompter forgot where it was")
        #expect(NSRectFromString(saved).width > 0)
    }
}
