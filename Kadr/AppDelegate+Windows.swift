import AppKit
import AutomationKit
import CaptureCore
import os
import OverlayKit

extension AppDelegate {
    /// Dock / Finder "Open" while Kadr is already running (docs/16 APP-1, APP-2).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if recordingStorage?.isRecording == true {
            refreshRecordingControlBar()
        } else if flag, let window = reopenableWindow() {
            // History, Settings or Help is open: a Dock click means "show me that", not
            // the status menu on top of it (docs/17 T-SH-5).
            ActivationJuggler.shared.bringForward(window)
        } else if statusItemController?.statusItem.isVisible == true {
            statusItemController?.popIdleMenu()
        } else {
            openSettings()
        }
        return false
    }

    /// The regular window a reopen should bring back: the frontmost titled Kadr window.
    /// Panels — cards, pins, the island — are not "windows" to the user and are left
    /// alone (docs/17 T-SH-5).
    func reopenableWindow() -> NSWindow? {
        NSApp.orderedWindows.first { window in
            (window.isVisible || window.isMiniaturized)
                && !(window is NSPanel)
                && window.styleMask.contains(.titled)
        }
    }

    func makeOnboardingModel() -> OnboardingModel {
        let model = OnboardingModel(permissions: permissions, settings: settings, loginItem: loginItem)
        model.onOpenPractice = { [weak self] url in
            self?.areaCapture.quickAccess.openInEditor(url)
        }
        model.prepareForRelaunch = { [weak self] in self?.releaseForRelaunch() }
        model.relaunchFailed = { [weak self] in self?.reclaimAfterFailedRelaunch() }
        return model
    }

    /// The CLI's end of the automation channel (docs/03 §8.4). A second Kadr would find
    /// the name taken, and should not pretend to own automation.
    func startAutomationListener() {
        guard automationListener == nil else { return }
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
    }

    /// Before a permission relaunch starts the next instance: give up the port and the
    /// hotkeys it will ask for. The new instance used to start while this one still held
    /// them, fail to open the CLI's port and never retry (docs/17 T-SH-3).
    func releaseForRelaunch() {
        logger.notice("Releasing the automation port and hotkeys for a relaunch")
        automationListener?.stop()
        automationListener = nil
        hotkeyCenter?.suspend()
    }

    /// Settings ▸ Permissions ▸ Quit & Reopen Kadr (docs/17 T-SH-4).
    func relaunchForNewGrant() {
        releaseForRelaunch()
        Task {
            do {
                try await RelaunchHelper().relaunchForNewGrant()
            } catch {
                logger.error("Could not relaunch: \(error.localizedDescription, privacy: .public)")
                reclaimAfterFailedRelaunch()
            }
        }
    }

    /// The relaunch failed, so this instance is staying: take everything back.
    func reclaimAfterFailedRelaunch() {
        logger.error("Relaunch failed; re-arming the automation port and hotkeys")
        hotkeyCenter?.resume()
        startAutomationListener()
    }
}
