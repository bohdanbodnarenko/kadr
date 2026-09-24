import AppKit
import AutomationKit
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

    var isActiveApp = false

    func returnActivation(to _: NSRunningApplication) {}
}

/// Lets AppKit finish closing the window.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

/// Polls until the probed object is gone, up to five seconds.
///
/// SwiftUI tears its hosting view down asynchronously — measured at ~100 ms — so this
/// waits rather than assuming it has already happened. The generous bound is what makes
/// it a leak test and not a timing test: a retain cycle never releases.
@MainActor
private func waitUntilDeallocated(_ probe: () -> AnyObject?) async -> Bool {
    for _ in 0 ..< 50 {
        if probe() == nil {
            return true
        }
        try? await Task.sleep(for: .milliseconds(100))
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

    /// The second show brings the window forward — activating again, which is what makes
    /// it come in front of the app the user is in (docs/17 T-SH-5) — but does not take a
    /// second regular-policy reference that closing once would leave behind.
    @Test("Showing twice reuses the one window and brings it forward")
    func showIsIdempotent() async {
        let app = FakeApplication()
        let controller = makeController(app)
        controller.show()
        let first = controller.window
        controller.show()

        #expect(controller.window === first)
        #expect(app.activateCount == 2)

        controller.close()
        await settle()
    }

    @Test("open-settings --tab switches the pane on an already-open window")
    func showUpdatesTabWithoutRebuilding() async {
        let app = FakeApplication()
        let controller = makeController(app)
        controller.show(tab: .general)
        let first = controller.window

        controller.show(tab: .capture)

        #expect(controller.window === first)
        #expect(controller.selectedTab == .capture)
        #expect(first?.styleMask.contains(.fullSizeContentView) == true)

        controller.close()
        await settle()
    }

    @Test("The window minimum matches the single geometry source (docs/14 UX-09)")
    func minimumSizeMatchesGeometry() async {
        let app = FakeApplication()
        let controller = makeController(app)
        controller.show()

        // Width is exact. Height is a floor: the split-view toolbar sits in the content
        // area, so AppKit's contentMinSize is a little taller than the form's 540 pt.
        #expect(controller.window?.contentMinSize.width == SettingsWindowGeometry.minimumWidth)
        #expect((controller.window?.contentMinSize.height ?? 0) >= SettingsWindowGeometry.minimumHeight)

        controller.close()
        await settle()
    }

    @Test("The SwiftUI view tree is deallocated on close, and the window is let go (PRD §8)")
    func closeDeallocatesTheViewTree() async {
        let app = FakeApplication()
        let controller = makeController(app)
        controller.show()

        // The hosting view is the expensive half: SwiftUI's runtime, the view hierarchy
        // and every observation registration hang off it.
        let hostingProbe: () -> AnyObject? = { [weak view = controller.window?.contentView] in view }
        #expect(hostingProbe() != nil)

        controller.close()

        #expect(await waitUntilDeallocated(hostingProbe), "the SwiftUI view tree outlived its window")
        #expect(controller.window == nil, "the controller is still holding its window")
        #expect(controller.isOpen == false)
    }
}
