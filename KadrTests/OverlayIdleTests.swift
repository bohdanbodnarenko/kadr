import AppKit
import Foundation
import SettingsKit
import Testing
@testable import Kadr

/// Auto-close costs nothing while a card is held (PRD §8, docs/03 §2).
@MainActor
@Suite("Overlay idle timer", .serialized)
struct OverlayIdleTests {
    private func showCard(_ harness: TestHarness) throws -> QuickAccessItem {
        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        return try #require(harness.manager.items.first)
    }

    private func makeHarness() -> TestHarness {
        let harness = makeManager(
            saveFolder: temporaryDirectory("save"),
            stagingFolder: temporaryDirectory("stage")
        )
        harness.settings.overlayTimeout = .tenSeconds
        return harness
    }

    /// A card under a resting pointer used to wake the agent every two seconds to ask
    /// whether the pointer was still there (PRD §8).
    @Test("Nothing runs while a card is held; letting go re-arms the timer", arguments: [false, true])
    func holdingACardRunsNoTimer(byDragging: Bool) throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        #expect(harness.manager.dismissTasks[item.id] != nil, "a fresh card has its timer")

        if byDragging {
            harness.manager.beginDrag(for: item)
        } else {
            harness.manager.setHovered(item, hovering: true)
        }
        #expect(harness.manager.dismissTasks[item.id] == nil, "holding a card stops its timer")

        // The timer firing while the card is held must not start a poll.
        harness.manager.autoDismissIfIdle(item)
        #expect(harness.manager.dismissTasks[item.id] == nil)
        #expect(harness.manager.items.contains { $0.id == item.id })

        if byDragging {
            harness.manager.endDrag(for: item)
        } else {
            harness.manager.setHovered(item, hovering: false)
        }
        #expect(harness.manager.dismissTasks[item.id] != nil, "letting go re-arms the timer")
        harness.manager.dismissAll()
    }

    @Test("An engaged card is not re-armed when the pointer leaves")
    func engagedCardStaysUnarmed() throws {
        let harness = makeHarness()
        let item = try showCard(harness)
        harness.manager.setHovered(item, hovering: true)
        harness.manager.noteEngagement(with: item)
        harness.manager.setHovered(item, hovering: false)
        #expect(harness.manager.dismissTasks[item.id] == nil)
        harness.manager.dismissAll()
    }
}
