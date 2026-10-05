import AppKit
import AutomationKit
import os
import RecordingCore

/// Quit, reopen and URL-scheme handling (docs/16 OUT-17, APP-1).
extension AppDelegate {
    /// Warns before quitting with a recording in flight or captures nobody has saved
    /// (docs/09 U2.1).
    ///
    /// A live recording has to be finished, not killed: ⌘Q and a Sparkle relaunch used
    /// to tear the writer down and throw the take away. Captures still on a card are
    /// kept only temporarily, so those get the same "save or discard" question.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isYieldingToAnotherInstance || isRemovingAllData {
            return .terminateNow
        }
        let unsaved = areaCaptureStorage?.quickAccess.unsavedItems ?? []
        if let recording = recordingStorage, recording.state.isActive {
            if recording.isCountingDown {
                _ = recording.cancelCountdown()
            } else if recording.state == .finishing {
                return finishRecordingThenQuit(recording, unsaved: unsaved, sender: sender)
            } else {
                return confirmQuitDuringRecording(recording, unsaved: unsaved, sender: sender)
            }
        }
        return replyForQuitWithUnsavedCaptures(unsaved)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A copy that yielded never set anything up; restoring the desktop from here
        // would undo the running copy's hidden icons (docs/17 T-SH-3).
        guard !isYieldingToAnotherInstance, !isRemovingAllData else { return }
        automationListener?.stop()
        statusItemController?.stopObservingMenuBarVisibility()
        // Pin moves are saved on a debounce; the last one must not be lost to ⌘Q.
        areaCaptureStorage?.pins.flushPendingSave()
        desktopHygiene.prepareForTermination()
    }

    /// Handles `kadr://…`. The answer is dropped: a URL has nowhere to send one, which is
    /// exactly why the CLI exists.
    ///
    /// Every URL passes the consent gate first (docs/17 T-OUT-12): any app can open one,
    /// and without the gate any app could take screenshots through Kadr's grant.
    func application(_ application: NSApplication, open urls: [URL]) {
        let sender = AutomationConsentGate.currentSender()
        for url in urls {
            do {
                let command = try AutomationParser.command(from: url)
                AutomationConsentGate.shared.authorize(
                    command,
                    from: sender,
                    openSettings: { [weak self] in self?.settingsWindowController.show(tab: .advanced) },
                    run: {
                        automation.perform(command) { [weak self] response in
                            guard response.status != .ok else { return }
                            let message = response.message ?? response.status.rawValue
                            guard let logger = self?.logger else { return }
                            // The caller is often a script with nobody watching its exit
                            // code; the person who ran it should still hear (docs/18 X-5a).
                            FailurePresenter.report(
                                "A Kadr automation command failed.",
                                detail: message,
                                logger: logger
                            )
                        }
                    }
                )
            } catch {
                let message = (error as? AutomationError)?.localizedDescription ?? error.localizedDescription
                logger.error("Could not run \(url.absoluteString, privacy: .private): \(message, privacy: .public)")
                FailurePresenter.present(message: "Kadr could not run that automation command. \(message)")
            }
        }
    }

    private func finishRecordingThenQuit(
        _ recording: RecordingCoordinator,
        unsaved: [QuickAccessItem],
        sender: NSApplication
    ) -> NSApplication.TerminateReply {
        finalizeStagedCapturesBeforeQuit(unsaved)
        recording.finishForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuitDuringRecording(
        _ recording: RecordingCoordinator,
        unsaved: [QuickAccessItem],
        sender: NSApplication
    ) -> NSApplication.TerminateReply {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "A screen recording is still in progress."
        var info = "Kadr will finish and save the recording before quitting. "
            + "This can take a moment for a long recording."
        if !unsaved.isEmpty {
            info += unsaved.count == 1
                ? " One capture on a card has not been saved either."
                : " \(unsaved.count) captures on cards have not been saved either."
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = unsaved.count == 1
                ? "Save 1 capture too"
                : "Save \(unsaved.count) captures too"
            alert.suppressionButton?.state = .on
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        // Cancel is the first button, so it is the default Return answers: a stray
        // Return must not end the take.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Finish Recording and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on {
            let saved = finalizeStagedCapturesBeforeQuit(unsaved)
            if saved < unsaved.count {
                return .terminateCancel
            }
        }
        recording.finishForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func replyForQuitWithUnsavedCaptures(_ unsaved: [QuickAccessItem]) -> NSApplication.TerminateReply {
        guard let quickAccess = areaCaptureStorage?.quickAccess else { return .terminateNow }
        guard !unsaved.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = unsaved.count == 1
            ? "One capture has not been saved."
            : "\(unsaved.count) captures have not been saved."
        alert.informativeText = "Captures still on screen are kept temporarily and cleared "
            + "within a day. Saving them puts them in your capture folder."
        alert.addButton(withTitle: unsaved.count == 1 ? "Save and Quit" : "Save All and Quit")
        alert.addButton(withTitle: "Discard and Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate()

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let saved = quickAccess.finalizeAllStaged()
            logger.info("Saved \(saved, privacy: .public) capture(s) before quitting")
            if saved < unsaved.count {
                return .terminateCancel
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    @discardableResult
    func finalizeStagedCapturesBeforeQuit(_ unsaved: [QuickAccessItem]) -> Int {
        guard !unsaved.isEmpty, let quickAccess = areaCaptureStorage?.quickAccess else { return 0 }
        return quickAccess.finalizeAllStaged()
    }
}
