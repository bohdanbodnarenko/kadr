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
    @Test("Opening the editor collapses the cards to a tab")
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

    /// Opening the editor tucks the cards away — but only if an editor actually opened.
    ///
    /// The overlay collapsed first and launched second, so when the launch did nothing (no
    /// editor embedded in the bundle, or a failure) the stack sat in the peek tab reading
    /// "1 Screenshot" forever: the only thing that expands it again is the editor process
    /// terminating, and none had started. The test bundle has no embedded editor, so this is
    /// that case exactly.
    @Test("A failed editor launch does not strand the cards in the peek tab")
    func failedEditorLaunchDoesNotStrandThePeekTab() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        // A launcher that cannot open anything, standing in for a build with no editor
        // embedded — and keeping the test from starting a real one.
        harness.manager.editor = EditorLauncher(editorURL: nil)
        #expect(!harness.manager.editor.isAvailable)

        harness.manager.annotate(item)

        #expect(!harness.manager.isPeeking, "the cards were hidden for an editor that never opened")
        #expect(harness.manager.items.count == 1)
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
    func lastPeekedCardTearsDownTheTab() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setPeeking(true)
        harness.manager.dismiss(item)
        #expect(!harness.manager.isPeeking)
        // The last card takes the panel with it: an agent with nothing to show owns no
        // windows (CLAUDE.md rule 2).
        #expect(harness.manager.overlayPanel == nil)
    }

    // MARK: - Swipe

    /// The gesture, wired to the stack — not just the arithmetic that classifies it.
    ///
    /// `OverlaySwipe` was covered and its wiring was not, so when the per-card panels were
    /// replaced by one panel the `scrollWheel` override went with them and every swipe test
    /// still passed. These go through the manager.
    @Test("A flick over a hovered card dismisses that card")
    func swipeDismissesThroughTheManager() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.settings.overlayCorner = .bottomRight
        harness.manager.setHovered(item, hovering: true)

        // Through the panel's own closure, which is the part that broke: the handler kept
        // working after the per-card panels went away, and nothing was calling it.
        let onScroll = try #require(
            harness.manager.overlayPanel?.onScroll,
            "the panel must be wired to the swipe handler"
        )
        onScroll(20, 0)
        #expect(harness.manager.items.isEmpty, "an outward flick hides the hovered card")
    }

    @Test("A flick toward the screen edge tucks the stack away")
    func swipePeeksThroughTheManager() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.settings.overlayCorner = .bottomRight
        harness.manager.setHovered(item, hovering: true)

        harness.manager.handleScroll(deltaX: 0, deltaY: 20)
        #expect(harness.manager.isPeeking)
        #expect(harness.manager.items.count == 1, "peeking keeps the card")
        harness.manager.dismissAll()
    }

    /// A flick that is not over a card belongs to whatever is underneath.
    @Test("A flick with nothing hovered does nothing")
    func swipeWithoutHoverIsIgnored() throws {
        let harness = makeHarness()
        _ = try showCard(harness)
        harness.settings.overlayCorner = .bottomRight

        harness.manager.handleScroll(deltaX: 20, deltaY: 0)
        #expect(harness.manager.items.count == 1)
        harness.manager.dismissAll()
    }

    @Test("A flick toward the docked edge hides the card")
    func swipeOutwardDismisses() {
        #expect(OverlaySwipe.from(deltaX: 12, deltaY: 0, corner: .bottomRight) == .dismiss)
        #expect(OverlaySwipe.from(deltaX: -12, deltaY: 0, corner: .bottomLeft) == .dismiss)
        #expect(OverlaySwipe.from(deltaX: 12, deltaY: 0, corner: .bottomLeft) == nil)
    }

    @Test("A flick toward the screen edge peeks")
    func swipeTowardEdgePeeks() {
        #expect(OverlaySwipe.from(deltaX: 0, deltaY: 10, corner: .bottomLeft) == .peek)
        #expect(OverlaySwipe.from(deltaX: 0, deltaY: -10, corner: .topRight) == .peek)
        #expect(OverlaySwipe.from(deltaX: 0, deltaY: 10, corner: .topRight) == nil)
    }

    @Test("The peek tab names screenshots unless a recording is in the stack")
    func peekTitleFollowsContents() {
        #expect(OverlayPeekCopy.title(count: 1, hasVideo: false) == "1 Screenshot")
        #expect(OverlayPeekCopy.title(count: 3, hasVideo: false) == "3 Screenshots")
        #expect(OverlayPeekCopy.title(count: 2, hasVideo: true) == "2 Captures")
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

    @Test("Option+Copy claims the card so auto-close cannot take it (CleanShot §6.2)")
    func optionCopyKeepsTheCard() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        #expect(!harness.manager.isEngaged(item))

        harness.manager.copy(item, keepOverlay: true)
        #expect(harness.manager.isEngaged(item))

        harness.manager.autoDismissIfIdle(item)
        #expect(harness.manager.items.contains { $0.id == item.id })
        harness.manager.dismissAll()
    }

    @Test("Copy without Option leaves the card disposable")
    func copyDoesNotEngage() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.copy(item)
        #expect(!harness.manager.isEngaged(item))
        harness.manager.dismissAll()
    }

    // MARK: - Hover keys

    private func keyDown(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @Test("Esc hides the hovered card without deleting it")
    func hoverEscDismisses() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(harness.manager.handleHoverKey(try keyDown(53), canStealCommandKeys: true))
        #expect(harness.manager.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    @Test("Return from the local monitor saves and dismisses")
    func hoverReturnSaves() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(harness.manager.handleHoverKey(try keyDown(36), canStealCommandKeys: true))
        #expect(harness.manager.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.settings.saveFolder.path).count == 1)
    }

    @Test("Return does nothing when the setting is off")
    func hoverReturnRespectsSetting() throws {
        let harness = makeHarness()
        harness.settings.overlayReturnSaves = false
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(!harness.manager.handleHoverKey(try keyDown(36), canStealCommandKeys: true))
        #expect(harness.manager.items.contains { $0.id == item.id })
        harness.manager.dismissAll()
    }

    @Test("⌘S from the local monitor saves and dismisses")
    func hoverCommandSSaves() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(harness.manager.handleHoverKey(try keyDown(1, modifiers: .command), canStealCommandKeys: true))
        #expect(harness.manager.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.settings.saveFolder.path).count == 1)
    }

    @Test("⌘S from the global monitor is ignored so the front app keeps it")
    func hoverCommandSIsLocalOnly() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(!harness.manager.handleHoverKey(try keyDown(1, modifiers: .command), canStealCommandKeys: false))
        #expect(harness.manager.items.contains { $0.id == item.id })
        harness.manager.dismissAll()
    }

    @Test("⌘C from the local monitor copies")
    func hoverCommandCCopies() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(harness.manager.handleHoverKey(try keyDown(8, modifiers: .command), canStealCommandKeys: true))
        #expect(harness.manager.items.first?.isStaged == false)
        harness.manager.dismissAll()
    }

    @Test("⌘P from the local monitor pins")
    func hoverCommandPPins() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(harness.manager.handleHoverKey(try keyDown(35, modifiers: .command), canStealCommandKeys: true))
        #expect(harness.manager.pins.count == 1)
        harness.manager.pins.closeAll()
        harness.manager.dismissAll()
    }

    @Test("⌘E from the local monitor opens annotate")
    func hoverCommandEAnnotates() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.editor = EditorLauncher(editorURL: nil)
        harness.manager.setHovered(item, hovering: true)

        #expect(harness.manager.handleHoverKey(try keyDown(14, modifiers: .command), canStealCommandKeys: true))
        #expect(harness.manager.isEngaged(item))
        harness.manager.dismissAll()
    }

    @Test("⌘W from the local monitor dismisses without deleting")
    func hoverCommandWDismisses() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(harness.manager.handleHoverKey(try keyDown(13, modifiers: .command), canStealCommandKeys: true))
        #expect(harness.manager.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
    }
}
