import AnnotationModel
import AppKit
import EditorUI
import os
import Shared

/// The editor process (docs/04 §1, §6).
///
/// A separate app rather than a window in the agent, and the reason is memory: the SwiftUI
/// runtime, the undo stack and a full-resolution bitmap all live here, and all of it goes
/// back to the OS when the last window closes. Process exit is the garbage collector.
///
/// `.regular` activation, so it has a Dock icon and ⌘Tab like the document editor it is —
/// which also sidesteps every LSUIElement focus quirk the agent has to work around.
@main
final class EditorAppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

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
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            open(url)
        }
    }

    /// The whole point of the separate process: when the last window goes, so does the
    /// memory (docs/04 §7 rule 4).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func open(_ url: URL) {
        let state = signposter.beginInterval("openCapture")
        defer { signposter.endInterval("openCapture", state) }

        // A recording opens into the trim window; there is nothing to annotate on a movie,
        // and Trim is what its card offers (docs/03 §1.8, docs/07 M8).
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

    private func presentOpenFailure(for url: URL, error: any Error) {
        let alert = NSAlert()
        alert.messageText = "Kadr could not open “\(url.lastPathComponent)”."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
