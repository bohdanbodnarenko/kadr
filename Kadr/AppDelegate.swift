import AppKit
import AutomationKit
import CaptureCore
import os
import OverlayKit
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
        created.onArmedStateChanged = { [weak self] in
            self?.refreshStatusItemIcon()
        }
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

    /// How many recordings are waiting to be recovered, counted off the main thread so the
    /// status menu can show it without touching the disk (docs/09 U3.1).
    let unfinishedRecordings = UnfinishedRecordingsCounter()

    /// The floating Stop/Pause/Discard bar, built only while recording (docs/03 §1.8).
    let recordingControlBar = RecordingControlBar()
    /// One camera session for the picker preview and the studio file. Constructed empty;
    /// opening a device happens only when the user arms the camera.
    let cameraRecorder = CameraFileRecorder()

    /// Record mode: pick a target and the options, then start (docs/03 §1.4).
    ///
    /// Built on first use like everything else here — an agent that never records never
    /// constructs it.
    lazy var recordSetup: RecordSetupHUD = {
        let hud = RecordSetupHUD(
            bar: recordingControlBar,
            settings: settings,
            record: { [weak self] target in
                self?.recording.startAfterCountdown(target: target)
            },
            pickWindow: { [weak self] completion in
                self?.recording.pickWindow { selection in
                    if let selection {
                        self?.recording.beginWindowHighlight(from: selection)
                    }
                    completion(selection)
                }
            },
            pickArea: { [weak self] completion in
                self?.recording.pickRegion(completion: completion)
            },
            cameraPreview: { [weak self] enabled in
                guard let self else { return }
                cameraRecorder.setPreview(
                    enabled: enabled,
                    deviceID: settings.recordingCameraDeviceID
                )
            }
        )
        hud.onBackToIsland = { [weak self] frame in
            self?.allInOne.present(morphingFrom: frame)
        }
        return hud
    }()

    /// All-in-One capture HUD (docs/03 §1.4). Built on first use.
    lazy var allInOne: AllInOneHUD = {
        let hud = AllInOneHUD(
            settings: settings,
            perform: { [weak self] mode in self?.performAllInOne(mode) },
            pickDisplay: { [weak self] id in self?.areaCapture.captureDisplay(id) },
            performTool: { [weak self] tool in self?.performAllInOneTool(tool) },
            desktopIconsHidden: { [weak self] in self?.desktopHygiene.isHidingIcons ?? false }
        )
        hud.onShowingChanged = { [weak self] in
            self?.refreshStatusItemIcon()
        }
        hud.onPresented = { [weak self] view, bar in
            guard let self, coachMarks.isTourNeeded else { return }
            coachMarks.startIslandTour(pointingAt: bar, in: view)
        }
        hud.onClosed = { [weak self] in
            self?.coachMarks.islandDidClose()
        }
        return hud
    }()

    /// First-run tips: under the menu-bar icon, and over the island's first opening.
    lazy var coachMarks: CoachMarks = {
        let coach = CoachMarks(settings: settings)
        coach.openIsland = { [weak self] in
            guard let self, !allInOne.isShowing else { return }
            allInOne.present()
        }
        coach.openShortcutSettings = { [weak self] in
            self?.settingsWindowController.show(tab: .shortcuts)
        }
        return coach
    }()

    /// Shows the menu-bar hint once the icon is up and nothing else is asking for attention.
    func scheduleMenuBarHint() {
        guard !settings.hasSeenMenuBarHint else { return }
        coachMarks.scheduleMenuBarHint { [weak self] in
            self?.statusItemController?.statusItem.button
        }
    }

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
            self?.unfinishedRecordings.refresh()
        }
        created.onStudioSessionReady = { [weak self] session, _ in
            guard let self else { return }
            guard settings.afterCaptureActions(for: .recording).contains(.openEditor) else { return }
            EditorLauncher().open(session.directory)
        }
        created.onStateChanged = { [weak self] in
            self?.refreshStatusItemIcon()
        }
        created.onAudioLevel = { [weak self] level in
            self?.recordingControlBar.setAudioLevel(level)
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
    var automationListener: AutomationListener?

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
        model: makeOnboardingModel(),
        settings: settings
    )

    private func makeOnboardingModel() -> OnboardingModel {
        let model = OnboardingModel(permissions: permissions, settings: settings, loginItem: loginItem)
        model.onOpenPractice = { [weak self] url in
            self?.areaCapture.quickAccess.openInEditor(url)
        }
        return model
    }

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
            unfinishedRecordings.refresh()
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

    private func installStatusItem() {
        statusItemInterval = signposter.beginInterval("launchToStatusItem")
        statusItemController = StatusItemController(
            perform: { [weak self] command in self?.perform(command) },
            openSettings: { [weak self] in self?.openSettings() },
            restoreRecentlyClosed: { [weak self] in self?.areaCapture.restoreRecentlyClosed() },
            closeAllPins: { [weak self] in self?.areaCapture.closeAllPins() },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            // A preflight, not a probe: it reads the grant without prompting or capturing.
            needsSetup: { [weak self] in self?.permissions.refresh().needsUserAction ?? false },
            recordingControls: { [weak self] in self?.currentRecordingControls() },
            additionalItems: { [weak self] in self?.debugMenuItems() ?? [] },
            history: history,
            reopenFromHistory: { [weak self] record in self?.areaCapture.openFromHistory(record) },
            canRestore: { [weak self] in self?.areaCaptureStorage?.canRestoreRecentlyClosed ?? false },
            openHistory: { [weak self] in self?.openHistory() },
            unfinishedRecordings: { [weak self] in self?.unfinishedRecordings.latest ?? 0 },
            refreshUnfinishedRecordings: { [weak self] completion in
                self?.unfinishedRecordings.refresh(completion: completion)
            },
            recoverRecordings: { [weak self] in self?.recoverUnfinishedRecordings() },
            overlayCardCount: { [weak self] in self?.areaCaptureStorage?.overlayCardCount ?? 0 },
            overlaysAreHidden: { [weak self] in self?.areaCaptureStorage?.overlaysAreHidden ?? false },
            pinCount: { [weak self] in self?.areaCaptureStorage?.pinCount ?? 0 },
            pinsAreHidden: { [weak self] in self?.areaCaptureStorage?.pinsAreHidden ?? false }
        )
        attachStatusItemDrop()
        statusItemController?.applyMenuBarVisibility(settings.showsMenuBarIcon)
        statusItemController?.onMenuBarVisibilityChange = { [weak self] visible in
            self?.settings.showsMenuBarIcon = visible
        }
        statusItemController?.onIconClicked = { [weak self] in
            guard let self, !settings.hasSeenMenuBarHint else { return }
            coachMarks.dismissMenuBarHint()
        }
        endStatusItemInterval()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppMenu.shared.install()
        applyOverlayCaptureVisibility()
        installStatusItem()

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
        history.onPin = { [weak self] record in
            guard let self, let url = history.fileURL(for: record) else { return }
            _ = areaCapture.quickAccess.pinFile(at: url)
        }
        history.onAnnotate = { [weak self] record in
            guard let self, let url = history.fileURL(for: record) else { return }
            areaCapture.quickAccess.annotateFile(at: url)
        }
        history.onCopyText = { [weak self] record in
            guard let self, let url = history.fileURL(for: record) else { return }
            areaCapture.quickAccess.recognizeText(at: url)
        }

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

        // First launch goes straight to onboarding; a grant that needed a restart
        // comes back to the permissions screen; every later launch just checks
        // whether the grant is still there (docs/03 §8.2, docs/04 §4.1).
        permissions.refresh()
        if settings.resumeOnboardingAtPermissions || !settings.hasCompletedOnboarding {
            // The hint waits for the welcome to close: two things asking for attention at
            // once is one too many.
            onboarding.onClosed = { [weak self] in self?.scheduleMenuBarHint() }
            onboarding.show()
        } else {
            scheduleMenuBarHint()
        }
        // Bound to a local: a log message is an autoclosure, so referring to a property
        // inside it would need an explicit `self.` that SwiftFormat then strips again.
        let loginItemState = String(describing: loginItem.state)
        logger.info("Login item state: \(loginItemState, privacy: .public)")
    }

    private func applyOverlayCaptureVisibility() {
        CaptureVisibility.includesOverlays = settings.includesOverlaysInCaptures
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

    /// Dock / Finder "Open" while Kadr is already running (docs/16 APP-1, APP-2).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if recordingStorage?.isRecording == true {
            refreshRecordingControlBar()
        } else if statusItemController?.statusItem.isVisible == true {
            statusItemController?.popIdleMenu()
        } else {
            openSettings()
        }
        return false
    }
}
