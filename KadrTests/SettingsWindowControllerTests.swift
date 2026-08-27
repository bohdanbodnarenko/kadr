import AppKit
import Foundation
import OverlayKit
import SettingsKit
import Testing
@testable import Kadr

@MainActor
private final class FakeApplication: ActivationPolicyControlling {
    var policy: NSApplication.ActivationPolicy = .accessory
    private(set) var activateCount = 0

    func currentActivationPolicy() -> NSApplication.ActivationPolicy {
        policy
    }

    @discardableResult
    func apply(_ policy: NSApplication.ActivationPolicy) -> Bool {
        self.policy = policy
        return true
    }

    func activateApp() {
        activateCount += 1
    }
}

/// Lets AppKit finish closing the window.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

/// Polls until the probed object is gone, up to three seconds.
///
/// AppKit releases an ordered-in window asynchronously (~300 ms in practice), so
/// this waits for the teardown instead of assuming it has already happened.
@MainActor
private func waitUntilDeallocated(_ probe: () -> AnyObject?) async -> Bool {
    for _ in 0 ..< 60 {
        if probe() == nil {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return probe() == nil
}

@MainActor
@Suite("Settings window lifecycle", .serialized)
struct SettingsWindowControllerTests {
    private func makeController(_ app: FakeApplication) -> SettingsWindowController {
        let suite = UUID().uuidString
        guard let store = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite named \(suite)")
        }
        store.removePersistentDomain(forName: suite)
        return SettingsWindowController(
            settings: AppSettings(store: store),
            loginItem: LoginItemController(),
            juggler: ActivationJuggler(application: app)
        )
    }

    @Test("Opening raises the app to .regular so the window can become key")
    func openRaisesActivationPolicy() async {
        let app = FakeApplication()
        let controller = makeController(app)
        controller.show()

        #expect(controller.isOpen)
        #expect(app.policy == .regular)
        #expect(app.activateCount == 1)

        controller.close()
        await settle()
    }

    @Test("Closing returns the agent to .accessory and forgets the window")
    func closeRestoresAccessory() async {
        let app = FakeApplication()
        let controller = makeController(app)
        controller.show()
        controller.close()
        await settle()

        #expect(controller.isOpen == false)
        #expect(app.policy == .accessory)
    }

    @Test("Showing twice reuses the one window rather than stacking activations")
    func showIsIdempotent() async {
        let app = FakeApplication()
        let controller = makeController(app)
        controller.show()
        let first = controller.window
        controller.show()

        #expect(controller.window === first)
        #expect(app.activateCount == 1)

        controller.close()
        await settle()
    }

    @Test("The window and its SwiftUI hosting view are deallocated on close (PRD §8)")
    func closeDeallocatesEverything() async {
        let app = FakeApplication()
        let controller = makeController(app)
        controller.show()

        let windowProbe: () -> AnyObject? = { [weak window = controller.window] in window }
        let hostingProbe: () -> AnyObject? = { [weak view = controller.window?.contentView] in view }
        #expect(windowProbe() != nil)
        #expect(hostingProbe() != nil)

        controller.close()

        #expect(await waitUntilDeallocated(windowProbe), "the Settings window outlived its close")
        #expect(await waitUntilDeallocated(hostingProbe), "the SwiftUI hosting view outlived its window")
    }
}
