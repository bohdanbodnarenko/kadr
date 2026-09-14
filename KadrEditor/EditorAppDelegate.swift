import AnnotationModel
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
        guard !isKadrOwned(url), !TrimWindowController.handles(url) else { return nil }
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

    @MainActor
    @objc func saveDocument(_ sender: Any?) {
        keyEditor()?.export(.save)
    }

    @MainActor
    @objc func saveDocumentAs(_ sender: Any?) {
        keyEditor()?.export(.saveAs)
    }

    @MainActor
    @objc func saveProjectDocument(_ sender: Any?) {
        keyEditor()?.saveProject()
    }

    @MainActor
    @objc func printDocument(_ sender: Any?) {
        keyEditor()?.export(.print)
    }

    @MainActor
    private func keyEditor() -> EditorWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.last
    }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveDocument(_:)),
             #selector(saveDocumentAs(_:)),
             #selector(saveProjectDocument(_:)),
             #selector(printDocument(_:)):
            keyEditor() != nil
        default:
            true
        }
    }

    /// The whole point of the separate process: when the last window goes, so does the
    /// memory (docs/04 §7 rule 4).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q during an export asks first, and then waits for the render to unwind
    /// (docs/11 S0.4).
    ///
    /// Without this the process died mid-write: the renderer's `defer` never ran, so the
    /// half-finished movie survived at the path the user picked, looking for all the world
    /// like a finished export. `.terminateLater` is the only reply that buys the time to
    /// delete it — `false` would refuse the quit outright, and `true` would not wait.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let exporting = studioWindows.filter(\.isExporting)
        guard !exporting.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = exporting.count == 1
            ? "An export is still running."
            : "\(exporting.count) exports are still running."
        alert.informativeText = "Quitting now discards the export, and the partly-written "
            + "file is deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Exporting")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor in
            for window in exporting {
                await window.cancelExport()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
                self?.windows.removeAll { $0 === controller }
            }
            windows.append(controller)
            controller.show()
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

    private func openInStudio(_ session: RecordingSession) {
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

    /// A minimal menu bar: the commands a `.regular` app is expected to have.
    ///
    /// Built in code rather than in a nib because there are five items and a nib would be
    /// five items plus a file nobody reads. Open is the one that earns it — without it,
    /// import-from-Finder works only by dragging onto the icon (docs/09 U1.8).
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Kadr Editor",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Services",
            action: nil,
            keyEquivalent: ""
        ).submenu = NSApp.servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kadr Editor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        ).keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Kadr Editor",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(importImage(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(
            withTitle: "Save As…",
            action: #selector(saveDocumentAs(_:)),
            keyEquivalent: "s"
        )
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        let saveProject = fileMenu.addItem(
            withTitle: "Save Project…",
            action: #selector(saveProjectDocument(_:)),
            keyEquivalent: "s"
        )
        saveProject.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(printDocument(_:)), keyEquivalent: "p")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(EditorWindowController.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(
            withTitle: "Redo",
            action: #selector(EditorWindowController.redo(_:)),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(EditorWindowController.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(EditorWindowController.copy(_:)), keyEquivalent: "c")
        let copyFlattened = editMenu.addItem(
            withTitle: "Copy Flattened Image",
            action: #selector(copyFlattenedImage(_:)),
            keyEquivalent: "c"
        )
        copyFlattened.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "Paste", action: #selector(EditorWindowController.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(EditorWindowController.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(
            withTitle: "Duplicate",
            action: #selector(EditorWindowController.duplicate(_:)),
            keyEquivalent: "d"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Bring to Front",
            action: #selector(EditorWindowController.bringToFront(_:)),
            keyEquivalent: ""
        )
        editMenu.addItem(
            withTitle: "Bring Forward",
            action: #selector(EditorWindowController.bringForward(_:)),
            keyEquivalent: "]"
        )
        editMenu.addItem(
            withTitle: "Send Backward",
            action: #selector(EditorWindowController.sendBackward(_:)),
            keyEquivalent: "["
        )
        editMenu.addItem(
            withTitle: "Send to Back",
            action: #selector(EditorWindowController.sendToBack(_:)),
            keyEquivalent: ""
        )
        editMenu.addItem(.separator())
        let lock = editMenu.addItem(
            withTitle: "Lock Objects",
            action: #selector(EditorWindowController.toggleCanvasLock(_:)),
            keyEquivalent: "l"
        )
        lock.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            withTitle: "Show Inspector",
            action: #selector(EditorWindowController.toggleInspector(_:)),
            keyEquivalent: "i"
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(
            withTitle: "Zoom Out",
            action: #selector(EditorWindowController.zoomOut(_:)),
            keyEquivalent: "-"
        )
        viewMenu.addItem(
            withTitle: "Fit Canvas",
            action: #selector(EditorWindowController.zoomToFit(_:)),
            keyEquivalent: "1"
        )
        viewMenu.addItem(
            withTitle: "Actual Size",
            action: #selector(EditorWindowController.zoomActualSize(_:)),
            keyEquivalent: "0"
        )
        viewMenu.addItem(.separator())
        let increaseTool = viewMenu.addItem(
            withTitle: "Increase Tool Size",
            action: #selector(EditorWindowController.increaseToolSize(_:)),
            keyEquivalent: "="
        )
        increaseTool.keyEquivalentModifierMask = [.shift]
        viewMenu.addItem(
            withTitle: "Decrease Tool Size",
            action: #selector(EditorWindowController.decreaseToolSize(_:)),
            keyEquivalent: "`"
        )
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        windowItem.submenu = NSApp.windowsMenu
        main.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Kadr Help", action: #selector(openHelp(_:)), keyEquivalent: "?")
        helpMenu.addItem(
            withTitle: "Keyboard Shortcuts",
            action: #selector(openKeyboardShortcuts(_:)),
            keyEquivalent: ""
        )
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        return main
    }

    @objc private func copyFlattenedImage(_ sender: Any?) {
        keyEditor()?.export(.copyFlattened)
    }

    @objc private func openHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/kadr-app/Kadr#readme") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openKeyboardShortcuts(_ sender: Any?) {
        if let url = URL(string: "https://github.com/kadr-app/Kadr/blob/main/docs/03-features.md") {
            NSWorkspace.shared.open(url)
        }
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
