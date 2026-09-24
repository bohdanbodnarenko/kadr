import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import MediaExport
import SettingsKit
import Shared
import Testing
@testable import Kadr

/// The overlay's swipe gestures, and the peek tab they collapse into (docs/03 §2).
///
/// Split from `OverlayEngagementTests`, which had grown past the file limit: that suite is
/// about what a card does, this one about what the stack does.
@MainActor
@Suite("Overlay swipes", .serialized)
struct OverlaySwipeTests {
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
        let onSwipe = try #require(
            harness.manager.overlayPanel?.onSwipe,
            "the panel must be wired to the swipe handler"
        )
        onSwipe(.began, 20, 0, true)
        #expect(harness.manager.items.isEmpty, "an outward flick hides the hovered card")
    }

    @Test("One long swipe hides one card, not every card that slides under the pointer")
    func oneSwipeOneCard() throws {
        let harness = makeHarness()
        harness.settings.overlayCorner = .bottomRight
        _ = try showCard(harness)
        let second = try showCard(harness)
        harness.manager.setHovered(second, hovering: true)
        let onSwipe = try #require(harness.manager.overlayPanel?.onSwipe)

        onSwipe(.began, 20, 0, true)
        if let next = harness.manager.items.first {
            harness.manager.setHovered(next, hovering: true)
        }
        onSwipe(.changed, 20, 0, true)
        onSwipe(.changed, 20, 0, true)

        #expect(harness.manager.items.count == 1)
        harness.manager.dismissAll()
    }

    @Test("A mouse-wheel notch does not collapse the stack")
    func wheelIsIgnored() throws {
        let harness = makeHarness()
        harness.settings.overlayCorner = .bottomRight
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)
        let onSwipe = try #require(harness.manager.overlayPanel?.onSwipe)

        onSwipe(.changed, 0, 40, false)

        #expect(!harness.manager.isPeeking)
        #expect(harness.manager.items.count == 1)
        harness.manager.dismissAll()
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

        #expect(try harness.manager.handleCardKey(keyDown(53)))
        #expect(harness.manager.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    @Test("Return from the local monitor saves and dismisses")
    func hoverReturnSaves() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(try harness.manager.handleCardKey(keyDown(36)))
        #expect(harness.manager.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.settings.saveFolder.path).count == 1)
    }

    @Test("Return does nothing when the setting is off")
    func hoverReturnRespectsSetting() throws {
        let harness = makeHarness()
        harness.settings.overlayReturnSaves = false
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(try !harness.manager.handleCardKey(keyDown(36)))
        #expect(harness.manager.items.contains { $0.id == item.id })
        harness.manager.dismissAll()
    }

    @Test("⌘S from the local monitor saves and dismisses")
    func hoverCommandSSaves() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(try harness.manager.handleCardKey(keyDown(1, modifiers: .command)))
        #expect(harness.manager.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.settings.saveFolder.path).count == 1)
    }

    @Test("⌘C from the local monitor copies")
    func hoverCommandCCopies() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(try harness.manager.handleCardKey(keyDown(8, modifiers: .command)))
        #expect(harness.manager.items.first?.isStaged == false)
        harness.manager.dismissAll()
    }

    @Test("⌘P from the local monitor pins")
    func hoverCommandPPins() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(try harness.manager.handleCardKey(keyDown(35, modifiers: .command)))
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

        #expect(try harness.manager.handleCardKey(keyDown(14, modifiers: .command)))
        #expect(harness.manager.isEngaged(item))
        harness.manager.dismissAll()
    }

    @Test("⌘W from the local monitor dismisses without deleting")
    func hoverCommandWDismisses() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)

        #expect(try harness.manager.handleCardKey(keyDown(13, modifiers: .command)))
        #expect(harness.manager.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
    }
}
