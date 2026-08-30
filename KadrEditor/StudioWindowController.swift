import AppKit
import EditorUI
import os
import Shared
import StudioSession
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

    /// Whether this window is in the middle of a render (docs/11 S0.4).
    var isExporting: Bool {
        model.isExporting
    }

    /// Stops a render and waits for its cleanup, so quitting cannot outrun it.
    func cancelExport() async {
        await model.cancelExport()
    }

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

    /// Closing is safe without a prompt *unless* a render is running (docs/11 S0.4).
    ///
    /// Every edit has already been written to the draft as it was made and the footage was
    /// never touched, so there is normally nothing to lose by closing. An export is the
    /// exception: it is the one thing here that takes minutes and cannot be resumed, and
    /// closing the window used to kill it with no warning and leave a half-written movie at
    /// the path the user chose. Finder would show a file that plays for seven minutes of a
    /// ten-minute recording — worse than no file, because one of those is obviously missing
    /// and the other is quietly wrong.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isExporting else { return true }

        let alert = NSAlert()
        alert.messageText = "Stop exporting “\(sender.title)”?"
        alert.informativeText = "The export is not finished. Closing now discards it, "
            + "and the partly-written file is deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Exporting")
        alert.addButton(withTitle: "Keep Exporting")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        // Closed once the render has actually unwound, not once it has been told to. The
        // renderer deletes the partial file on its way out, and a window that vanished
        // first would let the process quit before that ran.
        Task { @MainActor [weak self] in
            await self?.model.cancelExport()
            self?.window?.close()
        }
        return false
    }

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
