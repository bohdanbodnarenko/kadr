import AppKit
import Carbon.HIToolbox
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
final class StudioWindowController: NSResponder, NSWindowDelegate, NSMenuItemValidation {
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

    let model: StudioDocumentModel
    private let logger = KadrLog.logger(.app)
    private var window: NSWindow?
    private var hostingView: NSView?
    /// True once the user has confirmed a close that was interrupted by speech or export.
    private var isClosingConfirmed = false

    var onClose: (() -> Void)?

    /// Whether this window is in the middle of a render (docs/11 S0.4).
    var isExporting: Bool {
        model.isExporting
    }

    /// Stops a render and waits for its cleanup, so quitting cannot outrun it.
    func cancelExport() async {
        await model.cancelExport()
    }

    /// What quitting or closing would interrupt (docs/17 T-STU-9).
    var longOperations: [String] {
        model.longOperations
    }

    /// Stops all of it and waits for partial files to be deleted.
    func cancelLongOperations() async {
        await model.cancelLongOperations()
    }

    /// The recording this window edits, so a second open can find it (docs/17 T-STU-9).
    var sessionDirectory: URL {
        model.session.directory.standardizedFileURL
    }

    /// Commits the edit on quit (docs/17 T-STU-9).
    ///
    /// `windowWillClose` is not called when the app terminates, so ⌘Q left every open
    /// session with a draft and no commit — which is what a crash looks like, and the
    /// agent then offered to "recover" a recording nobody lost.
    func commitForQuit() {
        model.stopPlayback()
        model.commitOnClose()
    }

    /// Brings an already-open window forward rather than opening a second one over the
    /// same session, which would autosave over each other.
    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(session: RecordingSession) throws {
        guard let model = StudioDocumentModel(session: session) else {
            throw OpenError.notASession(session.directory)
        }
        self.model = model
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        window.title = model.session.displayName
        window.contentView = hosting
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        model.session.markOpened()
        self.window = window

        // Into the responder chain (docs/08 §3: "command-stack undo vs …").
        //
        // The window was built by hand rather than by an `NSWindowController`, so nothing
        // linked this object to the chain — and the Edit menu's `undo:` therefore walked
        // from the hosting view to the window and off the end. ⌘Z did nothing in the studio
        // while an Undo button sat beside the timeline doing something, which is a worse
        // state than having neither.
        nextResponder = window.nextResponder
        window.nextResponder = self

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - The Edit menu

    @objc func undo(_ sender: Any?) {
        model.undo()
    }

    @objc func redo(_ sender: Any?) {
        model.redo()
    }

    /// Copies the original footage. A focused text field still gets ⌘C first because it
    /// sits earlier in the responder chain than this controller.
    @objc func copy(_ sender: Any?) {
        Task { await model.copyEditedToClipboard() }
    }

    @objc func splitClipAtPlayhead(_ sender: Any?) {
        model.splitAtPlayhead()
    }

    @objc func toggleInspector(_ sender: Any?) {
        model.isInspectorPresented.toggle()
    }

    @objc func exportMovie(_ sender: Any?) {
        guard model.exportProgress == nil else { return }
        model.showsExportOptions = true
    }

    // MARK: - Playback keys

    /// Space and the arrows, from the responder chain rather than from the menu.
    ///
    /// They are bare keys, and a bare key equivalent in a menu fires *before* the first
    /// responder sees the event — so Space would start playback while the user was typing
    /// in the transcript, and ← would scrub instead of moving the insertion point. Arriving
    /// through `keyDown` they reach this controller only once nothing closer to the
    /// keyboard — a text field, or the focused timeline — has taken them.
    override func keyDown(with event: NSEvent) {
        guard !performPlaybackKey(event) else { return }
        super.keyDown(with: event)
    }

    private func performPlaybackKey(_ event: NSEvent) -> Bool {
        // Cropping owns the whole preview, and an export is not interruptible from here.
        guard !model.isCropping, model.exportProgress == nil else { return false }
        guard let key = StudioPlaybackKey.match(
            keyCode: Int(event.keyCode),
            modifiers: event.modifierFlags
        ) else {
            return false
        }
        switch key {
        case .togglePlayback: model.togglePlayback()
        case let .step(frames): model.step(frames: frames)
        case let .skip(seconds): model.step(seconds: seconds)
        }
        return true
    }

    /// Greys the menu items out when there is nothing to undo, rather than letting them
    /// look available and do nothing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): model.canUndo
        case #selector(redo(_:)): model.canRedo
        case #selector(copy(_:)):
            FileManager.default.fileExists(atPath: model.session.screenURL.path)
        case #selector(splitClipAtPlayhead(_:)): !model.isCropping
        case #selector(exportMovie(_:)): model.exportProgress == nil
        default: true
        }
    }

    // MARK: - Exporting

    /// Asks where the finished movie goes, then renders it.
    ///
    /// A save panel rather than exporting beside the session: the session lives in
    /// Application Support, which is not somewhere anybody looks for a video.
    private func presentExportPanel(for model: StudioDocumentModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [model.exportSettings.utType]
        // The project's name, not the window's (docs/17 T-STU-12): they differ once the
        // title carries anything else, and the timestamped folder name is nobody's choice.
        panel.nameFieldStringValue = "\(model.session.displayName).\(model.exportSettings.filenameExtension)"
        panel.canCreateDirectories = true
        panel.message = "Export the edited recording."

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await model.export(to: url)
                self?.reveal(url)
            }
        }
        // A sheet on the studio window (docs/17 T-STU-12), so it is plainly attached to
        // this recording rather than floating free of it.
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
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
        if isClosingConfirmed {
            return true
        }

        let operations = model.longOperations
        guard !operations.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = "Stop work on “\(sender.title)”?"
        alert.informativeText = Self.list(operations).prefix(1).uppercased()
            + Self.list(operations).dropFirst()
            + (operations.count == 1 ? " is" : " are")
            + " still running. Closing now stops it, and any partly-written file is deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Keep Working")
        let responder = FocusRestoration.capture(from: sender)
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                FocusRestoration.restore(responder, in: sender)
                return
            }
            // Closed once everything has actually unwound, not once it has been told to.
            // The renderer deletes the partial file on its way out, and a window that
            // vanished first would let the process quit before that ran.
            Task { @MainActor [weak self] in
                await self?.model.cancelLongOperations()
                self?.isClosingConfirmed = true
                self?.window?.close()
            }
        }
        return false
    }

    /// "an export and a transcription".
    static func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }

    func windowWillClose(_ notification: Notification) {
        // Stop decoding before anything else: a playback loop left running holds the frame
        // generator and keeps composing for a window nobody can see.
        model.stopPlayback()
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
