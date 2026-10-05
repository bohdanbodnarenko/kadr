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

    /// Where the editor is, or nil when this build has none.
    ///
    /// Stored rather than computed so a test can stand in a launcher that cannot open
    /// anything and exercise that branch without launching a real application.
    let editorURL: URL?

    init(editorURL: URL? = EditorLauncher.embeddedURL) {
        self.editorURL = editorURL
    }

    /// `Kadr.app/Contents/Applications/KadrEditor.app`, where the build embeds it.
    static var embeddedURL: URL? {
        let embedded = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Applications/KadrEditor.app")
        return FileManager.default.fileExists(atPath: embedded.path) ? embedded : nil
    }

    var isAvailable: Bool {
        editorURL != nil
    }

    /// Opens a capture for annotation.
    ///
    /// - Parameter completion: whether an editor is actually on screen. Callers change what
    ///   the overlay is doing on the strength of this, so "I asked" is not good enough — a
    ///   build with no editor embedded would otherwise tuck the cards away for an editor
    ///   that never arrives.
    func open(_ fileURL: URL, then completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard let editorURL else {
            logger.error("The editor is missing from the app bundle")
            completion?(false)
            return
        }
        let logger = logger
        // The capture is the agent's own file: tell the editor to edit it where it is
        // rather than copy it in like a Finder open (docs/18 ED-1).
        do {
            try EditorHandoff().mark(fileURL)
        } catch {
            logger.error("Could not mark the editor hand-off: \(error.localizedDescription, privacy: .public)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // One editor process serving several windows: cheaper than a process per capture,
        // and it still exits completely when the last window closes.
        configuration.createsNewApplicationInstance = false

        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: configuration) { app, error in
            Task { @MainActor in
                if let error {
                    logger.error("Could not open the editor: \(error.localizedDescription, privacy: .public)")
                }
                completion?(app != nil && error == nil)
            }
        }
    }
}
