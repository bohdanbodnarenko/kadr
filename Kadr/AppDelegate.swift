import AppKit
import CaptureCore
import os
import SelectionUI
import SettingsKit
import Shared

/// The resident agent (docs/04 §1, §3).
///
/// `NSApplicationMain` with a plain delegate, `LSUIElement`, `.accessory` activation:
/// no storyboard, no SwiftUI scene, no timers. Launch registers a status item and the
/// global hotkeys and then does nothing at all until the user asks for something —
/// that idle path is the PRD §8 RAM and CPU budget.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// NSApplication.delegate is *unretained* — keep a strong reference.
    private static let shared = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = shared
        delegate.beginLaunchInterval()
        app.delegate = delegate
        app.run()
    }

    private let logger = KadrLog.logger(.app)
    private let signposter = KadrLog.signposter(.app)
    private var launchInterval: OSSignpostIntervalState?
    private var launchStartedAt: ContinuousClock.Instant?

    private var statusItemController: StatusItemController?
    private var hotkeyCenter: HotkeyCenter?

    /// The capture layer. Constructing it touches no framework — ScreenCaptureKit is
    /// not messaged until the first capture, which is what keeps the idle budget
    /// (docs/04 §7.1).
    private lazy var captureEngine = CaptureEngine()
    private lazy var permissions = PermissionCoordinator()
    private lazy var areaCapture = AreaCaptureCoordinator(
        engine: captureEngine,
        permissions: permissions,
        settings: settings
    )

    // Settings state is Foundation-only and cheap; the window that presents it is not,
    // and is built on first use.
    private lazy var settings = AppSettings()
    private lazy var loginItem = LoginItemController()
    private lazy var settingsWindowController = SettingsWindowController(
        settings: settings,
        loginItem: loginItem
    )

    #if DEBUG
        private var debugCaptureMenu: DebugCaptureMenu?
    #endif

    // MARK: - Launch

    private func beginLaunchInterval() {
        launchStartedAt = .now
        launchInterval = signposter.beginInterval("launch")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItemController = StatusItemController(
            perform: { [weak self] command in self?.perform(command) },
            openSettings: { [weak self] in self?.openSettings() },
            restoreRecentlyClosed: { [weak self] in self?.areaCapture.restoreRecentlyClosed() },
            closeAllPins: { [weak self] in self?.areaCapture.closeAllPins() },
            additionalItems: { [weak self] in self?.debugMenuItems() ?? [] }
        )
        endLaunchInterval()

        hotkeyCenter = HotkeyCenter(perform: { [weak self] command in self?.perform(command) })
        hotkeyCenter?.start()

        // Clear staged captures the user never acted on (docs/03 §2). Once, at launch —
        // never on a timer.
        CaptureOutput(settings: settings).sweepStaging()

        // docs/04 §3.3: the user can flip this in System Settings, so never cache it
        // across launches. Deliberately after the status item, so ServiceManagement
        // loading cannot eat into the launch budget.
        loginItem.refresh()
        // Bound to a local: a log message is an autoclosure, so referring to a property
        // inside it would need an explicit `self.` that SwiftFormat then strips again.
        let loginItemState = String(describing: loginItem.state)
        logger.info("Login item state: \(loginItemState, privacy: .public)")
    }

    /// Ends the launch→statusItemReady interval budgeted at < 300 ms (PRD §8).
    private func endLaunchInterval() {
        if let launchInterval {
            signposter.endInterval("launch", launchInterval)
            self.launchInterval = nil
        }
        if let launchStartedAt {
            let milliseconds = Double(launchStartedAt.duration(to: .now).components.attoseconds) / 1e15
            logger.info("Status item ready in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
            self.launchStartedAt = nil
        }
    }

    // MARK: - Commands

    private func perform(_ command: CaptureCommand) {
        logger.info("Command requested: \(command.rawValue, privacy: .public)")
        switch command {
        case .captureArea:
            areaCapture.beginAreaCapture()
        case .capturePreviousArea:
            areaCapture.capturePreviousArea()
        case .captureWindow:
            areaCapture.beginWindowCapture()
        case .captureFullscreen:
            areaCapture.captureAllDisplays()
        case .captureText:
            areaCapture.beginTextCapture()
        }
    }

    private func openSettings() {
        settingsWindowController.show()
    }

    /// Debug builds get a submenu that drives CaptureCore directly (docs/06 M1).
    private func debugMenuItems() -> [NSMenuItem] {
        #if DEBUG
            if debugCaptureMenu == nil {
                debugCaptureMenu = DebugCaptureMenu(engine: captureEngine, permissions: permissions)
            }
            return [debugCaptureMenu].compactMap { $0?.makeMenuItem() }
        #else
            return []
        #endif
    }

    // MARK: - Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing Settings must not quit the agent.
        false
    }
}
