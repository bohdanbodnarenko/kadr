import AppKit
import AutomationKit
import KeyboardShortcuts
import os
import RecordingCore
import SelectionUI
import SettingsKit
import Shared

/// Running a command, wherever it came from — a hotkey, the menu, the URL scheme or the CLI
/// (docs/03 §8.1, §8.4).
///
/// Split from the delegate because the delegate is about *starting the app* and this is
/// about what the app does once it is running, and because the recording commands stopped
/// being one-liners: the record hotkeys toggle now, so the same key that starts a recording
/// is the one that ends it.
@MainActor
extension AppDelegate {
    // MARK: - Commands

    func perform(_ command: CaptureCommand) {
        logger.info("Command requested: \(command.rawValue, privacy: .public)")
        if performCapture(command) {
            return
        }
        if performOverlay(command) {
            return
        }
        switch command {
        case .captureScrolling:
            scrollCapture.begin()
        case .recordRegion, .recordDisplay, .stopRecording, .recordSetup:
            performRecording(command)
        case .toggleDesktopIcons:
            desktopHygiene.toggleUserHide()
        case .allInOne, .captureArea, .captureWindow, .captureFullscreen, .captureText,
             .pickColor, .capturePreviousArea, .captureAreaAndCopy, .captureAreaAndSave,
             .selfTimer, .freezeScreen, .closeAllOverlays, .saveAllOverlays, .hideOverlays, .focusOverlay,
             .hidePins, .pinClipboard, .togglePinClickThrough:
            break
        case .openHistory:
            openHistory()
        case .openSaveFolder:
            openSaveFolder()
        }
    }

    /// The commands that go through the selection overlay. Returns whether it was one.
    func performCapture(_ command: CaptureCommand) -> Bool {
        if performCaptureAndAction(command) {
            return true
        }
        if performCaptureAid(command) {
            return true
        }
        switch command {
        case .captureArea:
            areaCapture.beginAreaCapture()
        case .capturePreviousArea:
            areaCapture.capturePreviousArea()
        case .captureWindow:
            areaCapture.beginWindowCapture()
        case .captureFullscreen:
            areaCapture.captureFullscreen()
        case .captureText:
            areaCapture.beginTextCapture()
        case .pickColor:
            areaCapture.beginColorPick()
        default:
            return false
        }
        return true
    }

    /// Freeze, self-timer, and All-in-One — capture aids rather than a region tool.
    func performCaptureAid(_ command: CaptureCommand) -> Bool {
        switch command {
        case .freezeScreen:
            areaCapture.toggleFreezeScreen()
        case .selfTimer:
            areaCapture.beginSelfTimedAreaCapture()
        case .allInOne:
            // One key for "show me the capture modes": opens or closes the island, and
            // from the recorder steps back to it rather than stacking a second bar.
            if recordingControlBar.isShowingPicker {
                recordSetup.goBack()
            } else {
                allInOne.toggle()
            }
        default:
            return false
        }
        return true
    }

    /// Capture-and-action family: same overlay, a forced post-capture action (CleanShot §5).
    func performCaptureAndAction(_ command: CaptureCommand) -> Bool {
        switch command {
        case .captureAreaAndCopy:
            areaCapture.arm(CaptureOverrides(action: .copy), completion: nil)
            areaCapture.beginAreaCapture()
        case .captureAreaAndSave:
            areaCapture.arm(CaptureOverrides(action: .save), completion: nil)
            areaCapture.beginAreaCapture()
        default:
            return false
        }
        return true
    }

    /// Overlay stack commands (CleanShot §6.3). Returns whether it was one.
    func performOverlay(_ command: CaptureCommand) -> Bool {
        switch command {
        case .closeAllOverlays:
            areaCapture.closeAllOverlays()
        case .saveAllOverlays:
            areaCapture.saveAllOverlays()
        case .hideOverlays:
            areaCapture.toggleOverlaysHidden()
        case .focusOverlay:
            areaCapture.quickAccess.focusFromKeyboard()
        case .hidePins:
            areaCapture.togglePinsHidden()
        case .pinClipboard:
            areaCapture.pinClipboard()
        case .togglePinClickThrough:
            areaCapture.pins.toggleClickThroughUnderPointer()
        default:
            return false
        }
        return true
    }

    /// The island's tools menu (docs/03 §1.4, §7). Each is the command the menu-bar menu
    /// used to list, so a hotkey, the URL scheme and the island all run the same code.
    func performAllInOneTool(_ tool: AllInOneTool) {
        switch tool {
        case .previousArea: perform(.capturePreviousArea)
        case .selfTimer: perform(.selfTimer)
        case .freezeScreen: perform(.freezeScreen)
        case .desktopIcons: perform(.toggleDesktopIcons)
        case .pinClipboard: perform(.pinClipboard)
        case .systemPicker: areaCapture.captureWithSystemPicker()
        case .captureFolder: perform(.openSaveFolder)
        case .history: perform(.openHistory)
        }
    }

