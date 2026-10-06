import AppKit
import AVFoundation
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
        alert.messageText = String(localized: "Recording could not start")
        alert.informativeText = message(for: error)
        alert.addButton(withTitle: String(localized: "OK"))
        attachShowInFinder(to: alert, error: error)
        NSApp.activate()
        handle(alert.runModal(), error: error)
    }

    static func presentStopFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Recording could not finish")
        alert.informativeText = message(for: error)
        alert.addButton(withTitle: String(localized: "OK"))
        attachShowInFinder(to: alert, error: error)
        NSApp.activate()
        handle(alert.runModal(), error: error)
    }

    static func presentInterruption(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Recording stopped")
        alert.informativeText = String(localized: "Everything captured so far was saved. \(reason)")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }

    /// What to tell the user, in place of the framework's own wording where Kadr knows a
    /// plainer one (docs/18 REC P3). "The operation could not be completed (AVFoundation
    /// error -11807)" tells nobody that the disk is full.
    nonisolated static func message(for error: any Error) -> String {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        for candidate in [nsError, underlying].compactMap(\.self) {
            if let plain = plainMessage(domain: candidate.domain, code: candidate.code) {
                return plain
            }
        }
        return error.localizedDescription
    }

    nonisolated static func plainMessage(domain: String, code: Int) -> String? {
        switch (domain, code) {
        case (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue),
             (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError):
            String(localized: "The disk is full. Free up some space, then record again.")
        case (AVFoundationErrorDomain, AVError.Code.deviceNotConnected.rawValue),
             (AVFoundationErrorDomain, AVError.Code.deviceWasDisconnected.rawValue):
            String(localized: "A camera or microphone was disconnected.")
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError):
            String(localized: "Kadr is not allowed to write to the save folder. Choose another in Settings ▸ General.")
        default:
            nil
        }
    }

    private static func attachShowInFinder(to alert: NSAlert, error: any Error) {
        guard let directory = segmentDirectory(from: error) else { return }
        alert.informativeText += "\n\nThe footage is still in \(directory)."
        alert.addButton(withTitle: String(localized: "Show in Finder"))
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
