import AppKit
import CaptureCore
import Foundation
import MediaExport
import SettingsKit
import Shared
import Testing
@testable import Kadr

/// The one-time tip over the first capture (docs/03 §2).
///
/// A card in the corner shows a picture and nothing about it says that hovering reveals the
/// actions, that it can be dragged into Slack, or that double-clicking opens the editor. The
/// commonest outcome for a first capture is somebody looking at it, failing to work out what
/// it wants, and waiting for it to disappear.
@MainActor
@Suite("Overlay coach tip", .serialized)
struct OverlayCoachTipTests {
    private func makeHarness() -> TestHarness {
        makeManager(
            saveFolder: temporaryDirectory("save"),
            stagingFolder: temporaryDirectory("stage")
        )
    }

    private func showCard(_ harness: TestHarness) throws -> QuickAccessItem {
        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        return try #require(harness.manager.items.first)
    }

    /// While the tip is up the card must not time out — taking it away from under its own
    /// explanation is the one outcome that teaches nothing.
    @Test("The tip pauses auto-close")
    func tipPausesAutoClose() throws {
        let harness = makeHarness()
        harness.settings.hasSeenQuickAccessTip = false

        let item = try showCard(harness)
        #expect(!harness.manager.isIdleForAutoDismiss(item), "the card could close over its own tip")
    }

    /// Paused, not claimed. Engagement is permanent by design, and a first capture should
    /// still tidy itself away once the tip has been read and the user has moved on.
    @Test("The tip does not permanently claim the card")
    func tipDoesNotEngageTheCard() throws {
        let harness = makeHarness()
        harness.settings.hasSeenQuickAccessTip = false

        let item = try showCard(harness)
        #expect(!harness.manager.isEngaged(item), "the first card would never auto-close again")
    }

    /// Once seen, never again — a tip that reappears is a tip that nags.
    @Test("A second capture gets no tip")
    func secondCaptureHasNoTip() throws {
        let harness = makeHarness()
        harness.settings.hasSeenQuickAccessTip = true

        let item = try showCard(harness)
        #expect(!harness.manager.isShowingCoachTip(for: item))
        #expect(harness.manager.isIdleForAutoDismiss(item), "auto-close stayed paused with no tip up")
    }

    /// Dismissing the card counts the tip as seen: the explanation was on screen, and
    /// showing it again on the next capture would nag.
    @Test("Closing the card marks the tip seen")
    func closingTheCardMarksTheTipSeen() throws {
        let harness = makeHarness()
        harness.settings.hasSeenQuickAccessTip = false

        let item = try showCard(harness)
        harness.manager.dismiss(item)
        #expect(harness.settings.hasSeenQuickAccessTip)
    }
}