    /// What the All-in-One strip starts (docs/03 §1.4).
    func performAllInOne(_ mode: AllInOneMode) {
        let frontmost = allInOne.takeFrontmostBeforePresent()
        switch mode {
        case .area: areaCapture.beginOverlayCapture(mode: .area, frontmost: frontmost)
        case .window: areaCapture.beginOverlayCapture(mode: .window, frontmost: frontmost)
        case .screen: areaCapture.captureAllDisplays()
        case .record:
            let source = allInOne.takeHandOffFrame()
            // A take is live, starting or saving: the recorder would only arm a second one
            // that orphans it. Bring the take's own controls forward instead (docs/17 T-REC-3).
            if recordingStorage?.isBusy == true {
                refreshRecordingControlBar()
            } else if recordSetup.isShowing {
                recordSetup.toggle()
            } else {
                recordSetup.present(morphingFrom: source)
            }
        case .gif: recording.beginGIFRecording()
        case .scrolling: scrollCapture.begin()
        case .ocr: areaCapture.beginOverlayCapture(mode: .area, purpose: .recognizeText, frontmost: frontmost)
        case .color: areaCapture.beginColorPick()
        }
    }

    /// Whether a capture surface is on screen, so the menu bar can say so (docs/14 UX-08A).
    ///
    /// Reads `areaCaptureStorage` rather than `areaCapture`: an agent that has never
    /// captured anything must not build the capture layer to answer this. The picker is
    /// read off the control bar for the same reason — `recordSetup` is lazy.
    var isCaptureArmed: Bool {
        areaCaptureStorage?.isArmed == true
            || recordingControlBar.isShowingPicker
            || recordingStorage?.isSelectingTarget == true
            || allInOne.isShowing
            || recordingStorage?.isCountingDown == true
    }

    /// Keeps the menu bar and the floating controls in step with the recording.
    func refreshStatusItemIcon() {
        // Through `.finishing` too: the bar says "Saving…" until the file exists, rather
        // than going idle while a multi-second join is still running (docs/17 T-REC-4).
        guard let recording = recordingStorage, recording.isBusy else {
            // Recording always wins; armed is what is left when a capture surface is up.
            if isCaptureArmed {
                statusItemController?.showArmedIcon()
            } else {
                statusItemController?.showIdleIcon()
            }
            if !recordingControlBar.isShowingPicker {
                recordingControlBar.dismiss()
            }
            return
        }
        statusItemController?.showRecordingIcon(
            elapsed: recording.elapsedText,
            isPaused: recording.state == .paused
        )
        refreshRecordingControlBar()
    }

    /// Shows the floating controls while a recording runs, and keeps their clock moving.
    ///
    /// Driven from the same state change as the menu-bar icon, so the two can never
    /// disagree about whether a recording exists. Optional, because docs/03 §1.8 calls it
    /// "an optional floating stop button" — but on by default, since the app shipped with
    /// no on-screen way to stop at all and that is what people hit first.
    func refreshRecordingControlBar() {
        // With the bar off, Stop lives in the menu bar and on the stop shortcut. With no
        // shortcut bound either, the bar shows anyway: a take must always have an on-screen
        // Stop (docs/18 REC-2).
        let hasStopShortcut = KeyboardShortcuts.getShortcut(for: .stopRecording) != nil
        guard settings.recordingShowsControlBar || !hasStopShortcut else {
            recordingControlBar.dismiss()
            return
        }
        guard let controls = currentRecordingControls() else {
            recordingControlBar.dismiss()
            return
        }
        // During the countdown the bar offers the three things a recording is most often got
        // wrong by forgetting — microphone, system sound, camera — instead of a clock that
        // has not started (docs/03 §1.8's control strip, folded into the wait that already
        // exists rather than added as a step of its own).
        let preRoll: RecordingControlBar.PreRoll? = recordingStorage?.isCountingDown == true
            ? RecordingControlBar.PreRoll(
                remaining: recordingStorage?.countdownRemaining ?? 0,
                startNow: { [weak self] in self?.recordingStorage?.startCountdownNow() },
                cancel: { [weak self] in self?.recording.cancel() }
            )
            : nil

        if recordingControlBar.isShowing {
            recordingControlBar.update(controls: controls, settings: settings, preRoll: preRoll)
        } else {
            recordingControlBar.show(controls: controls, settings: settings, preRoll: preRoll)
        }
    }

