import AppKit
import CaptureCore
import Foundation
import MediaExport
import SettingsKit
import Shared
import Testing
@testable import Kadr

/// The card overlay's manners (docs/03 §2, docs/09 U2.1).
@MainActor
@Suite("Overlay engagement", .serialized)
struct OverlayEngagementTests {
    private func showCard(_ harness: TestHarness) throws -> QuickAccessItem {
        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        return try #require(harness.manager.items.first)
    }

    private func makeHarness(timeout: OverlayTimeout = .tenSeconds) -> TestHarness {
        let harness = makeManager(
            saveFolder: temporaryDirectory("save"),
            stagingFolder: temporaryDirectory("stage")
        )
        harness.settings.overlayTimeout = timeout
        return harness
    }

    // MARK: - Engagement

    /// Opening the editor claims the card. Hovering must not, or a timeout setting does
    /// nothing the moment the pointer crosses the thumbnail (docs/03 §2).
    @Test("Opening the editor cancels auto-close for good")
    func engagementCancelsAutoClose() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        #expect(!harness.manager.isEngaged(item))

        harness.manager.noteEngagement(with: item)
        #expect(harness.manager.isEngaged(item))

        // Re-arming must not bring it back: the card has been claimed.
        harness.manager.scheduleAutoDismiss(for: item)
        #expect(harness.manager.isEngaged(item))
        harness.manager.autoDismissIfIdle(item)
        #expect(harness.manager.items.contains { $0.id == item.id })
        harness.manager.dismissAll()
    }

    @Test("Hovering pauses auto-close without claiming the card")
    func hoverPausesWithoutEngaging() throws {
        let harness = makeHarness()
        let item = try showCard(harness)

        harness.manager.setHovered(item, hovering: true)
        #expect(harness.manager.isHovered(item))
        #expect(!harness.manager.isEngaged(item))
        #expect(!harness.manager.isIdleForAutoDismiss(item))

        harness.manager.autoDismissIfIdle(item)
        #expect(harness.manager.items.contains { $0.id == item.id }, "hover must not dismiss")

        harness.manager.setHovered(item, hovering: false)
        #expect(harness.manager.isIdleForAutoDismiss(item))
        harness.manager.autoDismissIfIdle(item)
        #expect(harness.manager.items.isEmpty)
    }

    @Test("Dragging pauses auto-close")
    func dragPausesAutoClose() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.beginDrag(for: item)
        #expect(!harness.manager.isIdleForAutoDismiss(item))
        harness.manager.autoDismissIfIdle(item)
        #expect(harness.manager.items.count == 1)
        harness.manager.endDrag(for: item)
        harness.manager.autoDismissIfIdle(item)
        #expect(harness.manager.items.isEmpty)
    }

    @Test("Engagement is per card, not per overlay")
    func engagementIsPerCard() throws {
        let harness = makeHarness()
        let first = try showCard(harness)
        let second = try showCard(harness)

        harness.manager.noteEngagement(with: second)
        #expect(harness.manager.isEngaged(second))
        #expect(!harness.manager.isEngaged(first))
        harness.manager.dismissAll()
    }

    @Test("Engaging twice is harmless")
    func engagingTwice() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.noteEngagement(with: item)
        harness.manager.noteEngagement(with: item)
        #expect(harness.manager.isEngaged(item))
        harness.manager.dismissAll()
    }

    // MARK: - Peek

    @Test("Cards start expanded")
    func startsExpanded() {
        #expect(!makeHarness().manager.isPeeking)
    }

    /// Peeking tucks the cards away and leaves a tab. Both are mounted in the same panel,
    /// so this is a flag the stack animates on, and the items stay put (docs/03 §2).
    @Test("A flick to the edge collapses the cards to a tab")
    func peekingCollapses() throws {
        let harness = makeHarness()
        _ = try showCard(harness)

        harness.manager.setPeeking(true)
        #expect(harness.manager.isPeeking)
        #expect(harness.manager.items.count == 1, "peeking must not lose the card")

        harness.manager.setPeeking(false)
        #expect(!harness.manager.isPeeking)
        #expect(harness.manager.items.count == 1)
        harness.manager.dismissAll()
    }

    @Test("Setting the same state twice is a no-op")
    func peekingIsIdempotent() throws {
        let harness = makeHarness()
        _ = try showCard(harness)
        harness.manager.setPeeking(true)
        harness.manager.setPeeking(true)
        #expect(harness.manager.isPeeking)
        harness.manager.setPeeking(false)
        harness.manager.dismissAll()
    }

    /// Opening a capture in the editor retires its card — but only if an editor opened.
    ///
    /// The card is the only copy of that capture the overlay has. Retiring it for a launch
    /// that did nothing (no editor embedded in the bundle, or a failure) would take the
    /// capture off the screen with nothing opened to show for it. The test bundle has no
    /// embedded editor, so this is that case exactly.
    @Test("A failed editor launch leaves the card where it is")
    func failedEditorLaunchKeepsTheCard() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        // A launcher that cannot open anything, standing in for a build with no editor
        // embedded — and keeping the test from starting a real one.
        harness.manager.editor = EditorLauncher(editorURL: nil)
        #expect(!harness.manager.editor.isAvailable)

        harness.manager.annotate(item)

        #expect(harness.manager.items.count == 1, "the card went for an editor that never opened")
        #expect(!harness.manager.isPeeking, "opening the editor no longer hides the other cards")
        harness.manager.dismissAll()
    }

    /// A recording opens its *session directory* in the studio, which matches no card's
    /// `fileURL` — so the card was left sitting over the studio window it belongs to.
    @Test("A card is retired even when the editor was handed another URL")
    func retiresCardOpenedByAnotherURL() throws {
        let harness = makeHarness()
        let item = try showCard(harness)

        harness.manager.retireCard(item)

        #expect(harness.manager.items.isEmpty)
    }

    @Test("Retiring a card that has already gone does nothing")
    func retiringATwiceDismissedCardIsSafe() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.dismiss(item)

        harness.manager.retireCard(item)
        harness.manager.retireCard(nil)

        #expect(harness.manager.items.isEmpty)
    }

    /// The overlay is not a second copy of what is already open in a window (docs/03 §2).
    @Test("Opening the editor retires that card and leaves the others")
    func editorRetiresOnlyItsOwnCard() throws {
        let harness = makeHarness()
        let first = try showCard(harness)
        let second = try showCard(harness)
        #expect(harness.manager.items.count == 2)

        // What the launcher's completion does on success, without launching anything.
        harness.manager.noteEngagement(with: second)
        harness.manager.dismiss(second)

        #expect(harness.manager.items.map(\.id) == [first.id])
        #expect(!harness.manager.isPeeking)
        // Dismissed, not deleted: the capture is still on disk and still recoverable.
        #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        #expect(harness.manager.recentlyClosed.contains { $0.id == second.id })
        harness.manager.dismissAll()
    }

    @Test("Peeking with nothing on screen does nothing")
    func peekingEmptyIsANoOp() {
        let harness = makeHarness()
        harness.manager.setPeeking(true)
        #expect(!harness.manager.isPeeking)
        #expect(harness.manager.overlayPanel == nil, "nothing to show means no window at all")
    }

    @Test("A new capture expands a peeked stack")
    func newCaptureExpandsPeek() throws {
        let harness = makeHarness()
        _ = try showCard(harness)
        harness.manager.setPeeking(true)
        #expect(harness.manager.isPeeking)

        _ = try showCard(harness)
        #expect(!harness.manager.isPeeking)
        #expect(harness.manager.items.count == 2)
        harness.manager.dismissAll()
    }

    @Test("Dismissing from the overlay keeps the file")
    func dismissFromCloseKeepsTheFile() throws {
        let harness = makeHarness()
        harness.settings.defaultAction = .saveToFolder
        let item = try showCard(harness)
        let path = item.fileURL.path
        harness.manager.dismiss(item)
        #expect(harness.manager.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Dismissing the last peeked card tears the tab down")
    func lastPeekedCardTearsDownTheTab() async throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setPeeking(true)
        harness.manager.dismiss(item)
        #expect(!harness.manager.isPeeking)
        // The last card takes the panel with it: an agent with nothing to show owns no
        // windows (CLAUDE.md rule 2). Awaited, because the tab slides out first
        // (docs/16 OUT-15) — the panel is what the slide is drawn in, so it outlives the
        // dismissal by the length of the animation.
        await waitUntil { harness.manager.overlayPanel == nil }
        #expect(harness.manager.overlayPanel == nil)
    }
}
