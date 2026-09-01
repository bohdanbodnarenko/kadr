import AppKit
import Foundation
import RecordingCore
import SettingsKit
import Shared

/// The wait before a recording begins (docs/03 §1.8).
///
/// A still got a self-timer and a recording did not, which is backwards: a photograph can be
/// retaken in a second and a recording has to be made again from the top. So every recording
/// used to begin on the same frame as the click, and its first second was the pointer
/// travelling away from whatever had just been pressed.
///
/// The wait doubles as the control strip the spec asks for: the floating bar shows
/// microphone, system sound and camera while the numbers run, so the three things a
/// recording is most often ruined by forgetting are decided in time that was being spent
/// anyway.
@MainActor
extension RecordingCoordinator {
    /// Counts down, then records (docs/03 §1.8).
    ///
    /// Recording used to begin on the same frame as the click, so the first second of every
    /// screen recording was the pointer travelling away from whatever had just been pressed
    /// — the menu item, the Record button, the corner of the selection. A still gets a
    /// timer and a recording did not, which is backwards: a photograph can be retaken in a
    /// second and a recording has to be made again from the top.
    ///
    /// Escape cancels the countdown, and zero seconds skips it entirely rather than costing
    /// a frame.
    func startAfterCountdown(target: RecordingTarget) {
        // Never for an automated recording: `kadr record-screen` is a script, and a script
        // does not need three seconds to put its pointer somewhere. A countdown there is
        // just latency somebody has to work around.
        let seconds = startedByAutomation ? 0 : settings.recordingCountdownSeconds
        state = .starting
        pendingTarget = target
        countdown.run(seconds: seconds) { [weak self] in
            guard let self else { return }
            pendingTarget = nil
            // `.starting` was claimed when the countdown began, so a second hotkey press
            // could not start a second recording while the numbers were on screen. It stays
            // claimed straight through into the recording.
            start(target: target, alreadyClaimed: true)
        }
    }

    /// Whether the countdown is on screen and recording has not begun.
    var isCountingDown: Bool {
        countdown.isRunning
    }

    /// Skips the rest of the countdown and starts now.
    ///
    /// The wait exists so somebody can get into position; the moment they are, waiting out
    /// the remaining two seconds is time they spend looking at a number.
    func startCountdownNow() {
        guard let target = pendingTarget, countdown.isRunning else { return }
        countdown.cancel()
        pendingTarget = nil
        start(target: target, alreadyClaimed: true)
    }

    // What the countdown is going to record, so "Start now" knows what to start.

    /// Cancels a countdown that has not started recording yet.
    ///
    /// Separate from `cancel()` because there is no engine, no session and no footage yet —
    /// only a promise to begin, and the only thing to undo is the promise.
    func cancelCountdown() -> Bool {
        guard countdown.isRunning else { return false }
        countdown.cancel()
        pendingTarget = nil
        state = .idle
        return true
    }
}