    /// The menu's view of a recording in progress, or nil when nothing is recording.
    func currentRecordingControls() -> RecordingControls? {
        guard let recording = recordingStorage, recording.isBusy else { return nil }
        let isSaving = recording.state == .finishing
        return RecordingControls(
            elapsedText: recording.elapsedText,
            isPaused: recording.state == .paused,
            // The bar's own Stop, and the menu's: both are reached by taking the pointer
            // there, and that trip comes off the end of the file (docs/03 §1.8). The
            // shortcut below does not, because nothing was navigated to.
            stop: { [weak self] in self?.recording.stop(trimmingTravel: true) },
            togglePause: {
                if recording.state == .paused {
                    recording.resume()
                } else {
                    recording.pause()
                }
            },
            cancel: { [weak self] in self?.recording.cancel() },
            restart: { [weak self] in self?.recording.restart() },
            audioLevel: recording.audioMeter.peak,
            microphoneIsSilent: recording.microphoneIsSilent,
            microphoneDropped: recording.microphoneDropped,
            notice: recording.liveNotice,
            isTransitioning: recording.isTransitioning,
            isSaving: isSaving
        )
    }

    /// Finish Setup…: straight to the grants that are missing (docs/17 T-SH-4).
    ///
    /// It used to replay the whole welcome and re-arm every tip, which is not what
    /// somebody who only needs to allow Screen Recording asked for.
    func finishSetup() {
        onboarding.onClosed = { [weak self] in self?.scheduleMenuBarHint() }
        onboarding.show(startingAt: .permissions)
    }

    /// Help ▸ Show Welcome…: the whole introduction again.
    func showOnboarding() {
        // Replaying the welcome re-arms every tip too. Somebody asking to be shown the
        // introduction again is asking about the whole app, and the explanations that only
        // appear over the real thing are the parts they are most likely to have missed.
        coachMarks.resetAll()
        onboarding.onClosed = { [weak self] in self?.scheduleMenuBarHint() }
        onboarding.show()
    }

    func openSettings() {
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
    func addToHistory(_ url: URL) -> Bool {
        guard let draft = ProjectIngest().draft(for: url) else { return false }
        history.ingest(draft)
        return true
    }

    func openHistory() {
        history.showWindow(
            reopen: { [weak self] record in self?.areaCapture.reopenFromHistory(record) },
            openStudio: { [weak self] record in self?.areaCapture.openFromHistory(record) }
        )
    }

    /// Creates the save folder if needed and reveals it (docs/16 X-7).
    func openSaveFolder() {
        let folder = settings.saveFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            FailurePresenter.present(message: "Couldn’t open the capture folder. \(error.localizedDescription)")
        }
    }

    /// Debug builds get a submenu that drives CaptureCore directly (docs/06 M1).
    func debugMenuItems() -> [NSMenuItem] {
        #if DEBUG
            if debugCaptureMenu == nil {
                debugCaptureMenu = DebugCaptureMenu(engine: captureEngine, permissions: permissions)
            }
            return [debugCaptureMenu].compactMap { $0?.makeMenuItem() }
        #else
            return []
        #endif
    }

    /// The four recording commands, which all share one rule.
    ///
    /// Every one of them stops a running recording rather than doing its own thing (docs/03
    /// §1.8). Pressing the shortcut you started with is the first thing anybody tries when
    /// they want to stop, and it used to be swallowed by `beginRegionRecording`'s
    /// `!isRecording` guard — so the app looked like it had no way out at all.
    private func performRecording(_ command: CaptureCommand) {
        if recording.isRecording, command != .stopRecording {
            recording.stop()
            return
        }
        // Still saving the last take. Opening the recorder now would arm a start the
        // coordinator has to refuse; the bar already says what is happening.
        if recording.state == .finishing {
            NSSound.beep()
            return
        }
        switch command {
        case .recordRegion: recordSetup.present(picking: .area)
        case .recordDisplay: recordSetup.present()
        case .stopRecording: recording.stop()
        // Opens the chooser rather than recording anything: the whole point of record mode
        // is that nothing starts until the user says so.
        case .recordSetup: recordSetup.toggle()
        default: break
        }
    }

    /// The menu-bar item on screen, which is the other way a recording is stopped.
    ///
    /// Read while a recording runs, so a press on it is kept out of the telemetry along
    /// with the bar's own (docs/09 U3.2).
    var menuBarItemFrame: CGRect? {
        guard let button = statusItemController?.statusItem.button, let window = button.window else {
            return nil
        }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
}
