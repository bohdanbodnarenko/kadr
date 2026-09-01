import AppKit
import os
import OverlayKit
import Shared

/// Counts down before a capture, showing the badge from docs/03 §1.5.
///
/// Named for what it does rather than the setting that drives it, so it does not
/// collide with `SettingsKit.SelfTimer`, which is the stored preference.
///
/// The countdown is a cancellable `Task`, not a repeating timer: it exists only while a
/// capture is pending, so the agent keeps its zero-timers-at-idle promise (PRD §8).
@MainActor
final class CaptureCountdown {
    private let panel = CountdownPanel()
    private let logger = KadrLog.logger(.capture)
    private var task: Task<Void, Never>?

    /// Seconds still showing, or 0 when nothing is counting.
    private(set) var remainingSeconds = 0
    /// Fired each time the number changes, so the recording bar can tick with the badge.
    var onTick: (@MainActor (Int) -> Void)?

    var isRunning: Bool {
        task != nil
    }

    /// Runs the countdown, then calls `perform`. Returns immediately.
    ///
    /// With zero seconds the work runs straight away and no badge appears — the timer
    /// being off must not add a frame of delay to every capture.
    func run(
        seconds: Int,
        placement: CountdownPlacement = .corner,
        perform: @escaping @MainActor () -> Void
    ) {
        cancel()

        guard seconds > 0 else {
            perform()
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                panel.dismiss()
                task = nil
            }

            for remaining in stride(from: seconds, to: 0, by: -1) {
                tick(remaining)
                if let screen {
                    panel.show(on: screen, seconds: remaining, placement: placement)
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    logger.info("Self-timer cancelled")
                    return
                }
            }

            guard !Task.isCancelled else { return }
            // The badge goes before the capture, so it cannot appear in the shot even if
            // window exclusion were to fail.
            panel.dismiss()
            perform()
        }
    }

    /// Called off before it fires.
    ///
    /// This used to say "Esc cancels the countdown (docs/03 §1.5)" and nothing anywhere
    /// listened for Escape — the badge is a non-activating panel in an accessory app, so it
    /// never becomes key, and a global key monitor would need an Accessibility grant this
    /// feature has no other reason to ask for. What actually calls it off is pressing the
    /// same shortcut again, which is the behaviour the recording path documents.
    func cancel() {
        task?.cancel()
        task = nil
        remainingSeconds = 0
        panel.dismiss()
    }

    private func tick(_ remaining: Int) {
        remainingSeconds = remaining
        onTick?(remaining)
    }
}
