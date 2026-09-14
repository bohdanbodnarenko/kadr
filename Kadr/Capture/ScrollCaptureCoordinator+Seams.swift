import AppKit
import CaptureCore
import MediaExport
import os
import OverlayKit
import SelectionUI
import SettingsKit
import Shared

/// What Kadr does when the stitcher is unsure, or gives up (docs/03 §1.6).
///
/// A scroll capture that cannot be joined still holds the user's frames, so every path in
/// here is about handing those back rather than discarding them.
@MainActor
extension ScrollCaptureCoordinator {
    enum SeamChoice {
        case keep
        case retry
        case exportFrames
    }

    func reviewSeams(_ response: ScrollStitchResponse, frames: [URL]) -> SeamChoice {
        let count = response.uncertainSeams.count
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "One join in this capture is uncertain"
            : "\(count) joins in this capture are uncertain"
        alert.informativeText = "Kadr could not be sure how two frames line up, which "
            + "usually means the page moved in a way the overlap could not explain — a "
            + "sticky banner, an animation, or scrolling faster than the frames could "
            + "follow. Keep it if it looks right, retry without the frame that caused it, "
            + "or take the frames away and assemble them yourself."
        alert.addButton(withTitle: "Keep Anyway")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Export Frames")
        NSApp.activate()

        return switch alert.runModal() {
        case .alertSecondButtonReturn: .retry
        case .alertThirdButtonReturn: .exportFrames
        default: .keep
        }
    }

    func presentStitchFailure(frames: [URL]) {
        let alert = NSAlert()
        alert.messageText = "Kadr could not stitch this capture"
        alert.informativeText = "The frames are still here. You can save them and put the "
            + "page together yourself."
        alert.addButton(withTitle: "Export Frames")
        alert.addButton(withTitle: "Discard")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            exportFrames(frames)
        }
    }

    /// Hands the raw frames over, which is the honest fallback when stitching cannot be
    /// trusted (docs/03 §1.6 failure mode).
    func exportFrames(_ frames: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the \(frames.count) captured frames."
        NSApp.activate()
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let folder = directory.appendingPathComponent(
            "Kadr Scrolling Capture \(Self.folderFormatter.string(from: Date()))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for frame in frames {
                try FileManager.default.copyItem(
                    at: frame,
                    to: folder.appendingPathComponent(frame.lastPathComponent)
                )
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            logger.error("Could not export frames: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// The middle of the captured region, in screen points, which is where a synthesized
    /// scroll has to land to reach the right window.
    func centrePoint(of rect: DisplayRect, on display: DisplayGeometry) -> CGPoint {
        let screenRect = rect.inScreenSpace(GlobalCoordinateSpace.current)
        // CGEvent locations are in display space, top-left origin, which is what the rect
        // already is — the round trip is here only to make the space explicit.
        _ = screenRect
        return CGPoint(x: rect.minX + rect.width / 2, y: rect.minY + rect.height / 2)
    }

    func explainAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Kadr needs Accessibility to scroll for you"
        alert.informativeText = "Auto-scroll works by sending scroll events to the window "
            + "you picked, which macOS only allows with Accessibility permission. Grant it "
            + "in System Settings and try again — this capture will carry on with you doing "
            + "the scrolling."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
