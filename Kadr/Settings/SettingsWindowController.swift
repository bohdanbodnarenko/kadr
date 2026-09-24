import AppKit
import AutomationKit
import os
import OverlayKit
import SettingsKit
import Shared
import SwiftUI

/// The one declared minimum for the Settings window (docs/14 UX-09).
///
/// There used to be two: the window said 620×460 and the view said 660×540, so the window
/// could be dragged to a size its own content refused to fit in. Both read this now.
///
/// 700×540 is the tested floor: a 200 pt sidebar plus the widest pane's controls, and tall
/// enough for the longest visible group without the form scrolling on arrival.
enum SettingsWindowGeometry {
    static let minimumWidth: CGFloat = 700
    static let minimumHeight: CGFloat = 540

    static var minimumSize: NSSize {
        NSSize(width: minimumWidth, height: minimumHeight)
    }

    /// Sidebar bounds. Ranged rather than pinned, so the system toggle and the divider
    /// both do something, and AppKit's frame autosave remembers where it was left.
    static let sidebarMinimumWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 200
    static let sidebarMaximumWidth: CGFloat = 280
}

/// Owns the one and only Settings window (docs/04 §3.1).
///
/// The window is built on demand and torn down on close: SwiftUI, its hosting view
/// and the whole view tree are allocated when the user opens Settings and gone by
/// the time the window has closed, so the agent returns to its idle footprint
/// (PRD §8). Debug builds assert on that rather than trusting it.
///
/// `.fullSizeContentView` is set at creation so macOS 26 can draw liquid-glass
/// corners; a SwiftUI `Window` scene cannot set that style mask.
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
    private var navigation: SettingsNavigation?

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

    /// The pane currently shown, when the window is open.
    var selectedTab: SettingsTab? {
        navigation?.selectedTab
    }

    var isSidebarHidden: Bool {
        navigation?.isSidebarHidden ?? false
    }

    /// - Parameter tab: which pane to land on, for `kadr open-settings --tab …`
    ///   (docs/03 §8.4). `nil` leaves the window wherever the user left it.
    func show(tab: SettingsTab? = nil) {
        // The user can flip the login item in System Settings behind our back.
        loginItem.refresh()

        if let tab {
            navigation?.selectedTab = tab
        }

        if let window {
            // Activates and deminiaturizes too: a second request for an open window used
            // to order it front behind the app the user was in (docs/17 T-SH-5).
            juggler.bringForward(window)
            return
        }

        // The pane the user was last in, as HIG › Settings asks; a `tab` from automation
        // or a deep link still wins (docs/17 T-SH-8).
        let navigation = SettingsNavigation(selectedTab: tab ?? Self.lastTab(in: .standard))
        self.navigation = navigation

        let hosting = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                loginItem: loginItem,
                history: history,
                navigation: navigation
            )
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowGeometry.minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = false
        window.contentViewController = hosting
        window.delegate = self
        window.contentMinSize = SettingsWindowGeometry.minimumSize
        window.minSize = SettingsWindowGeometry.minimumSize
        // AppKit would otherwise release the window out from under ARC on close.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("app.kadr.Kadr.settings")

        self.window = window
        hostingView = hosting.view

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

    static let lastTabKey = "app.kadr.settings.lastTab"

    static func lastTab(in defaults: UserDefaults) -> SettingsTab {
        defaults.string(forKey: lastTabKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        if let tab = navigation?.selectedTab {
            UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
        }

        window.delegate = nil
        // Drop the SwiftUI tree before the window goes, so nothing outlives the close.
        window.contentViewController = nil
        window.contentView = nil
        self.window = nil
        navigation = nil

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
