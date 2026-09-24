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
        isActiveApp = true
    }

    var isActiveApp = false
    private(set) var returnedTo: [pid_t] = []

    func returnActivation(to app: NSRunningApplication) {
        returnedTo.append(app.processIdentifier)
        isActiveApp = false
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

    @Test("Only Kadr's own processes are refused as a return target", arguments: [
        ("com.apple.Safari", true),
        ("com.microsoft.VSCode", true),
        (nil, true),
        ("app.kadr.Kadr", false),
        ("app.kadr.KadrEditor", false),
        ("app.kadr.helper", false)
    ] as [(String?, Bool)])
    func returnable(bundleIdentifier: String?, expected: Bool) {
        #expect(ActivationJuggler.isReturnable(bundleIdentifier: bundleIdentifier) == expected)
    }

    @Test("A temporary activation activates, then hands activation back once")
    func temporaryActivation() {
        let app = FakeApplication()
        let juggler = ActivationJuggler(application: app)
        let target = NSRunningApplication.current
        let lease = juggler.beginTemporaryActivation(returningTo: target)
        #expect(app.activateCount == 1)
        lease.end()
        lease.end()
        #expect(app.returnedTo == [target.processIdentifier])
    }

    @Test("withTemporaryActivation returns activation after the body")
    func scopedActivation() {
        let app = FakeApplication()
        let juggler = ActivationJuggler(application: app)
        let value = juggler.withTemporaryActivation(returningTo: .current) {
            #expect(app.isActiveApp)
            return 7
        }
        #expect(value == 7)
        #expect(app.returnedTo.count == 1)
    }

    @Test("Nothing is yielded while a regular window is open, or when Kadr is not active")
    func yieldGuards() {
        let app = FakeApplication()
        let juggler = ActivationJuggler(application: app)
        juggler.yieldActivation(to: .current)
        #expect(app.returnedTo.isEmpty, "Kadr was not active")

        juggler.beginRegularWindow()
        juggler.yieldActivation(to: .current)
        #expect(app.returnedTo.isEmpty, "Settings is open")

        juggler.endRegularWindow()
        juggler.yieldActivation(to: nil)
        #expect(app.returnedTo.isEmpty, "no target")
    }

    @Test("An abandoned lease hands nothing back")
    func abandonedLease() {
        let app = FakeApplication()
        let juggler = ActivationJuggler(application: app)
        let lease = juggler.beginTemporaryActivation(returningTo: .current)
        lease.abandon()
        lease.end()
        #expect(app.returnedTo.isEmpty)
    }
}
