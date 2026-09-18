import CoreGraphics
import Foundation
import Testing
@testable import Kadr

/// One hover pill at a time, however the enter and exit events are ordered.
@MainActor
@Suite("Island tooltip")
struct RecordingBarTooltipTests {
    private let frameA = CGRect(x: 0, y: 0, width: 40, height: 40)
    private let frameB = CGRect(x: 42, y: 0, width: 40, height: 40)

    /// Polls rather than sleeping a fixed time: the whole suite shares the main actor, and
    /// a busy one can hold a 160 ms show delay for much longer.
    private func wait(until condition: () -> Bool) async {
        for _ in 0 ..< 300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func warmedUp() async -> RecordingBarTooltipModel {
        let model = RecordingBarTooltipModel()
        model.hover(id: "a", text: "Area", key: "A", frame: frameA)
        await wait { model.visible != nil }
        return model
    }

    @Test("Sliding to the next control with the exit first keeps one pill that moves")
    func exitBeforeEnterNeverHides() async {
        let model = await warmedUp()
        #expect(model.visible?.id == "a")

        model.endHover(id: "a")
        #expect(model.visible?.id == "a", "the pill must not be removed on the exit alone")
        model.hover(id: "b", text: "Window", key: "W", frame: frameB)
        #expect(model.visible?.id == "b")
        #expect(model.visible?.key == "W")

        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.visible?.id == "b", "a cancelled hide must not clear the new pill")
    }

    @Test("Sliding with the entry first moves the pill too")
    func enterBeforeExit() async {
        let model = await warmedUp()
        model.hover(id: "b", text: "Window", key: "W", frame: frameB)
        model.endHover(id: "a")
        #expect(model.visible?.id == "b")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.visible?.id == "b")
    }

    @Test("Leaving the bar hides the pill after the grace period")
    func leavingHides() async {
        let model = await warmedUp()
        model.endHover(id: "a")
        await wait { model.visible == nil }
        #expect(model.visible == nil)
    }

    @Test("Clicking hides it at once")
    func dismissIsImmediate() async {
        let model = await warmedUp()
        model.dismiss()
        #expect(model.visible == nil)
    }
}
