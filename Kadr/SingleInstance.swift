import AppKit
import CaptureCore
import os
import Shared

/// One Kadr at a time (docs/17 T-SH-3).
///
/// A copy on the disk image and one in /Applications, or a development build and a
/// release, used to run side by side: every hotkey registered twice, two status items,
/// and only one of them owning the CLI's port. The second copy to start now hands over to
/// the first and quits.
nonisolated enum SingleInstance {
    /// Passed to the instance a permission relaunch starts, which must not yield to the
    /// instance that is quitting to make way for it.
    static let relaunchArgument = RelaunchHelper.relaunchArgument

    /// Whether this process should quit in favour of one already running.
    static func shouldYield(
        otherInstanceCount: Int,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        guard otherInstanceCount > 0 else { return false }
        if arguments.contains(relaunchArgument) {
            return false
        }
        // A test host must run whatever is installed on the machine.
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return false
        }
        return true
    }

    /// Hands over to the running copy and quits. Returns false when this copy should
    /// carry on launching.
    ///
    /// `beforeQuitting` runs first so the caller can mark itself as yielding: this copy
    /// never owned the desktop icons, the CLI port or the pins, and its termination path
    /// must not restore or flush any of them on the other copy's behalf.
    @MainActor
    static func yieldIfAnotherIsRunning(beforeQuitting: () -> Void) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != current && !$0.isTerminated }
        guard shouldYield(
            otherInstanceCount: others.count,
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ), let running = others.first else { return false }

        KadrLog.logger(.app).notice("Another Kadr is already running; handing over to it")
        // Opening the running copy's bundle delivers a reopen to it, which shows its menu or
        // brings its window forward — the agent's equivalent of activating it.
        if let url = running.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        beforeQuitting()
        NSApp.terminate(nil)
        return true
    }
}
