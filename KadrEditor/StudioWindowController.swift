import AppKit
import EditorUI
import os
import Shared
import StudioCore
import SwiftUI
import UniformTypeIdentifiers

/// One studio window over one recording session (docs/09 U3).
///
/// The same shape as the annotation editor's window: AppKit owns the window, SwiftUI lives
/// inside an `NSHostingView` that is released when it closes (CLAUDE.md rule 4). A studio
/// window holds decoded frames and a render context, so leaving one alive after it closes
/// would keep tens of megabytes for a window nobody can see.
@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    enum OpenError: LocalizedError {
        case notASession(URL)

        var errorDescription: String? {
            switch self {
            case let .notASession(url):
                "“\(url.lastPathComponent)” is not a recording Kadr can edit. It may be missing "
                    + "its footage, or it may have been recorded before the studio existed."
            }
        }
    }

    private let model: StudioDocumentModel
    private let logger = KadrLog.logger(.app)
    private var window: NSWindow?
    private var hostingView: NSView?

    var onClose: (() -> Void)?

    init(session: RecordingSession) throws {
        guard let model = StudioDocumentModel(session: session) else {
            throw OpenError.notASession(session.directory)
        }
        self.model = model
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = StudioRootView(model: model) { [weak self] model in
            self?.presentExportPanel(for: model)
        }
        let hosting = NSHostingView(rootView: root)
        hostingView = hosting

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.session.directory.deletingPathExtension().lastPathComponent
        window.contentView = hosting
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Exporting

    /// Asks where the finished movie goes, then renders it.
    ///
    /// A save panel rather than exporting beside the session: the session lives in
    /// Application Support, which is not somewhere anybody looks for a video.
    private func presentExportPanel(for model: StudioDocumentModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(window?.title ?? "Recording").mov"
        panel.canCreateDirectories = true
        panel.message = "Export the edited recording."

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await model.export(to: url)
                self?.reveal(url)
            }
        }
    }

    /// Shows the finished file, if it was written.
    ///
    /// Only on success: revealing after a failure opens a folder to point at nothing, and
    /// the failure has already been reported through the model.
    private func reveal(_ url: URL) {
        guard model.failure == nil, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Closing

    /// Closing is safe without a prompt, which the annotation editor cannot say.
    ///
    /// Every edit here has already been written to the draft as it was made, and the
    /// footage was never touched. There is nothing to lose by closing and nothing to ask
    /// about — reopening the session lands exactly where this left off.
    func windowWillClose(_ notification: Notification) {
        // Committing is what makes this a *clean* close rather than a disappearance. The
        // agent offers to recover sessions that have a draft and no commit, so a window
        // that closes without one leaves its recording looking interrupted forever.
        model.commitOnClose()
        hostingView = nil
        window?.contentView = nil
        window = nil
        onClose?()
    }
}
