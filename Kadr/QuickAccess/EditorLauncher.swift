import AppKit
import os
import Shared

/// Opens a capture in the embedded editor app (docs/04 §6).
///
/// The editor is a separate process launched by URL rather than a window in the agent, so
/// the SwiftUI runtime, the undo stack and the full-resolution bitmap all die with it.
/// The agent's job here is only to hand over a file.
@MainActor
struct EditorLauncher {
    private let logger = KadrLog.logger(.app)

    /// `Kadr.app/Contents/Applications/KadrEditor.app`, where the build embeds it.
    var editorURL: URL? {
        let embedded = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Applications/KadrEditor.app")
        return FileManager.default.fileExists(atPath: embedded.path) ? embedded : nil
    }

    var isAvailable: Bool {
        editorURL != nil
    }

    /// Opens a capture for annotation.
    func open(_ fileURL: URL) {
        guard let editorURL else {
            logger.error("The editor is missing from the app bundle")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // One editor process serving several windows: cheaper than a process per capture,
        // and it still exits completely when the last window closes.
        configuration.createsNewApplicationInstance = false

        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in
                    logger.error("Could not open the editor: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
