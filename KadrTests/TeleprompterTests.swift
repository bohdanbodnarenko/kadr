import AppKit
import Foundation
import OverlayKit
import SettingsKit
import StudioSession
import Testing
@testable import Kadr

/// The prompter as the agent runs it (docs/08).
///
/// The reading, the pacing and the following are tested in StudioSession, where they are
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

    // MARK: - Scrolling

    private func scriptView(text: String, width: CGFloat = 400) -> TeleprompterScriptView {
        let view = TeleprompterScriptView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        view.script = TeleprompterScript(text: text)
        return view
    }

    /// The scroll has to be continuous. Offsetting by whole lines holds the text still
    /// until the reader crosses into the next one and then jumps it a whole line, which is
    /// the stutter the fractional position exists to avoid.
    @Test("The text moves between words, not only between lines")
    func scrollIsContinuous() {
        let view = scriptView(text: "one two three four five six seven eight nine ten")
        view.position = 0
        let atStart = view.scrollOffsetForTesting
        view.position = 0.5
        let halfAWordLater = view.scrollOffsetForTesting
        #expect(atStart != halfAWordLater, "the text did not move for half a word")
    }

    @Test("Reading on scrolls the text upward")
    func scrollsUpward() {
        let view = scriptView(text: (0 ..< 40).map { "word\($0)" }.joined(separator: " "))
        view.position = 0
        let early = view.scrollOffsetForTesting
        view.position = 20
        #expect(view.scrollOffsetForTesting < early, "reading on did not move the text up")
    }

    // MARK: - Only drawing what shows

    /// A prompter holds a whole script — a thousand lines is an ordinary talk — and
    /// visiting all of them to reject all but a handful is work repeated every frame of a
    /// recording.
    @Test("Only the lines that fit on screen are drawn")
    func drawsOnlyVisibleLines() {
        let view = scriptView(text: (0 ..< 500).map { "line \($0)" }.joined(separator: "\n"))
        view.position = 250
        let visible = view.visibleRangeForTesting
        #expect(visible.count < 40, "\(visible.count) lines would be drawn for a screen that fits a handful")
        #expect(!visible.isEmpty)
    }

    /// `position` counts words, and each line here is two of them — so the reader at word
    /// 100 is on line 50. Getting that wrong in a test is how a prompter ships scrolled to
    /// twice the right place.
    @Test("The visible lines surround the reader's own line")
    func visibleLinesSurroundTheReader() {
        let view = scriptView(text: (0 ..< 200).map { "line \($0)" }.joined(separator: "\n"))
        view.position = 100
        let visible = view.visibleRangeForTesting
        #expect(visible.contains(50), "the reader's line is not among the ones being drawn")
    }

    @Test("A reader at the very start does not ask for lines above the script")
    func visibleRangeAtTheStart() {
        let view = scriptView(text: (0 ..< 50).map { "line \($0)" }.joined(separator: "\n"))
        view.position = 0
        let visible = view.visibleRangeForTesting
        #expect(visible.lowerBound >= 0)
        #expect(visible.upperBound <= 50)
    }

    @Test("A reader at the very end does not ask for lines past it")
    func visibleRangeAtTheEnd() {
        let view = scriptView(text: (0 ..< 50).map { "line \($0)" }.joined(separator: "\n"))
        view.position = 49
        let visible = view.visibleRangeForTesting
        #expect(visible.upperBound <= 50)
    }

    @Test("An empty script asks for nothing")
    func visibleRangeOfNothing() {
        let view = scriptView(text: "")
        #expect(view.visibleRangeForTesting.isEmpty)
    }
}
