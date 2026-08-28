import AppKit
import AutomationKit
import os
import OverlayKit
import SettingsKit
import Shared
import SwiftUI

/// Owns the one and only Settings window (docs/04 §3.1).
///
/// The window is built on demand and torn down on close: SwiftUI, its hosting view
/// and the whole view tree are allocated when the user opens Settings and gone by
/// the time the window has closed, so the agent returns to its idle footprint
/// (PRD §8). Debug builds assert on that rather than trusting it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let loginItem: LoginItemController
    private let history: HistoryController?
    private let juggler: ActivationJuggler
    private let logger = KadrLog.logger(.settings)

    /// Internal rather than private so tests can hold a weak reference and prove the
    /// window really goes away on close.
    private(set) var window: NSWindow?
    private weak var hostingView: NSView?

    init(
        settings: AppSettings,
        loginItem: LoginItemController,
        history: HistoryController? = nil,
        juggler: ActivationJuggler = .shared
    ) {
        self.settings = settings
        self.loginItem = loginItem
        self.history = history
        self.juggler = juggler
    }

    /// Whether a window is currently on screen. Used by the deallocation tests.
    var isOpen: Bool {
        window != nil
    }

    /// - Parameter tab: which pane to land on, for `kadr open-settings --tab …`
    ///   (docs/03 §8.4). `nil` leaves the window wherever the user left it.
    func show(tab: SettingsTab? = nil) {
        // The user can flip the login item in System Settings behind our back.
        loginItem.refresh()

        if let window {
            // A window that is already open cannot have its tab changed without rebuilding
            // the SwiftUI tree, and rebuilding it would throw away whatever the user was
            // typing. Bringing it forward is the honest thing to do.
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(
            rootView: SettingsView(
                settings: settings,
                loginItem: loginItem,
                history: history,
                selection: tab ?? .general
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kadr Settings"
        window.contentView = hosting
        window.delegate = self
        // AppKit would otherwise release the window out from under ARC on close.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("app.kadr.Kadr.settings")

        self.window = window
        hostingView = hosting

        // An .accessory app cannot make a window key on its own — docs/04 §3.1.
        juggler.beginRegularWindow()
        window.makeKeyAndOrderFront(nil)
        logger.info("Settings window opened")
    }

    /// Closes the window if it is open. The teardown runs through `windowWillClose`.
    func close() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }

        window.delegate = nil
        // Drop the SwiftUI tree before the window goes, so nothing outlives the close.
        window.contentView = nil
        self.window = nil

        juggler.endRegularWindow()
        logger.info("Settings window closed")

        assertTornDown()
    }

    /// Debug-only leak check on the part that actually costs memory: the SwiftUI tree.
    ///
    /// A retain cycle in a settings pane would keep the whole view hierarchy, its
    /// observation registrations and its state alive after the window closed, which is
    /// exactly the regression that ruins the idle RSS budget (PRD §8). Measured healthy
    /// teardown is ~100 ms.
    ///
    /// The `NSWindow` object itself is deliberately *not* asserted on. AppKit retains a
    /// window that has ever been ordered in for as long as it likes — a bare window with
    /// no delegate, no content view and no autosave name behaves identically, and was
    /// still alive after five seconds when measured. That is AppKit's bookkeeping, not a
    /// leak of ours, and asserting on it only produces flaky failures. What matters here
    /// is that the controller has let go of it, which `windowWillClose` guarantees and
    /// `isOpen` exposes.
    private func assertTornDown() {
        let hosting = hostingView
        hostingView = nil

        #if DEBUG
            Task { @MainActor [weak hosting] in
                for _ in 0 ..< 20 {
                    if hosting == nil {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                assert(hosting == nil, "Settings hosting view leaked — check for a retain cycle in a pane")
            }
        #endif
    }
}
