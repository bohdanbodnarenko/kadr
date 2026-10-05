import AppKit

/// Waiting for another app to become active, with a ceiling (docs/18 CAP-4).
///
/// The island activates Kadr so its letters work; a pick hands activation back, and macOS
/// does that asynchronously. A freeze has to wait for it, but never for long: a target
/// that quit or will not activate must not hold a capture hostage.
enum TargetActivation {
    /// How long a capture waits for its target before freezing anyway.
    static let ceiling: Duration = .milliseconds(150)

    /// Returns once the app with `pid` is frontmost, or after `ceiling`, whichever is first.
    /// Returns at once when there is no target or it is already active.
    @MainActor
    static func wait(for pid: pid_t?, ceiling: Duration = ceiling) async {
        guard let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        let waiter = Waiter()
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            // An observer rather than `notifications(named:)`: that sequence ignores
            // cancellation, so the losing side of a race kept the wait alive.
            waiter.observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier == pid else { return }
                MainActor.assumeIsolated { waiter.finish() }
            }
            waiter.deadline = Task { @MainActor in
                try? await Task.sleep(for: ceiling)
                waiter.finish()
            }
        }
    }

    /// Resumes its continuation exactly once, from whichever side gets there first.
    @MainActor
    private final class Waiter {
        var continuation: CheckedContinuation<Void, Never>?
        var observer: (any NSObjectProtocol)?
        var deadline: Task<Void, Never>?

        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            if let observer {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            observer = nil
            deadline?.cancel()
            continuation.resume()
        }
    }
}
