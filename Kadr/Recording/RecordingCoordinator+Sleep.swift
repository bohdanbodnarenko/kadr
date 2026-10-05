import AppKit
import os
import RecordingCore

/// Sleep, lid close and wake during a take (docs/18 REC-5, docs/03 §1.8).
///
/// Nothing reaches the screen while the Mac sleeps, so a take left running would either
/// write a frozen stretch or come back to a stream macOS stopped. Pausing first keeps the
/// file honest, and the wall-clock timer, which skips paused time, then agrees with it.
extension RecordingCoordinator {
    /// Listens for the system's sleep and wake notifications for the coordinator's lifetime.
    ///
    /// Notifications, not polling: an idle agent still costs nothing (rule 2).
    func listenForSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepTasks = [
            Task { [weak self] in
                for await _ in center.notifications(named: NSWorkspace.willSleepNotification) {
                    self?.systemWillSleep()
                }
            },
            Task { [weak self] in
                for await _ in center.notifications(named: NSWorkspace.didWakeNotification) {
                    self?.systemDidWake()
                }
            }
        ]
    }

    func systemWillSleep() {
        guard state == .recording else { return }
        logger.info("The Mac is going to sleep; pausing the recording")
        pausedForSleep = true
        pause()
    }

    func systemDidWake() {
        guard pausedForSleep else { return }
        pausedForSleep = false
        guard state == .paused else { return }
        liveNotice = Self.sleepNotice
        FeedbackAnnouncement.post(Self.sleepNotice)
    }

    /// Stays on the bar until the take resumes or ends.
    static let sleepNotice = "Paused while the Mac slept. Resume when you are ready."
}
