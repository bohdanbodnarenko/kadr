import AppKit
import AutomationKit
import CaptureCore
import os
import RecordingCore
import SelectionUI
import SettingsKit
import Shared
import StudioSession

/// The resident agent (docs/04 §1, §3).
///
/// `NSApplicationMain` with a plain delegate, `LSUIElement`, `.accessory` activation:
/// no storyboard, no SwiftUI scene, no timers. Launch registers a status item and the
/// global hotkeys and then does nothing at all until the user asks for something —
/// that idle path is the PRD §8 RAM and CPU budget.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// NSApplication.delegate is *unretained* — keep a strong reference.
    static let shared = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = shared
        delegate.beginLaunchInterval()
        app.delegate = delegate
        app.run()
    }

    let logger = KadrLog.logger(.app)
    private let signposter = KadrLog.signposter(.app)
    private var launchInterval: OSSignpostIntervalState?
    private var statusItemInterval: OSSignpostIntervalState?
    private var launchStartedAt: ContinuousClock.Instant?

    var statusItemController: StatusItemController?
    private var hotkeyCenter: HotkeyCenter?

    /// The capture layer. Constructing it touches no framework — ScreenCaptureKit is
    /// not messaged until the first capture, which is what keeps the idle budget
    /// (docs/04 §7.1).
    lazy var captureEngine = CaptureEngine()
    lazy var permissions = PermissionCoordinator()
    // Settings state is Foundation-only and cheap; the window that presents it is not,
    // and is built on first use.
    lazy var settings = AppSettings()
    lazy var history = HistoryController(settings: settings)
    lazy var desktopHygiene = DesktopHygieneController(settings: settings)
    /// Written out rather than `lazy` so the quit path can ask whether the capture layer
    /// was ever built without building it: a `lazy var` read at termination would
    /// construct the whole thing to discover it has nothing to say (docs/04 §7.1).
    var areaCaptureStorage: AreaCaptureCoordinator?
    var areaCapture: AreaCaptureCoordinator {
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

    var scrollCaptureStorage: ScrollCaptureCoordinator?
    var scrollCapture: ScrollCaptureCoordinator {
        if let scrollCaptureStorage {
            return scrollCaptureStorage
        }
        let created = ScrollCaptureCoordinator(
            captureEngine: captureEngine,
            permissions: permissions,
            settings: settings,
            output: CaptureOutput(settings: settings)
        )
        created.onFinished = { [weak self] url, size in
            self?.areaCapture.showScrollingCapture(at: url, pixelSize: size)
        }
        scrollCaptureStorage = created
        return created
    }

    /// The floating Stop/Pause/Discard bar, built only while recording (docs/03 §1.8).
    let recordingControlBar = RecordingControlBar()
    /// One camera session for the picker preview and the studio file. Constructed empty;
    /// opening a device happens only when the user arms the camera.
    let cameraRecorder = CameraFileRecorder()

    /// Record mode: pick a target and the options, then start (docs/03 §1.4).
    ///
    /// Built on first use like everything else here — an agent that never records never
    /// constructs it.
    lazy var recordSetup = RecordSetupHUD(
        bar: recordingControlBar,
        settings: settings,
        start: { [weak self] target in
            guard let self else { return }
            switch target {
            case .area: recording.beginRegionRecording()
            case .window: recording.beginWindowRecording()
            case .screen: recording.beginDisplayRecording()
            }
        },
        startDisplay: { [weak self] displayID in
            self?.recording.beginDisplayRecording(displayID)
        },
        cameraPreview: { [weak self] enabled in
            guard let self else { return }
            cameraRecorder.setPreview(
                enabled: enabled,
                deviceID: settings.recordingCameraDeviceID
            )
        }
    )

    /// All-in-One capture HUD (docs/03 §1.4). Built on first use.
    lazy var allInOne = AllInOneHUD(
        settings: settings,
        perform: { [weak self] mode in self?.performAllInOne(mode) }
    )

    var recordingStorage: RecordingCoordinator?
    var recording: RecordingCoordinator {
        if let recordingStorage {
            return recordingStorage
        }
        let created = RecordingCoordinator(
            captureEngine: captureEngine,
            permissions: permissions,
            settings: settings,
            hygiene: desktopHygiene,
            camera: cameraRecorder
        )
        created.onFinished = { [weak self] result, exportGIF in
            self?.areaCapture.showRecording(at: result.fileURL, exportGIF: exportGIF)
        }
        created.onStudioSessionReady = { [weak self] session, _ in
            guard let self else { return }
            guard settings.afterCaptureActions(for: .recording).contains(.openEditor) else { return }
            EditorLauncher().open(session.directory)
        }
        created.onStateChanged = { [weak self] in
            self?.refreshStatusItemIcon()
        }
        recordingStorage = created
        return created
    }

    /// The automation frontends (docs/03 §8.4). The router is built lazily; the listener
    /// is one run-loop source with no thread and no timer behind it, which is what lets
    /// automation exist without costing the idle budget (PRD §8).
    lazy var automation = AutomationRouter(
        areaCapture: areaCapture,
        scrollCapture: scrollCapture,
        recording: recording,
        hygiene: desktopHygiene,
        openSettings: { [weak self] tab in self?.settingsWindowController.show(tab: tab) },
        openHistory: { [weak self] in self?.openHistory() },
        addToHistory: { [weak self] url in self?.addToHistory(url) ?? false },
        openAllInOne: { [weak self] in self?.allInOne.present() }
    )
    private var automationListener: AutomationListener?

    private lazy var loginItem = LoginItemController()
    lazy var settingsWindowController = SettingsWindowController(
        settings: settings,
        loginItem: loginItem,
        history: history
    )

    /// Sparkle is constructed in `start()`, after the launch interval closes, so the
    /// controller is not mapped before the app can answer a hotkey (docs/10 R2.3).
    private lazy var updater = UpdaterManager.shared

    lazy var onboarding = OnboardingWindowController(
        model: OnboardingModel(permissions: permissions, settings: settings, loginItem: loginItem),
        settings: settings
    )

    #if DEBUG
        var debugCaptureMenu: DebugCaptureMenu?
    #endif

    // MARK: - Launch

    /// Reopens the recordings a crash left mid-edit (docs/09 U3.1).
    ///
    /// Every one of them, rather than a chooser. A session only counts as unfinished when
    /// it has footage and an uncommitted draft — somebody was editing it when the process
    /// went away — and there is rarely more than one. Asking which of your interrupted
    /// recordings you would like back is a question with an obvious answer.
    private func recoverUnfinishedRecordings() {
        let sessions = StudioSessionRecorder.unfinishedSessions()
        guard !sessions.isEmpty else { return }
        let launcher = EditorLauncher()
        for session in sessions {
            launcher.open(session.directory)
        }
        logger.info("Reopened \(sessions.count, privacy: .public) unfinished recording(s)")
    }

    /// Recovers in-flight recordings before sweeping empty session packages, so a crash
    /// mid-record is not cleaned up as litter (docs/03 §1.8).
    private func recoverInterruptedFootageThenSweep() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let count = await RecordingCrashRecovery.recover(
                saveFolder: settings.saveFolder,
                present: { [weak self] url in self?.areaCapture.showRecording(at: url) }
            )
            if count > 0 {
                RecordingCrashRecovery.announce(count)
            }
            StudioSessionRecorder.sweep()
        }
    }

    private func attachStatusItemDrop() {
        statusItemController?.openDroppedFile = { [weak self] url in
            self?.areaCapture.quickAccess.openInEditor(url)
        }
    }

    private func beginLaunchInterval() {
        launchStartedAt = .now
        launchInterval = signposter.beginInterval("launchToHotkeyArmed")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItemInterval = signposter.beginInterval("launchToStatusItem")
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
            reopenFromHistory: { [weak self] record in self?.areaCapture.openFromHistory(record) },
            canRestore: { [weak self] in
                (self?.areaCapture.canRestoreRecentlyClosed ?? false) || (self?.history.hasItems ?? false)
            },
            openHistory: { [weak self] in self?.openHistory() },
            unfinishedRecordings: { StudioSessionRecorder.unfinishedCount() },
            recoverRecordings: { [weak self] in self?.recoverUnfinishedRecordings() },
            desktopIconsHidden: { [weak self] in self?.desktopHygiene.isHidingIcons ?? false },
            overlayCardCount: { [weak self] in self?.areaCaptureStorage?.overlayCardCount ?? 0 },
            overlaysAreHidden: { [weak self] in self?.areaCaptureStorage?.overlaysAreHidden ?? false },
            pinCount: { [weak self] in self?.areaCaptureStorage?.pinCount ?? 0 },
            pinsAreHidden: { [weak self] in self?.areaCaptureStorage?.pinsAreHidden ?? false }
        )
        attachStatusItemDrop()
        endStatusItemInterval()

        hotkeyCenter = HotkeyCenter(perform: { [weak self] command in self?.perform(command) })
        hotkeyCenter?.start()
        endLaunchInterval()

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

        // Clear staged captures the user never acted on (docs/03 §2). Once, at launch —
        // never on a timer.
        CaptureOutput(settings: settings).sweepStaging()
        recoverInterruptedFootageThenSweep()

        // Open the library after the status item is up, so SQLite cannot eat into the
        // launch budget (PRD §8). Retention (including session-only wipe) runs here.
        history.start()

        // Pins from the last session, after History so a capture that was only in the
        // library is still on disk (docs/03 §4 P2). Skip constructing the capture layer
        // when nothing was pinned — idle RAM stays the empty-agent budget.
        if PinStore.applicationSupport()?.hasRecords == true {
            areaCapture.restorePersistedPins()
        }

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

    /// Ends the launch→statusItemReady interval budgeted at < 150 ms (docs/10 R2.7).
    private func endStatusItemInterval() {
        if let statusItemInterval {
            signposter.endInterval("launchToStatusItem", statusItemInterval)
            self.statusItemInterval = nil
        }
        if let launchStartedAt {
            let milliseconds = Double(launchStartedAt.duration(to: .now).components.attoseconds) / 1e15
            logger.info("Status item ready in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        }
    }

    /// Ends the launch→hotkeyArmed interval budgeted at < 300 ms (PRD §8, docs/10 R2.7).
    private func endLaunchInterval() {
        if let launchInterval {
            signposter.endInterval("launchToHotkeyArmed", launchInterval)
            self.launchInterval = nil
        }
        if let launchStartedAt {
            let milliseconds = Double(launchStartedAt.duration(to: .now).components.attoseconds) / 1e15
            logger.info("Hotkeys armed in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
            self.launchStartedAt = nil
        }
    }

    // MARK: - Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing Settings must not quit the agent.
        false
    }

    /// Warns before quitting with a recording in flight or captures nobody has saved
    /// (docs/09 U2.1).
    ///
    /// A live recording has to be finished, not killed: ⌘Q and a Sparkle relaunch used
    /// to tear the writer down and throw the take away. Captures still on a card are
    /// kept only temporarily, so those get the same "save or discard" question.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let recording = recordingStorage, recording.state.isActive {
            if recording.isCountingDown {
                _ = recording.cancelCountdown()
            } else if recording.state == .finishing {
                recording.finishForTermination {
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            } else {
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = "A screen recording is still in progress."
                alert.informativeText = "Kadr will finish and save the recording before quitting. "
                    + "This can take a moment for a long recording."
                alert.alertStyle = .warning
                // Cancel is leftmost so Return does not discard the take.
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Finish Recording and Quit")
                guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
                recording.finishForTermination {
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
        }

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
