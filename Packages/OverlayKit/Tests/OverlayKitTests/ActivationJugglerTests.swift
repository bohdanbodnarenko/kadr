import AppKit
import Testing
@testable import OverlayKit

@MainActor
private final class FakeApplication: ActivationPolicyControlling {
    var policy: NSApplication.ActivationPolicy = .accessory
    private(set) var policyHistory: [NSApplication.ActivationPolicy] = []
    private(set) var activateCount = 0

    func currentActivationPolicy() -> NSApplication.ActivationPolicy {
        policy
    }

    @discardableResult
    func apply(_ policy: NSApplication.ActivationPolicy) -> Bool {
        self.policy = policy
        policyHistory.append(policy)
        return true
    }

    func activateApp() {
        activateCount += 1
    }
}

@MainActor
@Suite("ActivationJuggler")
struct ActivationJugglerTests {
    @Test("Showing a window flips to .regular and activates the app")
    func raisesPolicy() {
        let app = FakeApplication()
        let juggler = ActivationJuggler(application: app)
        juggler.beginRegularWindow()

        #expect(app.policy == .regular)
        #expect(app.activateCount == 1)
        #expect(juggler.regularWindowCount == 1)
    }

    @Test("Closing the last window returns the agent to .accessory")
    func restoresIdlePolicy() async {
        let app = FakeApplication()
        let juggler = ActivationJuggler(application: app)
        juggler.beginRegularWindow()
        juggler.endRegularWindow()
        await Task.yield()

        #expect(app.policy == .accessory)
        #expect(app.policyHistory == [.regular, .accessory])
        #expect(juggler.regularWindowCount == 0)
    }

    @Test("A second window does not re-activate, and closing it does not drop the policy")
    func refCounts() async {
        let app = FakeApplication()
        let juggler = ActivationJuggler(application: app)
        juggler.beginRegularWindow()
        juggler.beginRegularWindow()
        juggler.endRegularWindow()

        #expect(app.policy == .regular)
        #expect(app.activateCount == 1)
        #expect(juggler.regularWindowCount == 1)

        juggler.endRegularWindow()
        await Task.yield()
        #expect(app.policy == .accessory)
    }

    @Test("An unbalanced end is ignored rather than driving the count negative")
    func unbalancedEndIsIgnored() {
        let app = FakeApplication()
        let juggler = ActivationJuggler(application: app)
        juggler.endRegularWindow()

        #expect(juggler.regularWindowCount == 0)
        #expect(app.policyHistory.isEmpty)
    }

    @Test("The idle policy is configurable for hosts that are not accessory apps")
    func customIdlePolicy() async {
        let app = FakeApplication()
        app.policy = .regular
        let juggler = ActivationJuggler(application: app, idlePolicy: .regular)
        juggler.beginRegularWindow()
        juggler.endRegularWindow()
        await Task.yield()

        #expect(app.policy == .regular)
        #expect(app.activateCount == 1)
    }
}
