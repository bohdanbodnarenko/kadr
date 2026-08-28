import AutomationKit
import Foundation
import Testing
@testable import Kadr

/// Who owns the answer to an automated capture (docs/03 §8.4, docs/06 M19).
///
/// The invariants are small and load-bearing: a script blocked on `kadr capture-area` must
/// be answered exactly once, and an automated capture's `action=` must not leak into the
/// next screenshot the user takes by hand.
@MainActor
@Suite("Automated capture requests")
struct AutomationCaptureRequestTests {
    @Test("An unarmed request reports to nobody and holds no overrides")
    func startsEmpty() {
        let request = AutomationCaptureRequest()
        #expect(request.overrides == .none)
        // Reporting with nothing armed must be harmless, because every capture path does
        // it whether automation asked for one or not.
        request.report(.cancelled)
    }

    @Test("The armed caller is told exactly once")
    func reportsOnce() {
        let request = AutomationCaptureRequest()
        var outcomes: [CaptureOutcome] = []
        request.arm(.none) { outcomes.append($0) }

        request.report(.file(URL(fileURLWithPath: "/tmp/a.png")))
        request.report(.file(URL(fileURLWithPath: "/tmp/b.png")))

        #expect(outcomes.count == 1)
        #expect(outcomes.first == .file(URL(fileURLWithPath: "/tmp/a.png")))
    }

    @Test("Overrides die with the capture that used them")
    func overridesDoNotLeak() {
        let request = AutomationCaptureRequest()
        request.arm(CaptureOverrides(action: .save, delaySeconds: 3)) { _ in }
        #expect(request.overrides.action == .save)

        request.report(.cancelled)
        #expect(request.overrides == .none, "the next capture must use the user's settings")
    }

    /// The case that would otherwise hang a script: two automations in a row, the first
    /// superseded before it finished.
    @Test("Arming a second request tells the first it was cancelled")
    func armingDisplacesThepreviousCaller() {
        let request = AutomationCaptureRequest()
        var first: CaptureOutcome?
        var second: CaptureOutcome?

        request.arm(.none) { first = $0 }
        request.arm(CaptureOverrides(action: .copy)) { second = $0 }

        #expect(first == .cancelled)
        #expect(second == nil)
        #expect(request.overrides.action == .copy)

        request.report(.text("#FF0000"))
        #expect(second == .text("#FF0000"))
    }

    @Test("A capture nobody asked for reports to nobody")
    func unarmedCapturesAreSilent() {
        let request = AutomationCaptureRequest()
        var calls = 0
        request.arm(.none) { _ in calls += 1 }
        request.report(.cancelled)
        request.report(.cancelled)
        #expect(calls == 1)
    }

    @Test("Overrides carry an automation's options through unchanged")
    func overridesFromOptions() {
        let overrides = CaptureOverrides(CaptureOptions(
            action: .pin,
            delay: 5,
            includesCursor: true
        ))
        #expect(overrides.action == .pin)
        #expect(overrides.delaySeconds == 5)
        #expect(overrides.includesCursor == true)
        #expect(!overrides.isEmpty)
    }

    @Test("An outcome becomes the response a script reads")
    func outcomesMapToResponses() {
        #expect(CaptureOutcome.file(URL(fileURLWithPath: "/tmp/a.png")).response.paths == ["/tmp/a.png"])
        #expect(CaptureOutcome.text("hello").response.text == "hello")
        #expect(CaptureOutcome.cancelled.response.exitCode == 2)
        #expect(CaptureOutcome.failed("nope").response.exitCode == 1)
    }
}
