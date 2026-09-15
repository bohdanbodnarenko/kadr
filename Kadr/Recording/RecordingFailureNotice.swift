import AppKit
import RecordingCore

/// Surfaces recording failures that used to be log-only (docs/16 REC-3).
///
/// Start and stop failures use a modal `NSAlert`. A stream or writer dying *during* a
/// take uses a transient line on the control bar instead — a modal over a live recording
/// would steal the recorded app's focus.
@MainActor
enum RecordingFailureNotice {
    static func presentStartFailure(_ error: any Error) {
        guard (error as? RecordingError) != .cancelledDuringStart else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording could not start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        attachShowInFinder(to: alert, error: error)
        NSApp.activate()
        handle(alert.runModal(), error: error)
    }

    static func presentStopFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording could not finish"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        attachShowInFinder(to: alert, error: error)
        NSApp.activate()
        handle(alert.runModal(), error: error)
    }

    static func presentInterruption(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Recording stopped"
        alert.informativeText = "Everything captured so far was saved. \(reason)"
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    private static func attachShowInFinder(to alert: NSAlert, error: any Error) {
        guard let directory = segmentDirectory(from: error) else { return }
        alert.informativeText += "\n\nThe footage is still in \(directory)."
        alert.addButton(withTitle: "Show in Finder")
        alert.accessoryView = FinderTarget(path: directory)
    }

    private static func handle(_ response: NSApplication.ModalResponse, error: any Error) {
        guard response == .alertSecondButtonReturn, let directory = segmentDirectory(from: error) else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
    }

    private static func segmentDirectory(from error: any Error) -> String? {
        guard let recordingError = error as? RecordingError,
              case let .stitchFailed(_, directory) = recordingError
        else {
            return nil
        }
        return directory
    }
}

/// Carries the folder path on the alert without putting it in the button title.
private final class FinderTarget: NSView {
    let path: String

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
