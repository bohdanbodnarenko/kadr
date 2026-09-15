import AppKit
import AutomationKit
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
             .selfTimer, .freezeScreen, .closeAllOverlays, .saveAllOverlays, .hideOverlays,
             .hidePins, .pinClipboard:
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
            allInOne.toggle()
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
        case .hidePins:
            areaCapture.togglePinsHidden()
        case .pinClipboard:
            areaCapture.pinClipboard()
        default:
            return false
        }
        return true
    }

    /// What the All-in-One strip starts (docs/03 §1.4).
    func performAllInOne(_ mode: AllInOneMode) {
        let frontmost = allInOne.frontmostBeforePresent
        allInOne.frontmostBeforePresent = nil
        switch mode {
        case .area: areaCapture.beginOverlayCapture(mode: .area, frontmost: frontmost)
        case .window: areaCapture.beginOverlayCapture(mode: .window, frontmost: frontmost)
        case .screen: areaCapture.captureAllDisplays()
        case .record: recordSetup.toggle()
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
        guard let recording = recordingStorage, recording.isRecording else {
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
        guard settings.recordingShowsControlBar else {
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
        guard let recording = recordingStorage, recording.isRecording else { return nil }
        return RecordingControls(
            elapsedText: recording.elapsedText,
            isPaused: recording.state == .paused,
            stop: { [weak self] in self?.recording.stop() },
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
            microphoneIsSilent: recording.settings.recordsMicrophone
                && recording.elapsed > 2
                && recording.microphonePeakMax < AudioMeter.silence,
            notice: recording.liveNotice,
            isTransitioning: recording.isTransitioning
        )
    }

    /// Reopens onboarding, which is also how the user recovers a revoked grant.
    func showOnboarding() {
        // Replaying the welcome re-arms the card tip too. Somebody asking to be shown the
        // introduction again is asking about the whole app, and the one explanation that
        // only appears over a real capture is the part they are most likely to have missed.
        settings.hasSeenQuickAccessTip = false
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
}
