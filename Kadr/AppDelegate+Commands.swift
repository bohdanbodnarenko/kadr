import AppKit
import AutomationKit
import os
import RecordingCore
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
        switch command {
        case .captureScrolling:
            scrollCapture.begin()
        // The record hotkeys toggle (docs/03 §1.8). Pressing the shortcut you started with
        // is the first thing anybody tries when they want to stop, and it used to be
        // swallowed by the `!isRecording` guard — so the app looked like it had no way out
        // at all. Three ways now: this, the floating bar, and the menu.
        case .recordRegion:
            if recording.isRecording {
                recording.stop()
            } else {
                recording.beginRegionRecording()
            }
        case .recordDisplay:
            if recording.isRecording {
                recording.stop()
            } else {
                recording.beginDisplayRecording()
            }
        case .stopRecording:
            recording.stop()
        case .toggleDesktopIcons:
            desktopHygiene.toggleUserHide()
        default:
            break
        }
    }

    /// The commands that go through the selection overlay. Returns whether it was one.
    func performCapture(_ command: CaptureCommand) -> Bool {
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

    /// Keeps the menu bar and the floating controls in step with the recording.
    func refreshStatusItemIcon() {
        guard let recording = recordingStorage, recording.isRecording else {
            statusItemController?.showIdleIcon()
            recordingControlBar.dismiss()
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
            cancel: { [weak self] in self?.recording.cancel() }
        )
    }

    /// Reopens onboarding, which is also how the user recovers a revoked grant.
    func showOnboarding() {
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
        history.showWindow { [weak self] record in
            self?.areaCapture.reopenFromHistory(record)
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
}
