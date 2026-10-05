import AnnotationModel
import AnnotationRender
import AppKit
import EditorUI
import os
import Shared
import StudioSession

/// The editor process (docs/04 §1, §6).
///
/// A separate app rather than a window in the agent, and the reason is memory: the SwiftUI
/// runtime, the undo stack and a full-resolution bitmap all live here, and all of it goes
/// back to the OS when the last window closes. Process exit is the garbage collector.
///
/// `.regular` activation, so it has a Dock icon and ⌘Tab like the document editor it is —
/// which also sidesteps every LSUIElement focus quirk the agent has to work around.
@main
final class EditorAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private static let shared = EditorAppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.run()
    }

    private let logger = KadrLog.logger(.app)
    private let signposter = KadrLog.signposter(.app)
    private var windows: [EditorWindowController] = []
    /// Trim windows, which are the same idea over a recording (docs/03 §1.8).
    private var trimWindows: [TrimWindowController] = []
    private var studioWindows: [StudioWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()

        // Recovery copies for captures that no longer exist are just clutter in
        // Application Support, and a deleted capture should not leave its annotations
        // behind (docs/07 H5, M7).
        EditorAutosave().sweepOrphans()
        // Copies of Finder-opened images are only for the window that edits them, and stale
        // hand-off markers mean an open that never arrived (docs/18 ED-1).
        CaptureImporter().sweepImports(keeping: Set(windows.map(\.documentURL)))
        EditorHandoff().sweepExpired()
        // Studio Copy leaves its render behind so the clipboard outlives the window; a day
        // later nobody is pasting it (docs/18 STU-1).
        Task.detached(priority: .utility) { StudioDocumentModel.sweepStagedRenders() }

        // Opened with no document — the agent always passes one, so this is a developer
        // launching the editor directly.
        if windows.isEmpty {
            logger.info("Editor launched with no capture; waiting for one to be opened")
        }
        NSApp.activate()
    }

    /// The agent hands a capture over by file URL (docs/04 §6).
    ///
    /// Finder does too, once the app declares the image types it reads — and a file that
    /// arrived from Finder is copied into Kadr's own folder first, so editing it can never
    /// touch the original (docs/09 U1.8).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            open(imported(url) ?? url)
        }
    }

    /// Kadr's own copy of a file that came from outside.
    ///
    /// Only files from outside: a capture the agent just took is already Kadr's, and
    /// copying it again would leave two of everything.
    private func imported(_ url: URL) -> URL? {
        guard url.pathExtension.lowercased() != StylePresetTransfer.pathExtension else { return nil }
        // A project is the user's own document: edited where it is, so saving it writes
        // back to the file they double-clicked, not to a hidden copy (T-ED-9).
        guard url.pathExtension.lowercased() != KadrDocumentFile.fileExtension else { return nil }
        guard !isKadrOwned(url), !TrimWindowController.handles(url) else { return nil }
        // A capture the agent handed over is edited in place, so ⌘S and Move to Trash act
        // on the file the user sees (docs/18 ED-1).
        guard !EditorHandoff().consume(url) else { return nil }
        return CaptureImporter().copyIntoLibrary(url)
    }

    /// Whether a file already lives somewhere Kadr controls.
    private func isKadrOwned(_ url: URL) -> Bool {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }
        let kadr = support.appendingPathComponent("Kadr", isDirectory: true).standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(kadr)
    }

    private func importStylePreset(_ url: URL) {
        do {
            let preset = try StylePresetTransfer.decoding(Data(contentsOf: url))
            _ = StylePresetStore().add(preset)
            let alert = NSAlert()
            alert.messageText = "Imported “\(preset.name)”."
            alert.informativeText = "The look is in the editor’s Look list. Open a capture to apply it."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { _ in }
            } else {
                alert.runModal()
            }
            logger.info("Imported look \(preset.name, privacy: .public)")
        } catch {
            presentOpenFailure(for: url, error: error)
        }
    }

    /// The File ▸ Open command, for a capture Kadr never took.
    @objc func importImage(_ sender: Any?) {
        guard let url = CaptureImporter().promptForImport() else { return }
        open(url)
    }

    /// File ▸ Open Recent: the documents opened before, most recent first (T-ED-9).
    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(imported(url) ?? url)
    }

    @objc func clearRecentDocuments(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(clearRecentDocuments(_:)):
            !NSDocumentController.shared.recentDocumentURLs.isEmpty
        default:
            true
        }
    }

    /// The whole point of the separate process: when the last window goes, so does the
    /// memory (docs/04 §7 rule 4).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q asks about unsaved edits and running exports before anything goes (T-ED-7,
    /// docs/11 S0.4).
    ///
    /// Exports: without asking, the process died mid-write, the renderer's `defer` never
    /// ran, and the half-finished movie survived at the path the user picked, looking like
    /// a finished export. `.terminateLater` is the only reply that buys the time to delete it.
    ///
    /// Edits: each dirty window shows its Save / Don't Save / Cancel sheet in turn, and
    /// with several a TextEdit-style Review Changes alert comes first. Cancel anywhere
    /// keeps the app running with every window as it was.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = windows.filter(\.model.hasUnsavedChanges)
        let busy = studioWindows.filter { !$0.longOperations.isEmpty }
        guard !dirty.isEmpty || !busy.isEmpty else {
            commitStudioSessions()
            return .terminateNow
        }
        // A durable copy first, in case the review is interrupted (docs/16 ED-7).
        for controller in dirty {
            controller.flushAutosaveSynchronously()
        }

        // Every long operation, not only exports (docs/17 T-STU-9): a transcription, a
        // model download or an audio export was ended by ⌘Q without a word.
        if !busy.isEmpty, !confirmQuittingDuringLongOperations(busy) {
            return .terminateCancel
        }

        Task { @MainActor in
            let proceed = await reviewBeforeQuitting(dirty)
            if proceed {
                for window in busy {
                    await window.cancelLongOperations()
                }
                self.commitStudioSessions()
            }
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    private func confirmQuittingDuringLongOperations(_ busy: [StudioWindowController]) -> Bool {
        let operations = busy.flatMap(\.longOperations)
        let alert = NSAlert()
        alert.messageText = operations.count == 1
            ? "Studio work is still running."
            : "\(operations.count) studio tasks are still running."
        alert.informativeText = "Quitting now stops "
            + StudioWindowController.list(operations)
            + ", and any partly-written file is deleted."
        alert.alertStyle = .warning
        // Keep Working is the Return default; quitting is the destructive choice (T-SH-6).
        alert.addButton(withTitle: "Keep Working")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Whether every dirty window was saved or deliberately discarded.
    private func reviewBeforeQuitting(_ dirty: [EditorWindowController]) async -> Bool {
        guard !dirty.isEmpty else { return true }
        if dirty.count > 1 {
            let alert = NSAlert()
            alert.messageText = "You have \(dirty.count) Kadr documents with unsaved changes. "
                + "Do you want to review these changes before quitting?"
            alert.informativeText = "If you don’t review your documents, all your changes will be lost."
            alert.addButton(withTitle: "Review Changes…")
            alert.addButton(withTitle: "Cancel")
            let discard = alert.addButton(withTitle: "Discard Changes")
            discard.hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                break
            case .alertThirdButtonReturn:
                for controller in dirty {
                    controller.autosave.discard(for: controller.documentURL)
                }
                return true
            default:
                return false
            }
        }
        for controller in dirty {
            let proceed = await withCheckedContinuation { continuation in
                controller.reviewUnsavedChanges { continuation.resume(returning: $0) }
            }
            guard proceed else { return false }
        }
        return true
    }

    private func open(_ url: URL) {
        let state = signposter.beginInterval("openCapture")
        defer { signposter.endInterval("openCapture", state) }

        if url.pathExtension.lowercased() == StylePresetTransfer.pathExtension {
            importStylePreset(url)
            return
        }

        // A recording session opens into the studio. Checked before the trim window,
        // because a `.kadrrec` contains a movie and would otherwise be opened for trimming
        // — which is the same recording with none of the sidecar that makes it worth
        // editing (docs/09 U3).
        if url.pathExtension.lowercased() == RecordingSession.fileExtension {
            openInStudio(RecordingSession(directory: url))
            return
        }

        // A recording opens into the *studio* when there is a session beside it.
        //
        // This is the difference between opening a recording and opening a video file. A
        // session carries the pointer telemetry, the camera track and the manifest — zooms,
        // cuts, speed, reframe, the reconstructed cursor, the lot. Without this check every
        // recording landed in the trim window instead: an `AVPlayerView` whose only edit is
        // dragging the two ends in, which is a fraction of what had been recorded for it
        // and reads as the studio not existing.
        //
        // Looked up by file identity rather than by path, so a recording the user has since
        // moved or renamed still finds its session.
        if TrimWindowController.handles(url), let session = studioSession(forFootageAt: url) {
            openInStudio(session)
            return
        }

        // A movie with no session behind it opens into the trim window; there is nothing to
        // annotate on a plain video, and trimming is the honest offer (docs/03 §1.8).
        if TrimWindowController.handles(url) {
            openForTrimming(url)
            return
        }

        do {
            let controller = try EditorWindowController(fileURL: url)
            controller.onClose = { [weak self, weak controller] in
                guard let self else { return }
                windows.removeAll { $0 === controller }
                // Each window's redaction previews leave with it; what the windows shared
                // (decoded inserts) goes once none is left to use it.
                if windows.isEmpty {
                    AnnotationRenderCaches.removeAll()
                }
            }
            windows.append(controller)
            controller.show()
            if !isKadrOwned(url) || url.pathExtension.lowercased() == KadrDocumentFile.fileExtension {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
            logger.info("Opened \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Could not open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            presentOpenFailure(for: url, error: error)
        }
    }

    /// The studio session whose footage this is, if one exists.
    ///
    /// The same lookup the agent's card does, repeated here because the editor is opened
    /// from Finder and from the after-capture action as well as from a card — and a
    /// recording should reach the studio however it was asked for.
    private func studioSession(forFootageAt url: URL) -> RecordingSession? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        let root = RecordingSession.defaultRoot(applicationSupport: support)
        return RecordingSessionStore(root: root).session(forFootageAt: url)
    }

    /// ⌘Q never reaches `windowWillClose`, so each studio commits here (docs/17 T-STU-9).
    private func commitStudioSessions() {
        for window in studioWindows {
            window.commitForQuit()
        }
    }

    private func openInStudio(_ session: RecordingSession) {
        // One window per recording (docs/17 T-STU-9): two would autosave over each other.
        let directory = session.directory.standardizedFileURL
        if let open = studioWindows.first(where: { $0.sessionDirectory == directory }) {
            open.bringToFront()
            return
        }
        do {
            let controller = try StudioWindowController(session: session)
            controller.onClose = { [weak self, weak controller] in
                self?.studioWindows.removeAll { $0 === controller }
            }
            studioWindows.append(controller)
            controller.show()
            logger.info("Opened \(session.directory.lastPathComponent, privacy: .public) in the studio")
        } catch {
            logger.error("Could not open the studio: \(error.localizedDescription, privacy: .public)")
            presentOpenFailure(for: session.directory, error: error)
        }
    }

    private func openForTrimming(_ url: URL) {
        do {
            let controller = try TrimWindowController(fileURL: url)
            controller.onClose = { [weak self, weak controller] in
                self?.trimWindows.removeAll { $0 === controller }
            }
            trimWindows.append(controller)
            controller.show()
            logger.info("Opened \(url.lastPathComponent, privacy: .public) for trimming")
        } catch {
            logger.error("Could not trim \(url.lastPathComponent, privacy: .public)")
            presentOpenFailure(for: url, error: error)
        }
    }

    @objc func openHelp(_ sender: Any?) {
        EditorHelpWindowController.shared.show(topic: .editor)
    }

    @objc func openKeyboardShortcuts(_ sender: Any?) {
        EditorHelpWindowController.shared.show(topic: .shortcuts)
    }

    private func presentOpenFailure(for url: URL, error: any Error) {
        let alert = NSAlert()
        alert.messageText = "Kadr could not open “\(url.lastPathComponent)”."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}
