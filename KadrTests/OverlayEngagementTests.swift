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

    /// A card someone has reached for stops being disposable. Having it vanish mid-thought
    /// is what makes people turn auto-close off entirely.
    @Test("Touching a card cancels its auto-close for good")
    func engagementCancelsAutoClose() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        #expect(!harness.manager.isEngaged(item))

        harness.manager.noteEngagement(with: item)
        #expect(harness.manager.isEngaged(item))

        // Re-arming must not bring it back: the card has been claimed.
        harness.manager.scheduleAutoDismiss(for: item)
        #expect(harness.manager.isEngaged(item))
        harness.manager.dismissAll()
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

    /// Peeking rather than hiding: hide-and-restore is a race, and either mistake loses a
    /// card or flashes it over the editor.
    @Test("Opening the editor collapses the cards to a tab")
    func peekingCollapses() throws {
        let harness = makeHarness()
        _ = try showCard(harness)

        harness.manager.setPeeking(true)
        #expect(harness.manager.isPeeking)
        #expect(harness.manager.items.count == 1, "peeking must not lose the card")

        harness.manager.setPeeking(false)
        #expect(!harness.manager.isPeeking)
        harness.manager.dismissAll()
    }

    @Test("Setting the same state twice is a no-op")
    func peekingIsIdempotent() {
        let harness = makeHarness()
        harness.manager.setPeeking(true)
        harness.manager.setPeeking(true)
        #expect(harness.manager.isPeeking)
        harness.manager.setPeeking(false)
    }

    // MARK: - Unsaved work

    /// A staged capture is one the sweep will delete. Quitting with those on screen throws
    /// work away silently, which is the one thing a capture tool must not do.
    @Test("A staged capture counts as unsaved")
    func stagedIsUnsaved() throws {
        let harness = makeHarness()
        harness.settings.defaultAction = .overlayOnly
        let item = try showCard(harness)

        #expect(item.isStaged)
        #expect(harness.manager.hasUnsavedItems)
        #expect(harness.manager.unsavedItems.count == 1)
        harness.manager.dismissAll()
    }

    @Test("A saved capture does not")
    func savedIsNotUnsaved() throws {
        let harness = makeHarness()
        harness.settings.defaultAction = .saveToFolder
        _ = try showCard(harness)

        #expect(!harness.manager.hasUnsavedItems)
        harness.manager.dismissAll()
    }

    @Test("Saving everything clears the warning")
    func finalizingClearsTheWarning() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .overlayOnly

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        #expect(harness.manager.hasUnsavedItems)

        let saved = harness.manager.finalizeAllStaged()
        #expect(saved == 1)
        #expect(!harness.manager.hasUnsavedItems)
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
        harness.manager.dismissAll()
    }

    @Test("An empty overlay has nothing to warn about")
    func emptyOverlayIsClean() {
        let harness = makeHarness()
        #expect(!harness.manager.hasUnsavedItems)
        #expect(harness.manager.finalizeAllStaged() == 0)
    }
}
