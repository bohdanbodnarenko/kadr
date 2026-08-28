import AppKit
import AutomationKit
import CaptureCore
import os
import RecordingCore
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
    // Settings state is Foundation-only and cheap; the window that presents it is not,
    // and is built on first use.
    private lazy var settings = AppSettings()
    private lazy var history = HistoryController(settings: settings)
    private lazy var desktopHygiene = DesktopHygieneController(settings: settings)
    /// Written out rather than `lazy` so the quit path can ask whether the capture layer
    /// was ever built without building it: a `lazy var` read at termination would
    /// construct the whole thing to discover it has nothing to say (docs/04 §7.1).
    private var areaCaptureStorage: AreaCaptureCoordinator?
    private var areaCapture: AreaCaptureCoordinator {
        if let areaCaptureStorage {
            return areaCaptureStorage
        }
        let created = AreaCaptureCoordinator(
            engine: captureEngine,
            permissions: permissions,
            settings: settings,
            history: history,
            hygiene: desktopHygiene
        )
        areaCaptureStorage = created
        return created
    }

    private lazy var scrollCapture = ScrollCaptureCoordinator(
        captureEngine: captureEngine,
        permissions: permissions,
        settings: settings,
        output: CaptureOutput(settings: settings)
    )
    private lazy var recording = RecordingCoordinator(
        captureEngine: captureEngine,
        permissions: permissions,
        settings: settings,
        hygiene: desktopHygiene
    )

    /// The automation frontends (docs/03 §8.4). The router is built lazily; the listener
    /// is one run-loop source with no thread and no timer behind it, which is what lets
    /// automation exist without costing the idle budget (PRD §8).
    private lazy var automation = AutomationRouter(
        areaCapture: areaCapture,
        scrollCapture: scrollCapture,
        recording: recording,
        hygiene: desktopHygiene,
        openSettings: { [weak self] tab in self?.settingsWindowController.show(tab: tab) },
        openHistory: { [weak self] in self?.openHistory() },
        addToHistory: { [weak self] url in self?.addToHistory(url) ?? false }
    )
    private var automationListener: AutomationListener?

    private lazy var loginItem = LoginItemController()
    private lazy var settingsWindowController = SettingsWindowController(
        settings: settings,
        loginItem: loginItem,
        history: history
    )

    /// Held from launch so Sparkle's controller exists before the app finishes starting,
    /// which is what it expects.
    private let updater = UpdaterManager.shared

    private lazy var onboarding = OnboardingWindowController(
        model: OnboardingModel(permissions: permissions, settings: settings, loginItem: loginItem),
        settings: settings
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
            captureWithPicker: { [weak self] in self?.areaCapture.captureWithSystemPicker() },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            checkForUpdates: { [weak self] in self?.updater.checkForUpdates() },
            canCheckForUpdates: { [weak self] in self?.updater.canCheckForUpdates ?? false },
            recordingControls: { [weak self] in self?.currentRecordingControls() },
            additionalItems: { [weak self] in self?.debugMenuItems() ?? [] },
            history: history,
            reopenFromHistory: { [weak self] record in self?.areaCapture.reopenFromHistory(record) },
            canRestore: { [weak self] in
                (self?.areaCapture.canRestoreRecentlyClosed ?? false) || (self?.history.hasItems ?? false)
            },
            openHistory: { [weak self] in self?.openHistory() },
            desktopIconsHidden: { [weak self] in self?.desktopHygiene.isHidingIcons ?? false }
        )
        endLaunchInterval()

        hotkeyCenter = HotkeyCenter(perform: { [weak self] command in self?.perform(command) })
        hotkeyCenter?.start()

        updater.start()

        // The CLI's end of the automation channel (docs/03 §8.4). A second Kadr would
        // find the name taken, and should not pretend to own automation.
        let listener = AutomationListener { [weak self] command, reply in
            guard let self else {
                reply(.failed("Kadr is shutting down."))
                return
            }
            automation.perform(command, completion: reply)
        }
        if listener.start() {
            automationListener = listener
        } else {
            logger.error("Another Kadr already owns the automation port")
        }

        // A finished recording lands in the same overlay as a screenshot (docs/03 §1.8).
        recording.onFinished = { [weak self] result in
            self?.areaCapture.showRecording(at: result.fileURL)
        }
        // A stitched page goes to the overlay and the editor (docs/03 §1.6).
        scrollCapture.onFinished = { [weak self] url, size in
            self?.areaCapture.showScrollingCapture(at: url, pixelSize: size)
        }
        // The menu bar shows the recording's state and elapsed time (docs/03 §8.1).
        recording.onStateChanged = { [weak self] in
            self?.refreshStatusItemIcon()
        }

        // Clear staged captures the user never acted on (docs/03 §2). Once, at launch —
        // never on a timer.
        CaptureOutput(settings: settings).sweepStaging()

        // Open the library after the status item is up, so SQLite cannot eat into the
        // launch budget (PRD §8). Retention (including session-only wipe) runs here.
        history.start()

        // Re-hide icons if the user left them hidden, and restore a wallpaper that
        // outlived a crash mid-capture (docs/03 §7).
        desktopHygiene.reassertOnLaunch()

        // docs/04 §3.3: the user can flip this in System Settings, so never cache it
        // across launches. Deliberately after the status item, so ServiceManagement
        // loading cannot eat into the launch budget.
        loginItem.refresh()

        // First launch goes straight to onboarding; every later launch just checks
        // whether the grant is still there (docs/03 §8.2, docs/04 §4.1).
        permissions.refresh()
        if !settings.hasCompletedOnboarding {
            onboarding.show()
        }
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
        if performCapture(command) {
            return
        }
        switch command {
        case .captureScrolling:
            scrollCapture.begin()
        case .recordRegion:
            recording.beginRegionRecording()
        case .recordDisplay:
            recording.beginDisplayRecording()
        case .toggleDesktopIcons:
            desktopHygiene.toggleUserHide()
        default:
            break
        }
    }

    /// The commands that go through the selection overlay. Returns whether it was one.
    private func performCapture(_ command: CaptureCommand) -> Bool {
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
        case .pickColor:
            areaCapture.beginColorPick()
        case .freezeScreen:
            areaCapture.toggleFreezeScreen()
        default:
            return false
        }
        return true
    }

    /// Keeps the menu bar in step with the recording.
    private func refreshStatusItemIcon() {
        guard recording.isRecording else {
            statusItemController?.showIdleIcon()
            return
        }
        statusItemController?.showRecordingIcon(
            elapsed: recording.elapsedText,
            isPaused: recording.state == .paused
        )
    }

    /// The menu's view of a recording in progress, or nil when nothing is recording.
    private func currentRecordingControls() -> RecordingControls? {
        guard recording.isRecording else { return nil }
        return RecordingControls(
            elapsedText: recording.elapsedText,
            isPaused: recording.state == .paused,
            stop: { [weak self] in self?.recording.stop() },
            togglePause: { [weak self] in
                guard let self else { return }
                if recording.state == .paused {
                    recording.resume()
                } else {
                    recording.pause()
                }
            },
            cancel: { [weak self] in self?.recording.cancel() }
        )
    }

    /// Reopens onboarding, which is also how the user recovers a revoked grant.
    func showOnboarding() {
        onboarding.show()
    }

    private func openSettings() {
        settingsWindowController.show()
    }

    /// The command layer, for the Shortcuts actions (docs/03 §8.4).
    @MainActor
    static func performAutomation(_ command: AppCommand, completion: @escaping (AutomationResponse) -> Void) {
        shared.automation.perform(command, completion: completion)
    }

    /// Copies a file into the capture library (docs/03 §8.4 `add-to-history`).
    ///
    /// How a `.kadr` project saved in the editor gets into History: the editor writes the
    /// file and opens `kadr://add-to-history`, because the library belongs to the agent.
    private func addToHistory(_ url: URL) -> Bool {
        guard let draft = ProjectIngest().draft(for: url) else { return false }
        history.ingest(draft)
        return true
    }

    private func openHistory() {
        history.showWindow { [weak self] record in
            self?.areaCapture.reopenFromHistory(record)
        }
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

    /// Warns before quitting with captures nobody has saved (docs/09 U2.1).
    ///
    /// A staged capture lives in the staging area and the 24-hour sweep deletes it. Quitting
    /// with cards on screen therefore throws work away, silently, which is the one thing a
    /// capture tool must not do — the user's mental model is that a card on screen is a
    /// screenshot they still have.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only if the capture layer exists: an agent that never captured anything has
        // nothing to lose, and asking would build the layer to find that out.
        guard let quickAccess = areaCaptureStorage?.quickAccess else { return .terminateNow }
        let unsaved = quickAccess.unsavedItems
        guard !unsaved.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = unsaved.count == 1
            ? "One capture has not been saved."
            : "\(unsaved.count) captures have not been saved."
        alert.informativeText = "Captures still on screen are kept temporarily and cleared "
            + "within a day. Saving them puts them in your capture folder."
        alert.addButton(withTitle: unsaved.count == 1 ? "Save and Quit" : "Save All and Quit")
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate()

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let saved = quickAccess.finalizeAllStaged()
            logger.info("Saved \(saved, privacy: .public) capture(s) before quitting")
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        automationListener?.stop()
        desktopHygiene.prepareForTermination()
    }

    // MARK: - URL scheme (docs/03 §8.4)

    /// Handles `kadr://…`. The answer is dropped: a URL has nowhere to send one, which is
    /// exactly why the CLI exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                let command = try AutomationParser.command(from: url)
                automation.perform(command) { [weak self] response in
                    guard response.status != .ok else { return }
                    let message = response.message ?? response.status.rawValue
                    self?.logger.error("URL command failed: \(message, privacy: .public)")
                }
            } catch {
                let message = (error as? AutomationError)?.localizedDescription ?? error.localizedDescription
                logger.error("Could not run \(url.absoluteString, privacy: .public): \(message, privacy: .public)")
            }
        }
    }
}
