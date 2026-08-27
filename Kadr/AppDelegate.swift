import AppKit
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
    private lazy var areaCapture = AreaCaptureCoordinator(
        engine: captureEngine,
        permissions: permissions,
        settings: settings
    )
    private lazy var recording = RecordingCoordinator(
        captureEngine: captureEngine,
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
            additionalItems: { [weak self] in self?.debugMenuItems() ?? [] }
        )
        endLaunchInterval()

        hotkeyCenter = HotkeyCenter(perform: { [weak self] command in self?.perform(command) })
        hotkeyCenter?.start()

        updater.start()

        // A finished recording lands in the same overlay as a screenshot (docs/03 §1.8).
        recording.onFinished = { [weak self] result in
            self?.areaCapture.showRecording(at: result.fileURL)
        }
        // The menu bar shows the recording's state and elapsed time (docs/03 §8.1).
        recording.onStateChanged = { [weak self] in
            self?.refreshStatusItemIcon()
        }

        // Clear staged captures the user never acted on (docs/03 §2). Once, at launch —
        // never on a timer.
        CaptureOutput(settings: settings).sweepStaging()

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
        case .recordRegion:
            recording.beginRegionRecording()
        case .recordDisplay:
            recording.beginDisplayRecording()
        }
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
